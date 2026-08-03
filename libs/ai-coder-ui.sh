#!/bin/bash
# ==============================================================================
# AI-CODER-UI.SH | Setup Wizard UI Helpers
# whiptail dialogs when available (Ubuntu/WSL), plain read prompts otherwise
# (Git Bash ships no whiptail). Helpers render the question and echo the raw
# answer on stdout; all screen output goes to stderr so command substitution
# captures only the answer. Interpretation of the answer (validation,
# write_pref, outcome messages) stays with the caller. Every helper returns 0
# so callers are safe under `set -euo pipefail`.
# ==============================================================================

UI_WHIPTAIL=false
UI_BACKTITLE="ai-coder setup"

# Decide whether whiptail dialogs can be used for this run.
# AI_CODER_NO_WHIPTAIL=1 forces the plain-read fallback (for testing).
ui_init() {
    UI_WHIPTAIL=false
    [ "${AI_CODER_NO_WHIPTAIL:-0}" = "1" ] && return 0
    command -v whiptail >/dev/null 2>&1 || return 0
    { [ -t 0 ] && [ -t 1 ]; } || return 0
    UI_WHIPTAIL=true
    return 0
}

# Dialog height for a text block: wrapped line count + frame/button rows.
# $1 = dialog text, $2 = extra rows (input field, menu list, ...)
_ui_height() {
    local _lines
    _lines=$(printf '%s\n' "$1" | fold -s -w 66 | wc -l)
    echo $(( _lines + ${2:-0} + 7 ))
    return 0
}

# Compose the whiptail dialog body: question + help + current-value footer.
# $1 = header (full question line), $2 = help text, $3 = current label ("" = omit)
_ui_text() {
    local _text="$1"
    if [ -n "$2" ]; then
        [ -n "$_text" ] && _text="${_text}"$'\n\n'
        _text="${_text}$2"
    fi
    if [ -n "$3" ]; then
        [ -n "$_text" ] && _text="${_text}"$'\n\n'
        _text="${_text}Current: $3 — ESC keeps current."
    fi
    printf '%s' "$_text"
    return 0
}

# Classic plain-mode question block, written to stderr.
# $1 = header, $2 = help text, $3 = current label ("" = omit), $4 = prompt
_ui_plain_header() {
    local _line
    [ -n "$1" ] && echo -e "\n${CYAN}$1${NC}" >&2
    if [ -n "$2" ]; then
        while IFS= read -r _line; do
            echo -e "${DIM}  ${_line}${NC}" >&2
        done <<< "$2"
    fi
    [ -n "$3" ] && echo -e "${DIM}  Current: $3${NC}" >&2
    echo -n "  $4 " >&2
    return 0
}

# ui_yesno TITLE HEADER HELP PROMPT CURRENT DEFAULT(yes|no)
# stdout: "yes" | "no" | "" (keep current) | raw input (plain mode, caught by
# the caller's *) arm exactly like the pre-whiptail wizard).
# Whiptail: the focused button follows DEFAULT so bare Enter re-selects the
# current value; ESC keeps current.
ui_yesno() {
    local _title="$1" _header="$2" _help="$3" _prompt="$4" _current="$5" _default="$6"
    local _input _rc=0 _text
    if [ "$UI_WHIPTAIL" = "true" ]; then
        _text=$(_ui_text "$_header" "$_help" "$_current")
        local _args=(--backtitle "$UI_BACKTITLE" --title "$_title")
        [ "$_default" = "no" ] && _args+=(--defaultno)
        whiptail "${_args[@]}" --yesno "$_text" "$(_ui_height "$_text")" 72 1>&2 || _rc=$?
        case "$_rc" in
            0) echo "yes" ;;
            1) echo "no" ;;
            *) echo "" ;;
        esac
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

# ui_input TITLE HEADER HELP PROMPT CURRENT PREFILL
# stdout: entered text; "" = keep current (blank entry, ESC or Cancel).
# Whiptail: the box is prefilled with the current value, so OK without edits
# is an idempotent re-write of the current value.
ui_input() {
    local _title="$1" _header="$2" _help="$3" _prompt="$4" _current="$5" _prefill="$6"
    local _input _rc=0 _text
    if [ "$UI_WHIPTAIL" = "true" ]; then
        _text=$(_ui_text "$_header" "$_help" "$_current")
        [ -n "$_text" ] && _text="${_text}"$'\n\n'
        _text="${_text}${_prompt}"
        _input=$(whiptail --backtitle "$UI_BACKTITLE" --title "$_title" \
            --inputbox "$_text" "$(_ui_height "$_text" 2)" 72 "$_prefill" \
            3>&1 1>&2 2>&3) || _rc=$?
        if [ "$_rc" -eq 0 ]; then echo "$_input"; else echo ""; fi
    else
        _ui_plain_header "$_header" "$_help" "$_current" "$_prompt"
        read -r _input || _input=""
        echo "$_input"
    fi
    return 0
}

# ui_menu TITLE HEADER HELP PROMPT CURRENT TAG1 DESC1 [TAG2 DESC2 ...]
# stdout: chosen tag; "" = keep current (ESC or Cancel).
# Plain mode echoes the raw typed value — invalid entries fall through to the
# caller's existing "unknown value" arm, same as the pre-whiptail wizard.
ui_menu() {
    local _title="$1" _header="$2" _help="$3" _prompt="$4" _current="$5"
    shift 5
    local _input _rc=0 _text _count
    _count=$(( $# / 2 ))
    if [ "$UI_WHIPTAIL" = "true" ]; then
        _text=$(_ui_text "$_header" "$_help" "$_current")
        _input=$(whiptail --backtitle "$UI_BACKTITLE" --title "$_title" \
            --default-item "$_current" \
            --menu "$_text" "$(_ui_height "$_text" "$_count")" 72 "$_count" "$@" \
            3>&1 1>&2 2>&3) || _rc=$?
        if [ "$_rc" -eq 0 ]; then echo "$_input"; else echo ""; fi
    else
        _ui_plain_header "$_header" "$_help" "$_current" "$_prompt"
        read -r _input || _input=""
        echo "$_input"
    fi
    return 0
}
