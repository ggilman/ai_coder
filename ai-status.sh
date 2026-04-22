#!/bin/bash
# ==============================================================================
# AI-STATUS.SH v1.0 | GPU & Engine Dashboard
# Monitors GPU utilization, VRAM, and AI Hub engine health.
# Usage: ./ai-status.sh
# ==============================================================================
set -euo pipefail

# --- [ COLOR PALETTE ] --------------------------------------------------------
readonly NC='\033[0m'; readonly BOLD='\033[1m'; readonly DIM='\033[2m'
readonly RED='\033[0;31m'; readonly GREEN='\033[0;32m'; readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'; readonly BG_BLUE='\033[44m'; readonly WHITE='\033[1;37m'

# --- [ CONFIGURATION ] --------------------------------------------------------
readonly BAR_WIDTH=35
readonly HEADER_WIDTH=72
readonly UPDATE_INTERVAL=2
readonly HEALTH_TIMEOUT=5
readonly ENGINE_NAME="ai-hub-engine"
readonly SEPARATOR_LINE=$(printf '═%.0s' {1..70})


# Platform detection
readonly IS_GITBASH=$(expr "$(uname -s)" : '.*MINGW.*' >/dev/null 2>&1 && echo "true" || echo "false")
readonly SMI="$([[ "$IS_GITBASH" == "true" ]] && echo "nvidia-smi.exe" || echo "nvidia-smi")"

# --- [ UTILITY FUNCTIONS ] ---------------------------------------------------

# Returns visible string length (stripping ANSI codes)
get_visible_length() {
    local str="$1"
    echo -ne "$str" | sed 's/\x1b\[[0-9;]*m//g' | wc -m | xargs
}

# Draws a colored progress bar
draw_bar() {
    perc=$1
    width=${2:-$BAR_WIDTH}
    filled=$((perc * width / 100))
    remaining=$((width - filled))
    
    color="$GREEN"
    [ "$perc" -gt 70 ] && color="$YELLOW"
    [ "$perc" -gt 90 ] && color="$RED"
    
    printf "%b" "${color}"
    i=0
    while [ "$i" -lt "$filled" ]; do printf "█"; i=$((i + 1)); done
    printf "%b" "${NC}${DIM}"
    i=0
    while [ "$i" -lt "$remaining" ]; do printf "░"; i=$((i + 1)); done
    printf "%b" "${NC}"
}

# Fetches raw GPU stats via nvidia-smi
get_gpu_stats() {
    $SMI --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw \
        --format=csv,noheader,nounits 2>/dev/null
}

# Checks engine slot status via curl (empty string on failure)
get_engine_health() {
    timeout "$HEALTH_TIMEOUT" docker exec "$ENGINE_NAME" curl -s http://localhost:8080/slots 2>/dev/null || echo ""
}

# Draws the dashboard header
draw_header() {
    # Top border
    printf "%b╔%s╗%b\n" "$CYAN" "$SEPARATOR_LINE" "$NC"

    # Content line
    local content_text="$BOLD$WHITE$BG_BLUE  AI HUB COMMAND CENTER  $NC $DIM v1.0$NC"
    local content_len=$(get_visible_length "$content_text")
    local pad=$((70 - content_len))
    [ "$pad" -lt 0 ] && pad=0

    printf "%b║%b%b%*s%b║%b\n" "$CYAN" "$NC" "$content_text" "$pad" "" "$CYAN" "$NC"
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
    while true; do
        clear
        draw_header
        
        # Display GPU stats
        if gpu_data=$(get_gpu_stats); then
            echo "$gpu_data" | while IFS=',' read -r id name util m_used m_total temp pwr; do
                # Trim whitespace
                id=$(echo "$id" | xargs)
                name=$(echo "$name" | xargs)
                util=$(echo "$util" | xargs)
                m_used=$(echo "$m_used" | xargs)
                m_total=$(echo "$m_total" | xargs)
                temp=$(echo "$temp" | xargs)
                pwr=$(echo "$pwr" | xargs)

                # Validate data - skip if empty or zero
                if [ -z "$m_total" ] || [ "$m_total" -le 0 ]; then
                    continue
                fi

                # Calculate memory percentage
                m_perc=$((m_used * 100 / m_total))

                header_text="$BOLD GPU $id: $name $NC"
                header_len=$(get_visible_length "$header_text")
                pad=$((70 - header_len))
                [ "$pad" -lt 0 ] && pad=0
                printf "%b║%b%b%*s%b║%b\n" \
                    "$CYAN" "$NC" "$header_text" "$pad" "" "$CYAN" "$NC"

                # VRAM Line
                vram_bar_part=$(draw_bar "$m_perc" "$BAR_WIDTH")
                vram_text="  VRAM: ${vram_bar_part} ${m_perc}% (${m_used} MB)"
                vram_len=$(get_visible_length "$vram_text")
                vram_pad=$((70 - vram_len))
                [ "$vram_pad" -lt 0 ] && vram_pad=0
                printf "%b║%b%b%*s%b║%b\n" "$CYAN" "$NC" "$vram_text" "$vram_pad" "" "$CYAN" "$NC"

                # Load Line
                load_bar_part=$(draw_bar "$util" "$BAR_WIDTH")
                load_text="  Load: ${load_bar_part} ${util}% | ${temp}°C | ${pwr}W"
                load_len=$(get_visible_length "$load_text")
                load_pad=$((70 - load_len))
                [ "$load_pad" -lt 0 ] && load_pad=0
                printf "%b║%b%b%*s%b║%b\n" "$CYAN" "$NC" "$load_text" "$load_pad" "" "$CYAN" "$NC"

                # Spacer
                printf "%b║%b%b%b║%b\n" "$CYAN" "$NC" "$(printf ' %.0s' {1..70})" "$CYAN" "$NC"
            done
        else
            err_text="✘ Failed to query GPU stats"
            err_colored="${RED}${err_text}${NC}"
            err_len=$(get_visible_length "$err_colored")
            err_pad=$((70 - err_len))
            [ "$err_pad" -lt 0 ] && err_pad=0
            printf "%b║%b %b%*s%b║%b\n" "$CYAN" "$NC" "$err_colored" "$err_pad" "" "$CYAN" "$NC"
        fi

        draw_separator

        # Display engine health
        slots_raw=$(get_engine_health)
        if [ -n "$slots_raw" ]; then
            total_slots=$(echo "$slots_raw" | { grep -o '"id"' || true; } | wc -l | xargs)
            active_slots=$(echo "$slots_raw" | { grep -o '"is_processing":true' || true; } | wc -l | xargs)

            health_text="${BOLD}ENGINE HUB: ${GREEN}● Online${NC}${BOLD} | ${total_slots} slot(s) | ${active_slots} active${NC}"
            health_len=$(get_visible_length "$health_text")
            health_pad=$((70 - health_len))
            [ "$health_pad" -lt 0 ] && health_pad=0

            printf "%b║%b%b%*s%b║%b\n" \
                "$CYAN" "$NC" "$health_text" "$health_pad" "" "$CYAN" "$NC"
        else
            health_text="${BOLD}ENGINE HUB: ${RED}● Offline${NC}"
            health_len=$(get_visible_length "$health_text")
            health_pad=$((70 - health_len))
            [ "$health_pad" -lt 0 ] && health_pad=0
            printf "%b║%b%b%*s%b║%b\n" \
                "$CYAN" "$NC" "$health_text" "$health_pad" "" "$CYAN" "$NC"
        fi

        draw_footer

        sleep "$UPDATE_INTERVAL"
    done
}

main