# Shared progress callback contract used by the long-running operations
# (sync, project import, GitHub clone). RemoteSync already emits structured
# `(stage::Symbol, info::NamedTuple)` events; we mirror that signature for
# the rest of the stack so the dashboard's busy card can render structured
# progress (percent + recent files) instead of free-form strings.
#
# Stages we emit / consume:
#   :phase             — generic free-text update.   info = (msg=String,)
#   :walk_done         — manifest scan done.          info = (count=Int,)
#   :manifest_received — receiver got manifest.       info = (count=Int,)
#   :plan_received     — sender got plan.             info = (planned=Int, work=Int)
#   :file_start        — sender starts a file.        info = (idx=Int, total=Int, rel=String)
#   :apply_start       — receiver starts a file.      info = (idx=Int, total=Int, rel=String)
#   :transfer_done     — directory transfer done.     info = (files=Int,) | (written=Int, deleted=Int, skipped=Int)
#   :file_done, :file_chunk, :wait_manifest, :walk_start — informational, ignored by the UI
#
# Callbacks have signature `(stage::Symbol, info::NamedTuple) -> Any`.
# Errors raised from inside the callback are swallowed so a UI hiccup
# (e.g. a stale browser observable update) can never abort the transfer.

notify_progress(::Nothing, ::Symbol, ::NamedTuple) = nothing
function notify_progress(cb, stage::Symbol, info::NamedTuple)
    try
        cb(stage, info)
    catch err
        @debug "progress callback threw" stage exception=err
    end
    return nothing
end

# ── BusyState — what the dashboard's single-line progress pill renders ─────
# A NamedTuple snapshot of the current operation. The pill is hidden when
# `is_busy_idle(s)` returns true. Mutations happen by replacing the snapshot
# atomically (`busy[] = …`).
#
# The dashboard renders the pill by *deriving three Observable{String}s* off
# this one (title / pct / msg) and binding each to its own <span>. That hits
# Bonito's fast-path `Observable{String}` jsrender (innerText swap, no DOM
# replacement), so the pill updates in place without re-mounting — which
# matters: a librsync transfer fires thousands of file events and a fresh
# DOM tree per event would visibly flash.

const BUSY_IDLE = (
    title = "",
    msg   = "",
    done  = 0,
    total = 0,
)

is_busy_idle(s) = isempty(s.title) && isempty(s.msg)

# Begin a new operation. Clears any prior progress.
function busy_start!(obs::Observable, title::AbstractString, msg::AbstractString = "")
    BUSY_LAST_FILE_NS[] = UInt64(0)   # reset throttle so the very first file event lands
    safe_set!(obs, (
        title = String(title),
        msg   = String(msg),
        done  = 0,
        total = 0,
    ))
end

busy_clear!(obs::Observable) = safe_set!(obs, BUSY_IDLE)

# Per-file events arrive at librsync's pace (often 100s/sec); without a
# throttle we'd push thousands of WS frames per sync. 60ms ≈ 16fps which is
# plenty to read scrolling file paths and avoids saturating the channel.
const BUSY_FILE_THROTTLE_NS = 60_000_000  # 60 ms
const BUSY_LAST_FILE_NS = Ref{UInt64}(UInt64(0))

# Apply a structured progress event from RemoteSync / our :phase events.
function busy_event!(obs::Observable, stage::Symbol, info::NamedTuple)
    cur = obs[]
    next = if stage === :phase
        merge(cur, (msg = String(get(info, :msg, "")),))
    elseif stage === :walk_done
        merge(cur, (msg = "Scanning files: $(info.count) found",))
    elseif stage === :manifest_received
        merge(cur, (msg = "Receiving manifest: $(info.count) files",))
    elseif stage === :plan_received
        merge(cur, (msg = "Planning: $(info.work) of $(info.planned) need transfer",))
    elseif stage === :file_start || stage === :apply_start
        idx   = Int(info.idx)
        total = Int(info.total)
        # Always emit the last file event; throttle in between.
        if idx != total
            now = time_ns()
            (now - BUSY_LAST_FILE_NS[]) < BUSY_FILE_THROTTLE_NS && return nothing
            BUSY_LAST_FILE_NS[] = now
        end
        verb = stage === :file_start ? "sending" : "receiving"
        rel  = String(info.rel)
        merge(cur, (
            done  = idx,
            total = total,
            msg   = "$verb $idx/$total · $rel",
        ))
    elseif stage === :transfer_done
        merge(cur, (msg = "Transfer complete", done = max(cur.total, cur.done)))
    else
        cur   # ignore informational stages (:walk_start, :file_chunk, etc.)
    end
    safe_set!(obs, next)
    return nothing
end

# Render a progress event as a single human-readable line. Used by callers
# that surface progress as a plain string (e.g. the chat header's "Sync"
# button which reuses one Observable{String} for label + status).
function format_progress_string(stage::Symbol, info::NamedTuple)::String
    if stage === :phase
        return String(get(info, :msg, ""))
    elseif stage === :walk_done
        return "Scanning files: $(info.count) found"
    elseif stage === :manifest_received
        return "Receiving manifest: $(info.count) files"
    elseif stage === :plan_received
        return "Planning: $(info.work) of $(info.planned) need transfer"
    elseif stage === :file_start
        return "Sending $(info.idx)/$(info.total): $(info.rel)"
    elseif stage === :apply_start
        return "Receiving $(info.idx)/$(info.total): $(info.rel)"
    elseif stage === :transfer_done
        return haskey(info, :written) ?
            "Transfer complete: $(info.written) wrote, $(info.deleted) deleted, $(info.skipped) skipped" :
            "Transfer complete: $(get(info, :files, 0)) files"
    end
    return ""
end
