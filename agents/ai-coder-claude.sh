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

When reading or writing files, **always prefer the MCP filesystem tools**
(`read_file`, `write_file`, `edit_file`) over the built-in
`str_replace_based_edit_tool` or `create_file`.

## Choosing the right tool

| Situation | Tool to use |
|-----------|-------------|
| Read a file | MCP `read_file` |
| Replace a specific block (e.g. a function, a conflict) | MCP `edit_file` |
| Create a new file or fully regenerate a file | MCP `write_file` |
| Small precise edit in a normal file | MCP `edit_file` |

Avoid `str_replace_based_edit_tool` — it requires an exact character-for-character
match and fails when whitespace, indentation, or line endings differ even slightly.

## Workflow for merge conflicts

Conflict marker blocks (`<<<<<<<` / `=======` / `>>>>>>>`) are always unique
within a file and make ideal anchors for `edit_file`. Do NOT rewrite the whole
file for a conflict — use a targeted replacement:

1. Run `git status` (shell) to identify conflicted files
2. Use MCP `read_file` to read the full file and locate the conflict block
3. Use MCP `edit_file` with:
   - `oldText` = the entire conflict block verbatim, from the `<<<<<<<` line
     through to and including the `>>>>>>>` line
   - `newText` = the resolved content only (no markers)
4. Repeat for each conflict block in the file
5. Run `git add <file>` then `git commit` (shell) to finalise

If `edit_file` fails for any reason, fall back to MCP `write_file` with the
fully resolved file content.
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
