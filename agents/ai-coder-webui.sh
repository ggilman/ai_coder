#!/bin/bash
# ==============================================================================
# AI-CODER-WEBUI.SH | Open WebUI Variant
# Starts the llama.cpp engine and an Open WebUI container connected to it.
# Access the chat UI at http://localhost:3000, then press any key to stop both.
# ==============================================================================

OPEN_WEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"
OPEN_WEBUI_HOST_PORT=3000

IMAGE_NAME=""
TOOL_NAME="Open WebUI"

build_image() { return 0; }

configure_workbench() { return 0; }

start_workbench() {
    echo -e "${ICON_GEAR} Starting Open WebUI..."

    if ! docker image inspect "$OPEN_WEBUI_IMAGE" >/dev/null 2>&1; then
        echo -e "${CYAN}  Pulling $OPEN_WEBUI_IMAGE ...${NC}"
        docker pull "$OPEN_WEBUI_IMAGE" || {
            echo -e "${RED}✘ Failed to pull Open WebUI image${NC}"
            return 1
        }
    fi

    local _wb_network="$HUB_NETWORK"
    [ "${NETWORK_INTERNAL:-false}" = "true" ] && _wb_network="$HUB_ISOLATED_NET"

    local _wb_http_proxy="${DOWNLOAD_PROXY:-}"
    [ "${NETWORK_INTERNAL:-false}" = "true" ] && _wb_http_proxy=""

    # Bind to localhost only — WEBUI_AUTH is disabled, so the UI must not be
    # reachable from the LAN.
    docker run -d --name "$WORKBENCH" --network "$_wb_network" \
        -p "127.0.0.1:${OPEN_WEBUI_HOST_PORT}:8080" \
        -e "OPENAI_API_BASE_URL=http://${GLOBAL_ENGINE_NAME}:8080/v1" \
        -e "OPENAI_API_BASE_URLS=http://${GLOBAL_ENGINE_NAME}:8080/v1" \
        -e "OPENAI_API_KEY=sk-local-bypass" \
        -e "OPENAI_API_KEYS=sk-local-bypass" \
        -e "ENABLE_OPENAI_API=True" \
        -e "ENABLE_OLLAMA_API=False" \
        -e "WEBUI_AUTH=False" \
        -e "http_proxy=${_wb_http_proxy}" \
        -e "https_proxy=${_wb_http_proxy}" \
        -e "HTTP_PROXY=${_wb_http_proxy}" \
        -e "HTTPS_PROXY=${_wb_http_proxy}" \
        -e "no_proxy=localhost,127.0.0.1,${GLOBAL_ENGINE_NAME}" \
        -e "NO_PROXY=localhost,127.0.0.1,${GLOBAL_ENGINE_NAME}" \
        -v "open-webui:/app/backend/data" \
        "$OPEN_WEBUI_IMAGE" > /dev/null || {
        echo -e "${RED}✘ Failed to start Open WebUI container${NC}"
        return 1
    }
}

execute_tool() {
    echo -e "${ICON_OK} Open WebUI is running — browse to ${CYAN}http://localhost:${OPEN_WEBUI_HOST_PORT}${NC}"
    echo -e "${DIM}  Press any key to stop Open WebUI and the hub engine and exit.${NC}"
    read -r -s -n 1 _ 2>/dev/null || true
}
