#!/bin/bash

SCRIPT_DIR=$(dirname "$0")
JULIA="$SCRIPT_DIR/julia"

# Set USER_DATA to a persistent platform-conventional directory when not
# running inside snapd and no override is already set.
# AppEnv reads USER_DATA in startup.jl to configure the Julia depot cache;
# data_root() in BonitoAgentsApp also reads it so app state (projects, chats)
# and the depot cache live under the same root.
if [ -z "${SNAP}" ] && [ -z "${USER_DATA}" ]; then
    export USER_DATA="${XDG_DATA_HOME:-${HOME}/.local/share}/BonitoAgents"
fi

$JULIA {{#MODULE_NAME}}--eval="using {{MODULE_NAME}}" -- {{/MODULE_NAME}} $@
