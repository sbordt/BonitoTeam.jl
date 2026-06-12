#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" # $0 can also be a relative path

JULIA="$SCRIPT_DIR/bin/julia"

# Set USER_DATA to a persistent platform-conventional directory when not
# running inside the Apple sandbox and no override is already set.
# AppEnv reads USER_DATA in startup.jl to configure the Julia depot cache;
# data_root() in BonitoAgentsApp also reads it so app state (projects, chats)
# and the depot cache live under the same root.
if [ -z "${APP_SANDBOX_CONTAINER_ID}" ] && [ -z "${USER_DATA}" ]; then
    export USER_DATA="${HOME}/Library/Application Support/BonitoAgents"
fi

{{^WINDOWED}}
if [ $# -eq 0 ]; then
    osascript -e 'tell application "Terminal" to activate' \
              -e 'tell application "Terminal" to do script "clear && '"$JULIA"' {{#MODULE_NAME}}--eval=\"using {{MODULE_NAME}}\" -- {{/MODULE_NAME}}; exit"'
    exit 0
fi
{{/WINDOWED}}
# Arguments provided: Execute in current shell
"$JULIA"{{#MODULE_NAME}} --eval="using {{MODULE_NAME}}" -- {{/MODULE_NAME}} $@
