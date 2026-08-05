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
    clear
    while true; do
        printf "\033[H"
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

                # Validate data - skip if empty or zero. Fields can read
                # "[N/A]" on some GPUs; non-numeric values would crash the
                # arithmetic below (and kill the dashboard under set -e).
                case "$m_total" in ''|*[!0-9]*) continue ;; esac
                if [ "$m_total" -le 0 ]; then
                    continue
                fi
                case "$m_used" in ''|*[!0-9]*) m_used=0 ;; esac
                case "$util"   in ''|*[!0-9]*) util=0   ;; esac

                # Calculate memory percentage
                m_perc=$((m_used * 100 / m_total))

                header_text="$BOLD🎮 GPU $id: $name $NC"
                header_len=$(get_visible_length "$header_text")
                pad=$((70 - header_len))
                [ "$pad" -lt 0 ] && pad=0
                printf "%b║%b%b%*s%b║%b\n" \
                    "$CYAN" "$NC" "$header_text" "$pad" "" "$CYAN" "$NC"

                # VRAM Line
                vram_bar_part=$(render_progress_bar "$m_perc" "$BAR_WIDTH" "$GREEN" "$YELLOW" "$RED" "$DIM" "$NC")
                vram_text="💾  VRAM: ${vram_bar_part} ${m_perc}% (${m_used} MB)"
                vram_len=$(get_visible_length "$vram_text")
                vram_pad=$((70 - vram_len))
                [ "$vram_pad" -lt 0 ] && vram_pad=0
                printf "%b║%b%b%*s%b║%b\n" "$CYAN" "$NC" "$vram_text" "$vram_pad" "" "$CYAN" "$NC"

                # Load Line
                load_bar_part=$(render_progress_bar "$util" "$BAR_WIDTH" "$GREEN" "$YELLOW" "$RED" "$DIM" "$NC")
                load_text="📊  Load: ${load_bar_part} ${util}%"
                load_len=$(get_visible_length "$load_text")
                load_pad=$((70 - load_len))
                [ "$load_pad" -lt 0 ] && load_pad=0
                printf "%b║%b%b%*s%b║%b\n" "$CYAN" "$NC" "$load_text" "$load_pad" "" "$CYAN" "$NC"

                # Temp & Power Line
                tp_text="🌡️ ${temp}°C | ⚡ ${pwr}W"
                tp_len=$(get_visible_length "$tp_text")
                tp_pad=$((70 - tp_len))
                [ "$tp_pad" -lt 0 ] && tp_pad=0
                printf "%b║%b%b%*s%b║%b\n" "$CYAN" "$NC" "$tp_text" "$tp_pad" "" "$CYAN" "$NC"

                # Spacer
                printf "%b║%b%b%b║%b\n" "$CYAN" "$NC" "$(printf ' %.0s' {1..70})" "$CYAN" "$NC"
            done
        else
            err_text="✘ Failed to query GPU stats"
            err_colored="${RED}${err_text}${NC}"
            err_len=$(get_visible_length "$err_colored")
            err_pad=$((70 - err_len))
            [ "$err_pad" -lt 0 ] && err_pad=0
            printf "%b║%b%b%*s%b║%b\n" "$CYAN" "$NC" "$err_colored" "$err_pad" "" "$CYAN" "$NC"
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
            slots_raw=$(cat "$_SLOTS_TMP" 2>/dev/null || true)
            rm -f "$_SLOTS_TMP"
            if [ -n "$slots_raw" ]; then
                total_slots=$(echo "$slots_raw" | { grep -o '"id"' || true; } | wc -l | xargs)
                active_slots=$(echo "$slots_raw" | { grep -o '"is_processing":true' || true; } | wc -l | xargs)
                slot_info="${total_slots} slot(s) | ${active_slots} active"
            else
                slot_info="${YELLOW}busy processing${NC}${BOLD}"
            fi
            model_name=$(get_model_name)

            health_text="🚀 ${BOLD}ENGINE HUB: ${GREEN}● Online${NC}${BOLD} | ${slot_info}${NC}"
            health_len=$(get_visible_length "$health_text")
            health_pad=$((70 - health_len))
            [ "$health_pad" -lt 0 ] && health_pad=0
            printf "%b║%b%b%*s%b║%b\n" \
                "$CYAN" "$NC" "$health_text" "$health_pad" "" "$CYAN" "$NC"

            if [ -n "$model_name" ]; then
                model_text="🤖  Model: ${CYAN}${model_name}${NC}"
                model_len=$(get_visible_length "$model_text")
                model_pad=$((70 - model_len))
                [ "$model_pad" -lt 0 ] && model_pad=0
                printf "%b║%b%b%*s%b║%b\n" "$CYAN" "$NC" "$model_text" "$model_pad" "" "$CYAN" "$NC"
            fi

            # Network isolation status
            _iso_val=$(get_network_isolation_status "$SCRIPT_DIR")
            if [ "$_iso_val" = "yes" ]; then
                net_text="🌐  Network: ${YELLOW}⊘ Isolated${NC}${DIM} (ai-engineering-isolated)${NC}"
            else
                net_text="🌐  Network: ${GREEN}◎ Standard${NC}${DIM} (ai-engineering-net)${NC}"
            fi
            net_len=$(get_visible_length "$net_text")
            net_pad=$((70 - net_len))
            [ "$net_pad" -lt 0 ] && net_pad=0
            printf "%b║%b%b%*s%b║%b\n" "$CYAN" "$NC" "$net_text" "$net_pad" "" "$CYAN" "$NC"
        else
            # Non-empty /health without "ok" means the server is up but the
            # model is still loading; empty means unreachable.
            if [ -n "$health_raw" ]; then
                health_text="🚀 ${BOLD}ENGINE HUB: ${YELLOW}● Loading model...${NC}"
            else
                health_text="🚀 ${BOLD}ENGINE HUB: ${RED}● Offline${NC}"
            fi
            health_len=$(get_visible_length "$health_text")
            health_pad=$((70 - health_len))
            [ "$health_pad" -lt 0 ] && health_pad=0
            printf "%b║%b%b%*s%b║%b\n" \
                "$CYAN" "$NC" "$health_text" "$health_pad" "" "$CYAN" "$NC"
        fi

        draw_footer
        printf "\033[J"

        sleep "$UPDATE_INTERVAL"
    done
}

main