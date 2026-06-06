// deno-fmt-ignore-file
// deno-lint-ignore-file
// This code was bundled using `deno bundle` and it's not recommended to edit it manually

class Collapsable {
    constructor(headerEl, bodyEl, opts = {}){
        this.header = headerEl;
        this.body = bodyEl;
        this.toggle = opts.toggleEl || null;
        this.native = opts.native || false;
        this.fetchEachExpand = opts.fetchEachExpand || false;
        this.discardOnCollapse = opts.discardOnCollapse || false;
        this.onExpand = opts.onExpand || null;
        this.lazy = !!this.onExpand;
        this.loaded = !this.lazy;
        this.expanded = false;
        if (this.native) {
            this.details = headerEl.closest('details') || bodyEl.closest('details');
            this.details && this.details.addEventListener('toggle', ()=>this.applyExpanded(this.details.open));
        } else {
            headerEl.style.cursor = 'pointer';
            headerEl.addEventListener('click', ()=>this.applyExpanded(!this.expanded));
        }
    }
    setExpanded(expanded) {
        if (this.native) {
            if (this.details) this.details.open = expanded;
            return;
        }
        this.applyExpanded(expanded);
    }
    applyExpanded(expanded) {
        if (expanded === this.expanded) return;
        this.expanded = expanded;
        if (!this.native) {
            this.header.dataset.expanded = expanded ? 'true' : 'false';
            if (this.toggle) this.toggle.textContent = expanded ? '▼' : '▶';
            this.body.style.display = expanded ? '' : 'none';
        }
        if (expanded) {
            if (this.lazy && (!this.loaded || this.fetchEachExpand)) {
                this.body.innerHTML = '<div class="bt-collapsable-loading">loading…</div>';
                this.onExpand && this.onExpand();
            }
        } else if (this.discardOnCollapse) {
            this.body.innerHTML = '';
            this.loaded = false;
        }
    }
    fill(html) {
        if (html != null) this.body.innerHTML = html;
        this.loaded = true;
    }
}
const TYPE_LABELS = {
    user: 'User',
    agent: 'Agent',
    thought: 'Thoughts',
    plan: 'Todos',
    summary: 'Summaries'
};
const TYPE_ORDER = [
    'user',
    'agent',
    'thought',
    'plan',
    'summary'
];
const filterKey = (msg)=>msg.type === 'tool' ? 'tool:' + (msg.tool || 'other') : msg.type;
const DEFAULT_HIDDEN = [
    'tool:ToolSearch'
];
class BonitoChat {
    constructor(container, comm){
        this.container = container;
        this.comm = comm;
        this.destroyed = false;
        this.cache = new Map();
        this.heights = new Map();
        this.rendered = new Set();
        this.nodeById = new Map();
        this.ros = new Map();
        this.totalCount = 0;
        this.EST_HEIGHT = 80;
        this.OVERSCAN = 8;
        this.initialLoad = false;
        this.ITEM_GAP = parseFloat(getComputedStyle(container).rowGap) || 0;
        this.followMode = true;
        this.unreadCount = 0;
        this.AT_BOTTOM_PX = 20;
        this.spacerTop = container.querySelector('.bt-spacer-top');
        this.spacerBottom = container.querySelector('.bt-spacer-bottom');
        this.toolbarEl = container.parentElement.querySelector('.bt-chat-toolbar');
        this.hiddenTypes = new Set(DEFAULT_HIDDEN);
        this.seenTypes = new Set();
        this.keyByIdx = new Map();
        this.filterRow = null;
        this.optionsRow = null;
        this.nativeImages = true;
        this.nativeVideos = true;
        if (this.toolbarEl) {
            this.filterRow = document.createElement('div');
            this.filterRow.className = 'bt-toolbar-filters';
            this.optionsRow = document.createElement('div');
            this.optionsRow.className = 'bt-toolbar-options';
            this.toolbarEl.append(this.filterRow, this.optionsRow);
            const addOption = (text, checked, onChange)=>{
                const label = document.createElement('label');
                label.className = 'bt-filter-toggle';
                const cb = document.createElement('input');
                cb.type = 'checkbox';
                cb.checked = checked;
                cb.addEventListener('change', ()=>onChange(cb.checked));
                label.append(cb, text);
                this.optionsRow.appendChild(label);
            };
            addOption('Native Images', this.nativeImages, (on)=>this._setNativeMedia('image/', on));
            addOption('Native Videos', this.nativeVideos, (on)=>this._setNativeMedia('video/', on));
        }
        this.busyEl = container.querySelector('.bt-busy');
        this.waitingEl = container.querySelector('.bt-waiting');
        this.thinkingEl = container.querySelector('.bt-thinking');
        this.tailEl = container.querySelector('.bt-messages-tail');
        this._sizeTail();
        this.measureEl = document.createElement('div');
        this.measureEl.className = 'bt-measure';
        container.parentElement.appendChild(this.measureEl);
        this._startSettle();
        comm.on((msg)=>{
            if (this.destroyed) return;
            if (msg && typeof msg === 'object') this.dispatch(msg);
        });
        const cur = comm.value;
        if (cur && cur.type === 'msgs.count' && cur.n > 0) {
            this.applyCount(cur.n);
        } else if (cur && cur.type === 'msgs.range') {
            this._startSettle();
            this.onRange(cur);
            this._startPrefetch();
        }
        comm.notify({
            type: 'init'
        });
        this._lastUserInputT = 0;
        const markUserInput = ()=>{
            this._lastUserInputT = performance.now();
        };
        container.addEventListener('wheel', markUserInput, {
            passive: true
        });
        container.addEventListener('touchstart', markUserInput, {
            passive: true
        });
        container.addEventListener('touchmove', markUserInput, {
            passive: true
        });
        container.addEventListener('keydown', markUserInput, {
            passive: true
        });
        this._markUserInput = markUserInput;
        this._scrollbarDrag = false;
        this._onContainerMouseDown = ()=>{
            this._scrollbarDrag = true;
            markUserInput();
        };
        this._onWindowMouseUp = ()=>{
            if (!this._scrollbarDrag) return;
            this._scrollbarDrag = false;
            markUserInput();
            for (const node of this.cache.values()){
                if (node.isConnected && node.dataset.btAutoExpand) {
                    delete node.dataset.btAutoExpand;
                    node.collapsable?.setExpanded(true);
                }
            }
            this._queueRefresh();
        };
        container.addEventListener('mousedown', this._onContainerMouseDown, {
            passive: true
        });
        window.addEventListener('mouseup', this._onWindowMouseUp, {
            passive: true
        });
        this._onScroll = ()=>{
            const userDriven = this._scrollbarDrag || performance.now() - this._lastUserInputT < 400;
            const atBot = this.atBottom();
            if (userDriven) {
                this.setFollowMode(atBot);
                if (!atBot) this._cancelPendingScroll();
            } else if (this.followMode && !atBot) {
                this._queueScrollToBottom();
            }
            this.refresh();
        };
        container.addEventListener('scroll', this._onScroll, {
            passive: true
        });
        this._containerRO = new ResizeObserver(()=>{
            if (this.destroyed) return;
            this._sizeTail();
            if (this.followMode) this._queueScrollToBottom();
        });
        this._containerRO.observe(this.container);
        if (this.busyEl) this._containerRO.observe(this.busyEl);
        if (this.waitingEl) this._containerRO.observe(this.waitingEl);
        if (this.thinkingEl) this._containerRO.observe(this.thinkingEl);
        if (window.visualViewport) {
            this._onVPResize = ()=>this.onViewportResize();
            window.visualViewport.addEventListener('resize', this._onVPResize);
        }
        Promise.resolve().then(()=>{
            this._setupInputs();
            this._setupLiveTicker();
        });
    }
    destroy() {
        this.destroyed = true;
        if (this._onScroll) {
            this.container.removeEventListener('scroll', this._onScroll);
        }
        if (this._markUserInput) {
            this.container.removeEventListener('wheel', this._markUserInput);
            this.container.removeEventListener('touchstart', this._markUserInput);
            this.container.removeEventListener('touchmove', this._markUserInput);
            this.container.removeEventListener('keydown', this._markUserInput);
        }
        if (this._onContainerMouseDown) {
            this.container.removeEventListener('mousedown', this._onContainerMouseDown);
        }
        if (this._onWindowMouseUp) {
            window.removeEventListener('mouseup', this._onWindowMouseUp);
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
        this.ros.forEach((ro)=>ro.disconnect());
        this.ros.clear();
        if (this._onPaste && this.textInput) {
            this.textInput.removeEventListener('paste', this._onPaste);
        }
        if (this._onTextInputKeyCapture && this.textInput) {
            this.textInput.removeEventListener('keydown', this._onTextInputKeyCapture, true);
        }
        if (this._onAppClickCapture && this.app) {
            this.app.removeEventListener('click', this._onAppClickCapture, true);
        }
        if (this._onEscapeKey) {
            document.removeEventListener('keydown', this._onEscapeKey, true);
        }
        if (this.app) {
            this._onDragOver && this.app.removeEventListener('dragover', this._onDragOver);
            this._onDragLeave && this.app.removeEventListener('dragleave', this._onDragLeave);
            this._onDrop && this.app.removeEventListener('drop', this._onDrop);
        }
        clearTimeout(this._attachErrorTimer);
        clearTimeout(this._prefetchTimer);
        if (!this._settleDone && this._paneEl) delete this._paneEl.dataset.btSettling;
        if (this.measureEl) {
            this.measureEl.remove();
            this.measureEl = null;
        }
        if (this._tickerId) {
            clearInterval(this._tickerId);
            this._tickerId = null;
        }
        if (this.taskbarEl && this._onTaskbarClick) {
            this.taskbarEl.removeEventListener('click', this._onTaskbarClick);
        }
    }
    dispatch(msg) {
        if (typeof msg.n === 'number' && msg.n > this.totalCount) {
            this.totalCount = msg.n;
        }
        switch(msg.type){
            case 'msgs.count':
                return this.applyCount(msg.n);
            case 'msgs.range':
                return this.onRange(msg);
            case 'busy_start':
                this.busyEl?.classList.add('bt-busy-active');
                if (this.followMode) this._queueScrollToBottom();
                return;
            case 'busy_end':
                this.busyEl?.classList.remove('bt-busy-active');
                if (this.followMode) this._queueScrollToBottom();
                return;
            case 'agent_final':
                return this.onAgentFinal(msg);
            case 'thinking':
                return this.onThinking(msg.active);
            case 'thought_final':
                return this.onThoughtFinal(msg);
            case 'thought.body':
                return this.onThoughtBody(msg);
            case 'tool_update':
                return this.onToolUpdate(msg);
            case 'plan_update':
                return this.onPlanUpdate(msg);
            case 'chunk':
                return this.appendChunk(msg);
            case 'user_chunk':
                return this.appendUserChunk(msg.text);
            case 'user_unqueue':
                return this.unqueueOldestUser();
            case 'summary_final':
                return this.onSummaryFinal(msg);
            case 'attach_error':
                return this._showAttachError(msg.error || 'Attachment failed');
            case 'user':
            case 'agent':
            case 'thought':
            case 'tool':
            case 'plan':
            case 'summary':
                return this.appendNewMessage(msg);
        }
    }
    applyCount(n) {
        if (n <= 0) {
            this._startSettle();
            this._settle();
            return;
        }
        this.totalCount = n;
        this.initialLoad = true;
        this._startSettle();
        this.refresh();
        this._startPrefetch();
    }
    _startSettle() {
        if (this._settleWatch || this._settleDone) return;
        this._settleWatch = true;
        this._settleT0 = performance.now();
        this._settleLastH = -1;
        this._settleStable = 0;
        this._paneEl = this.container.closest('.bt-chatpane');
        if (this._paneEl) {
            delete this._paneEl.dataset.btSettled;
            this._paneEl.dataset.btSettling = '1';
        }
        this._announceSettle('bt-chat-settling');
        const watch = ()=>{
            if (this.destroyed || this._settleDone) return;
            const h = this.container.scrollHeight;
            if (h === this._settleLastH) this._settleStable++;
            else {
                this._settleStable = 0;
                this._settleLastH = h;
            }
            const elapsed = performance.now() - this._settleT0;
            const pendingBody = [
                ...this.container.querySelectorAll('.bt-collapsable-loading')
            ].some((el)=>!(el.closest('.bt-tool-msg')?.dataset.showMime || '').startsWith('video/'));
            const pendingImg = [
                ...this.container.querySelectorAll('img')
            ].some((img)=>!img.complete);
            const settled = this._settleStable >= 10 && elapsed > 400 && !this.initialLoad && !pendingBody && !pendingImg;
            if (settled || elapsed > 5000) this._settle();
            else requestAnimationFrame(watch);
        };
        requestAnimationFrame(watch);
    }
    _settle() {
        if (this._settleDone) return;
        this._settleDone = true;
        this._settleWatch = false;
        this.setFollowMode(true);
        this.scrollToBottom();
        if (this._paneEl) {
            delete this._paneEl.dataset.btSettling;
            this._paneEl.dataset.btSettled = '1';
        }
        this._announceSettle('bt-chat-settled');
    }
    _announceSettle(name) {
        const pid = this._paneEl?.dataset.panePid || '';
        window.dispatchEvent(new CustomEvent(name, {
            detail: pid
        }));
    }
    _startPrefetch() {
        if (this._prefetchStarted) return;
        this._prefetchStarted = true;
        this._prefetchTimer = setTimeout(()=>this._prefetchTick(), 600);
    }
    _prefetchTick() {
        if (this.destroyed) return;
        let e = -1;
        for(let i = Math.min(this._prefetchCursor ?? Infinity, this.totalCount - 1); i >= 0; i--){
            if (!this.cache.has(i)) {
                e = i;
                break;
            }
        }
        if (e < 0) return;
        let s = e;
        while(s > 0 && !this.cache.has(s - 1) && e - s < 63)s--;
        this._prefetchCursor = s - 1;
        this._prefetchPending = [
            s,
            e
        ];
        this.comm.notify({
            type: 'msgs.request',
            range: [
                s,
                e
            ]
        });
        clearTimeout(this._prefetchTimer);
        this._prefetchTimer = setTimeout(()=>this._prefetchTick(), 2000);
    }
    visibleRange() {
        if (this.totalCount === 0) return [
            0,
            -1
        ];
        const { scrollTop , clientHeight  } = this.container;
        const over = this.OVERSCAN * this.EST_HEIGHT;
        const s = this.indexAt(Math.max(0, scrollTop - over));
        const e = this.indexAt(scrollTop + clientHeight + over);
        return [
            s,
            Math.min(this.totalCount - 1, e)
        ];
    }
    effHeight(i) {
        if (this.hiddenTypes.has(this.keyByIdx.get(i))) return 0;
        return (this.heights.get(i) ?? this.EST_HEIGHT) + this.ITEM_GAP;
    }
    indexAt(offset) {
        let h = 0;
        for(let i = 0; i < this.totalCount; i++){
            h += this.effHeight(i);
            if (h > offset) return i;
        }
        return Math.max(0, this.totalCount - 1);
    }
    cumHeight(from, to) {
        let h = 0;
        for(let i = from; i < to; i++)h += this.effHeight(i);
        return h;
    }
    refresh() {
        if (this.totalCount === 0) return;
        const wasAtBottom = this.atBottom();
        const preHeight = this.container.scrollHeight;
        const [s, e] = this.visibleRange();
        if (!this._scrollbarDrag) {
            const missing = [];
            for(let i = s; i <= e; i++)if (!this.cache.has(i)) missing.push(i);
            if (missing.length > 0) {
                this.comm.notify({
                    type: 'msgs.request',
                    range: [
                        missing[0],
                        missing[missing.length - 1]
                    ]
                });
            }
        }
        this.updateDOM(s, e);
        if (wasAtBottom && !this._scrollbarDrag && this.container.scrollHeight !== preHeight) {
            this.container.scrollTop = this.container.scrollHeight;
        }
    }
    onRange({ start , msgs  }) {
        const messages = msgs ?? [];
        const fresh = [];
        messages.forEach((data, i)=>{
            const idx = start + i;
            if (this.cache.has(idx)) return;
            const node = this.createNode(data);
            this.cache.set(idx, node);
            this.keyByIdx.set(idx, filterKey(data));
            if (data.id) this.nodeById.set(data.id, node);
            this.observe(idx, node);
            fresh.push([
                idx,
                node
            ]);
        });
        this._measureNodes(fresh);
        if (this._prefetchStarted) {
            clearTimeout(this._prefetchTimer);
            this._prefetchTimer = setTimeout(()=>this._prefetchTick(), 30);
        }
        const pf = this._prefetchPending;
        if (pf && start === pf[0]) {
            this._prefetchPending = null;
            const [vs, ve] = this.visibleRange();
            const end = start + messages.length - 1;
            if (end >= vs && start <= ve && !this._scrollbarDrag) {
                this.updateDOM(vs, ve);
            }
            return;
        }
        if (this._scrollbarDrag) return;
        this.updateDOM(...this.visibleRange());
        if (this.initialLoad) {
            this.initialLoad = true;
            this.setFollowMode(true);
            this.scrollToBottom();
            requestAnimationFrame(()=>{
                if (!this.destroyed && this.followMode) this.scrollToBottom();
            });
            setTimeout(()=>{
                if (!this.destroyed && this.followMode) this.scrollToBottom();
            }, 100);
            setTimeout(()=>{
                if (!this.destroyed && this.followMode) this.scrollToBottom();
                this.initialLoad = false;
            }, 300);
        } else if (this.followMode) {
            this._queueScrollToBottom();
        }
    }
    _measureNodes(pairs) {
        if (!this.measureEl || pairs.length === 0) return;
        const cs = getComputedStyle(this.container);
        const w = this.container.clientWidth - (parseFloat(cs.paddingLeft) || 0) - (parseFloat(cs.paddingRight) || 0);
        if (w <= 0) return;
        this.measureEl.style.width = w + 'px';
        const toMeasure = pairs.filter(([idx, node])=>!node.isConnected && !this.heights.has(idx));
        for (const [, node] of toMeasure)this.measureEl.appendChild(node);
        for (const [idx, node] of toMeasure){
            const h = node.offsetHeight;
            if (h > 0) this.heights.set(idx, h);
        }
        for (const [, node] of toMeasure){
            if (node.parentNode === this.measureEl) this.measureEl.removeChild(node);
        }
    }
    observe(idx, node) {
        const ro = new ResizeObserver(([e])=>{
            const h = e.contentRect.height;
            if (h > 0 && this.heights.get(idx) !== h) {
                this.heights.set(idx, h);
                if (!this._scrollbarDrag) this._queueRefresh();
            }
        });
        ro.observe(node);
        this.ros.set(idx, ro);
    }
    _queueRefresh() {
        if (this._refreshQueued || this.destroyed) return;
        this._refreshQueued = true;
        requestAnimationFrame(()=>{
            this._refreshQueued = false;
            if (!this.destroyed) this.refresh();
        });
    }
    updateDOM(s, e) {
        if (s > e) return;
        for (const idx of [
            ...this.rendered
        ]){
            if (idx < s || idx > e) {
                this.cache.get(idx)?.remove();
                this.rendered.delete(idx);
            }
        }
        for(let i = s; i <= e; i++){
            if (this.cache.has(i) && !this.rendered.has(i)) {
                this.insertSorted(i, this.cache.get(i));
                this.rendered.add(i);
            }
        }
        this.spacerTop.style.height = this.cumHeight(0, s) + 'px';
        this.spacerBottom.style.height = this.cumHeight(e + 1, this.totalCount) + 'px';
    }
    insertSorted(idx, node) {
        const sorted = [
            ...this.rendered
        ].filter((i)=>i > idx).sort((a, b)=>a - b);
        const before = sorted.length ? this.cache.get(sorted[0]) : this.spacerBottom;
        this.container.insertBefore(node, before);
        if (node.dataset && node.dataset.btAutoExpand && !this._scrollbarDrag) {
            delete node.dataset.btAutoExpand;
            node.collapsable?.setExpanded(true);
        }
    }
    appendNewMessage(msg) {
        const idx = this.totalCount - 1;
        if (!this.cache.has(idx)) {
            const node = this.createNode(msg);
            this.cache.set(idx, node);
            this.keyByIdx.set(idx, filterKey(msg));
            if (msg.id) this.nodeById.set(msg.id, node);
            this.observe(idx, node);
        }
        if (this.followMode) {
            this.scrollToBottom();
        } else {
            this._registerUnread();
        }
    }
    appendChunk(msg) {
        const node = this.nodeById.get(msg.id);
        if (!node) return;
        if (msg.html !== undefined) {
            node.innerHTML = msg.html;
        } else if (msg.text !== undefined) {
            const t = node.querySelector('.bt-stream-text');
            if (t) t.textContent += msg.text;
        }
        if (this.followMode) {
            this._queueScrollToBottom();
        } else {
            this._registerUnread();
        }
    }
    appendUserChunk(text) {
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
        node && node.collapsable && node.collapsable.fill(msg.html || '');
    }
    onThoughtBody(msg) {
        const node = this.nodeById.get(msg.id);
        node && node.collapsable && node.collapsable.fill(msg.html);
    }
    onThinking(active) {
        if (this.thinkingEl) this.thinkingEl.classList.toggle('bt-thinking-active', !!active);
        if (active && this.followMode) this._queueScrollToBottom();
    }
    onToolUpdate(msg) {
        const node = this.nodeById.get(msg.id);
        if (!node) return;
        if (msg.status) {
            const s = node.querySelector('.bt-tool-status');
            if (s) {
                s.textContent = msg.status;
                s.className = `bt-tool-status bt-status-${msg.status}`;
            }
            const live = !(msg.status === 'completed' || msg.status === 'failed');
            node.classList.toggle('bt-tool-live', live);
        }
        if (msg.finished_at != null) {
            node.dataset.toolFinished = String(msg.finished_at);
            node.classList.remove('bt-tool-live');
        }
        if (msg.title) {
            const t = node.querySelector('.bt-tool-title');
            if (t) t.textContent = msg.title;
        }
        if (msg.summary != null) {
            const s = node.querySelector('.bt-tool-summary');
            if (s) s.textContent = msg.summary;
        }
        if (msg.preview != null) {
            let prev = node.querySelector('.bt-edit-preview');
            if (!prev) {
                prev = document.createElement('div');
                prev.className = 'bt-edit-preview';
                const header = node.querySelector('.bt-tool-header');
                if (header) header.insertAdjacentElement('afterend', prev);
            }
            prev.innerHTML = msg.preview;
        }
        if (msg.show_mime) node.dataset.showMime = msg.show_mime;
        if (this._wantsNative(node)) {
            this._applyNative(node);
        } else if (msg.expand && node.collapsable) {
            if (node.isConnected) node.collapsable.setExpanded(true);
            else node.dataset.btAutoExpand = '1';
        }
        if (msg.taskbar) node.dataset.toolTaskbar = '1';
        this._refreshTaskbar();
    }
    noteKey(msg) {
        const key = filterKey(msg);
        if (!key || this.seenTypes.has(key) || !this.filterRow) return;
        this.seenTypes.add(key);
        if (key === 'agent') this._updateWaiting();
        const isTool = key.startsWith('tool:');
        const text = isTool ? key.slice(5) : TYPE_LABELS[key] ?? key;
        const label = document.createElement('label');
        label.className = 'bt-filter-toggle';
        label.dataset.key = key;
        const cb = document.createElement('input');
        cb.type = 'checkbox';
        cb.checked = !this.hiddenTypes.has(key);
        cb.addEventListener('change', ()=>this.setKeyHidden(key, !cb.checked));
        label.append(cb, text);
        const toggles = ()=>[
                ...this.filterRow.querySelectorAll('.bt-filter-toggle')
            ];
        if (isTool) {
            this.ensureToolGroupLabel();
            const next = toggles().find((el)=>el.dataset.key.startsWith('tool:') && el.dataset.key.slice(5).localeCompare(text) > 0);
            this.filterRow.insertBefore(label, next ?? null);
        } else {
            const order = (t)=>{
                const i = TYPE_ORDER.indexOf(t);
                return i < 0 ? TYPE_ORDER.length : i;
            };
            const next = toggles().find((el)=>!el.dataset.key.startsWith('tool:') && order(el.dataset.key) > order(key)) ?? this.filterRow.querySelector('.bt-filter-group-label');
            this.filterRow.insertBefore(label, next ?? null);
        }
    }
    ensureToolGroupLabel() {
        if (this.filterRow.querySelector('.bt-filter-group-label')) return;
        const span = document.createElement('span');
        span.className = 'bt-filter-group-label';
        span.textContent = 'Tools:';
        this.filterRow.appendChild(span);
    }
    _wantsNative(node) {
        const mime = node.dataset.showMime || '';
        if (mime.startsWith('image/')) return this.nativeImages;
        if (mime.startsWith('video/')) return this.nativeVideos;
        return false;
    }
    _applyNative(node) {
        node.classList.add('bt-tool-native');
        if (node.isConnected) {
            node.collapsable?.setExpanded(true);
        } else {
            node.dataset.btAutoExpand = '1';
        }
    }
    _removeNative(node) {
        node.classList.remove('bt-tool-native');
        delete node.dataset.btAutoExpand;
        node.collapsable?.setExpanded(false);
    }
    _setNativeMedia(prefix, on) {
        if (prefix === 'image/') this.nativeImages = on;
        else this.nativeVideos = on;
        for (const node of this.cache.values()){
            if (!(node.dataset.showMime || '').startsWith(prefix)) continue;
            on ? this._applyNative(node) : this._removeNative(node);
        }
        this.refresh();
    }
    setKeyHidden(key, hidden) {
        this.hiddenTypes[hidden ? 'add' : 'delete'](key);
        for (const node of this.cache.values()){
            if (node.dataset.filterKey === key) node.style.display = hidden ? 'none' : '';
        }
        if (key === 'agent') this._updateWaiting();
        this.refresh();
        if (this.followMode) this._queueScrollToBottom();
    }
    _updateWaiting() {
        if (!this.waitingEl) return;
        const on = this.seenTypes.has('agent') && !this.hiddenTypes.has('agent');
        this.waitingEl.classList.toggle('bt-waiting-on', on);
    }
    createNode(msg) {
        const div = document.createElement('div');
        const fkey = filterKey(msg);
        div.dataset.filterKey = fkey;
        this.noteKey(msg);
        switch(msg.type){
            case 'user':
                div.className = 'bt-user-msg';
                if (msg.queued) div.classList.add('bt-queued');
                div.textContent = msg.text;
                break;
            case 'agent':
                div.className = 'bt-agent-msg';
                if (msg.streaming) {
                    const span = document.createElement('span');
                    span.className = 'bt-stream-text';
                    if (msg.text) span.textContent = msg.text;
                    div.appendChild(span);
                } else {
                    div.innerHTML = msg.html || '';
                }
                break;
            case 'thought':
                {
                    div.className = 'bt-thought-msg';
                    div.innerHTML = this.thoughtHTML(msg);
                    const id = msg.id;
                    div.collapsable = new Collapsable(div.querySelector('.bt-thought-summary'), div.querySelector('.bt-thought-body'), {
                        native: true,
                        onExpand: ()=>this.comm.notify({
                                type: 'thought.render',
                                id
                            })
                    });
                    if (msg.html) div.collapsable.fill(msg.html);
                    break;
                }
            case 'tool':
                {
                    div.className = 'bt-tool-msg';
                    div.innerHTML = this.toolHTML(msg);
                    if (msg.id) div.dataset.msgId = msg.id;
                    if (msg.started_at != null) div.dataset.toolStarted = String(msg.started_at);
                    if (msg.finished_at != null) div.dataset.toolFinished = String(msg.finished_at);
                    if (msg.taskbar) div.dataset.toolTaskbar = '1';
                    const liveTool = !(msg.status === 'completed' || msg.status === 'failed') && msg.finished_at == null;
                    if (liveTool) div.classList.add('bt-tool-live');
                    const id = msg.id;
                    div.collapsable = new Collapsable(div.querySelector('.bt-tool-header'), div.querySelector('.bt-tool-body'), {
                        toggleEl: div.querySelector('.bt-tool-toggle'),
                        fetchEachExpand: true,
                        discardOnCollapse: true,
                        onExpand: ()=>this.comm.notify({
                                type: 'tool.render',
                                id
                            })
                    });
                    const detachBtn = div.querySelector('.bt-tool-detach');
                    if (detachBtn) detachBtn.addEventListener('click', (e)=>{
                        e.stopPropagation();
                        window._btPopup && window._btPopup.detach(id);
                    });
                    const wideBtn = div.querySelector('.bt-tool-fullwidth');
                    if (wideBtn) wideBtn.addEventListener('click', (e)=>{
                        e.stopPropagation();
                        const active = div.classList.toggle('bt-tool-wide-active');
                        wideBtn.textContent = active ? '«' : '»';
                        wideBtn.title = active ? 'Collapse to default width' : 'Expand to full chat width';
                    });
                    if (msg.show_mime) div.dataset.showMime = msg.show_mime;
                    if (this._wantsNative(div)) {
                        div.classList.add('bt-tool-native');
                        div.dataset.btAutoExpand = '1';
                    } else if (msg.expand) {
                        div.dataset.btAutoExpand = '1';
                    }
                    break;
                }
            case 'plan':
                {
                    div.className = 'bt-plan-msg';
                    div.innerHTML = msg.html || '';
                    if (msg.id) div.dataset.msgId = msg.id;
                    if (msg.started_at != null) div.dataset.planStarted = String(msg.started_at);
                    if (msg.finished_at != null) div.dataset.planFinished = String(msg.finished_at);
                    if (msg.summary) div.dataset.planSummary = msg.summary;
                    if (msg.live) div.classList.add('bt-plan-live');
                    break;
                }
            case 'summary':
                {
                    div.className = 'bt-summary-msg';
                    const inner = document.createElement('div');
                    inner.className = 'bt-summary-body';
                    if (msg.streaming && !msg.html) {
                        inner.textContent = 'Session continued — summary loading…';
                    } else {
                        inner.innerHTML = msg.html || '';
                    }
                    div.appendChild(inner);
                    break;
                }
        }
        if (this.hiddenTypes.has(fkey)) div.style.display = 'none';
        return div;
    }
    unqueueOldestUser() {
        const q = this.container.querySelector('.bt-user-msg.bt-queued');
        if (q) q.classList.remove('bt-queued');
    }
    onSummaryFinal(msg) {
        const nodes = this.container.querySelectorAll('.bt-summary-msg .bt-summary-body');
        const tgt = nodes[nodes.length - 1];
        if (tgt) tgt.innerHTML = msg.html || '';
    }
    thoughtHTML(msg) {
        const summary = msg.summary || 'Show thinking';
        return `<details class="bt-thought-details" data-thought-id="${escapeAttr(msg.id || '')}">
            <summary class="bt-thought-summary">💭 ${escapeHTML(summary)}</summary>
            <div class="bt-thought-body">${msg.html || ''}</div>
        </details>`;
    }
    toolHTML(msg) {
        const statusCls = `bt-tool-status bt-status-${msg.status || 'pending'}`;
        const preview = msg.preview ? `<div class="bt-edit-preview">${msg.preview}</div>` : '';
        const server = msg.server ? `<span class="bt-tool-server">${escapeHTML(msg.server)}</span>` : '';
        return `
            <div class="bt-tool-header" data-expanded="false">
                <span class="bt-tool-toggle">▶</span>
                <span class="bt-tool-kind">${msg.icon || '⚙'}</span>
                ${server}
                <span class="bt-tool-title">${escapeHTML(msg.title || '')}</span>
                <span class="bt-tool-summary">${escapeHTML(msg.summary || '')}</span>
                <span class="bt-tool-timer"></span>
                <span class="${statusCls}">${escapeHTML(msg.status || '')}</span>
                ${msg.kind === 'bonito_app' ? `<button class="bt-tool-detach" type="button"
                              title="Detach to floating window">⤢</button>` : ''}
            </div>
            ${preview}
            <div class="bt-tool-body" data-tool-id="${escapeAttr(msg.id || '')}"></div>
            <button class="bt-tool-fullwidth" type="button"
                    title="Expand to full chat width">»</button>`;
    }
    onPlanUpdate(msg) {
        const node = this.nodeById.get(msg.id);
        if (!node) return;
        if (msg.html != null) node.innerHTML = msg.html;
        if (msg.started_at != null) node.dataset.planStarted = String(msg.started_at);
        if (msg.finished_at != null) {
            node.dataset.planFinished = String(msg.finished_at);
            node.classList.remove('bt-plan-live');
        } else if (msg.live === false) {
            node.classList.remove('bt-plan-live');
        } else if (msg.live === true) {
            node.classList.add('bt-plan-live');
        }
        if (msg.summary) node.dataset.planSummary = msg.summary;
        this._refreshTaskbar();
    }
    _setupLiveTicker() {
        this.taskbarEl = this.app ? this.app.querySelector('.bt-taskbar') : this.container.parentElement.querySelector('.bt-taskbar');
        if (!this.taskbarEl) return;
        this._onTaskbarClick = (ev)=>{
            const stopBtn = ev.target.closest('.bt-taskbar-slot-stop');
            if (stopBtn) {
                ev.stopPropagation();
                const slot = stopBtn.closest('.bt-taskbar-slot');
                const id = slot?.dataset.targetId;
                if (id) this.comm.notify({
                    type: 'stop_tool',
                    id
                });
                return;
            }
            const slot = ev.target.closest('.bt-taskbar-slot');
            if (!slot) return;
            const id = slot.dataset.targetId;
            if (!id) return;
            const target = this.nodeById.get(id);
            if (target) target.scrollIntoView({
                block: 'center',
                behavior: 'smooth'
            });
        };
        this.taskbarEl.addEventListener('click', this._onTaskbarClick);
        this._tickerId = setInterval(()=>this._tickLiveTimers(), 1000);
        this._refreshTaskbar();
    }
    _tickLiveTimers() {
        if (this.destroyed) return;
        const now = Date.now() / 1000;
        for (const el of this.container.querySelectorAll('div.bt-tool-msg.bt-tool-live, div.bt-plan-msg.bt-plan-live')){
            const started = parseFloat(el.dataset.toolStarted ?? el.dataset.planStarted ?? '0');
            if (!started) continue;
            const elapsed = now - started;
            const timer = el.querySelector('.bt-tool-timer');
            if (timer) timer.textContent = elapsed > 1 ? _formatElapsed(elapsed) : '';
        }
        for (const slot of this.taskbarEl.querySelectorAll('.bt-taskbar-slot')){
            const started = parseFloat(slot.dataset.started ?? '0');
            if (!started) continue;
            const elapsed = now - started;
            const t = slot.querySelector('.bt-taskbar-slot-timer');
            if (t) t.textContent = elapsed > 1 ? _formatElapsed(elapsed) : '';
        }
    }
    _refreshTaskbar() {
        if (this.destroyed || !this.taskbarEl) return;
        const live = this.container.querySelectorAll('div.bt-tool-msg.bt-tool-live[data-tool-taskbar], div.bt-plan-msg.bt-plan-live');
        if (live.length === 0) {
            this.taskbarEl.replaceChildren();
            return;
        }
        const frag = document.createDocumentFragment();
        for (const el of live){
            const id = el.dataset.msgId;
            if (!id) continue;
            const isPlan = el.classList.contains('bt-plan-msg');
            const icon = isPlan ? '📋' : el.querySelector('.bt-tool-kind')?.textContent || '⚙';
            const label = isPlan ? el.dataset.planSummary || 'Todo list' : el.querySelector('.bt-tool-title')?.textContent || 'Tool';
            const started = isPlan ? el.dataset.planStarted : el.dataset.toolStarted;
            const slot = document.createElement('div');
            slot.className = 'bt-taskbar-slot';
            slot.dataset.targetId = id;
            if (started) slot.dataset.started = started;
            const stop = isPlan ? '' : `<span class="bt-taskbar-slot-stop" title="Ask Claude to stop this">⊗</span>`;
            slot.innerHTML = `<span class="bt-taskbar-slot-icon">${icon}</span>` + `<span class="bt-taskbar-slot-label"></span>` + `<span class="bt-taskbar-slot-timer"></span>` + stop;
            slot.querySelector('.bt-taskbar-slot-label').textContent = label;
            frag.appendChild(slot);
        }
        this.taskbarEl.replaceChildren(frag);
        this._tickLiveTimers();
    }
    _sizeTail() {
        if (!this.tailEl) return;
        this.tailEl.style.height = Math.round(this.container.clientHeight * 0.3) + 'px';
    }
    atBottom() {
        const { scrollTop , scrollHeight , clientHeight  } = this.container;
        return scrollHeight - scrollTop - clientHeight < this.AT_BOTTOM_PX;
    }
    _queueScrollToBottom() {
        if (this._scrollbarDrag) return;
        if (this._scrollQueued || this.destroyed) return;
        this._scrollQueued = true;
        this._scrollRafId = requestAnimationFrame(()=>{
            this._scrollQueued = false;
            this._scrollRafId = null;
            if (!this.destroyed) this.scrollToBottom();
        });
    }
    scrollToBottom() {
        if (this._scrollbarDrag) return;
        this.container.scrollTop = this.container.scrollHeight;
        const anchor = this.tailEl || this.spacerBottom;
        if (anchor) {
            anchor.scrollIntoView({
                block: 'end',
                behavior: 'auto'
            });
        }
        this.refresh();
    }
    _setupInputs() {
        if (this.destroyed) return;
        const app = this.container?.parentElement;
        if (!app) return;
        this.app = app;
        this.inputArea = app.querySelector('.bt-input-area');
        this.textInput = app.querySelector('.bt-text-input');
        if (!this.inputArea || !this.textInput) return;
        this.attachBar = document.createElement('div');
        this.attachBar.className = 'bt-attachments';
        this.inputArea.insertBefore(this.attachBar, this.inputArea.firstChild);
        this.attachments = new Map();
        this._attachIdCounter = 0;
        this.ATTACH_MAX_BYTES = 5 * 1024 * 1024;
        this._onPaste = (e)=>{
            const items = e.clipboardData?.items;
            if (!items) return;
            for (const it of items){
                if (it.kind === 'file' && it.type && it.type.startsWith('image/')) {
                    const blob = it.getAsFile();
                    if (blob) this._attachAddBlob(blob, blob.type || it.type, blob.name || `pasted-${Date.now()}.png`);
                }
            }
        };
        this.textInput.addEventListener('paste', this._onPaste);
        this._onDragOver = (e)=>{
            if (!this._dragHasImage(e)) return;
            e.preventDefault();
            this.app.classList.add('bt-drag-over');
        };
        this._onDragLeave = (e)=>{
            if (e.relatedTarget && this.app.contains(e.relatedTarget)) return;
            this.app.classList.remove('bt-drag-over');
        };
        this._onDrop = (e)=>{
            e.preventDefault();
            this.app.classList.remove('bt-drag-over');
            const files = e.dataTransfer?.files;
            if (!files) return;
            for (const f of files){
                if (f.type && f.type.startsWith('image/')) {
                    this._attachAddBlob(f, f.type, f.name || `dropped-${Date.now()}.png`);
                }
            }
        };
        this.app.addEventListener('dragover', this._onDragOver);
        this.app.addEventListener('dragleave', this._onDragLeave);
        this.app.addEventListener('drop', this._onDrop);
        this._onAppClickCapture = (e)=>{
            if (this.destroyed) return;
            if (e.target.closest('.bt-send-btn')) {
                e.preventDefault();
                e.stopImmediatePropagation();
                this._submit();
            } else if (e.target.closest('.bt-stop-btn')) {
                e.preventDefault();
                e.stopImmediatePropagation();
                this._cancel();
            }
        };
        this.app.addEventListener('click', this._onAppClickCapture, true);
        this._onTextInputKeyCapture = (e)=>{
            if (e.key !== 'Enter' || e.shiftKey) return;
            e.preventDefault();
            e.stopImmediatePropagation();
            this._submit();
        };
        this.textInput.addEventListener('keydown', this._onTextInputKeyCapture, true);
        this._onEscapeKey = (e)=>{
            if (e.key !== 'Escape' || e.repeat) return;
            const t = e.target;
            if (t && t.closest && t.closest('.monaco-editor')) return;
            e.preventDefault();
            this._cancel();
        };
        document.addEventListener('keydown', this._onEscapeKey, true);
    }
    _cancel() {
        this.comm.notify({
            type: 'cancel'
        });
    }
    _dragHasImage(e) {
        const dt = e.dataTransfer;
        if (!dt) return false;
        if (dt.types) {
            for (const t of dt.types)if (t === 'Files') return true;
        }
        return false;
    }
    _attachAddBlob(blob, mime, filename) {
        if (blob.size > this.ATTACH_MAX_BYTES) {
            this._showAttachError(`Image too large (${(blob.size / 1024 / 1024).toFixed(1)} MB, ` + `max ${this.ATTACH_MAX_BYTES / 1024 / 1024} MB)`);
            return;
        }
        const id = `att-${++this._attachIdCounter}`;
        const reader = new FileReader();
        reader.onload = ()=>{
            if (this.destroyed) return;
            this.attachments.set(id, {
                blob,
                mime,
                filename,
                dataUrl: reader.result
            });
            this._renderAttachments();
        };
        reader.onerror = ()=>this._showAttachError('Failed to read image');
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
        const err = this.attachBar.querySelector('.bt-attach-error');
        this.attachBar.innerHTML = '';
        if (this.attachments.size === 0) {
            this.attachBar.classList.remove('bt-attachments-active');
        } else {
            this.attachBar.classList.add('bt-attachments-active');
            for (const [id, item] of this.attachments){
                const wrap = document.createElement('div');
                wrap.className = 'bt-attachment-thumb';
                wrap.dataset.attachId = id;
                const img = document.createElement('img');
                img.src = item.dataUrl;
                img.alt = item.filename || 'image';
                img.title = item.filename || 'image';
                wrap.appendChild(img);
                const rm = document.createElement('button');
                rm.type = 'button';
                rm.className = 'bt-attachment-remove';
                rm.title = 'Remove';
                rm.textContent = '×';
                rm.addEventListener('click', (e)=>{
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
        this._attachErrorTimer = setTimeout(()=>{
            chip.remove();
            if (this.attachments.size === 0) {
                this.attachBar.classList.remove('bt-attachments-active');
            }
        }, 4500);
    }
    async _submit() {
        const text = this.textInput.value;
        if (text.trim() === '' && this.attachments.size === 0) return;
        const payload = [];
        for (const item of this.attachments.values()){
            const buf = await item.blob.arrayBuffer();
            payload.push({
                mime: item.mime,
                filename: item.filename || '',
                data: arrayBufferToBase64(buf)
            });
        }
        this.comm.notify({
            type: 'send',
            text,
            attachments: payload
        });
        this.textInput.value = '';
        this.textInput.dispatchEvent(new Event('input', {
            bubbles: true
        }));
        this._attachClear();
    }
    onViewportResize() {
        const vv = window.visualViewport;
        const app = document.querySelector('.bt-app');
        if (app) app.style.height = vv.height + 'px';
        if (this.followMode) this._queueScrollToBottom();
    }
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
    _createNewMessagePill() {
        const app = this.container?.parentElement;
        if (!app) return;
        const pill = document.createElement('button');
        pill.type = 'button';
        pill.className = 'bt-new-msg-pill';
        pill.innerHTML = '<span class="bt-new-msg-pill-arrow">↓</span>' + '<span>New messages</span>';
        pill.addEventListener('click', (e)=>{
            e.preventDefault();
            this.setFollowMode(true);
            this.scrollToBottom();
        });
        app.appendChild(pill);
        this._pillEl = pill;
    }
}
function escapeHTML(str) {
    return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
function escapeAttr(str) {
    return escapeHTML(str).replace(/"/g, '&quot;');
}
function _formatElapsed(sec) {
    if (sec < 60) return `${Math.round(sec)}s`;
    const m = Math.floor(sec / 60);
    const s = Math.round(sec - m * 60);
    return s === 0 ? `${m}m` : `${m}m${s}s`;
}
function arrayBufferToBase64(buf) {
    const bytes = new Uint8Array(buf);
    let binary = '';
    const CHUNK = 0x8000;
    for(let i = 0; i < bytes.length; i += CHUNK){
        binary += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
    }
    return btoa(binary);
}
const CHAT_INSTANCES = new Set();
window._btToolSlot = (id)=>{
    const direct = document.querySelector(`.bt-tool-body[data-tool-id="${CSS.escape(id)}"]`);
    if (direct) return direct;
    for (const chat of CHAT_INSTANCES){
        const node = chat.nodeById.get(id);
        const slot = node && node.querySelector('.bt-tool-body');
        if (slot) return slot;
    }
    return null;
};
function connect(node, comm) {
    const chat = new BonitoChat(node, comm);
    node.__bt_chat = chat;
    CHAT_INSTANCES.add(chat);
    const parent = node.parentNode;
    if (parent) {
        const mo = new MutationObserver(()=>{
            if (!node.isConnected) {
                try {
                    chat.destroy();
                } catch (_) {}
                CHAT_INSTANCES.delete(chat);
                mo.disconnect();
            }
        });
        mo.observe(parent, {
            childList: true
        });
    }
    return chat;
}
export { BonitoChat as BonitoChat };
export { Collapsable as Collapsable };
export { connect as connect };

