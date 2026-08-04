#!/bin/bash
# ==============================================================================
# AI-CODER | Interactive Selection Menus
# ==============================================================================

# ------------------------------------------------------------------------------
# _menu_ui_init — lazily bootstrap gum for the menus, once per run
#
# Downloads gum if missing (ensure_gum) and resolves UI_GUM/GUM_CMD (ui_init).
# Only called when a menu is actually about to be shown, so normal launches
# with saved preferences never touch gum at all.
# ------------------------------------------------------------------------------
_MENU_UI_READY=""
_menu_ui_init() {
    [ -n "$_MENU_UI_READY" ] && return 0
    ensure_gum
    ui_init
    _MENU_UI_READY=1
}

# ------------------------------------------------------------------------------
# _run_selection_menu — shared list picker used by both menu functions.
# Uses gum choose when available, falling back to a numbered plain-text
# picker with input validation when gum can't be installed or run.
# Usage: _run_selection_menu <prompt> <state_file> <pref_key> <current_key> [name:key ...]
# ------------------------------------------------------------------------------
_run_selection_menu() {
    local prompt="$1" state_file="$2" pref_key="$3" current_key="$4"
    shift 4
    local pairs=("$@")

    _menu_ui_init

    if [ "$UI_GUM" = "true" ]; then
        local names=() current_name=""
        for pair in "${pairs[@]}"; do
            local _key="${pair#*:}" _name="${pair%%:*}"
            names+=("$_name")
            [ "$_key" = "$current_key" ] && current_name="$_name"
        done

        local choice _gum_rc
        choice=$(_gum_choose "$prompt" "" "$current_name" "$current_name" "${names[@]}")
        _gum_rc=$?
        # 126/127 mean the gum binary itself failed to run (not executable /
        # not found) — a real error, not the user cancelling. Anything else
        # with empty output (e.g. Escape) is a normal cancel.
        if [ "$_gum_rc" -eq 126 ] || [ "$_gum_rc" -eq 127 ]; then
            echo -e "${RED}✘ gum failed to run (exit ${_gum_rc}) — try: $(basename "$0") --setup${NC}" >&2
            exit 1
        fi
        if [ -z "$choice" ]; then
            exit 0
        fi

        for pair in "${pairs[@]}"; do
            if [ "${pair%%:*}" = "$choice" ]; then
                write_pref "$state_file" "$pref_key" "${pair#*:}"
                echo -e "${ICON_OK} ${choice} selected."
                return
            fi
        done
        return
    fi

    while true; do
        echo -e "\n${CYAN}${prompt}${NC}"
        local i=1 default_choice=""
        for pair in "${pairs[@]}"; do
            local _key="${pair#*:}" _name="${pair%%:*}"
            if [ "$_key" = "$current_key" ]; then
                echo -e "  $i) ${_name} ${DIM}◀ current${NC}"
                default_choice=$i
            else
                echo "  $i) $_name"
            fi
            (( i++ ))
        done
        echo "  q) Quit"
        [ -n "$default_choice" ] && echo -n "Selection [$default_choice]: " || echo -n "Selection: "
        read -r choice
        [ -z "$choice" ] && choice="${default_choice}"
        if [[ "$choice" == "q" ]]; then exit 0; fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#pairs[@]} )); then
            local key="${pairs[$((choice-1))]#*:}"
            local name="${pairs[$((choice-1))]%%:*}"
            write_pref "$state_file" "$pref_key" "$key"
            echo -e "${ICON_OK} ${name} selected."
            return
        fi
        echo -e "${RED}Invalid selection.${NC}"
    done
}

# ------------------------------------------------------------------------------
# show_family_menu — prompt user to select a model family
# ------------------------------------------------------------------------------
show_family_menu() {
    local current_key="${1:-}"
    local pairs=()
    for f in "$FAMILIES_DIR"/*.conf; do
        [ -f "$f" ] || continue
        local name; name=$(grep -m1 '^MODEL_FAMILY=' "$f" | sed 's/^MODEL_FAMILY=//;s/"//g;s/\${[^:]*:-//;s/}//')
        [ -n "$name" ] || continue
        local key; key=$(basename "$f" .conf)
        pairs+=("$name:$key")
    done
    IFS=$'\n' pairs=($(printf '%s\n' "${pairs[@]}" | sort)); unset IFS
    _run_selection_menu "Please select your preferred model family:" "$STATE_FILE" "family_pref" "$current_key" "${pairs[@]}"
}

# ------------------------------------------------------------------------------
# show_menu — prompt user to select an AI tool (agent)
# ------------------------------------------------------------------------------
show_menu() {
    local current_key="${1:-}"
    local agents_dir
    agents_dir="$(dirname "$(realpath "$0")")/agents"

    local pairs=()
    for f in "$agents_dir"/ai-coder-*.sh; do
        [ -f "$f" ] || continue
        local name; name=$(grep -m1 '^TOOL_NAME=' "$f" | cut -d'"' -f2)
        [ -n "$name" ] || continue
        local key; key=$(basename "$f" .sh); key="${key#ai-coder-}"
        pairs+=("$name:$key")
    done
    IFS=$'\n' pairs=($(printf '%s\n' "${pairs[@]}" | sort)); unset IFS
    _run_selection_menu "Welcome to AI-Coder. Please select your preferred tool:" "$STATE_FILE" "tool_pref" "$current_key" "${pairs[@]}"
}

# ------------------------------------------------------------------------------
# show_webui_prompt — ask whether to start Open WebUI alongside the agent.
# Only offered when the engine port is exposed to the host (see --setup).
# Uses gum when available, falling back to a plain y/n read.
# ------------------------------------------------------------------------------
show_webui_prompt() {
    local prev="${1:-}"
    local def="no" hint="[y/N]"
    if [ "$prev" = "yes" ]; then def="yes"; hint="[Y/n]"; fi

    _menu_ui_init

    local _webui_input
    _webui_input=$(ui_yesno "Open WebUI" \
        "Start Open WebUI alongside your coding agent?" \
        "Chat with the same local model at http://localhost:${OPEN_WEBUI_HOST_PORT} while you code." \
        "Start Open WebUI? $hint:" \
        "" "$def")
    [ -z "$_webui_input" ] && _webui_input="$def"
    case "${_webui_input,,}" in
        y|yes)
            write_pref "$STATE_FILE" webui_pref yes
            echo -e "${ICON_OK} Open WebUI will start with each session."
            ;;
        *)
            write_pref "$STATE_FILE" webui_pref no
            echo -e "${DIM}  Open WebUI will not be started.${NC}"
            ;;
    esac
}
