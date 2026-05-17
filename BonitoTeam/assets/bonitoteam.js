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
        this.wasAtBottom   = true;
        this.initialLoad   = false;
        this.chasingBottom = false;

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

        this._onScroll = () => {
            if (this.chasingBottom && !this.atBottom()) this.chasingBottom = false;
            this.wasAtBottom = this.atBottom();
            this.refresh();
        };
        container.addEventListener('scroll', this._onScroll, { passive: true });

        // Re-scroll whenever the messages container changes size while
        // we're in follow-tail mode. Covers: bt-busy 0↔28px transition
        // on each agent turn, mobile soft-keyboard slide-in/out, the
        // browser's address bar collapsing on scroll, window resize.
        // Without this, the last message + input area can slide below
        // the fold and the user has no way back without manual scroll.
        this._containerRO = new ResizeObserver(() => {
            if (this.destroyed) return;
            if (this.wasAtBottom || this.chasingBottom) {
                this._queueScrollToBottom();
            }
        });
        this._containerRO.observe(this.container);

        if (window.visualViewport) {
            this._onVPResize = () => this.onViewportResize();
            window.visualViewport.addEventListener('resize', this._onVPResize);
        }
    }

    destroy() {
        this.destroyed = true;
        if (this._onScroll) {
            this.container.removeEventListener('scroll', this._onScroll);
        }
        if (this._onVPResize && window.visualViewport) {
            window.visualViewport.removeEventListener('resize', this._onVPResize);
        }
        if (this._containerRO) {
            this._containerRO.disconnect();
        }
        this.ros.forEach((ro) => ro.disconnect());
        this.ros.clear();
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
                // wasAtBottom — which it should be when a turn starts.
                if (this.wasAtBottom) this._queueScrollToBottom();
                return;
            case 'busy_end':
                this.busyEl?.classList.remove('bt-busy-active');
                if (this.wasAtBottom) this._queueScrollToBottom();
                return;
            case 'agent_final':  return this.onAgentFinal(msg);
            case 'thought_final':return this.onThoughtFinal(msg);
            case 'thought.body': return this.onThoughtBody(msg);
            case 'tool_update':  return this.onToolUpdate(msg);
            case 'chunk':        return this.appendChunk(msg.id, msg.text);
            case 'thought_chunk':return this.appendChunk(msg.id, msg.text);
            case 'user_chunk':   return this.appendUserChunk(msg.text);
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
            this.initialLoad   = false;
            this.chasingBottom = true;
            this.scrollToBottom();
            requestAnimationFrame(() => {
                if (!this.destroyed && this.chasingBottom) this.scrollToBottom();
            });
            setTimeout(() => {
                if (!this.destroyed && this.chasingBottom) this.scrollToBottom();
            }, 100);
            setTimeout(() => {
                if (!this.destroyed && this.chasingBottom) this.scrollToBottom();
                this.chasingBottom = false;
            }, 300);
        } else if (this.chasingBottom) {
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
        // User-originated message ("user" type): ALWAYS scroll, even if
        // wasAtBottom is stale-false. The user just hit Enter — they
        // expect to see their own bubble. (For agent / tool / thought
        // arriving from the worker, honour the user's scroll position.)
        const isOwnMessage = msg.type === 'user';
        if (this.wasAtBottom || isOwnMessage) {
            this.updateDOM(...this.visibleRange());
            if (isOwnMessage) {
                // Re-engage chase for the agent's reply that will follow.
                this.wasAtBottom   = true;
                this.chasingBottom = true;
            }
            this._queueScrollToBottom();
        }
    }

    appendChunk(id, text) {
        const node = this.nodeById.get(id);
        if (!node) return;
        const t = node.querySelector('.bt-stream-text');
        if (t) t.textContent += text;
        // Streaming text grows the bubble downward; if the user was
        // following the tail, keep them at the tail. wasAtBottom is
        // refreshed by the scroll listener so a deliberate scroll-up
        // releases the chase. _queueScrollToBottom rAF-batches multiple
        // chunks-per-frame so we only scroll AFTER the layout pass that
        // includes the new text (avoids the stale-scrollHeight race).
        if (this.wasAtBottom) this._queueScrollToBottom();
    }

    appendUserChunk(text) {
        // Streaming user message: append to the most recent user bubble.
        const idx = this.totalCount - 1;
        const node = this.cache.get(idx);
        if (node && node.classList.contains('bt-user-msg')) {
            node.textContent += text;
            if (this.wasAtBottom) this._queueScrollToBottom();
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
        return `
            <div class="bt-tool-header" data-expanded="false">
                <span class="bt-tool-toggle">▶</span>
                <span class="bt-tool-kind">${msg.icon || '⚙'}</span>
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
        // Generous threshold (was 60). On mobile a single new message
        // bubble can be 80-120px tall — a tight threshold flips
        // wasAtBottom=false on every new message, breaking auto-follow.
        return scrollHeight - scrollTop - clientHeight < 200;
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
        requestAnimationFrame(() => {
            this._scrollQueued = false;
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

    onViewportResize() {
        // Mobile keyboard or browser address bar changed the visual
        // viewport. Resize bt-app so flex math has the right available
        // height, then chase the tail across the keyboard's slide-in
        // animation (~250ms on iOS; the container's ResizeObserver
        // picks up each frame of it once .bt-app's height has changed).
        const vv  = window.visualViewport;
        const app = document.querySelector('.bt-app');
        if (app) app.style.height = vv.height + 'px';
        if (this.wasAtBottom) this._queueScrollToBottom();
    }
}

function escapeHTML(str) {
    return String(str).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}
function escapeAttr(str) {
    return escapeHTML(str).replace(/"/g, '&quot;');
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
