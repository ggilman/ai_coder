#!/bin/bash
# ==============================================================================
# AI-CODER-COMMANDS.SH | One-Shot CLI Commands
# Non-interactive commands dispatched by the ai-coder case block:
# --fix-project, --update, --version, --doctor, --logs. They print and exit —
# no prompts — so they need no ui.sh helpers, only the palette, pref I/O and
# release-hash helpers already sourced earlier in the chain (core.sh).
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

    # Installing over a git checkout wipes release-owned dirs and overwrites the
    # working tree (including uncommitted work) with the release tarball.
    if _is_git_checkout "$install_dir" && [ "${1:-}" != "--force" ]; then
        echo -e "${RED}✘ ${install_dir} is a git checkout — --update would overwrite your working tree.${NC}"
        echo -e "  Use git instead:  ${CYAN}git fetch origin && git switch release && git pull --ff-only${NC}"
        echo -e "  ${DIM}(or run --update --force to overwrite the checkout from the release tarball)${NC}"
        return 1
    fi

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
    rm -rf "$install_dir/agents" "$install_dir/libs" "$install_dir/packages" "$install_dir/offline" \
           "$install_dir/config/sglang-patches"

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

    # Record the installed release hash (and its checkin date) so future update
    # checks have a baseline to compare and --version has something to show.
    local new_hash; new_hash=$(_fetch_release_hash) || true
    if [ -n "$new_hash" ]; then
        write_pref "$STATE_FILE" release_hash "$new_hash"
        local new_date; new_date=$(_fetch_commit_date "$new_hash") || true
        [ -n "$new_date" ] && write_pref "$STATE_FILE" release_date "$new_date"
    fi

    echo -e "${ICON_OK} Updated successfully${NC}"

    # Reset timestamp so the next run doesn't immediately re-check
    write_pref "$STATE_FILE" last_check "$(date +%s 2>/dev/null || echo 0)"
}

# ------------------------------------------------------------------------------
# cmd_version — print the installed release, its checkin date and, when the
# install dir is a git checkout, the current branch and how far it is ahead of /
# behind the release commit.
#
# Tarball installs take the release hash/date from state recorded by install.sh /
# --update, reaching out to GitHub (short timeout) only if those are missing. Git
# checkouts ignore that recorded state and use the local origin/release ref (kept
# current by fetch/push), asking GitHub only if the ref doesn't exist. It never
# writes state and never runs `git fetch`.
# ------------------------------------------------------------------------------
cmd_version() {
    local install_dir; install_dir="$(dirname "$SCRIPT_DIR")"
    local hash="" release_date="" hash_note=""

    local is_git=false
    _is_git_checkout "$install_dir" && is_git=true

    if [ "$is_git" = true ]; then
        # Checkout: the local origin/release ref is the source of truth. A
        # `git push origin release` from here updates it, so it can't drift the
        # way state.json's release_hash (tarball installs only) does. Fall back
        # to GitHub only if the ref doesn't exist (e.g. never fetched).
        hash=$(_git_at "$install_dir" rev-parse --verify --quiet refs/remotes/origin/release 2>/dev/null) || hash=""
        if [ -n "$hash" ]; then
            hash_note="origin/release, as of last fetch/push"
        else
            hash=$(_fetch_release_hash) || true
        fi
        if [ -n "$hash" ] && _git_at "$install_dir" cat-file -e "${hash}^{commit}" 2>/dev/null; then
            release_date=$(_git_at "$install_dir" log -1 --format=%aI "$hash" 2>/dev/null) || release_date=""
        fi
        [ -n "$hash" ] && [ -z "$release_date" ] && { release_date=$(_fetch_commit_date "$hash") || true; }
    else
        # Tarball install: hash/date recorded by install.sh / --update; ask
        # GitHub only for whatever is missing.
        hash=$(read_pref "$STATE_FILE" release_hash "")
        release_date=$(read_pref "$STATE_FILE" release_date "")
        [ -z "$hash" ] && { hash=$(_fetch_release_hash) || true; }
        [ -n "$hash" ] && [ -z "$release_date" ] && { release_date=$(_fetch_commit_date "$hash") || true; }
    fi

    echo -e "${BOLD}ai-coder${NC}"
    echo -e "  Installed at:  ${CYAN}${install_dir}${NC}"
    if [ "$is_git" = true ]; then
        echo -e "  Installation:  ${DIM}local git repo${NC}"
    else
        echo -e "  Installation:  ${DIM}installed version${NC}"
    fi
    if [ -n "$hash" ]; then
        echo -e "  Release:       ${CYAN}${hash:0:10}${NC} (${DIM}${hash}${NC})${hash_note:+ ${DIM}[${hash_note}]${NC}}"
        if [ -n "$release_date" ]; then
            local checkin; checkin=$(date -u -d "$release_date" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "$release_date")
            echo -e "  Checked in:    ${DIM}${checkin}${NC}"
        fi
    else
        echo -e "  Release:       ${DIM}unknown — GitHub unreachable; run --update once online to record it${NC}"
    fi

    if [ "$is_git" = true ]; then
        local branch head_short
        branch=$(_git_at "$install_dir" symbolic-ref --short --quiet HEAD 2>/dev/null) || branch=""
        head_short=$(_git_at "$install_dir" rev-parse --short HEAD 2>/dev/null) || head_short="?"
        if [ -n "$branch" ]; then
            echo -e "  Branch:        ${CYAN}${branch}${NC} (${DIM}${head_short}${NC})"
        else
            echo -e "  Branch:        ${DIM}detached HEAD at ${head_short}${NC}"
        fi

        if [ -n "$hash" ]; then
            local counts=""
            if _git_at "$install_dir" cat-file -e "${hash}^{commit}" 2>/dev/null; then
                counts=$(_git_at "$install_dir" rev-list --left-right --count "HEAD...${hash}" 2>/dev/null) || counts=""
            fi
            if [ -n "$counts" ]; then
                local ahead behind
                read -r ahead behind <<< "$counts"
                if [ "$ahead" -eq 0 ] && [ "$behind" -eq 0 ]; then
                    echo -e "  vs. release:   ${DIM}at the release commit${NC}"
                else
                    echo -e "  vs. release:   ${DIM}${ahead} ahead, ${behind} behind${NC}"
                fi
            else
                echo -e "  vs. release:   ${DIM}release commit not in local repo (git fetch origin release, then retry)${NC}"
            fi
        fi
        if [ -n "$(_git_at "$install_dir" status --porcelain 2>/dev/null)" ]; then
            echo -e "  Working tree:  ${DIM}uncommitted changes${NC}"
        fi
    fi
    if [ "$is_git" = true ]; then
        # --update overwrites release-owned files from a tarball, which would
        # clobber a checkout's working tree � use git to move to the release.
        echo -e "  ${DIM}This is a git checkout, so don't use --update. To get on the latest release:${NC}"
        if [ "${branch:-}" = "release" ]; then
            echo -e "    ${CYAN}git pull --ff-only origin release${NC}"
        else
            echo -e "    ${CYAN}git fetch origin${NC}"
            echo -e "    ${CYAN}git switch release && git pull --ff-only${NC}"
        fi
        echo -e "  ${DIM}(commit or stash local changes first)${NC}"
    else
        echo -e "  ${DIM}Run \"$(basename "$0") --update\" to check for and install the latest release.${NC}"
    fi
}

# ------------------------------------------------------------------------------
# cmd_doctor — sweep orphaned state left behind by killed sessions, and flag a
# couple of easy-to-miss misconfigurations. Safe to run any time; each check
# is best-effort and independent of the others.
# ------------------------------------------------------------------------------
cmd_doctor() {
    echo -e "${BOLD}ai-coder doctor${NC}"
    local issues=0

    # --- orphaned write_pref temp files ---------------------------------------
    # write_pref self-heals these on its own next call (see libs/ai-coder-env.sh),
    # but a file that's rarely written (e.g. settings.json) could sit on one for
    # a long time otherwise — sweep the whole user/ dir explicitly here too.
    echo -e "${ICON_GEAR} Orphaned temp files in ${CYAN}${USER_DIR}${NC}..."
    local _tmp_found=() _f
    while IFS= read -r _f; do
        [ -n "$_f" ] && _tmp_found+=("$_f")
    done < <(find "$USER_DIR" -maxdepth 1 -name "*.tmp.*" -mmin +5 2>/dev/null)
    if [ "${#_tmp_found[@]}" -gt 0 ]; then
        for _f in "${_tmp_found[@]}"; do
            rm -f "$_f" && echo -e "  ${GREEN}✔${NC} removed ${DIM}$(basename "$_f")${NC}"
        done
        issues=$((issues + ${#_tmp_found[@]}))
    else
        echo -e "  ${DIM}none found${NC}"
    fi

    # --- orphaned lock directories --------------------------------------------
    # acquire_lock's mkdir-based locks are only ever held for the duration of a
    # single preference write or the Hub check-then-restart section — a couple
    # of seconds at most. One older than 2 minutes belonged to a session that
    # died while holding it (crash, kill -9) rather than one still in progress.
    echo -e "${ICON_GEAR} Orphaned lock directories..."
    local _lock_found=() _d
    while IFS= read -r _d; do
        [ -n "$_d" ] && _lock_found+=("$_d")
    done < <(find "$USER_DIR" -maxdepth 1 -name "*.lock" -type d -mmin +2 2>/dev/null)
    if [ "${#_lock_found[@]}" -gt 0 ]; then
        for _d in "${_lock_found[@]}"; do
            rmdir "$_d" 2>/dev/null && echo -e "  ${GREEN}✔${NC} removed ${DIM}$(basename "$_d")${NC}"
        done
        issues=$((issues + ${#_lock_found[@]}))
    else
        echo -e "  ${DIM}none found${NC}"
    fi

    # --- secrets file permissions ---------------------------------------------
    # AI_CODER_ENV_FILE (sourced by ai-coder for API keys like BRAVE_API_KEY)
    # is plain text — worth flagging if group/other can read it. Meaningful on
    # WSL/Linux; Git Bash reports NTFS ACLs approximately, so this is best-effort.
    local _env_file="${AI_CODER_ENV_FILE:-$WIN_HOME/.ai-coder-env}"
    echo -e "${ICON_GEAR} Secrets file permissions..."
    if [ -f "$_env_file" ]; then
        local _mode; _mode=$(stat -c%a "$_env_file" 2>/dev/null || echo "")
        if [ -n "$_mode" ] && [ $(( 0${_mode} & 0044 )) -ne 0 ]; then
            echo -e "  ${YELLOW}⚠${NC} ${_env_file} is readable by group/other (mode ${_mode})"
            echo -e "    ${DIM}Fix with: chmod 600 \"${_env_file}\"${NC}"
            issues=$((issues + 1))
        else
            echo -e "  ${DIM}${_env_file}: OK${NC}"
        fi
    else
        echo -e "  ${DIM}not present — nothing to check${NC}"
    fi

    # --- leftover workbench containers ----------------------------------------
    # Doesn't call check_docker (which would launch Docker Desktop just to run
    # a health check) — skips this section instead when Docker isn't already up.
    echo -e "${ICON_GEAR} Docker state..."
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        local _stopped; _stopped=$(docker ps -aq --filter "status=exited" --filter "name=^/${WORKBENCH_PREFIX}-" 2>/dev/null)
        if [ -n "$_stopped" ]; then
            local _count; _count=$(echo "$_stopped" | grep -c .)
            echo -e "  ${YELLOW}⚠${NC} ${_count} stopped workbench container(s) left over"
            echo -e "    ${DIM}Remove with: $(basename "$0") --clean${NC}"
            issues=$((issues + 1))
        else
            echo -e "  ${DIM}no leftover workbench containers${NC}"
        fi
    else
        echo -e "  ${DIM}Docker not running — skipped${NC}"
    fi

    # --- legacy flat config files (pre-JSON) ------------------------------------
    # user/settings.conf and user/state.conf are the pre-JSON formats. They're
    # no longer read at runtime (user/settings.json / user/state.json are the
    # source of truth now), so they're safe to delete. Flag them so an old-format
    # user knows the .conf is dead weight.
    echo -e "${ICON_GEAR} Legacy flat config files..."
    local _legacy_any=0
    for _legacy in "$USER_DIR/settings.conf" "$USER_DIR/state.conf"; do
        if [ -f "$_legacy" ]; then
            echo -e "  ${YELLOW}⚠${NC} ${DIM}$(basename "$_legacy")${NC} is legacy (pre-JSON) — no longer read, safe to delete"
            issues=$((issues + 1))
            _legacy_any=1
        fi
    done
    [ "$_legacy_any" -eq 0 ] && echo -e "  ${DIM}none found${NC}"

    # --- inference engine vs. saved model family --------------------------------
    # Under SGLang, only families with a MODEL_SGL_* list can run; a family
    # saved back when llama.cpp was the engine would fail at next launch.
    echo -e "${ICON_GEAR} Inference engine: ${CYAN}$(engine_display_name)${NC}"
    if engine_is_sglang; then
        local _fam; _fam=$(read_pref "$STATE_FILE" family_pref "")
        if [ -n "$_fam" ] && [ -f "$ROOT_DIR/config/families/${_fam}.conf" ] && \
           ! family_conf_supports_sglang "$ROOT_DIR/config/families/${_fam}.conf"; then
            echo -e "  ${YELLOW}⚠${NC} saved model family ${DIM}${_fam}${NC} has no SGLang models"
            echo -e "    ${DIM}Pick another with: $(basename "$0") --model${NC}"
            issues=$((issues + 1))
        else
            echo -e "  ${DIM}saved model family is compatible${NC}"
        fi
    fi

    # --- corrupt user JSON config ---------------------------------------------
    # A user/*.json that isn't valid JSON degrades to defaults at read time,
    # but is worth surfacing so it can be fixed (hand-truncated / mid-write).
    # Only checked when a jq is resolvable.
    local _jq=""
    resolve_jq_cmd &>/dev/null && _jq="$JQ_CMD"
    if [ -n "$_jq" ]; then
        for _j in "$SETTINGS_FILE" "$STATE_FILE"; do
            if [ -f "$_j" ] && ! "$_jq" empty "$_j" >/dev/null 2>&1; then
                echo -e "  ${YELLOW}⚠${NC} ${DIM}$(basename "$_j")${NC} is not valid JSON — its values read as defaults until fixed"
                issues=$((issues + 1))
            fi
        done
    fi

    echo ""
    if [ "$issues" -eq 0 ]; then
        echo -e "${ICON_OK} Nothing to clean up."
    else
        echo -e "${ICON_OK} Cleaned up / flagged ${issues} issue(s)."
    fi
}

# ------------------------------------------------------------------------------
# cmd_logs — show Docker logs for the hub containers
# Usage: --logs [--follow|-f] [--tail N] [--proxy] [--webui]
# ------------------------------------------------------------------------------
cmd_logs() {
    local follow=false tail=50
    local show_proxy=false show_webui=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --follow|-f)
                follow=true
                shift
                ;;
            --tail)
                tail="${2:-50}"
                shift
                if [ $# -gt 0 ]; then shift; fi
                ;;
            --proxy)
                show_proxy=true
                shift
                ;;
            --webui)
                show_webui=true
                shift
                ;;
            *)
                echo -e "${RED}Unknown --logs option: $1${NC}"
                return 1
                ;;
        esac
    done
    case "$tail" in
        ''|*[!0-9]*)
            tail=50
            ;;
    esac

    check_docker || exit 1

    if [ -z "$(docker ps -aq -f "name=$GLOBAL_ENGINE_NAME" 2>/dev/null)" ]; then
        echo -e "${RED}✘ Engine not started${NC}"
        echo -e "${YELLOW}  Launch a session first, then run: ${CYAN}$(basename "$0") --logs${NC}"
        return 1
    fi

    local containers=("$GLOBAL_ENGINE_NAME")
    if [ "$show_proxy" = "true" ] && [ -n "$(docker ps -aq -f "name=$GLOBAL_PROXY_NAME" 2>/dev/null)" ]; then
        containers+=("$GLOBAL_PROXY_NAME")
    fi
    if [ "$show_webui" = "true" ] && [ -n "$(docker ps -aq -f "name=$GLOBAL_WEBUI_NAME" 2>/dev/null)" ]; then
        containers+=("$GLOBAL_WEBUI_NAME")
    fi

    if [ "$follow" = "true" ]; then
        docker logs -f "${containers[@]}"
    else
        docker logs --tail "$tail" "${containers[@]}"
    fi
}
