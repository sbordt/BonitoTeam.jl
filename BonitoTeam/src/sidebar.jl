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

# Sidebar entry: icon + label, "active" state highlighted with a left-edge
# accent bar via the bt-side-active class. Click notifies `current_view`,
# which the App's main panel observes.
function sidebar_entry(label::AbstractString, icon::Bonito.Node,
                        target_value::AbstractString,
                        current_view::Observable{String}, title::AbstractString)
    active = current_view[] == target_value
    DOM.div(icon, DOM.span(label; class = "bt-side-name"),
        class = "bt-side-item" * (active ? " bt-side-active" : ""),
        title = title,
        onclick = js"event => $(current_view).notify($(target_value))")
end

const HOME_ICON = Bonito.Asset(joinpath(@__DIR__, "..", "assets", "icons", "home.svg"))

"""
    project_sidebar(state, current_view) → DOM

Always-visible vertical nav. Top entry is "Home" (dashboard view); below
it, one entry per registered project. Re-renders on `state.version` so
new/deleted projects show up live, and on `current_view` so the active
highlight tracks the user's selection.
"""
function project_sidebar(state::ServerState, current_view::Observable{String})
    # House icon centered in a 32px tile colored with the muted text color.
    # The img inside fixes its own size so a fallback alt-text doesn't
    # blow out the icon's footprint.
    home_icon = DOM.div(
        DOM.img(src = HOME_ICON, alt = "Home", draggable = "false",
                style = "width:20px;height:20px;display:block;pointer-events:none");
        class = "bt-proj-icon bt-side-home-icon",
        title = "Dashboard")

    # `state.version` triggers a re-render whenever workers/projects mutate;
    # `current_view` triggers it whenever the user navigates so the
    # highlighted entry stays in sync.
    body = map(state.version, current_view) do _, _
        entries = [sidebar_entry("Home", home_icon, "", current_view, "Dashboard")]
        for p in values(state.projects)
            push!(entries,
                  sidebar_entry(p.name, project_icon(p), p.id, current_view, p.name))
        end
        DOM.div(entries...; class = "bt-side-list")
    end

    DOM.aside(body; class = "bt-sidebar")
end

# CSS for the sidebar + icons. Mobile (≤640px) collapses to icons-only at
# 56px wide; desktop expands to 200px with the project name to the right
# of each icon.
const SidebarStyles = Bonito.Styles(
    CSS(".bt-sidebar",
        "position" => "fixed", "top" => "0", "left" => "0", "bottom" => "0",
        "width" => "200px",
        "background" => "var(--bt-surface)",
        "border-right" => "1px solid var(--bt-border)",
        "overflow-y" => "auto", "overflow-x" => "hidden",
        "z-index" => "10",
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
    CSS(".bt-side-home-icon",
        "background" => "var(--bt-text-muted)"),
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
        "overflow" => "hidden"),
    CSS(".bt-shell",
        "position" => "fixed", "inset" => "0",
        "display" => "flex", "flex-direction" => "row"),
    CSS(".bt-main",
        "flex" => "1 1 auto",
        "min-width" => "0",
        "position" => "relative",
        "display" => "flex", "flex-direction" => "column",
        "overflow" => "hidden",
        "margin-left" => "200px"),
    CSS("@media (max-width: 640px)",
        CSS(".bt-main", "margin-left" => "56px")),
    # Keep the chat shell respecting the sidebar instead of laying itself
    # out as a position:fixed full-viewport block (which would cover the
    # sidebar). Inside the unified app the chat occupies the .bt-main column.
    CSS(".bt-shell .bt-app",
        "position" => "static",
        "flex" => "1 1 auto"),
)

# Render the main panel given the current view + the bonito session. Pulled
# out so unified_app's body stays small.
function unified_main(state::ServerState, current_view::Observable{String},
                       session)
    map(current_view) do pid
        if isempty(pid)
            dashboard_dom(state; current_view = current_view)
        elseif haskey(state.chat_models, pid)
            chat_dom(state.chat_models[pid], session)
        elseif haskey(state.projects, pid)
            DOM.div("Starting chat for $(state.projects[pid].name)…";
                    class = "bt-empty",
                    style = "padding:40px")
        else
            DOM.div("Unknown project: $pid"; class = "bt-empty",
                    style = "padding:40px")
        end
    end
end

"""
    unified_app(state) → Bonito.App

Single-page app: sidebar on the left, dashboard or chat in the main area
depending on `current_view`. Replaces the old per-project `/p/<id>` routes.
"""
function unified_app(state::ServerState)
    current_view = Observable("")
    App() do session
        sidebar = project_sidebar(state, current_view)
        main_panel = unified_main(state, current_view, session)
        DOM.div(
            UnifiedShellStyles,
            DashboardStyles,
            ChatStyles,
            SidebarStyles,
            BonitoTeamJS,
            Bonito.MarkdownCSS,
            Bonito.ConnectionIndicator(),
            sidebar,
            DOM.div(main_panel; class = "bt-main");
            class = "bt-shell")
    end
end
