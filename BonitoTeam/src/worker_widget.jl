# KeyedList-friendly widget for one worker row. Held stable per worker_id
# in dashboard_dom's `worker_cards` Dict; picker form + discover panel
# are sub-DOMs toggled via class-bound Observables so their state
# (folder picker selection, scan results, focus) survives open/close.

mutable struct WorkerCard
    state            :: ServerState
    worker_id        :: String          # KeyedList key
    error_obs        :: Observable{String}
    picker_state     :: Observable{String}    # worker_id of the open picker
    discover_state   :: Observable{String}    # worker_id of the open panel
    busy             :: Observable            # BUSY_IDLE-shape NamedTuple
    discover_busy    :: Observable{Bool}
    discover_results :: Observable{Vector{Dict{String,Any}}}
    import_path      :: Observable{Dict{String,Any}}
    do_import        :: Function
    trigger_scan     :: Function
    remote_picker    :: RemoteFolderPicker
    name_obs         :: Observable{String}
end

function WorkerCard(state::ServerState, worker_id::AbstractString;
                     error_obs::Observable{String},
                     picker_state::Observable{String},
                     discover_state::Observable{String},
                     busy::Observable,
                     discover_busy::Observable{Bool},
                     discover_results::Observable{Vector{Dict{String,Any}}},
                     import_path::Observable{Dict{String,Any}},
                     do_import::Function,
                     trigger_scan::Function)
    initial_name = haskey(state.workers[], worker_id) ?
                    state.workers[][worker_id].name : worker_id
    WorkerCard(state, String(worker_id),
                error_obs, picker_state, discover_state,
                busy, discover_busy, discover_results, import_path,
                do_import, trigger_scan,
                RemoteFolderPicker(worker_id),
                Observable(initial_name))
end

Base.hash(c::WorkerCard, h::UInt) = hash(c.worker_id, hash(:WorkerCard, h))
Base.:(==)(a::WorkerCard, b::WorkerCard) = a.worker_id == b.worker_id

function Bonito.jsrender(session::Bonito.Session, c::WorkerCard)
    state, wid = c.state, c.worker_id

    status_obs = map(state.workers) do workers
        w = get(workers, wid, nothing)
        w === nothing ? :unknown : w.status
    end
    subtitle_obs = map(state.workers) do workers
        w = get(workers, wid, nothing)
        w === nothing ? "(removed)" : worker_subtitle(w)
    end
    is_online_obs = map(s -> s == :online, status_obs)
    title_attr = let w = get(state.workers[], wid, nothing)
        w === nothing ? "(removed)" :
            "$(w.hostname) · home: $(w.home)"
    end

    new_proj_btn = Bonito.Button("+ Project"; style=nothing, class = "bt-btn bt-btn-secondary")
    discover_btn = Bonito.Button("Discover";  style=nothing, class = "bt-btn bt-btn-secondary")
    on(new_proj_btn.value) do clicked
        clicked || return
        c.picker_state[]   = c.picker_state[] == wid ? "" : wid
        c.discover_state[] = ""
        c.error_obs[]      = ""
    end
    on(discover_btn.value) do clicked
        clicked || return
        c.discover_state[] = c.discover_state[] == wid ? "" : wid
        c.picker_state[]   = ""
        c.error_obs[]      = ""
    end

    name_input = DOM.input(
        type  = "text",
        value = c.name_obs,
        class = "bt-card-name bt-card-name-edit",
        title = "Click to rename — Enter to save, Esc to cancel",
        onblur    = js"event => $(c.name_obs).notify(event.target.value)",
        onkeydown = js"""event => {
            if (event.key === 'Enter')  { event.target.blur(); }
            if (event.key === 'Escape') {
                event.target.value = event.target.defaultValue;
                event.target.blur();
            }
        }""")
    on(c.name_obs) do v
        new = strip(String(v))
        cur = haskey(state.workers[], wid) ? state.workers[][wid].name : wid
        isempty(new) && (c.name_obs[] = cur; return)
        new == cur && return
        try
            rename_worker!(state, wid, new)
            c.error_obs[] = ""
        catch e
            c.error_obs[] = "Rename failed: $(sprint(showerror, e))"
            c.name_obs[]  = cur
        end
    end

    status_dot_obs = map(status_obs) do s
        status_dot(s)
    end

    # Render both action variants; toggle visibility via class. Keeps the
    # Bonito.Button instances mounted so click handlers don't churn.
    online_class  = map(o -> o ? "bt-card-actions"            : "bt-card-actions bt-hidden", is_online_obs)
    offline_class = map(o -> o ? "bt-card-actions bt-hidden"  : "bt-card-actions",            is_online_obs)
    actions_block = DOM.div(
        DOM.div(discover_btn, new_proj_btn; class = online_class),
        DOM.div(DOM.span("offline"; class = "bt-pill bt-pill-muted"); class = offline_class))

    card_body = DOM.div(
        DOM.div(status_dot_obs, name_input; class = "bt-card-title"),
        DOM.div(subtitle_obs; class = "bt-card-meta", title = title_attr);
        class = "bt-card-body")

    card = DOM.div(card_body, actions_block; class = "bt-card")

    is_picking_obs = map(s -> s == wid, c.picker_state)
    picker_form    = render_remote_picker_form(c, wid)
    picker_class   = map(p -> p ? "bt-form-wrapper" : "bt-form-wrapper bt-hidden", is_picking_obs)
    picker_block   = DOM.div(picker_form; class = picker_class)

    is_discover_obs = map(s -> s == wid, c.discover_state)
    discover_block_dom = render_discover_panel(c, wid)
    discover_class = map(d -> d ? "bt-discover-wrapper" : "bt-discover-wrapper bt-hidden", is_discover_obs)
    discover_block = DOM.div(discover_block_dom; class = discover_class)

    return Bonito.jsrender(session,
        DOM.div(card, picker_block, discover_block;
                class = "bt-worker-cell"))
end

function render_remote_picker_form(c::WorkerCard, wid::String)
    create_btn = Bonito.Button("Create"; style=nothing, class = "bt-btn")
    cancel_btn = Bonito.Button("Cancel"; style=nothing, class = "bt-btn bt-btn-secondary")
    rp = c.remote_picker

    on(create_btn.value) do clicked
        clicked || return
        is_busy_idle(c.busy[]) || return
        chosen = String(strip(rp.selected[]))
        if isempty(chosen)
            c.error_obs[] = "Pick a folder on the worker first (Browse → Choose)."
            return
        end
        rp.selected[] = ""
        c.do_import(wid, chosen)
    end
    on(cancel_btn.value) do clicked
        clicked || return
        is_busy_idle(c.busy[]) || return
        c.picker_state[] = ""
        c.error_obs[]    = ""
    end

    display_name_obs = map(c.state.workers) do workers
        w = get(workers, wid, nothing)
        w === nothing ? wid : w.name
    end
    label_obs = map(n -> "Folder on $n", display_name_obs)

    DOM.div(
        DOM.label(label_obs),
        DOM.div(
            remote_folder_picker_render(rp),
            map(rp.selected) do sel
                isempty(sel) ? DOM.div() :
                    DOM.div("✓ selected: $sel",
                            style = Styles("color" => "#065f46",
                                            "font-size" => "12px",
                                            "margin-top" => "4px"))
            end),
        DOM.div(cancel_btn, create_btn, class = "bt-form-actions");
        class = "bt-form")
end

# All pieces (spinner, empty, errors, two KeyedLists, section labels) are
# mounted simultaneously; class-bound observables flip visibility so
# nothing re-renders on busy / results transitions.
function render_discover_panel(c::WorkerCard, wid::String)
    close_btn  = Bonito.Button("✕";       style=nothing, class = "bt-btn bt-btn-ghost")
    rescan_btn = Bonito.Button("↻ Rescan"; style=nothing, class = "bt-btn bt-btn-secondary")
    on(close_btn.value)  do clicked; clicked && (c.discover_state[] = ""); end
    on(rescan_btn.value) do clicked; clicked && c.trigger_scan(wid); end

    display_name_obs = map(c.state.workers) do workers
        w = get(workers, wid, nothing)
        w === nothing ? wid : w.name
    end
    title_obs = map(n -> "Claude Code sessions on $n", display_name_obs)

    spinner_msg_obs = map(n -> "Scanning $n for Claude Code sessions…", display_name_obs)
    spinner_class = map(b -> b ? "bt-spinner-row" : "bt-spinner-row bt-hidden",
                        c.discover_busy)
    spinner_block = DOM.div(
        DOM.div(class = "bt-spinner"),
        DOM.span(spinner_msg_obs);
        class = spinner_class)

    empty_msg_obs = map(n -> "No Claude Code sessions found on $n.", display_name_obs)
    show_empty_obs = map(c.discover_busy, c.discover_results) do busy, results
        !busy && isempty(results)
    end
    empty_class = map(show -> show ? "bt-empty" : "bt-empty bt-hidden", show_empty_obs)
    empty_block = DOM.div(empty_msg_obs; class = empty_class)

    # Errors are 0..N small spans, rebuilt via map(); KeyedList overkill.
    errors_obs = map(c.discover_results) do results
        DOM.div(
            (DOM.div("Error: $(r["error"])"; class = "bt-error")
             for r in results if haskey(r, "error"))...;
            class = "bt-errors-list")
    end

    # Active flag is part of the key so it remounts with the right badge.
    session_rows = Dict{String,SessionRow}()
    function get_session_row(r::AbstractDict)
        sr = SessionRow(c, r)
        get!(session_rows, sr.row_key, sr)
    end
    active_widgets_obs = map(c.discover_results) do results
        SessionRow[get_session_row(r) for r in results
                    if !haskey(r, "error") && get(r, "active", false) === true]
    end
    historical_widgets_obs = map(c.discover_results) do results
        SessionRow[get_session_row(r) for r in results
                    if !haskey(r, "error") && get(r, "active", false) !== true]
    end
    active_keyed_list     = KeyedList(active_widgets_obs;     key = s -> s.row_key)
    historical_keyed_list = KeyedList(historical_widgets_obs; key = s -> s.row_key)

    show_active_obs = map(active_widgets_obs, c.discover_busy) do rows, busy
        !busy && !isempty(rows)
    end
    show_hist_obs = map(historical_widgets_obs, c.discover_busy) do rows, busy
        !busy && !isempty(rows)
    end
    active_label_class = map(show -> show ? "bt-section-label" : "bt-section-label bt-hidden", show_active_obs)
    hist_label_class   = map(show -> show ? "bt-section-label" : "bt-section-label bt-hidden", show_hist_obs)
    active_list_class = map(show -> show ? "bt-discover-section" : "bt-discover-section bt-hidden", show_active_obs)
    hist_list_class   = map(show -> show ? "bt-discover-section" : "bt-discover-section bt-hidden", show_hist_obs)

    DOM.div(
        DOM.div(
            DOM.span(title_obs; class = "bt-discover-title"),
            DOM.div(rescan_btn, close_btn; class = "bt-discover-actions");
            class = "bt-discover-header"),
        spinner_block,
        empty_block,
        errors_obs,
        DOM.div("Active"; class = active_label_class),
        DOM.div(active_keyed_list; class = active_list_class),
        DOM.div("Historical"; class = hist_label_class),
        DOM.div(historical_keyed_list; class = hist_list_class);
        class = "bt-discover-panel bt-slide-in")
end
