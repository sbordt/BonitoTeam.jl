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

// One reusable collapsible-section behaviour, shared by tool rows and thought
// bubbles (and any future lazy section). It owns the expand/collapse plus the
// lazy-body lifecycle that used to be duplicated across wireToolToggle /
// setToolExpanded / wireThoughtToggle:
//   • a header click (or, in `native` mode, a <details> `toggle`) flips expanded
//   • the first expand of a lazy section shows a "loading…" placeholder and
//     fires `onExpand` once; the owner fills the body (via dom_in_js or a comm
//     reply) and `fill()` marks it loaded so a re-expand doesn't refetch
//   • `fetchEachExpand` (tools) refetches on every expand and `discardOnCollapse`
//     empties the body on collapse (frees the mounted Monaco editors)
export class Collapsable {
    constructor(headerEl, bodyEl, opts = {}) {
        this.header  = headerEl;
        this.body    = bodyEl;
        this.toggle  = opts.toggleEl || null;
        this.native  = opts.native || false;          // hosted in <details>/<summary>
        this.fetchEachExpand   = opts.fetchEachExpand || false;
        this.discardOnCollapse = opts.discardOnCollapse || false;
        this.onExpand = opts.onExpand || null;
        this.lazy     = !!this.onExpand;
        this.loaded   = !this.lazy;                    // eager bodies start loaded
        this.expanded = false;

        if (this.native) {
            this.details = headerEl.closest('details') || bodyEl.closest('details');
            this.details && this.details.addEventListener(
                'toggle', () => this.applyExpanded(this.details.open));
        } else {
            headerEl.style.cursor = 'pointer';
            headerEl.addEventListener('click', () => this.applyExpanded(!this.expanded));
        }
    }

    setExpanded(expanded) {
        if (this.native) { if (this.details) this.details.open = expanded; return; }
        this.applyExpanded(expanded);
    }

    applyExpanded(expanded) {
        if (expanded === this.expanded) return;        // idempotent
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

    // Owner finished loading the lazy body: set its html + mark loaded so a
    // subsequent expand shows it without another round-trip.
    fill(html) {
        if (html != null) this.body.innerHTML = html;
        this.loaded = true;
    }
}

// Message filter: human labels + a fixed display order so toolbar checkboxes
// don't reshuffle based on which type happens to arrive first. Tool calls are
// NOT one type — each tool name gets its own key/checkbox in a trailing
// "Tools:" group (alphabetical), keyed `tool:<name>` from the wire `tool`
// field (the ACP tool name, threaded through by tool_header_dict).
const TYPE_LABELS = { user: 'User', agent: 'Agent', thought: 'Thoughts',
                      plan: 'Todos', summary: 'Summaries' };
const TYPE_ORDER  = ['user', 'agent', 'thought', 'plan', 'summary'];
const filterKey = (msg) =>
    msg.type === 'tool' ? 'tool:' + (msg.tool || 'other') : msg.type;

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
        // The .bt-messages flex column separates children with a row gap.
        // The virtual height math must count it per item or the virtual
        // geometry drifts ~gap px per message from the real scrollHeight —
        // in long chats that drift exceeds the overscan and the bottom
        // "bounces" away while scrolling down. Read it from the computed
        // style so a CSS change can't silently re-introduce the drift.
        this.ITEM_GAP = parseFloat(getComputedStyle(container).rowGap) || 0;

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
        // ── Message filter ─────────────────────────────────────────────
        // Checkboxes appear in the toolbar (below the composer) the first
        // time a filter key occurs (a base message type, or `tool:<name>`
        // per tool). Unchecking hides matching nodes (inline display:none)
        // AND zeroes their entries in the height math (effHeight), so
        // spacers/scroll mapping stay exact. Per-tab — rebuilt on remount.
        this.toolbarEl   = container.parentElement.querySelector('.bt-chat-toolbar');
        this.hiddenTypes = new Set();   // filter keys currently hidden
        this.seenTypes   = new Set();   // keys that already have a checkbox
        this.keyByIdx    = new Map();   // idx → filter key (drives effHeight)
        this.busyEl       = container.parentElement.querySelector('.bt-busy');
        // Transient "reasoning…" indicator: shown for the lifetime of an agent
        // thought, then removed. Most thoughts are redacted (empty) so this is
        // usually all the user sees of the model's thinking.
        this.thinkingEl   = container.parentElement.querySelector('.bt-thinking');

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
            this._startPrefetch();
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

        // Scrollbar drags emit NO wheel/touch/key events — only mousedown on
        // the container (the scrollbar is part of its hit area) and then
        // scroll events while the button is held, possibly for much longer
        // than the 400ms recency window. Track the held state explicitly so
        // a drag is always classified as user-driven; otherwise the chase
        // treats it as a layout shift and yanks the thumb back to the
        // bottom ("scrollbar feels stuck"). mouseup lands on window — the
        // pointer often leaves the container before release.
        this._scrollbarDrag = false;
        this._dragTotal     = null;   // scrollHeight frozen for the drag's duration
        this._onContainerMouseDown = () => {
            this._scrollbarDrag = true;
            // Freeze the scrollbar geometry: while estimates are being
            // corrected to measurements mid-drag, scrollHeight would
            // otherwise fluctuate every tick and the thumb visibly
            // "flickers". updateDOM compensates the bottom spacer against
            // this snapshot; release re-trues everything in one go.
            this._dragTotal = this.container.scrollHeight;
            markUserInput();
        };
        this._onWindowMouseUp      = () => {
            if (!this._scrollbarDrag) return;
            this._scrollbarDrag = false;
            this._dragTotal = null;
            markUserInput();   // the release tick still counts as user input
            this._queueRefresh();   // re-true spacers to the corrected heights
        };
        container.addEventListener('mousedown', this._onContainerMouseDown, { passive: true });
        window.addEventListener('mouseup', this._onWindowMouseUp, { passive: true });

        this._onScroll = () => {
            const userDriven = this._scrollbarDrag ||
                (performance.now() - this._lastUserInputT) < 400;
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
        Promise.resolve().then(() => {
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
            this.container.removeEventListener('wheel',    this._markUserInput);
            this.container.removeEventListener('touchstart', this._markUserInput);
            this.container.removeEventListener('touchmove',  this._markUserInput);
            this.container.removeEventListener('keydown',  this._markUserInput);
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
        this.ros.forEach((ro) => ro.disconnect());
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
            this._onDragOver  && this.app.removeEventListener('dragover',  this._onDragOver);
            this._onDragLeave && this.app.removeEventListener('dragleave', this._onDragLeave);
            this._onDrop      && this.app.removeEventListener('drop',      this._onDrop);
        }
        clearTimeout(this._attachErrorTimer);
        clearTimeout(this._prefetchTimer);
        if (this._tickerId) {
            clearInterval(this._tickerId);
            this._tickerId = null;
        }
        if (this.taskbarEl && this._onTaskbarClick) {
            this.taskbarEl.removeEventListener('click', this._onTaskbarClick);
        }
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
            case 'thinking':     return this.onThinking(msg.active);
            case 'thought_final':return this.onThoughtFinal(msg);
            case 'thought.body': return this.onThoughtBody(msg);
            case 'tool_update':  return this.onToolUpdate(msg);
            case 'plan_update':  return this.onPlanUpdate(msg);
            case 'chunk':        return this.appendChunk(msg);
            case 'user_chunk':   return this.appendUserChunk(msg.text);
            case 'user_unqueue': return this.unqueueOldestUser();
            case 'summary_final':return this.onSummaryFinal(msg);
            case 'attach_error':
                return this._showAttachError(msg.error || 'Attachment failed');
            // (formerly `send_ack` — JS now clears the input widget
            // unconditionally on submit, so no server ack is needed.)
            case 'user':
            case 'agent':
            case 'thought':
            case 'tool':
            case 'plan':
            case 'summary':
                return this.appendNewMessage(msg);
        }
    }

    // ── Range / virtual scroll ────────────────────────────────────────────

    applyCount(n) {
        if (n <= 0) return;
        this.totalCount  = n;
        this.initialLoad = true;
        this.refresh();
        this._startPrefetch();
    }

    // ── Background history prefetch ──────────────────────────────────────
    // Trickle-load the ENTIRE history into the node cache after mount, so
    // scrolling/seeking never lands on blank spacer. Bottom-up (the
    // direction users scroll into), 64 messages per request, each chunk
    // paced on the previous response — user-driven fetches and streaming
    // always win the wire. Cached-only during scrollbar drags by design
    // (onRange skips DOM work mid-drag), so blanks fill in on release.
    _startPrefetch() {
        if (this._prefetchStarted) return;
        this._prefetchStarted = true;
        this._prefetchTimer = setTimeout(() => this._prefetchTick(), 600);
    }

    _prefetchTick() {
        if (this.destroyed) return;
        // Highest missing index at or below the cursor.
        let e = -1;
        for (let i = Math.min(this._prefetchCursor ?? Infinity, this.totalCount - 1); i >= 0; i--) {
            if (!this.cache.has(i)) { e = i; break; }
        }
        if (e < 0) return;                       // fully cached — done
        let s = e;
        while (s > 0 && !this.cache.has(s - 1) && (e - s) < 63) s--;
        this._prefetchCursor = s - 1;
        this.comm.notify({type: 'msgs.request', range: [s, e]});
        // onRange reschedules the next tick when the response lands; this
        // timer is only the safety net for a lost/empty response.
        clearTimeout(this._prefetchTimer);
        this._prefetchTimer = setTimeout(() => this._prefetchTick(), 2000);
    }

    visibleRange() {
        if (this.totalCount === 0) return [0, -1];
        const { scrollTop, clientHeight } = this.container;
        const over = this.OVERSCAN * this.EST_HEIGHT;
        const s = this.indexAt(Math.max(0, scrollTop - over));
        const e = this.indexAt(scrollTop + clientHeight + over);
        return [s, Math.min(this.totalCount - 1, e)];
    }

    // Effective height: 0 for filtered-out keys (display:none flex items
    // produce no gap either), else the measured height (or the estimate)
    // PLUS the flex row gap that follows each rendered item. The ONLY way
    // spacer/offset math may read heights — keeping it gap-aware makes a
    // measured node's virtual contribution match its real pixels exactly.
    // `observe`'s h>0 guard keeps the last measured height through a
    // hide/show cycle, so re-showing restores exact sizes.
    effHeight(i) {
        if (this.hiddenTypes.has(this.keyByIdx.get(i))) return 0;
        return (this.heights.get(i) ?? this.EST_HEIGHT) + this.ITEM_GAP;
    }

    indexAt(offset) {
        let h = 0;
        for (let i = 0; i < this.totalCount; i++) {
            h += this.effHeight(i);
            if (h > offset) return i;
        }
        return Math.max(0, this.totalCount - 1);
    }

    cumHeight(from, to) {
        let h = 0;
        for (let i = from; i < to; i++) h += this.effHeight(i);
        return h;
    }

    refresh() {
        if (this.totalCount === 0) return;
        // Bottom anchoring: updateDOM resizes the spacers, which moves
        // scrollHeight under a scrollTop pinned at the bottom — without
        // compensation the bottom edge "bounces" away from the user
        // (scrollHeight changes fire no scroll event, and overflow-anchor
        // is off on the spacers). If we were at the bottom before the
        // re-window and the geometry shifted, re-pin. Within-AT_BOTTOM_PX
        // already means "at the bottom" everywhere else (followMode), so
        // pinning here matches the existing semantics.
        const wasAtBottom = this.atBottom();
        const preHeight   = this.container.scrollHeight;
        const [s, e] = this.visibleRange();

        // While the scrollbar is held, do NOT fetch: every arriving range
        // inserts + measures new nodes mid-drag and the resulting geometry
        // churn makes the thumb flicker. A drag navigates CACHED content
        // only (uncached regions show as spacer); the release handler's
        // refresh fetches whatever the thumb landed on.
        if (!this._scrollbarDrag) {
            const missing = [];
            for (let i = s; i <= e; i++) if (!this.cache.has(i)) missing.push(i);
            if (missing.length > 0) {
                this.comm.notify({type: 'msgs.request',
                                  range: [missing[0], missing[missing.length - 1]]});
            }
        }
        this.updateDOM(s, e);
        // Never pin while the user is actively dragging the scrollbar —
        // the drag IS the authority on where scrollTop should be.
        if (wasAtBottom && !this._scrollbarDrag &&
            this.container.scrollHeight !== preHeight) {
            this.container.scrollTop = this.container.scrollHeight;
        }
    }

    onRange({ start, msgs }) {
        const messages = msgs ?? [];          // tolerate the legacy `messages` field
        messages.forEach((data, i) => {
            const idx = start + i;
            if (this.cache.has(idx)) return;
            const node = this.createNode(data);
            this.cache.set(idx, node);
            this.keyByIdx.set(idx, filterKey(data));
            if (data.id) this.nodeById.set(data.id, node);
            this.observe(idx, node);
        });
        // Any arriving range advances the background prefetch (pacing: one
        // chunk in flight at a time, ~30ms apart). Runs through drags too —
        // caching is the drag-safe part.
        if (this._prefetchStarted) {
            clearTimeout(this._prefetchTimer);
            this._prefetchTimer = setTimeout(() => this._prefetchTick(), 30);
        }
        // Ranges still in flight when a scrollbar drag started: cache the
        // nodes (above) but don't touch the DOM/geometry until release —
        // mid-drag insertion is the thumb flicker.
        if (this._scrollbarDrag) return;
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
            if (h > 0 && this.heights.get(idx) !== h) {
                this.heights.set(idx, h);
                // Apply the correction NOW (rAF-batched) instead of letting
                // it ambush the next scroll tick: the spacers re-true while
                // refresh()'s bottom anchoring keeps the viewport pinned,
                // so estimate→measured corrections are invisible. EXCEPT
                // mid-scrollbar-drag: corrections then wait for release —
                // re-spacing under a held thumb is exactly the flicker.
                if (!this._scrollbarDrag) this._queueRefresh();
            }
        });
        ro.observe(node);
        this.ros.set(idx, ro);
    }

    // rAF-batched refresh: many ResizeObserver measurements land in the
    // same frame (initial range render, streaming reflows) — coalesce them
    // into one re-window + respace.
    _queueRefresh() {
        if (this._refreshQueued || this.destroyed) return;
        this._refreshQueued = true;
        requestAnimationFrame(() => {
            this._refreshQueued = false;
            if (!this.destroyed) this.refresh();
        });
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
        // During a scrollbar drag, hold the TOTAL scrollHeight at its
        // drag-start value: estimate→measurement corrections re-balance
        // between the spacers instead of resizing the scrollbar, so the
        // thumb tracks the pointer smoothly. Spill into the top spacer
        // when the bottom one clamps at 0 (drags near the bottom — bar
        // stability beats content stability mid-drag). One forced-layout
        // read; the release handler re-trues the geometry honestly.
        if (this._scrollbarDrag && this._dragTotal != null) {
            const delta = this.container.scrollHeight - this._dragTotal;
            if (delta !== 0) {
                const curB = parseFloat(this.spacerBottom.style.height) || 0;
                const newB = Math.max(0, curB - delta);
                this.spacerBottom.style.height = newB + 'px';
                const rem = delta - (curB - newB);   // unabsorbed remainder
                if (rem !== 0) {
                    const curT = parseFloat(this.spacerTop.style.height) || 0;
                    this.spacerTop.style.height = Math.max(0, curT - rem) + 'px';
                }
            }
        }
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
            this.keyByIdx.set(idx, filterKey(msg));
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

    appendChunk(msg) {
        const node = this.nodeById.get(msg.id);
        if (!node) return;
        // Server ships the FULL rendered html of the message-so-far each
        // chunk (CommonMark-rendered, so intraword `_`s don't italicize and
        // newlines/lists/headings format correctly while streaming). Just
        // replace the bubble's content.
        if (msg.html !== undefined) {
            node.innerHTML = msg.html;
        } else if (msg.text !== undefined) {
            // Legacy text-delta path (kept for the streaming-stress mocks
            // that still feed plain text). Append to the streaming span.
            const t = node.querySelector('.bt-stream-text');
            if (t) t.textContent += msg.text;
        }
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

    // A committed thought ships its html on close — pre-fill so the body is
    // there (and marked loaded) before the user even expands.
    onThoughtFinal(msg) {
        const node = this.nodeById.get(msg.id);
        node && node.collapsable && node.collapsable.fill(msg.html || '');
    }

    // Reply to a `thought.render` request (reloaded thought, lazy body).
    onThoughtBody(msg) {
        const node = this.nodeById.get(msg.id);
        node && node.collapsable && node.collapsable.fill(msg.html);
    }

    // Transient "reasoning…" indicator toggled by Julia for the lifetime of an
    // agent thought (redacted thoughts have no body, so this is the only trace).
    onThinking(active) {
        if (this.thinkingEl) this.thinkingEl.classList.toggle('bt-thinking-active', !!active);
        if (active && this.followMode) this._queueScrollToBottom();
    }

    onToolUpdate(msg) {
        const node = this.nodeById.get(msg.id);
        if (!node) return;
        if (msg.status) {
            const s = node.querySelector('.bt-tool-status');
            if (s) { s.textContent = msg.status; s.className = `bt-tool-status bt-status-${msg.status}`; }
            // Pulsing glow + taskbar slot are gated on the `bt-tool-live`
            // class. Terminal status sheds it; mid-flight gets it.
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
        // Edit tools ship their inline diff preview as a follow-up update (the
        // header was emitted before the diff was on disk). Insert it right after
        // the header, matching the initial toolHTML layout.
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
        // bt_show: the completion update is when we learn it's a "show me this"
        // tool — auto-expand its preview (idempotent; user can still collapse).
        if (msg.expand && node.collapsable) node.collapsable.setExpanded(true);
        // A background bash/Task only learns it's a taskbar item when its launch
        // result arrives (rawInput doesn't carry run_in_background), so the server
        // flips `taskbar` on a later update. The taskbar filter keys off this
        // attr — set it so `_refreshTaskbar` below adds the slot. (Set-only,
        // matching createNode; nothing clears it.)
        if (msg.taskbar) node.dataset.toolTaskbar = '1';
        // Live-set / timer / taskbar all sit on the same DOM data attrs the
        // ticker reads — rebuild now so the taskbar reflects this change
        // instantly instead of waiting for the next 1s tick.
        this._refreshTaskbar();
    }

    // ── Message filter (toolbar below the composer) ──────────────────────

    // First occurrence of a filter key → add its show/hide checkbox to the
    // toolbar, checked. Base types sit first in TYPE_ORDER; tool keys go in
    // a trailing "Tools:" group, alphabetical — stable positions either way,
    // independent of arrival order. No-op when the toolbar isn't mounted.
    noteKey(msg) {
        const key = filterKey(msg);
        if (!key || this.seenTypes.has(key) || !this.toolbarEl) return;
        this.seenTypes.add(key);
        const isTool = key.startsWith('tool:');
        const text   = isTool ? key.slice(5) : (TYPE_LABELS[key] ?? key);
        const label = document.createElement('label');
        label.className = 'bt-filter-toggle';
        label.dataset.key = key;
        const cb = document.createElement('input');
        cb.type = 'checkbox';
        cb.checked = !this.hiddenTypes.has(key);
        cb.addEventListener('change', () => this.setKeyHidden(key, !cb.checked));
        label.append(cb, text);
        const toggles = () => [...this.toolbarEl.querySelectorAll('.bt-filter-toggle')];
        if (isTool) {
            this.ensureToolGroupLabel();
            const next = toggles().find(el =>
                el.dataset.key.startsWith('tool:') &&
                el.dataset.key.slice(5).localeCompare(text) > 0);
            this.toolbarEl.insertBefore(label, next ?? null);
        } else {
            const order = t => { const i = TYPE_ORDER.indexOf(t); return i < 0 ? TYPE_ORDER.length : i; };
            // Before the first base toggle that sorts after us; else before
            // the Tools: group; else at the end.
            const next = toggles().find(el =>
                !el.dataset.key.startsWith('tool:') && order(el.dataset.key) > order(key))
                ?? this.toolbarEl.querySelector('.bt-filter-group-label');
            this.toolbarEl.insertBefore(label, next ?? null);
        }
    }

    ensureToolGroupLabel() {
        if (this.toolbarEl.querySelector('.bt-filter-group-label')) return;
        const span = document.createElement('span');
        span.className = 'bt-filter-group-label';
        span.textContent = 'Tools:';
        this.toolbarEl.appendChild(span);
    }

    // Toggle a key's visibility: inline display on every matching node (an
    // open key-set — per-tool keys — rules out static CSS classes), while
    // effHeight zeroes the hidden indices so the spacer/scroll math matches
    // the real (collapsed) layout exactly. Nodes created later pick up the
    // current state in createNode.
    setKeyHidden(key, hidden) {
        this.hiddenTypes[hidden ? 'add' : 'delete'](key);
        for (const node of this.cache.values()) {
            if (node.dataset.filterKey === key) node.style.display = hidden ? 'none' : '';
        }
        this.refresh();
        if (this.followMode) this._queueScrollToBottom();
    }

    // ── DOM node creation ────────────────────────────────────────────────

    createNode(msg) {
        const div = document.createElement('div');
        const fkey = filterKey(msg);
        div.dataset.filterKey = fkey;       // filter identity: type, or tool:<name>
        this.noteKey(msg);                  // first occurrence → toolbar checkbox
        switch (msg.type) {
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
                    // Seed with whatever the first chunk sent (may be ""):
                    // a viewer that joined mid-stream needs to see this
                    // initial text immediately, not wait for the next chunk.
                    if (msg.text) span.textContent = msg.text;
                    div.appendChild(span);
                } else {
                    div.innerHTML = msg.html || '';
                }
                break;
            case 'thought': {
                div.className = 'bt-thought-msg';
                div.innerHTML = this.thoughtHTML(msg);
                const id = msg.id;
                // Native <details> host, lazy body loaded once via thought.render.
                div.collapsable = new Collapsable(
                    div.querySelector('.bt-thought-summary'),
                    div.querySelector('.bt-thought-body'),
                    { native: true,
                      onExpand: () => this.comm.notify({type: 'thought.render', id}) });
                if (msg.html) div.collapsable.fill(msg.html);
                break;
            }
            case 'tool': {
                div.className = 'bt-tool-msg';
                div.innerHTML = this.toolHTML(msg);
                // Live state + start time live on the message node itself so
                // the 1s ticker can find them by selector. Status `pending` /
                // `in_progress` count as live until a terminal update flips
                // the class via `onToolUpdate`.
                if (msg.id) div.dataset.msgId = msg.id;
                if (msg.started_at != null)
                    div.dataset.toolStarted = String(msg.started_at);
                if (msg.finished_at != null)
                    div.dataset.toolFinished = String(msg.finished_at);
                // Server-decided opt-in for the taskbar slot. Background bash
                // / Task land here; regular tools don't.
                if (msg.taskbar) div.dataset.toolTaskbar = '1';
                const liveTool = !(msg.status === 'completed' || msg.status === 'failed') &&
                                  msg.finished_at == null;
                if (liveTool) div.classList.add('bt-tool-live');
                const id = msg.id;
                // Click-header host; the body is re-rendered (Monaco etc.) on
                // every expand via tool.render → dom_in_js, and discarded on
                // collapse so the editors are freed.
                div.collapsable = new Collapsable(
                    div.querySelector('.bt-tool-header'),
                    div.querySelector('.bt-tool-body'),
                    { toggleEl: div.querySelector('.bt-tool-toggle'),
                      fetchEachExpand: true, discardOnCollapse: true,
                      onExpand: () => this.comm.notify({type: 'tool.render', id}) });
                // Detach (bonito_app only): pop the embed into the floating
                // window. Lives on the ⤢ header button — the conventional "open
                // in a window" glyph, and where users expect detach.
                const detachBtn = div.querySelector('.bt-tool-detach');
                if (detachBtn) detachBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    window._btPopup && window._btPopup.detach(id);
                });
                // Full-chat-width toggle, vertically centered on the bubble's
                // right edge (CSS reveals it only while the body is expanded —
                // there's no point widening an empty header). Extends the pill to
                // span the whole message column so wide content (diffs / tables /
                // remote-app embeds) gets room. Must NOT toggle expand/collapse,
                // so stopPropagation.
                const wideBtn = div.querySelector('.bt-tool-fullwidth');
                if (wideBtn) wideBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    const active = div.classList.toggle('bt-tool-wide-active');
                    wideBtn.textContent = active ? '«' : '»';
                    wideBtn.title = active ?
                        'Collapse to default width' : 'Expand to full chat width';
                });
                // Auto-expand (e.g. bt_show). Deferred to a microtask so the
                // node is inserted into the document before tool.render's
                // dom_in_js tries to mount into its `[data-tool-id]` slot.
                if (msg.expand) queueMicrotask(() => div.collapsable.setExpanded(true));
                break;
            }
            case 'plan': {
                div.className = 'bt-plan-msg';
                div.innerHTML = msg.html || '';
                // TodoListMsg absorbs subsequent updates by id — every later
                // emit overwrites the same node's html. The live flag (and
                // started_at) drive the pulse + taskbar slot.
                if (msg.id) div.dataset.msgId = msg.id;
                if (msg.started_at != null)
                    div.dataset.planStarted = String(msg.started_at);
                if (msg.finished_at != null)
                    div.dataset.planFinished = String(msg.finished_at);
                if (msg.summary)
                    div.dataset.planSummary = msg.summary;
                if (msg.live) div.classList.add('bt-plan-live');
                break;
            }
            case 'summary': {
                // Centered separator block for a `/compact` summary — NOT a
                // user/agent bubble. Streaming case shows a tiny placeholder
                // until `summary_final` lands; the persisted-replay case ships
                // the html directly in `msg.html`.
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
        // A node created while its filter key is unchecked starts hidden —
        // scrollback fetches and live appends respect the active filter.
        if (this.hiddenTypes.has(fkey)) div.style.display = 'none';
        return div;
    }

    // Clear the "queued" state from the FIRST (oldest) still-queued user
    // bubble. Server-side FIFO under `promote_queued_user_bubble!` matches the
    // DOM order the bubbles were created in, so first-match is correct.
    unqueueOldestUser() {
        const q = this.container.querySelector('.bt-user-msg.bt-queued');
        if (q) q.classList.remove('bt-queued');
    }

    onSummaryFinal(msg) {
        // Find the LAST summary node still in streaming/placeholder state and
        // fill it. We don't carry an id (summaries are rare — one per session
        // continuation — and there's no ambiguity in practice).
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
        const preview   = msg.preview ?
            `<div class="bt-edit-preview">${msg.preview}</div>` : '';
        // MCP tools carry a `server` (e.g. "bonitoteam"); show it as a dim
        // badge before the (already prefix-stripped) tool name.
        const server = msg.server ?
            `<span class="bt-tool-server">${escapeHTML(msg.server)}</span>` : '';
        // Elapsed timer — only renders text once > 1s have passed (see
        // _tickLiveTimers). Always emitted so the same span can be updated
        // in place by every tick + by `onToolUpdate`.
        return `
            <div class="bt-tool-header" data-expanded="false">
                <span class="bt-tool-toggle">▶</span>
                <span class="bt-tool-kind">${msg.icon || '⚙'}</span>
                ${server}
                <span class="bt-tool-title">${escapeHTML(msg.title || '')}</span>
                <span class="bt-tool-summary">${escapeHTML(msg.summary || '')}</span>
                <span class="bt-tool-timer"></span>
                <span class="${statusCls}">${escapeHTML(msg.status || '')}</span>
                ${msg.kind === 'bonito_app'
                    ? `<button class="bt-tool-detach" type="button"
                              title="Detach to floating window">⤢</button>`
                    : ''}
            </div>
            ${preview}
            <div class="bt-tool-body" data-tool-id="${escapeAttr(msg.id || '')}"></div>
            <button class="bt-tool-fullwidth" type="button"
                    title="Expand to full chat width">»</button>`;
    }

    // ── Live tools / todos: pulse + timer + taskbar ──────────────────────
    // A single 1s interval drives all live-state UX:
    //   1) Update the inline `.bt-tool-timer` on each live pill (> 1s only).
    //   2) Rebuild the floating taskbar from current live DOM (one slot per
    //      live pill; click → scrollIntoView on the source).
    // No per-pill timers, no server-pushed taskbar state — DOM is the source
    // of truth. Cheap: scans at most a few dozen nodes once a second.
    onPlanUpdate(msg) {
        const node = this.nodeById.get(msg.id);
        if (!node) return;
        if (msg.html != null) node.innerHTML = msg.html;
        if (msg.started_at != null)
            node.dataset.planStarted = String(msg.started_at);
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
        // The taskbar element is mounted by the Julia side as a sibling of
        // `.bt-messages`. Bail gracefully if it's absent (older mount points
        // / tests skipping the chat shell).
        this.taskbarEl = this.app ?
            this.app.querySelector('.bt-taskbar') :
            this.container.parentElement.querySelector('.bt-taskbar');
        if (!this.taskbarEl) return;
        // Delegated click on the taskbar:
        //   - hitting the ⊗ stop affordance → notify the server, which
        //     dispatches per-tool via `StopToolCommand` (synthetic user
        //     message asking Claude to stop the background tool — we don't
        //     fake an immediate-stop UI because the SDK has no kill primitive
        //     for background bash, so the slot keeps living until the tool
        //     itself transitions to terminal status).
        //   - anywhere else on the slot → scroll back to the source pill.
        this._onTaskbarClick = (ev) => {
            const stopBtn = ev.target.closest('.bt-taskbar-slot-stop');
            if (stopBtn) {
                ev.stopPropagation();
                const slot = stopBtn.closest('.bt-taskbar-slot');
                const id = slot?.dataset.targetId;
                if (id) this.comm.notify({ type: 'stop_tool', id });
                return;
            }
            const slot = ev.target.closest('.bt-taskbar-slot');
            if (!slot) return;
            const id = slot.dataset.targetId;
            if (!id) return;
            const target = this.nodeById.get(id);
            if (target) target.scrollIntoView({ block: 'center', behavior: 'smooth' });
        };
        this.taskbarEl.addEventListener('click', this._onTaskbarClick);
        this._tickerId = setInterval(() => this._tickLiveTimers(), 1000);
        // Initial paint so the bar is populated immediately on first mount
        // (not after a 1s delay).
        this._refreshTaskbar();
    }

    _tickLiveTimers() {
        if (this.destroyed) return;
        const now = Date.now() / 1000;
        // Update inline timers on every live pill — both tools and todos.
        for (const el of this.container.querySelectorAll(
                'div.bt-tool-msg.bt-tool-live, div.bt-plan-msg.bt-plan-live')) {
            const started = parseFloat(el.dataset.toolStarted ?? el.dataset.planStarted ?? '0');
            if (!started) continue;
            const elapsed = now - started;
            const timer = el.querySelector('.bt-tool-timer');
            if (timer) timer.textContent = elapsed > 1 ? _formatElapsed(elapsed) : '';
        }
        // Also tick the taskbar slot timers (cheaper than full rebuild).
        for (const slot of this.taskbarEl.querySelectorAll('.bt-taskbar-slot')) {
            const started = parseFloat(slot.dataset.started ?? '0');
            if (!started) continue;
            const elapsed = now - started;
            const t = slot.querySelector('.bt-taskbar-slot-timer');
            if (t) t.textContent = elapsed > 1 ? _formatElapsed(elapsed) : '';
        }
    }

    _refreshTaskbar() {
        if (this.destroyed || !this.taskbarEl) return;
        // Collect live source nodes in document order: tool pills that
        // opted into the taskbar (background bash / Task) plus every live
        // todo list. The `[data-tool-taskbar]` filter mirrors the server-
        // side `is_taskbar_item` decision — a regular live Read pulses
        // briefly but doesn't crowd the bar.
        const live = this.container.querySelectorAll(
            'div.bt-tool-msg.bt-tool-live[data-tool-taskbar], div.bt-plan-msg.bt-plan-live');
        if (live.length === 0) {
            this.taskbarEl.replaceChildren();
            return;
        }
        const frag = document.createDocumentFragment();
        for (const el of live) {
            const id = el.dataset.msgId;
            if (!id) continue;
            const isPlan = el.classList.contains('bt-plan-msg');
            const icon = isPlan ? '📋' :
                (el.querySelector('.bt-tool-kind')?.textContent || '⚙');
            const label = isPlan ?
                (el.dataset.planSummary || 'Todo list') :
                (el.querySelector('.bt-tool-title')?.textContent || 'Tool');
            const started = isPlan ? el.dataset.planStarted : el.dataset.toolStarted;
            const slot = document.createElement('div');
            slot.className = 'bt-taskbar-slot';
            slot.dataset.targetId = id;
            if (started) slot.dataset.started = started;
            // Todo lists are passive trackers — no SDK primitive to "stop"
            // them. Only tool slots get the ⊗ affordance.
            const stop = isPlan ? '' :
                `<span class="bt-taskbar-slot-stop" title="Ask Claude to stop this">⊗</span>`;
            slot.innerHTML =
                `<span class="bt-taskbar-slot-icon">${icon}</span>` +
                `<span class="bt-taskbar-slot-label"></span>` +
                `<span class="bt-taskbar-slot-timer"></span>` +
                stop;
            slot.querySelector('.bt-taskbar-slot-label').textContent = label;
            frag.appendChild(slot);
        }
        this.taskbarEl.replaceChildren(frag);
        // Prime the timers now so a freshly added slot doesn't wait a full
        // tick to show its elapsed time.
        this._tickLiveTimers();
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
        // NOTE: we deliberately do NOT cache `.bt-send-btn` / `.bt-stop-btn`
        // references at setup time. Bonito renders the chat's children
        // non-atomically — the send button can land in the DOM a frame
        // before the stop button, so a `querySelector('.bt-stop-btn')`
        // here can return `null` even though the button shows up moments
        // later. A null-ref + late button = silently dead click handler
        // (esp. the stop button, which is the user's only interrupt
        // affordance). Event delegation on the chat root (`.bt-app`)
        // sidesteps the race entirely: the listener is alive before
        // either button exists, and dispatches by `e.target.closest`
        // at click time.
        if (!this.inputArea || !this.textInput) return;

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

        // Single delegated click handler on the chat root. Capture phase
        // so we run before any inner element that might (in the future)
        // also wire a click handler. `target.closest` survives DOM swaps
        // and works regardless of when the buttons are added.
        this._onAppClickCapture = (e) => {
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

        // Enter-to-send on the textarea (Shift+Enter newline as usual).
        this._onTextInputKeyCapture = (e) => {
            if (e.key !== 'Enter' || e.shiftKey) return;
            e.preventDefault();
            e.stopImmediatePropagation();
            this._submit();
        };
        this.textInput.addEventListener('keydown', this._onTextInputKeyCapture, true);

        // ESC anywhere → cancel. Listener on `document` so the user's
        // current focus (textarea, scroll position, anywhere) can't
        // suppress it. The Monaco tool-body editor owns ESC for its own
        // semantics — skip when the user is editing inside one.
        this._onEscapeKey = (e) => {
            if (e.key !== 'Escape' || e.repeat) return;
            const t = e.target;
            if (t && t.closest && t.closest('.monaco-editor')) return;
            e.preventDefault();
            this._cancel();
        };
        document.addEventListener('keydown', this._onEscapeKey, true);
    }

    // Fire a cancel notification. Used by both the stop button click
    // and the ESC keystroke. Stays a one-line helper so the two
    // entry points can't drift in what they send.
    _cancel() {
        this.comm.notify({type: 'cancel'});
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

// Compact elapsed-time formatting for the inline tool timer + taskbar slot.
// `< 60s` shows seconds; minutes-and-up shows `<m>m<s>s`. Only callers that
// have already crossed the 1s threshold reach here, so we never render "0s".
function _formatElapsed(sec) {
    if (sec < 60) return `${Math.round(sec)}s`;
    const m = Math.floor(sec / 60);
    const s = Math.round(sec - m * 60);
    return s === 0 ? `${m}m` : `${m}m${s}s`;
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
