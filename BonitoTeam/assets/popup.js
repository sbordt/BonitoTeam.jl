// Popup / plotpane controller — the JS half of the PlotPane widget
// (src/plotpane.jl owns the Julia half, src/popup.jl builds the DOM).
//
// One instance per window, constructed by install_popup!'s onload with its
// DOM nodes and observables as arguments. Everything the page needs from it
// arrives through those observables (detach/restore/dock/undock requests,
// the current chat pid, the active tab) — there is no window.* API surface
// and no getElementById of foreign components. The only ID-based lookups are
// `bt-embed-<toolId>` / `bt-slot-<toolId>`: that naming is the embed-identity
// contract that lets `Bonito.move_dom_node` find a chat bubble's live app
// subtree across chat re-renders.
//
// The plotpane is TABBED (Julia owns the tab state): the controller's jobs
// are (a) moving app embeds between surfaces, (b) reporting docking through
// `appDocked` so Julia folds it into the tab state, and (c) applying the
// `activeTab` observable — content visibility + the pane column's own
// visibility derive from it.

export class PopupController {
    constructor({
        popupMount,     // mount inside the floating window
        paneMount,      // the tabbed plotpane mount (visibility root)
        appHost,        // the app tab's content host inside paneMount
        dropzone,       // the .bt-plotpane column element
        vis,            // Observable{Bool}: floating window visible
        ppv,            // Observable{Bool}: plotpane column visible
        loc,            // Observable{String}: last-used surface ("floating"|"docked")
        title,          // Observable{String}: floating-window title
        chatWidth,      // Observable{Int}: per-chat divider width (persisted)
        currentView,    // Observable{String}: active chat pid (navigation)
        activeTab,      // Observable{String}: active tab id ("" ⇒ pane empty)
        detachApp,      // Observable{String} pulse: tool_id to detach
        restoreApp,     // Observable{Bool} pulse: embed back to bubble
        dockApp,        // Observable{Bool} pulse: floating → docked
        undockApp,      // Observable{Bool} pulse: docked → floating
        appDocked,      // Observable{String} JS→Julia: docked tool_id or ""
    }) {
        this.popupMount = popupMount;
        this.paneMount = paneMount;
        this.appHost = appHost;
        this.dropzone = dropzone;
        this.vis = vis;
        this.ppv = ppv;
        this.loc = loc;
        this.title = title;
        this.appDocked = appDocked;

        // Per-chat detached state. Each chat (pid) independently remembers
        // which of its bubble embeds is detached and where (floating |
        // docked). The surfaces are SHARED chrome — only the active chat's
        // embed is ever in them; the others are parked back in their own
        // (kept-alive) bubbles.
        this.activePid = '';
        this.byPid = {};   // pid -> { toolId, location }

        // ── Observable subscriptions: the controller's entire inbound API ──
        ppv.on(() => this.applyPlotpaneVis());
        this.applyPlotpaneVis();
        activeTab.on((id) => this.applyActiveTab(id));
        this.applyActiveTab(activeTab.value || '');
        currentView.on((pid) => this.setChat(pid));
        detachApp.on((toolId) => { if (toolId) this.detach(toolId); });
        restoreApp.on((v) => { if (v) this.restore(); });
        dockApp.on((v) => { if (v) this.dock(); });
        undockApp.on((v) => { if (v) this.undock(); });

        this.setupDivider(chatWidth);
        this.setupDragToDock();
    }

    current() { return this.byPid[this.activePid] || null; }

    // Imperative class swap for the plotpane column (Bonito doesn't bind
    // `class = Observable` live the way it bridges `style.display`).
    applyPlotpaneVis() {
        this.dropzone.classList.toggle('bt-plotpane-visible', this.ppv.value);
    }

    // The active tab drives BOTH the per-tab content visibility and the
    // pane column's visibility: some active tab ⇒ column shown, none ⇒
    // collapsed. The id is also stamped on the mount so a KeyedList-added
    // file wrapper (mounting AFTER this ran) can self-init its display.
    applyActiveTab(id) {
        this.paneMount.dataset.activeTab = id || '';
        this.paneMount.querySelectorAll('[data-tab-id]').forEach((el) => {
            el.style.display = (el.dataset.tabId === id) ? '' : 'none';
        });
        this.ppv.notify(!!id);
    }

    toSurface(toolId, location) {
        const embed = document.getElementById('bt-embed-' + toolId);
        const mount = location === 'docked' ? this.appHost : this.popupMount;
        if (!embed || !mount) return false;
        Bonito.move_dom_node(embed, mount, null);
        const slot = document.getElementById('bt-slot-' + toolId);
        if (slot) slot.setAttribute('data-detached', '1');
        return true;
    }

    toBubble(toolId) {
        const embed = document.getElementById('bt-embed-' + toolId);
        const slot  = document.getElementById('bt-slot-'  + toolId);
        if (embed && slot) {
            Bonito.move_dom_node(embed, slot, null);
            slot.removeAttribute('data-detached');
        }
    }

    // Open the active chat's bubble embed at its last-used surface. If a
    // different app in THIS chat was detached, send it back first.
    detach(toolId) {
        const pid = this.activePid, prev = this.byPid[pid];
        if (prev && prev.toolId !== toolId) this.toBubble(prev.toolId);
        const location = (prev && prev.location) || this.loc.value || 'floating';
        if (!this.toSurface(toolId, location)) {
            console.warn('[PopupController] detach: no embed for', toolId);
            return;
        }
        this.byPid[pid] = { toolId, location };
        this.loc.notify(location);
        this.title.notify('App · ' + toolId.slice(0, 8));
        if (location === 'docked') {
            this.vis.notify(false);
            this.appDocked.notify(toolId);   // → Julia adds + activates the app tab
        } else {
            this.vis.notify(true);
            this.appDocked.notify('');
        }
    }

    // Send the active chat's embed back to its bubble; the floating window
    // hides; the pane column follows the tab state (a remaining file tab
    // keeps it open).
    restore() {
        const rec = this.current();
        if (rec) { this.toBubble(rec.toolId); delete this.byPid[this.activePid]; }
        this.vis.notify(false);
        this.appDocked.notify('');
    }

    dock() {
        const rec = this.current(); if (!rec) return;
        if (!this.toSurface(rec.toolId, 'docked')) return;
        rec.location = 'docked';
        this.loc.notify('docked');
        this.vis.notify(false);
        this.appDocked.notify(rec.toolId);
    }

    undock() {
        const rec = this.current(); if (!rec) return;
        if (!this.toSurface(rec.toolId, 'floating')) return;
        rec.location = 'floating';
        this.loc.notify('floating');
        this.vis.notify(true);
        this.appDocked.notify('');
    }

    // Navigation hook. Park the previous chat's detached embed back into its
    // kept-alive bubble, then re-detach the new chat's app if it had one —
    // each chat's floating/docked app reappears exactly where it was left.
    setChat(pid) {
        pid = pid || '';
        if (pid === this.activePid) return;
        const old = this.byPid[this.activePid];
        if (old) this.toBubble(old.toolId);
        this.vis.notify(false);
        this.appDocked.notify('');
        this.activePid = pid;
        const rec = this.byPid[pid];
        if (rec && this.toSurface(rec.toolId, rec.location)) {
            this.loc.notify(rec.location);
            this.title.notify('App · ' + rec.toolId.slice(0, 8));
            if (rec.location === 'docked') {
                this.appDocked.notify(rec.toolId);
            } else {
                this.vis.notify(true);
            }
        }
    }

    // ── Divider: resizes the CHAT column ─────────────────────────────────
    // The plotpane (flex:1) fills whatever the chat leaves, so the handle on
    // its left edge sizes `--bt-chat-width` on `.bt-main`. Layout ancestors
    // are reached relative to our own dropzone node — no global IDs.
    setupDivider(chatWidth) {
        const CHAT_MIN = 480, CHAT_MAX = 1400, PANE_MIN = 320;
        const handle = this.dropzone.querySelector('.bt-pp-resize');
        const stage  = this.dropzone.closest('.bt-stage');
        const main   = stage ? stage.querySelector('.bt-main') : null;
        if (!handle || !stage || !main) return;
        handle.addEventListener('pointerdown', (e) => {
            e.preventDefault();
            const stageW = stage.clientWidth || window.innerWidth;
            const startX = e.clientX;
            const startW = main.getBoundingClientRect().width;
            const clampW = (w) => Math.max(CHAT_MIN,
                Math.min(Math.min(CHAT_MAX, stageW - PANE_MIN), w));
            this.dropzone.classList.add('bt-pp-resizing');
            // Gesture-scoped listeners (see Bonito AGENTS.md): attached for
            // this drag only, removed together via the AbortController.
            const drag = new AbortController();
            const { signal } = drag;
            window.addEventListener('pointermove', (ev) => {
                main.style.setProperty('--bt-chat-width',
                    clampW(startW + (ev.clientX - startX)) + 'px');
            }, { signal });
            window.addEventListener('pointerup', () => {
                drag.abort();
                this.dropzone.classList.remove('bt-pp-resizing');
                const finalW = Math.round(main.getBoundingClientRect().width);
                if (finalW >= CHAT_MIN) chatWidth.notify(finalW);   // → Julia saver
            }, { signal });
        });
        // Double-click = reset to the default chat width.
        handle.addEventListener('dblclick', (e) => {
            e.preventDefault();
            main.style.removeProperty('--bt-chat-width');
            chatWidth.notify(0);
        });
    }

    // ── Drag-to-dock ──────────────────────────────────────────────────────
    // Dragging the floating window's title bar over the area to the RIGHT of
    // the chat (the region the plotpane fills) docks it. The whole drop
    // region highlights via a fixed-position overlay (pointer-events:none so
    // it never interferes with the FloatingWindow's own drag, which runs in
    // parallel on its own listeners). The pointerdown listener is permanent
    // (one controller per window); the move/up listeners are gesture-scoped.
    setupDragToDock() {
        document.addEventListener('pointerdown', (ev) => {
            const tb = ev.target.closest('.bn-fw-title');
            if (!tb || ev.target.closest('.bn-fw-controls')) return;
            if (!this.current()) return;             // nothing detached → no-op
            const stage = this.dropzone.closest('.bt-stage');
            const main  = stage ? stage.querySelector('.bt-main') : null;
            if (!main || !stage) return;
            const mr = main.getBoundingClientRect(), sr = stage.getBoundingClientRect();
            const left = mr.right, right = sr.right;
            if (right - left < 40) return;           // no room to dock into
            const ov = document.createElement('div');
            ov.className = 'bt-drop-overlay';
            ov.style.left = left + 'px';  ov.style.top = sr.top + 'px';
            ov.style.width = (right - left) + 'px';  ov.style.height = sr.height + 'px';
            document.body.appendChild(ov);
            const inZone = (e2) => e2.clientX >= left && e2.clientX <= right &&
                                   e2.clientY >= sr.top && e2.clientY <= sr.bottom;
            const drag = new AbortController();
            const { signal } = drag;
            document.addEventListener('pointermove',
                (e2) => ov.classList.toggle('bt-drop-active', inZone(e2)), { signal });
            document.addEventListener('pointerup', (e2) => {
                drag.abort();
                const over = inZone(e2);
                ov.remove();
                if (over) this.dock();
            }, { signal });
        });
    }
}
