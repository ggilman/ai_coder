#!/bin/bash
# ==============================================================================
# AI-CODER-CLAUDE.SH | Claude-Code Variant Overrides
# ==============================================================================

IMAGE_NAME="claude-engineer-v4-9"
TOOL_NAME="Claude"

build_image() {
    echo -e "${ICON_GEAR} Building Coder Image..."
    local pm_proxy_cmds; pm_proxy_cmds=$(make_npm_proxy_cmds)
    local pip_proxy_cmds; pip_proxy_cmds=$(make_pip_proxy_cmds)
    local apt_pkgs; apt_pkgs="$(read_package_list "$PACKAGES_DIR/apt-common.txt") $(read_package_list "$PACKAGES_DIR/apt-claude.txt")"
    local mcp_pkgs; mcp_pkgs=$(read_mcp_packages "$PACKAGES_DIR/mcp-common.txt" "$PACKAGES_DIR/mcp-claude.txt")
    local mcp_pip_pkgs; mcp_pip_pkgs=$(read_mcp_pip_packages --offline "$PACKAGES_DIR/mcp-common.txt" "$PACKAGES_DIR/mcp-claude.txt")
    local mcp_pip_online; mcp_pip_online=$(read_mcp_pip_packages --online "$PACKAGES_DIR/mcp-common.txt" "$PACKAGES_DIR/mcp-claude.txt")
    local pip_cmd=""
    if [ -n "$(echo "$mcp_pip_pkgs" | tr -d ' ')" ]; then
        pip_cmd=$'\nRUN '"${pip_proxy_cmds} ${mcp_pip_pkgs}"
    fi
    if [ -n "$(echo "$mcp_pip_online" | tr -d ' ')" ]; then
        pip_cmd+=$'\nRUN '"${pip_proxy_cmds} ${mcp_pip_online} || true"
    fi
    build_standard_image "Dockerfile" "$apt_pkgs" "$pm_proxy_cmds" \
        "RUN npm install -g @anthropic-ai/claude-code ${mcp_pkgs}--quiet${pip_cmd}"
}

configure_workbench() {
    # Docker runs Claude as root so files written back to the mounted ~/.claude-config
    # end up root-owned on the WSL host. Reclaim ownership before writing config.
    if [ ! -d "$HOME/.claude-config" ]; then
        mkdir -p "$HOME/.claude-config"
    elif [ ! -w "$HOME/.claude-config" ]; then
        sudo chown -R "$USER" "$HOME/.claude-config"
    fi
    # Update mcpServers in ~/.claude-config.json while preserving any other keys
    # Claude Code writes there (e.g. telemetry consent, preferences).
    # Writing the new block to a temp file then merging via python3 avoids clobbering
    # saved settings on every launch.
    local _cfg="$HOME/.claude-config.json"
    local _tmp; _tmp=$(mktemp)
    cat > "$_tmp" <<EOF
{
  "mcpServers": {
$(make_mcp_servers_json "/$WORKSPACE_DIR" standard "$PACKAGES_DIR/mcp-common.txt" "$PACKAGES_DIR/mcp-claude.txt")
  }
}
EOF
    if [ -f "$_cfg" ] && command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    new = json.load(f)
try:
    with open(sys.argv[2]) as f:
        old = json.load(f)
    new = {**old, **new}
except Exception:
    pass
with open(sys.argv[2], 'w') as f:
    json.dump(new, f, indent=2)
" "$_tmp" "$_cfg" || cp "$_tmp" "$_cfg"
    else
        cp "$_tmp" "$_cfg"
    fi
    rm -f "$_tmp"
    # Write global instructions so Claude uses MCP tools for file I/O.
    # This avoids the str_replace exact-match failures that occur when editing
    # files with whitespace variance or after merge conflicts add marker lines.
    cat > "$HOME/.claude-config/CLAUDE.md" <<'EOF'
# File Editing Instructions

When reading or writing files, **always use the MCP filesystem tools** — never
the built-in `str_replace_based_edit_tool` or `create_file`.

## Tool reference — exact parameter names

### Read a file
```
mcp__filesystem__read_file
  path: "/abs/path/to/file"
```

### Write (create or fully replace) a file
```
mcp__filesystem__write_file
  path: "/abs/path/to/file"
  content: "<full file content>"
```

### Edit — replace one block inside a file
```
mcp__filesystem__edit_file
  path: "/abs/path/to/file"
  edits:
    - oldText: "<exact text to replace>"
      newText: "<replacement text>"
```

`edits` is an array — you may include multiple `{oldText, newText}` pairs in a
single call to make several replacements atomically.

## Why MCP filesystem, not built-in tools?

`str_replace_based_edit_tool` requires a character-for-character match and fails
whenever indentation, trailing spaces, or line endings differ even slightly.
The MCP filesystem tools are tolerant of minor whitespace variance.

## Workflow for merge conflicts

1. Run `git status` (shell) to list conflicted files.
2. Use `mcp__filesystem__read_file` to read the file and locate the conflict block.
3. Use `mcp__filesystem__edit_file` with:
   - `oldText` = the entire conflict block verbatim, from `<<<<<<<` through `>>>>>>>`
   - `newText` = the resolved content (no conflict markers)
4. Repeat for every conflict block.
5. Run `git add <file>` then `git commit` (shell) to finalise.

If `edit_file` fails, fall back to `mcp__filesystem__write_file` with the fully
resolved file content.
EOF
}

start_workbench() {
    echo -e "${ICON_GEAR} Mapping Spoke for [$PROJECT_ID]..."
    local _model_id="${MODEL_FILE%.gguf}"
    run_workbench \
        -v "$(to_host_path "$HOME/.npm-cache"):/root/.npm" \
        -v "$(to_host_path "$HOME/.claude-config"):/root/.claude" \
        -v "$(to_host_path "$HOME/.claude-config.json"):/root/.claude.json" \
        -e ANTHROPIC_BASE_URL="http://$GLOBAL_ENGINE_NAME:8080" \
        -e ANTHROPIC_API_KEY="sk-local-bypass" \
        -e ANTHROPIC_MODEL="$_model_id"
}

execute_tool() {
    exec_in_container -e CLAUDE_CODE_SIMPLE=1 "${WORKBENCH_PREFIX}-${PROJECT_ID}" claude --bare
}
