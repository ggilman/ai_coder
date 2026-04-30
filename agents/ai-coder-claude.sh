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
    local mcp_pip_pkgs; mcp_pip_pkgs=$(read_mcp_pip_packages "$PACKAGES_DIR/mcp-common.txt" "$PACKAGES_DIR/mcp-claude.txt")
    local pip_cmd=""
    if [ -n "$(echo "$mcp_pip_pkgs" | tr -d ' ')" ]; then
        pip_cmd=$'\nRUN '"${pip_proxy_cmds} ${mcp_pip_pkgs}"
    fi
    build_standard_image "Dockerfile" "$apt_pkgs" "$pm_proxy_cmds" \
        "RUN npm install -g @anthropic-ai/claude-code ${mcp_pkgs}--quiet${pip_cmd}"
}

configure_workbench() {
    mkdir -p "$HOME/.claude-config"
    # Always rewrite so mcpServers paths reflect the current project workspace.
    # Auth tokens are stored in ~/.claude/ (the directory), not this JSON file.
    cat > "$HOME/.claude-config.json" <<EOF
{
  "mcpServers": {
$(make_mcp_servers_json "/$WORKSPACE_DIR" standard "$PACKAGES_DIR/mcp-common.txt" "$PACKAGES_DIR/mcp-claude.txt")
  }
}
EOF
    # Write global instructions so Claude uses MCP tools for file I/O.
    # This avoids the str_replace exact-match failures that occur when editing
    # files with whitespace variance or after merge conflicts add marker lines.
    cat > "$HOME/.claude-config/CLAUDE.md" <<'EOF'
# File Editing Instructions

When reading or writing files — especially during merge conflict resolution —
**always use the MCP filesystem tools** (`read_file`, `write_file`) instead of
the built-in `str_replace_based_edit_tool` or `create_file`.

## Why

The built-in `str_replace` tool requires an exact character-for-character match
of the text being replaced. This fails when:
- Files contain conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`)
- Whitespace or indentation differs from what was previously read
- The file was modified between the read and the edit

The MCP `write_file` tool replaces the whole file atomically and never fails
due to content mismatch.

## Workflow for merge conflicts

1. Run `git status` (shell) to identify conflicted files
2. Use `read_file` (MCP filesystem) to read the full file content
3. Resolve all conflict blocks in memory
4. Use `write_file` (MCP filesystem) to write the complete resolved content
5. Run `git add <file>` then `git commit` (shell) to finalise
EOF
}

start_workbench() {
    echo -e "${ICON_GEAR} Mapping Spoke for [$PROJECT_ID]..."
    run_workbench \
        -v "$(to_host_path "$HOME/.npm-cache"):/root/.npm" \
        -v "$(to_host_path "$HOME/.claude-config"):/root/.claude" \
        -v "$(to_host_path "$HOME/.claude-config.json"):/root/.claude.json" \
        -e ANTHROPIC_BASE_URL="http://$GLOBAL_ENGINE_NAME:8080" \
        -e ANTHROPIC_API_KEY="sk-local-bypass"
}

execute_tool() {
    exec_in_container -e CLAUDE_CODE_SIMPLE=1 "${WORKBENCH_PREFIX}-${PROJECT_ID}" claude --bare
}
