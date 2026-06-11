# ── PlotPane: the Julia-side handle for the right-hand pane ──────────────────
# One per browser window. Created by `install_popup!` (popup.jl), which also
# builds the pane's DOM and the JS controller; passed DOWN the object graph —
# unified_main → ChatPaneRef → the per-session ChatModel view — so chat code
# drives the pane through plain Julia + Observables. No session registries,
# no `window.*` controller objects.
#
# The pane is TABBED (VSCode-style): every open file editor is a tab, and a
# docked `bt_show_app` embed is a tab too — they coexist instead of clobbering
# each other. All tab state travels through ONE atomic observable
# (`tabs :: Observable{TabsState}`): items + the active id always change
# together, so there is no window where the bar and the content disagree.
#
#   • File tabs: `open_file!(pane, model, path)` upserts a tab and activates
#     it. Editors are CACHED by path (`editors`) and rendered through a
#     KeyedList keyed on the tab id, so switching tabs preserves Monaco
#     state (cursor, scroll, unsaved edits) — re-rendering would lose it.
#   • The app tab: the embed DOM is moved in/out imperatively by the JS
#     controller (`Bonito.move_dom_node` keeps its WebSocket state alive).
#     The controller reports docking through `app_docked` (tool_id or "");
#     Julia folds that into the tab state like any other tab.
#
# `tabs` carries only plain data (ids/labels) — safe to interpolate into JS.
# The CONTENTS (FileEditor widgets) ride the KeyedList, never a JS-visible
# observable.
struct PaneTab
    id    :: String     # "file:<path>" | "app"
    label :: String
    kind  :: Symbol     # :file | :app
end

struct TabsState
    items  :: Vector{PaneTab}
    active :: String    # tab id; "" ⇒ nothing active (pane empty)
end
TabsState() = TabsState(PaneTab[], "")

struct PlotPane
    tabs        :: Observable{TabsState}
    # Open file editors, cached by tab id — the stable instances the
    # KeyedList contract requires (AGENTS.md §5).
    editors     :: Dict{String,Any}
    # UI events (JS/buttons notify; install_popup! folds them into `tabs`):
    tab_click   :: Observable{String}   # tab id → activate
    tab_close   :: Observable{String}   # tab id → remove (app tab ⇒ restore)
    app_docked  :: Observable{String}   # JS controller: docked tool_id or ""
    # App-embed actions (independent user actions; the JS controller
    # subscribes, everything else only notifies):
    detach_app  :: Observable{String}   # tool_id pulse: open embed at last surface
    restore_app :: Observable{Bool}     # pulse: embed back to bubble
    dock_app    :: Observable{Bool}     # pulse: floating → docked
    undock_app  :: Observable{Bool}     # pulse: docked → floating
end

PlotPane() = PlotPane(
    Observable(TabsState()),
    Dict{String,Any}(),
    Observable(""),
    Observable(""),
    Observable(""),
    Observable(""),
    Observable(false),
    Observable(false),
    Observable(false),
)

file_tab_id(path::AbstractString) = "file:" * String(path)
const APP_TAB_ID = "app"

# Pure helpers over TabsState — all tab mutations build ONE new state.
function upsert_tab(st::TabsState, tab::PaneTab; activate::Bool = true)
    items = copy(st.items)
    idx = findfirst(t -> t.id == tab.id, items)
    idx === nothing ? push!(items, tab) : (items[idx] = tab)
    TabsState(items, activate ? tab.id : st.active)
end

function remove_tab(st::TabsState, id::AbstractString)
    items = filter(t -> t.id != id, st.items)
    active = st.active == id ?
        (isempty(items) ? "" : items[end].id) : st.active
    TabsState(items, active)
end

function activate_tab(st::TabsState, id::AbstractString)
    any(t -> t.id == id, st.items) || return st
    TabsState(st.items, String(id))
end

# One kept-alive wrapper per file tab — the KeyedList item. Visibility is
# toggled by the controller from `active_tab` ([data-tab-id] children of the
# mount); a freshly added wrapper self-initializes from the mount's
# data-active-tab (the controller's last write), since it mounts AFTER the
# toggle ran.
struct PaneTabContent
    id     :: String
    editor :: Any            # FileEditor or an error card
end

function Bonito.jsrender(session::Bonito.Session, c::PaneTabContent)
    node = DOM.div(c.editor; class = "bt-pp-tabcontent", dataTabId = c.id)
    Bonito.onload(session, node, js"""(el) => {
        const mount = el.closest('#bt-plotpane-mount');
        const active = mount ? (mount.dataset.activeTab || '') : '';
        el.style.display = (el.dataset.tabId === active) ? '' : 'none';
    }""")
    Bonito.jsrender(session, node)
end
