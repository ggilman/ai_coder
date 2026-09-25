#!/bin/bash
# ==============================================================================
# AI-CODER-OPENCODE.SH | OpenCode Variant Overrides
# ==============================================================================

IMAGE_NAME="ai-coder-opencode"
TOOL_NAME="OpenCode"
RESUME_FLAG="--continue"

build_image() {
    build_npm_agent_image "Dockerfile.oc" "apt-opencode.txt" "mcp-opencode.txt" \
        "opencode-ai" "" "RUN opencode --version"
}

configure_workbench() {
    local config_dir="$HOME/.opencode-config"
    # Docker runs as root so mounted dir files can become root-owned on the WSL host.
    ensure_host_dir_writable "$config_dir"
    # Agent instructions (prompts/) — OpenCode reads the project's AGENTS.md
    # itself, so only ai-coder's file is listed here.
    local _instructions=""
    if render_agent_prompt opencode "$config_dir/ai-coder-prompt.md"; then
        _instructions='  "instructions": ["/root/.config/opencode/ai-coder-prompt.md"],'
    fi
    # Largest reply: the family's model-card value (capped), else 8192.
    local _max_out; _max_out=$(agent_max_output_tokens)
    # When the engine keeps past reasoning (reasoning_preserved), OpenCode
    # must send it back as reasoning_content — it drops it otherwise.
    local _reasoning=""
    if reasoning_preserved; then
        _reasoning='          "reasoning": true,
          "interleaved": { "field": "reasoning_content" },'
    fi
    cat > "$config_dir/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "share": "disabled",
$_instructions
  "permission": {
    "write": "deny"
  },
  "model": "local/hub-model",
  "provider": {
    "local": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Local $MODEL_FAMILY (llama.cpp)",
      "options": {
        "baseURL": "$ENGINE_URL/v1",
        "apiKey": "$LOCAL_API_KEY"
      },
      "models": {
        "hub-model": {
          "name": "$MODEL_FAMILY Local",
$_reasoning
          "limit": {
            "context": $MODEL_CTX_SIZE,
            "input": $MODEL_CTX_SIZE,
            "output": ${_max_out:-8192}
          }
        }
      }
    }
  },
  "mcp": {
$(make_agent_mcp_json "/$WORKSPACE_DIR" opencode mcp-opencode.txt)
  }
}
EOF
    report_mcp_registration "/$WORKSPACE_DIR" opencode "mcp-opencode.txt"
}

start_workbench() {
    run_workbench \
        -e OPENCODE_DISABLE_MODELS_FETCH=1 \
        -v "$(to_host_path "$HOME/.npm-cache"):/root/.npm" \
        -v "$(to_host_path "$HOME/.opencode-config"):/root/.config/opencode" \
        -v "$(to_host_path "$PACKAGES_DIR/opencode-pty.py"):/opt/opencode-pty.py:ro"
}

execute_tool() {
    # Run through a PTY wrapper (packages/opencode-pty.py) instead of `opencode`
    # directly — OpenCode doesn't handle Ctrl-C well from inside a docker exec
    # TTY, and the wrapper strips it from the input stream instead. The wrapper
    # forwards any extra args it receives straight through to opencode.
    exec_in_container "$WORKBENCH" python3 /opt/opencode-pty.py "${RESUME_ARGS[@]}"
}
