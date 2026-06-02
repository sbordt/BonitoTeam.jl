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
                          location::AbstractString = "floating")
    f = popup_state_file(chat_dir)
    mkpath(dirname(f))
    tmp = f * ".tmp"
    try
        open(tmp, "w") do io
            JSON.print(io, Dict("x"        => Int(x),
                                "y"        => Int(y),
                                "width"    => Int(width),
                                "height"   => Int(height),
                                "location" => String(location)), 2)
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
    detach_btn = DOM.span("↗ Detach";
        class   = "bt-detach-btn",
        title   = "Move this app to the floating window",
        onclick = js"""event => {
            event.stopPropagation();
            window._btPopup && window._btPopup.detach($(tid));
        }""")
    placeholder = DOM.span("In popup window — close it to bring this back";
                          class = "bt-detach-placeholder")
    DOM.div(
        DOM.div(detach_btn, placeholder; class = "bt-embed-controls"),
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
    plotpane_close_t = Observable(false)
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
            location = location[])
    end
    on(_ -> saver(), x);        on(_ -> saver(), y)
    on(_ -> saver(), width);    on(_ -> saver(), height)
    on(_ -> saver(), location)

    # The floating popup + plotpane are chat-global affordances — they belong
    # to a chat's detached `bt_show_app` embed, not to the dashboard. Hide both
    # whenever we navigate to home so a leftover embed from chat A doesn't
    # linger on top of the project list. We deliberately DO NOT touch x/y/
    # width/height here, so returning to the chat lands the popup at the
    # exact position the user last dragged it to.
    on(current_view) do pid
        if isempty(pid)
            visible[]    = false
            plotpane_v[] = false
        end
    end

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

        // ── Resize handle ────────────────────────────────────────────────────
        // The plotpane width is a CSS var (`--bt-pp-width`) on the pane element,
        // so the visible/transition rules in CSS just follow whatever we set.
        // Min 280 px keeps the pane usable; we also leave at least MIN_CHAT_PX
        // for the chat so dragging can't squeeze it to nothing.
        const PP_MIN = 280;
        const MIN_CHAT_PX = 480;
        const PP_KEY = 'bt-pp-width';
        const pp = document.getElementById('bt-plotpane-dropzone');
        if (pp) {
            // Restore the last persisted width (if any).
            const saved = +localStorage.getItem(PP_KEY);
            if (saved >= PP_MIN) pp.style.setProperty('--bt-pp-width', saved + 'px');

            const handle = pp.querySelector('.bt-pp-resize');
            if (handle) {
                let startX = 0, startW = 0, shellW = 0;
                const onMove = (e) => {
                    // Pane grows when the cursor moves LEFT (handle is on the
                    // pane's left edge), shrinks when it moves right.
                    const proposed = startW - (e.clientX - startX);
                    const max = Math.max(PP_MIN, shellW - MIN_CHAT_PX);
                    const w = Math.max(PP_MIN, Math.min(max, proposed));
                    pp.style.setProperty('--bt-pp-width', w + 'px');
                };
                const onUp = () => {
                    window.removeEventListener('pointermove', onMove);
                    window.removeEventListener('pointerup',   onUp);
                    pp.classList.remove('bt-pp-resizing');
                    const finalW = parseFloat(
                        getComputedStyle(pp).getPropertyValue('--bt-pp-width')) || 0;
                    if (finalW >= PP_MIN) localStorage.setItem(PP_KEY, Math.round(finalW));
                };
                handle.addEventListener('pointerdown', (e) => {
                    e.preventDefault();
                    const shell = document.querySelector('.bt-shell');
                    shellW = shell ? shell.clientWidth : window.innerWidth;
                    startX = e.clientX;
                    startW = pp.getBoundingClientRect().width;
                    pp.classList.add('bt-pp-resizing');
                    window.addEventListener('pointermove', onMove);
                    window.addEventListener('pointerup',   onUp);
                });
                // Double-click = reset to the CSS default (clears the override).
                handle.addEventListener('dblclick', (e) => {
                    e.preventDefault();
                    pp.style.removeProperty('--bt-pp-width');
                    localStorage.removeItem(PP_KEY);
                });
            }
        }

        window._btPopup = {
            _currentToolId: null,
            // Open the bubble's embed at whichever surface the chat last left
            // the container in. If something else is already detached, send it
            // back to its bubble first.
            detach(toolId) {
                if (this._currentToolId && this._currentToolId !== toolId) {
                    this.restore();
                }
                const embed = document.getElementById('bt-embed-' + toolId);
                if (!embed) {
                    console.warn('[btPopup] detach: no embed for', toolId);
                    return;
                }
                const targetId = locObs.value === 'docked' ? 'bt-plotpane-mount'
                                                           : 'bt-popup-mount';
                const mount = document.getElementById(targetId);
                if (!mount) return;
                Bonito.move_dom_node(embed, mount, null);
                const slot = document.getElementById('bt-slot-' + toolId);
                if (slot) slot.setAttribute('data-detached', '1');
                this._currentToolId = toolId;
                titleObs.notify('App · ' + toolId.slice(0, 8));
                showFor(locObs.value);
            },
            // Send the current embed back to its bubble; hide both surfaces.
            restore() {
                const toolId = this._currentToolId;
                if (!toolId) return;
                const embed = document.getElementById('bt-embed-' + toolId);
                const slot  = document.getElementById('bt-slot-'  + toolId);
                if (embed && slot) {
                    Bonito.move_dom_node(embed, slot, null);
                    slot.removeAttribute('data-detached');
                }
                this._currentToolId = null;
                visObs.notify(false);
                ppvObs.notify(false);
            },
            // floating → docked.
            dock() {
                const toolId = this._currentToolId;
                if (!toolId) return;
                const embed = document.getElementById('bt-embed-' + toolId);
                const mount = document.getElementById('bt-plotpane-mount');
                if (!embed || !mount) return;
                Bonito.move_dom_node(embed, mount, null);
                locObs.notify('docked');
                showFor('docked');
            },
            // docked → floating.
            undock() {
                const toolId = this._currentToolId;
                if (!toolId) return;
                const embed = document.getElementById('bt-embed-' + toolId);
                const mount = document.getElementById('bt-popup-mount');
                if (!embed || !mount) return;
                Bonito.move_dom_node(embed, mount, null);
                locObs.notify('floating');
                showFor('floating');
            },
        };

        // Drag-to-dock. Tracks pointer drags that begin on the popup's title
        // bar (but not its controls). On pointerdown we light up a slim drop
        // strip on the right (otherwise the plotpane is collapsed when empty
        // and there's nothing to drop onto); during move we highlight when
        // over it; on release we dock if released over it. Runs in parallel
        // with FloatingWindow's own drag — they don't conflict because each
        // owns independent listeners.
        document.addEventListener('pointerdown', (ev) => {
            const tb = ev.target.closest('.bn-fw-title');
            if (!tb || ev.target.closest('.bn-fw-controls')) return;
            // No-op when nothing is detached — drag-to-dock only makes sense
            // when there's an embed in the popup.
            if (!window._btPopup._currentToolId) return;
            const zone = document.getElementById('bt-plotpane-dropzone');
            if (!zone) return;
            zone.classList.add('bt-drop-ready');
            const overZone = (e2) => {
                const r = zone.getBoundingClientRect();
                if (r.width === 0) return false;
                return e2.clientX >= r.left && e2.clientX <= r.right &&
                       e2.clientY >= r.top  && e2.clientY <= r.bottom;
            };
            const onMove = (e2) => zone.classList.toggle('bt-drop-active', overZone(e2));
            const onUp = (e2) => {
                document.removeEventListener('pointermove', onMove);
                document.removeEventListener('pointerup',   onUp);
                const wasOver = overZone(e2);
                zone.classList.remove('bt-drop-ready');
                zone.classList.remove('bt-drop-active');
                if (wasOver) window._btPopup.dock();
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
    Bonito.CSS(".bt-detach-btn",
        "cursor" => "pointer",
        "color" => "var(--bt-accent)",
        "font-size" => "11px", "font-weight" => "500",
        "padding" => "2px 6px",
        "border-radius" => "var(--bt-radius-sm)",
        "user-select" => "none"),
    Bonito.CSS(".bt-detach-btn:hover",
        "background" => "var(--bt-surface-2)"),
    Bonito.CSS(".bt-detach-placeholder",
        "color" => "var(--bt-text-muted)",
        "font-size" => "11px", "font-style" => "italic",
        "display" => "none"),
    # Toggled by the JS controller (sets data-detached on the .bt-slot when an
    # embed is in the popup); the `:has()` selectors below flip the controls.
    Bonito.CSS(".bt-embed-frame:has(.bt-slot[data-detached]) .bt-detach-btn",
        "display" => "none"),
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
    # Adaptive default: takes up to half the shell (up to 720px) — gives wide
    # monitors a comfortably large pane instead of a fixed-cramped 480px — and
    # never goes below 360px on small screens. The user's drag override sets
    # `--bt-pp-width` on the pane element itself, winning over this default.
    Bonito.CSS(":root", "--bt-pp-width" => "min(720px, max(360px, 50%))"),
    Bonito.CSS(".bt-plotpane",
        "flex"        => "0 0 0",
        "width"       => "0",
        "overflow"    => "hidden",
        "position"    => "relative",
        "display"     => "flex", "flex-direction" => "column",
        "background"  => "var(--bt-surface)",
        "border-left" => "1px solid var(--bt-border)",
        "transition"  => "flex-basis 200ms ease, width 200ms ease"),
    Bonito.CSS(".bt-plotpane.bt-plotpane-visible",
        "flex"  => "0 0 var(--bt-pp-width)",
        "width" => "var(--bt-pp-width)"),
    # Disable the width transition while the user is actively dragging the
    # resize handle, otherwise every pointermove animates into place and the
    # pane lags the cursor.
    Bonito.CSS(".bt-plotpane.bt-pp-resizing",
        "transition" => "none"),
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
    # Drop strip — shown while the user is dragging the popup, so they have
    # something to drag onto even when the plotpane is empty/collapsed.
    Bonito.CSS(".bt-plotpane.bt-drop-ready",
        "flex"       => "0 0 56px",
        "width"      => "56px",
        "background" => "var(--bt-surface-2)",
        # Visible "drop here" hint via diagonal stripes.
        "background-image" =>
            "repeating-linear-gradient(135deg, transparent 0 8px, rgba(0,0,0,0.04) 8px 16px)"),
    # Drag-to-dock highlight: pointer is over the drop zone.
    Bonito.CSS(".bt-plotpane.bt-drop-active",
        "background-color" => "var(--bt-bg)",
        "outline" => "2px dashed var(--bt-accent)",
        "outline-offset" => "-6px"),
)
