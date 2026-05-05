#!/usr/bin/env julia
# Standalone worker entry point. Wraps BonitoWorker.serve and self-registers
# with the BonitoTeam server.
#
# Run with the BonitoWorker env active:
#   julia --project=<path>/BonitoWorker worker_standalone.jl
# All config is via env vars — see bin/bonitoteam-worker for the wrapper.

using HTTP, JSON, Sockets, BonitoWorker

# Discover the local IP the server can actually reach back on. We open a TCP
# socket to the server's host:port, then read getsockname() — that's the
# local address the OS routed the connection through, i.e. the IP the server
# saw as the connection's peer. Works on LAN; on NAT the worker still sees
# its private IP, in which case the operator must set BONITOTEAM_REGISTER_HOST
# explicitly (e.g. to a port-forwarded public IP).
function discover_reachable_host(server_url::AbstractString)
    uri = HTTP.URI(server_url)
    host = String(uri.host)
    port = isempty(uri.port) ? (uri.scheme == "https" ? 443 : 80) : parse(Int, uri.port)
    sock = Sockets.connect(host, port)
    try
        addr, _ = Sockets.getsockname(sock)
        return string(addr)
    finally
        close(sock)
    end
end

# Self-register with the server. Best-effort: if the server is down, log + carry
# on listening — the operator can register later via the dashboard.
function self_register!(server_url::String, secret::String, port::Int)
    register_host = get(ENV, "BONITOTEAM_REGISTER_HOST") do
        try
            discover_reachable_host(server_url)
        catch e
            @warn "Worker: reachable-host discovery failed; falling back to gethostname()" exception=e
            gethostname()
        end
    end
    register_name = get(ENV, "BONITOTEAM_WORKER_NAME", register_host)
    body = JSON.json(Dict(
        "secret" => secret,
        "host"   => register_host,
        "port"   => port,
        "name"   => register_name,
    ))
    @info "BonitoWorker: registering with server" server_url register_host port register_name
    try
        r = HTTP.request("POST", "$server_url/api/workers/register",
                         ["Content-Type" => "application/json"], body;
                         readtimeout = 10, retry = false, status_exception = false)
        if r.status == 200
            @info "BonitoWorker: registered" response=String(r.body)
        else
            @error "BonitoWorker: REGISTRATION FAILED" status=r.status body=String(r.body) hint="server probe back to ws://$(register_host):$(port) likely blocked by firewall — open port $(port) on this host"
        end
    catch e
        @error "BonitoWorker: REGISTRATION POST FAILED" exception=e hint="server at $(server_url) unreachable from this worker"
    end
end

const secret     = get(ENV, "BONITOTEAM_WORKER_SECRET", "")
const port       = parse(Int, get(ENV, "BONITOTEAM_WORKER_PORT", "8039"))
const host       = get(ENV, "BONITOTEAM_WORKER_HOST", "0.0.0.0")
const server_url = get(ENV, "BONITOTEAM_SERVER_URL", "")

isempty(secret) && error("BONITOTEAM_WORKER_SECRET must be set")

# Register in the background; serve() blocks immediately so we can't await it
# before the listener is up.
isempty(server_url) ?
    @warn("BONITOTEAM_SERVER_URL not set; skipping self-registration. " *
          "Add the worker manually via the dashboard.") :
    @async (sleep(1); self_register!(server_url, secret, port))

BonitoWorker.serve(; host, port, secret)
