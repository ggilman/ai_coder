#!/bin/bash
# ==============================================================================
# AI-CODER-DOCKER.SH | Container Runtime Preflight & Image Pulls
# check_container_runtime (Docker: CLI reachable, daemon up — starting Docker
# Desktop on Windows when it isn't; wslc: binary present, session service
# answering), the cross-runtime Hub guard (check_other_runtime_hub) and the
# proxy-aware image pulls (pull_image_if_missing, pull_base_image_via_proxy).
# Sourced by ai-coder-core.sh — not run standalone.
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

# Poll the Docker daemon until it answers `docker info` (or timeout).
# Probes every 2s — the daemon can take a while to come up after a cold
# Docker Desktop start, and a slow Linux daemon can also lag behind the CLI.
# Returns 0 on the first successful probe, 1 on timeout. With a second arg,
# prints it after each failed probe as a progress tick.
docker_ready() {
    local timeout="${1:-90}" tick="${2:-}"
    local waited=0
    while ! docker info >/dev/null 2>&1; do
        if [ "$waited" -ge "$timeout" ]; then
            return 1
        fi
        [ -n "$tick" ] && echo -ne "$tick"
        sleep 2
        waited=$((waited + 2))
    done
    return 0
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

    # Daemon already up (the common path): the first probe succeeds and this
    # is a no-op. The poller also covers the transient "Desktop is up but the
    # daemon is still initializing" case on Windows and the slow-daemon-start
    # case on Linux, which previously fell through to the start-Docker branch.
    if ! docker info >/dev/null 2>&1; then
        if [ "$IS_WSL" != "true" ] && [ "$IS_GITBASH" != "true" ]; then
            # Plain Linux: no Docker Desktop to start — wait briefly in case the
            # daemon is mid-start, then fail with a distinct message.
            if ! docker_ready 15; then
                echo -e "${RED}✘ Docker daemon is not running — start it and retry.${NC}"; return 1
            fi
        else
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
            echo -ne "${CYAN}◈ Waiting for Daemon...${NC} "
            # A cold Docker Desktop start (WSL VM boot) can take several minutes,
            # so keep the pre-poller ~5 min budget rather than failing early.
            if ! docker_ready 300 "◈"; then
                echo -e " ${RED}TIMEOUT${NC}"
                echo -e "${RED}✘ Docker daemon not ready after 300s — is Docker Desktop fully started?${NC}"
                return 1
            fi
            echo -e " ${GREEN}ONLINE${NC}"
        fi
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

# Preflight for the selected runtime (ai-coder-runtime.sh). Docker keeps the
# Docker Desktop start-and-wait flow; WSL Containers has no daemon to start —
# the session VM boots on the first command, so it is polled briefly.
check_container_runtime() {
    runtime_is_wslc || { check_docker; return; }
    if ! wslc_available; then
        echo -e "${RED}✘ WSL Containers (wslc.exe) not found.${NC}"
        echo -e "${YELLOW}  It ships with WSL 2.9.3 or newer — update with: ${CYAN}wsl --update${NC}"
        echo -e "${YELLOW}  Or switch back to Docker with: ${CYAN}$(basename "$0") --setup${NC}"
        return 1
    fi
    ctr info >/dev/null 2>&1 && return 0
    echo -ne "${CYAN}◈ Waiting for the WSL Containers session...${NC} "
    local _waited=0
    until ctr info >/dev/null 2>&1; do
        if [ "$_waited" -ge 60 ]; then
            echo -e " ${RED}TIMEOUT${NC}"
            echo -e "${RED}✘ wslc did not answer after 60s — try: ${CYAN}wslc list${NC}"
            return 1
        fi
        echo -ne "◈"
        sleep 2
        _waited=$((_waited + 2))
    done
    echo -e " ${GREEN}ONLINE${NC}"
}

# True when the selected runtime already answers, without starting it (no
# Docker Desktop launch) — for read-only checks like --doctor.
runtime_reachable() {
    if runtime_is_wslc; then
        wslc_available && ctr info >/dev/null 2>&1
    else
        command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
    fi
}

_other_runtime_name() {
    runtime_is_wslc && echo "Docker" || echo "WSL Containers (wslc)"
}

_other_runtime_cli() {
    runtime_is_wslc && echo "docker" || echo "wslc"
}

# True when the runtime NOT selected runs the Hub engine. Cheap and
# side-effect free: Docker is only asked when its daemon already answers, and
# wslc only when a session already exists (`wslc list` would otherwise boot
# the session VM on every Docker launch).
_other_runtime_hub_running() {
    { [ "$IS_WSL" = "true" ] || [ "$IS_GITBASH" = "true" ]; } || return 1
    if runtime_is_wslc; then
        command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || return 1
        ( resolve_container_runtime docker; ctr_container_running "$GLOBAL_ENGINE_NAME" )
    else
        local _wslc; _wslc=$(_find_wslc_bin) || return 1
        [ "$("$_wslc" system session list 2>/dev/null | tr -d '\r' | grep -c '[0-9]')" -gt 0 ] || return 1
        ( resolve_container_runtime wslc; ctr_container_running "$GLOBAL_ENGINE_NAME" )
    fi
}

# Launch guard: stop when the other runtime still runs a Hub engine — e.g.
# after a one-off AI_CODER_RUNTIME override — since both would compete for
# VRAM and the published port.
check_other_runtime_hub() {
    _other_runtime_hub_running || return 0
    echo -e "${RED}✘ $(_other_runtime_name) is still running the Hub (${GLOBAL_ENGINE_NAME}).${NC}"
    echo -e "${YELLOW}  Two engines would compete for VRAM. Stop it first: ${CYAN}$(_other_runtime_cli) stop ${GLOBAL_ENGINE_NAME}${NC}"
    return 1
}

# Build the CA bundle the host-side proxy pulls need: the user's corporate
# proxy CAs (user/certificates/, DER auto-converted to PEM) plus the
# distro's system roots, as one PEM file. crane (Go) and curl (OpenSSL)
# honor SSL_CERT_FILE, which replaces the default store — so the bundle
# carries both sets and neither is lost. Prints the temp bundle path;
# returns 1 when user/certificates/ holds no usable certificate. The
# caller owns the file and removes it after use.
_proxy_ca_bundle() {
    local _dir="$USER_DIR/certificates"
    [ -d "$_dir" ] || return 1
    local _bundle _cert _pem
    _bundle=$(mktemp) || return 1
    for _cert in "$_dir"/*.crt "$_dir"/*.pem "$_dir"/*.cer; do
        [ -f "$_cert" ] || continue
        if grep -q -- '-----BEGIN CERTIFICATE' "$_cert" 2>/dev/null; then
            cat "$_cert" >> "$_bundle"
        elif command -v openssl >/dev/null 2>&1; then
            _pem=$(openssl x509 -in "$_cert" -inform DER -outform PEM 2>/dev/null) || continue
            printf '%s\n' "$_pem" >> "$_bundle"
        fi
    done
    [ -f /etc/ssl/certs/ca-certificates.crt ] && cat /etc/ssl/certs/ca-certificates.crt >> "$_bundle"
    [ -s "$_bundle" ] || { rm -f "$_bundle"; return 1; }
    printf '%s' "$_bundle"
}

# Pull <image> through $proxy when a plain docker pull can't reach the
# registry: Git Bash sets the proxy env vars for Docker Desktop (Windows
# cert store); WSL2 retries plain pull first (daemon-side proxy settings)
# then falls back to crane for an explicit proxy-aware registry pull,
# verifying the proxy's re-signed certs against user/certificates/ via
# SSL_CERT_FILE (the host-side clients use the distro trust store, which
# lacks the corporate CAs).
pull_base_image_via_proxy() {
    local image="$1" proxy="$2"

    # Git Bash: Docker Desktop is a native Windows app using the Windows cert store.
    # It handles proxy natively — just set env vars and docker pull works directly.
    if [ "$IS_GITBASH" = "true" ]; then
        echo -e "${CYAN}  Pulling $image via $(runtime_display_name) (Windows proxy)...${NC}"
        HTTPS_PROXY="$proxy" HTTP_PROXY="$proxy" ctr pull "$image" || {
            echo -e "${RED}  ✘ Base image pull failed${NC}"; return 1
        }
        return 0
    fi

    # In WSL2 the Docker daemon runs inside Docker Desktop (Windows), which has
    # its own proxy settings configured via the Docker Desktop GUI — independent
    # of WSL env vars. Try plain docker pull first; it often works even when the
    # proxy is unreachable from the WSL shell itself.
    echo -e "${CYAN}  Pulling $image via $(runtime_display_name) (WSL2)...${NC}"
    if ctr pull "$image" 2>/dev/null; then
        return 0
    fi
    echo -e "${YELLOW}  Plain pull failed — attempting crane for proxy-aware pull...${NC}"

    # The host-side TLS clients on this path (crane's Go runtime and curl's
    # OpenSSL) verify the proxy's re-signed certs against the distro trust
    # store — feed them the corporate CAs so that verification passes.
    local _ca_bundle; _ca_bundle=$(_proxy_ca_bundle || true)

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
            local _dl_env=()
            [ -n "$_ca_bundle" ] && _dl_env=(SSL_CERT_FILE="$_ca_bundle")
            if env "${_dl_env[@]}" curl --proxy "$proxy" -fsSL --connect-timeout 30 "$crane_url" | tar xz -C "$crane_tmp" crane; then
                crane_bin="$crane_tmp/crane"
            else
                echo -e "${YELLOW}  ✘ crane unavailable — trying a pull with explicit proxy env vars${NC}"
                rm -rf "$crane_tmp"; [ -n "$_ca_bundle" ] && rm -f "$_ca_bundle"
                HTTPS_PROXY="$proxy" HTTP_PROXY="$proxy" ctr pull "$image" || {
                    echo -e "${RED}  ✘ Base image pull failed${NC}"; return 1
                }
                return 0
            fi
        fi
    fi
    echo -e "${CYAN}  Pulling $image from registry via proxy (crane)...${NC}"
    local image_tar; image_tar=$(mktemp --suffix=.tar)
    local _pull_env=(HTTPS_PROXY="$proxy" HTTP_PROXY="$proxy")
    [ -n "$_ca_bundle" ] && _pull_env+=(SSL_CERT_FILE="$_ca_bundle")
    if env "${_pull_env[@]}" "$crane_bin" pull "$image" "$image_tar"; then
        echo -e "${CYAN}  Loading image into $(runtime_display_name)...${NC}"
        if ctr load < "$image_tar"; then
            rm -f "$image_tar"; [ -n "$crane_tmp" ] && rm -rf "$crane_tmp"
            [ -n "$_ca_bundle" ] && rm -f "$_ca_bundle"
            return 0
        else
            rm -f "$image_tar"; [ -n "$crane_tmp" ] && rm -rf "$crane_tmp"
            [ -n "$_ca_bundle" ] && rm -f "$_ca_bundle"
            return 1
        fi
    else
        echo -e "${RED}  ✘ crane pull failed${NC}"
        echo -e "${YELLOW}  The proxy's re-signed certificate isn't trusted by the host —${NC}"
        echo -e "${YELLOW}  add its CA certificate(s) to ${USER_DIR}/certificates/ and retry.${NC}"
        rm -f "$image_tar"; [ -n "$crane_tmp" ] && rm -rf "$crane_tmp"
        [ -n "$_ca_bundle" ] && rm -f "$_ca_bundle"
        return 1
    fi
}

# Pull <image> if not present locally, routing through the proxy-aware
# pull_base_image_via_proxy when DOWNLOAD_PROXY is set. Retried like model
# downloads (AI_CODER_DOWNLOAD_RETRIES); Docker keeps the layers a failed
# pull already fetched, so a retry only fetches the rest.
pull_image_if_missing() {
    local img="$1"
    ctr_image_exists "$img" && return 0
    echo -e "${CYAN}  Pulling $img ...${NC}"
    retry_with_backoff "${AI_CODER_DOWNLOAD_RETRIES:-3}" "Image pull" _pull_image_once "$img" || {
        echo -e "${RED}✘ Failed to pull $img${NC}"; return 1
    }
}

_pull_image_once() {
    if [ -n "${DOWNLOAD_PROXY:-}" ]; then
        pull_base_image_via_proxy "$1" "$DOWNLOAD_PROXY"
    else
        ctr pull "$1"
    fi
}
