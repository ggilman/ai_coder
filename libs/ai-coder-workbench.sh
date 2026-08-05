#!/bin/bash
# ==============================================================================
# AI-CODER-WORKBENCH.SH | Workbench & Hub Engine Container Lifecycle
# Dockerfile generation and image builds shared by every npm-based agent,
# run_workbench/exec_in_container for the per-project spoke container, and
# start_hub_engine (plus its GPU arg resolution and fast-storage model volume
# sync) for the shared Hub.
# ==============================================================================

_write_standard_dockerfile() {
    local build_dir="$1" df_name="$2" apt_pkgs="$3" pm_proxy_cmds="$4" install_cmds="$5"
    local _proxy_env_block=""
    if [ -n "${DOWNLOAD_PROXY:-}" ]; then
        _proxy_env_block=$'ENV http_proxy=${PROXY_URL} https_proxy=${PROXY_URL} HTTP_PROXY=${PROXY_URL} HTTPS_PROXY=${PROXY_URL} \\\n    no_proxy=localhost,127.0.0.1 NO_PROXY=localhost,127.0.0.1'
    fi
    cat > "$build_dir/$df_name" <<DOCKERFILE
FROM $BASE_IMAGE
ARG PROXY_URL
ARG GIT_USER_NAME
ARG GIT_USER_EMAIL
ENV DEBIAN_FRONTEND=noninteractive
RUN if [ -n "\${PROXY_URL}" ]; then \
      apt_proxy=\$(echo "\${PROXY_URL}" | sed 's|^https://|http://|') && \
      if [ -f /etc/apt/sources.list ]; then \
        sed -i 's|http://|https://|g' /etc/apt/sources.list; \
      fi && \
      if [ -d /etc/apt/sources.list.d ]; then \
        find /etc/apt/sources.list.d -name '*.list' -exec sed -i 's|http://|https://|g' {} +; \
      fi && \
      printf 'Acquire::https::Proxy "%s";\nAcquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";\n' "\${apt_proxy}" > /etc/apt/apt.conf.d/01proxy; \
    fi
RUN apt-get update && apt-get install -y wget ca-certificates gnupg apt-transport-https --no-install-recommends && \
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | \
      gpg --dearmor > /usr/share/keyrings/microsoft-archive-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-archive-keyring.gpg] https://packages.microsoft.com/debian/12/prod bookworm main" \
      > /etc/apt/sources.list.d/microsoft-prod.list && \
    apt-get update && apt-get install -y \
    ${apt_pkgs} \
    --no-install-recommends --fix-missing && rm -rf /var/lib/apt/lists/*
RUN if [ -n "\${GIT_USER_NAME}" ] && [ -n "\${GIT_USER_EMAIL}" ]; then \
      git config --global user.name "\${GIT_USER_NAME}" && \
      git config --global user.email "\${GIT_USER_EMAIL}"; \
    fi
${_proxy_env_block}
${pm_proxy_cmds}
${install_cmds}
DOCKERFILE
}

build_standard_image() {
    # Args: <dockerfile-name> <apt-pkgs> <pm-proxy-cmds> <install-cmds>
    local df_name="$1" apt_pkgs="$2" pm_proxy_cmds="$3" install_cmds="$4"

    if [ -n "$(docker images -q "$IMAGE_NAME" 2>/dev/null)" ]; then return 0; fi

    pull_image_if_missing "$BASE_IMAGE" || return 1

    local proxy_args=()
    [ -n "${DOWNLOAD_PROXY:-}" ] && proxy_args=(--build-arg "PROXY_URL=$(resolve_proxy_to_ip "$DOWNLOAD_PROXY")")

    local git_args=()
    [ -n "${GIT_USER_NAME:-}" ] && [ -n "${GIT_USER_EMAIL:-}" ] && \
        git_args=(--build-arg "GIT_USER_NAME=${GIT_USER_NAME}" --build-arg "GIT_USER_EMAIL=${GIT_USER_EMAIL}")

    local _build_dir; _build_dir=$(mktemp -d)
    trap 'rm -rf "$_build_dir"; trap - RETURN' RETURN

    _write_standard_dockerfile "$_build_dir" "$df_name" "$apt_pkgs" "$pm_proxy_cmds" "$install_cmds"

    docker build -t "$IMAGE_NAME" "${proxy_args[@]}" "${git_args[@]}" \
        -f "$(to_host_path "$_build_dir")/$df_name" \
        "$(to_host_path "$_build_dir")" || {
        echo -e "${RED}✘ Docker build failed${NC}"; return 1
    }
}

build_npm_agent_image() {
    # Shared build_image scaffolding for npm-based agents.
    # Args:
    #   $1  dockerfile name
    #   $2  agent-specific apt package file basename (under $PACKAGES_DIR)
    #   $3  agent-specific mcp package file basename (under $PACKAGES_DIR)
    #   $4  npm package(s) to pass to npm install -g
    #   $5  extra npm flags appended after mcp packages (e.g. "--quiet"), or ""
    #   $6  extra RUN line appended after npm install (e.g. "RUN gemini --version"), or ""
    local df_name="$1" apt_file="$2" mcp_file="$3" npm_pkg="$4" npm_extra_flags="${5:-}" verify_run="${6:-}"

    if [ -n "$(docker images -q "$IMAGE_NAME" 2>/dev/null)" ]; then
        echo -e "${ICON_OK} ${TOOL_NAME} Image: ready."
        return 0
    fi
    echo -e "${ICON_GEAR} Building ${TOOL_NAME} Image..."
    local pm_proxy_cmds; pm_proxy_cmds=$(make_npm_proxy_cmds)
    local pip_proxy_cmds; pip_proxy_cmds=$(make_pip_proxy_cmds)
    local apt_pkgs; apt_pkgs="$(read_package_list "$PACKAGES_DIR/apt-common.txt") $(read_package_list "$PACKAGES_DIR/$apt_file")"
    # mcp-extra.txt servers are always installed in the image (so toggling the
    # MCP extras setting never requires a rebuild); registration in the agent
    # config is decided per-launch by make_agent_mcp_json.
    local mcp_pkgs; mcp_pkgs=$(read_mcp_packages "$PACKAGES_DIR/mcp-common.txt" "$PACKAGES_DIR/mcp-extra.txt" "$PACKAGES_DIR/$mcp_file")
    local mcp_pip_pkgs; mcp_pip_pkgs=$(read_mcp_pip_packages --offline "$PACKAGES_DIR/mcp-common.txt" "$PACKAGES_DIR/mcp-extra.txt" "$PACKAGES_DIR/$mcp_file")
    local mcp_pip_online; mcp_pip_online=$(read_mcp_pip_packages --online "$PACKAGES_DIR/mcp-common.txt" "$PACKAGES_DIR/mcp-extra.txt" "$PACKAGES_DIR/$mcp_file")
    local pip_cmd; pip_cmd=$(build_pip_install_cmds "$pip_proxy_cmds" "$mcp_pip_pkgs" "$mcp_pip_online")
    local install_cmds="RUN npm install -g ${npm_pkg} ${mcp_pkgs}${npm_extra_flags}${pip_cmd}"
    [ -n "$verify_run" ] && install_cmds+=$'\n'"$verify_run"
    build_standard_image "$df_name" "$apt_pkgs" "$pm_proxy_cmds" "$install_cmds"
}

exec_in_container() {
    # Usage: exec_in_container [extra docker exec flags...] <container> <cmd> [args...]
    # Handles winpty on Git Bash automatically.
    # NOTE: do NOT pass -e PATH=... here. On Git Bash, MSYS converts the colon-
    # separated value into Windows-style paths through the winpty boundary, which
    # the Linux container cannot use. docker exec inherits the container's
    # image-set PATH (which already includes /usr/local/bin for npm globals) and
    # that is sufficient.
    # On Git Bash, MSYS converts /foo paths to Windows paths when winpty is the
    # intermediary, even with MSYS_NO_PATHCONV=1. The // prefix suppresses MSYS
    # conversion (treated as a UNC prefix); Linux normalises //foo → /foo.
    local _wd="/$WORKSPACE_DIR"
    [ "$IS_GITBASH" = "true" ] && _wd="//$WORKSPACE_DIR"
    local cmd_args=(docker exec -it -w "$_wd" "$@")
    if [ "$IS_GITBASH" = "true" ]; then
        winpty "${cmd_args[@]}"
    else
        "${cmd_args[@]}"
    fi
}

run_workbench() {
    # Usage: run_workbench [extra docker run flags...] [-- <entrypoint-cmd>]
    # Starts the workbench with standard flags. Pass a custom entrypoint after --.
    echo -e "${ICON_GEAR} Mapping Spoke for [$PROJECT_ID]..."
    local extra_flags=()
    local entrypoint="mkdir -p \"/$WORKSPACE_DIR\"; trap 'true' EXIT; while true; do sleep 3600; done"
    local past_sep=false
    for arg in "$@"; do
        if [ "$arg" = "--" ]; then past_sep=true; continue; fi
        if $past_sep; then entrypoint="$arg"; else extra_flags+=("$arg"); fi
    done
    local wb_network="$HUB_NETWORK"
    [ "${NETWORK_INTERNAL:-false}" = "true" ] && wb_network="$HUB_ISOLATED_NET"
    local no_proxy_hosts="localhost,127.0.0.1,$GLOBAL_ENGINE_NAME"
    [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ] && no_proxy_hosts="$no_proxy_hosts,$GLOBAL_PROXY_NAME"
    # When isolated, don't inject proxy env vars — the container has no internet
    # access anyway, and proxy settings can interfere with internal container
    # communication if no_proxy isn't perfectly honoured by every client.
    local _wb_http_proxy="${DOWNLOAD_PROXY:-}"
    [ "${NETWORK_INTERNAL:-false}" = "true" ] && _wb_http_proxy=""
    # On Git Bash, MSYS may still convert /$WORKSPACE_DIR to a Windows path for
    # --workdir even with MSYS_NO_PATHCONV=1. The // prefix suppresses conversion
    # and Linux containers normalise //foo → /foo.
    local _wb_workdir="/$WORKSPACE_DIR"
    [ "$IS_GITBASH" = "true" ] && _wb_workdir="//$WORKSPACE_DIR"
    # No --privileged: agents only need the workspace mount and network access,
    # and a privileged container would undermine the network-isolation option.
    # --stop-timeout 2: the keep-alive entrypoint ignores SIGTERM, so a short
    # grace period avoids a 10s docker stop hang on every exit.
    docker run -d --name "$WORKBENCH" --network "$wb_network" --stop-timeout 2 \
        -e "http_proxy=${_wb_http_proxy}" -e "https_proxy=${_wb_http_proxy}" \
        -e "HTTP_PROXY=${_wb_http_proxy}" -e "HTTPS_PROXY=${_wb_http_proxy}" \
        -e "no_proxy=$no_proxy_hosts" -e "NO_PROXY=$no_proxy_hosts" \
        -v "$(to_host_path "$(pwd)"):/$WORKSPACE_DIR" \
        -v "$(to_host_path "$HOME/.gitconfig-container"):/root/.gitconfig:ro" \
        --workdir "$_wb_workdir" \
        "${extra_flags[@]}" \
        "$IMAGE_NAME" /bin/bash -c "$entrypoint" > /dev/null
}

_resolve_engine_gpu_args() {
    # Sets _gpus_flag, _ts_args, _cuda_env for the caller based on GPU_MODE.
    # "single": exposes only GPU 0; also sets CUDA_VISIBLE_DEVICES to guard against
    # Docker Desktop / WSL2 passthrough quirks where --gpus device=0 isn't fully enforced.
    # "multi": exposes all GPUs and builds --tensor-split from per-GPU VRAM so llama.cpp
    # distributes compute (not just VRAM) across every card.
    _gpus_flag="all"
    _ts_args=()
    _cuda_env=()
    if [ "${GPU_MODE:-multi}" = "single" ]; then
        _gpus_flag="device=0"
        _cuda_env=(-e CUDA_VISIBLE_DEVICES=0)
        echo -e "${ICON_GEAR} GPU Mode: ${YELLOW}Single (GPU 0 only)${NC}"
    else
        # Split by FREE VRAM (fallback: capacity) so the display GPU — which
        # loses VRAM to the desktop — receives proportionally fewer layers.
        # This runs after the old engine is stopped, so free reflects reality.
        local _vram_raw; _vram_raw=$($SMI --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | tr -d '\r') || true
        local _split_vals=()
        for _v in $_vram_raw; do
            case "$_v" in *[!0-9]*) ;; *) _split_vals+=("$_v") ;; esac
        done
        if [ "${#_split_vals[@]}" -lt 2 ]; then
            _vram_raw=$($SMI --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | tr -d '\r') || true
            _split_vals=()
            for _v in $_vram_raw; do
                case "$_v" in *[!0-9]*) ;; *) _split_vals+=("$_v") ;; esac
            done
        fi
        if [ "${#_split_vals[@]}" -gt 1 ]; then
            local _ts; _ts=$(IFS=,; echo "${_split_vals[*]}")
            _ts_args=(--tensor-split "$_ts")
            echo -e "${ICON_GEAR} GPU Mode: ${GREEN}Multi — distributing across ${#_split_vals[@]} GPUs (split: ${CYAN}${_ts}${NC}${GREEN})${NC}"
        fi
    fi
}

# Ensure the given models exist inside the fast-storage Docker volume.
# Usage: ensure_model_in_volume <gguf-file> [more-gguf-files...]
# On Windows hosts, bind mounts go through Docker Desktop's 9p bridge, making
# the engine's model load (every cold start) several times slower than the
# named volume, which lives on the Docker VM's native disk. The host copies in
# MODEL_STORAGE_DIR remain the download cache and source of truth; this copies
# them into the volume once per model (size-verified, interruption-safe via a
# .part rename). Previously synced models are retained in the volume so
# switching family or tier back is instant; remove the volume to reclaim disk.
# Requires $LLAMA_IMAGE to be present (caller pulls it first).
ensure_model_in_volume() {
    local files=("$@") f
    [ "${#files[@]}" -gt 0 ] || return 1
    for f in "${files[@]}"; do
        [ -f "$MODEL_STORAGE_DIR/$f" ] || return 1
    done

    docker volume create "$MODEL_VOLUME_NAME" >/dev/null 2>&1 || true

    # One container call lists current volume contents as "name size" lines.
    local vol_listing
    vol_listing=$(docker run --rm --entrypoint /bin/sh -v "$MODEL_VOLUME_NAME:/vol" "$LLAMA_IMAGE" \
        -c 'for p in /vol/*.gguf; do [ -f "$p" ] && printf "%s %s\n" "${p##*/}" "$(stat -c%s "$p")"; done; true' \
        2>/dev/null | tr -d '\r') || vol_listing=""

    local sync_files=() total_sz=0 host_sz vol_sz
    for f in "${files[@]}"; do
        host_sz=$(stat -c%s "$MODEL_STORAGE_DIR/$f" 2>/dev/null || echo 0)
        [ "$host_sz" -gt 0 ] || return 1
        vol_sz=$(printf '%s\n' "$vol_listing" | awk -v n="$f" '$1==n{print $2}')
        if [ "${vol_sz:-0}" != "$host_sz" ]; then
            sync_files+=("$f")
            total_sz=$(( total_sz + host_sz ))
        fi
    done

    if [ "${#sync_files[@]}" -eq 0 ]; then
        # Nothing to copy — files no longer wanted (e.g. a draft model after
        # speculative decoding was turned off, or an old model) are left in
        # the volume rather than pruned.
        return 0
    fi

    echo -e "${ICON_GEAR} Syncing model(s) to fast storage volume ${DIM}(one-time per model)...${NC}"
    local _sync_name="ai-coder-model-sync"
    docker rm -f "$_sync_name" >/dev/null 2>&1 || true
    # Filenames are passed as positional args ("$@"), not interpolated into
    # the script text, so a filename with spaces/backticks/$() can't inject
    # shell commands into the container's sh -c.
    docker run -d --name "$_sync_name" --entrypoint /bin/sh \
        -v "$MODEL_VOLUME_NAME:/vol" \
        -v "$(to_host_path "$MODEL_STORAGE_DIR"):/src:ro" \
        "$LLAMA_IMAGE" -c '
            for f; do
                rm -f "/vol/$f.part" "/vol/$f"
                cp "/src/$f" "/vol/$f.part" && mv "/vol/$f.part" "/vol/$f" || exit 1
            done
        ' sh "${sync_files[@]}" >/dev/null || return 1

    local human_total; human_total=$(_human_size "$total_sz")
    while container_running "$_sync_name"; do
        local cur
        cur=$(docker exec "$_sync_name" /bin/sh -c '
            tot=0
            for f; do
                if [ -f "/vol/$f" ]; then s=$(stat -c%s "/vol/$f")
                elif [ -f "/vol/$f.part" ]; then s=$(stat -c%s "/vol/$f.part")
                else s=0; fi
                tot=$((tot+s))
            done
            echo $tot
        ' sh "${sync_files[@]}" 2>/dev/null | tr -d '\r') || cur=0
        case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
        printf "\r  Synced: %s / %s (%d%%)   " "$(_human_size "$cur")" "$human_total" "$(( cur * 100 / total_sz ))"
        sleep 3
    done
    printf "\r%-60s\r" ""

    local _rc; _rc=$(docker inspect -f '{{.State.ExitCode}}' "$_sync_name" 2>/dev/null | tr -d '\r') || _rc=1
    docker rm "$_sync_name" >/dev/null 2>&1 || true
    if [ "$_rc" != "0" ]; then
        echo -e "${YELLOW}⚠ Model volume sync failed (exit ${_rc}).${NC}"
        return 1
    fi
    echo -e "${ICON_OK} Model(s) cached in fast storage volume."
}

_start_litellm_proxy() {
    local hub_net="$1"
    mkdir -p "$HOME/.ai-coder"
    local config_content; config_content=$(get_litellm_config)
    cat > "$HOME/.ai-coder/litellm_config.yaml" <<EOF
$config_content
EOF
    # on-failure:3 (not always) so a host reboot doesn't resurrect the proxy
    # orphaned without its engine. Port bound to localhost only. --port is
    # passed explicitly (LiteLLM's own image default also happens to be
    # 4000) so PROXY_PORT is a real single source of truth, not just a label
    # that would silently mismatch the container's actual listen port if ever
    # changed.
    docker run -d --name "$GLOBAL_PROXY_NAME" --network "$hub_net" -p "127.0.0.1:${PROXY_PORT}:${PROXY_PORT}" --restart on-failure:3 \
        -e "http_proxy=${DOWNLOAD_PROXY:-}" -e "https_proxy=${DOWNLOAD_PROXY:-}" \
        -e "no_proxy=localhost,127.0.0.1,$GLOBAL_ENGINE_NAME" \
        -v "$(to_host_path "$HOME/.ai-coder/litellm_config.yaml"):/app/config.yaml:ro" \
        "$LITELLM_IMAGE" --config /app/config.yaml --port "$PROXY_PORT" > /dev/null || {
        echo -e "${RED}✘ Failed to start proxy container${NC}"; return 1
    }
}

start_hub_engine() {
    echo -e "${ICON_GEAR} Initializing Global GPU Hub..."

    docker stop "$GLOBAL_ENGINE_NAME" 2>/dev/null || true
    docker rm   "$GLOBAL_ENGINE_NAME" 2>/dev/null || true
    if [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ]; then
        docker stop "$GLOBAL_PROXY_NAME" 2>/dev/null || true
        docker rm   "$GLOBAL_PROXY_NAME" 2>/dev/null || true
    fi

    pull_image_if_missing "$LLAMA_IMAGE" || return 1
    if [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ]; then
        pull_image_if_missing "$LITELLM_IMAGE" || return 1
    fi

    # Speculative decoding strategy: initialize flags and map to llama.cpp args.
    # MTP uses built-in draft heads, ngram uses hashing, none disables it.
    LLAMA_SPEC_FLAGS=""
    case "${MODEL_SPEC_STRATEGY:-none}" in
        mtp)
            LLAMA_SPEC_FLAGS="--spec-type draft-mtp --spec-draft-n-max 3"
            MODEL_MAX_SLOTS="1" # CRITICAL: MTP does not support concurrent requests yet
            echo -e "${ICON_GEAR} Speculative decoding: ${GREEN}MTP (built-in draft heads)${NC}"
            echo -e "${ICON_GEAR} MTP Override: ${YELLOW}Forcing --parallel 1${NC}"
            ;;
        ngram)
            LLAMA_SPEC_FLAGS="--spec-type ngram-mod --spec-default"
            echo -e "${ICON_GEAR} Speculative decoding: ${GREEN}ngram (hash-based)${NC}"
            ;;
        none|*)
            ;;
    esac

    # External draft model: a small GGUF that proposes tokens the main
    # model verifies in one pass — typically 1.5-2x generation speed on code.
    local _draft_args=() _vol_files=("$MODEL_FILE")
    if spec_decode_enabled && [ -f "$MODEL_STORAGE_DIR/$MODEL_DRAFT_FILE" ]; then
        _draft_args=(--model-draft "/models/$MODEL_DRAFT_FILE" -ngld 99)
        _vol_files+=("$MODEL_DRAFT_FILE")
        echo -e "${ICON_GEAR} External draft model: ${GREEN}enabled${NC} ${DIM}(draft: ${MODEL_DRAFT_FILE})${NC}"
    fi

    # Model mount: fast Docker volume when enabled (with fallback to the
    # direct host folder mount if the sync fails for any reason).
    local _models_src; _models_src="$(to_host_path "$MODEL_STORAGE_DIR")"
    if [ "$(read_pref "$SETTINGS_FILE" model_volume "$MODEL_VOLUME_DEFAULT")" = "yes" ]; then
        if ensure_model_in_volume "${_vol_files[@]}"; then
            _models_src="$MODEL_VOLUME_NAME"
            echo -e "${ICON_GEAR} Model storage: ${GREEN}fast volume (${MODEL_VOLUME_NAME})${NC}"
        else
            echo -e "${YELLOW}⚠ Falling back to direct host folder mount for models.${NC}"
        fi
    fi

    local _gpus_flag _ts_args=() _cuda_env=()
    _resolve_engine_gpu_args

    local _hub_net="$HUB_NETWORK"
    [ "${NETWORK_INTERNAL:-false}" = "true" ] && _hub_net="$HUB_ISOLATED_NET"

    local _port_args=()
    if [ "$(read_pref "$SETTINGS_FILE" expose_host_port no)" = "yes" ]; then
        # Bind to localhost only so the engine is not reachable from the LAN.
        _port_args=(-p "127.0.0.1:${ENGINE_PORT}:${ENGINE_PORT}")
        echo -e "${ICON_GEAR} Engine port: ${GREEN}published on localhost:${ENGINE_PORT}${NC}"
    fi

    local _jinja_args=()
    if [ "${MODEL_JINJA:-true}" = "true" ]; then
        _jinja_args=(--jinja)
        echo -e "${ICON_GEAR} Jinja template: ${GREEN}enabled${NC}"
    else
        echo -e "${ICON_GEAR} Jinja template: ${YELLOW}disabled (model uses non-JSON tool call format)${NC}"
    fi

    # Thinking mode: reasoning models (Qwen3) burn hundreds of tokens before
    # every tool call. MODEL_THINKING=false disables it for snappier turns.
    local _think_args=()
    if [ "${MODEL_THINKING:-true}" = "false" ]; then
        _think_args=(--reasoning-budget 0)
        echo -e "${ICON_GEAR} Thinking mode: ${YELLOW}disabled (--reasoning-budget 0)${NC}"
    fi

    # Repeat penalty is off unless a family conf sets MODEL_REPEAT_PENALTY —
    # it penalizes legitimately repeated tokens (indentation, identifiers,
    # JSON keys in tool calls) and is a known cause of malformed tool calls.
    local _rp_args=()
    if [ -n "${MODEL_REPEAT_PENALTY:-}" ]; then
        _rp_args=(--repeat-penalty "$MODEL_REPEAT_PENALTY" --repeat-last-n "${MODEL_REPEAT_LAST_N:-128}")
        echo -e "${ICON_GEAR} Repeat penalty: ${YELLOW}${MODEL_REPEAT_PENALTY}${NC}"
    fi

    # --cache-reuse: agent conversations grow by appending, so reusing KV
    # cache chunks across requests avoids reprocessing the whole prompt each
    # turn — a large time-to-first-token win in agent loops.
    #
    # --restart no (NOT on-failure): a restart policy persists across Docker
    # daemon restarts, so after a crash/BSOD mid-load the engine would reload
    # the model at full GPU power unattended as soon as Docker Desktop came
    # back — exactly the wrong behaviour on a machine that just crashed
    # (observed 2026-07-15: overnight re-crash after a GPU hardware failure).
    # A failed engine stays down until a human relaunches it.
    docker run -d --name "$GLOBAL_ENGINE_NAME" --network "$_hub_net" --gpus "$_gpus_flag" --restart no \
        "${_port_args[@]}" "${_cuda_env[@]}" \
        -v "${_models_src}:/models" \
        "$LLAMA_IMAGE" \
        -m "/models/$MODEL_FILE" --host 0.0.0.0 --port "$ENGINE_PORT" \
        --parallel "$MODEL_MAX_SLOTS" -ngl "${MODEL_NGL:-99}" -c "$MODEL_CTX_SIZE" --flash-attn on \
        -ctk "${MODEL_KV_TYPE:-q8_0}" -ctv "${MODEL_KV_TYPE:-q8_0}" \
        --batch-size "${MODEL_BATCH_SIZE:-1024}" --ubatch-size "${MODEL_UBATCH_SIZE:-${MODEL_BATCH_SIZE:-1024}}" --defrag-thold 0.1 \
        --cache-reuse "${MODEL_CACHE_REUSE:-256}" \
        ${LLAMA_SPEC_FLAGS} \
        "${_draft_args[@]}" "${_think_args[@]}" "${_rp_args[@]}" "${_jinja_args[@]}" "${_ts_args[@]}" > /dev/null || {
        echo -e "${RED}✘ Failed to start engine container${NC}"; return 1
    }

    write_pref "$STATE_FILE" engine_gpu_mode "${GPU_MODE:-multi}"
    write_pref "$STATE_FILE" engine_model "${MODEL_FILE:-}"
    # Informational only — deliberately NOT part of the restart-detection
    # comparison in ai-coder: with the engine running, detect_model budgets
    # from capacity instead of free VRAM, so the recomputed layer count can
    # differ by a few layers every launch and would restart-flap the engine.
    # A settings change that matters flips the selected model file instead,
    # which the engine_model comparison already catches.
    write_pref "$STATE_FILE" engine_ngl "${MODEL_NGL:-99}"
    write_pref "$STATE_FILE" engine_ctx "${MODEL_CTX_SIZE:-}"
    write_pref "$STATE_FILE" engine_kv "${MODEL_KV_TYPE:-q8_0}"
    write_pref "$STATE_FILE" engine_batch "${MODEL_BATCH_SIZE:-1024}/${MODEL_UBATCH_SIZE:-${MODEL_BATCH_SIZE:-1024}}"
    write_pref "$STATE_FILE" engine_expose "$(read_pref "$SETTINGS_FILE" expose_host_port no)"
    write_pref "$STATE_FILE" engine_net "${NETWORK_INTERNAL:-false}"
    write_pref "$STATE_FILE" engine_mvol "$(read_pref "$SETTINGS_FILE" model_volume "$MODEL_VOLUME_DEFAULT")"
	local _spec_state="${MODEL_SPEC_STRATEGY:-none}"
    [ "${#_draft_args[@]}" -gt 0 ] && _spec_state="external-draft"
    write_pref "$STATE_FILE" engine_spec "$_spec_state"

    start_gpu_guard

    if [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ]; then
        _start_litellm_proxy "$_hub_net" || return 1
    fi
}

# Sets WORKBENCH_STARTED_BY_US so the caller's cleanup only stops containers
# this session actually started (not one shared with a concurrent session).
# The check-then-start is guarded by a mkdir lock (atomic on both WSL and Git
# Bash) so two sessions launched close together in the same project+tool
# can't both decide they "started" the container and race to stop it on exit.
ensure_workbench_running() {
    WORKBENCH_STARTED_BY_US=false
    local _lock_dir="${TMPDIR:-/tmp}/.ai-coder-wb-lock-${WORKBENCH}"
    acquire_lock "$_lock_dir" 0.2 150

    local _rc=0
    if container_running "$WORKBENCH"; then
        :
    elif [ -n "$(docker ps -aq -f name=^/${WORKBENCH}$ 2>/dev/null)" ]; then
        WORKBENCH_STARTED_BY_US=true
        docker start "$WORKBENCH" >/dev/null 2>&1 || _rc=1
    else
        WORKBENCH_STARTED_BY_US=true
        start_workbench || _rc=1
    fi

    release_lock "$_lock_dir"
    return $_rc
}
