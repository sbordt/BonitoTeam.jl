# After a server restart `state.chat_models` is empty, but
# `state.discovered` is loaded from disk and any Claude Code session whose
# process is still alive on a worker has `running == true`. The sidebar should
# pick those up automatically as "resumable" entries so the user can click them
# to bring the chat back up, rather than seeing an empty active-chats list.
using Test, BonitoTeam, Dates
using BonitoTeam: ProjectInfo, sidebar_resumable_projects, now, UTC

@testset "sidebar_resumable_projects" begin
    mk(id, w, wpath) = ProjectInfo(id, id, w, "/srv/$id", wpath, now(UTC))
    projects = Dict(
        "p1" => mk("p1", "wA", "/w/projA"),
        "p2" => mk("p2", "wA", "/w/projB"),
        "p3" => mk("p3", "wB", "/w/projA"),     # same path, different worker
    )
    discovered = Dict(
        "wA" => Any[
            Dict("path" => "/w/projA", "running" => true,  "kind" => "session"),
            Dict("path" => "/w/projB", "running" => false, "kind" => "session"),
        ],
        "wB" => Any[Dict("path" => "/w/projA", "running" => true, "kind" => "session")],
    )

    # Running sessions on (wA,/w/projA) and (wB,/w/projA) → both resumable.
    r = sidebar_resumable_projects(projects, discovered, Set{String}())
    @test Set(p.id for p in r) == Set(["p1", "p3"])

    # When a project is already open, it's not also listed as resumable.
    r2 = sidebar_resumable_projects(projects, discovered, Set(["p1"]))
    @test Set(p.id for p in r2) == Set(["p3"])

    # Discover error rows are skipped (a worker that failed to scan).
    discovered["wA"] = Any[Dict("error" => "scan failed")]
    r3 = sidebar_resumable_projects(projects, discovered, Set{String}())
    @test Set(p.id for p in r3) == Set(["p3"])

    # No scan cached for a worker → no entries from that worker.
    r4 = sidebar_resumable_projects(projects, Dict(), Set{String}())
    @test isempty(r4)
end
