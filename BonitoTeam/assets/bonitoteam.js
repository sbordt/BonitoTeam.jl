// BonitoTeam.js — client-side chat: virtual scroll, DOM windowing, streaming.
// Tool-call bodies are lazy: collapsed by default, expand fires `requestToolRender(id)`
// which reaches Julia; Julia answers via Bonito.dom_in_js by inserting a fully-
// mounted Bonito sub-DOM (Monaco editors etc.) into the matching placeholder.

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
        obs.totalCount.on(n      => { this.totalCount = n; this.refresh(); });
        obs.newMsg.on(str        => { if (str) this.handleNewMsg(JSON.parse(str)); });
        obs.rangeResponse.on(str => { if (str) this.onRange(JSON.parse(str)); });

        // Bootstrap history on page load — totalCount.on only fires on future changes
        if (obs.initialCount > 0) {
            this.totalCount  = obs.initialCount;
            this.initialLoad = true;
            this.refresh();
        }

        // Scroll
        container.addEventListener('scroll', () => {
            this.wasAtBottom = this.atBottom();
            this.refresh();
        }, { passive: true });

        // Mobile: keep input visible when virtual keyboard opens
        if (window.visualViewport) {
            window.visualViewport.addEventListener('resize', () => this.onViewportResize());
        }
    }

    // Range / virtual scroll

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
        if (missing.length > 0)
            this.obs.requestRange.notify([missing[0], missing[missing.length - 1]]);

        this.updateDOM(s, e);
    }

    onRange({ start, messages }) {
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
            this.scrollToBottom();
            this.initialLoad = false;
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

    // New messages + streaming

    handleNewMsg(msg) {
        if (msg.type === 'busy_start') { this.busyEl?.classList.add('bt-busy-active');    return; }
        if (msg.type === 'busy_end')   { this.busyEl?.classList.remove('bt-busy-active'); return; }

        if (msg.type === 'agent_final') {
            const node = this.nodeById.get(msg.id);
            if (node) { node.innerHTML = msg.html; }
            return;
        }

        if (msg.type === 'thought_final') {
            // Streaming finished. The body holds the live <span class="bt-stream-text">
            // accumulator; if msg.html is present (legacy path), use it. Otherwise
            // mark the node as ready for lazy fetch — body will be re-fetched when
            // the user expands the <details>.
            const node = this.nodeById.get(msg.id);
            if (node) {
                if (msg.html) {
                    const body = node.querySelector('.bt-thought-body');
                    if (body) body.innerHTML = msg.html;
                }
                const details = node.querySelector('.bt-thought-details');
                if (details) details.dataset.streamed = 'true';
            }
            return;
        }

        if (msg.type === 'thought_body') {
            // Response from requestThoughtRender — fill the lazy body.
            const node = this.nodeById.get(msg.id);
            if (node) {
                const body = node.querySelector('.bt-thought-body');
                if (body) {
                    body.innerHTML = msg.html;
                    body.dataset.loaded = 'true';
                }
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
            if (msg.summary != null) {
                const s = node.querySelector('.bt-tool-summary');
                if (s) s.textContent = msg.summary;
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

        const idx = this.totalCount - 1;
        if (!this.cache.has(idx)) {
            const node = this.createNode(msg);
            this.cache.set(idx, node);
            if (msg.id) this.nodeById.set(msg.id, node);
            this.observe(idx, node);
        }
        if (this.wasAtBottom) {
            this.updateDOM(...this.visibleRange());
            this.scrollToBottom();
        }
    }

    // DOM node creation

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
        // Streaming: live accumulator via bt-stream-text.
        // Historical: empty body, lazy-loaded on expand by wireThoughtToggle.
        // Legacy (msg.html present): just render it.
        const body = msg.streaming ? '<span class="bt-stream-text"></span>' :
                     msg.html      ? msg.html : '';
        const summary = msg.streaming ? 'Thinking…' :
                        (msg.summary || 'Show thinking');
        return `<details class="bt-thought-details" data-thought-id="${escapeAttr(msg.id || '')}">
            <summary class="bt-thought-summary">💭 ${escapeHTML(summary)}</summary>
            <div class="bt-thought-body" data-loaded="${msg.streaming || msg.html ? 'true' : 'false'}">${body}</div>
        </details>`;
    }

    // On first expand of a non-streaming thought, ask Julia for the body.
    // Subsequent expands reuse the cached HTML in the body div.
    wireThoughtToggle(node, thoughtId) {
        const details = node.querySelector('.bt-thought-details');
        const body    = node.querySelector('.bt-thought-body');
        if (!details || !body) return;
        details.addEventListener('toggle', () => {
            if (!details.open) return;                // collapsing
            if (body.dataset.loaded === 'true') return;   // already have HTML
            body.innerHTML = '<span class="bt-thought-loading">loading…</span>';
            this.obs.requestThoughtRender?.notify(thoughtId);
        });
    }

    // Tool block: header + empty placeholder. Body is fetched lazily on expand.
    toolHTML(msg) {
        const statusCls = `bt-tool-status bt-status-${msg.status || 'pending'}`;
        return `
            <div class="bt-tool-header" data-expanded="false">
                <span class="bt-tool-toggle">▶</span>
                <span class="bt-tool-kind">${msg.icon || '⚙'}</span>
                <span class="bt-tool-title">${escapeHTML(msg.title || '')}</span>
                <span class="bt-tool-summary">${escapeHTML(msg.summary || '')}</span>
                <span class="${statusCls}">${escapeHTML(msg.status || '')}</span>
            </div>
            <div class="bt-tool-body" data-tool-id="${escapeAttr(msg.id || '')}"></div>`;
    }

    // Wire the click-to-expand on the tool header. On expand, ask Julia to
    // ship the rendered body (Bonito.dom_in_js will inject it into the body
    // div). On collapse, blank the body div so Monaco editors etc. drop out
    // of the DOM.
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
                this.obs.requestToolRender.notify(toolId);
                header.dataset.expanded = 'true';
                toggle.textContent = '▼';
            }
        });
    }

    // Helpers

    atBottom() {
        const { scrollTop, scrollHeight, clientHeight } = this.container;
        return scrollHeight - scrollTop - clientHeight < 60;
    }

    scrollToBottom() {
        this.container.scrollTop = this.container.scrollHeight;
    }

    onViewportResize() {
        const vv  = window.visualViewport;
        const app = document.querySelector('.bt-app');
        if (app) app.style.height = vv.height + 'px';
        if (this.wasAtBottom) this.scrollToBottom();
    }
}

function escapeHTML(str) {
    return String(str).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}
function escapeAttr(str) {
    return escapeHTML(str).replace(/"/g, '&quot;');
}

// Entry point called from Julia evaljs after session is ready
function initBonitoChat(obs) {
    const container = document.querySelector('.bt-messages');
    if (!container) { requestAnimationFrame(() => initBonitoChat(obs)); return; }
    window.bonitochat = new BonitoChat(container, obs);
}

window.BonitoChat     = BonitoChat;
window.initBonitoChat = initBonitoChat;
