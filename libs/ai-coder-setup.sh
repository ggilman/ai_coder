#!/bin/bash
# ==============================================================================
# AI-CODER | Setup Wizard & Project-Fix Commands
# ==============================================================================

# ------------------------------------------------------------------------------
# cmd_fix_project — normalize line endings in the current git project
# ------------------------------------------------------------------------------
cmd_fix_project() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo -e "${RED}✘ Not inside a git repository. Run this from your project folder.${NC}"
        return 1
    fi

    _proj_root=$(git rev-parse --show-toplevel)
    _ga="$_proj_root/.gitattributes"
    _ec="$_proj_root/.editorconfig"

    echo -e "\n${CYAN}◈ Fixing project: ${BOLD}$_proj_root${NC}\n"

    # .gitattributes — add eol=lf catch-all if not already present
    if grep -q 'eol=lf' "$_ga" 2>/dev/null; then
        echo -e "${DIM}  .gitattributes already has eol=lf — skipping.${NC}"
    else
        if [ -f "$_ga" ]; then
            printf '\n# Normalize all text files to LF (added by ai-coder --fix-project)\n* text=auto eol=lf\n' >> "$_ga"
            echo -e "${ICON_OK} Appended LF normalization rule to .gitattributes"
        else
            printf '# Normalize all text files to LF\n* text=auto eol=lf\n\n*.png  binary\n*.jpg  binary\n*.jpeg binary\n*.gif  binary\n*.gz   binary\n*.zip  binary\n' > "$_ga"
            echo -e "${ICON_OK} Created .gitattributes with LF normalization rules"
        fi
    fi

    # .editorconfig — create if absent
    if [ -f "$_ec" ]; then
        echo -e "${DIM}  .editorconfig already exists — skipping.${NC}"
    else
        printf 'root = true\n\n[*]\nend_of_line = lf\ncharset = utf-8\ntrim_trailing_whitespace = true\ninsert_final_newline = true\n\n[*.md]\ntrim_trailing_whitespace = false\n' > "$_ec"
        echo -e "${ICON_OK} Created .editorconfig (lf, utf-8)"
    fi

    # Set autocrlf=input locally so git strips CR on add
    git -C "$_proj_root" config --local core.autocrlf input
    echo -e "${ICON_OK} Set core.autocrlf=input in .git/config"

    # Renormalize all tracked files to LF
    echo -e "${CYAN}◈ Renormalizing tracked files (this may take a moment)...${NC}"
    git -C "$_proj_root" add --renormalize . 2>/dev/null && \
        echo -e "${ICON_OK} All tracked files normalized to LF" || \
        echo -e "${YELLOW}⚠ Renormalize had warnings — check git status${NC}"

    echo -e "\n${ICON_OK} Done. Commit the changes to lock them in:\n  ${CYAN}git commit -m 'chore: normalize line endings to LF'${NC}\n"
}

# ------------------------------------------------------------------------------
# cmd_update — download and install the latest release from GitHub
# ------------------------------------------------------------------------------
cmd_update() {
    local install_dir; install_dir="$(dirname "$SCRIPT_DIR")"
    local tarball_url="https://github.com/ggilman/ai_coder/archive/refs/heads/release.tar.gz"
    local tmp_dir; tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN

    echo -e "${ICON_GEAR} Downloading latest release..."
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 "$tarball_url" | tar xz --strip-components=1 -C "$tmp_dir" || {
            echo -e "${RED}✘ Download failed${NC}"; return 1
        }
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout=30 "$tarball_url" | tar xz --strip-components=1 -C "$tmp_dir" || {
            echo -e "${RED}✘ Download failed${NC}"; return 1
        }
    else
        echo -e "${RED}✘ Neither curl nor wget is available${NC}"; return 1
    fi

    echo -e "${ICON_GEAR} Installing..."

    # Wipe dirs that are entirely release-owned so deleted/renamed files don't linger
    rm -rf "$install_dir/agents" "$install_dir/libs" "$install_dir/packages" "$install_dir/offline"

    # Wipe release-owned top-level files
    rm -f "$install_dir/ai-coder" "$install_dir/ai-status.sh" \
          "$install_dir/LICENSE" "$install_dir/README.md" \
          "$install_dir/.gitignore" "$install_dir/.gitattributes" "$install_dir/.editorconfig" \
          "$install_dir/config/ai-coder-model.conf"

    # For config/families: only remove files that exist in the new release so user-added
    # custom family confs are preserved
    if [ -d "$tmp_dir/config/families" ]; then
        for _f in "$tmp_dir/config/families"/*; do
            [ -f "$_f" ] && rm -f "$install_dir/config/families/$(basename "$_f")"
        done
    fi

    cp -r "$tmp_dir/." "$install_dir/"
    chmod +x "$install_dir/ai-coder" "$install_dir/ai-status.sh"

    # Record the installed release hash so future update checks have a baseline to compare
    local new_hash; new_hash=$(_fetch_release_hash) || true
    [ -n "$new_hash" ] && printf '%s\\n' "$new_hash" > "$HOME/.ai-coder-release-hash"

    printf 'rebuild_required=true\\n' > "$HOME/.ai-coder-rebuild-needed"

    echo -e \"${ICON_OK} Updated successfully${NC}\"

    # Reset timestamp so the next run doesn't immediately re-check
    printf 'last_check=%s\n' "$(date +%s 2>/dev/null || echo 0)" > "$HOME/.ai-coder-update-check"
}

# ------------------------------------------------------------------------------
# cmd_setup — first-time and re-configuration wizard
# ------------------------------------------------------------------------------
cmd_setup() {
    rc_file="$HOME/.bashrc"
    if [ "$IS_GITBASH" = "true" ]; then
        rc_file="$HOME/.bash_profile"
    elif [ "$SHELL" != "${SHELL%zsh}" ]; then
        rc_file="$HOME/.zshrc"
    fi

    echo -e "\n${CYAN}Shell alias — '${ALIAS_NAME}' shortcut in $rc_file${NC}"
    echo -e "${DIM}  Skip if you prefer to add ai-coder to your PATH manually.${NC}"
    _alias_exists=false
    grep -q "alias $ALIAS_NAME=" "$rc_file" 2>/dev/null && _alias_exists=true
    echo -e "${DIM}  Current: $([ "$_alias_exists" = "true" ] && echo "set" || echo "not set")${NC}"
    echo -n "  Add alias? [y/n, Enter to keep]: "
    read -r _alias_input
    case "${_alias_input,,}" in
        y|yes)
            touch "$rc_file"
            sed -i.bak "/alias $ALIAS_NAME=/d" "$rc_file"
            echo "alias $ALIAS_NAME='\"$(realpath "$0")\"'" >> "$rc_file"
            echo -e "${ICON_OK} Alias '${ALIAS_NAME}' added to $rc_file. Run: ${CYAN}source $rc_file${NC}"
            ;;
        n|no)
            touch "$rc_file"
            sed -i.bak "/alias $ALIAS_NAME=/d" "$rc_file"
            echo -e "${DIM}  Alias removed from $rc_file.${NC}"
            ;;
        *)
            echo -e "${DIM}  Alias unchanged.${NC}"
            ;;
    esac

    echo -e "\n${CYAN}Proxy configuration:${NC}"
    _cur_proxy=$(cat "$HOME/.ai-coder-proxy" 2>/dev/null || true)
    [ -n "$_cur_proxy" ] && printf "%s%s %s%s\n" "$DIM" "  Current:" "$_cur_proxy" "$NC" || printf "%s%s%s\n" "$DIM" "  Current: none" "$NC"
    echo -e "${DIM}  Enter a URL to set, '-' to clear, or leave blank to keep.${NC}"
    echo -n "  Proxy URL: "
    read -r _proxy_input
    case "$_proxy_input" in
        "")
            echo -e "${DIM}  Proxy unchanged.${NC}"
            ;;
        -)
            rm -f "$HOME/.ai-coder-proxy"
            echo -e "${DIM}  Proxy cleared.${NC}"
            ;;
        *)
            echo "$_proxy_input" > "$HOME/.ai-coder-proxy"
            printf "%s  Proxy saved: %s%s%s\n" "${ICON_OK}" "${CYAN}" "$_proxy_input" "${NC}"
            ;;
    esac

    echo -e "\n${CYAN}Network isolation — block all internet access from containers?${NC}"
    echo -e "${DIM}  (Recommended for regulated environments. Leave blank to keep current setting.)${NC}"
    _cur_iso=$(read_pref "$HOME/.ai-coder-netconfig" isolated no)
    printf "%s%s %s%s\n" "$DIM" "  Current:" "$_cur_iso" "$NC"
    echo -n "  Isolate containers? [y/N]: "
    read -r _iso_input
    case "${_iso_input,,}" in
        y|yes)
            printf 'isolated=yes\n' > "$HOME/.ai-coder-netconfig"
            echo -e "${ICON_OK} Network isolation ${GREEN}enabled${NC}."
            ;;
        n|no)
            printf 'isolated=no\n' > "$HOME/.ai-coder-netconfig"
            echo -e "${DIM}  Network isolation disabled.${NC}"
            ;;
        *)
            printf "%s  Network isolation unchanged (%s)%s\n" "$DIM" "$_cur_iso" "$NC"
            ;;
    esac

    # GPU mode — only prompt if multiple GPUs are detected
    _gpu_count=1
    _gpu_count=$($SMI --query-gpu=name --format=csv,noheader,nounits 2>/dev/null | grep -c '.' || echo 1)
    if [ "${_gpu_count:-1}" -gt 1 ]; then
        echo -e "\n${CYAN}GPU mode — ${_gpu_count} GPUs detected. Use all for inference?${NC}"
        _cur_gpu=$(read_pref "$HOME/.ai-coder-gpuconf" gpu_mode multi)
        printf "%s%s %s%s\n" "$DIM" "  Current:" "$_cur_gpu" "$NC"
        echo -n "  Use all GPUs? [Y/n]: "
        read -r _gpu_input
        case "${_gpu_input,,}" in
            n|no)
                printf 'gpu_mode=single\n' > "$HOME/.ai-coder-gpuconf"
                echo -e "${DIM}  GPU mode set to single.${NC}"
                ;;
            *)
                printf 'gpu_mode=multi\n' > "$HOME/.ai-coder-gpuconf"
                echo -e "${ICON_OK} GPU mode set to ${GREEN}multi${NC}."
                ;;
        esac
    fi

    echo -e "\n${CYAN}Context window level — how many tokens of context should the model keep?${NC}"
    echo -e "${DIM}  4k / 8k / 16k / 32k / 64k / 128k (default) / 256k${NC}"
    echo -e "${DIM}  Larger = more context, but higher VRAM usage and slower responses.${NC}"
    _cur_ctx=$(read_pref "$HOME/.ai-coder-ctxconfig" ctx_level 128k)
    printf "%s%s %s%s\n" "$DIM" "  Current:" "$_cur_ctx" "$NC"
    echo -n "  Context level [${_cur_ctx}]: "
    read -r _ctx_input
    _ctx_input="${_ctx_input:-}"
    case "${_ctx_input}" in
        4k|8k|16k|32k|64k|128k|256k)
            printf 'ctx_level=%s\n' "$_ctx_input" > "$HOME/.ai-coder-ctxconfig"
            printf "%s%s Context level set to %s%s%s\n" "${ICON_OK}" "" "${GREEN}" "$_ctx_input" "${NC}."
            ;;
        "")
            printf "%s  Context level unchanged (%s)%s\n" "$DIM" "$_cur_ctx" "$NC"
            ;;
        *)
            printf "%s⚠ Unknown level '%s' — keeping %s%s\n" "$YELLOW" "$_ctx_input" "$_cur_ctx" "$NC"
            ;;
    esac

    echo -e "\n${CYAN}Host port exposure — publish the engine on localhost:8080?${NC}"
    echo -e "${DIM}  Allows external applications (e.g. Open WebUI) to connect directly.${NC}"
    echo -e "${DIM}  Leave disabled if you only need the AI coding tools inside Docker.${NC}"
    _cur_expose=$(read_pref "$HOME/.ai-coder-portconfig" expose_host_port no)
    printf "%s%s %s%s\n" "$DIM" "  Current:" "$_cur_expose" "$NC"
    echo -n "  Expose engine on localhost:8080? [y/N]: "
    read -r _expose_input
    case "${_expose_input,,}" in
        y|yes)
            printf 'expose_host_port=yes\n' > "$HOME/.ai-coder-portconfig"
            echo -e "${ICON_OK} Engine will be published on ${CYAN}localhost:8080${NC}."
            ;;
        n|no)
            printf 'expose_host_port=no\n' > "$HOME/.ai-coder-portconfig"
            echo -e "${DIM}  Engine port not exposed to host.${NC}"
            ;;
        *)
            printf "%s  Host port exposure unchanged (%s)%s\n" "$DIM" "$_cur_expose" "$NC"
            ;;
    esac

    echo -e "\n${CYAN}Git identity for commits inside containers:${NC}"
    _cur_git_email=$(read_pref "$HOME/.ai-coder-gitconfig" email)
    _cur_git_name=$(read_pref "$HOME/.ai-coder-gitconfig" name)
    [ -z "$_cur_git_email" ] && _cur_git_email=$(git config --global user.email 2>/dev/null || true)
    [ -z "$_cur_git_name" ]  && _cur_git_name=$(git config --global user.name 2>/dev/null || true)
    [ -n "$_cur_git_email" ] && printf "%s%s %s <%s>%s\n" "$DIM" "  Current:" "$_cur_git_name" "$_cur_git_email" "$NC"
    echo -n "  Email (leave blank to keep): "
    read -r _git_email_input
    echo -n "  Name  (leave blank to keep): "
    read -r _git_name_input
    _final_git_email="${_git_email_input:-$_cur_git_email}"
    _final_git_name="${_git_name_input:-$_cur_git_name}"
    if [ -n \"$_final_git_email\" ] || [ -n \"$_final_git_name\" ]; then
        if [[ \"$_final_git_email\" != \"$_cur_git_email\" || \"$_final_git_name\" != \"$_cur_git_name\" ]]; then
            printf 'rebuild_required=true\\n' > \"$HOME/.ai-coder-rebuild-needed\"
            echo -e \"${YELLOW}  Note: Git identity changed. A rebuild (ai --rebuild) is required to bake this into the image.${NC}\"
        fi
        printf 'email=%s\\nname=%s\\n' \"$_final_git_email\" \"$_final_git_name\" > \"$HOME/.ai-coder-gitconfig\"
        echo -e \"${ICON_OK} Git identity saved.\"\n    else
        echo -e "${DIM}  No git identity set — commits will use container defaults.${NC}"
    fi

    touch "$HOME/.ai-coder-setup"
    echo -e "\n${ICON_OK} Setup complete."
}
