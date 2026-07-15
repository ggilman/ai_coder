#!/bin/bash
# ==============================================================================
# AI-CODER-WEBUI.SH | Open WebUI Variant
# Starts the llama.cpp engine and an Open WebUI container connected to it.
# Access the chat UI at http://localhost:3000, then press any key to stop both.
# ==============================================================================

IMAGE_NAME=""
TOOL_NAME="Open WebUI"

build_image() { return 0; }

configure_workbench() { return 0; }

start_workbench() {
    echo -e "${ICON_GEAR} Starting Open WebUI..."

    # The global sidecar variant (started via the --menu question) binds the
    # same host port — evict it so this dedicated instance can take over.
    stop_webui_sidecar

    # Container config lives in run_open_webui_container (ai-coder-core.sh),
    # shared with the sidecar variant.
    run_open_webui_container "$WORKBENCH" || {
        echo -e "${RED}✘ Failed to start Open WebUI container${NC}"
        return 1
    }
}

execute_tool() {
    echo -e "${ICON_OK} Open WebUI is running — browse to ${CYAN}http://localhost:${OPEN_WEBUI_HOST_PORT}${NC}"
    echo -e "${DIM}  Press any key to stop Open WebUI and the hub engine and exit.${NC}"
    read -r -s -n 1 _ 2>/dev/null || true
}
