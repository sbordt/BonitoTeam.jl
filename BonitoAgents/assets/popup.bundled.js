// deno-fmt-ignore-file
// deno-lint-ignore-file
// This code was bundled using `deno bundle` and it's not recommended to edit it manually

class PopupController {
    constructor({ popupMount , paneMount , appHost , dropzone , vis , ppv , loc , title , chatWidth , currentView , activeTab , detachApp , restoreApp , dockApp , undockApp , appDocked  }){
        this.popupMount = popupMount;
        this.paneMount = paneMount;
        this.appHost = appHost;
        this.dropzone = dropzone;
        this.vis = vis;
        this.ppv = ppv;
        this.loc = loc;
        this.title = title;
        this.appDocked = appDocked;
        this.activePid = '';
        this.byPid = {};
        ppv.on(()=>this.applyPlotpaneVis());
        this.applyPlotpaneVis();
        activeTab.on((id)=>this.applyActiveTab(id));
        this.applyActiveTab(activeTab.value || '');
        currentView.on((pid)=>this.setChat(pid));
        detachApp.on((toolId)=>{
            if (toolId) this.detach(toolId);
        });
        restoreApp.on((v)=>{
            if (v) this.restore();
        });
        dockApp.on((v)=>{
            if (v) this.dock();
        });
        undockApp.on((v)=>{
            if (v) this.undock();
        });
        this.setupDivider(chatWidth);
        this.setupDragToDock();
    }
    current() {
        return this.byPid[this.activePid] || null;
    }
    applyPlotpaneVis() {
        this.dropzone.classList.toggle('bt-plotpane-visible', this.ppv.value);
    }
    applyActiveTab(id) {
        this.paneMount.dataset.activeTab = id || '';
        this.paneMount.querySelectorAll('[data-tab-id]').forEach((el)=>{
            el.style.display = el.dataset.tabId === id ? '' : 'none';
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
        const slot = document.getElementById('bt-slot-' + toolId);
        if (embed && slot) {
            Bonito.move_dom_node(embed, slot, null);
            slot.removeAttribute('data-detached');
        }
    }
    detach(toolId) {
        const pid = this.activePid, prev = this.byPid[pid];
        if (prev && prev.toolId !== toolId) this.toBubble(prev.toolId);
        const location = prev && prev.location || this.loc.value || 'floating';
        if (!this.toSurface(toolId, location)) {
            console.warn('[PopupController] detach: no embed for', toolId);
            return;
        }
        this.byPid[pid] = {
            toolId,
            location
        };
        this.loc.notify(location);
        this.title.notify('App · ' + toolId.slice(0, 8));
        if (location === 'docked') {
            this.vis.notify(false);
            this.appDocked.notify(toolId);
        } else {
            this.vis.notify(true);
            this.appDocked.notify('');
        }
    }
    restore() {
        const rec = this.current();
        if (rec) {
            this.toBubble(rec.toolId);
            delete this.byPid[this.activePid];
        }
        this.vis.notify(false);
        this.appDocked.notify('');
    }
    dock() {
        const rec = this.current();
        if (!rec) return;
        if (!this.toSurface(rec.toolId, 'docked')) return;
        rec.location = 'docked';
        this.loc.notify('docked');
        this.vis.notify(false);
        this.appDocked.notify(rec.toolId);
    }
    undock() {
        const rec = this.current();
        if (!rec) return;
        if (!this.toSurface(rec.toolId, 'floating')) return;
        rec.location = 'floating';
        this.loc.notify('floating');
        this.vis.notify(true);
        this.appDocked.notify('');
    }
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
    setupDivider(chatWidth) {
        const handle = this.dropzone.querySelector('.bt-pp-resize');
        const stage = this.dropzone.closest('.bt-stage');
        const main = stage ? stage.querySelector('.bt-main') : null;
        if (!handle || !stage || !main) return;
        handle.addEventListener('pointerdown', (e)=>{
            e.preventDefault();
            const stageW = stage.clientWidth || window.innerWidth;
            const startX = e.clientX;
            const startW = main.getBoundingClientRect().width;
            const clampW = (w)=>Math.max(480, Math.min(Math.min(1400, stageW - 320), w));
            this.dropzone.classList.add('bt-pp-resizing');
            const drag = new AbortController();
            const { signal  } = drag;
            window.addEventListener('pointermove', (ev)=>{
                main.style.setProperty('--bt-chat-width', clampW(startW + (ev.clientX - startX)) + 'px');
            }, {
                signal
            });
            window.addEventListener('pointerup', ()=>{
                drag.abort();
                this.dropzone.classList.remove('bt-pp-resizing');
                const finalW = Math.round(main.getBoundingClientRect().width);
                if (finalW >= 480) chatWidth.notify(finalW);
            }, {
                signal
            });
        });
        handle.addEventListener('dblclick', (e)=>{
            e.preventDefault();
            main.style.removeProperty('--bt-chat-width');
            chatWidth.notify(0);
        });
    }
    setupDragToDock() {
        document.addEventListener('pointerdown', (ev)=>{
            const tb = ev.target.closest('.bn-fw-title');
            if (!tb || ev.target.closest('.bn-fw-controls')) return;
            if (!this.current()) return;
            const stage = this.dropzone.closest('.bt-stage');
            const main = stage ? stage.querySelector('.bt-main') : null;
            if (!main || !stage) return;
            const mr = main.getBoundingClientRect(), sr = stage.getBoundingClientRect();
            const left = mr.right, right = sr.right;
            if (right - left < 40) return;
            const ov = document.createElement('div');
            ov.className = 'bt-drop-overlay';
            ov.style.left = left + 'px';
            ov.style.top = sr.top + 'px';
            ov.style.width = right - left + 'px';
            ov.style.height = sr.height + 'px';
            document.body.appendChild(ov);
            const inZone = (e2)=>e2.clientX >= left && e2.clientX <= right && e2.clientY >= sr.top && e2.clientY <= sr.bottom;
            const drag = new AbortController();
            const { signal  } = drag;
            document.addEventListener('pointermove', (e2)=>ov.classList.toggle('bt-drop-active', inZone(e2)), {
                signal
            });
            document.addEventListener('pointerup', (e2)=>{
                drag.abort();
                const over = inZone(e2);
                ov.remove();
                if (over) this.dock();
            }, {
                signal
            });
        });
    }
}
export { PopupController as PopupController };

