#!/bin/bash
# ==============================================================================
# AI-CODER-MODEL.SH | Docker Preflight, VRAM Budgeting, Model Selection & Download
# Covers everything needed to pick and fetch the right GGUF model tier for the
# detected hardware before the Hub engine is started: check_docker, VRAM/KV
# estimation, select_model_for_vram, download_model/detect_model, and the base
# image pull helpers used while preparing the workbench build.
# ==============================================================================

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
        echo -e "${ICON_GEAR} Starting Docker Desktop..."
        if [ "$IS_WSL" == "true" ]; then
            if [ -n "$DOCKER_BIN" ]; then
                powershell.exe -Command "Start-Process '$DOCKER_BIN'" >/dev/null 2>&1 || {
                    echo -e "${RED}✘ Failed to start Docker${NC}"; return 1
                }
            else
                powershell.exe -Command "Start-Process 'Docker Desktop'" >/dev/null 2>&1 || {
                    echo -e "${RED}✘ Failed to start Docker${NC}"; return 1
                }
            fi
        else
            if [ -n "$DOCKER_BIN" ]; then
                # Use powershell.exe Start-Process rather than Git Bash's `start` shim.
                # The `start` shim invokes cmd.exe which hijacks the console and detaches
                # Git Bash from its own terminal window. PowerShell launches the process
                # detached without touching the calling terminal.
                # cygpath converts the MSYS path to a Windows path for PowerShell.
                local _start_bin="$DOCKER_BIN"
                [ "$IS_GITBASH" = "true" ] && _start_bin=$(cygpath -w "$DOCKER_BIN")
                powershell.exe -Command "Start-Process '$_start_bin'" >/dev/null 2>&1 || {
                    echo -e "${RED}✘ Failed to start Docker${NC}"; return 1
                }
            else
                echo -e "${RED}✘ Docker Desktop not found — start it manually and retry.${NC}"; return 1
            fi
        fi

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

# Estimate the KV-cache VRAM reserve in GB (rounded up) for the active
# context size and KV quantization type.
# Exact KV size is model-specific (layers x KV-heads x head-dim), which the
# launcher can't know before a model is chosen. Across this project's model
# range (8B-35B GQA models) q8_0 KV costs ~64-140 KB per token; 96 KiB/token
# is used as a middle estimate. MODEL_KV_BYTES_PER_TOKEN (settable in a family
# conf for models far from that band) is always a q8_0-equivalent figure —
# scaled here for the KV type actually in effect, so a family override stays
# accurate whether or not the low-VRAM KV cache toggle is on.
_estimate_kv_reserve_gb() {
    local _q8_bpt="${MODEL_KV_BYTES_PER_TOKEN:-98304}" _bpt
    case "${MODEL_KV_TYPE:-q8_0}" in
        f16|bf16)  _bpt=$(( _q8_bpt * 2 )) ;;
        q4_0|q4_1) _bpt=$(( _q8_bpt / 2 )) ;;
        *)         _bpt="$_q8_bpt" ;;
    esac
    echo $(( (${MODEL_CTX_SIZE:-65536} * _bpt + 1073741823) / 1073741824 ))
}

# Walks the MODEL_1..MODEL_N candidate list defined by the active family conf,
# in priority order (best quality first), and selects the first entry whose
# MODEL_N_WEIGHTS_GB fits within the supplied VRAM headroom (already KV-cache
# and draft reserve subtracted). Sets MODEL_FILE, MODEL_URL, MODEL_SHA256,
# MODEL_TIER, MODEL_LAYERS, and MODEL_NGL in the caller's environment.
#
# Partial CPU offload: when MODEL_CPU_OFFLOAD_PCT > 0, an entry ranked above
# the full-fit choice may be selected with some layers left on CPU, provided
# at least that percentage of its weights fits in VRAM. The shortfall
# fraction equals the fraction of layers pushed to CPU, and a CPU layer is
# roughly 10x slower than a GPU layer, so slowdown ≈ 1 + 9 × fraction
# offloaded — the default 90% caps the worst case around half speed. Only
# entries whose MODEL_N_LAYERS differs from the full-fit choice qualify:
# quants of the same model share a layer count, and halving generation speed
# for a quant bump is a bad trade. MODEL_NGL is the -ngl value for llama.cpp
# (99 = all layers on GPU, the pre-offload behaviour).
# The last candidate should have MODEL_N_WEIGHTS_GB=0 — it is always selected
# unconditionally as the fallback when nothing larger fits.
select_model_for_vram() {
    local vram="${1:-0}" i _fv _wv _lv _uv _sv _dv _w
    local _count="${MODEL_COUNT:-0}"
    MODEL_NGL=99

    # Pass 1: first entry that fits entirely in VRAM (the full-fit choice).
    # When no entry fits (malformed conf without a WEIGHTS_GB=0 fallback),
    # use the last defined candidate.
    local _full=0
    for (( i=1; i<=_count; i++ )); do
        _fv="MODEL_${i}_FILE"
        [ -z "${!_fv:-}" ] && break
        _wv="MODEL_${i}_WEIGHTS_GB"
        if [ "$vram" -ge "${!_wv:-0}" ]; then _full=$i; break; fi
    done
    [ "$_full" -eq 0 ] && _full=$(( _count > 0 ? _count : 1 ))
    local _sel=$_full

    # Pass 2: partial CPU offload — the best-ranked entry above the full-fit
    # choice wins if enough of it fits and it is a different model.
    local _pct="${MODEL_CPU_OFFLOAD_PCT:-90}"
    _lv="MODEL_${_full}_LAYERS"
    local _full_layers="${!_lv:-0}"
    if [ "$_pct" -gt 0 ] 2>/dev/null; then
        for (( i=1; i<_full; i++ )); do
            _wv="MODEL_${i}_WEIGHTS_GB"; _w="${!_wv:-0}"
            _lv="MODEL_${i}_LAYERS"
            [ "$_w" -gt 0 ] || continue
            [ -n "${!_lv:-}" ] || continue
            [ "${!_lv}" -ne "$_full_layers" ] || continue
            if [ $(( vram * 100 / _w )) -ge "$_pct" ]; then
                _sel=$i
                # Floor division is deliberately conservative: WEIGHTS_GB also
                # covers tensors that never offload per-layer (embeddings,
                # output head), so the true per-layer cost is slightly lower.
                MODEL_NGL=$(( ${!_lv} * vram / _w ))
                break
            fi
        done
    fi

    _fv="MODEL_${_sel}_FILE"; _uv="MODEL_${_sel}_URL"
    _sv="MODEL_${_sel}_SHA256"; _dv="MODEL_${_sel}_DESC"
    _lv="MODEL_${_sel}_LAYERS"
    MODEL_FILE="${!_fv:-}"
    MODEL_URL="${!_uv:-}"
    MODEL_SHA256="${!_sv:-}"
    MODEL_TIER="${!_dv:-model-$_sel}"
    MODEL_LAYERS="${!_lv:-}"
}

# Download a URL to a local path. Selects the best available tool and handles proxy.
_download_file() {
    local url="$1" dest="$2"
    local win_curl=""
    [ "$IS_WSL" = "true" ] && win_curl=$(command -v curl.exe 2>/dev/null || true)
    local http_proxy=""
    [ -n "${DOWNLOAD_PROXY:-}" ] && http_proxy=$(resolve_proxy_to_ip "$(echo "$DOWNLOAD_PROXY" | sed 's|^https://|http://|')")

    if [ "$IS_GITBASH" = "true" ] && command -v powershell.exe >/dev/null 2>&1; then
        local win_out; win_out=$(cygpath -w "$dest")
        local ps_cmd="\$ProgressPreference='SilentlyContinue'; Invoke-WebRequest -Uri '${url}' -OutFile '${win_out}' -UseBasicParsing"
        [ -n "$http_proxy" ] && ps_cmd+=" -Proxy '${http_proxy}'"
        powershell.exe -NoProfile -NonInteractive -Command "$ps_cmd" &
        _await_download $! "$dest"
    elif [ -n "$http_proxy" ] && [ -n "$win_curl" ]; then
        local win_path; win_path=$(wslpath -w "$dest")
        "$win_curl" -L --proxy "$http_proxy" --ssl-no-revoke --no-progress-meter --show-error -o "$win_path" "$url" &
        _await_download $! "$dest"
    elif [ -n "$http_proxy" ] && command -v curl >/dev/null 2>&1; then
        curl -L --proxy "$http_proxy" --progress-bar --show-error -o "$dest" "$url"
    elif [ -n "$win_curl" ]; then
        local win_path; win_path=$(wslpath -w "$dest")
        "$win_curl" -L --no-progress-meter --show-error -o "$win_path" "$url" &
        _await_download $! "$dest"
    elif command -v curl >/dev/null 2>&1; then
        curl -L --progress-bar --show-error -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        local wget_proxy_args=()
        [ -n "$http_proxy" ] && wget_proxy_args=(-e "use_proxy=yes" -e "http_proxy=$http_proxy" -e "https_proxy=$http_proxy")
        wget --no-verbose --show-progress --progress=dot:giga "${wget_proxy_args[@]}" -O "$dest" "$url"
    else
        return 1
    fi
}

# Verify a file's sha256 against an expected value. No-op when the expected
# value is empty or sha256sum is unavailable. Removes the file on mismatch.
_verify_sha256() {
    local file="$1" expected="$2"
    [ -n "$expected" ] || return 0
    command -v sha256sum >/dev/null 2>&1 || return 0
    echo -e "${ICON_GEAR} Verifying checksum..."
    local actual; actual=$(sha256sum "$file" | cut -d' ' -f1)
    if [ "$actual" != "$expected" ]; then
        rm -f "$file"
        echo -e "${RED}✘ Checksum mismatch — expected ${expected}, got ${actual}${NC}"
        echo -e "${YELLOW}  The download may be corrupt or tampered with. Please retry.${NC}"
        return 1
    fi
    echo -e "${GREEN}✔ Checksum verified${NC}"
}

# True when speculative decoding should be used: the setting is on (default)
# and the active model family defines a draft model.
spec_decode_enabled() {
    [ "$(read_pref "$SETTINGS_FILE" spec_decode yes)" = "yes" ] && [ -n "${MODEL_DRAFT_FILE:-}" ]
}

# Download the family's speculative-decoding draft model if missing.
download_draft_model() {
    local dest="$MODEL_STORAGE_DIR/$MODEL_DRAFT_FILE"
    [ -f "$dest" ] && return 0
    [ -n "${MODEL_DRAFT_URL:-}" ] || return 1
    local part="${dest}.part"
    rm -f "$part"
    echo -e "${ICON_GEAR} Downloading draft model ${CYAN}${MODEL_DRAFT_FILE}${NC} ${DIM}(speculative decoding)...${NC}"
    if _download_file "$MODEL_DRAFT_URL" "$part"; then
        _verify_sha256 "$part" "${MODEL_DRAFT_SHA256:-}" || return 1
        mv "$part" "$dest"
    else
        rm -f "$part"
        return 1
    fi
}

# Format a byte count as a human-readable size.
# numfmt is not available in Git Bash — use awk for portability.
_human_size() {
    awk -v b="${1:-0}" 'BEGIN{
        s=b+0; u="B"
        if(s>=1073741824){s=s/1073741824; u="GiB"}
        else if(s>=1048576){s=s/1048576; u="MiB"}
        else if(s>=1024){s=s/1024; u="KiB"}
        printf "%.1f%s", s, u
    }'
}

# Show a file-size progress ticker for a background download PID, then wait for it.
# Cleans up a partial file if the download fails.
_await_download() {
    local dl_pid="$1" file_path="$2"
    while kill -0 "$dl_pid" 2>/dev/null; do
        local sz; sz=$(stat -c%s "$file_path" 2>/dev/null || echo 0)
        printf "\r  Downloaded: %-12s" "$(_human_size "$sz")"
        sleep 2
    done
    printf "\n"
    if ! wait "$dl_pid"; then
        rm -f "$file_path"
        return 1
    fi
}

# Resolve DOWNLOAD_PROXY to a plain http://ip:port URL for tools (npm, pip)
# that need an explicit http:// proxy scheme regardless of the configured
# scheme. resolve_proxy_to_ip converts the hostname to an IP so proxy
# resolution doesn't depend on DNS being reachable during a Docker build.
# Echoes empty when no proxy is configured. Shared by make_npm_proxy_cmds,
# make_pip_proxy_cmds, and any agent build_image() that installs via pip
# outside build_pip_install_cmds (e.g. Aider's venv-based install).
resolve_http_proxy_url() {
    [ -z "${DOWNLOAD_PROXY:-}" ] && return
    local build_proxy; build_proxy=$(resolve_proxy_to_ip "$DOWNLOAD_PROXY")
    echo "$build_proxy" | sed 's|^https://|http://|'
}

# Returns Dockerfile RUN commands to configure npm proxy, or empty string if no proxy.
make_npm_proxy_cmds() {
    local npm_proxy; npm_proxy=$(resolve_http_proxy_url)
    [ -z "$npm_proxy" ] && return
    echo "RUN npm config set proxy $npm_proxy && npm config set https-proxy $npm_proxy && npm config set strict-ssl false"
}

make_pip_proxy_cmds() {
    # Returns the full command prefix to place between "RUN " and the package names.
    # When no proxy is configured: just "pip3 install --break-system-packages".
    # --break-system-packages is required on Debian Bookworm (PEP 668) to allow
    # system-wide pip installs inside Docker containers.
    # When proxy is configured: unset proxy env vars first (urllib3/pip tries
    # TLS-in-TLS when https_proxy is set, even with http:// scheme, causing
    # "check_hostname requires server_hostname"). Clearing the env vars and
    # passing --proxy http:// explicitly forces a plain CONNECT tunnel.
    local pip_proxy; pip_proxy=$(resolve_http_proxy_url)
    if [ -z "$pip_proxy" ]; then
        echo "pip3 install --break-system-packages"
        return
    fi
    echo "env -u https_proxy -u HTTPS_PROXY -u http_proxy -u HTTP_PROXY pip3 install --break-system-packages --proxy $pip_proxy --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org"
}

build_pip_install_cmds() {
    # Usage: build_pip_install_cmds <pip_proxy_cmds> <offline_pkgs> <online_pkgs>
    # Returns Dockerfile RUN lines for offline pip packages (required) and online
    # pip packages (best-effort, || true). Used by agent build_image() functions.
    #
    # Pins mcp<2.0.0: the MCP Python SDK's 2.0.0 release removed the
    # @server.list_tools() decorator API that third-party servers like
    # mcp-server-git and cli-mcp-server are still built against, so an
    # unpinned install resolves 2.0.0 and they crash on startup with
    # "AttributeError: 'Server' object has no attribute 'list_tools'".
    # Remove this pin once those packages catch up to the new SDK.
    local pip_proxy_cmds="$1" mcp_pip_pkgs="$2" mcp_pip_online="$3"
    local pip_cmd=""
    if [ -n "$(echo "$mcp_pip_pkgs" | tr -d ' ')" ]; then
        pip_cmd=$'\nRUN '"${pip_proxy_cmds} ${mcp_pip_pkgs} 'mcp<2.0.0'"
    fi
    if [ -n "$(echo "$mcp_pip_online" | tr -d ' ')" ]; then
        pip_cmd+=$'\nRUN '"${pip_proxy_cmds} ${mcp_pip_online} 'mcp<2.0.0' || true"
    fi
    printf '%s' "$pip_cmd"
}

download_model() {
    if [ -n "${MODEL_FILE:-}" ] && [ -f "$MODEL_STORAGE_DIR/$MODEL_FILE" ]; then
        return 0
    fi

    # Resolve model selection and metadata (file, url, sha256, desc) when not
    # already set — e.g. on the initial run or when MODEL_FILE was cleared.
    if [ -z "${MODEL_FILE:-}" ] || [ -z "${MODEL_URL:-}" ]; then
        select_model_for_vram "${EFFECTIVE_VRAM_GB:-${VRAM_GB:-0}}"
    fi

    local model_url="${MODEL_URL:-}"
    local model_hint="${MODEL_TIER:-$MODEL_FILE}"
    local model_sha="${MODEL_SHA256:-}"

    [ -z "$model_url" ] && { echo -e "${RED}✘ Missing download URL for $MODEL_FILE${NC}"; return 1; }

    local model_path="$MODEL_STORAGE_DIR/$MODEL_FILE"
    local part_path="${model_path}.part"

    # Remove any leftover partial download from a previous interrupted attempt.
    if [ -f "$part_path" ]; then
        echo -e "${YELLOW}⚠ Removing incomplete previous download: $(basename "$part_path")${NC}"
        rm -f "$part_path"
    fi

    echo -e "${ICON_GEAR} Downloading ${model_hint}..."
    echo -e "${CYAN}Downloading to: $model_path${NC}"
    [ -n "${DOWNLOAD_PROXY:-}" ] && echo -e "${CYAN}Using proxy: $DOWNLOAD_PROXY${NC}"

    # Download to a .part file so an interrupted transfer never leaves a file
    # that looks like a complete model.
    if _download_file "$model_url" "$part_path"; then
        # Verify checksum when the family conf provides one (MODEL_<tier>_SHA256).
        _verify_sha256 "$part_path" "${model_sha:-}" || return 1
        mv "$part_path" "$model_path"
        echo -e "${GREEN}✔ Model downloaded successfully${NC}"
    else
        rm -f "$part_path"
        echo -e "${RED}✘ Download failed${NC}"
        return 1
    fi
}

detect_model() {
    local vram_list; vram_list=$($SMI --query-gpu=memory.total,memory.free --format=csv,noheader,nounits 2>/dev/null | tr -d '\r') || {
        echo -e "${RED}✘ nvidia-smi failed${NC}"; return 1
    }

    # Budget from FREE VRAM, not capacity: the display GPU permanently loses
    # VRAM to the desktop compositor and other apps, and budgeting from
    # capacity lets a model that "fits on paper" oversubscribe the card —
    # WDDM then silently pages VRAM to system RAM and the whole desktop
    # freezes/crawls. When the hub engine is already loaded, free VRAM
    # reflects its own model and is meaningless for tier selection — fall
    # back to capacity for that launch (the tier only matters if a config
    # change forces a restart, which frees the VRAM anyway).
    local _use_free=true
    [ -n "$(docker ps -q -f name=^/${GLOBAL_ENGINE_NAME}$ 2>/dev/null)" ] && _use_free=false

    local total_vram=0 free_vram=0 gpu_idx=0 gpus_used=0 _t _f
    while IFS=', ' read -r _t _f _; do
        case "$_t" in ''|*[!0-9]*) gpu_idx=$((gpu_idx + 1)); continue ;; esac
        # In single-GPU mode only count VRAM from GPU 0 so the tier selection
        # matches what will actually be available to the engine container.
        if [ "${GPU_MODE:-multi}" = "single" ] && [ "$gpu_idx" -gt 0 ]; then
            gpu_idx=$((gpu_idx + 1)); continue
        fi
        total_vram=$((total_vram + _t))
        case "$_f" in ''|*[!0-9]*) free_vram=$((free_vram + _t)) ;; *) free_vram=$((free_vram + _f)) ;; esac
        gpus_used=$((gpus_used + 1))
        gpu_idx=$((gpu_idx + 1))
    done <<< "$vram_list"
    VRAM_GB=$((total_vram / 1024))
    local budget_gb=$VRAM_GB
    if $_use_free; then
        budget_gb=$((free_vram / 1024))
        echo -e "${ICON_GEAR} Hardware Audit: Detected ${BOLD}${VRAM_GB}GB Total VRAM${NC} ${DIM}(${budget_gb}GB free)${NC}"
    else
        echo -e "${ICON_GEAR} Hardware Audit: Detected ${BOLD}${VRAM_GB}GB Total VRAM${NC} ${DIM}(engine loaded — budgeting from capacity)${NC}"
    fi

    # Reserve estimated KV-cache VRAM before picking a tier — a model that
    # fills the card leaves no room for the KV cache at the chosen context
    # size, causing OOM or RAM spill (which makes inference crawl).
    # The speculative-decoding draft model occupies VRAM too when enabled,
    # and each GPU loses a fixed overhead to CUDA context, compute buffers,
    # and desktop/display usage (see MODEL_VRAM_OVERHEAD_GB).
    local kv_reserve; kv_reserve=$(_estimate_kv_reserve_gb)
    local draft_reserve=0 _draft_note=""
    if spec_decode_enabled; then
        draft_reserve="${MODEL_DRAFT_VRAM_GB:-1}"
        _draft_note=" + ${draft_reserve}GB draft"
    fi
    local overhead_reserve=$(( ${MODEL_VRAM_OVERHEAD_GB:-1} * gpus_used ))
    EFFECTIVE_VRAM_GB=$(( budget_gb - kv_reserve - draft_reserve - overhead_reserve ))
    [ "$EFFECTIVE_VRAM_GB" -lt 0 ] && EFFECTIVE_VRAM_GB=0
    echo -e "${ICON_GEAR} VRAM Reserve: ${BOLD}~${kv_reserve}GB KV${NC} ${DIM}(${MODEL_CTX_LEVEL:-64k} ctx, ${MODEL_KV_TYPE:-q8_0})${_draft_note} + ${overhead_reserve}GB overhead (${gpus_used} GPU)${NC} → ${BOLD}${EFFECTIVE_VRAM_GB}GB${NC} usable for model"

    select_model_for_vram "$EFFECTIVE_VRAM_GB"
    echo -e "${ICON_GEAR} Model: ${BOLD}${MODEL_TIER}${NC}"
    echo -e "${ICON_GEAR} File:  ${CYAN}${MODEL_FILE}${NC}"
    if [ "${MODEL_NGL:-99}" -lt 99 ]; then
        echo -e "${YELLOW}⚠ CPU offload: ${MODEL_NGL}/${MODEL_LAYERS} layers on GPU — running a bigger model at reduced speed (threshold ${MODEL_CPU_OFFLOAD_PCT:-90}%, disable via --setup)${NC}"
    fi

    if [ -f "$MODEL_STORAGE_DIR/$MODEL_FILE" ]; then
        echo -e "${ICON_OK} Target Model: ${CYAN}${MODEL_FILE}${NC}"
        return 0
    fi

    echo -e "${YELLOW}⚠ Target model not found locally — will download: ${CYAN}${MODEL_FILE}${NC}"
    return 0
}

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
