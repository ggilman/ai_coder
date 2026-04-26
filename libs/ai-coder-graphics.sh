#!/bin/bash
# ==============================================================================
# AI-CODER-GRAPHICS.SH | Shared Color & Icon Palette
# Source this file from any script that needs ANSI colors or status icons.
# Idempotent — safe to source multiple times in the same shell.
# ==============================================================================
[ "${_AI_CODER_GRAPHICS_LOADED:-}" = "1" ] && return 0
readonly _AI_CODER_GRAPHICS_LOADED=1

# --- [ ANSI COLORS ] ----------------------------------------------------------
readonly NC='\033[0m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly BG_BLUE='\033[44m'

# --- [ STATUS ICONS ] ---------------------------------------------------------
readonly ICON_OK=" ${GREEN}✔${NC} "
readonly ICON_GEAR=" ${CYAN}⚙${NC} "
readonly ICON_WAIT=" ${CYAN}◈${NC} "
