#!/bin/bash
# ==============================================================================
# AI-CODER | Setup Wizard & Project-Fix Commands
# ==============================================================================

# gum bootstrap/resolution (ensure_gum, resolve_gum_cmd, _download_gum_binary).
# Sourced here (rather than relying on the caller) since ai-status.sh and
# offline/bundle.sh source this file directly without going through the full
# ai-coder launch chain.
source "$(dirname "${BASH_SOURCE[0]}")/ai-coder-gum.sh"

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
    [ -n "$new_hash" ] && write_pref "$STATE_FILE" release_hash "$new_hash"

    echo -e "${ICON_OK} Updated successfully${NC}"

    # Reset timestamp so the next run doesn't immediately re-check
    write_pref "$STATE_FILE" last_check "$(date +%s 2>/dev/null || echo 0)"
}

setup_step_alias() {
    local rc_file="$HOME/.bashrc"
    if [ "$IS_GITBASH" = "true" ]; then
        rc_file="$HOME/.bash_profile"
    elif [ "$SHELL" != "${SHELL%zsh}" ]; then
        rc_file="$HOME/.zshrc"
    fi

    local _alias_exists=false
    grep -q "alias $ALIAS_NAME=" "$rc_file" 2>/dev/null && _alias_exists=true
    local _alias_input; _alias_input=$(ui_yesno "Shell alias" \
        "Shell alias — '${ALIAS_NAME}' shortcut in $rc_file" \
        "Skip if you prefer to add ai-coder to your PATH manually." \
        "Add alias? [y/n, Enter to keep]:" \
        "$([ "$_alias_exists" = "true" ] && echo "set" || echo "not set")" \
        "$([ "$_alias_exists" = "true" ] && echo "yes" || echo "no")")
    case "$_alias_input" in
        yes)
            touch "$rc_file"
            sed -i.bak "/alias $ALIAS_NAME=/d" "$rc_file"
            echo "alias $ALIAS_NAME='\"$(realpath "$0")\"'" >> "$rc_file"
            echo -e "${ICON_OK} Alias '${ALIAS_NAME}' added to $rc_file. Run: ${CYAN}source $rc_file${NC}"
            ;;
        no)
            touch "$rc_file"
            sed -i.bak "/alias $ALIAS_NAME=/d" "$rc_file"
            echo -e "${DIM}  Alias removed from $rc_file.${NC}"
            ;;
        *)
            echo -e "${DIM}  Alias unchanged.${NC}"
            ;;
    esac
}

setup_step_proxy() {
    local _cur_proxy; _cur_proxy=$(read_pref "$SETTINGS_FILE" proxy "")
    local _proxy_input; _proxy_input=$(ui_input "Proxy" \
        "Proxy configuration:" \
        "Enter a URL to set, '-' to clear, or leave blank to keep." \
        "Proxy URL:" \
        "${_cur_proxy:-none}" \
        "$_cur_proxy")
    case "$_proxy_input" in
        "")
            echo -e "${DIM}  Proxy unchanged.${NC}"
            ;;
        -)
            write_pref "$SETTINGS_FILE" proxy ""
            echo -e "${DIM}  Proxy cleared.${NC}"
            ;;
        *)
            write_pref "$SETTINGS_FILE" proxy "$_proxy_input"
            printf "%s  Proxy saved: %s%s%s\n" "${ICON_OK}" "${CYAN}" "$_proxy_input" "${NC}"
            ;;
    esac
}

setup_step_network() {
    local _cur_iso; _cur_iso=$(read_pref "$SETTINGS_FILE" isolated no)
    local _iso_input; _iso_input=$(ui_yesno "Network isolation" \
        "Network isolation — block all internet access from containers?" \
        "(Recommended for regulated environments. Leave blank to keep current setting.)" \
        "Isolate containers? [y/N]:" \
        "$_cur_iso" "$_cur_iso")
    case "$_iso_input" in
        yes)
            write_pref "$SETTINGS_FILE" isolated yes
            echo -e "${ICON_OK} Network isolation ${GREEN}enabled${NC}."
            ;;
        no)
            write_pref "$SETTINGS_FILE" isolated no
            echo -e "${DIM}  Network isolation disabled.${NC}"
            ;;
        *)
            printf "%s  Network isolation unchanged (%s)%s\n" "$DIM" "$_cur_iso" "$NC"
            ;;
    esac
}

# GPU mode — only prompt if multiple GPUs are detected
setup_step_gpu() {
    local _gpu_count; _gpu_count=$($SMI --query-gpu=name --format=csv,noheader,nounits 2>/dev/null | grep -c '.' || echo 1)
    [ "${_gpu_count:-1}" -gt 1 ] || return 0

    local _cur_gpu; _cur_gpu=$(read_pref "$SETTINGS_FILE" gpu_mode multi)
    local _gpu_input; _gpu_input=$(ui_yesno "GPU mode" \
        "GPU mode — ${_gpu_count} GPUs detected. Use all for inference?" \
        "" \
        "Use all GPUs? [Y/n]:" \
        "$_cur_gpu" \
        "$([ "$_cur_gpu" = "multi" ] && echo "yes" || echo "no")")
    case "$_gpu_input" in
        no)
            write_pref "$SETTINGS_FILE" gpu_mode single
            echo -e "${DIM}  GPU mode set to single.${NC}"
            ;;
        yes)
            write_pref "$SETTINGS_FILE" gpu_mode multi
            echo -e "${ICON_OK} GPU mode set to ${GREEN}multi${NC}."
            ;;
        *)
            echo -e "${DIM}  GPU mode unchanged (${_cur_gpu}).${NC}"
            ;;
    esac
}

setup_step_ctx() {
    local _cur_ctx; _cur_ctx=$(read_pref "$SETTINGS_FILE" ctx_level 64k)
    local _ctx_input; _ctx_input=$(ui_menu "Context window" \
        "Context window level — how many tokens of context should the model keep?" \
        "4k / 8k / 16k / 32k / 64k (default) / 128k / 256k
Larger = more context, but higher VRAM usage and slower responses." \
        "Context level [${_cur_ctx}]:" \
        "$_cur_ctx" \
        "4k"   "Smallest — minimal VRAM usage" \
        "8k"   "Small tasks" \
        "16k"  "Light coding sessions" \
        "32k"  "Medium projects" \
        "64k"  "Default — balanced" \
        "128k" "Large codebases" \
        "256k" "Largest — highest VRAM usage, slowest")
    case "${_ctx_input}" in
        4k|8k|16k|32k|64k|128k|256k)
            write_pref "$SETTINGS_FILE" ctx_level "$_ctx_input"
            printf "%s%s Context level set to %s%s%s\n" "${ICON_OK}" "" "${GREEN}" "$_ctx_input" "${NC}."
            ;;
        "")
            printf "%s  Context level unchanged (%s)%s\n" "$DIM" "$_cur_ctx" "$NC"
            ;;
        *)
            printf "%s⚠ Unknown level '%s' — keeping %s%s\n" "$YELLOW" "$_ctx_input" "$_cur_ctx" "$NC"
            ;;
    esac
}

setup_step_kv() {
    local _cur_kvq4; _cur_kvq4=$(read_pref "$SETTINGS_FILE" kv_q4 no)
    local _kvq4_input; _kvq4_input=$(ui_yesno "Low-VRAM KV cache" \
        "Low-VRAM KV cache — quantize both K and V cache to q4_0?" \
        "Roughly halves the KV-cache VRAM reserve vs the family's default (usually
q8_0), which can unlock a bigger model tier or larger context on low-VRAM
cards. Real quality cost on long-context recall — keys are more
quantization-sensitive than values. K and V stay matched, so llama.cpp
keeps using its fast fused Flash Attention kernel (mismatched K/V types
silently fall back to a much slower CPU-bound path)." \
        "Enable low-VRAM (q4_0) KV cache? [y/N]:" \
        "$_cur_kvq4" "$_cur_kvq4")
    case "$_kvq4_input" in
        yes)
            write_pref "$SETTINGS_FILE" kv_q4 yes
            echo -e "${ICON_OK} Low-VRAM KV cache ${GREEN}enabled${NC} (q4_0/q4_0) — applied on next engine start."
            ;;
        no)
            write_pref "$SETTINGS_FILE" kv_q4 no
            echo -e "${DIM}  Low-VRAM KV cache disabled — using the family's default KV type.${NC}"
            ;;
        *)
            printf "%s  Low-VRAM KV cache unchanged (%s)%s\n" "$DIM" "$_cur_kvq4" "$NC"
            ;;
    esac
}

setup_step_vram_overhead() {
    local _cur_vram_oh; _cur_vram_oh=$(read_pref "$SETTINGS_FILE" vram_overhead 1)
    local _vram_oh_input; _vram_oh_input=$(ui_input "VRAM overhead" \
        "VRAM overhead reserve — how many GB of VRAM should be reserved for CUDA/system overhead?" \
        "Recommended: 1GB. Larger values can prevent OOMs on high-load GPUs." \
        "Reserve (GB) [${_cur_vram_oh}]:" \
        "$_cur_vram_oh" \
        "$_cur_vram_oh")
    case "${_vram_oh_input}" in
        *[!0-9]*)
            printf "%s⚠ Not a number — keeping %s%s\n" "$YELLOW" "$_cur_vram_oh" "$NC"
            ;;
        "")
            printf "%s  VRAM overhead unchanged (%s)%s\n" "$DIM" "$_cur_vram_oh" "$NC"
            ;;
        *)
            write_pref "$SETTINGS_FILE" vram_overhead "$_vram_oh_input"
            echo -e "${ICON_OK} VRAM overhead reserve set to ${GREEN}${_vram_oh_input}GB${NC}."
            ;;
    esac
}

setup_step_cpu_offload() {
    local _cur_offload; _cur_offload=$(read_pref "$SETTINGS_FILE" cpu_offload_pct 90)
    local _offload_input; _offload_input=$(ui_input "CPU offload" \
        "CPU offload threshold — run a bigger model with a few layers on CPU when at least this % of it fits in VRAM?" \
        "Recommended: 90 — worst case is roughly half generation speed. Range
50-99; 0 keeps only models that fit fully on the GPU. Never applies to a
higher quant of the same model, only to a genuinely bigger one." \
        "Threshold in % (0 disables) [${_cur_offload}]:" \
        "$_cur_offload" \
        "$_cur_offload")
    case "${_offload_input}" in
        *[!0-9]*)
            printf "%s⚠ Not a number — keeping %s%s\n" "$YELLOW" "$_cur_offload" "$NC"
            ;;
        "")
            printf "%s  CPU offload threshold unchanged (%s)%s\n" "$DIM" "$_cur_offload" "$NC"
            ;;
        0)
            write_pref "$SETTINGS_FILE" cpu_offload_pct 0
            echo -e "${ICON_OK} CPU offload ${YELLOW}disabled${NC} — only fully GPU-resident models will be selected."
            ;;
        *)
            if [ "$_offload_input" -ge 50 ] && [ "$_offload_input" -le 99 ]; then
                write_pref "$SETTINGS_FILE" cpu_offload_pct "$_offload_input"
                echo -e "${ICON_OK} CPU offload threshold set to ${GREEN}${_offload_input}%${NC}."
            else
                printf "%s⚠ Out of range (50-99, or 0 to disable) — keeping %s%s\n" "$YELLOW" "$_cur_offload" "$NC"
            fi
            ;;
    esac
}

setup_step_mcp_extras() {
    local _cur_extras; _cur_extras=$(read_pref "$SETTINGS_FILE" mcp_extras no)
    local _extras_input; _extras_input=$(ui_yesno "MCP extras" \
        "MCP extras — register the optional MCP servers with each agent?" \
        "Extras: memory, sequential-thinking, conan, context7, brave-search, github, fetch, time.
Every registered server adds tool definitions to the model's context on every
request — small local models get slower and worse at tool selection as the
list grows. Core servers (filesystem, git, shell) are always registered." \
        "Enable MCP extras? [y/N]:" \
        "$_cur_extras" "$_cur_extras")
    case "$_extras_input" in
        yes)
            write_pref "$SETTINGS_FILE" mcp_extras yes
            echo -e "${ICON_OK} MCP extras ${GREEN}enabled${NC} — applied on next launch (no rebuild needed)."
            ;;
        no)
            write_pref "$SETTINGS_FILE" mcp_extras no
            echo -e "${DIM}  MCP extras disabled — only core servers are registered.${NC}"
            ;;
        *)
            printf "%s  MCP extras unchanged (%s)%s\n" "$DIM" "$_cur_extras" "$NC"
            ;;
    esac
}

setup_step_keep_hub() {
    local _cur_keep; _cur_keep=$(read_pref "$SETTINGS_FILE" keep_hub no)
    local _keep_input; _keep_input=$(ui_yesno "Keep hub warm" \
        "Keep hub warm — leave the engine running after the last session exits?" \
        "Skips the model load on your next launch. Uses GPU VRAM while idle;
stop it any time with: ai --clean" \
        "Keep hub warm? [y/N]:" \
        "$_cur_keep" "$_cur_keep")
    case "$_keep_input" in
        yes)
            write_pref "$SETTINGS_FILE" keep_hub yes
            echo -e "${ICON_OK} Hub will ${GREEN}stay warm${NC} after sessions end."
            local _cur_timeout; _cur_timeout=$(read_pref "$SETTINGS_FILE" keep_hub_timeout 60)
            local _timeout_input; _timeout_input=$(ui_input "Idle timeout" \
                "" \
                "" \
                "Auto-stop after how many idle minutes? [${_cur_timeout}] (0 = keep forever):" \
                "" \
                "$_cur_timeout")
            case "$_timeout_input" in
                "")
                    printf "%s  Idle timeout unchanged (%s min)%s\n" "$DIM" "$_cur_timeout" "$NC"
                    ;;
                *[!0-9]*)
                    printf "%s⚠ Not a number — keeping %s min%s\n" "$YELLOW" "$_cur_timeout" "$NC"
                    ;;
                *)
                    write_pref "$SETTINGS_FILE" keep_hub_timeout "$_timeout_input"
                    if [ "$_timeout_input" = "0" ]; then
                        echo -e "${DIM}  Hub will stay warm until stopped with --clean.${NC}"
                    else
                        echo -e "${ICON_OK} Hub auto-stops after ${GREEN}${_timeout_input}${NC} idle minutes."
                    fi
                    ;;
            esac
            ;;
        no)
            write_pref "$SETTINGS_FILE" keep_hub no
            echo -e "${DIM}  Hub will shut down when the last session exits.${NC}"
            ;;
        *)
            printf "%s  Keep-hub setting unchanged (%s)%s\n" "$DIM" "$_cur_keep" "$NC"
            ;;
    esac
}

setup_step_model_volume() {
    local _cur_mvol; _cur_mvol=$(read_pref "$SETTINGS_FILE" model_volume "$MODEL_VOLUME_DEFAULT")
    local _mvol_input; _mvol_input=$(ui_yesno "Fast model storage" \
        "Fast model storage — cache the model in a Docker volume?" \
        "The engine loads the model from the Docker VM's native disk instead of
the much slower Windows filesystem bridge — engine cold starts drop from
minutes to seconds. Costs a one-time copy per model and duplicates the
active model's disk usage inside the Docker VM.
Reclaim the space any time with: docker volume rm ai-coder-models" \
        "Use fast model storage? [y/n, Enter to keep]:" \
        "$_cur_mvol" "$_cur_mvol")
    case "$_mvol_input" in
        yes)
            write_pref "$SETTINGS_FILE" model_volume yes
            echo -e "${ICON_OK} Fast model storage ${GREEN}enabled${NC} — model syncs on next engine start."
            ;;
        no)
            write_pref "$SETTINGS_FILE" model_volume no
            echo -e "${DIM}  Fast model storage disabled — engine mounts the host model folder directly.${NC}"
            echo -e "${DIM}  Reclaim volume space with: docker volume rm ai-coder-models${NC}"
            ;;
        *)
            printf "%s  Fast model storage unchanged (%s)%s\n" "$DIM" "$_cur_mvol" "$NC"
            ;;
    esac
}

setup_step_spec_decode() {
    local _cur_spec; _cur_spec=$(read_pref "$SETTINGS_FILE" spec_decode yes)
    local _spec_input; _spec_input=$(ui_yesno "Speculative decoding" \
        "Speculative decoding — speed up generation with a small draft model?" \
        "A tiny draft model proposes tokens the main model verifies in one pass —
typically 1.5-2x faster code generation. Costs ~1GB extra VRAM.
Applies only to model families that define a draft (currently Qwen3)." \
        "Use speculative decoding? [Y/n]:" \
        "$_cur_spec" "$_cur_spec")
    case "$_spec_input" in
        no)
            write_pref "$SETTINGS_FILE" spec_decode no
            echo -e "${DIM}  Speculative decoding disabled.${NC}"
            ;;
        yes)
            write_pref "$SETTINGS_FILE" spec_decode yes
            echo -e "${ICON_OK} Speculative decoding ${GREEN}enabled${NC} — draft downloads on next launch."
            ;;
        *)
            printf "%s  Speculative decoding unchanged (%s)%s\n" "$DIM" "$_cur_spec" "$NC"
            ;;
    esac
}

setup_step_expose_port() {
    local _cur_expose; _cur_expose=$(read_pref "$SETTINGS_FILE" expose_host_port no)
    local _expose_input; _expose_input=$(ui_yesno "Host port exposure" \
        "Host port exposure — publish the engine on localhost:8080?" \
        "Allows external applications (e.g. Open WebUI) to connect directly.
Leave disabled if you only need the AI coding tools inside Docker." \
        "Expose engine on localhost:8080? [y/N]:" \
        "$_cur_expose" "$_cur_expose")
    case "$_expose_input" in
        yes)
            write_pref "$SETTINGS_FILE" expose_host_port yes
            echo -e "${ICON_OK} Engine will be published on ${CYAN}localhost:8080${NC}."
            echo -e "${DIM}  Next launch will also offer to start Open WebUI alongside your agent.${NC}"
            ;;
        no)
            write_pref "$SETTINGS_FILE" expose_host_port no
            echo -e "${DIM}  Engine port not exposed to host.${NC}"
            ;;
        *)
            printf "%s  Host port exposure unchanged (%s)%s\n" "$DIM" "$_cur_expose" "$NC"
            ;;
    esac
}

setup_step_git_identity() {
    local _cur_git_email; _cur_git_email=$(read_pref "$SETTINGS_FILE" git_email "")
    local _cur_git_name;  _cur_git_name=$(read_pref  "$SETTINGS_FILE" git_name  "")
    [ -z "$_cur_git_email" ] && _cur_git_email=$(git config --global user.email 2>/dev/null || true)
    [ -z "$_cur_git_name" ]  && _cur_git_name=$(git config --global user.name 2>/dev/null || true)

    local _git_email_input; _git_email_input=$(ui_input "Git identity — email" \
        "Git Identity (1/2): Email" \
        "Used for commits inside containers. Leave blank to keep current." \
        "Email:" \
        "$_cur_git_email" \
        "$_cur_git_email")

    local _git_name_input; _git_name_input=$(ui_input "Git identity — name" \
        "Git Identity (2/2): Name" \
        "Used for commits inside containers. Leave blank to keep current." \
        "Name:" \
        "$_cur_git_name" \
        "$_cur_git_name")

    local _final_git_email="${_git_email_input:-$_cur_git_email}"
    local _final_git_name="${_git_name_input:-$_cur_git_name}"
    if [ -n "$_final_git_email" ] || [ -n "$_final_git_name" ]; then
        if [[ "$_final_git_email" != "$_cur_git_email" || "$_final_git_name" != "$_cur_git_name" ]]; then
            touch "$USER_DIR/.rebuild-needed"
            echo -e "${YELLOW}  Note: Git identity changed. A rebuild (ai --rebuild) is required to bake this into the image.${NC}"
        fi
        write_pref "$SETTINGS_FILE" git_email "$_final_git_email"
        write_pref "$SETTINGS_FILE" git_name  "$_final_git_name"
        echo -e "${ICON_OK} Git identity saved."
    else
        echo -e "${DIM}  No git identity set — commits will use container defaults.${NC}"
    fi
}

# ------------------------------------------------------------------------------
# cmd_setup — first-time and re-configuration wizard
# ------------------------------------------------------------------------------
cmd_setup() {
    # Ensure gum is available before initializing the UI
    ensure_gum
    ui_init

    clear
    echo -e "${CYAN}${BOLD}==========================================================${NC}"
    echo -e "${CYAN}${BOLD}                  AI-CODER SETUP WIZARD                   ${NC}"
    echo -e "${CYAN}${BOLD}==========================================================${NC}"
    echo -e "${DIM}Configure your local agent environment and preferences.${NC}"

    setup_step_alias
    setup_step_proxy
    setup_step_network
    setup_step_gpu
    setup_step_ctx
    setup_step_kv
    setup_step_vram_overhead
    setup_step_cpu_offload
    setup_step_mcp_extras
    setup_step_keep_hub
    setup_step_model_volume
    setup_step_spec_decode
    setup_step_expose_port
    setup_step_git_identity

    touch "$USER_DIR/.setup-done"
    echo -e "\n${ICON_OK} Setup complete."
}
