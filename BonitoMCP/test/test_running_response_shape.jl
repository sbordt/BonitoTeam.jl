# A `running` checkpoint must return the SAME block shape as a `completed`
# response — fenced ```julia code echo first, then a `stdout:`-prefixed
# console block — so the BonitoTeam chat renders both via `render_eval_body`
# (Code + Output collapsibles, RichText for ANSI/stdout). The earlier shape
# was a single `status: running…\n\n…` text block that fell through to
# `Markdown.parse`, italicizing tool names like `bt_julia_continue` and
# stripping the structured eval rendering — that's the regression this test
# locks against.

using Test
using BonitoMCP
const M = BonitoMCP

@testset "running_response is eval-shaped (code echo + stdout block)" begin
    code = "using Bonito\nprintln(1+1)"
    r = M.running_response("/tmp/x", "hello\n", 3.14, code)

    @test r["isError"] === false
    @test r["_meta"]["status"] == "running"
    @test length(r["content"]) == 2

    code_block, stdout_block = r["content"][1]["text"], r["content"][2]["text"]
    @test occursin("```julia\n$code\n```", code_block)
    @test startswith(stdout_block, "stdout:\n")
    @test occursin("hello", stdout_block)
    @test occursin("still running", stdout_block)
end

@testset "running variant carries `code` so callers can echo it" begin
    s = M.JuliaSession(nothing; is_temp = true)
    try
        r = M.execute(s, """
        println("partial")
        flush(stdout)
        sleep(5)
        99
        """; timeout = 1.0)
        @test r.status == :running
        @test :code in propertynames(r)
        @test occursin("partial", r.code)
    finally
        try M.interrupt!(s) catch end
        M.kill_session!(s)
    end
end
