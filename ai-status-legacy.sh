#!/bin/bash
# ==============================================================================
# AI-STATUS.SH v1.0 | GPU & Engine Dashboard
# Monitors GPU utilization, VRAM, and AI Hub engine health.
# Usage: ./ai-status.sh
# ==============================================================================
set -euo pipefail

# --- [ GRAPHICS ] -------------------------------------------------------------
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
source "$SCRIPT_DIR/libs/ai-coder-graphics.sh"
# Platform/SMI detection, engine-probe constants, get_gpu_stats,
# render_progress_bar, get_network_isolation_status — shared with ai-status.sh.
source "$SCRIPT_DIR/libs/ai-coder-status-common.sh"

# --- [ CONFIGURATION ] --------------------------------------------------------
# UPDATE_INTERVAL/HEALTH_TIMEOUT/ENGINE_NAME, IS_GITBASH/SMI, and the engine
# temp-file paths come from ai-coder-status-common.sh (sourced above).
readonly BAR_WIDTH=35
readonly SEPARATOR_LINE=$(printf '═%.0s' {1..70})

# --- [ UTILITY FUNCTIONS ] ---------------------------------------------------

# Returns the string's rendered terminal width (not its character count).
# Strips ANSI codes and invisible variation selectors (U+FE0F), then counts
# characters with wc -m — which counts each emoji as ONE character, same as
# any other codepoint. Real terminals (WSL's, Windows Terminal, VS Code, ...)
# render the pictographic icons used in this dashboard as TWO columns wide,
# so wc -m undercounts by one column per icon and every right border printed
# after it lands one (or more) columns too far right.
#
# Git Bash's mintty is the exception — it renders the same icons single-width,
# so wc -m already matches there and no correction is applied. This is the
# same mintty-vs-real-terminal gap the E_PAD hack in ai-status.sh compensates
# for in the gum dashboard (see the comment at its definition); IS_GITBASH
# comes from ai-coder-status-common.sh (sourced above).
get_visible_length() {
    local str="$1"
    local stripped
    stripped=$(echo -ne "$str" | sed 's/\x1b\[[0-9;]*m//g' | sed 's/\xef\xb8\x8f//g')
    local len; len=$(printf '%s' "$stripped" | wc -m | xargs)
    if [ "$IS_GITBASH" != "true" ]; then
        local wide
        wide=$(printf '%s' "$stripped" | grep -o '🎮\|💾\|📊\|🌡\|⚡\|🚀\|🤖\|🌐' | wc -l | xargs)
        len=$((len + wide))
    fi
    echo "$len"
}

# get_engine_health / get_engine_slots / get_model_name — shared with
# ai-status.sh (both read the globals defined by ai-coder-status-common.sh).
source "$SCRIPT_DIR/libs/ai-coder-engine-status.sh"

# Prints <text> as one dashboard row between the ║ borders, padded to the
# box width by its rendered (not character) length.
box_line() {
    local _len _pad
    _len=$(get_visible_length "$1")
    _pad=$(( 70 - _len ))
    [ "$_pad" -lt 0 ] && _pad=0
    printf "%b║%b%b%*s%b║%b\n" "$CYAN" "$NC" "$1" "$_pad" "" "$CYAN" "$NC"
}

# Draws the dashboard header
draw_header() {
    printf "%b╔%s╗%b\n" "$CYAN" "$SEPARATOR_LINE" "$NC"
    box_line "$BOLD$WHITE$BG_BLUE  AI HUB COMMAND CENTER  $NC $DIM v1.0$NC"
}

# Draws a separator line
draw_separator() {
    printf "%b╠%s╣%b\n" "$CYAN" "$SEPARATOR_LINE" "$NC"
}

# Draws the dashboard footer
draw_footer() {
    printf "%b╚%s╝%b\n" "$CYAN" "$SEPARATOR_LINE" "$NC"
}

# --- [ MAIN LOOP ] -----------------------------------------------------------

main() {
    clear
    while true; do
        printf "\033[H"
        draw_header

        # Display GPU stats
        if gpu_data=$(get_gpu_rows); then
            while IFS='|' read -r id name util m_used m_total temp pwr m_perc; do
                [ -n "$id" ] || continue
                box_line "$BOLD🎮 GPU $id: $name $NC"
                box_line "💾  VRAM: $(render_progress_bar "$m_perc" "$BAR_WIDTH" "$GREEN" "$YELLOW" "$RED" "$DIM" "$NC") ${m_perc}% (${m_used} MB)"
                box_line "📊  Load: $(render_progress_bar "$util" "$BAR_WIDTH" "$GREEN" "$YELLOW" "$RED" "$DIM" "$NC") ${util}%"
                box_line "🌡️ ${temp}°C | ⚡ ${pwr}W"
                box_line ""
            done <<< "$gpu_data"
        else
            box_line "${RED}✘ Failed to query GPU stats${NC}"
        fi

        draw_separator

        # Display engine health
        get_engine_health
        health_raw=$(cat "$_ENGINE_TMP" 2>/dev/null || true)
        rm -f "$_ENGINE_TMP"
        if echo "$health_raw" | grep -q '"ok"'; then
            # Engine is up. Slot detail is best-effort: /slots stalls while a
            # prompt is being processed, which just means "busy", not offline.
            get_engine_slots
            slot_counts=$(get_engine_slot_counts)
            rm -f "$_SLOTS_TMP"
            if [ -n "$slot_counts" ]; then
                read -r total_slots active_slots <<< "$slot_counts"
                slot_info="${total_slots} slot(s) | ${active_slots} active"
            elif [ "$ENGINE_KIND" = "sglang" ]; then
                slot_info="SGLang"
            else
                slot_info="${YELLOW}busy processing${NC}${BOLD}"
            fi
            model_name=$(get_model_name)

            box_line "🚀 ${BOLD}ENGINE HUB: ${GREEN}● Online${NC}${BOLD} | ${slot_info}${NC}"
            [ -n "$model_name" ] && box_line "🤖  Model: ${CYAN}${model_name}${NC}"

            size_text=$(get_engine_footprint "$SCRIPT_DIR")
            [ -n "$size_text" ] && box_line "💾  Size: ${size_text}"

            speed_text=$(get_engine_speed)
            [ -n "$speed_text" ] && box_line "⚡  Speed: ${speed_text}"

            # Network isolation status
            if [ "$(get_network_isolation_status "$SCRIPT_DIR")" = "yes" ]; then
                box_line "🌐  Network: ${YELLOW}⊘ Isolated${NC}${DIM} (ai-engineering-isolated)${NC}"
            else
                box_line "🌐  Network: ${GREEN}◎ Standard${NC}${DIM} (ai-engineering-net)${NC}"
            fi
        else
            # Non-empty /health without "ok" means the server is up but the
            # model is still loading; empty means unreachable.
            if [ -n "$health_raw" ]; then
                box_line "🚀 ${BOLD}ENGINE HUB: ${YELLOW}● Loading model...${NC}"
            else
                box_line "🚀 ${BOLD}ENGINE HUB: ${RED}● Offline${NC}"
            fi
        fi

        draw_footer
        printf "\033[J"

        sleep "$UPDATE_INTERVAL"
    done
}
main