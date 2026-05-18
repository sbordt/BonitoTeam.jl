# KeyedList widget for one discovered Claude Code session row. Keyed on
# (path, session_id, active) — an active flip remounts the row with the
# updated badge; re-scans returning the same data hit the same key and
# touch nothing. The row carries no in-progress UI state (the
# "Importing…" feedback lives only in the JS onclick handler), so we
# don't need instance stability across active-flag changes.

mutable struct SessionRow
    import_path :: Observable{Dict{String,Any}}
    path        :: String
    name        :: String
    session_id  :: String
    is_active   :: Bool
    meta        :: String
    row_key     :: String   # "path|session_id|active"
end

function SessionRow(c::WorkerCard, r::AbstractDict)
    path       = String(get(r, "path", ""))
    name       = String(get(r, "name", basename(path)))
    is_active  = get(r, "active", false) === true
    sid_raw    = get(r, "session_id", nothing)
    session_id = sid_raw === nothing ? "" : String(sid_raw)
    meta = if is_active
        "PID $(get(r, "pid", "?"))"
    elseif haskey(r, "last_used")
        ts = get(r, "last_used", 0.0)
        dt = Dates.unix2datetime(ts isa Number ? Float64(ts) : 0.0)
        "Last used $(Dates.format(dt, "yyyy-mm-dd HH:MM"))"
    else
        ""
    end
    row_key = string(path, '|', session_id, '|', is_active)
    SessionRow(c.import_path, path, name, session_id, is_active, meta, row_key)
end

Base.hash(s::SessionRow, h::UInt) = hash(s.row_key, hash(:SessionRow, h))
Base.:(==)(a::SessionRow, b::SessionRow) = a.row_key == b.row_key

function Bonito.jsrender(session::Bonito.Session, s::SessionRow)
    badge = s.is_active ?
        DOM.span("active"; class = "bt-pill bt-pill-active") : DOM.span()
    btn_label = isempty(s.session_id) ? "Import" : "Resume"
    return Bonito.jsrender(session, DOM.div(
        DOM.div(
            DOM.div(s.name, badge; class = "bt-session-name"),
            DOM.div(s.path; class = "bt-session-path"),
            isempty(s.meta) ? DOM.span() : DOM.div(s.meta; class = "bt-session-meta")),
        DOM.div(btn_label;
            class   = "bt-btn bt-btn-secondary",
            style   = Styles("cursor" => "pointer", "flex-shrink" => "0"),
            onclick = js"""event => {
                const btn = event.currentTarget;
                btn.classList.add('bt-clicked');
                btn.textContent = $(btn_label) === 'Resume' ? 'Resuming…' : 'Importing…';
                $(s.import_path).notify({path: $(s.path), session_id: $(s.session_id)});
            }""");
        class = s.is_active ? "bt-session-row bt-session-active" : "bt-session-row"))
end
