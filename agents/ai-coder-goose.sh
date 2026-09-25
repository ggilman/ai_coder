#!/bin/bash
# ==============================================================================
# AI-CODER-GOOSE.SH | Goose Variant Overrides
# ==============================================================================

IMAGE_NAME="ai-coder-goose"
TOOL_NAME="Goose"
RESUME_FLAG="--resume"

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

# _mcp_each_server callback (ai-coder-env.sh) emitting one entry of goose's
# config.yaml `extensions:` block — the same mcp-*.txt manifests the other
# agents register as JSON. Values are double-quoted YAML, whose escapes are
# JSON-compatible, so _mcp_json_escape covers them.
_goose_mcp_extension_yaml() {
    local key="$1" cmd="$2" args_str="$3" env_specs="$4" workspace="$5"
    printf '  %s:\n    enabled: true\n    type: stdio\n    cmd: "%s"\n' "$key" "$(_mcp_json_escape "$cmd")"
    if [ -n "$args_str" ]; then
        printf '    args:\n'
        local a
        for a in $args_str; do printf '      - "%s"\n' "$(_mcp_json_escape "$a")"; done
    else
        printf '    args: []\n'
    fi

    local pairs; pairs=$(_mcp_env_pairs "$env_specs" "$workspace")
    if [ -n "$pairs" ]; then
        printf '    envs:\n'
        local pair
        while IFS= read -r pair; do
            printf '      %s: "%s"\n' "${pair%%=*}" "$(_mcp_json_escape "${pair#*=}")"
        done <<< "$pairs"
    else
        printf '    envs: {}\n'
    fi
    printf '    timeout: 300\n'
}

configure_workbench() {
    local config_dir="$HOME/.goose-config"
    # Docker runs as root so mounted dir files can become root-owned on the WSL host.
    ensure_host_dir_writable "$config_dir"

    local mcp_files=()
    mapfile -t mcp_files < <(mcp_manifest_files mcp-goose.txt)

    # Always rewrite config.yaml so the endpoint/extensions reflect the current
    # project and infra. GOOSE_DISABLE_KEYRING sidesteps a DBus secret-service
    # lookup that fails inside the headless container — no secret is actually
    # stored here, OPENAI_API_KEY is injected via env var in start_workbench.
    cat > "$config_dir/config.yaml" <<EOF
GOOSE_PROVIDER: openai
GOOSE_MODEL: $(model_id)
GOOSE_DISABLE_KEYRING: "1"
OPENAI_HOST: $ENGINE_URL
OPENAI_BASE_PATH: v1/chat/completions
extensions:
$(_mcp_each_server _goose_mcp_extension_yaml "/$WORKSPACE_DIR" "${mcp_files[@]}")
EOF
}

start_workbench() {
    run_workbench \
        -v "$(to_host_path "$HOME/.goose-config"):/root/.config/goose" \
        -e OPENAI_API_KEY="${LOCAL_API_KEY}" \
        -e GOOSE_DISABLE_KEYRING=1
}

execute_tool() {
    exec_in_container \
        -e TERM=xterm-256color -e COLORTERM=truecolor \
        "$WORKBENCH" goose session "${RESUME_ARGS[@]}"
}
