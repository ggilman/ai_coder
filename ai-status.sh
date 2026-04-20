#!/bin/bash
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

# Platform detection
readonly IS_GITBASH=$(expr "$(uname -s)" : '.*MINGW.*' >/dev/null 2>&1 && echo "true" || echo "false")
readonly SMI="$([[ "$IS_GITBASH" == "true" ]] && echo "nvidia-smi.exe" || echo "nvidia-smi")"

# --- [ UTILITY FUNCTIONS ] ---------------------------------------------------

get_visible_length() {
    local str="$1"
    echo -ne "$str" | sed 's/\x1b\[[0-9;]*m//g' | wc -m | xargs
}

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

get_gpu_stats() {
    $SMI --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw \
        --format=csv,noheader,nounits 2>/dev/null
}

get_engine_health() {
    timeout "$HEALTH_TIMEOUT" docker exec "$ENGINE_NAME" curl -s http://localhost:8080/health 2>/dev/null || echo "{}"
}

draw_header() {
    time=$(date +%H:%M:%S)
    printf "%b╔%s╗%b\n" "$CYAN" "$(printf '═%.0s' {1..70})" "$NC"

    header_content="  AI HUB COMMAND CENTER  "
    version_text="v4.8"

    # We want to style parts of the header content.
    # Let's construct the full string with ANSI codes first.
    full_header_text="%b%b%b%s%b %b%b%s%b"
    # But printf doesn't work that way easily for padding.

    # Let's simplify: construct the text with colors, then pad based on visible length.
    # We'll use a combination of colors.

    # Part 1: BOLD WHITE BG_BLUE "  AI HUB COMMAND CENTER  "
    # Part 2: DIM "v4.8"

    text_part1="%b%b%b%s%b" # $BOLD$WHITE$BG_BLUE "  AI HUB COMMAND CENTER  " $NC
    text_part2="%b%b%s%b"   # $DIM "v4.8" $NC

    # This is tricky with printf padding.
    # Let's just build the whole line string and calculate its visible length.

    # The desired line is: ║ [Color-Text1] [Color-Text2] [Padding] ║
    # Wait, the user's error shows: AI HUB COMMAND CENTER   v4.8\033[0;36m
    # This means the color code was printed AS TEXT.

    # Looking at line 58-59:
    # printf "%b║%b %b%b  AI HUB COMMAND CENTER  %b %b%-41s%b║%b\n" \
    #     "$CYAN" "$NC" "$BOLD$WHITE$BG_BLUE" "$NC" "$DIM" "v4.8" "$CYAN" "$NC"

    # The problem is the "%b" and how arguments are passed.
    # When using %b, the argument is interpreted as a format string.
    # If the argument contains escape sequences, they are interpreted.
    # However, the way it's written:
    # printf "%b║%b %b%b  AI HUB COMMAND CENTER  %b %b%-41s%b║%b\n" \
    #     "$CYAN" "$NC" "$BOLD$WHITE$BG_BLUE" "$NC" "$DIM" "v4.8" "$CYAN" "$NC"

    # Let's count the %b's:
    # 1: $CYAN
    # 2: $NC
    # 3: $BOLD$WHITE$BG_BLUE
    # 4: $NC
    # 5: $DIM
    # 6: "v4.8" (wait, this is %-41s)
    # 7: $CYAN
    # 8: $NC

    # The number of arguments: 1(CYAN), 2(NC), 3(BOLD...), 4(NC), 5(DIM), 6(v4.8), 7(CYAN), 8(NC). Total 8.
    # The format string:
    # %b (1) ║
    # %b (2)
    # %b (3) %b (4)  AI HUB COMMAND CENTER  %b (5) %b (6, but it's %-41s) %b (7) ║
    # %b (8)

    # Let's re-examine line 58-59 carefully.
    # printf "%b║%b %b%b  AI HUB COMMAND CENTER  %b %b%-41s%b║%b\n" \
    #     "$CYAN" "$NC" "$BOLD$WHITE$BG_BLUE" "$NC" "$DIM" "v4.8" "$CYAN" "$NC"

    # The format string has:
    # 1. %b
    # 2. %b
    # 3. %b
    # 4. %b
    # 5. %b
    # 6. %b (this is the %-41s one)
    # 7. %b
    # 8. %b

    # Wait, the format string is:
    # "%b ║ %b %b %b  AI HUB COMMAND CENTER  %b %b %-41s %b ║ %b\n"
    # Let's re-count:
    # %b (1)
    # ║
    # %b (2)
    # (space)
    # %b (3)
    # %b (4)
    # (space) AI HUB COMMAND CENTER (space)
    # %b (5)
    # (space)
    # %b (6) -- wait, the format string is "%b%-41s" which is TWO format specifiers.
    # So it's %b (6) and then %-41s (7).
    # Then %b (8).
    # Then ║
    # Then %b (9).

    # Arguments provided:
    # 1: "$CYAN"
    # 2: "$NC"
    # 3: "$BOLD$WHITE$BG_BLUE"
    # 4: "$NC"
    # 5: "$DIM"
    # 6: "v4.8"
    # 7: "$CYAN"
    # 8: "$NC"

    # Total arguments: 8.
    # Total specifiers: 9.
    # This explains why it's breaking.

    # Let's rewrite it properly.
    # I will use the `get_visible_length` approach for the whole line to ensure perfect padding.
}

draw_separator() {
    printf "%b╠%s╣%b\n" "$CYAN" "$(printf '═%.0s' {1..70})" "$NC"
}

draw_footer() {
    printf "%b╚%s╝%b\n" "$CYAN" "$(printf '═%.0s' {1..70})" "$NC"
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

                # Print GPU header
                # We want the content between ║ and ║ to be 70 chars.
                # Content: " GPU $id: $name " (length L)
                # We need 70 - L spaces after it.
                header_text=" GPU $id: $name "
                header_len=$(get_visible_length "$header_text")
                pad=$((70 - header_len))
                [ "$pad" -lt 0 ] && pad=0

                printf "%b║%b%b%s%*s%b║%b\n" \
                    "$CYAN" "$NC" "$BOLD" "$header_text" "$pad" "" "$CYAN" "$NC"

                # Print VRAM bar
                # Content: "  VRAM: [bar] 100% (1000 MB) "
                # This is getting complicated. Let's simplify.
                # We'll calculate the length of the text part and pad it.

                # VRAM Line
                vram_bar_part=$(draw_bar "$m_perc" "$BAR_WIDTH")
                vram_text="  VRAM: ${vram_bar_part} ${m_perc}% (${m_used} MB)"
                vram_len=$(get_visible_length "$vram_text")
                vram_pad=$((70 - vram_len))
                [ "$vram_pad" -lt 0 ] && vram_pad=0
                printf "%b║%b%s%*s%b║%b\n" "$CYAN" "$NC" "$vram_text" "$vram_pad" "" "$CYAN" "$NC"

                # Load Line
                load_bar_part=$(draw_bar "$util" "$BAR_WIDTH")
                load_text="  Load: ${load_bar_part} ${util}% | ${temp}°C | ${pwr}W"
                load_len=$(get_visible_length "$load_text")
                load_pad=$((70 - load_len))
                [ "$load_pad" -lt 0 ] && load_pad=0
                printf "%b║%b%s%*s%b║%b\n" "$CYAN" "$NC" "$load_text" "$load_pad" "" "$CYAN" "$NC"

                # Spacer
                printf "%b║%b%s%b║%b\n" "$CYAN" "$NC" "$(printf ' %.0s' {1..70})" "$CYAN" "$NC"
            done
        else
            err_text="✘ Failed to query GPU stats"
            printf "%b║%b %b%*s%b║%b\n" "$CYAN" "$NC" "${RED}${err_text}${NC}" $((70 - ${#err_text})) "" "$CYAN" "$NC"
        fi

        draw_separator

        # Display engine health
        if health=$(get_engine_health); then
            proc_slots=$(echo "$health" | grep -o '"slots_processing":[[:space:]]*[0-9]*' | grep -o '[0-9]*$' || echo 0)
            idle_slots=$(echo "$health" | grep -o '"slots_idle":[[:space:]]*[0-9]*' | grep -o '[0-9]*$' || echo 0)
            total_slots=$((proc_slots + idle_slots))

            health_text=" ENGINE HUB: [$proc_slots/$total_slots Slots Active]"
            health_len=$(get_visible_length "$health_text")
            health_pad=$((70 - health_len))
            [ "$health_pad" -lt 0 ] && health_pad=0

            printf "%b║%b%b%b%s%*s%b║%b\n" \
                "$CYAN" "$NC" "$BOLD" "$health_text" "$NC" "$health_pad" "" "$CYAN" "$NC"
        else
            err_msg="✘ Engine health check failed"
            err_text="${RED}${err_msg}${NC}"
            err_len=$(get_visible_length "$err_text")
            err_pad=$((70 - err_len))
            [ "$err_pad" -lt 0 ] && err_pad=0
            printf "%b║%b %b%*s%b║%b\n" \
                "$CYAN" "$NC" "$err_text" "$err_pad" "" "$CYAN" "$NC"
        fi

        draw_footer

        sleep "$UPDATE_INTERVAL"
    done
}

main