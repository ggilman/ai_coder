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
# cmd_setup — first-time and re-configuration wizard
# ------------------------------------------------------------------------------
cmd_setup() {
    rc_file="$HOME/.bashrc"
    if [ "$IS_GITBASH" = "true" ]; then
        rc_file="$HOME/.bash_profile"
    elif [ "$SHELL" != "${SHELL%zsh}" ]; then
        rc_file="$HOME/.zshrc"
    fi

    echo -e "\n${CYAN}Shell alias — add '${ALIAS_NAME}' shortcut to $rc_file?${NC}"
    echo -e "${DIM}  Skip if you prefer to add ai-coder to your PATH manually.${NC}"
    echo -n "  Add alias? [Y/n]: "
    read -r _alias_input
    touch "$rc_file"
    sed -i.bak "/alias $ALIAS_NAME=/d" "$rc_file"
    case "${_alias_input,,}" in
        n|no)
            echo -e "${DIM}  Alias not added. Any previous alias has been removed from $rc_file.${NC}"
            ;;
        *)
            echo "alias $ALIAS_NAME='$(realpath "$0")'" >> "$rc_file"
            echo -e "${ICON_OK} Alias '${ALIAS_NAME}' added to $rc_file. Run: ${CYAN}source $rc_file${NC}"
            ;;
    esac

    echo -e "\n${CYAN}Proxy configuration (leave blank for none / to clear existing):${NC}"
    if [ -f "$HOME/.ai-coder-proxy" ]; then
        _cur_proxy=$(cat "$HOME/.ai-coder-proxy" 2>/dev/null || true)
        echo -e "${DIM}  Current proxy: ${_cur_proxy}${NC}"
    fi
    echo -n "  Proxy URL: "
    read -r _proxy_input
    if [ -n "$_proxy_input" ]; then
        echo "$_proxy_input" > "$HOME/.ai-coder-proxy"
        echo -e "${ICON_OK} Proxy saved: ${CYAN}${_proxy_input}${NC}"
    else
        rm -f "$HOME/.ai-coder-proxy"
        echo -e "${DIM}  No proxy set.${NC}"
    fi

    echo -e "\n${CYAN}Network isolation — block all internet access from containers?${NC}"
    echo -e "${DIM}  (Recommended for regulated environments. Leave blank to keep current setting.)${NC}"
    _cur_iso=$(read_pref "$HOME/.ai-coder-netconfig" isolated no)
    echo -e "${DIM}  Current: ${_cur_iso}${NC}"
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
            echo -e "${DIM}  Network isolation unchanged (${_cur_iso}).${NC}"
            ;;
    esac

    # GPU mode — only prompt if multiple GPUs are detected
    _gpu_count=1
    _gpu_count=$($SMI --query-gpu=name --format=csv,noheader,nounits 2>/dev/null | grep -c '.' || echo 1)
    if [ "${_gpu_count:-1}" -gt 1 ]; then
        echo -e "\n${CYAN}GPU mode — ${_gpu_count} GPUs detected. Use all for inference?${NC}"
        _cur_gpu=$(read_pref "$HOME/.ai-coder-gpuconf" gpu_mode multi)
        echo -e "${DIM}  Current: ${_cur_gpu}${NC}"
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

    echo -e "\n${CYAN}Host port exposure — publish the engine on localhost:8080?${NC}"
    echo -e "${DIM}  Allows external applications (e.g. Open WebUI) to connect directly.${NC}"
    echo -e "${DIM}  Leave disabled if you only need the AI coding tools inside Docker.${NC}"
    _cur_expose=$(read_pref "$HOME/.ai-coder-portconfig" expose_host_port no)
    echo -e "${DIM}  Current: ${_cur_expose}${NC}"
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
            echo -e "${DIM}  Host port exposure unchanged (${_cur_expose}).${NC}"
            ;;
    esac

    echo -e "\n${CYAN}Git identity for commits inside containers:${NC}"
    _cur_git_email=$(read_pref "$HOME/.ai-coder-gitconfig" email)
    _cur_git_name=$(read_pref "$HOME/.ai-coder-gitconfig" name)
    [ -z "$_cur_git_email" ] && _cur_git_email=$(git config --global user.email 2>/dev/null || true)
    [ -z "$_cur_git_name" ]  && _cur_git_name=$(git config --global user.name 2>/dev/null || true)
    [ -n "$_cur_git_email" ] && echo -e "${DIM}  Current: ${_cur_git_name} <${_cur_git_email}>${NC}"
    echo -n "  Email (leave blank to keep): "
    read -r _git_email_input
    echo -n "  Name  (leave blank to keep): "
    read -r _git_name_input
    _final_git_email="${_git_email_input:-$_cur_git_email}"
    _final_git_name="${_git_name_input:-$_cur_git_name}"
    if [ -n "$_final_git_email" ] || [ -n "$_final_git_name" ]; then
        printf 'email=%s\nname=%s\n' "$_final_git_email" "$_final_git_name" > "$HOME/.ai-coder-gitconfig"
        echo -e "${ICON_OK} Git identity saved."
    else
        echo -e "${DIM}  No git identity set — commits will use container defaults.${NC}"
    fi

    touch "$HOME/.ai-coder-setup"
    echo -e "\n${ICON_OK} Setup complete."
}
