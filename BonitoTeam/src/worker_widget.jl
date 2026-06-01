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
    on(new_proj_btn.value) do clicked
        clicked || return
        c.picker_state[]   = c.picker_state[] == wid ? "" : wid
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

    # Remove worker. The confirm() lives in JS so we never fire the
    # destructive call without an explicit OK; only then does the trigger
    # Observable flip and the Julia handler run `remove_worker!`.
    remove_trigger = Observable(false)
    on(remove_trigger) do go
        go || return
        try
            remove_worker!(state, wid)
            c.error_obs[] = ""
        catch e
            c.error_obs[] = "Remove failed: $(sprint(showerror, e))"
        end
    end
    remove_btn = DOM.div("✕";
        class = "bt-card-remove",
        title = "Remove this worker",
        onclick = js"""event => {
            event.stopPropagation();
            if (confirm("Remove this worker and its projects from the list?\n\nChat history files are kept on disk. A worker whose process is still running may reconnect."))
                $(remove_trigger).notify(true);
        }""")

    # Render both action variants; toggle visibility via class. Keeps the
    # Bonito.Button instances mounted so click handlers don't churn.
    online_class  = map(o -> o ? "bt-card-actions"            : "bt-card-actions bt-hidden", is_online_obs)
    offline_class = map(o -> o ? "bt-card-actions bt-hidden"  : "bt-card-actions",            is_online_obs)
    actions_block = DOM.div(
        DOM.div(new_proj_btn; class = online_class),
        DOM.div(DOM.span("offline"; class = "bt-pill bt-pill-muted"); class = offline_class))

    card_body = DOM.div(
        DOM.div(status_dot_obs, name_input, remove_btn; class = "bt-card-title"),
        DOM.div(subtitle_obs; class = "bt-card-meta", title = title_attr);
        class = "bt-card-body")

    card = DOM.div(card_body, actions_block; class = "bt-card")

    is_picking_obs = map(s -> s == wid, c.picker_state)
    picker_form    = render_remote_picker_form(c, wid)
    picker_class   = map(p -> p ? "bt-form-wrapper" : "bt-form-wrapper bt-hidden", is_picking_obs)
    picker_block   = DOM.div(picker_form; class = picker_class)

    # The folder→threads browser is now ALWAYS visible (persistent), fed from
    # state.discovered — no Discover toggle. Folders are collapsable <details>.
    discover_block = DOM.div(render_discover_panel(c, wid); class = "bt-discover-wrapper")

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

# Persistent folder→threads browser for one worker. Reads from the
# server-side `state.discovered[wid]` cache (saved to discovered.json), so the
# tree survives a restart with no re-scan; the per-card Rescan button refreshes
# it. All pieces (spinner, empty, errors, the KeyedList of folder groups) are
# mounted simultaneously; class-bound observables flip visibility so nothing
# re-renders on busy / results transitions.
function render_discover_panel(c::WorkerCard, wid::String)
    # Per-card scan-in-flight flag so rescanning one worker doesn't spin every
    # other worker's panel.
    scan_busy = Observable(false)
    rescan_trigger = Observable(false)
    on(rescan_trigger) do go
        go || return
        scan_busy[] && return
        scan_busy[] = true
        @async try
            scan_and_store!(c.state, wid)
        catch e
            c.error_obs[] = "Scan failed: $(sprint(showerror, e))"
        finally
            scan_busy[] = false
        end
    end
    # Plain DOM (not Bonito.Button) so the onclick can `preventDefault` the
    # enclosing <details> summary toggle (Rescan should NOT collapse the panel
    # — it should open it so the spinner / refreshed tree are visible), and
    # `stopPropagation` belt-and-braces.
    rescan_btn = DOM.span("↻ Rescan";
        class = "bt-btn bt-btn-secondary",
        style = Styles("cursor" => "pointer"),
        onclick = js"""event => {
            event.preventDefault(); event.stopPropagation();
            const d = event.currentTarget.closest('details');
            if (d) d.open = true;
            $(rescan_trigger).notify(true);
        }""")

    # This worker's persisted scan results (worker_id → Vector of session dicts).
    results_obs = map(c.state.discovered) do d
        get(d, wid, Dict{String,Any}[])
    end

    display_name_obs = map(c.state.workers) do workers
        w = get(workers, wid, nothing)
        w === nothing ? wid : w.name
    end
    title_obs = map(n -> "Folders & threads on $n", display_name_obs)

    spinner_msg_obs = map(n -> "Scanning $n for Claude Code sessions…", display_name_obs)
    spinner_class = map(b -> b ? "bt-spinner-row" : "bt-spinner-row bt-hidden", scan_busy)
    spinner_block = DOM.div(
        DOM.div(class = "bt-spinner"),
        DOM.span(spinner_msg_obs);
        class = spinner_class)

    empty_msg_obs = map(n -> "No Claude Code sessions found on $n yet — click Rescan.", display_name_obs)
    show_empty_obs = map(scan_busy, results_obs) do busy, results
        !busy && isempty(results)
    end
    empty_class = map(show -> show ? "bt-empty" : "bt-empty bt-hidden", show_empty_obs)
    empty_block = DOM.div(empty_msg_obs; class = empty_class)

    # Errors are 0..N small spans, rebuilt via map(); KeyedList overkill.
    errors_obs = map(results_obs) do results
        DOM.div(
            (DOM.div("Error: $(r["error"])"; class = "bt-error")
             for r in results if haskey(r, "error"))...;
            class = "bt-errors-list")
    end

    # Two-level rendering: one project group per cwd, each containing the
    # session/subagent rows from that project. Both levels use KeyedList
    # for stable identity across rescans — opening a group survives a
    # Refresh because the <details> DOM node is preserved when its key
    # (= path) is unchanged.
    #
    # Caches are pruned each tick to avoid unbounded growth if a project
    # disappears between scans (e.g. its on-disk jsonl was deleted).
    session_groups = Dict{String, SessionGroup}()
    session_rows   = Dict{String, SessionRow}()

    function get_session_row(r::AbstractDict)
        sr = SessionRow(c, r)
        get!(session_rows, sr.row_key, sr)
    end

    groups_obs = map(results_obs) do results
        by_path  = Dict{String, Vector{Any}}()
        latest_by_path = Dict{String, Float64}()
        for r in results
            haskey(r, "error") && continue
            # Subagents share their parent's process and aren't user-startable.
            # Surface only top-level sessions. A project whose only entries are
            # subagents (e.g. older Claude Code versions that didn't persist the
            # parent jsonl) drops out of the list entirely.
            String(get(r, "kind", "session")) == "subagent" && continue
            p = String(get(r, "path", ""))
            push!(get!(by_path, p, Any[]), r)
            ts = get(r, "last_used", 0.0)
            t = ts isa Number ? Float64(ts) : 0.0
            t > get(latest_by_path, p, 0.0) && (latest_by_path[p] = t)
        end
        out = SessionGroup[]
        seen_row_keys = Set{String}()
        for (p, rs) in by_path
            sort!(rs; by = r -> -Float64(get(r, "last_used", 0.0)))
            rows = SessionRow[get_session_row(r) for r in rs]
            for sr in rows; push!(seen_row_keys, sr.row_key); end
            g = get!(session_groups, p) do
                SessionGroup(p, basename(p),
                             Observable(rows), Observable(""),
                             wid, c.import_path)
            end
            g.rows_obs[]    = rows
            g.summary_obs[] = group_summary_string(rs)
            push!(out, g)
        end
        # Prune stale cache entries (paths/rows no longer present).
        for k in collect(keys(session_groups))
            haskey(by_path, k) || delete!(session_groups, k)
        end
        for k in collect(keys(session_rows))
            k in seen_row_keys || delete!(session_rows, k)
        end
        sort!(out; by = g -> -get(latest_by_path, g.path, 0.0))
        return out
    end

    groups_keyed_list = KeyedList(groups_obs; key = g -> g.path)

    # The whole tree is now a collapsable `<details>` so the worker card stays
    # compact by default ("BOOM — opens the list on click"). Rescan inside the
    # summary preventDefaults the toggle and force-opens, so the user always
    # sees scan progress + refreshed results.
    DOM.details(
        DOM.summary(
            DOM.span(title_obs; class = "bt-discover-title"),
            DOM.div(rescan_btn; class = "bt-discover-actions");
            class = "bt-discover-header"),
        spinner_block,
        empty_block,
        errors_obs,
        DOM.div(groups_keyed_list; class = "bt-discover-section");
        class = "bt-discover-panel")
end
