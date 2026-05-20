# BonitoTeam/test/smoke_mcp.jl
#
# Smoke test for the BonitoTeam.MCP server. Two layers:
#   1. In-process: dispatch! against a IOBuffer, verify response shapes
#   2. Subprocess: spawn `julia -e 'using BonitoMCP; BonitoMCP.run_stdio()'`,
#      drive it over stdio with JSON-RPC, verify a real round-trip works
#
# Run via:
#   julia_eval(include("BonitoTeam/test/smoke_mcp.jl"))

using JSON
using BonitoTeam
using BonitoTeam.MCP: dispatch!, TOOLS, register!, run_stdio

function _run(req::Dict)
    io = IOBuffer()
    dispatch!(io, req)
    line = String(take!(io))
    return isempty(line) ? nothing : JSON.parse(strip(line))
end

# Test 1: initialize
function test_initialize()
    resp = _run(Dict("jsonrpc"=>"2.0", "id"=>1, "method"=>"initialize",
                     "params"=>Dict("protocolVersion"=>"2025-06-18",
                                    "capabilities"=>Dict(),
                                    "clientInfo"=>Dict("name"=>"smoke","version"=>"0"))))
    return (
        ok = resp !== nothing && haskey(resp, "result"),
        protocol = get(get(resp, "result", Dict()), "protocolVersion", nothing),
        server_name = get(get(get(resp, "result", Dict()), "serverInfo", Dict()), "name", nothing),
    )
end

# Test 2: tools/list
function test_tools_list()
    resp = _run(Dict("jsonrpc"=>"2.0", "id"=>2, "method"=>"tools/list"))
    tools = get(get(resp, "result", Dict()), "tools", [])
    return (
        ok = !isempty(tools),
        n_tools = length(tools),
        tool_names = [get(t, "name", "") for t in tools],
    )
end

# Test 3: tools/call → julia_eval
function test_eval_simple()
    resp = _run(Dict("jsonrpc"=>"2.0", "id"=>3, "method"=>"tools/call",
                     "params"=>Dict("name"=>"julia_eval",
                                    "arguments"=>Dict("code"=>"1+1"))))
    result = get(resp, "result", Dict())
    content = get(result, "content", [])
    return (
        ok = !get(result, "isError", true) && !isempty(content),
        is_error = get(result, "isError", nothing),
        first_text = isempty(content) ? nothing : get(first(content), "text", nothing),
    )
end

# Test 4: state persists between calls
function test_eval_state()
    _run(Dict("jsonrpc"=>"2.0", "id"=>4, "method"=>"tools/call",
              "params"=>Dict("name"=>"julia_eval",
                             "arguments"=>Dict("code"=>"x_smoketest = 42"))))
    resp = _run(Dict("jsonrpc"=>"2.0", "id"=>5, "method"=>"tools/call",
                     "params"=>Dict("name"=>"julia_eval",
                                    "arguments"=>Dict("code"=>"x_smoketest * 2"))))
    content = get(get(resp, "result", Dict()), "content", [])
    text = isempty(content) ? "" : get(first(content), "text", "")
    return (
        ok = occursin("84", text),
        text = text,
    )
end

# Test 5: error handling — runtime error should set isError=true
function test_eval_error()
    resp = _run(Dict("jsonrpc"=>"2.0", "id"=>6, "method"=>"tools/call",
                     "params"=>Dict("name"=>"julia_eval",
                                    "arguments"=>Dict("code"=>"error(\"boom\")"))))
    result = get(resp, "result", Dict())
    return (
        is_error = get(result, "isError", nothing),
        first_text = get(first(get(result, "content", [Dict()])), "text", nothing),
    )
end

# Test 6: output truncation kicks in
function test_truncation()
    code = "repeat(\"x\", 50000); println(\"ok\"); 1"
    # First send a print of huge text via stdout
    big_print = "println(\"start\"); println(repeat(\"a\", 30000)); 1"
    resp = _run(Dict("jsonrpc"=>"2.0", "id"=>7, "method"=>"tools/call",
                     "params"=>Dict("name"=>"julia_eval",
                                    "arguments"=>Dict("code"=>big_print))))
    blocks = get(get(resp, "result", Dict()), "content", [])
    truncated = any(b -> occursin("[truncated", get(b, "text", "")), blocks)
    return (
        n_blocks = length(blocks),
        truncated = truncated,
        sample = isempty(blocks) ? "" : last(get(first(blocks), "text", ""), 200),
    )
end

# Test 7: full_output=true bypasses truncation
function test_full_output()
    big_print = "println(repeat(\"a\", 30000)); 1"
    resp = _run(Dict("jsonrpc"=>"2.0", "id"=>8, "method"=>"tools/call",
                     "params"=>Dict("name"=>"julia_eval",
                                    "arguments"=>Dict("code"=>big_print,
                                                       "full_output"=>true))))
    blocks = get(get(resp, "result", Dict()), "content", [])
    has_truncated_marker = any(b -> occursin("[truncated", get(b, "text", "")), blocks)
    total = sum(length(get(b, "text", "")) for b in blocks; init = 0)
    return (
        n_blocks = length(blocks),
        truncated = has_truncated_marker,
        total_bytes = total,
    )
end

# Test 8: large container summarized
function test_large_container_summary()
    code = "collect(1:500)"
    resp = _run(Dict("jsonrpc"=>"2.0", "id"=>9, "method"=>"tools/call",
                     "params"=>Dict("name"=>"julia_eval",
                                    "arguments"=>Dict("code"=>code))))
    blocks = get(get(resp, "result", Dict()), "content", [])
    text = isempty(blocks) ? "" : get(first(blocks), "text", "")
    return (
        summarized = occursin("with 500 elements", text),
        sample = first(text, 200),
    )
end

# Test 9: subprocess end-to-end
function test_subprocess()
    # Launch BonitoMCP the same way the worker does: a plain `julia` process
    # with an argv array (no shell wrapper — cross-platform).
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    project = something(Base.active_project(), Base.load_path_expand("@bonito-team"))
    proc = open(`$julia --project=$project --startup-file=no -e $("using BonitoMCP; BonitoMCP.run_stdio()")`, "r+")
    try
        # initialize
        write(proc.in, JSON.json(Dict("jsonrpc"=>"2.0", "id"=>1, "method"=>"initialize",
            "params"=>Dict())) * "\n")
        flush(proc.in)
        l1 = readline(proc.out)

        # tools/list
        write(proc.in, JSON.json(Dict("jsonrpc"=>"2.0", "id"=>2, "method"=>"tools/list")) * "\n")
        flush(proc.in)
        l2 = readline(proc.out)

        # tools/call julia_eval
        write(proc.in, JSON.json(Dict("jsonrpc"=>"2.0", "id"=>3, "method"=>"tools/call",
            "params"=>Dict("name"=>"julia_eval",
                            "arguments"=>Dict("code"=>"3+4")))) * "\n")
        flush(proc.in)
        l3 = readline(proc.out)

        return (
            ok = !isempty(l1) && !isempty(l2) && !isempty(l3),
            init_response = JSON.parse(l1),
            tools_count = length(get(get(JSON.parse(l2), "result", Dict()), "tools", [])),
            eval_response = JSON.parse(l3),
        )
    finally
        close(proc.in)
        close(proc)
    end
end

function run_all()
    out = Dict{Symbol,Any}()
    out[:initialize] = (try test_initialize() catch e; (error=string(e),) end)
    out[:tools_list] = (try test_tools_list() catch e; (error=string(e),) end)
    out[:eval_simple] = (try test_eval_simple() catch e; (error=string(e),) end)
    out[:eval_state] = (try test_eval_state() catch e; (error=string(e),) end)
    out[:eval_error] = (try test_eval_error() catch e; (error=string(e),) end)
    out[:truncation] = (try test_truncation() catch e; (error=string(e),) end)
    out[:full_output] = (try test_full_output() catch e; (error=string(e),) end)
    out[:large_container] = (try test_large_container_summary() catch e; (error=string(e),) end)
    out[:subprocess] = (try test_subprocess() catch e; (error=string(e),) end)
    return out
end

const RESULT = run_all()
RESULT
