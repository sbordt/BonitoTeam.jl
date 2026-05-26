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
    meta        :: String
    row_key     :: String   # "path|session_id"
end

function SessionRow(c::WorkerCard, r::AbstractDict)
    path       = String(get(r, "path", ""))
    name       = String(get(r, "name", basename(path)))
    sid_raw    = get(r, "session_id", nothing)
    session_id = sid_raw === nothing ? "" : String(sid_raw)
    meta = if haskey(r, "last_used")
        ts = get(r, "last_used", 0.0)
        dt = Dates.unix2datetime(ts isa Number ? Float64(ts) : 0.0)
        "Last used $(Dates.format(dt, "yyyy-mm-dd HH:MM"))"
    else
        ""
    end
    row_key = string(path, '|', session_id)
    SessionRow(c.import_path, path, name, session_id, meta, row_key)
end

Base.hash(s::SessionRow, h::UInt) = hash(s.row_key, hash(:SessionRow, h))
Base.:(==)(a::SessionRow, b::SessionRow) = a.row_key == b.row_key

function Bonito.jsrender(session::Bonito.Session, s::SessionRow)
    btn_label = isempty(s.session_id) ? "Import" : "Resume"
    return Bonito.jsrender(session, DOM.div(
        DOM.div(
            DOM.div(
                # Wrap the name text in a span so it can ellipsize when the
                # row is narrow.
                DOM.span(s.name; class = "bt-session-name-text");
                class = "bt-session-name"),
            DOM.div(s.path; class = "bt-session-path"),
            isempty(s.meta) ? DOM.span() : DOM.div(s.meta; class = "bt-session-meta");
            class = "bt-session-info"),
        DOM.div(btn_label;
            class   = "bt-btn bt-btn-secondary",
            style   = Styles("cursor" => "pointer", "flex-shrink" => "0"),
            onclick = js"""event => {
                const btn = event.currentTarget;
                btn.classList.add('bt-clicked');
                btn.textContent = $(btn_label) === 'Resume' ? 'Resuming…' : 'Importing…';
                $(s.import_path).notify({path: $(s.path), session_id: $(s.session_id)});
            }""");
        class = "bt-session-row"))
end
