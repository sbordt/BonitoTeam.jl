# ── Chat-global popup window for `bt_show_app` ─────────────────────────────────
# A single floating "show-app target" per session that any `bt_show_app` bubble
# can detach into. The DOM node of the embed itself is moved (via Bonito's
# `move_dom_node`, which bypasses the delete-MutationObserver), so interactive
# state stays alive across moves. The popup geometry is persisted per chat to
# `chat_dir/popup_state.json`, so it survives a server reboot.
#
# The JS half is `PopupController` (assets/popup.js): one instance per window,
# constructed with its DOM nodes + observables — every inbound action
# (detach / restore / dock / undock / reveal-file-pane / chat navigation)
# arrives through an Observable on the `PlotPane` handle (plotpane.jl).

const PopupLib = Bonito.ES6Module(joinpath(@__DIR__, "..", "assets", "popup.js"))

# ── Per-chat persisted geometry ──────────────────────────────────────────────

popup_state_file(chat_dir::AbstractString) = joinpath(String(chat_dir), "popup_state.json")

const POPUP_DEFAULTS = (x = 120, y = 80, width = 720, height = 480)

function load_popup_state(chat_dir::AbstractString)
    f = popup_state_file(chat_dir)
    isfile(f) || return nothing
    try
        return JSON.parsefile(f)
    catch e
        @debug "load_popup_state: parse failed" path=f exception=e
        return nothing
    end
end

function save_popup_state(chat_dir::AbstractString;
                          x::Integer, y::Integer,
                          width::Integer, height::Integer,
                          location::AbstractString = "floating",
                          chat_width::Integer = 0)
    f = popup_state_file(chat_dir)
    mkpath(dirname(f))
    tmp = f * ".tmp"
    try
        open(tmp, "w") do io
            JSON.print(io, Dict("x"        => Int(x),
                                "y"        => Int(y),
                                "width"    => Int(width),
                                "height"   => Int(height),
                                "location" => String(location),
                                # 0 ⇒ no per-chat override, fall back to the CSS
                                # default; the divider position is per chat.
                                "chat_width" => Int(chat_width)), 2)
        end
        mv(tmp, f; force=true)
    catch e
        @debug "save_popup_state: write failed" path=f exception=e
        # Best-effort temp cleanup; a failure to remove a stray temp file is
        # itself only worth a debug line, never a silent swallow (T20).
        try
            rm(tmp; force=true)
        catch rm_e
            @debug "save_popup_state: temp cleanup failed" path=tmp exception=rm_e
        end
    end
    return nothing
end

# ── Tool-body wrapper helper ─────────────────────────────────────────────────
# Wrap a `RemoteAppPlaceholder` (or any rendered app body) in the slot/embed
# pair the JS controller needs, plus an "↗ Detach" affordance + a placeholder
# string that takes over while the embed is detached.
#
#   <div class="bt-embed-frame">
#     <div class="bt-embed-controls">
#       <span class="bt-detach-btn">↗ Detach</span>
#       <span class="bt-detach-placeholder">In popup window — close it to bring this back</span>
#     </div>
#     <div class="bt-slot"  id="bt-slot-<tool_id>">
#       <div class="bt-embed" id="bt-embed-<tool_id>"> [rendered body] </div>
#     </div>
#   </div>
"""
    wrap_for_detach(tool_id, body) -> Node

Wrap a tool body so the JS controller can re-parent it into the chat-global
popup window (Detach button) and back (popup close → restore-to-slot).
"""
function wrap_for_detach(tool_id::AbstractString, body)
    tid = String(tool_id)
    # Detach now lives on the ⤢ button in the tool header (rendered for
    # bonito_app tools by bonitoagents.js; routed comm → DetachAppCommand →
    # `pane.detach_app`). Here we only keep the slot/embed structure the
    # controller moves between surfaces, plus a placeholder that takes over
    # the inline spot while it's detached.
    placeholder = DOM.span("In floating window — close it to bring this back";
                          class = "bt-detach-placeholder")
    DOM.div(
        DOM.div(placeholder; class = "bt-embed-controls"),
        DOM.div(
            DOM.div(body; id = "bt-embed-$(tid)", class = "bt-embed");
            id = "bt-slot-$(tid)", class = "bt-slot");
        class = "bt-embed-frame")
end

# ── unified_app integration ──────────────────────────────────────────────────

"""
    install_popup!(session, state, current_view) ->
        (FloatingWindow, plotpane_dom, onload_js::Bonito.JSCode, pane::PlotPane)

Build the chat-global popup + plotpane surfaces, with per-chat persistence
(geometry **and** last-used location: "floating" vs "docked") to
`state.chat_models[pid].chat_dir/popup_state.json`.

The returned `PlotPane` is the Julia-side handle: pass it down to the chat
views (ChatPaneRef sets it on each per-session ChatModel) so chat code can
`open_file!(pane, model, path)` and route detach/restore requests. The
`onload_js` constructs the `PopupController` (assets/popup.js) once the
shell is mounted; the controller subscribes to the pane's observables —
nothing here ever talks to a window-global.

Plus an unobtrusive **drag-to-dock**: drag the popup's title bar over the
plotpane drop zone and release → docks. (No special drop handler on the
widget; the controller listens to pointer events at the document level,
runs in parallel with FloatingWindow's own drag logic.)
"""
function install_popup!(session::Bonito.Session,
                         state::ServerState,
                         current_view::Observable{String})
    x         = Observable(POPUP_DEFAULTS.x)
    y         = Observable(POPUP_DEFAULTS.y)
    width     = Observable(POPUP_DEFAULTS.width)
    height    = Observable(POPUP_DEFAULTS.height)
    visible   = Observable(false)                # floating popup
    plotpane_v= Observable(false)                # plotpane column
    location  = Observable("floating")           # "floating" or "docked"
    close_t   = Observable(false)
    chat_width = Observable(0)                    # per-chat chat-column width (0 ⇒ CSS default)
    title     = Observable("Detached app")

    pane = PlotPane()
    # ── Tab-state folding ────────────────────────────────────────────────
    # Every UI event funnels into ONE atomic `tabs` update (items + active
    # change together — see plotpane.jl).
    on(session, pane.tab_click) do id
        isempty(id) && return
        pane.tabs[] = activate_tab(pane.tabs[], id)
    end
    on(session, pane.tab_close) do id
        isempty(id) && return
        if id == APP_TAB_ID
            # The app tab closes by restoring the embed to its bubble; the
            # controller then reports `app_docked("")`, which drops the tab.
            pane.restore_app[] = true
        else
            delete!(pane.editors, id)
            pane.tabs[] = remove_tab(pane.tabs[], id)
        end
    end
    # The JS controller reports app-embed docking; fold it in as a tab.
    on(session, pane.app_docked) do tid
        st = pane.tabs[]
        if isempty(tid)
            any(t -> t.id == APP_TAB_ID, st.items) &&
                (pane.tabs[] = remove_tab(st, APP_TAB_ID))
        else
            pane.tabs[] = upsert_tab(st,
                PaneTab(APP_TAB_ID, "App · " * tid[1:min(8, end)], :app))
        end
    end
    # JS-safe derivation the controller subscribes to: the active tab id
    # drives content visibility + the pane column's own visibility.
    active_tab = map(st -> st.active, session, pane.tabs)

    loading = Ref(false)

    # current_view → chat_dir → load saved state.
    on(current_view) do pid
        isempty(pid) && return
        # `get` not `haskey`+index (T19): the model can be evicted (chat closed,
        # worker dropped) between the check and the index, KeyError-ing out of the
        # notify chain. A nil model just means "no popup state to load".
        model = get(state.chat_models, pid, nothing)
        model === nothing && return
        chat_dir = String(model.chat_dir)
        st = load_popup_state(chat_dir)
        st === nothing && return
        loading[] = true
        try
            haskey(st, "x")        && (x[]        = Int(st["x"]))
            haskey(st, "y")        && (y[]        = Int(st["y"]))
            haskey(st, "width")    && (width[]    = Int(st["width"]))
            haskey(st, "height")   && (height[]   = Int(st["height"]))
            haskey(st, "location") && (location[] = String(st["location"]))
            # Always assign chat_width (default 0) so navigating from a chat with
            # a custom divider position to one without resets to the CSS default.
            chat_width[] = haskey(st, "chat_width") ? Int(st["chat_width"]) : 0
        finally
            loading[] = false
        end
    end

    saver = function()
        loading[] && return
        pid = current_view[]
        isempty(pid) && return
        # `get` not `haskey`+index (T19) — same eviction race as the loader above.
        model = get(state.chat_models, pid, nothing)
        model === nothing && return
        chat_dir = String(model.chat_dir)
        save_popup_state(chat_dir;
            x = x[], y = y[], width = width[], height = height[],
            location = location[], chat_width = chat_width[])
    end
    on(_ -> saver(), x);        on(_ -> saver(), y)
    on(_ -> saver(), width);    on(_ -> saver(), height)
    on(_ -> saver(), location); on(_ -> saver(), chat_width)

    # Apply the per-chat chat-column width to `.bt-main` (parent session owns the
    # column, so interpolating chat_width here is safe). 0 ⇒ clear the override so
    # the CSS default (820px, clamped) applies; the plotpane fills the rest.
    Bonito.onjs(session, chat_width, js"""(w) => {
        const main = document.querySelector('.bt-main');
        if (!main) return;
        if (w && w > 0) main.style.setProperty('--bt-chat-width', w + 'px');
        else            main.style.removeProperty('--bt-chat-width');
    }""")

    # Navigation (`current_view`) drives the per-chat surface swap inside the
    # controller (`setChat` subscription): it parks the previous chat's
    # detached embed back into its kept-alive bubble, then re-detaches the
    # new chat's app at its remembered location. x/y/width/height are
    # deliberately left to the geometry loader above, so a returning chat
    # lands its popup exactly where it was dragged.

    # Mounts. The floating window keeps its single slot; the plotpane mount
    # is TABBED: the app host (where the controller moves `bt-embed-<id>`
    # subtrees) and one kept-alive wrapper per open file editor (KeyedList —
    # switching tabs preserves Monaco state). The controller toggles
    # `[data-tab-id]` visibility from the `active_tab` observable.
    popup_mount = DOM.div(""; id = "bt-popup-mount", class = "bt-popup-mount")
    app_host = DOM.div(""; id = "bt-plotpane-app",
        class = "bt-pp-tabcontent", dataTabId = APP_TAB_ID)
    file_items = map(session, pane.tabs) do st
        PaneTabContent[PaneTabContent(t.id, pane.editors[t.id])
                       for t in st.items
                       if t.kind === :file && haskey(pane.editors, t.id)]
    end
    plotpane_mount = DOM.div(
        app_host,
        Bonito.KeyedList(file_items; key = c -> c.id);
        id = "bt-plotpane-mount", class = "bt-plotpane-mount")

    fw = FloatingWindow(popup_mount;
        title = title, x = x, y = y, width = width, height = height,
        visible = visible, close_trigger = close_t)

    # Plotpane column: a stable shell + a VSCode-style tab bar (+ undock /
    # close chrome) + the mount. The whole column is hidden (CSS width:0)
    # when `plotpane_visible` is false. The tab bar is a small bounded
    # region — whole-bar re-render per tabs update is fine (AGENTS.md §5);
    # per-render click handlers live in the map's sub-session and are freed
    # on the next render.
    tab_bar = map(session, pane.tabs) do st
        DOM.div(
            (DOM.div(
                DOM.span(t.label; class = "bt-pp-tab-label"),
                DOM.span("×"; class = "bt-pp-tab-close", title = "Close",
                    onclick = js"event => { event.stopPropagation(); $(pane.tab_close).notify($(t.id)); }");
                class = t.id == st.active ? "bt-pp-tab bt-pp-tab-active" : "bt-pp-tab",
                onclick = js"event => $(pane.tab_click).notify($(t.id))")
             for t in st.items)...;
            class = "bt-pp-tabs")
    end
    undock_btn = DOM.span("⤡";
        class = "bt-pp-btn", title = "Pop out to floating window",
        onclick = js"event => { event.stopPropagation(); $(pane.undock_app).notify(true); }")
    pp_close_btn = DOM.span("×";
        class = "bt-pp-btn", title = "Close pane",
        onclick = js"event => { event.stopPropagation(); $(pane.restore_app).notify(true); }")
    # The resize handle is the first child so it sits at the left edge of the
    # column (the column is `position: relative` so the absolute handle anchors
    # to the pane, not the page). Drag wiring in `controller_js`.
    pp_resize = DOM.div(""; class = "bt-pp-resize",
        title = "Drag to resize · double-click to reset")
    plotpane = DOM.div(
        pp_resize,
        DOM.div(
            tab_bar,
            DOM.div(undock_btn, pp_close_btn; class = "bt-pp-controls");
            class = "bt-pp-header"),
        plotpane_mount;
        id    = "bt-plotpane-dropzone",
        # Class is toggled imperatively in `controller_js` (Bonito doesn't
        # live-bind `class = Observable` the way it does for `style`); start
        # without the `-visible` modifier so the column is collapsed at mount.
        class = "bt-plotpane")

    # Close (×) on the floating window: send embed back to its bubble.
    on(session, close_t) do v
        v || return
        close_t[] = false
        pane.restore_app[] = true
    end

    # Construct the PopupController (assets/popup.js) once the shell is in
    # the DOM. Everything it touches is handed over here — its own DOM nodes
    # and the observables it subscribes to. No window globals.
    controller_js = js"""
    (root) => $(PopupLib).then(mod => new mod.PopupController({
        popupMount:    $(popup_mount),
        paneMount:     $(plotpane_mount),
        appHost:       $(app_host),
        dropzone:      $(plotpane),
        vis:           $(visible),
        ppv:           $(plotpane_v),
        loc:           $(location),
        title:         $(title),
        chatWidth:     $(chat_width),
        currentView:   $(current_view),
        activeTab:     $(active_tab),
        detachApp:     $(pane.detach_app),
        restoreApp:    $(pane.restore_app),
        dockApp:       $(pane.dock_app),
        undockApp:     $(pane.undock_app),
        appDocked:     $(pane.app_docked),
    }))
    """

    return (fw, plotpane, controller_js, pane)
end

const PopupStyles = Bonito.Styles(
    Bonito.CSS(".bt-embed-frame",
        "display" => "flex", "flex-direction" => "column",
        "min-width" => "0"),
    Bonito.CSS(".bt-embed-controls",
        "display" => "flex", "align-items" => "center", "gap" => "10px",
        "padding" => "2px 0 6px"),
    # Detach lives on the tool header's ⤢ button now (see bonitoagents.js); the
    # in-frame controls row only carries the "detached" placeholder.
    Bonito.CSS(".bt-detach-placeholder",
        "color" => "var(--bt-text-muted)",
        "font-size" => "11px", "font-style" => "italic",
        "display" => "none"),
    # Toggled by the JS controller (sets data-detached on the .bt-slot when an
    # embed is in a surface); reveal the placeholder in the now-empty inline spot.
    Bonito.CSS(".bt-embed-frame:has(.bt-slot[data-detached]) .bt-detach-placeholder",
        "display" => "inline"),
    Bonito.CSS(".bt-popup-mount",
        "width" => "100%", "height" => "100%",
        "overflow" => "auto"),

    # ── Plotpane (right-side column dock target) ─────────────────────────────
    # Width transitions from 0 (hidden) → `--bt-pp-width` (visible). The column
    # sits as a flex child of `.bt-shell`, right of `.bt-main`, with its own
    # header (undock + close) above the mount slot. Width is user-resizable via
    # the left-edge drag handle (`.bt-pp-resize`) and persisted in localStorage,
    # so re-opening lands on the same width.
    # Plain px fallback only. The real default is computed (clamped to the
    # stage) in `applyPlotpaneVis` and written as explicit px on the element —
    # a complex min/max/% value here gets mangled to a zero basis by the `flex`
    # The plotpane is collapsed to 0 when hidden, and fills ALL remaining stage
    # width (flex:1) when visible — the chat column (sized by `--bt-chat-width`)
    # is the only other flex child, so the pane takes everything to its right
    # with no gap. The divider on its left edge resizes the CHAT, not the pane.
    Bonito.CSS(".bt-plotpane",
        "flex"        => "0 0 0",
        "width"       => "0",
        "min-width"   => "0",
        "overflow"    => "hidden",
        "position"    => "relative",
        "display"     => "flex", "flex-direction" => "column",
        "background"  => "var(--bt-surface)",
        "border-left" => "1px solid var(--bt-border)"),
    Bonito.CSS(".bt-plotpane.bt-plotpane-visible",
        "flex"  => "1 1 0",
        "width" => "auto"),
    # Drag handle on the left edge: thin column, full height, col-resize cursor.
    # Slightly visible on hover so the affordance is discoverable.
    Bonito.CSS(".bt-pp-resize",
        "position" => "absolute",
        "left" => "0", "top" => "0", "bottom" => "0",
        "width" => "6px",
        "cursor" => "col-resize",
        "user-select" => "none",
        "z-index" => "2",
        "transition" => "background 80ms"),
    Bonito.CSS(".bt-pp-resize:hover, .bt-plotpane.bt-pp-resizing .bt-pp-resize",
        "background" => "var(--bt-accent)"),
    Bonito.CSS(".bt-pp-header",
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "padding" => "6px 10px",
        "border-bottom" => "1px solid var(--bt-border)",
        "background" => "var(--bt-surface-2)",
        "flex-shrink" => "0",
        "font" => "13px/1.2 system-ui, -apple-system, sans-serif",
        "color" => "var(--bt-text)"),
    # VSCode-style tab bar: one tab per open file + the docked app.
    Bonito.CSS(".bt-pp-tabs",
        "flex" => "1 1 auto", "min-width" => "0",
        "display" => "flex", "align-items" => "stretch",
        "gap" => "2px", "overflow-x" => "auto"),
    Bonito.CSS(".bt-pp-tab",
        "display" => "flex", "align-items" => "center", "gap" => "6px",
        "padding" => "4px 8px",
        "font" => "12px/1.2 system-ui, -apple-system, sans-serif",
        "color" => "var(--bt-text-muted)",
        "border-radius" => "6px 6px 0 0",
        "border" => "1px solid transparent",
        "border-bottom" => "none",
        "cursor" => "pointer",
        "white-space" => "nowrap",
        "user-select" => "none"),
    Bonito.CSS(".bt-pp-tab:hover",
        "background" => "var(--bt-surface-2)"),
    Bonito.CSS(".bt-pp-tab-active",
        "background" => "var(--bt-surface)",
        "border-color" => "var(--bt-border)",
        "color" => "var(--bt-text)",
        "font-weight" => "600"),
    Bonito.CSS(".bt-pp-tab-close",
        "color" => "var(--bt-text-faint)",
        "padding" => "0 2px",
        "border-radius" => "4px"),
    Bonito.CSS(".bt-pp-tab-close:hover",
        "color" => "var(--bt-error)",
        "background" => "var(--bt-surface-2)"),
    Bonito.CSS(".bt-pp-tabcontent",
        "height" => "100%", "min-height" => "0",
        "display" => "flex", "flex-direction" => "column",
        "overflow" => "auto"),
    Bonito.CSS(".bt-pp-controls",
        "display" => "flex", "gap" => "2px", "flex-shrink" => "0"),
    Bonito.CSS(".bt-pp-btn",
        "cursor" => "pointer",
        "color" => "var(--bt-text-muted)",
        "padding" => "2px 8px", "border-radius" => "var(--bt-radius-sm)",
        "user-select" => "none",
        "font" => "14px/1 system-ui, sans-serif",
        "font-weight" => "500"),
    Bonito.CSS(".bt-pp-btn:hover",
        "background" => "var(--bt-bg)", "color" => "var(--bt-text)"),
    Bonito.CSS(".bt-plotpane-mount",
        "flex" => "1 1 auto", "overflow" => "auto"),
    # Drag-to-dock highlight overlay: a fixed-position rectangle covering the
    # WHOLE area right of the chat (where the plotpane fills), shown while the
    # floating window is being dragged. pointer-events:none so it never blocks
    # the float's own drag. Brightens when the pointer is over it (will dock).
    Bonito.CSS(".bt-drop-overlay",
        "position" => "fixed",
        "z-index" => "50",
        "pointer-events" => "none",
        "box-sizing" => "border-box",
        "background" => "rgba(59,130,246,0.06)",
        "border" => "2px dashed var(--bt-accent)",
        "border-radius" => "8px",
        "transition" => "background 80ms"),
    Bonito.CSS(".bt-drop-overlay.bt-drop-active",
        "background" => "rgba(59,130,246,0.16)"),
)
