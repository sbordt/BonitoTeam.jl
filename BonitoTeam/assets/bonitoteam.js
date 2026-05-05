// BonitoTeam.js — client-side chat: virtual scroll, DOM windowing, streaming

class BonitoChat {
    constructor(container, obs) {
        this.container = container;
        this.obs       = obs;

        this.cache    = new Map();  // idx (0-based) → DOMNode
        this.heights  = new Map();  // idx → measured px
        this.rendered = new Set();  // indices currently in DOM
        this.nodeById = new Map();  // msg_id → DOMNode  (for streaming updates)
        this.ros      = new Map();  // idx → ResizeObserver  (kept to disconnect)

        this.totalCount      = 0;
        this.EST_HEIGHT      = 80;
        this.OVERSCAN        = 8;
        this.wasAtBottom     = true;
        this.initialLoad     = false;  // true while waiting for first range response

        this.spacerTop    = container.querySelector('.bt-spacer-top');
        this.spacerBottom = container.querySelector('.bt-spacer-bottom');
        this.busyEl       = container.parentElement.querySelector('.bt-busy');

        // Julia → JS
        obs.totalCount.on(n    => { this.totalCount = n; this.refresh(); });
        obs.newMsg.on(str      => { if (str) this._onNewMsg(JSON.parse(str)); });
        obs.rangeResponse.on(str => { if (str) this._onRange(JSON.parse(str)); });

        // Bootstrap history on page load — totalCount.on only fires on future changes
        if (obs.initialCount > 0) {
            this.totalCount  = obs.initialCount;
            this.initialLoad = true;
            this.refresh();
        }

        // Scroll
        container.addEventListener('scroll', () => {
            this.wasAtBottom = this._atBottom();
            this.refresh();
        }, { passive: true });

        // Mobile: keep input visible when virtual keyboard opens
        if (window.visualViewport) {
            window.visualViewport.addEventListener('resize', () => this._onVPResize());
        }
    }

    // ── Range / virtual scroll ───────────────────────────────────────────────

    _visibleRange() {
        if (this.totalCount === 0) return [0, -1];
        const { scrollTop, clientHeight } = this.container;
        const over = this.OVERSCAN * this.EST_HEIGHT;
        const s = this._indexAt(Math.max(0, scrollTop - over));
        const e = this._indexAt(scrollTop + clientHeight + over);
        return [s, Math.min(this.totalCount - 1, e)];
    }

    _indexAt(offset) {
        let h = 0;
        for (let i = 0; i < this.totalCount; i++) {
            h += (this.heights.get(i) ?? this.EST_HEIGHT);
            if (h > offset) return i;
        }
        return Math.max(0, this.totalCount - 1);
    }

    _cumHeight(from, to) {
        let h = 0;
        for (let i = from; i < to; i++) h += (this.heights.get(i) ?? this.EST_HEIGHT);
        return h;
    }

    refresh() {
        if (this.totalCount === 0) return;
        const [s, e] = this._visibleRange();

        // Collect missing indices → batch request to Julia
        const missing = [];
        for (let i = s; i <= e; i++) if (!this.cache.has(i)) missing.push(i);
        if (missing.length > 0)
            this.obs.requestRange.notify([missing[0], missing[missing.length - 1]]);

        this._updateDOM(s, e);
    }

    _onRange({ start, messages }) {
        messages.forEach((data, i) => {
            const idx = start + i;
            if (this.cache.has(idx)) return;
            const node = this._createNode(data);
            this.cache.set(idx, node);
            if (data.id) this.nodeById.set(data.id, node);
            this._observe(idx, node);
        });
        this._updateDOM(...this._visibleRange());
        if (this.initialLoad) {
            this.scrollToBottom();
            this.initialLoad = false;
        }
    }

    _observe(idx, node) {
        const ro = new ResizeObserver(([e]) => {
            const h = e.contentRect.height;
            if (h > 0) { this.heights.set(idx, h); }
        });
        ro.observe(node);
        this.ros.set(idx, ro);
    }

    _updateDOM(s, e) {
        if (s > e) return;

        // Remove out-of-window
        for (const idx of [...this.rendered]) {
            if (idx < s || idx > e) {
                this.cache.get(idx)?.remove();
                this.rendered.delete(idx);
            }
        }

        // Insert in-window, maintaining document order
        for (let i = s; i <= e; i++) {
            if (this.cache.has(i) && !this.rendered.has(i)) {
                this._insertSorted(i, this.cache.get(i));
                this.rendered.add(i);
            }
        }

        this.spacerTop.style.height    = this._cumHeight(0, s) + 'px';
        this.spacerBottom.style.height = this._cumHeight(e + 1, this.totalCount) + 'px';
    }

    _insertSorted(idx, node) {
        const sorted = [...this.rendered].filter(i => i > idx).sort((a,b) => a-b);
        const before = sorted.length ? this.cache.get(sorted[0]) : this.spacerBottom;
        this.container.insertBefore(node, before);
    }

    // ── New messages + streaming ─────────────────────────────────────────────

    _onNewMsg(msg) {
        if (msg.type === 'busy_start') { this.busyEl?.classList.add('bt-busy-active');    return; }
        if (msg.type === 'busy_end')   { this.busyEl?.classList.remove('bt-busy-active'); return; }

        if (msg.type === 'agent_final') {
            const node = this.nodeById.get(msg.id);
            if (node) { node.innerHTML = msg.html; }
            return;
        }

        if (msg.type === 'thought_final') {
            const node = this.nodeById.get(msg.id);
            if (node) {
                const body = node.querySelector('.bt-thought-body');
                if (body) body.innerHTML = msg.html;
            }
            return;
        }

        if (msg.type === 'tool_update') {
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
            if (msg.preview != null) {
                let pre = node.querySelector('.bt-tool-preview');
                if (!pre) { pre = document.createElement('pre'); pre.className = 'bt-tool-preview'; node.appendChild(pre); }
                pre.textContent = msg.preview;
            }
            return;
        }

        if (msg.type === 'chunk') {
            const node = this.nodeById.get(msg.id);
            if (node) {
                const t = node.querySelector('.bt-stream-text');
                if (t) t.textContent += msg.text;
            }
            return;
        }

        if (msg.type === 'thought_chunk') {
            const node = this.nodeById.get(msg.id);
            if (node) {
                const t = node.querySelector('.bt-stream-text');
                if (t) t.textContent += msg.text;
            }
            return;
        }

        // Regular new message — totalCount fires separately, so cache at that index
        const idx = this.totalCount - 1;
        if (!this.cache.has(idx)) {
            const node = this._createNode(msg);
            this.cache.set(idx, node);
            if (msg.id) this.nodeById.set(msg.id, node);
            this._observe(idx, node);
        }
        if (this.wasAtBottom) {
            this._updateDOM(...this._visibleRange());
            this.scrollToBottom();
        }
    }

    // ── DOM node creation ────────────────────────────────────────────────────

    _createNode(msg) {
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
                    div.appendChild(span);
                } else {
                    div.innerHTML = msg.html || '';
                }
                break;
            case 'thought':
                div.className = 'bt-thought-msg';
                div.innerHTML = this._thoughtHTML(msg);
                break;
            case 'tool':
                div.className = 'bt-tool-msg';
                div.innerHTML = this._toolHTML(msg);
                break;
            case 'plan':
                div.className = 'bt-plan-msg';
                div.innerHTML = msg.html || '';
                break;
        }
        return div;
    }

    _thoughtHTML(msg) {
        const body = msg.streaming
            ? `<span class="bt-stream-text"></span>`
            : `<div class="bt-thought-body">${msg.html || ''}</div>`;
        return `<details class="bt-thought-details">
            <summary class="bt-thought-summary">💭 Thinking…</summary>
            <div class="bt-thought-body">${msg.streaming ? '<span class="bt-stream-text"></span>' : (msg.html || '')}</div>
        </details>`;
    }

    _toolHTML(msg) {
        const statusCls = `bt-tool-status bt-status-${msg.status || 'pending'}`;
        const preview   = msg.preview
            ? `<pre class="bt-tool-preview">${_esc(msg.preview)}</pre>` : '';
        return `
            <div class="bt-tool-header">
                <span class="bt-tool-kind">${msg.icon || '⚙'}</span>
                <span class="bt-tool-title">${_esc(msg.title || '')}</span>
                <span class="${statusCls}">${_esc(msg.status || '')}</span>
            </div>${preview}`;
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    _atBottom() {
        const { scrollTop, scrollHeight, clientHeight } = this.container;
        return scrollHeight - scrollTop - clientHeight < 60;
    }

    scrollToBottom() {
        this.container.scrollTop = this.container.scrollHeight;
    }

    _onVPResize() {
        const vv  = window.visualViewport;
        const app = document.querySelector('.bt-app');
        if (app) app.style.height = vv.height + 'px';
        if (this.wasAtBottom) this.scrollToBottom();
    }
}

function _esc(str) {
    return str.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

// Entry point called from Julia evaljs after session is ready
function initBonitoChat(obs) {
    const container = document.querySelector('.bt-messages');
    if (!container) { requestAnimationFrame(() => initBonitoChat(obs)); return; }
    window._bonitochat = new BonitoChat(container, obs);
}

window.BonitoChat     = BonitoChat;
window.initBonitoChat = initBonitoChat;
