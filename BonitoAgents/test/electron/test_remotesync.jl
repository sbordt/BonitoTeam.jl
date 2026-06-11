# Tier 4a — RemoteSync over real HTTP.WebSockets.
#
# This is the integration test that proves today's "drop the package
# extension, depend on HTTP directly" change actually works end to end.
# We stand up a real HTTP server + client WebSocket pair and stream a file
# through `RemoteSync.send_file` / `receive_file`, then compare bytes.
#
# No Electron / DOM here — pure Julia round-trip — but lives in the same
# test/electron/ tree because it covers the same end-to-end story.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using HTTP, RemoteSync, SHA

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

# Pick an ephemeral port and bring up an HTTP server with a single
# /transfer-ws WebSocket route. The server side reads the file off the wire
# and writes it to `dst`. Done channel signals when the read completes so
# the test can shut down cleanly.
# Randomized to avoid colliding with leftover sockets from prior runs in
# the same Julia session.
const PORT = 19000 + rand(1:999)

dst = tempname() * ".bin"
done = Channel{Any}(1)

server = HTTP.WebSockets.listen!("127.0.0.1", PORT) do ws
    try
        io = RemoteSync.WebSocketIO(ws)
        size_received, mtime = RemoteSync.receive_file(dst, io)
        put!(done, (:ok, size_received))
    catch e
        put!(done, (:err, e))
    end
end

# Client: build a payload with structure you can verify (so failure
# diagnostics tell us what actually went wrong), connect, send.
src = tempname() * ".bin"
payload = vcat(rand(UInt8, 1024 * 64),
               codeunits("RemoteSync end-to-end test marker"),
               rand(UInt8, 1024 * 64))
write(src, payload)
src_sha = bytes2hex(sha256(payload))

try
    HTTP.WebSockets.open("ws://127.0.0.1:$PORT/transfer-ws") do ws
        io = RemoteSync.WebSocketIO(ws)
        sent = RemoteSync.send_file(src, io)
        record("client send_file returned correct byte count",
               @TH.test_eq Int(sent) length(payload))
    end

    TH.section("Server received the file") do
        # Wait for the server-side receive_file to finish.
        result = try take!(done) catch _; (:err, "no result") end
        record("server completed without error",
               @TH.test_eq result[1] :ok)
        if result[1] === :ok
            record("byte count matches",
                   @TH.test_eq Int(result[2]) length(payload))
        end
    end

    TH.section("Bytes round-trip exactly") do
        record("dst exists", @TH.test_true isfile(dst))
        if isfile(dst)
            dst_bytes = read(dst)
            record("size matches", @TH.test_eq length(dst_bytes) length(payload))
            record("sha256 matches",
                   @TH.test_eq bytes2hex(sha256(dst_bytes)) src_sha)
            record("text marker present in dst",
                   @TH.test_true occursin("RemoteSync end-to-end test marker", String(read(dst))))
        end
    end

finally
    TH.report!("Tier 4a — RemoteSync over HTTP.WebSockets", results)
    try close(server) catch end
    try rm(src) catch end
    try rm(dst) catch end
end
