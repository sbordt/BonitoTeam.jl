#!/usr/bin/env julia
# Standalone server entry point.
#
#   julia --project=<path>/BonitoTeam server_standalone.jl
#
# Env (all optional except SECRET + PUBLIC_URL):
#   BONITOTEAM_WORKER_SECRET   shared secret workers authenticate with (required)
#   BONITOTEAM_PUBLIC_URL      public base URL, e.g. https://your.domain.com (required)
#   BONITOTEAM_PORT            internal bind port (default: 8038)
#   BONITOTEAM_HOST            bind address (default: 127.0.0.1)
#   BONITOTEAM_STATE_DIR       where workers.json / projects.json are stored
#   BONITOTEAM_WORKING_DIR     where canonical project copies live on the server

using BonitoTeam

const secret     = get(ENV, "BONITOTEAM_WORKER_SECRET", "")
const public_url = get(ENV, "BONITOTEAM_PUBLIC_URL", "")

isempty(secret)     && error("BONITOTEAM_WORKER_SECRET must be set")
isempty(public_url) && error("BONITOTEAM_PUBLIC_URL must be set")

BonitoTeam.serve(;
    worker_secret = secret,
    public_url    = public_url,
    port          = parse(Int, get(ENV, "BONITOTEAM_PORT", "8038")),
    host          = get(ENV, "BONITOTEAM_HOST", "127.0.0.1"),
    state_dir     = get(ENV, "BONITOTEAM_STATE_DIR",   nothing),
    working_dir   = get(ENV, "BONITOTEAM_WORKING_DIR", nothing),
)

wait()
