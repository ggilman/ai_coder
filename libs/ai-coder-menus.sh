#!/bin/bash
# ==============================================================================
# AI-CODER | Interactive Selection Menus
# ==============================================================================

# ------------------------------------------------------------------------------
# show_family_menu — prompt user to select a model family
# ------------------------------------------------------------------------------
show_family_menu() {
    local pairs=()
    for f in "$FAMILIES_DIR"/*.conf; do
        [ -f "$f" ] || continue
        local name; name=$(grep -m1 '^MODEL_FAMILY=' "$f" | sed 's/^MODEL_FAMILY=//;s/"//g;s/\${[^:]*:-//;s/}//')
        [ -n "$name" ] || continue
        local key; key=$(basename "$f" .conf)
        pairs+=("$name:$key")
    done
    IFS=$'\n' pairs=($(printf '%s\n' "${pairs[@]}" | sort)); unset IFS

    while true; do
        echo -e "\n${CYAN}Please select your preferred model family:${NC}"
        local i=1
        for pair in "${pairs[@]}"; do
            echo "  $i) ${pair%%:*}"
            (( i++ ))
        done
        echo "  q) Quit"
        echo -n "Selection: "
        read -r choice
        if [[ "$choice" == "q" ]]; then exit 0; fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#pairs[@]} )); then
            local key="${pairs[$((choice-1))]#*:}"
            local name="${pairs[$((choice-1))]%%:*}"
            echo "$key" > "$FAMILY_PREF_FILE"
            echo -e "${ICON_OK} ${name} selected."
            return
        fi
        echo -e "${RED}Invalid selection.${NC}"
    done
}

# ------------------------------------------------------------------------------
# show_menu — prompt user to select an AI tool (agent)
# ------------------------------------------------------------------------------
show_menu() {
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

    while true; do
        echo -e "\n${CYAN}Welcome to AI-Coder. Please select your preferred tool:${NC}"
        local i=1
        for pair in "${pairs[@]}"; do
            echo "$i) ${pair%%:*}"
            (( i++ ))
        done
        echo "q) Quit"
        echo -n "Selection: "
        read -r choice
        if [[ "$choice" == "q" ]]; then exit 0; fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#pairs[@]} )); then
            local key="${pairs[$((choice-1))]#*:}"
            local name="${pairs[$((choice-1))]%%:*}"
            echo "$key" > "$PREF_FILE"
            echo "$name selected."
            return
        fi
        echo -e "${RED}Invalid selection.${NC}"
    done
}
