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

# Renders one icon. `size_px` lets the sidebar reuse this at 32 px and the
# project_card (if we want to surface it there too) at e.g. 24 px.
function project_icon(p::ProjectInfo; size_px::Int = 32)
    DOM.div(project_initials(p.name);
        class = "bt-proj-icon",
        style = string("background:", project_color(p.id), ";",
                       "width:$(size_px)px;height:$(size_px)px;",
                       "line-height:$(size_px)px;font-size:$(round(Int, size_px*0.42))px"),
        title = p.name)
end

# A single sidebar row: icon + label + identifying data-attribute. NO
# Observables interpolated in here — the click handler and the
# active-highlight class swap are delegated from the outer `<aside>`,
# so this DOM can be recycled by the structural `map(state.projects)`
# below without churning any tracked Observable IDs.
function sidebar_entry(label::AbstractString, icon::Bonito.Node,
                        target_value::AbstractString, title::AbstractString;
                        active::Bool = false)
    DOM.div(icon, DOM.span(label; class = "bt-side-name"),
        class = "bt-side-item" * (active ? " bt-side-active" : ""),
        title = title,
        # `data-project-id` is the empty string for "Home" (the dashboard
        # entry) and the project id for everything else. The delegated
        # click handler reads this to know which view to switch to.
        dataProjectId = target_value)
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

    # Structural re-renders only. We read `current_view[]` synchronously
    # so the *initial* `bt-side-active` class is correct on each
    # re-render, but subsequent navigation flips the class via the
    # `onjs` handler below — no body re-render.
    body = map(state.projects) do projects
        active_pid = current_view[]
        entries = [sidebar_entry("Home", home_icon, "", "Dashboard";
                                  active = active_pid == "")]
        for p in values(projects)
            push!(entries,
                  sidebar_entry(p.name, project_icon(p), p.id, p.name;
                                active = active_pid == p.id))
        end
        DOM.div(entries...; class = "bt-side-list")
    end

    aside = DOM.aside(body; class = "bt-sidebar")

    # Delegated click handler: one listener on the aside, walks up to
    # the nearest .bt-side-item, notifies current_view with its
    # data-project-id. `current_view` enters the JS object cache here
    # exactly once and never gets re-tracked by a recycling subsession.
    Bonito.onload(session, aside, js"""(el) => {
        el.addEventListener('click', e => {
            const item = e.target.closest('.bt-side-item');
            if (item) $(current_view).notify(item.dataset.projectId || '');
        });
    }""")

    # Active-highlight swap: when current_view changes, find every
    # sidebar item, toggle .bt-side-active based on data-project-id
    # match. No DOM replacement, no subsession recycling.
    Bonito.onjs(session, current_view, js"""(pid) => {
        document.querySelectorAll('.bt-sidebar .bt-side-item').forEach(el => {
            el.classList.toggle('bt-side-active', el.dataset.projectId === pid);
        });
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
        "display" => "flex", "align-items" => "center", "gap" => "10px",
        "padding" => "6px 10px",
        "cursor" => "pointer",
        "border-left" => "3px solid transparent",
        "transition" => "background 80ms"),
    CSS(".bt-side-item:hover",
        "background" => "var(--bt-surface-2)"),
    CSS(".bt-side-active",
        "border-left-color" => "var(--bt-accent)",
        "background" => "var(--bt-surface-2)"),
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
        "font-size" => "13px",
        "color" => "var(--bt-text)",
        "white-space" => "nowrap", "overflow" => "hidden",
        "text-overflow" => "ellipsis"),

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
        # Light off-white surrounding the centered shell on wide monitors —
        # subtle, just enough that the app reads as a contained surface
        # instead of dissolving into the page bg. Match the dashboard's bg
        # variable so theming stays in one place.
        "background" => "var(--bt-bg, #fafaf9)"),
    # Centered application shell. On screens wider than `--bt-shell-max`
    # (1280px default) the app is bounded and centered; on narrower screens
    # `max-width` is a no-op and the shell fills the viewport. The 1px
    # vertical borders give the contained app a subtle frame on wide
    # monitors and disappear visually when the shell hits the viewport
    # edges.
    CSS(":root", "--bt-shell-max" => "1280px"),
    CSS(".bt-shell",
        "max-width" => "var(--bt-shell-max)",
        "margin"    => "0 auto",
        # 100dvh, not 100vh: on mobile 100vh is the LARGEST viewport (URL
        # bar collapsed), so when the bar is showing our last flex child
        # (chat input / dashboard bottom) falls below the visible area.
        # 100dvh shrinks with the bar.
        "height"    => "100dvh",
        "display"   => "flex", "flex-direction" => "row",
        "border-left"  => "1px solid var(--bt-border)",
        "border-right" => "1px solid var(--bt-border)",
        "background"   => "var(--bt-bg)"),
    CSS(".bt-main",
        "flex" => "1 1 auto",
        "min-width" => "0",
        "position" => "relative",
        "display" => "flex", "flex-direction" => "column",
        "overflow" => "hidden"),
)

# Render the main panel given the current view + the bonito session. Pulled
# out so unified_app's body stays small.
function unified_main(state::ServerState, current_view::Observable{String})
    map(current_view) do pid
        if isempty(pid)
            dashboard_dom(state; current_view = current_view)
        elseif haskey(state.chat_models, pid)
            # Wrap the ChatModel in a Node — Bonito's reactive Observable
            # renderer (jsrender(::Session, ::Observable)) calls
            # render_subsession on the Observable's *value*, which only
            # accepts a Hyperscript.Node (or App). DOM.div(model) gives it
            # a Node and lets Bonito recurse into the child to call
            # jsrender(::Session, ::ChatModel). The flex sizing here is
            # load-bearing: the chat shell (.bt-app) uses `height: 100%`,
            # so without `flex: 1; min-height: 0; display:flex` on the
            # wrapper the chat collapses to zero height inside the
            # `.bt-main` flex column.
            DOM.div(state.chat_models[pid];
                style = Styles("flex"          => "1 1 auto",
                               "min-height"    => "0",
                               "display"       => "flex",
                               "flex-direction"=> "column"))
        elseif haskey(state.projects[], pid)
            DOM.div("Starting chat for $(state.projects[][pid].name)…";
                    class = "bt-empty",
                    style = Styles("padding" => "40px"))
        else
            DOM.div("Unknown project: $pid"; class = "bt-empty",
                    style = Styles("padding" => "40px"))
        end
    end
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
        sidebar = project_sidebar(session, view, current_view)
        main_panel = unified_main(view, current_view)
        DOM.div(
            UnifiedShellStyles,
            DashboardStyles,
            ChatStyles,
            SidebarStyles,
            Bonito.MarkdownCSS,
            Bonito.ConnectionIndicator(),
            sidebar,
            DOM.div(main_panel; class = "bt-main");
            class = "bt-shell")
    end
end
