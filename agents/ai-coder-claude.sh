#!/bin/bash
# ==============================================================================
# AI-CODER-CLAUDE.SH | Claude-Code Variant Overrides
# ==============================================================================

IMAGE_NAME="ai-coder-claude"
TOOL_NAME="Claude"
RESUME_FLAG="--continue"
# Set by configure_workbench when agent instructions are rendered.
CLAUDE_PROMPT_ARGS=()

build_image() {
    build_npm_agent_image "Dockerfile" "apt-claude.txt" "mcp-claude.txt" \
        "@anthropic-ai/claude-code" "--quiet" ""
}

configure_workbench() {
    # Docker runs Claude as root so files written back to the mounted ~/.claude-config
    # end up root-owned on the WSL host. Reclaim ownership before writing config.
    ensure_host_dir_writable "$HOME/.claude-config"
    # Update mcpServers in ~/.claude-config.json while preserving any other keys
    # Claude Code writes there (e.g. telemetry consent, dark mode, preferences).
    local _cfg="$HOME/.claude-config.json"
    local _tmp; _tmp=$(mktemp)
    cat > "$_tmp" <<EOF
{
  "mcpServers": {
$(make_agent_mcp_json "/$WORKSPACE_DIR" standard mcp-claude.txt)
  }
}
EOF
    merge_json_file "$_tmp" "$_cfg"
    rm -f "$_tmp"
    report_mcp_registration "/$WORKSPACE_DIR" standard "mcp-claude.txt"
    # Agent instructions (prompts/) go in through --append-system-prompt-file
    # in execute_tool: --bare skips CLAUDE.md discovery, both ~/.claude's and
    # the project's, so the project's CLAUDE.md (or AGENTS.md) is folded into
    # the same file. Earlier ai-coder versions wrote a ~/.claude/CLAUDE.md
    # that --bare never read — remove it if it's still that generated file.
    if [ "$(head -n 1 "$HOME/.claude-config/CLAUDE.md" 2>/dev/null)" = "# File Editing Instructions" ]; then
        rm -f "$HOME/.claude-config/CLAUDE.md"
    fi
    CLAUDE_PROMPT_ARGS=()
    if render_agent_prompt claude "$HOME/.claude-config/ai-coder-prompt.md" \
            "$(project_instructions_file CLAUDE.md AGENTS.md)"; then
        CLAUDE_PROMPT_ARGS=(--append-system-prompt-file /root/.claude/ai-coder-prompt.md)
    fi
}

start_workbench() {
    run_workbench \
        -v "$(to_host_path "$HOME/.npm-cache"):/root/.npm" \
        -v "$(to_host_path "$HOME/.claude-config"):/root/.claude" \
        -v "$(to_host_path "$HOME/.claude-config.json"):/root/.claude.json" \
        -e ANTHROPIC_BASE_URL="$ENGINE_URL" \
        -e ANTHROPIC_API_KEY="${LOCAL_API_KEY}" \
        -e ANTHROPIC_MODEL="$(model_id)"
}

execute_tool() {
    # Per-session settings go on the exec, not the container, since they
    # follow the model and context size and the container can outlive them.
    #  - ATTRIBUTION_HEADER=0: the per-request attribution header changes the
    #    prompt prefix, so neither engine's prefix cache hits across turns
    #    (unsloth's and SGLang's Claude Code guidance).
    #  - MAX_CONTEXT_TOKENS: the GGUF-name model ID is unknown to Claude Code,
    #    so it would otherwise assume a larger window and never compact
    #    before the engine rejects the prompt.
    #  - DEFAULT_HAIKU_MODEL: background requests name the local model too.
    #  - MAX_OUTPUT_TOKENS: the family's model-card value, when it has one.
    local _env=(
        -e CLAUDE_CODE_SIMPLE=1
        -e CLAUDE_CODE_ATTRIBUTION_HEADER=0
        -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
        -e CLAUDE_CODE_MAX_CONTEXT_TOKENS="$MODEL_CTX_SIZE"
        -e ANTHROPIC_DEFAULT_HAIKU_MODEL="$(model_id)"
    )
    local _max_out; _max_out=$(agent_max_output_tokens)
    [ -n "$_max_out" ] && _env+=(-e CLAUDE_CODE_MAX_OUTPUT_TOKENS="$_max_out")
    exec_in_container "${_env[@]}" "$WORKBENCH" claude --bare "${CLAUDE_PROMPT_ARGS[@]}" "${RESUME_ARGS[@]}"
}
