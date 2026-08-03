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

UI_GUM=false
GUM_CMD=""
UI_BACKTITLE="ai-coder setup"

# Beautiful CLI Theme Colors (256-color compatible)
COLOR_ACCENT='\033[38;5;81m'     # Cyan
COLOR_DIM='\033[38;5;244m'       # Grey
COLOR_HIGHLIGHT='\033[38;5;118m' # Green
COLOR_BOLD='\033[1m'
COLOR_RESET='\033[0m'

# Ensure gum is available; resolve GUM_CMD to the active binary.
_ensure_gum() {
    if command -v gum >/dev/null 2>&1; then
        GUM_CMD="gum"
        return 0
    fi

    local gum_exe_name="gum"
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
        gum_exe_name="gum.exe"
    fi

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local gum_path="$script_dir/../.assets/$gum_exe_name"

    if [[ -f "$gum_path" ]]; then
        GUM_CMD="$gum_path"
        export GUM_CMD
        return 0
    fi

    return 1
}

ui_init() {
    UI_GUM=false
    [ "${AI_CODER_NO_GUM:-0}" = "1" ] && return 0
    if ! _ensure_gum; then return 0; fi
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
    # Added $_prompt as the 5th argument
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
    
    # Added --height to keep the menu compact
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
        _gum_confirm "$_header" "$_help" "$_current" "$_default"
        if [ $? -eq 0 ]; then echo "yes"; else echo "no"; fi
    else
        _ui_plain_header "$_header" "$_help" "$_current" "$_prompt"
        read -r _input || _input=""
        case "${_input,,}" in
            y|yes) echo "yes" ;;
            n|no)  echo "no" ;;
            *)     echo "$_input" ;;
        esac
    fi
    return 0
}

ui_input() {
    local _title="$1" _header="$2" _help="$3" _prompt="$4" _current="$5" _prefill="$6"
    local _input
    
    if [ "$UI_GUM" = "true" ]; then
        # Passed $_prompt into _gum_input
        _input=$(_gum_input "$_header" "$_help" "$_current" "$_prefill" "$_prompt")
        echo "$_input"
    else
        _ui_plain_header "$_header" "$_help" "$_current" "$_prompt"
        read -r _input || _input=""
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
        echo "$_input"
    else
        _ui_plain_header "$_header" "$_help" "$_current" "$_prompt"
        read -r _input || _input=""
        echo "$_input"
    fi
    return 0
}