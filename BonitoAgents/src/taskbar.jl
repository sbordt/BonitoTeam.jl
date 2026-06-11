# ── TaskBar: the pin-board for long-running work ─────────────────────────────
# A Bonito component, state-first: Julia owns ONE list of pinned items on the
# shared ChatModel (`taskbar_items`); the widget renders it as plain Julia
# DOM. Nothing here scans the chat's (virtually scrolled) DOM — scrolling,
# node recycling and remounts cannot affect the bar, because the bar never
# looks at them.
#
# Items are pinned/unpinned by the SAME Julia code that drives the tool
# lifecycle (`process!` / `process_update!` / the bg poller / the todo
# lifecycle) — see `pin_task!` / `unpin_task!` in chat.jl.

struct TaskbarItem
    id        :: String
    kind      :: Symbol                       # :tool | :todo
    icon      :: String
    label     :: String
    started   :: Float64
    stoppable :: Bool
    # 0-based index of the source message in the chat store (stable: the
    # store is append-only). Lets a slot click scroll the chat there
    # DETERMINISTICALLY via the virtual scroller's geometry — a node-based
    # scrollIntoView only works when the pill happens to be rendered.
    msg_index :: Int                          # -1 = no chat anchor
    # Todo lists only: every entry, rendered in full — finished ones are
    # crossed out, the in-progress one highlighted.
    entries   :: Vector{Tuple{String,String}} # (content, status)
end

TaskbarItem(id, kind, icon, label; started = time(), stoppable = false,
            msg_index = -1, entries = Tuple{String,String}[]) =
    TaskbarItem(String(id), kind, String(icon), String(label),
                Float64(started), stoppable, Int(msg_index),
                collect(Tuple{String,String}, entries))

"""
    TaskBar(items::Observable{Vector{TaskbarItem}}) -> TaskBar

The chat's pin-board. `stop_request` fires with the item id when the user
clicks an item's ⊗ — the chat render wires it to `request_tool_stop!`.
"""
struct TaskBar
    items        :: Observable{Vector{TaskbarItem}}
    stop_request :: Observable{String}
end

TaskBar(items::Observable{Vector{TaskbarItem}}) = TaskBar(items, Observable(""))

function render_taskbar_item(bar::TaskBar, item::TaskbarItem)
    head = Any[
        DOM.span(item.icon; class = "bt-taskbar-slot-icon"),
        DOM.span(item.label; class = "bt-taskbar-slot-label"),
        DOM.span(""; class = "bt-taskbar-slot-timer",
                 dataStarted = string(item.started)),
    ]
    # Always-visible stop, styled like the composer's stop button
    # (.bt-stop-mini draws the red square).
    item.stoppable && push!(head, DOM.button(;
        type = "button", class = "bt-taskbar-slot-stop bt-stop-mini",
        title = "Stop",
        onclick = js"event => { event.stopPropagation(); $(bar.stop_request).notify($(item.id)); }"))
    if item.kind === :todo
        rows = map(item.entries) do (content, status)
            cls = status == "completed"   ? "bt-taskbar-todo-item bt-todo-done" :
                  status == "in_progress" ? "bt-taskbar-todo-item bt-todo-active" :
                                            "bt-taskbar-todo-item"
            DOM.div(content; class = cls)
        end
        DOM.div(DOM.div(head...; class = "bt-taskbar-todo-head"), rows...;
                class = "bt-taskbar-slot bt-taskbar-todo")
    else
        # data-msg-index feeds the chat module's click-to-scroll (jump the
        # virtual scroller to the source pill).
        DOM.div(head...; class = "bt-taskbar-slot",
                dataTaskId = item.id, dataMsgIndex = string(item.msg_index))
    end
end

function Bonito.jsrender(session::Bonito.Session, bar::TaskBar)
    # Whole-bar re-render per update is fine: a handful of pinned items,
    # plain DOM (AGENTS.md §5 — small bounded region). Per-render click
    # handlers live in the map's sub-session, freed on the next render.
    slots = map(session, bar.items) do items
        isempty(items) ?
            DOM.div(; class = "bt-taskbar-slots",
                    style = Styles("display" => "none")) :
            DOM.div((render_taskbar_item(bar, it) for it in items)...;
                    class = "bt-taskbar-slots")
    end
    root = DOM.div(slots; class = "bt-taskbar")
    # Elapsed-time ticker — pure presentation, scoped to this bar's element;
    # stops itself when the bar leaves the DOM.
    Bonito.onload(session, root, js"""(el) => {
        const fmt = (sec) => {
            if (sec < 60) return Math.round(sec) + 's';
            const m = Math.floor(sec / 60), s = Math.round(sec - m * 60);
            return s === 0 ? m + 'm' : m + 'm' + s + 's';
        };
        const tick = () => {
            if (!el.isConnected) { clearInterval(h); return; }
            const now = Date.now() / 1000;
            el.querySelectorAll('[data-started]').forEach((t) => {
                const dt = now - parseFloat(t.dataset.started);
                t.textContent = dt > 1 ? fmt(dt) : '';
            });
        };
        const h = setInterval(tick, 1000);
        tick();
    }""")
    return Bonito.jsrender(session, root)
end
