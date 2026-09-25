#!/bin/bash
# ==============================================================================
# AI-CODER-DOCKER.SH | Docker Preflight & Image Pulls
# check_docker (CLI reachable, daemon up — starting Docker Desktop on Windows
# when it isn't) and the proxy-aware image pulls (pull_image_if_missing,
# pull_base_image_via_proxy). Sourced by ai-coder-core.sh — not run standalone.
# ==============================================================================

# Resolve DOCKER_BIN (unless preset) to the Docker Desktop launcher, only
# needed when check_docker has to start the daemon. Docker Desktop may be a
# machine-wide install (Program Files) or a per-user install (AppData\Local).
# Candidates are probed in mount-path form; under WSL the match is converted
# to the Windows backslash form powershell.exe Start-Process expects (the Git
# Bash launch path converts with cygpath instead).
_resolve_docker_bin() {
    [ -n "$DOCKER_BIN" ] && return 0
    local _c_root="/c" _cand
    [ "$IS_WSL" = "true" ] && _c_root="/mnt/c"
    for _cand in \
        "$_c_root/Program Files/Docker/Docker/Docker Desktop.exe" \
        "$WIN_HOME/AppData/Local/Programs/DockerDesktop/frontend/Docker Desktop.exe"; do
        if [ -f "$_cand" ]; then
            DOCKER_BIN="$_cand"
            [ "$IS_WSL" = "true" ] && DOCKER_BIN=$(wslpath -w "$DOCKER_BIN")
            return 0
        fi
    done
    # No install found — keep the historical Program Files default so the
    # failure mode (Start-Process error + manual-start hint) is unchanged.
    DOCKER_BIN="C:\\Program Files\\Docker\\Docker\\Docker Desktop.exe"
}

check_docker() {
    # Verify the docker binary is reachable from this shell before anything else.
    # On some machines Docker is installed but its CLI is not on the PATH when
    # running from Git Bash (e.g. missing entry in /etc/paths or a broken
    # Desktop integration), which causes every subsequent docker call to fail
    # with "command not found" in a confusing way.
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}✘ Docker CLI not found in PATH.${NC}"
        echo -e "${YELLOW}  Docker may be installed but is not accessible from this shell.${NC}"
        echo -e "${CYAN}  Try reopening Git Bash after a fresh Docker Desktop install,${NC}"
        echo -e "${CYAN}  or run from PowerShell / WSL where Docker is reachable.${NC}"
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        if [ "$IS_WSL" != "true" ] && [ "$IS_GITBASH" != "true" ]; then
            echo -e "${RED}✘ Docker daemon is not running — start it and retry.${NC}"; return 1
        fi
        echo -e "${ICON_GEAR} Starting Docker Desktop..."
        _resolve_docker_bin
        # powershell.exe Start-Process rather than Git Bash's `start` shim: the
        # shim invokes cmd.exe, which hijacks the console and detaches Git Bash
        # from its own terminal window. Git Bash paths need cygpath -w first.
        local _start_bin="$DOCKER_BIN"
        [ "$IS_GITBASH" = "true" ] && _start_bin=$(cygpath -w "$DOCKER_BIN")
        powershell.exe -Command "Start-Process '$_start_bin'" >/dev/null 2>&1 || {
            echo -e "${RED}✘ Failed to start Docker${NC}"; return 1
        }

        local wait_count=0
        echo -ne "${CYAN}◈ Waiting for Daemon...${NC} "
        until docker info >/dev/null 2>&1; do
            wait_count=$((wait_count + 1))
            if [ "$wait_count" -gt 60 ]; then
                echo -e " ${RED}TIMEOUT${NC}"; return 1
            fi
            echo -ne "◈"; sleep 5
        done
        echo -e " ${GREEN}ONLINE${NC}"
    fi

    # Daemon is up — run a basic command to confirm the CLI actually works in
    # this shell context.  On certain Windows machines `docker info` succeeds
    # (it uses a simpler pipe path) while other commands like `docker ps` fail
    # due to permission or socket issues specific to the Git Bash environment.
    if ! docker ps >/dev/null 2>&1; then
        echo -e "${RED}✘ Docker daemon is running but commands fail from this shell.${NC}"
        echo -e "${YELLOW}  This is a known issue on some Windows machines with Git Bash.${NC}"
        echo -e "${CYAN}  Possible fixes:${NC}"
        echo -e "${CYAN}    • Add your user to the 'docker-users' group and log out/in${NC}"
        echo -e "${CYAN}    • Run Docker Desktop as Administrator once to repair permissions${NC}"
        echo -e "${CYAN}    • Use PowerShell or WSL instead of Git Bash${NC}"
        return 1
    fi
}

# Pull <image> through $proxy when a plain docker pull can't reach the
# registry: Git Bash sets the proxy env vars for Docker Desktop (Windows
# cert store); WSL2 retries plain pull first (daemon-side proxy settings)
# then falls back to crane for an explicit proxy-aware registry pull.
pull_base_image_via_proxy() {
    local image="$1" proxy="$2"

    # Git Bash: Docker Desktop is a native Windows app using the Windows cert store.
    # It handles proxy natively — just set env vars and docker pull works directly.
    if [ "$IS_GITBASH" = "true" ]; then
        echo -e "${CYAN}  Pulling $image via Docker Desktop (Windows proxy)...${NC}"
        HTTPS_PROXY="$proxy" HTTP_PROXY="$proxy" docker pull "$image" || {
            echo -e "${RED}  ✘ Base image pull failed${NC}"; return 1
        }
        return 0
    fi

    # In WSL2 the Docker daemon runs inside Docker Desktop (Windows), which has
    # its own proxy settings configured via the Docker Desktop GUI — independent
    # of WSL env vars. Try plain docker pull first; it often works even when the
    # proxy is unreachable from the WSL shell itself.
    echo -e "${CYAN}  Pulling $image via Docker Desktop (WSL2)...${NC}"
    if docker pull "$image" 2>/dev/null; then
        return 0
    fi
    echo -e "${YELLOW}  Plain pull failed — attempting crane for proxy-aware pull...${NC}"

    local crane_bin crane_tmp=""
    crane_bin=$(command -v crane 2>/dev/null)
    if [ -z "$crane_bin" ]; then
        local crane_url="https://github.com/google/go-containerregistry/releases/download/v0.20.2/go-containerregistry_Linux_x86_64.tar.gz"
        crane_tmp=$(mktemp -d)
        # Try without proxy first (--noproxy overrides env http_proxy), then via proxy.
        echo -e "${CYAN}  Downloading crane (registry pull tool) directly...${NC}"
        if curl --noproxy '*' -fsSL --connect-timeout 15 "$crane_url" 2>/dev/null | tar xz -C "$crane_tmp" crane 2>/dev/null; then
            crane_bin="$crane_tmp/crane"
        else
            echo -e "${CYAN}  Direct download failed, retrying via proxy...${NC}"
            if curl --proxy "$proxy" -fsSL --connect-timeout 30 "$crane_url" | tar xz -C "$crane_tmp" crane; then
                crane_bin="$crane_tmp/crane"
            else
                echo -e "${YELLOW}  ✘ crane unavailable — trying docker pull with explicit proxy env vars${NC}"
                rm -rf "$crane_tmp"
                HTTPS_PROXY="$proxy" HTTP_PROXY="$proxy" docker pull "$image" || {
                    echo -e "${RED}  ✘ Base image pull failed${NC}"; return 1
                }
                return 0
            fi
        fi
    fi
    echo -e "${CYAN}  Pulling $image from registry via proxy (crane)...${NC}"
    local image_tar; image_tar=$(mktemp --suffix=.tar)
    if HTTPS_PROXY="$proxy" HTTP_PROXY="$proxy" "$crane_bin" pull "$image" "$image_tar"; then
        echo -e "${CYAN}  Loading image into Docker...${NC}"
        if docker load < "$image_tar"; then
            rm -f "$image_tar"; [ -n "$crane_tmp" ] && rm -rf "$crane_tmp"
            return 0
        else
            rm -f "$image_tar"; [ -n "$crane_tmp" ] && rm -rf "$crane_tmp"
            return 1
        fi
    else
        echo -e "${RED}  ✘ crane pull failed${NC}"
        rm -f "$image_tar"; [ -n "$crane_tmp" ] && rm -rf "$crane_tmp"
        return 1
    fi
}

# Pull <image> if not present locally, routing through the proxy-aware
# pull_base_image_via_proxy when DOWNLOAD_PROXY is set.
pull_image_if_missing() {
    local img="$1"
    docker image inspect "$img" >/dev/null 2>&1 && return 0
    echo -e "${CYAN}  Pulling $img ...${NC}"
    if [ -n "${DOWNLOAD_PROXY:-}" ]; then
        pull_base_image_via_proxy "$img" "$DOWNLOAD_PROXY" || { echo -e "${RED}✘ Failed to pull $img${NC}"; return 1; }
    else
        docker pull "$img" || { echo -e "${RED}✘ Failed to pull $img${NC}"; return 1; }
    fi
}
