#!/bin/bash
# ==============================================================================
# AI-CODER-HUB.SH | Hub-Only (Null Workbench) Variant
# Starts the llama.cpp engine and holds it running for use by external
# applications (e.g. Open WebUI, custom scripts) without launching any
# AI coding tool. Press Ctrl-C to stop the hub and clean up.
# ==============================================================================

IMAGE_NAME=""
TOOL_NAME="Hub Only"

build_image() { return 0; }

configure_workbench() { return 0; }

start_workbench() { return 0; }

execute_tool() {
    if [ "$(read_pref "$HOME/.ai-coder-portconfig" expose_host_port no)" = "yes" ]; then
        echo -e "${ICON_OK} Hub is running — connect any OpenAI-compatible app to ${CYAN}http://localhost:8080${NC}"
    else
        echo -e "${ICON_OK} Hub is running — engine reachable by containers on the Docker network only."
        echo -e "${DIM}  Run ${CYAN}ai --setup${NC}${DIM} and enable host port exposure to access it from the host.${NC}"
    fi
    echo -e "${DIM}  Press any key to stop the hub and exit.${NC}"
    read -r -s -n 1 _ 2>/dev/null || true
}
