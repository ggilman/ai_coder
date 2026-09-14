#!/bin/bash
# ==============================================================================
# AI-CODER-GOOSE.SH | Goose Variant Overrides
# ==============================================================================

IMAGE_NAME="ai-coder-goose"
TOOL_NAME="Goose"

build_image() {
    # Goose ships no npm package of its own (Rust binary via install script), so
    # npm_pkg is left blank — build_npm_agent_image still installs every MCP
    # server from mcp-common.txt/mcp-extra.txt/mcp-goose.txt (npm and pip alike),
    # keeping this agent's tool setup identical to the other agents'.
    build_npm_agent_image "Dockerfile.goose" "apt-goose.txt" "mcp-goose.txt" \
        "" "" \
        "RUN curl -fsSL https://github.com/aaif-goose/goose/releases/download/stable/download_cli.sh | CONFIGURE=false GOOSE_BIN_DIR=/usr/local/bin bash
RUN goose --version"
}

# Emit a goose config.yaml `extensions:` block from the same pipe-delimited
# mcp-*.txt files the other agents use (see make_mcp_servers_json in
# ai-coder-env.sh). Goose's YAML extension schema doesn't fit that JSON-only
# helper, so this is a small standalone equivalent for the same file format.
_goose_mcp_extensions_yaml() {
    local workspace="$1"; shift
    local file pkg key cmd args_str env_vars_str net_req
    for file in "$@"; do
        [ -f "$file" ] || continue
        while IFS='|' read -r pkg key cmd args_str env_vars_str net_req; do
            pkg=$(printf '%s' "$pkg" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            pkg="${pkg#pip:}"
            [[ "$pkg" =~ ^# ]] && continue
            [ -z "$pkg" ] && continue
            net_req=$(printf '%s' "${net_req:-}" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ "$net_req" = "online" ] && [ "${NETWORK_INTERNAL:-false}" = "true" ] && continue
            key=$(printf '%s' "$key" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            cmd=$(printf '%s' "$cmd" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            args_str=$(printf '%s' "$args_str" | tr -d '\r' | \
                sed "s|{workspace}|$workspace|g;s/^[[:space:]]*//;s/[[:space:]]*$//")

            printf '  %s:\n    enabled: true\n    type: stdio\n    cmd: "%s"\n' "$key" "$cmd"
            if [ -n "$args_str" ]; then
                printf '    args:\n'
                local a
                for a in $args_str; do printf '      - "%s"\n' "$a"; done
            else
                printf '    args: []\n'
            fi

            env_vars_str=$(printf '%s' "${env_vars_str:-}" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [ -n "$env_vars_str" ]; then
                printf '    envs:\n'
                local en env_names
                IFS=',' read -ra env_names <<< "$env_vars_str"
                for en in "${env_names[@]}"; do
                    en=$(printf '%s' "$en" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    [ -z "$en" ] && continue
                    if [[ "$en" == *=* ]]; then
                        local ek="${en%%=*}" ev="${en#*=}"
                        ev=$(printf '%s' "$ev" | sed "s|{workspace}|$workspace|g")
                        printf '      %s: "%s"\n' "$ek" "$ev"
                    else
                        printf '      %s: "%s"\n' "$en" "${!en:-}"
                    fi
                done
            else
                printf '    envs: {}\n'
            fi
            printf '    timeout: 300\n'
        done < "$file"
    done
}

configure_workbench() {
    local config_dir="$HOME/.goose-config"
    # Docker runs as root so mounted dir files can become root-owned on the WSL host.
    ensure_host_dir_writable "$config_dir"
    local _model_id="${MODEL_FILE##*/}"; _model_id="${_model_id%.gguf}"

    local mcp_files=("$PACKAGES_DIR/mcp-common.txt")
    [ "$(read_pref "$SETTINGS_FILE" mcp_extras no)" = "yes" ] && mcp_files+=("$PACKAGES_DIR/mcp-extra.txt")
    mcp_files+=("$PACKAGES_DIR/mcp-goose.txt")

    # Always rewrite config.yaml so the endpoint/extensions reflect the current
    # project and infra. GOOSE_DISABLE_KEYRING sidesteps a DBus secret-service
    # lookup that fails inside the headless container — no secret is actually
    # stored here, OPENAI_API_KEY is injected via env var in start_workbench.
    cat > "$config_dir/config.yaml" <<EOF
GOOSE_PROVIDER: openai
GOOSE_MODEL: $_model_id
GOOSE_DISABLE_KEYRING: "1"
OPENAI_HOST: http://$GLOBAL_ENGINE_NAME:$ENGINE_PORT
OPENAI_BASE_PATH: v1/chat/completions
extensions:
$(_goose_mcp_extensions_yaml "/$WORKSPACE_DIR" "${mcp_files[@]}")
EOF
}

start_workbench() {
    run_workbench \
        -v "$(to_host_path "$HOME/.goose-config"):/root/.config/goose" \
        -e OPENAI_API_KEY="${LOCAL_API_KEY}" \
        -e GOOSE_DISABLE_KEYRING=1
}

execute_tool() {
    local _resume=()
    [ "${CONTINUE_SESSION:-false}" = "true" ] && _resume=(--resume)
    exec_in_container \
        -e TERM=xterm-256color -e COLORTERM=truecolor \
        "$WORKBENCH" goose session "${_resume[@]}"
}
