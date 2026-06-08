# Left-edge nav strip shared by the unified app's main panel — one entry
# per project plus a "home" icon. Each entry click flips `current_view`
# (Observable{String}); the App's main panel reactively swaps to either
# the dashboard (current_view == "") or that project's chat.
#
# Icons are auto-generated: initials from the project name, background
# colour deterministically derived from the project id (so the same
# project always gets the same colour across reloads).

"""
    project_initials(name) → String

Two uppercase characters that sum up `name` for a 32-px icon. Splits on
whitespace / dash / dot / underscore / slash; if there are two or more
"words", takes the first letter of each of the first two; otherwise
takes the first two letters of the only word.
"""
function project_initials(name::AbstractString)
    s = strip(name)
    isempty(s) && return "?"
    parts = split(s, r"[\s\-_/.]+"; keepempty = false)
    isempty(parts) && return "?"
    if length(parts) >= 2
        return uppercase(string(first(parts[1]), first(parts[2])))
    end
    word = parts[1]
    return uppercase(length(word) >= 2 ? String(word[1:2]) : String(word))
end

"""
    project_color(id) → String

A CSS `hsl(...)` value seeded by `id`. Saturation/lightness are fixed so
every icon looks balanced; only hue varies. Same id → same colour.
"""
function project_color(id::AbstractString)
    hue = abs(hash(id) % 360)
    return "hsl($(hue), 60%, 48%)"
end

# Renders one icon. The colour stays seeded by `p.id` (visually identifies
# the project across surfaces); the *contents* default to the worker's
# initials (`[DT]`-style — Desktop/HP Laptop/…) so the user reads from a
# glance which machine hosts the chat. Pass `worker_tag = ""` to fall back
# to the folder initials (used when a worker isn't connected). `size_px`
# lets the sidebar reuse this at 32 px and the project_card at e.g. 24 px.
function project_icon(p::ProjectInfo, worker_tag::AbstractString = "";
                       size_px::Int = 32)
    label = isempty(worker_tag) ? project_initials(p.name) : String(worker_tag)
    tip   = isempty(worker_tag) ? p.name : "$(worker_tag) · $(p.name)"
    DOM.div(label;
        class = "bt-proj-icon",
        style = string("background:", project_color(p.id), ";",
                       "width:$(size_px)px;height:$(size_px)px;",
                       "line-height:$(size_px)px;font-size:$(round(Int, size_px*0.42))px"),
        title = tip)
end

# A single sidebar row: icon + label + identifying data-attribute. NO
# Observables interpolated in here — the click handler and the
# active-highlight class swap are delegated from the outer `<aside>`,
# so this DOM can be recycled by the structural `map(state.projects)`
# below without churning any tracked Observable IDs.
function sidebar_entry(label::AbstractString, icon::Bonito.Node,
                        target_value::AbstractString, title::AbstractString;
                        active::Bool = false, closeable::Bool = false,
                        extra_class::AbstractString = "")
    # The icon now carries the worker initials (project_icon does the
    # styling); the title span only needs the chat title text.
    kids = Any[icon, DOM.span(label; class = "bt-side-name")]
    # A ✕ to close (stop) an active chat. Plain markup — the delegated
    # handler on the aside reads `.bt-side-close` and routes to close_trigger
    # rather than current_view, so no per-entry Observable is interpolated
    # into the recyclable body.
    closeable && push!(kids, DOM.span("✕"; class = "bt-side-close", title = "Close chat"))
    cls = "bt-side-item" * (active ? " bt-side-active" : "")
    isempty(extra_class) || (cls = cls * " " * String(extra_class))
    DOM.div(kids...;
        class = cls,
        title = title,
        # `data-project-id` is the empty string for "Home" (the dashboard
        # entry) and the project id for everything else. The delegated
        # click handler reads this to know which view to switch to.
        dataProjectId = target_value)
end

"""
    sidebar_resumable_projects(projects, discovered, open_set) -> Vector{ProjectInfo}

Projects whose Claude Code session is currently running on the worker (per the
cached discover scan) but which aren't already open as a live ChatModel. These
are what should re-fill the sidebar after a server restart — the agent process
is still alive on the worker, the user just needs to click it to resume the
session via `session/load`.

Match rule: `discovered[project.worker_id]` has a record with
`path == project.worker_path` and `running == true`. We don't require the
record's `session_id` to match `project.resume_session_id` — any running
session at that path makes the project resumable (resume_session_id is the
hint the bring-up uses; matching at the path is enough to surface the entry).
"""
function sidebar_resumable_projects(projects::AbstractDict{<:AbstractString,ProjectInfo},
                                     discovered::AbstractDict,
                                     open_set::AbstractSet{<:AbstractString})
    out = ProjectInfo[]
    for (pid, p) in projects
        pid in open_set && continue
        scans = get(discovered, p.worker_id, nothing)
        scans === nothing && continue
        for r in scans
            haskey(r, "error") && continue
            String(get(r, "path", "")) == p.worker_path && get(r, "running", false) === true || continue
            push!(out, p)
            break
        end
    end
    return out
end

const HOME_ICON = Bonito.Asset(joinpath(@__DIR__, "..", "assets", "icons", "home.svg"))

"""
    project_sidebar(session, state, current_view) → DOM

Always-visible vertical nav. Top entry is "Home" (dashboard view); below
it, one entry per registered project.

The body re-renders ONLY when `state.projects` changes (project add /
remove / rename). Worker churn doesn't touch this section, so connecting
a new laptop or a worker going offline does not trigger any sidebar
work. Navigation (`current_view` change) does NOT
trigger a re-render: the click handler is delegated on the outer
`<aside>` via `onload`, and active-highlighting is handled by an `onjs`
class swap on the existing DOM. This matters because every re-render
tears down the body subsession, and any Observable interpolated into
that subsession's DOM gets caught in a tracked-object refcount race
with the new subsession (Bonito Sessions.js GLOBAL_OBJECT_CACHE). By
keeping `current_view` only on the OUTER aside (parent session, never
torn down), it crosses the JS bridge once at initial render and stays
in cache forever.
"""
function project_sidebar(session::Bonito.Session, state::ServerState,
                          current_view::Observable{String})
    # The home glyph isn't a project — it's nav. Renders as a borderless
    # 32px slot so it visually reads as "go home" instead of competing
    # with the colored project tiles below it.
    home_icon = DOM.div(
        DOM.img(src = HOME_ICON, alt = "Home", draggable = "false",
                style = Styles("width" => "18px", "height" => "18px",
                               "display" => "block", "pointer-events" => "none"));
        class = "bt-side-home-icon",
        title = "Dashboard")

    # Closing an active chat from the sidebar: tear its session down and, if it
    # was the one on screen, fall back to the dashboard. Interpolated once on
    # the aside's onload (below), never into the recyclable body.
    close_trigger = Observable("")
    on(session, close_trigger) do pid
        isempty(pid) && return
        p = get(state.projects[], pid, nothing)
        p === nothing && return
        try
            stop_session!(state, p)
        catch e
            @warn "sidebar: closing chat failed" project = p.name exception = e
        end
        current_view[] == pid && (current_view[] = "")
    end

    # The left strip is now an ACTIVE-CHATS switcher: one entry per running
    # ChatModel (`state.chat_models`), not per registered project. It also
    # picks up "resumable" projects — ones whose Claude Code session is
    # currently running on the worker (per the cached discover scan) but
    # which the server hasn't brought up yet (e.g. fresh after a server
    # restart). Those render dimmer and clicking them does the normal
    # current_view = pid path, which `ensure_project_session!` turns into a
    # `session/load` resume. Re-renders on `chat_signal` (a chat opened/
    # closed), `discovered` (a worker rescan), or project/worker changes.
    body = map(state.chat_signal, state.projects, state.workers, state.discovered) do _, projects, workers, discovered
        active_pid = current_view[]
        open_ids = lock(state.lock) do
            collect(keys(state.chat_models))
        end
        open_set = Set{String}(open_ids)
        open_projs = ProjectInfo[projects[id] for id in open_ids if haskey(projects, id)]
        sort!(open_projs; by = p -> lowercase(p.name))

        # Resumable: projects with a `running == true` discover record matching
        # (worker_id, worker_path), AND which aren't already open. Survives a
        # server restart since `discovered` is loaded from disk on boot.
        resumable_projs = sidebar_resumable_projects(projects, discovered, open_set)
        sort!(resumable_projs; by = p -> lowercase(p.name))

        entries = Any[sidebar_entry("Home", home_icon, "", "Dashboard";
                                    active = active_pid == "")]
        # New label format: `[WW] <title>` where WW is the worker's editable
        # initials and title is the (possibly auto-backfilled) chat title.
        # The `[WW]` lives in its own span so the title can ellipsize / wrap
        # over two lines without breaking the tag. Two siblings of the same
        # folder still need a tail thread-tag to disambiguate when their
        # titles coincide.
        wtag(p) = haskey(workers, p.worker_id) ?
                    worker_initials(workers[p.worker_id]) :
                    derive_initials(p.worker_id)
        base(p) = project_display_title(p)
        base_counts = Dict{String,Int}()
        for p in open_projs; base_counts[base(p)] = get(base_counts, base(p), 0) + 1; end
        for p in open_projs
            t = wtag(p)
            b = base(p)
            label = base_counts[b] > 1 ? "$b · $(thread_tag(p))" : b
            tooltip = "[$t] $label · folder: $(p.name)"
            push!(entries,
                  sidebar_entry(label, project_icon(p, t), p.id, tooltip;
                                active = active_pid == p.id, closeable = true))
        end
        if !isempty(resumable_projs)
            push!(entries, DOM.div("Running on worker"; class = "bt-side-section"))
            for p in resumable_projs
                t = wtag(p)
                b = base(p)
                tooltip = "[$t] $b · folder: $(p.name) · resumable"
                # Clicking pulls them up the normal way (current_view = pid),
                # which `ensure_project_session!` resolves to a session/load resume.
                push!(entries,
                      sidebar_entry(b, project_icon(p, t), p.id, tooltip;
                                    active = active_pid == p.id,
                                    closeable = false,
                                    extra_class = "bt-side-resumable"))
            end
        end
        isempty(open_projs) && isempty(resumable_projs) && push!(entries,
            DOM.div("No open chats yet — open one from the dashboard.";
                    class = "bt-side-empty"))
        DOM.div(entries...; class = "bt-side-list")
    end

    aside = DOM.aside(body; class = "bt-sidebar")

    # Delegated click handler: one listener on the aside. A click on a
    # `.bt-side-close` ✕ routes to `close_trigger`; anything else on a
    # `.bt-side-item` switches `current_view`. Both Observables enter the JS
    # object cache here exactly once and never get re-tracked by a recycling
    # subsession.
    #
    # Last-route memory: complements Bonito's soft_close session reconnect
    # (which preserves Observable state for an hour, set in `serve()`). When
    # that timeout DOES lapse, or the user opens a fresh tab, this onload
    # restores `current_view` from localStorage so you still land on your last
    # chat instead of getting bounced to home. We only restore IF the entry
    # for that pid exists (worker still has the project) — otherwise fall
    # back to home so a deleted project doesn't strand the user on an empty view.
    Bonito.onload(session, aside, js"""(el) => {
        const LAST_PID_KEY = 'bt-last-pid';
        el.addEventListener('click', e => {
            const close = e.target.closest('.bt-side-close');
            if (close) {
                e.stopPropagation();
                const item = close.closest('.bt-side-item');
                if (item) $(close_trigger).notify(item.dataset.projectId || '');
                return;
            }
            const item = e.target.closest('.bt-side-item');
            if (item) $(current_view).notify(item.dataset.projectId || '');
        });
        // Restore last route on fresh sessions (when soft_close didn't catch us).
        const saved = localStorage.getItem(LAST_PID_KEY);
        if (saved) {
            // Only restore if that sidebar entry exists right now — projects can
            // be deleted while you're away, and we don't want to navigate to a
            // dangling pid (the loading view would show an error).
            const entry = el.querySelector('.bt-side-item[data-project-id="' + saved.replace(/"/g, '') + '"]');
            if (entry) $(current_view).notify(saved);
        }
    }""")

    # Active-highlight swap: when current_view changes, find every
    # sidebar item, toggle .bt-side-active based on data-project-id
    # match. No DOM replacement, no subsession recycling. Also persists the
    # current pid to localStorage so a hard reconnect (past soft_close window
    # OR a fresh tab) can restore it via the onload above.
    Bonito.onjs(session, current_view, js"""(pid) => {
        document.querySelectorAll('.bt-sidebar .bt-side-item').forEach(el => {
            el.classList.toggle('bt-side-active', el.dataset.projectId === pid);
        });
        try { localStorage.setItem('bt-last-pid', pid || ''); } catch (e) {}
    }""")

    return aside
end

# CSS for the sidebar + icons. Mobile (≤640px) collapses to icons-only at
# 56px wide; desktop expands to 200px with the project name to the right
# of each icon.
const SidebarStyles = Bonito.Styles(
    CSS(".bt-sidebar",
        # Normal flex child of `.bt-shell` rather than `position: fixed`. The
        # old fixed positioning was relative to the viewport, so on wide
        # monitors the sidebar pinned to viewport-left while the centered
        # main panel floated far away — visually disconnecting them. Inside
        # the shell flexbox, it sits flush against the main column.
        "width" => "200px", "flex-shrink" => "0",
        "background" => "var(--bt-surface)",
        "border-right" => "1px solid var(--bt-border)",
        "overflow-y" => "auto", "overflow-x" => "hidden",
        "display" => "flex", "flex-direction" => "column",
        "padding" => "10px 0"),
    CSS(".bt-side-list",
        "display" => "flex", "flex-direction" => "column", "gap" => "2px"),
    CSS(".bt-side-item",
        # `align-items: flex-start` keeps the icon at the top of two-line
        # titles instead of jumping down to vertical-center the row.
        "display" => "flex", "align-items" => "flex-start", "gap" => "8px",
        "padding" => "6px 10px",
        "cursor" => "pointer",
        "border-left" => "3px solid transparent",
        "transition" => "background 80ms"),
    CSS(".bt-side-item:hover",
        "background" => "var(--bt-surface-2)"),
    CSS(".bt-side-active",
        "border-left-color" => "var(--bt-accent)",
        "background" => "var(--bt-surface-2)"),
    # Subheader for the "Running on worker" group. Dim, uppercase, small —
    # reads as a section label, not an item.
    CSS(".bt-side-section",
        "padding" => "10px 12px 4px",
        "font-size" => "10.5px", "font-weight" => "600",
        "letter-spacing" => "0.08em", "text-transform" => "uppercase",
        "color" => "var(--bt-text-faint)"),
    # A resumable entry is dimmer (the agent process is alive but the server
    # hasn't brought up its ChatModel yet — clicking does the resume).
    CSS(".bt-side-resumable",
        "opacity" => "0.78"),
    CSS(".bt-side-resumable .bt-side-name",
        "color" => "var(--bt-text-muted)",
        "font-style" => "italic"),
    CSS(".bt-proj-icon",
        "border-radius" => "8px",
        "color" => "#fff", "font-weight" => "600",
        "text-align" => "center",
        "flex-shrink" => "0",
        "user-select" => "none",
        "font-family" => "'Inter', system-ui, sans-serif",
        # Flex-center the contents so the home <img> sits perfectly in the
        # middle. For initials we still use line-height (set inline by
        # `project_icon`) which falls into the same flex box gracefully.
        "display" => "flex", "align-items" => "center", "justify-content" => "center"),
    # Home icon: borderless 32px slot, glyph in muted text color so it sits
    # quietly above the colorful project tiles. The SVG ships with white
    # strokes, so we recolor it via a CSS filter.
    CSS(".bt-side-home-icon",
        "width" => "32px", "height" => "32px",
        "display" => "flex", "align-items" => "center", "justify-content" => "center",
        "flex-shrink" => "0"),
    # invert+sepia+rotate is the standard trick for tinting a white SVG via
    # CSS without per-color SVG variants. Lands close to --bt-text-muted (#64748b).
    CSS(".bt-side-home-icon img",
        "filter" => "invert(48%) sepia(13%) saturate(540%) hue-rotate(176deg) brightness(92%) contrast(86%)"),
    CSS(".bt-side-active .bt-side-home-icon img",
        "filter" => "invert(38%) sepia(86%) saturate(2400%) hue-rotate(212deg) brightness(99%) contrast(95%)"),
    CSS(".bt-side-name",
        "font-size" => "12px",
        "line-height" => "1.3",
        "color" => "var(--bt-text)",
        "min-width" => "0",
        "flex" => "1 1 auto",
        # Two-line clamp so a long auto-inferred title wraps cleanly without
        # blowing up the row height. Newer Chromium / WebKit honour
        # `-webkit-line-clamp`; fallback for the rare browser that doesn't is
        # nowrap-with-ellipsis (so the row stays single-line at worst).
        "display" => "-webkit-box",
        "-webkit-box-orient" => "vertical",
        "-webkit-line-clamp" => "2",
        "overflow" => "hidden",
        "overflow-wrap" => "anywhere",
        "text-overflow" => "ellipsis"),
    # Close (✕) on an active-chat row: reveal on row hover, red on its own hover.
    CSS(".bt-side-close",
        "margin-left" => "auto", "flex-shrink" => "0",
        "color" => "var(--bt-text-faint)",
        "font-size" => "12px", "line-height" => "1",
        "padding" => "2px 4px", "border-radius" => "var(--bt-radius-sm)",
        "opacity" => "0",
        "transition" => "opacity 80ms, background 80ms, color 80ms"),
    CSS(".bt-side-item:hover .bt-side-close", "opacity" => "1"),
    CSS(".bt-side-close:hover",
        "background" => "rgba(239,68,68,0.14)", "color" => "var(--bt-error)"),
    # Shown when no chats are open yet.
    CSS(".bt-side-empty",
        "padding" => "10px 12px", "font-size" => "12px",
        "color" => "var(--bt-text-muted)", "line-height" => "1.4"),

    # Mobile: collapse to icon-only sidebar.
    CSS("@media (max-width: 640px)",
        CSS(".bt-sidebar",  "width" => "56px"),
        CSS(".bt-side-name", "display" => "none"),
        CSS(".bt-side-item", "justify-content" => "center")),
)

# ── Unified App ────────────────────────────────────────────────────────────
# Single Bonito App that owns the whole site. The sidebar always shows on
# the left; the main area swaps between the dashboard and a project's chat
# based on `current_view::Observable{String}`. "" → dashboard; otherwise →
# the project id (looked up in state.chat_models).

const UnifiedShellStyles = Bonito.Styles(
    CSS("html, body",
        "height" => "100%", "margin" => "0", "padding" => "0",
        "overflow" => "hidden",
        # Light off-white surrounding the centered chat column on wide monitors —
        # subtle, just enough that the app reads as a contained surface
        # instead of dissolving into the page bg. Match the dashboard's bg
        # variable so theming stays in one place.
        "background" => "var(--bt-bg, #fafaf9)"),
    # Width tokens for the chat/dashboard column. `--bt-main-max` is the bounded,
    # centered width when the plotpane is CLOSED — chosen so home / a plotpane-less
    # chat look identical to the old centered 1600px shell (1600 − 200px sidebar =
    # 1400px). `--bt-main-min` is the floor the chat shrinks to once the plotpane
    # has eaten all the surrounding whitespace and reached the "left wall".
    CSS(":root",
        "--bt-main-max" => "1400px",
        "--bt-main-min" => "480px"),
    # Full-viewport shell — NO centered cap. The centering moved down to `.bt-main`
    # so the plotpane (a `.bt-stage` child, sibling of `.bt-main`) can extend past
    # the chat into the right-hand whitespace the old centered shell used to waste.
    CSS(".bt-shell",
        # 100dvh, not 100vh (mobile URL-bar safe).
        "height"    => "100dvh",
        "display"   => "flex", "flex-direction" => "row",
        "background"   => "var(--bt-bg)"),
    # Everything to the right of the sidebar: the chat/dashboard column plus the
    # plotpane. Fills the viewport minus the sidebar; `.bt-main` centers within
    # whatever horizontal space the plotpane leaves it.
    CSS(".bt-stage",
        "flex" => "1 1 auto", "min-width" => "0",
        "display" => "flex", "flex-direction" => "row",
        "overflow" => "hidden"),
    # The chat / dashboard column. `flex: 0 1 max` + `margin: 0 auto` ⇒ it caps at
    # `--bt-main-max` and sits centered in the free space when the plotpane is
    # closed (identical to the old look). As the plotpane grows, the free space
    # shrinks so the column slides left; once the free space is gone it shrinks
    # down to `--bt-main-min` — the two-stage "slide then shrink at the wall".
    # Side borders give the contained-surface frame the shell used to provide.
    CSS(".bt-main",
        "flex" => "0 1 var(--bt-main-max)",
        "min-width" => "var(--bt-main-min)",
        "margin" => "0 auto",
        "position" => "relative",
        "display" => "flex", "flex-direction" => "column",
        "overflow" => "hidden",
        "border-left"  => "1px solid var(--bt-border)",
        "border-right" => "1px solid var(--bt-border)"),
    # When the plotpane is OPEN, the chat stops centering and becomes a fixed,
    # resizable LEFT column — the plotpane (flex:1) then fills ALL the space to
    # its right with no gap. The divider sets `--bt-chat-width` (clamped to the
    # chat's sensible reading range). This is what makes "everything right of the
    # chat is the plotpane/editor/drop zone" true.
    CSS(".bt-stage:has(.bt-plotpane.bt-plotpane-visible) .bt-main",
        "flex"   => "0 0 clamp(var(--bt-main-min), var(--bt-chat-width, 820px), var(--bt-main-max))",
        "margin" => "0"),

    # ── Keep-alive view stack ────────────────────────────────────────────────
    # The dashboard and every opened chat are all mounted at once and stacked on
    # top of each other (absolute inset:0); the nav handler toggles `display` so
    # exactly one shows. Stacking (not a flow swap) is what lets us preserve each
    # chat's DOM/embeds while only one is on screen.
    CSS(".bt-main-views",
        "position" => "relative",
        "flex" => "1 1 auto", "min-height" => "0", "min-width" => "0"),
    CSS(".bt-view",
        "position" => "absolute", "inset" => "0",
        "display" => "flex", "flex-direction" => "column", "min-width" => "0"),
    # The chats container is just a positioning context; its panes are the
    # absolutely-positioned, individually-toggled children. It is stacked ON TOP
    # of the dashboard (later in DOM), so it MUST be click-transparent — otherwise
    # the empty container (all panes hidden on home) swallows every click meant
    # for the dashboard beneath it. Only a visible pane re-enables pointer events.
    CSS(".bt-view-chats", "display" => "block", "pointer-events" => "none"),
    CSS(".bt-chatpane",
        "position" => "absolute", "inset" => "0",
        "display" => "none", "flex-direction" => "column", "min-width" => "0",
        "pointer-events" => "auto"),
    # Overlay sits on top (loading / unknown card). Click-through when empty so
    # it never blocks the chat behind it; its card re-enables pointer events.
    CSS(".bt-view-overlay",
        "position" => "absolute", "inset" => "0",
        "pointer-events" => "none"),
    CSS(".bt-view-overlay .bt-loading-wrap, .bt-view-overlay .bt-empty",
        "pointer-events" => "auto"),
    # The loading card doubles as the chat's mount curtain (phases 2/3, see
    # chat_waiting_view): full height + opaque so the pane's initial geometry
    # churn (estimate→measured heights, image mounts, scrollbar pumping)
    # never shows around or below the card. The wrap stays a PLAIN block, so
    # `.bt-loading`'s flex centering is inert and the card hugs the top —
    # the same spot across all phases.
    CSS(".bt-view-overlay .bt-loading-wrap",
        "height" => "100%",
        "background" => "var(--bt-bg)",
        "transition" => "opacity 200ms ease"),
    # Hidden-until-onload: a card over an already-settled pane (kept-alive
    # revisit) is dismissed before it ever paints.
    CSS(".bt-loading-wrap.bt-loading-pending",
        "visibility" => "hidden"),
    # The settle fade — mirrors the old curtain reveal.
    CSS(".bt-loading-wrap.bt-loading-hide",
        "opacity" => "0", "pointer-events" => "none"),
)

# Per-session bring-up bookkeeping for the loading view. `inflight` holds the
# project ids that currently have a `ensure_project_session!` task running (so
# re-renders don't spawn duplicates); `errors` holds the last bring-up failure
# message per id (gates re-kicking AND drives the error card); `retry` is an
# Observable a "Try again" click notifies with the id to retry.
struct LoadingState
    inflight :: Set{String}
    errors   :: Dict{String,String}
    retry    :: Observable{String}
end
LoadingState() = LoadingState(Set{String}(), Dict{String,String}(), Observable(""))

# Loading screen for a project whose ChatModel isn't cached yet. Replaces the
# old bare "Starting chat for X…" text, which had two problems: it never
# changed once shown (so a chat that finished bringing up AFTER you navigated
# stayed stuck on the text until you clicked away and back), and it span
# forever for projects whose worker was offline (the model never builds).
#
# This view depends on `state.workers`, so it re-renders on every worker
# status change — giving us, for free, the offline message AND a re-attempt
# when the worker comes (back) online. When a bring-up task finishes it
# `notify`s `current_view` (value unchanged → pure re-render kick), so
# `unified_main`'s outer `map` re-evaluates and swaps to the now-cached chat.
#
# The state machine (per project id, see `LoadingState`):
#   offline worker        → "worker is offline" card (no task, no spinner)
#   last attempt errored  → error card + "Try again" (no auto-retry — that
#                            would be a tight failure loop)
#   a task is in flight   → spinner
#   otherwise             → spawn ONE bring-up task, show spinner
function project_loading_view(state::ServerState, pid::String,
                               current_view::Observable{String},
                               ls::LoadingState)
    # Wrap the reactive body in a DOM.div: unified_main's outer
    # `map(current_view) do pid ... end` expects each branch to return a
    # Node, not an Observable{Node}. Returning the bare `map(state.workers)`
    # threw `MethodError: Cannot convert Observable{Node} to Node` and the
    # loading view never appeared while the bring-up ran.
    body = map(state.workers) do workers
        p = get(state.projects[], pid, nothing)
        p === nothing && return DOM.div("Unknown project: $pid";
                                        class = "bt-empty",
                                        style = Styles("padding" => "40px"))
        w      = get(workers, p.worker_id, nothing)
        wname  = w === nothing ? p.worker_id : w.name
        online = w !== nothing && w.status == :online
        if !online
            return DOM.div(
                DOM.div("⚠"; class = "bt-loading-glyph"),
                DOM.div("Worker is offline"; class = "bt-loading-title"),
                DOM.div("$(p.name) lives on $(wname), which isn't connected " *
                        "right now. Start that worker to open this chat.";
                        class = "bt-loading-sub");
                class = "bt-loading")
        end
        if haskey(ls.errors, pid)
            return DOM.div(
                DOM.div("⚠"; class = "bt-loading-glyph"),
                DOM.div("Couldn't open $(p.name)"; class = "bt-loading-title"),
                DOM.div(ls.errors[pid]; class = "bt-loading-sub"),
                DOM.div("Try again";
                        class   = "bt-btn bt-btn-secondary",
                        style   = Styles("margin-top" => "6px"),
                        onclick = js"() => $(ls.retry).notify($(pid))");
                class = "bt-loading")
        end
        if !(pid in ls.inflight) && !haskey(state.chat_models, pid)
            push!(ls.inflight, pid)
            proj = p
            @async begin
                try
                    ensure_project_session!(state, proj)
                catch e
                    ls.errors[pid] = sprint(showerror, e)
                    @warn "loading: chat bring-up failed" project = proj.name exception = e
                finally
                    delete!(ls.inflight, pid)
                    safe_notify!(current_view)   # re-render: show chat, or the error card
                end
            end
        end
        DOM.div(
            DOM.div(class = "bt-loading-spinner"),
            DOM.div("Opening $(p.name)…"; class = "bt-loading-title"),
            DOM.div("Connecting to $(wname) and restoring the conversation…";
                    class = "bt-loading-sub");
            class = "bt-loading")
    end
    return DOM.div(body; class = "bt-loading-wrap")
end

# Phases 2+3 of the load screen: the card for a chat whose ChatModel IS
# cached but whose pane hasn't finished mounting and settling yet. Before
# this existed the overlay vanished the instant the model landed server-side
# — but the pane's DOM still had to ship, mount, and settle, so the user saw
# bring-up card → ~1s of bare background → a separate per-chat curtain.
# Now ONE card (identical classes/geometry to `project_loading_view`'s) stays
# up from click to settle and only its sub-text changes:
#
#   "Connecting to <worker>…"   project_loading_view, while session/load runs
#   "Loading the chat…"         this card, pane DOM shipping + mounting
#   "Rendering messages…"       chat module mounted, settle watch running
#
# The chat module drives the hand-offs: `_startSettle` (bonitoteam.js)
# dispatches `bt-chat-settling` / `bt-chat-settled` window events carrying
# the pane pid, and mirrors them as `data-bt-settling` / `data-bt-settled`
# flags on the `.bt-chatpane` so a card that mounts AFTER an event fired
# (kept-alive revisit, rapid navigation) can read the current state
# synchronously instead of waiting for the next event.
#
# A struct + jsrender (not a plain function) for the same reason as
# ChatPaneRef below: `Bonito.onload` must register against the SUBSESSION
# that renders this card (the overlay re-renders one per `current_view`
# change) — registered on the parent session, whose document loaded long
# ago, the mount hook would never fire.
struct ChatWaitingView
    state :: ServerState
    pid   :: String
end

function Bonito.jsrender(session::Bonito.Session, v::ChatWaitingView)
    p     = get(v.state.projects[], v.pid, nothing)
    title = p === nothing ? "Opening chat…" : "Opening $(p.name)…"
    wrap  = DOM.div(
        DOM.div(
            DOM.div(class = "bt-loading-spinner"),
            DOM.div(title; class = "bt-loading-title"),
            DOM.div("Loading the chat…"; class = "bt-loading-sub");
            class = "bt-loading");
        # Starts hidden (`bt-loading-pending`): navigating back to an
        # already-settled pane must not flash a loading card. The onload
        # below either keeps it hidden and bails, or reveals it.
        class = "bt-loading-wrap bt-loading-pending",
        dataWaitingFor = v.pid)
    Bonito.onload(session, wrap, js"""(wrap) => {
        const pid = wrap.dataset.waitingFor;
        const sub = wrap.querySelector('.bt-loading-sub');
        const pane = document.querySelector(
            '.bt-chatpane[data-pane-pid="' + pid + '"]');
        const phase3 = () => { if (sub) sub.textContent = 'Rendering messages…'; };
        let cap = null;
        const cleanup = () => {
            window.removeEventListener('bt-chat-settling', onSettling);
            window.removeEventListener('bt-chat-settled',  onSettled);
            if (cap) clearTimeout(cap);
        };
        const hide = () => {
            cleanup();
            wrap.classList.add('bt-loading-hide');
            setTimeout(() => { wrap.style.display = 'none'; }, 250);
        };
        const onSettling = (e) => { if (e.detail === pid) phase3(); };
        const onSettled  = (e) => { if (e.detail === pid) hide(); };
        if (pane && pane.dataset.btSettled) {       // kept-alive revisit
            wrap.style.display = 'none';
            return;
        }
        wrap.classList.remove('bt-loading-pending');
        if (pane && pane.dataset.btSettling) phase3();  // mounted mid-settle
        window.addEventListener('bt-chat-settling', onSettling);
        window.addEventListener('bt-chat-settled',  onSettled);
        // Failsafe: a pane that dies during render must not leave an opaque
        // overlay forever. The chat's own settle watch hard-caps at 5s, so
        // this only fires when something is genuinely broken.
        cap = setTimeout(hide, 15000);
    }""")
    return Bonito.jsrender(session, wrap)
end

# Max number of chat panes kept mounted (DOM-preserved) at once. Beyond this,
# the least-recently-viewed chat's pane is dropped — its live embeds tear down
# and re-delegate on the next visit. Generous enough that normal back-and-forth
# between a handful of chats never re-renders anything.
const KEEP_ALIVE_CAP = 6

# A stable, per-pid handle the chat-pane KeyedList renders. Memoized per session
# (see `unified_main`) so the SAME object is handed to KeyedList across renders,
# and the pane's DOM — with its live embeds, scroll position, and per-app
# collapse state — is preserved across navigation. That preservation IS the
# "resident per-chat state" requirement: switching chats just hides/shows panes.
struct ChatPaneRef
    state :: ServerState
    pid   :: String
end

# Render one kept-alive chat pane. The pane is absolutely positioned to fill the
# view area and toggled visible/hidden by the nav handler (see `unified_main`),
# never re-rendered.
function Bonito.jsrender(session::Bonito.Session, r::ChatPaneRef)
    model = get(r.state.chat_models, r.pid, nothing)
    # The flex sizing is load-bearing: the chat shell (.bt-app) is height:100%,
    # so the wrapper must be a flex column that fills, or the chat collapses.
    inner = model === nothing ? DOM.div() :
        DOM.div(model; style = Styles("flex" => "1 1 auto", "min-height" => "0",
                                      "display" => "flex", "flex-direction" => "column"))
    pane = DOM.div(inner; class = "bt-chatpane", dataPanePid = r.pid)
    # Self-initialize visibility on mount: a pane the KeyedList adds while its
    # chat is ALREADY the active view must reveal itself (the nav handler ran
    # before this pane existed). We read the active pid from the container's
    # data attribute rather than interpolating the parent-session `current_view`
    # Observable — interpolating a parent Observable into a KeyedList child's JS
    # triggers "Key not found"/null.notify, because the child renders in a
    # different session (see feedback_keyedlist_child_session_observable).
    Bonito.onload(session, pane, js"""(el) => {
        const root = el.closest('.bt-main-views');
        const active = root ? (root.dataset.activeView || '') : '';
        el.style.display = (el.dataset.panePid === active) ? 'flex' : 'none';
    }""")
    Bonito.jsrender(session, pane)
end

# Render the main panel given the current view + the bonito session. Pulled out
# so unified_app's body stays small.
#
# Keep-alive architecture (replaces the old `map(current_view)` node-swap, which
# tore the whole panel down on every navigation): the dashboard and every opened
# chat are mounted SIMULTANEOUSLY and only their visibility is toggled. This (a)
# preserves per-chat DOM/embeds/collapse state across navigation and (b) stops
# the `null.bonitoKeyedList` flood — the dashboard's KeyedLists are never torn
# down mid-update because the dashboard is never unmounted.
function unified_main(session::Bonito.Session, state::ServerState,
                      current_view::Observable{String}, ls::LoadingState)
    # ── Dashboard pane: rendered ONCE, mounted forever ──────────────────────
    dash_pane = DOM.div(
        dashboard_dom(session, state; current_view = current_view);
        class = "bt-view bt-view-dash")

    # ── Chat panes: one per opened chat, DOM-preserved via KeyedList ────────
    # `alive` is the LRU-ordered list of pids whose pane stays mounted. Memoized
    # ChatPaneRefs (same object per pid) give KeyedList a stable identity so it
    # preserves rather than rebuilds. A pid that's no longer cached (chat closed)
    # drops out of the list ⇒ KeyedList detaches its pane.
    alive = Observable(String[])
    panes = Dict{String,ChatPaneRef}()
    ref(pid) = get!(() -> ChatPaneRef(state, pid), panes, pid)
    chatpanes_obs = map(alive) do pids
        ChatPaneRef[ref(pid) for pid in pids if haskey(state.chat_models, pid)]
    end
    chats_host = DOM.div(KeyedList(chatpanes_obs; key = r -> r.pid);
                         class = "bt-view bt-view-chats")

    # ── Overlay: the single, continuous load screen ──────────────────────────
    # Model not cached yet → `project_loading_view` (kicks the bring-up and
    # re-notifies `current_view` on success → we re-enter). Model cached →
    # `chat_waiting_view`: cached ≠ pixels ready — the pane still has to
    # ship, mount, and settle, and the overlay must hold the SAME card up
    # until the chat module's settle events dismiss it. (It used to go
    # display:none here, exposing ~1s of bare background before the
    # now-removed per-chat curtain painted.)
    overlay = map(session, current_view) do pid
        if isempty(pid)
            DOM.div(; style = Styles("display" => "none"))
        elseif haskey(state.chat_models, pid)
            # The wrapper div keeps this branch a Node (like the others) so
            # Bonito renders it directly; height:100% hands the overlay's
            # full height down to the card's `.bt-loading-wrap`.
            DOM.div(ChatWaitingView(state, pid);
                    style = Styles("height" => "100%"))
        elseif haskey(state.projects[], pid)
            project_loading_view(state, pid, current_view, ls)
        else
            DOM.div("Unknown project: $pid"; class = "bt-empty",
                    style = Styles("padding" => "40px"))
        end
    end
    overlay_pane = DOM.div(overlay; class = "bt-view-overlay")

    # ── Navigation → promote to most-recently-used + evict beyond the cap ────
    on(session, current_view) do pid
        (isempty(pid) || !haskey(state.chat_models, pid)) && return
        cur = alive[]
        (!isempty(cur) && cur[end] == pid) && return     # already MRU, no churn
        keep = vcat(filter(!=(pid), cur), pid)
        length(keep) > KEEP_ALIVE_CAP && (keep = keep[(end - KEEP_ALIVE_CAP + 1):end])
        alive[] = keep
    end

    container = DOM.div(dash_pane, chats_host, overlay_pane; class = "bt-main-views")

    # Visibility: pure DOM toggling (no re-render, no teardown). Sets the active
    # pid on the container (so a freshly-added pane can self-init via its onload)
    # and shows the matching chat pane / the dashboard. Interpolating only
    # `current_view` here is safe — this runs in the PARENT session that owns the
    # container; it never crosses into a KeyedList child subsession.
    Bonito.onjs(session, current_view, js"""(pid) => {
        const root = document.querySelector('.bt-main-views');
        if (!root) return;
        root.dataset.activeView = pid || '';
        const dash = root.querySelector('.bt-view-dash');
        if (dash) dash.style.display = (!pid) ? 'flex' : 'none';
        // Per-pane visibility + an `onShown` ping on the one we just
        // revealed. The ping lets BonitoChat re-anchor to the bottom on
        // each open while followMode is on (user was at the bottom), and
        // preserves the user's scroll position otherwise. Without this,
        // a kept-alive pane keeps the scrollTop the browser had when we
        // hid it — fine when the user had scrolled up to read history,
        // but stale ("missing the latest message") when they had been
        // following the conversation. Brand-new chats use this same
        // path: followMode defaults true on construction, so first open
        // also lands at the bottom even if the initial mount's scroll
        // attempts raced against late image / virtual-scroll measuring.
        root.querySelectorAll('.bt-view-chats .bt-chatpane').forEach(p => {
            const visible = (p.dataset.panePid === pid);
            p.style.display = visible ? 'flex' : 'none';
            if (visible) {
                const msgs = p.querySelector('.bt-messages');
                const chat = msgs && msgs.__bt_chat;
                if (chat && typeof chat.onShown === 'function') chat.onShown();
            }
        });
    }""")
    return container
end

"""
    unified_app(state) → Bonito.App

Single-page app: sidebar on the left, dashboard or chat in the main area
depending on `current_view`. Replaces the old per-project `/p/<id>` routes.
"""
function unified_app(state::ServerState)
    App(; title = "BonitoTeam") do session
        # Per-session view of the shared state. `copy(state, session)` shares
        # the workers/projects/chat_models tables and the lock, but gives this
        # session its OWN connected child of each version Observable (via
        # `map(identity, session, ...)` — auto-deregisters on tab close).
        # `current_view` is per-session (transient navigation state).
        view = copy(state, session)
        current_view = Observable("")
        # Per-session bring-up bookkeeping for the loading view (see
        # LoadingState / project_loading_view). The retry handler clears the
        # recorded error and re-renders, which re-spawns the bring-up task.
        ls = LoadingState()
        on(session, ls.retry) do retry_pid
            isempty(retry_pid) && return
            delete!(ls.errors, retry_pid)
            safe_notify!(current_view)
        end
        sidebar = project_sidebar(session, view, current_view)
        main_panel = unified_main(session, view, current_view, ls)
        # Chat-global floating "show-app target" + right-side plotpane column.
        # `Detach` on any bt_show_app bubble moves the embed DOM into the
        # popup (or plotpane, if that was the last location); close → restore
        # to bubble. Drag the popup title bar over the plotpane → docks.
        # Geometry + location persist per chat to disk.
        popup, plotpane, popup_controller_js = install_popup!(session, view, current_view)
        # `.bt-stage` holds the centered chat column AND the plotpane side by side,
        # filling the whole viewport-minus-sidebar. The plotpane being a sibling of
        # `.bt-main` (not nested inside it) is what lets it grow into the right
        # whitespace while `.bt-main` stays capped + centered.
        stage = DOM.div(
            DOM.div(main_panel; class = "bt-main"),
            plotpane;
            class = "bt-stage")
        shell = DOM.div(
            # MarkdownCSS FIRST: it's the base sheet our styles override.
            # Stylesheet order breaks specificity ties — with MarkdownCSS
            # last, its `.markdown-body pre` light-gray background beat the
            # chat's dark code blocks (see ChatStyles' agent-pre comment).
            Bonito.MarkdownCSS,
            UnifiedShellStyles,
            DashboardStyles,
            ChatStyles,
            SidebarStyles,
            PopupStyles,
            Bonito.ConnectionIndicator(),
            sidebar,
            stage,
            popup;
            class = "bt-shell")
        # Install `window._btPopup` once the shell is in the DOM. The DOM nodes
        # the controller queries (#bt-popup-mount inside the popup body, and
        # per-tool #bt-slot-<id> / #bt-embed-<id> in the chat) are all
        # descendants of the shell, so they're guaranteed present by onload.
        Bonito.onload(session, shell, popup_controller_js)
        shell
    end
end
