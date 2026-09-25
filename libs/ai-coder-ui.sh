#!/bin/bash
# ==============================================================================
# AI-CODER-UI.SH | Setup Wizard UI Helpers
# Gum-based dialogs with plain-read fallback. Gum works on WSL and Git Bash;
# the fallback is used only when gum cannot be installed or run. Helpers render
# the question and echo the raw answer on stdout; all screen output goes to
# stderr so command substitution captures only the answer. Interpretation of
# the answer (validation, write_pref, outcome messages) stays with the caller.
# Every helper returns 0 so callers are safe under `set -euo pipefail`.
# ==============================================================================

# Gum binary resolution (resolve_gum_cmd) lives in ai-coder-gum.sh — sourced
# here (not via ai-coder-setup.sh) so this file stays self-contained for
# standalone sourcing (offline/unbundle.sh).
source "$(dirname "${BASH_SOURCE[0]}")/ai-coder-gum.sh"

UI_GUM=false
# GUM_CMD — resolved gum binary path, set by resolve_gum_cmd in ui_init
GUM_CMD=""
# Set to "true" by the ui_* helpers when the user cancels a prompt (gum
# Escape / Ctrl-C, or a plain-read EOF).  Wizards check this via
# _ui_abort_if_cancelled to stop the remaining steps without overwriting
# saved state.  Never read before the first ui_* call.
UI_ABORTED=false

# Exit the process if the user cancelled a prompt.  Called by wizards
# (cmd_setup, --model flow) after each question to stop without touching
# saved state.  Does nothing if the user has not cancelled yet.
_ui_abort_if_cancelled() {
    if [ "$UI_ABORTED" = "true" ]; then
        echo -e "\n${DIM}  Interrupted — no further questions; previously saved settings kept.${NC}"
        exit 0
    fi
}

# Beautiful CLI Theme Colors (256-color compatible)
COLOR_ACCENT='\033[38;5;81m'     # Cyan
COLOR_DIM='\033[38;5;244m'       # Grey
COLOR_HIGHLIGHT='\033[38;5;118m' # Green
COLOR_BOLD='\033[1m'
COLOR_RESET='\033[0m'

ui_init() {
    UI_GUM=false
    [ "${AI_CODER_NO_GUM:-0}" = "1" ] && return 0
    if ! resolve_gum_cmd; then return 0; fi
    if ! "$GUM_CMD" version-check 0.17.0 >/dev/null 2>&1; then return 0; fi
    UI_GUM=true
    return 0
}

# ==============================================================================
# UI RENDERERS
# ==============================================================================

# Renders the formatted text above interactive Gum prompts
_render_gum_prompt() {
    local _header="$1" _help="$2" _current="$3"
    
    # Add a subtle visual divider before the new step begins
    echo -e "\n${COLOR_DIM}──────────────────────────────────────────────────────────${COLOR_RESET}" >&2
    echo -e "${COLOR_ACCENT}${COLOR_BOLD}${_header}${COLOR_RESET}" >&2
    
    if [ -n "$_help" ]; then
        echo -e "${COLOR_DIM}${_help}${COLOR_RESET}" >&2
    fi
    
    if [ -n "$_current" ]; then
        echo -e "${COLOR_DIM}Current:${COLOR_RESET} ${COLOR_HIGHLIGHT}${_current}${COLOR_RESET}" >&2
    fi
    echo "" >&2 # Blank line spacing before the interactive element
}

# ==============================================================================
# PLAIN-READ FALLBACK
# ==============================================================================

# Renders the same header/help/current block as _render_gum_prompt, then prints
# the prompt text with no trailing newline so a plain `read` lands on the same
# line. All output goes to stderr — callers capture only the answer.
_ui_plain_header() {
    local _header="$1" _help="$2" _current="$3" _prompt="$4"

    echo -e "\n${COLOR_ACCENT}${COLOR_BOLD}${_header}${COLOR_RESET}" >&2

    if [ -n "$_help" ]; then
        echo -e "${COLOR_DIM}${_help}${COLOR_RESET}" >&2
    fi

    if [ -n "$_current" ]; then
        echo -e "${COLOR_DIM}Current:${COLOR_RESET} ${COLOR_HIGHLIGHT}${_current}${COLOR_RESET}" >&2
    fi

    echo -n "${_prompt} " >&2
}

# ==============================================================================
# GUM ABSTRACTIONS (THEMED)
# ==============================================================================

_gum_confirm() {
    local _header="$1" _help="$2" _current="$3" _default="$4"
    _render_gum_prompt "$_header" "$_help" "$_current"
    
    local _def_val="true"
    if [[ "${_default,,}" == "no" || "${_default,,}" == "n" ]]; then
        _def_val="false"
    fi
    
    # Ghost button style with explicitly cleared backgrounds to kill the default pink
    "$GUM_CMD" confirm " " --default="${_def_val}" \
        --selected.foreground="81" --selected.background="" \
        --selected.padding="0 2" --selected.margin="0 1" \
        --selected.border="rounded" --selected.border-foreground="81" \
        --unselected.foreground="250" --unselected.background="" \
        --unselected.padding="0 2" --unselected.margin="0 1" \
        --unselected.border="rounded" --unselected.border-foreground="236"
}

_gum_input() {
    local _header="$1" _help="$2" _current="$3" _prefill="$4" _prompt="$5"
    _render_gum_prompt "$_header" "$_help" "$_current"
    
    local _p_text=" ❯ "
    [ -n "$_prompt" ] && _p_text=" ${_prompt} "
    
    "$GUM_CMD" input --value="${_prefill}" \
        --prompt="${_p_text}" --prompt.foreground="81" \
        --cursor.foreground="81" --width=60
}

_gum_choose() {
    local _header="$1" _help="$2" _current="$3" _selected="$4"
    shift 4
    _render_gum_prompt "$_header" "$_help" "$_current"
    
    # Cap the rendered list height so long menus stay compact
    "$GUM_CMD" choose --selected="${_selected}" \
        --cursor=" ❯ " --cursor.foreground="81" \
        --item.foreground="250" --selected.foreground="81" \
        --height=10 \
        -- "$@"
}

# ==============================================================================
# EXPORTED UI FUNCTIONS
# ==============================================================================

ui_yesno() {
    local _title="$1" _header="$2" _help="$3" _prompt="$4" _current="$5" _default="$6"
    local _input

    if [ "$UI_GUM" = "true" ]; then
        local _gum_rc
        _gum_confirm "$_header" "$_help" "$_current" "$_default"
        _gum_rc=$?
        # 126/127 mean the gum binary itself failed to run (not executable /
        # not found) — surface it rather than silently recording "no", which
        # would get written to settings.json as if the user had declined.
        if [ "$_gum_rc" -eq 126 ] || [ "$_gum_rc" -eq 127 ]; then
            echo "gum failed to run (exit ${_gum_rc})" >&2
            echo "no"
        elif [ "$_gum_rc" -eq 0 ]; then
            echo "yes"
        else
            UI_ABORTED=true
            echo "no"
        fi
    else
        _ui_plain_header "$_header" "$_help" "$_current" "$_prompt"
        read -r _input || _input=""
        case "${_input,,}" in
            y|yes) echo "yes" ;;
            n|no)  echo "no" ;;
            *)    UI_ABORTED=true; echo "$_input" ;;
        esac
    fi
    return 0
}

ui_input() {
    local _title="$1" _header="$2" _help="$3" _prompt="$4" _current="$5" _prefill="$6"
    local _input

    if [ "$UI_GUM" = "true" ]; then
        _input=$(_gum_input "$_header" "$_help" "$_current" "$_prefill" "$_prompt")
        [ -z "$_input" ] && UI_ABORTED=true
        echo "$_input"
    else
        _ui_plain_header "$_header" "$_help" "$_current" "$_prompt"
        read -r _input || _input=""
        [ -z "$_input" ] && UI_ABORTED=true
        echo "$_input"
    fi
    return 0
}

ui_menu() {
    local _title="$1" _header="$2" _help="$3" _prompt="$4" _current="$5"
    shift 5

    _current=$(echo "$_current" | tr -d '\n\r')
    [ -z "$_current" ] && _current=""

    local _input
    
    if [ "$UI_GUM" = "true" ]; then
        local _items=()
        while [ $# -gt 0 ]; do
            _items+=("$1")
            shift 2
        done

        if [ ${#_items[@]} -eq 0 ]; then
            _input=""
        else
            local _found=false
            for _item in "${_items[@]}"; do
                if [ "$_item" = "$_current" ]; then
                    _found=true
                    break
                fi
            done

            if [ "$_found" = false ] && [ -n "$_current" ]; then
                _current=""
            fi

            _input=$(_gum_choose "$_header" "$_help" "$_current" "$_current" "${_items[@]}")
        fi
        [ -z "$_input" ] && UI_ABORTED=true
        echo "$_input"
    else
        echo -e "\n${COLOR_ACCENT}${COLOR_BOLD}${_header}${COLOR_RESET}" >&2
        [ -n "$_help" ] && echo -e "${COLOR_DIM}${_help}${COLOR_RESET}" >&2
        [ -n "$_current" ] && echo -e "${COLOR_DIM}Current:${COLOR_RESET} ${COLOR_HIGHLIGHT}${_current}${COLOR_RESET}" >&2
        while [ $# -gt 0 ]; do
            if [ -n "${2:-}" ]; then
                echo -e "  ${1} ${COLOR_DIM}- ${2}${COLOR_RESET}" >&2
            else
                echo "  ${1}" >&2
            fi
            shift 2
        done
        echo -n "${_prompt} " >&2
        read -r _input || _input=""
        [ -z "$_input" ] && UI_ABORTED=true
        echo "$_input"
    fi
    return 0
}