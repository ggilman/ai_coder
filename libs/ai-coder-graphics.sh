#!/bin/bash
# ==============================================================================
# AI-CODER-GRAPHICS.SH | Shared Color & Icon Palette
# Source this file from any script that needs ANSI colors or status icons.
# Idempotent — safe to source multiple times in the same shell.
# ==============================================================================
[ "${_AI_CODER_GRAPHICS_LOADED:-}" = "1" ] && return 0
readonly _AI_CODER_GRAPHICS_LOADED=1

# --- [ ANSI COLORS ] ----------------------------------------------------------
readonly NC=$'\e[0m'
readonly BOLD=$'\e[1m'
readonly DIM=$'\e[2m'
readonly RED=$'\e[0;31m'
readonly GREEN=$'\e[0;32m'
readonly YELLOW=$'\e[1;33m'
readonly CYAN=$'\e[0;36m'
readonly WHITE=$'\e[1;37m'
readonly BG_BLUE=$'\e[44m'

# --- [ STATUS ICONS ] ---------------------------------------------------------
readonly ICON_OK=" ${GREEN}✔${NC} "
readonly ICON_GEAR=" ${CYAN}⚙${NC} "
readonly ICON_WAIT=" ${CYAN}◈${NC} "
