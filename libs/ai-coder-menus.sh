#!/bin/bash
# ==============================================================================
# AI-CODER | Interactive Selection Menus
# ==============================================================================

# ------------------------------------------------------------------------------
# _run_selection_menu — shared numbered-list picker used by both menu functions
# Usage: _run_selection_menu <prompt> <state_file> <pref_key> <current_key> [name:key ...]
# ------------------------------------------------------------------------------
_run_selection_menu() {
    local prompt="$1" state_file="$2" pref_key="$3" current_key="$4"
    shift 4
    local pairs=("$@")
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
