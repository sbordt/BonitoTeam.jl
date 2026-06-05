# ── Chat-global popup window for `bt_show_app` ─────────────────────────────────
# A single floating "show-app target" per session that any `bt_show_app` bubble
# can detach into. The DOM node of the embed itself is moved (via Bonito's
# `move_dom_node`, which bypasses the delete-MutationObserver), so interactive
# state stays alive across moves. The popup geometry is persisted per chat to
# `chat_dir/popup_state.json`, so it survives a server reboot.
#
# JS controller: `window._btPopup.detach(toolId)` / `.restore()`. The bubble's
# Detach button is plain DOM with `onclick → window._btPopup.detach('<id>')`,
# decoupling the button from the per-session Observable wiring.

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
        try; rm(tmp; force=true); catch; end
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
    # bonito_app tools by bonitoteam.js, calling window._btPopup.detach). Here we
    # only keep the slot/embed structure the controller moves between surfaces,
    # plus a placeholder that takes over the inline spot while it's detached.
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
        (FloatingWindow, plotpane_dom, onload_js::Bonito.JSCode)

Build the chat-global popup + plotpane surfaces and the `window._btPopup`
controller JS, with per-chat persistence (geometry **and** last-used location:
"floating" vs "docked") to `state.chat_models[pid].chat_dir/popup_state.json`.

The controller exposes:
  - `_btPopup.detach(toolId)` — open the bubble's app at whichever surface the
    chat last left it in (floating popup, or the docked plotpane).
  - `_btPopup.restore()` — send the current embed back to its bubble; both
    surfaces hide.
  - `_btPopup.dock()` / `.undock()` — toggle the current embed between the
    floating popup and the plotpane.
Plus an unobtrusive **drag-to-dock**: drag the popup's title bar over the
plotpane drop zone and release → docks. (No special drop handler on the
widget; the JS listens to pointer events at the document level, runs in
parallel with FloatingWindow's own drag logic.)
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

    loading = Ref(false)

    # current_view → chat_dir → load saved state.
    on(current_view) do pid
        isempty(pid) && return
        haskey(state.chat_models, pid) || return
        chat_dir = String(state.chat_models[pid].chat_dir)
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
        haskey(state.chat_models, pid) || return
        chat_dir = String(state.chat_models[pid].chat_dir)
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

    # Navigation drives the per-chat surface swap: `setChat` parks the previous
    # chat's detached embed back into its (kept-alive) bubble, hides both
    # surfaces, then re-detaches the new chat's app at its remembered location.
    # This is what makes the floating-window / plotpane state resident per chat
    # (home → both surfaces simply hide, since "" has no detached app). It runs
    # in the parent session that owns the `window._btPopup` controller, so
    # interpolating `current_view` here is safe (never a KeyedList child).
    # x/y/width/height are deliberately left to the geometry loader above, so a
    # returning chat lands its popup exactly where it was dragged.
    Bonito.onjs(session, current_view,
        js"(pid) => window._btPopup && window._btPopup.setChat(pid)")

    # Two mount slots, one per surface. The controller moves the embed
    # `bt-embed-<tool_id>` between them.
    popup_mount = DOM.div(""; id = "bt-popup-mount", class = "bt-popup-mount")
    plotpane_mount = DOM.div(""; id = "bt-plotpane-mount", class = "bt-plotpane-mount")

    fw = FloatingWindow(popup_mount;
        title = title, x = x, y = y, width = width, height = height,
        visible = visible, close_trigger = close_t)

    # Plotpane column: a stable shell + header (undock + close) + the mount.
    # The whole column is hidden (CSS width:0) when `plotpane_visible` is false.
    pp_title = map(t -> t, title)
    undock_btn = DOM.span("⤡";
        class = "bt-pp-btn", title = "Pop out to floating window",
        onclick = js"event => { event.stopPropagation(); window._btPopup && window._btPopup.undock(); }")
    pp_close_btn = DOM.span("×";
        class = "bt-pp-btn", title = "Close",
        onclick = js"event => { event.stopPropagation(); window._btPopup && window._btPopup.restore(); }")
    # The resize handle is the first child so it sits at the left edge of the
    # column (the column is `position: relative` so the absolute handle anchors
    # to the pane, not the page). Drag wiring in `controller_js`.
    pp_resize = DOM.div(""; class = "bt-pp-resize",
        title = "Drag to resize · double-click to reset")
    plotpane = DOM.div(
        pp_resize,
        DOM.div(
            DOM.span(pp_title; class = "bt-pp-title"),
            DOM.div(undock_btn, pp_close_btn; class = "bt-pp-controls");
            class = "bt-pp-header"),
        plotpane_mount;
        id    = "bt-plotpane-dropzone",
        # Class is toggled imperatively in `controller_js` (Bonito doesn't
        # live-bind `class = Observable` the way it does for `style`); start
        # without the `-visible` modifier so the column is collapsed at mount.
        class = "bt-plotpane")

    # Close (×) on the floating window: send embed back to its bubble.
    on(close_t) do v
        v || return
        close_t[] = false
        try
            Bonito.evaljs(session, js"""window._btPopup && window._btPopup.restore && window._btPopup.restore();""")
        catch e
            @debug "popup close: evaljs failed" exception = e
        end
    end

    controller_js = js"""
    (root) => {
        const visObs   = $(visible);
        const ppvObs   = $(plotpane_v);
        const locObs   = $(location);
        const titleObs = $(title);

        const showFor = (location) => {
            if (location === 'docked') {
                ppvObs.notify(true);  visObs.notify(false);
            } else {
                visObs.notify(true);  ppvObs.notify(false);
            }
        };

        // Imperative class swap for the plotpane column (Bonito doesn't bind
        // `class = Observable` live the way it bridges `style.display`).
        const applyPlotpaneVis = () => {
            const z = document.getElementById('bt-plotpane-dropzone');
            if (z) z.classList.toggle('bt-plotpane-visible', ppvObs.value);
        };
        ppvObs.on(applyPlotpaneVis);
        applyPlotpaneVis();

        // ── Divider: resizes the CHAT column ─────────────────────────────────
        // The plotpane (flex:1) fills whatever the chat leaves, so the handle on
        // its left edge sizes `--bt-chat-width` on `.bt-main`. Drag right → wider
        // chat (narrower pane); drag left → narrower chat. Clamped to the chat's
        // readable range, always leaving at least PANE_MIN for the pane.
        const CHAT_MIN = 480, CHAT_MAX = 1400, PANE_MIN = 320;
        const chatWidthObs = $(chat_width);   // per-chat divider width (persisted)
        const pp = document.getElementById('bt-plotpane-dropzone');
        const main = document.querySelector('.bt-main');
        const handle = pp ? pp.querySelector('.bt-pp-resize') : null;
        if (main && handle) {
            let startX = 0, startW = 0, stageW = 0;
            const clampW = (w) => Math.max(CHAT_MIN,
                Math.min(Math.min(CHAT_MAX, stageW - PANE_MIN), w));
            const onMove = (e) => {
                main.style.setProperty('--bt-chat-width',
                    clampW(startW + (e.clientX - startX)) + 'px');
            };
            const onUp = () => {
                window.removeEventListener('pointermove', onMove);
                window.removeEventListener('pointerup',   onUp);
                pp && pp.classList.remove('bt-pp-resizing');
                const finalW = Math.round(main.getBoundingClientRect().width);
                if (finalW >= CHAT_MIN) chatWidthObs.notify(finalW);   // → Julia saver
            };
            handle.addEventListener('pointerdown', (e) => {
                e.preventDefault();
                const stage = document.querySelector('.bt-stage');
                stageW = stage ? stage.clientWidth : window.innerWidth;
                startX = e.clientX;
                startW = main.getBoundingClientRect().width;
                pp && pp.classList.add('bt-pp-resizing');
                window.addEventListener('pointermove', onMove);
                window.addEventListener('pointerup',   onUp);
            });
            // Double-click = reset to the default chat width.
            handle.addEventListener('dblclick', (e) => {
                e.preventDefault();
                main.style.removeProperty('--bt-chat-width');
                chatWidthObs.notify(0);
            });
        }

        // Per-chat detached state. Each chat (pid) independently remembers which
        // of its bubble embeds is detached and where (floating | docked). The
        // surfaces (floating window + plotpane) are SHARED chrome — only the
        // active chat's embed is ever in them; the others are parked back in
        // their own (kept-alive) bubbles. That's what makes detach/dock state
        // "resident per chat": navigating swaps which embed occupies the surface.
        window._btPopup = {
            activePid: '',
            byPid: {},                     // pid -> { toolId, location }
            current() { return this.byPid[this.activePid] || null; },
            _toSurface(toolId, location) {
                const embed = document.getElementById('bt-embed-' + toolId);
                const mount = document.getElementById(
                    location === 'docked' ? 'bt-plotpane-mount' : 'bt-popup-mount');
                if (!embed || !mount) return false;
                Bonito.move_dom_node(embed, mount, null);
                const slot = document.getElementById('bt-slot-' + toolId);
                if (slot) slot.setAttribute('data-detached', '1');
                return true;
            },
            _toBubble(toolId) {
                const embed = document.getElementById('bt-embed-' + toolId);
                const slot  = document.getElementById('bt-slot-'  + toolId);
                if (embed && slot) {
                    Bonito.move_dom_node(embed, slot, null);
                    slot.removeAttribute('data-detached');
                }
            },
            // Open the active chat's bubble embed at its last-used surface. If a
            // different app in THIS chat was detached, send it back first.
            detach(toolId) {
                const pid = this.activePid, prev = this.byPid[pid];
                if (prev && prev.toolId !== toolId) this._toBubble(prev.toolId);
                const location = (prev && prev.location) || locObs.value || 'floating';
                if (!this._toSurface(toolId, location)) {
                    console.warn('[btPopup] detach: no embed for', toolId); return;
                }
                this.byPid[pid] = { toolId, location };
                locObs.notify(location);
                titleObs.notify('App · ' + toolId.slice(0, 8));
                showFor(location);
            },
            // Send the active chat's embed back to its bubble; hide both surfaces.
            restore() {
                const rec = this.current();
                if (rec) { this._toBubble(rec.toolId); delete this.byPid[this.activePid]; }
                visObs.notify(false);
                ppvObs.notify(false);
            },
            // floating → docked.
            dock() {
                const rec = this.current(); if (!rec) return;
                if (!this._toSurface(rec.toolId, 'docked')) return;
                rec.location = 'docked'; locObs.notify('docked'); showFor('docked');
            },
            // docked → floating.
            undock() {
                const rec = this.current(); if (!rec) return;
                if (!this._toSurface(rec.toolId, 'floating')) return;
                rec.location = 'floating'; locObs.notify('floating'); showFor('floating');
            },
            // Navigation hook (driven by current_view). Park the previous chat's
            // detached embed back into its kept-alive bubble and hide the
            // surfaces, then re-detach the new chat's app if it had one — so each
            // chat's floating/docked app reappears exactly where it was left.
            setChat(pid) {
                pid = pid || '';
                if (pid === this.activePid) return;
                const old = this.byPid[this.activePid];
                if (old) this._toBubble(old.toolId);
                visObs.notify(false);
                ppvObs.notify(false);
                this.activePid = pid;
                const rec = this.byPid[pid];
                if (rec && this._toSurface(rec.toolId, rec.location)) {
                    locObs.notify(rec.location);
                    titleObs.notify('App · ' + rec.toolId.slice(0, 8));
                    showFor(rec.location);
                }
            },
        };

        // Drag-to-dock. Dragging the floating window's title bar over the whole
        // area to the RIGHT of the chat (the region the plotpane fills) docks it.
        // The ENTIRE drop region highlights — not a thin strip. A fixed-position
        // overlay marks it (pointer-events:none so it never interferes with the
        // FloatingWindow's own drag, which runs in parallel on its own listeners).
        document.addEventListener('pointerdown', (ev) => {
            const tb = ev.target.closest('.bn-fw-title');
            if (!tb || ev.target.closest('.bn-fw-controls')) return;
            if (!window._btPopup.current()) return;     // nothing detached → no-op
            const main  = document.querySelector('.bt-main');
            const stage = document.querySelector('.bt-stage');
            if (!main || !stage) return;
            const mr = main.getBoundingClientRect(), sr = stage.getBoundingClientRect();
            const left = mr.right, right = sr.right;
            if (right - left < 40) return;              // no room to dock into
            const ov = document.createElement('div');
            ov.className = 'bt-drop-overlay';
            ov.style.left = left + 'px';  ov.style.top = sr.top + 'px';
            ov.style.width = (right - left) + 'px';  ov.style.height = sr.height + 'px';
            document.body.appendChild(ov);
            const inZone = (e2) => e2.clientX >= left && e2.clientX <= right &&
                                   e2.clientY >= sr.top && e2.clientY <= sr.bottom;
            const onMove = (e2) => ov.classList.toggle('bt-drop-active', inZone(e2));
            const onUp = (e2) => {
                document.removeEventListener('pointermove', onMove);
                document.removeEventListener('pointerup',   onUp);
                const over = inZone(e2);
                ov.remove();
                if (over) window._btPopup.dock();
            };
            document.addEventListener('pointermove', onMove);
            document.addEventListener('pointerup',   onUp);
        });
    }
    """

    return (fw, plotpane, controller_js)
end

const PopupStyles = Bonito.Styles(
    Bonito.CSS(".bt-embed-frame",
        "display" => "flex", "flex-direction" => "column",
        "min-width" => "0"),
    Bonito.CSS(".bt-embed-controls",
        "display" => "flex", "align-items" => "center", "gap" => "10px",
        "padding" => "2px 0 6px"),
    # Detach lives on the tool header's ⤢ button now (see bonitoteam.js); the
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
    Bonito.CSS(".bt-pp-title",
        "flex" => "1 1 auto", "min-width" => "0",
        "overflow" => "hidden", "text-overflow" => "ellipsis",
        "white-space" => "nowrap", "font-weight" => "600"),
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
