// BonitoTeam.js — client-side chat: virtual scroll, DOM windowing, streaming.
//
// All Julia↔JS traffic flows through ONE Bonito Observable: `comm`.
// Julia → JS:  Bonito propagates `model.comm[] = {type, ...}` writes; we
//              dispatch by `msg.type` in `dispatch()` below.
// JS → Julia:  `comm.notify({type: "...", ...})` lands in `chat_dispatch!`
//              on the Julia side. Bonito's `update_nocycle!` keeps Julia
//              writes from echoing back to JS as JS-originated events.
//
// Tool-body lazy renders still go through `Bonito.dom_in_js` (Monaco editors
// inside need a live session) — Julia ships the rendered DOM into the
// `[data-tool-id]` slot directly. Everything else (counts, ranges, message
// pushes, status pings) is on `comm`.

class BonitoChat {
    constructor(container, comm) {
        this.container = container;
        this.comm      = comm;
        this.destroyed = false;

        this.cache    = new Map();  // idx (0-based) → DOMNode
        this.heights  = new Map();
        this.rendered = new Set();
        this.nodeById = new Map();  // msg_id → DOMNode  (for streaming updates)
        this.ros      = new Map();

        this.totalCount    = 0;
        this.EST_HEIGHT    = 80;
        this.OVERSCAN      = 8;
        this.initialLoad   = false;

        // ── Scroll UX state ────────────────────────────────────────────
        // followMode: when true, new messages auto-scroll the viewport
        // to the bottom. When false, the viewport stays where the user
        // left it and an "↓ New messages" pill appears that jumps them
        // back when clicked. Toggled by:
        //   - user scrolls away from bottom → followMode = false
        //   - user scrolls to the bottom (within AT_BOTTOM_PX) → true
        //   - user sends a message → true
        //   - user clicks the pill → true
        // We do NOT toggle followMode from a layout-induced scroll: if
        // a viewport resize shifts the geometry, we stay in whatever
        // mode the user last chose.
        this.followMode = true;
        this.unreadCount = 0;
        // "At bottom" is intentionally tight here (20px) — the loose
        // 200px threshold the old code used was a workaround for
        // chunked-text-during-burst race conditions. With explicit
        // followMode there's no race: chase scrolls to scrollHeight
        // unconditionally, so being "at the bottom" means actually
        // there, not "near enough".
        this.AT_BOTTOM_PX = 20;

        this.spacerTop    = container.querySelector('.bt-spacer-top');
        this.spacerBottom = container.querySelector('.bt-spacer-bottom');
        this.busyEl       = container.parentElement.querySelector('.bt-busy');

        // Single subscription. `comm` is a Bonito Observable bridged via
        // WS; every message Julia sets via `model.comm[] = {...}` arrives here.
        comm.on((msg) => {
            if (this.destroyed) return;
            if (msg && typeof msg === 'object') this.dispatch(msg);
        });

        // Ask Julia for the current message count. The reply arrives as
        // `{type: "msgs.count", n}` and triggers the initial range fetch.
        // If Julia already pushed a count (e.g., on a re-mount the
        // observable still holds the latest dict), bootstrap from that
        // immediately so we don't double-render.
        const cur = comm.value;
        if (cur && cur.type === 'msgs.count' && cur.n > 0) {
            this.applyCount(cur.n);
        } else if (cur && cur.type === 'msgs.range') {
            // Re-mount of a chat that already has messages cached.
            this.onRange(cur);
        }
        comm.notify({type: 'init'});

        // Track the last user input on the container. A scroll event
        // within ~400ms of a wheel/touch/keydown is treated as
        // user-initiated; outside that window, it's a layout shift
        // (viewport resize, container RO re-render, attachment-bar
        // pop-in). Only user-initiated scrolls toggle followMode —
        // a layout shift never disengages chase.
        this._lastUserInputT = 0;
        const markUserInput = () => { this._lastUserInputT = performance.now(); };
        container.addEventListener('wheel',      markUserInput, { passive: true });
        container.addEventListener('touchstart', markUserInput, { passive: true });
        container.addEventListener('touchmove',  markUserInput, { passive: true });
        container.addEventListener('keydown',    markUserInput, { passive: true });
        this._markUserInput = markUserInput;

        this._onScroll = () => {
            const userDriven = (performance.now() - this._lastUserInputT) < 400;
            const atBot      = this.atBottom();
            if (userDriven) {
                // User-driven scroll → followMode reflects whether
                // they landed at the bottom. Scrolling up → false,
                // scrolling all the way back down → true.
                this.setFollowMode(atBot);
                if (!atBot) this._cancelPendingScroll();
            } else if (this.followMode && !atBot) {
                // Layout shift moved us off the bottom while in
                // follow mode (viewport resize / attachment-bar
                // pop-in). Re-anchor.
                this._queueScrollToBottom();
            }
            this.refresh();
        };
        container.addEventListener('scroll', this._onScroll, { passive: true });

        // Re-scroll whenever the messages container changes size
        // while in follow mode. Covers: bt-busy 0↔28px transition
        // on each agent turn, mobile soft-keyboard slide-in/out,
        // browser address bar collapse, window resize, attachment
        // bar growing. Without this, the last message + input area
        // slide below the fold and the user has no way back without
        // manual scroll.
        this._containerRO = new ResizeObserver(() => {
            if (this.destroyed) return;
            if (this.followMode) this._queueScrollToBottom();
        });
        this._containerRO.observe(this.container);

        if (window.visualViewport) {
            this._onVPResize = () => this.onViewportResize();
            window.visualViewport.addEventListener('resize', this._onVPResize);
        }

        // Image attachments (paste / drag-drop). Wired AFTER the input area
        // is in the DOM, on a microtask so .bt-app's children are queryable.
        Promise.resolve().then(() => this._setupInputs());
    }

    destroy() {
        this.destroyed = true;
        if (this._onScroll) {
            this.container.removeEventListener('scroll', this._onScroll);
        }
        if (this._markUserInput) {
            this.container.removeEventListener('wheel',    this._markUserInput);
            this.container.removeEventListener('touchstart', this._markUserInput);
            this.container.removeEventListener('touchmove',  this._markUserInput);
            this.container.removeEventListener('keydown',  this._markUserInput);
        }
        if (this._scrollRafId !== null && this._scrollRafId !== undefined) {
            cancelAnimationFrame(this._scrollRafId);
        }
        if (this._onVPResize && window.visualViewport) {
            window.visualViewport.removeEventListener('resize', this._onVPResize);
        }
        if (this._containerRO) {
            this._containerRO.disconnect();
        }
        this.ros.forEach((ro) => ro.disconnect());
        this.ros.clear();
        if (this._onPaste && this.textInput) {
            this.textInput.removeEventListener('paste', this._onPaste);
        }
        if (this._onTextInputKeyCapture && this.textInput) {
            this.textInput.removeEventListener('keydown', this._onTextInputKeyCapture, true);
        }
        if (this._onSendClickCapture && this.sendBtn) {
            this.sendBtn.removeEventListener('click', this._onSendClickCapture, true);
        }
        if (this._onStopClick && this.stopBtn) {
            this.stopBtn.removeEventListener('click', this._onStopClick);
        }
        if (this.app) {
            this._onDragOver  && this.app.removeEventListener('dragover',  this._onDragOver);
            this._onDragLeave && this.app.removeEventListener('dragleave', this._onDragLeave);
            this._onDrop      && this.app.removeEventListener('drop',      this._onDrop);
        }
        clearTimeout(this._attachErrorTimer);
    }

    // Single dispatch table. Julia sends `{type, ...}`; we route here.
    dispatch(msg) {
        // Track incrementally-arriving counts: every message-creation event
        // includes `n`, the new total. We avoid a separate `msgs.count`
        // broadcast for the steady-state stream.
        if (typeof msg.n === 'number' && msg.n > this.totalCount) {
            this.totalCount = msg.n;
        }

        switch (msg.type) {
            case 'msgs.count':   return this.applyCount(msg.n);
            case 'msgs.range':   return this.onRange(msg);
            case 'busy_start':
                this.busyEl?.classList.add('bt-busy-active');
                // bt-busy grows from 0 to 28px over 150ms; the container
                // ResizeObserver re-scrolls on each frame, but only if
                // followMode is on — which it should be when a turn starts.
                if (this.followMode) this._queueScrollToBottom();
                return;
            case 'busy_end':
                this.busyEl?.classList.remove('bt-busy-active');
                if (this.followMode) this._queueScrollToBottom();
                return;
            case 'agent_final':  return this.onAgentFinal(msg);
            case 'thought_final':return this.onThoughtFinal(msg);
            case 'thought.body': return this.onThoughtBody(msg);
            case 'tool_update':  return this.onToolUpdate(msg);
            case 'chunk':        return this.appendChunk(msg.id, msg.text);
            case 'thought_chunk':return this.appendChunk(msg.id, msg.text);
            case 'user_chunk':   return this.appendUserChunk(msg.text);
            case 'attach_error':
                return this._showAttachError(msg.error || 'Attachment failed');
            // (formerly `send_ack` — JS now clears the input widget
            // unconditionally on submit, so no server ack is needed.)
            case 'user':
            case 'agent':
            case 'thought':
            case 'tool':
            case 'plan':
                return this.appendNewMessage(msg);
        }
    }

    // ── Range / virtual scroll ────────────────────────────────────────────

    applyCount(n) {
        if (n <= 0) return;
        this.totalCount  = n;
        this.initialLoad = true;
        this.refresh();
    }

    visibleRange() {
        if (this.totalCount === 0) return [0, -1];
        const { scrollTop, clientHeight } = this.container;
        const over = this.OVERSCAN * this.EST_HEIGHT;
        const s = this.indexAt(Math.max(0, scrollTop - over));
        const e = this.indexAt(scrollTop + clientHeight + over);
        return [s, Math.min(this.totalCount - 1, e)];
    }

    indexAt(offset) {
        let h = 0;
        for (let i = 0; i < this.totalCount; i++) {
            h += (this.heights.get(i) ?? this.EST_HEIGHT);
            if (h > offset) return i;
        }
        return Math.max(0, this.totalCount - 1);
    }

    cumHeight(from, to) {
        let h = 0;
        for (let i = from; i < to; i++) h += (this.heights.get(i) ?? this.EST_HEIGHT);
        return h;
    }

    refresh() {
        if (this.totalCount === 0) return;
        const [s, e] = this.visibleRange();

        const missing = [];
        for (let i = s; i <= e; i++) if (!this.cache.has(i)) missing.push(i);
        if (missing.length > 0) {
            this.comm.notify({type: 'msgs.request',
                              range: [missing[0], missing[missing.length - 1]]});
        }
        this.updateDOM(s, e);
    }

    onRange({ start, msgs }) {
        const messages = msgs ?? [];          // tolerate the legacy `messages` field
        messages.forEach((data, i) => {
            const idx = start + i;
            if (this.cache.has(idx)) return;
            const node = this.createNode(data);
            this.cache.set(idx, node);
            if (data.id) this.nodeById.set(data.id, node);
            this.observe(idx, node);
        });
        this.updateDOM(...this.visibleRange());
        if (this.initialLoad) {
            // Initial mount: scroll to bottom and lock follow mode on.
            // Multiple scroll attempts cover the period during which
            // child Monaco editors / images are still laying out and
            // pushing scrollHeight around.
            this.initialLoad = true; // cleared below after the last scroll
            this.setFollowMode(true);
            this.scrollToBottom();
            requestAnimationFrame(() => {
                if (!this.destroyed && this.followMode) this.scrollToBottom();
            });
            setTimeout(() => {
                if (!this.destroyed && this.followMode) this.scrollToBottom();
            }, 100);
            setTimeout(() => {
                if (!this.destroyed && this.followMode) this.scrollToBottom();
                this.initialLoad = false;
            }, 300);
        } else if (this.followMode) {
            this._queueScrollToBottom();
        }
    }

    observe(idx, node) {
        const ro = new ResizeObserver(([e]) => {
            const h = e.contentRect.height;
            if (h > 0) { this.heights.set(idx, h); }
        });
        ro.observe(node);
        this.ros.set(idx, ro);
    }

    updateDOM(s, e) {
        if (s > e) return;
        for (const idx of [...this.rendered]) {
            if (idx < s || idx > e) {
                this.cache.get(idx)?.remove();
                this.rendered.delete(idx);
            }
        }
        for (let i = s; i <= e; i++) {
            if (this.cache.has(i) && !this.rendered.has(i)) {
                this.insertSorted(i, this.cache.get(i));
                this.rendered.add(i);
            }
        }
        this.spacerTop.style.height    = this.cumHeight(0, s) + 'px';
        this.spacerBottom.style.height = this.cumHeight(e + 1, this.totalCount) + 'px';
    }

    insertSorted(idx, node) {
        const sorted = [...this.rendered].filter(i => i > idx).sort((a,b) => a-b);
        const before = sorted.length ? this.cache.get(sorted[0]) : this.spacerBottom;
        this.container.insertBefore(node, before);
    }

    // ── New messages + streaming ──────────────────────────────────────────

    appendNewMessage(msg) {
        // `n` already pushed totalCount above; the new message lives at idx n-1.
        const idx = this.totalCount - 1;
        if (!this.cache.has(idx)) {
            const node = this.createNode(msg);
            this.cache.set(idx, node);
            if (msg.id) this.nodeById.set(msg.id, node);
            this.observe(idx, node);
        }
        // Strict no-yank semantics: any new message (including the
        // user's own) auto-scrolls ONLY while followMode is on.
        // When the user is reading scrollback we just register unread
        // and surface the pill — sending their own message doesn't
        // re-engage follow either; they have to click the pill or
        // scroll to the bottom to come back. This matches the spec
        // "always stay at the position the user scrolls to".
        if (this.followMode) {
            // Scroll synchronously — `scrollToBottom` does the scroll +
            // calls `refresh()` (which re-computes `visibleRange()` from
            // the new scrollTop and calls `updateDOM`), so the new bubble
            // lands in the DOM in one synchronous call. We deliberately
            // do NOT route through `_queueScrollToBottom` here: rAF is
            // paused in backgrounded tabs/windows, which means new
            // messages would land in `cache` but never make it into the
            // DOM until the user re-focuses the tab. That manifests as
            // "I sent a message and 5 old messages appeared instantly" —
            // they were already cached, the auto-scroll just couldn't
            // fire while the tab was in the background. Synchronous
            // scrollTop writes and DOM updates work regardless of tab
            // visibility, so we land the bubble immediately. rAF batching
            // is still used for `appendChunk` (50 chunks/s, batching is
            // a real perf win; the streaming bubble itself is already in
            // the DOM, only the scroll lags).
            this.scrollToBottom();
        } else {
            this._registerUnread();
        }
    }

    appendChunk(id, text) {
        const node = this.nodeById.get(id);
        if (!node) return;
        const t = node.querySelector('.bt-stream-text');
        if (t) t.textContent += text;
        // _queueScrollToBottom rAF-batches multiple chunks per frame so
        // we only scroll AFTER the layout pass that includes the new
        // text (avoids the stale-scrollHeight race).
        if (this.followMode) {
            this._queueScrollToBottom();
        } else {
            // Streaming bubble is being extended while user is reading
            // scrollback. _registerUnread is idempotent for repeated
            // chunks of the same bubble — the pill stays visible once
            // shown.
            this._registerUnread();
        }
    }

    appendUserChunk(text) {
        // Streaming user message: append to the most recent user bubble.
        const idx = this.totalCount - 1;
        const node = this.cache.get(idx);
        if (node && node.classList.contains('bt-user-msg')) {
            node.textContent += text;
            if (this.followMode) {
                this._queueScrollToBottom();
            } else {
                this._registerUnread();
            }
        }
    }

    onAgentFinal(msg) {
        const node = this.nodeById.get(msg.id);
        if (node && msg.html) node.innerHTML = msg.html;
    }

    onThoughtFinal(msg) {
        const node = this.nodeById.get(msg.id);
        if (!node) return;
        if (msg.html) {
            const body = node.querySelector('.bt-thought-body');
            if (body) body.innerHTML = msg.html;
        }
        const details = node.querySelector('.bt-thought-details');
        if (details) details.dataset.streamed = 'true';
    }

    onThoughtBody(msg) {
        // Reply to a `thought.render` request — populate the lazy body.
        const node = this.nodeById.get(msg.id);
        if (!node) return;
        const body = node.querySelector('.bt-thought-body');
        if (body) {
            body.innerHTML = msg.html;
            body.dataset.loaded = 'true';
        }
    }

    onToolUpdate(msg) {
        const node = this.nodeById.get(msg.id);
        if (!node) return;
        if (msg.status) {
            const s = node.querySelector('.bt-tool-status');
            if (s) { s.textContent = msg.status; s.className = `bt-tool-status bt-status-${msg.status}`; }
        }
        if (msg.title) {
            const t = node.querySelector('.bt-tool-title');
            if (t) t.textContent = msg.title;
        }
        if (msg.summary != null) {
            const s = node.querySelector('.bt-tool-summary');
            if (s) s.textContent = msg.summary;
        }
    }

    // ── DOM node creation ────────────────────────────────────────────────

    createNode(msg) {
        const div = document.createElement('div');
        switch (msg.type) {
            case 'user':
                div.className = 'bt-user-msg';
                div.textContent = msg.text;
                break;
            case 'agent':
                div.className = 'bt-agent-msg';
                if (msg.streaming) {
                    const span = document.createElement('span');
                    span.className = 'bt-stream-text';
                    // Seed with whatever the first chunk sent (may be ""):
                    // a viewer that joined mid-stream needs to see this
                    // initial text immediately, not wait for the next chunk.
                    if (msg.text) span.textContent = msg.text;
                    div.appendChild(span);
                } else {
                    div.innerHTML = msg.html || '';
                }
                break;
            case 'thought':
                div.className = 'bt-thought-msg';
                div.innerHTML = this.thoughtHTML(msg);
                this.wireThoughtToggle(div, msg.id);
                break;
            case 'tool':
                div.className = 'bt-tool-msg';
                div.innerHTML = this.toolHTML(msg);
                this.wireToolToggle(div, msg.id);
                break;
            case 'plan':
                div.className = 'bt-plan-msg';
                div.innerHTML = msg.html || '';
                break;
        }
        return div;
    }

    thoughtHTML(msg) {
        const body = msg.streaming ?
                       `<span class="bt-stream-text">${escapeHTML(msg.text || '')}</span>` :
                     msg.html      ? msg.html : '';
        const summary = msg.streaming ? 'Thinking…' :
                        (msg.summary || 'Show thinking');
        return `<details class="bt-thought-details" data-thought-id="${escapeAttr(msg.id || '')}">
            <summary class="bt-thought-summary">💭 ${escapeHTML(summary)}</summary>
            <div class="bt-thought-body" data-loaded="${msg.streaming || msg.html ? 'true' : 'false'}">${body}</div>
        </details>`;
    }

    wireThoughtToggle(node, thoughtId) {
        const details = node.querySelector('.bt-thought-details');
        const body    = node.querySelector('.bt-thought-body');
        if (!details || !body) return;
        details.addEventListener('toggle', () => {
            if (!details.open) return;
            if (body.dataset.loaded === 'true') return;
            body.innerHTML = '<span class="bt-thought-loading">loading…</span>';
            this.comm.notify({type: 'thought.render', id: thoughtId});
        });
    }

    toolHTML(msg) {
        const statusCls = `bt-tool-status bt-status-${msg.status || 'pending'}`;
        const preview   = msg.preview ?
            `<div class="bt-edit-preview">${msg.preview}</div>` : '';
        // MCP tools carry a `server` (e.g. "bonitoteam"); show it as a dim
        // badge before the (already prefix-stripped) tool name.
        const server = msg.server ?
            `<span class="bt-tool-server">${escapeHTML(msg.server)}</span>` : '';
        return `
            <div class="bt-tool-header" data-expanded="false">
                <span class="bt-tool-toggle">▶</span>
                <span class="bt-tool-kind">${msg.icon || '⚙'}</span>
                ${server}
                <span class="bt-tool-title">${escapeHTML(msg.title || '')}</span>
                <span class="bt-tool-summary">${escapeHTML(msg.summary || '')}</span>
                <span class="${statusCls}">${escapeHTML(msg.status || '')}</span>
            </div>
            ${preview}
            <div class="bt-tool-body" data-tool-id="${escapeAttr(msg.id || '')}"></div>`;
    }

    wireToolToggle(node, toolId) {
        const header = node.querySelector('.bt-tool-header');
        const toggle = header.querySelector('.bt-tool-toggle');
        const body   = node.querySelector('.bt-tool-body');
        if (!header || !body) return;
        header.style.cursor = 'pointer';
        header.addEventListener('click', () => {
            // The glyph is swapped directly (`▶` ↔ `▼`) — a plain
            // textContent change that works in every renderer. There is
            // NO CSS `transform: rotate()` on `.bt-tool-toggle`: the old
            // code rotated the glyph 90° *as well as* swapping it, so the
            // expanded `▼` came out sideways (looked like a small `◀`).
            const expanded = header.dataset.expanded === 'true';
            if (expanded) {
                body.innerHTML = '';
                header.dataset.expanded = 'false';
                toggle.textContent = '▶';
            } else {
                body.innerHTML = '<div class="bt-tool-loading">loading…</div>';
                this.comm.notify({type: 'tool.render', id: toolId});
                header.dataset.expanded = 'true';
                toggle.textContent = '▼';
            }
        });
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    atBottom() {
        const { scrollTop, scrollHeight, clientHeight } = this.container;
        // Tight (AT_BOTTOM_PX = 20) so "user manually scrolled to the
        // very bottom" re-engages follow mode while merely-near doesn't.
        // The chase always scrolls to scrollHeight so streaming content
        // doesn't bounce in and out of this threshold — the worry the
        // old generous 200px window was guarding against.
        return scrollHeight - scrollTop - clientHeight < this.AT_BOTTOM_PX;
    }

    // rAF-batched scroll: multiple stream chunks arriving in the same
    // frame (or a chunk + a ResizeObserver callback) coalesce into ONE
    // scroll, run AFTER the browser has laid out the new content.
    // Reading scrollHeight synchronously after a textContent write
    // returns a stale value mid-layout; deferring to rAF guarantees
    // we measure post-layout.
    _queueScrollToBottom() {
        if (this._scrollQueued || this.destroyed) return;
        this._scrollQueued = true;
        this._scrollRafId = requestAnimationFrame(() => {
            this._scrollQueued = false;
            this._scrollRafId = null;
            if (!this.destroyed) this.scrollToBottom();
        });
    }

    scrollToBottom() {
        // Belt + suspenders: set scrollTop AND scrollIntoView on the
        // bottom spacer. scrollTop alone uses the container's reported
        // scrollHeight which can be stale during streaming; scrollIntoView
        // tells the browser "make this element's bottom edge visible"
        // and lets it compute the right position from current layout.
        this.container.scrollTop = this.container.scrollHeight;
        if (this.spacerBottom) {
            this.spacerBottom.scrollIntoView({ block: 'end', behavior: 'auto' });
        }
        // Don't rely on the `scroll` event to drive the post-scroll range
        // fetch — Electron's offscreen renderer (and a few other headless
        // browser configs) doesn't fire scroll events for programmatic
        // scrollTop changes, which leaves the chasing-bottom loop fetching
        // nothing past the initial range. `refresh()` is idempotent and
        // cheap, so call it explicitly.
        this.refresh();
    }

    // ── Image attachments ────────────────────────────────────────────────
    // Wire up the input widgets (textarea + send/stop buttons + attachments).
    // Single send path: ALL user submissions ship `{type: 'send', text,
    // attachments}` through `comm`. The send-button click + textarea Enter
    // are JS-owned in capture phase; the local textarea + attachment strip
    // are cleared right after `comm.notify` — no Julia round-trip for the
    // UI reset. Stop button posts `{type: 'cancel'}`. Paste / drag-drop
    // populates `this.attachments` (Map<id, {blob, mime, filename, dataUrl}>)
    // with thumbnails shown above the input row; on submit Julia stores
    // the bytes under `<cwd>/.bt-attachments/<ts>.<ext>`, pushes to the
    // worker mirror (via `send_file_to_worker!`), and forwards them to
    // claude as multimodal content blocks.
    _setupInputs() {
        if (this.destroyed) return;
        const app = this.container?.parentElement;
        if (!app) return;
        this.app       = app;
        this.inputArea = app.querySelector('.bt-input-area');
        this.textInput = app.querySelector('.bt-text-input');
        this.sendBtn   = app.querySelector('.bt-send-btn');
        if (!this.inputArea || !this.textInput || !this.sendBtn) return;

        // Thumbnail strip lives ABOVE the input row inside .bt-input-area.
        this.attachBar = document.createElement('div');
        this.attachBar.className = 'bt-attachments';
        this.inputArea.insertBefore(this.attachBar, this.inputArea.firstChild);

        this.attachments = new Map();
        this._attachIdCounter = 0;
        this.ATTACH_MAX_BYTES = 5 * 1024 * 1024;

        // Paste — clipboardData.items carries File entries for images.
        this._onPaste = (e) => {
            const items = e.clipboardData?.items;
            if (!items) return;
            for (const it of items) {
                if (it.kind === 'file' && it.type && it.type.startsWith('image/')) {
                    const blob = it.getAsFile();
                    if (blob) this._attachAddBlob(blob, blob.type || it.type,
                                                  blob.name || `pasted-${Date.now()}.png`);
                }
            }
        };
        this.textInput.addEventListener('paste', this._onPaste);

        // Drag-drop — listen on the whole .bt-app so a drop anywhere in
        // the chat counts. dragover MUST preventDefault to enable drop.
        this._onDragOver = (e) => {
            if (!this._dragHasImage(e)) return;
            e.preventDefault();
            this.app.classList.add('bt-drag-over');
        };
        this._onDragLeave = (e) => {
            // Only clear when leaving the .bt-app envelope itself, not
            // when crossing between nested children (relatedTarget inside app).
            if (e.relatedTarget && this.app.contains(e.relatedTarget)) return;
            this.app.classList.remove('bt-drag-over');
        };
        this._onDrop = (e) => {
            e.preventDefault();
            this.app.classList.remove('bt-drag-over');
            const files = e.dataTransfer?.files;
            if (!files) return;
            for (const f of files) {
                if (f.type && f.type.startsWith('image/')) {
                    this._attachAddBlob(f, f.type, f.name || `dropped-${Date.now()}.png`);
                }
            }
        };
        this.app.addEventListener('dragover',  this._onDragOver);
        this.app.addEventListener('dragleave', this._onDragLeave);
        this.app.addEventListener('drop',      this._onDrop);

        // Send click — capture phase so we run before any other listener
        // (none exist now that Julia uses a plain DOM button, but
        // capture is robust against future additions). Same shape for
        // textarea Enter.
        this._onSendClickCapture = (e) => {
            e.preventDefault();
            e.stopImmediatePropagation();
            this._submit();
        };
        this.sendBtn.addEventListener('click', this._onSendClickCapture, true);

        this._onTextInputKeyCapture = (e) => {
            if (e.key !== 'Enter' || e.shiftKey) return;
            e.preventDefault();
            e.stopImmediatePropagation();
            this._submit();
        };
        this.textInput.addEventListener('keydown', this._onTextInputKeyCapture, true);

        if (this.stopBtn) {
            this._onStopClick = (e) => {
                e.preventDefault();
                this.comm.notify({type: 'cancel'});
            };
            this.stopBtn.addEventListener('click', this._onStopClick);
        }
    }

    _dragHasImage(e) {
        const dt = e.dataTransfer;
        if (!dt) return false;
        if (dt.types) {
            // 'Files' is the type when the user drags from the OS file picker.
            // Browsers don't expose individual MIME types during dragover, so
            // we accept any Files drag here and filter image/* on drop.
            for (const t of dt.types) if (t === 'Files') return true;
        }
        return false;
    }

    _attachAddBlob(blob, mime, filename) {
        if (blob.size > this.ATTACH_MAX_BYTES) {
            this._showAttachError(
                `Image too large (${(blob.size / 1024 / 1024).toFixed(1)} MB, ` +
                `max ${this.ATTACH_MAX_BYTES / 1024 / 1024} MB)`);
            return;
        }
        const id = `att-${++this._attachIdCounter}`;
        const reader = new FileReader();
        reader.onload = () => {
            if (this.destroyed) return;
            this.attachments.set(id, {
                blob, mime, filename,
                dataUrl: reader.result,
            });
            this._renderAttachments();
        };
        reader.onerror = () => this._showAttachError('Failed to read image');
        reader.readAsDataURL(blob);
    }

    _attachRemove(id) {
        this.attachments.delete(id);
        this._renderAttachments();
    }

    _attachClear() {
        this.attachments.clear();
        this._renderAttachments();
    }

    _renderAttachments() {
        if (!this.attachBar) return;
        // Preserve any transient error chip across re-renders.
        const err = this.attachBar.querySelector('.bt-attach-error');
        this.attachBar.innerHTML = '';
        if (this.attachments.size === 0) {
            this.attachBar.classList.remove('bt-attachments-active');
        } else {
            this.attachBar.classList.add('bt-attachments-active');
            for (const [id, item] of this.attachments) {
                const wrap = document.createElement('div');
                wrap.className = 'bt-attachment-thumb';
                wrap.dataset.attachId = id;
                const img = document.createElement('img');
                img.src   = item.dataUrl;
                img.alt   = item.filename || 'image';
                img.title = item.filename || 'image';
                wrap.appendChild(img);
                const rm = document.createElement('button');
                rm.type = 'button';
                rm.className = 'bt-attachment-remove';
                rm.title = 'Remove';
                rm.textContent = '×';
                rm.addEventListener('click', (e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    this._attachRemove(id);
                });
                wrap.appendChild(rm);
                this.attachBar.appendChild(wrap);
            }
        }
        if (err) this.attachBar.appendChild(err);
    }

    _showAttachError(message) {
        if (!this.attachBar) return;
        let chip = this.attachBar.querySelector('.bt-attach-error');
        if (!chip) {
            chip = document.createElement('div');
            chip.className = 'bt-attach-error';
            this.attachBar.appendChild(chip);
            this.attachBar.classList.add('bt-attachments-active');
        }
        chip.textContent = message;
        clearTimeout(this._attachErrorTimer);
        this._attachErrorTimer = setTimeout(() => {
            chip.remove();
            if (this.attachments.size === 0) {
                this.attachBar.classList.remove('bt-attachments-active');
            }
        }, 4500);
    }

    async _submit() {
        const text = this.textInput.value;
        // Nothing to send → noop. (Pressing Enter on an empty textarea
        // shouldn't fire a request, and the user can have queued some
        // attachments without any text — the latter case still sends.)
        if (text.trim() === '' && this.attachments.size === 0) return;
        const payload = [];
        for (const item of this.attachments.values()) {
            const buf = await item.blob.arrayBuffer();
            payload.push({
                mime:     item.mime,
                filename: item.filename || '',
                data:     arrayBufferToBase64(buf),
            });
        }
        this.comm.notify({type: 'send', text, attachments: payload});
        // Clear the local input immediately. We don't wait for any
        // server ack — the textarea content is already encoded on the
        // wire, Julia will surface errors (e.g. attachment rejection)
        // via a separate event, and locking the user out of typing
        // their next message while bytes are in flight would be hostile.
        this.textInput.value = '';
        this.textInput.dispatchEvent(new Event('input', {bubbles: true}));
        this._attachClear();
    }

    onViewportResize() {
        // Mobile keyboard or browser address bar changed the visual
        // viewport. Resize bt-app so flex math has the right available
        // height, then chase the tail across the keyboard's slide-in
        // animation (~250ms on iOS; the container's ResizeObserver
        // picks up each frame of it once .bt-app's height has changed).
        const vv  = window.visualViewport;
        const app = document.querySelector('.bt-app');
        if (app) app.style.height = vv.height + 'px';
        if (this.followMode) this._queueScrollToBottom();
    }

    // ── Follow mode + unread pill ────────────────────────────────────────
    // followMode is the one-bit "should new content auto-scroll" state.
    // It's set true when the user is at the bottom (within AT_BOTTOM_PX)
    // and the chat starts in this mode. Scrolling away → false. Sending
    // a message, clicking the pill, or scrolling back to the bottom →
    // true. Layout shifts never toggle it.
    setFollowMode(on) {
        if (this.followMode === on) return;
        this.followMode = on;
        if (on) {
            this.unreadCount = 0;
            this._hideNewMessagePill();
        }
    }

    _cancelPendingScroll() {
        if (this._scrollRafId !== null && this._scrollRafId !== undefined) {
            cancelAnimationFrame(this._scrollRafId);
            this._scrollRafId = null;
            this._scrollQueued = false;
        }
    }

    // Bump unread + show pill. Called from appendNewMessage and
    // appendChunk when followMode is off.
    _registerUnread() {
        this.unreadCount++;
        this._showNewMessagePill();
    }

    _showNewMessagePill() {
        if (!this._pillEl) this._createNewMessagePill();
        if (this._pillEl) this._pillEl.classList.add('bt-new-msg-pill-visible');
    }

    _hideNewMessagePill() {
        if (this._pillEl) this._pillEl.classList.remove('bt-new-msg-pill-visible');
    }

    // Pill lives inside .bt-app, absolutely positioned above the input
    // area. We append it once and toggle its visibility class. Click →
    // re-engage follow mode and scroll to the bottom.
    _createNewMessagePill() {
        const app = this.container?.parentElement;
        if (!app) return;
        const pill = document.createElement('button');
        pill.type = 'button';
        pill.className = 'bt-new-msg-pill';
        pill.innerHTML = '<span class="bt-new-msg-pill-arrow">↓</span>' +
                          '<span>New messages</span>';
        pill.addEventListener('click', (e) => {
            e.preventDefault();
            this.setFollowMode(true);
            this.scrollToBottom();
        });
        app.appendChild(pill);
        this._pillEl = pill;
    }
}

function escapeHTML(str) {
    return String(str).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}
function escapeAttr(str) {
    return escapeHTML(str).replace(/"/g, '&quot;');
}

// Chunked base64 encoder. `btoa(String.fromCharCode(...new Uint8Array(buf)))`
// breaks on large buffers (browser arg-count limit, ~64k); we chunk through
// 32k bytes at a time.
function arrayBufferToBase64(buf) {
    const bytes = new Uint8Array(buf);
    let binary = '';
    const CHUNK = 0x8000;
    for (let i = 0; i < bytes.length; i += CHUNK) {
        binary += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
    }
    return btoa(binary);
}

// ── ES6 module exports ─────────────────────────────────────────────────────
// `connect(node, comm)` is the public entry point — Julia calls it inline
// via `js"$(ChatLib).then(lib => lib.connect($(node), $(comm)))"`. The
// MutationObserver auto-cleans the BonitoChat instance when its container
// leaves the document, so no Julia-side lifecycle plumbing is needed.
export function connect(node, comm) {
    const chat = new BonitoChat(node, comm);
    node.__bt_chat = chat;     // devtools/test inspection hook

    const parent = node.parentNode;
    if (parent) {
        const mo = new MutationObserver(() => {
            if (!node.isConnected) {
                try { chat.destroy(); } catch (_) {}
                mo.disconnect();
            }
        });
        mo.observe(parent, { childList: true });
    }
    return chat;
}

export { BonitoChat };
