# KeyedList widget for one discovered Claude Code session row. Keyed on
# (path, session_id); re-scans returning the same data hit the same key and
# touch nothing. The row carries no in-progress UI state (the "Importing…"
# feedback lives only in the JS onclick handler), so we don't need extra
# instance stability beyond the key.

mutable struct SessionRow
    import_path :: Observable{Dict{String,Any}}
    path        :: String
    name        :: String
    session_id  :: String
    preview     :: String   # truncated first user-message; "" if unavailable
    meta        :: String
    running     :: Bool     # confirmed alive via OS-level pid check
    row_key     :: String   # "path|session_id"
end

function SessionRow(c::WorkerCard, r::AbstractDict)
    path       = String(get(r, "path", ""))
    name       = String(get(r, "name", basename(path)))
    sid_raw    = get(r, "session_id", nothing)
    session_id = sid_raw === nothing ? "" : String(sid_raw)
    preview_raw = get(r, "first_prompt", nothing)
    preview    = preview_raw isa AbstractString ? String(preview_raw) : ""
    meta = if haskey(r, "last_used")
        ts = get(r, "last_used", 0.0)
        dt = Dates.unix2datetime(ts isa Number ? Float64(ts) : 0.0)
        base = "Last used $(Dates.format(dt, "yyyy-mm-dd HH:MM"))"
        at = get(r, "agent_type", nothing)
        at === nothing ? base : base * "  ·  subagent: $at"
    else
        ""
    end
    # Three-valued `running` from the worker (true | false | nothing); only
    # explicit `true` produces a UI badge. `nothing` (OS check unavailable)
    # falls through silently.
    running = get(r, "running", nothing) === true
    row_key = string(path, '|', session_id)
    SessionRow(c.import_path, path, name, session_id, preview, meta, running, row_key)
end

Base.hash(s::SessionRow, h::UInt) = hash(s.row_key, hash(:SessionRow, h))
Base.:(==)(a::SessionRow, b::SessionRow) = a.row_key == b.row_key

function Bonito.jsrender(session::Bonito.Session, s::SessionRow)
    btn_label = isempty(s.session_id) ? "Import" : "Resume"
    running_pill = s.running ?
        DOM.span("running"; class = "bt-pill bt-pill-online") :
        DOM.span()
    # Inside a project group, the cwd is already shown in the group header,
    # so the per-row "path" line is redundant. Display the session's first
    # user prompt as a preview instead — falls back to the path if no
    # preview was extractable (rare: jsonl had no real user message yet).
    preview_node = isempty(s.preview) ?
        DOM.div(s.path; class = "bt-session-path") :
        DOM.div(s.preview; class = "bt-session-preview")
    return Bonito.jsrender(session, DOM.div(
        DOM.div(
            DOM.div(
                # Wrap the name text in a span so it can ellipsize when the
                # row is narrow.
                DOM.span(s.name; class = "bt-session-name-text"),
                running_pill;
                class = "bt-session-name"),
            preview_node,
            isempty(s.meta) ? DOM.span() : DOM.div(s.meta; class = "bt-session-meta");
            class = "bt-session-info"),
        DOM.div(btn_label;
            class   = "bt-btn bt-btn-secondary",
            style   = Styles("cursor" => "pointer", "flex-shrink" => "0"),
            onclick = js"""event => {
                const btn = event.currentTarget;
                btn.classList.add('bt-clicked');
                btn.textContent = $(btn_label) === 'Resume' ? 'Resuming…' : 'Importing…';
                // js_path: backslashes are invalid JS string escapes; forward
                // slashes round-trip cleanly and Julia accepts them on Windows.
                $(s.import_path).notify({path: $(js_path(s.path)), session_id: $(s.session_id)});
            }""");
        class = "bt-session-row"))
end

# One project's header + collapsed list of its session/subagent rows.
# Keyed on `path`; remounts only when a project disappears or appears. The
# nested KeyedList over `rows_obs` preserves child identity inside.
mutable struct SessionGroup
    path        :: String                           # KeyedList key
    name        :: String                           # basename(path)
    rows_obs    :: Observable{Vector{SessionRow}}   # nested KeyedList input
    summary_obs :: Observable{String}               # "5 sessions · 12 subagents · Last used …"
end

Base.hash(g::SessionGroup, h::UInt) = hash(g.path, hash(:SessionGroup, h))
Base.:(==)(a::SessionGroup, b::SessionGroup) = a.path == b.path

# Build the right-of-name summary line for a group given its (raw) result
# dicts. Counts sessions vs subagents using the `kind` field and reports the
# most recent `last_used` mtime.
function group_summary_string(rs::Vector)
    n_sessions  = 0
    n_subagents = 0
    n_running   = 0
    latest      = 0.0
    for r in rs
        if String(get(r, "kind", "session")) == "subagent"
            n_subagents += 1
        else
            n_sessions += 1
        end
        get(r, "running", nothing) === true && (n_running += 1)
        ts = get(r, "last_used", 0.0)
        ts isa Number && Float64(ts) > latest && (latest = Float64(ts))
    end
    parts = String[]
    n_sessions  > 0 && push!(parts, "$(n_sessions) session"   * (n_sessions  == 1 ? "" : "s"))
    n_running   > 0 && push!(parts, "$(n_running) running")
    n_subagents > 0 && push!(parts, "$(n_subagents) subagent" * (n_subagents == 1 ? "" : "s"))
    if latest > 0
        dt = Dates.unix2datetime(latest)
        push!(parts, "Last used $(Dates.format(dt, "yyyy-mm-dd HH:MM"))")
    end
    return join(parts, "  ·  ")
end

function Bonito.jsrender(session::Bonito.Session, g::SessionGroup)
    return Bonito.jsrender(session, DOM.details(
        DOM.summary(
            DOM.span(g.name; class = "bt-group-name"),
            DOM.span(g.path; class = "bt-group-path"),
            DOM.span(g.summary_obs; class = "bt-group-meta");
            class = "bt-group-summary"),
        DOM.div(KeyedList(g.rows_obs; key = sr -> sr.row_key);
            class = "bt-group-body");
        class = "bt-group"))   # default-closed: no `open` attribute
end
