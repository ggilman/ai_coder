#!/bin/bash
# ==============================================================================
# AI-CODER-WORKBENCH.SH | Workbench & Hub Engine Container Lifecycle
# Dockerfile generation and image builds shared by every npm-based agent,
# run_workbench/exec_in_container for the per-project spoke container, and
# start_hub_engine (plus its GPU arg resolution and fast-storage model volume
# sync) for the shared Hub, plus the --rebuild image sweep, the engine
# (re)start decision, and the post-start readiness poll. start_hub_engine is
# engine-neutral apart from the docker run itself: _run_llamacpp_engine here,
# _run_sglang_engine in ai-coder-sglang.sh.
# ==============================================================================

# Emit the shared Dockerfile template every agent image is built from
# (base image, apt packages, git identity, proxy ENV block).
# Args: <build-dir> <dockerfile-name> <apt-pkgs> <pm-proxy-cmds> <install-cmds>
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
    # conversion (treated as a UNC prefix); Linux normalises //foo → /foo. It
    # must cover the workdir AND every container-path argument the caller
    # passes (agent binaries, script paths, config files).
    local _wd="/$WORKSPACE_DIR"
    [ "$IS_GITBASH" = "true" ] && _wd="//$WORKSPACE_DIR"
    local cmd_args=(docker exec -it -w "$_wd" "$@")
    if [ "$IS_GITBASH" = "true" ]; then
        local _safe_args=() _a
        for _a in "${cmd_args[@]}"; do
            if [[ "$_a" == /* && ! "$_a" == //* ]]; then
                _a="//${_a#/}"
            fi
            _safe_args+=("$_a")
        done
        winpty "${_safe_args[@]}"
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
    # Sets _gpus_flag, _ts_args, _tp_args, _cuda_env for the caller based on
    # GPU_MODE. _ts_args is llama.cpp's --tensor-split, _tp_args SGLang's --tp
    # (see _resolve_sglang_tp_args); only the active engine's is ever set.
    # "single": exposes only GPU 0; also sets CUDA_VISIBLE_DEVICES to guard against
    # Docker Desktop / WSL2 passthrough quirks where --gpus device=0 isn't fully enforced.
    # "multi": exposes all GPUs and builds --tensor-split from per-GPU VRAM so llama.cpp
    # distributes compute (not just VRAM) across every card.
    _gpus_flag="all"
    _ts_args=()
    _tp_args=()
    _cuda_env=()
    if [ "${GPU_MODE:-multi}" = "single" ]; then
        _gpus_flag="device=0"
        _cuda_env=(-e CUDA_VISIBLE_DEVICES=0)
        echo -e "${ICON_GEAR} GPU Mode: ${YELLOW}Single (GPU 0 only)${NC}"
    elif engine_is_sglang; then
        _resolve_sglang_tp_args
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
# Usage: ensure_model_in_volume <model> [more-models...]
# Each <model> is a path relative to MODEL_STORAGE_DIR: a GGUF file
# (llama.cpp) or a Hugging Face snapshot directory (SGLang).
# On Windows hosts, bind mounts go through Docker Desktop's 9p bridge, making
# the engine's model load (every cold start) several times slower than the
# named volume, which lives on the Docker VM's native disk. The host copies in
# MODEL_STORAGE_DIR remain the download cache and source of truth; this copies
# them into the volume once per model (size-verified — a directory by the sum
# of its file sizes — and interruption-safe via a .part rename). Previously
# synced models are retained in the volume so switching family, tier or
# engine back is instant; remove the volume to reclaim disk.
# Runs its helper containers from $ENGINE_IMAGE (caller pulls it first), so
# an SGLang-only setup never pulls the llama.cpp image just for this.

# Shell snippet shared by the host and the helper containers: _msz <path>
# (_msz) prints a file's size, or the summed size of every file under a directory
# (directory entries' own sizes differ between filesystems, so du is avoided).
_MODEL_SZ_FN='_msz() { if [ -d "$1" ]; then find "$1" -type f -exec stat -c%s {} + 2>/dev/null | awk "{s+=\$1} END{print s+0}"; elif [ -f "$1" ]; then stat -c%s "$1"; else echo 0; fi; }'

ensure_model_in_volume() {
    local files=("$@") f
    [ "${#files[@]}" -gt 0 ] || return 1
    for f in "${files[@]}"; do
        [ -e "$MODEL_STORAGE_DIR/$f" ] || return 1
    done
    eval "$_MODEL_SZ_FN"

    docker volume create "$MODEL_VOLUME_NAME" >/dev/null 2>&1 || true

    # One container call lists current volume contents as "name size" lines:
    # every GGUF, plus every completed snapshot directory (marker present).
    # find (not a flat glob) so models nested under a family subfolder are
    # reported with their subfolder-relative path, matching $f below.
    local vol_listing
    vol_listing=$(docker run --rm --entrypoint /bin/sh -v "$MODEL_VOLUME_NAME:/vol" "$ENGINE_IMAGE" \
        -c "$_MODEL_SZ_FN"'
            find /vol -type f -name "*.gguf" 2>/dev/null | while read -r p; do printf "%s %s\n" "${p#/vol/}" "$(_msz "$p")"; done
            find /vol -type f -name "$1" 2>/dev/null | while read -r m; do d="${m%/*}"; printf "%s %s\n" "${d#/vol/}" "$(_msz "$d")"; done
            true' sh "$SGL_COMPLETE_MARKER" \
        2>/dev/null | tr -d '\r') || vol_listing=""

    local sync_files=() total_sz=0 host_sz vol_sz
    for f in "${files[@]}"; do
        host_sz=$(_msz "$MODEL_STORAGE_DIR/$f")
        [ "${host_sz:-0}" -gt 0 ] || return 1
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
        "$ENGINE_IMAGE" -c '
            for f; do
                mkdir -p "/vol/$(dirname "$f")"
                rm -rf "/vol/$f.part" "/vol/$f"
                cp -r "/src/$f" "/vol/$f.part" && mv "/vol/$f.part" "/vol/$f" || exit 1
            done
        ' sh "${sync_files[@]}" >/dev/null || return 1

    local human_total; human_total=$(_human_size "$total_sz")
    while container_running "$_sync_name"; do
        local cur
        cur=$(docker exec "$_sync_name" /bin/sh -c "$_MODEL_SZ_FN"'
            tot=0
            for f; do
                if [ -e "/vol/$f" ]; then s=$(_msz "/vol/$f")
                else s=$(_msz "/vol/$f.part"); fi
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

# Start the LiteLLM proxy container ($GLOBAL_PROXY_NAME) on the hub network,
# config written to ~/.ai-coder/litellm_config.yaml. Used by agents that need
# the proxy in front of the engine (set NEEDS_LITELLM_PROXY=true, e.g. Gemini).
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

# llama.cpp docker run, called by start_hub_engine after the shared prelude
# has resolved _hub_net, _gpus_flag, _cuda_env, _ts_args, _port_args,
# _models_src and _draft_args (all in the caller's scope). Also sets
# LLAMA_SPEC_FLAGS, which start_hub_engine records in engine_spec state.
_run_llamacpp_engine() {
    # Speculative decoding strategy: initialize flags and map to llama.cpp args.
    # MTP uses built-in draft heads, ngram uses hashing, none disables it.
    LLAMA_SPEC_FLAGS=""
    case "${MODEL_SPEC_STRATEGY:-none}" in
        mtp)
            # Most MTP families (Gemma 4, Qwen3.6 MTP) bake the draft heads into
            # the main GGUF itself — no MODEL_DRAFT_FILE, so the flags always
            # apply. Qwen3.8 instead pairs this with a real external draft file
            # (see qwen3.8.conf), which the spec_decode setting — or a failed
            # download, which clears MODEL_DRAFT_FILE — can make unavailable;
            # MODEL_DRAFT_DEFINED (captured before any such clearing, in
            # ai-coder) is what tells the two cases apart. Without this check,
            # a disabled/failed Qwen3.8 draft would still get --spec-type
            # draft-mtp with no draft model loaded to back it.
            # MODEL_MTP additionally covers built-in-head families where only
            # some tiers actually have them baked in (e.g. Gemma 4's 12B/E2B
            # don't) — llama.cpp hard-errors on load if forced against a GGUF
            # without MTP layers, so this must be checked even when there's no
            # external draft file to speak of.
            if [ "${MODEL_DRAFT_DEFINED:-false}" != "true" ] && [ "${MODEL_MTP:-true}" = "false" ]; then
                echo -e "${ICON_GEAR} Speculative decoding: ${DIM}disabled (this model tier has no built-in MTP draft heads)${NC}"
            elif [ "${MODEL_DRAFT_DEFINED:-false}" != "true" ] || spec_decode_enabled; then
                # MODEL_SPEC_DRAFT_N_MAX is per-family (default 3) — e.g.
                # qwen3.6MTP.conf's own verified value is 2; don't assume one
                # n-max fits every MTP model.
                LLAMA_SPEC_FLAGS="--spec-type draft-mtp --spec-draft-n-max ${MODEL_SPEC_DRAFT_N_MAX:-3}"
                MODEL_MAX_SLOTS="1" # CRITICAL: MTP does not support concurrent requests yet
                echo -e "${ICON_GEAR} Speculative decoding: ${GREEN}MTP (built-in draft heads)${NC}"
                echo -e "${ICON_GEAR} MTP Override: ${YELLOW}Forcing --parallel 1${NC}"
            else
                echo -e "${ICON_GEAR} Speculative decoding: ${DIM}disabled (spec_decode setting off)${NC}"
            fi
            ;;
        ngram)
            LLAMA_SPEC_FLAGS="--spec-type ngram-mod --spec-default"
            echo -e "${ICON_GEAR} Speculative decoding: ${GREEN}ngram (hash-based)${NC}"
            ;;
        none|*)
            ;;
    esac

    local _jinja_args=()
    if [ "${MODEL_JINJA:-true}" = "true" ]; then
        _jinja_args=(--jinja)
        echo -e "${ICON_GEAR} Jinja template: ${GREEN}enabled${NC}"
    else
        echo -e "${ICON_GEAR} Jinja template: ${YELLOW}disabled (model uses non-JSON tool call format)${NC}"
    fi

    # Thinking mode: reasoning models (Qwen3) burn hundreds of tokens before
    # every tool call. MODEL_THINKING=false disables it for snappier turns.
    # With thinking on, --no-reasoning-preserve drops earlier turns' reasoning
    # from the prompt (templates like Qwen3.8's keep it by default), so it
    # stops eating context; MODEL_REASONING_PRESERVE=true keeps it.
    local _think_args=()
    if [ "${MODEL_THINKING:-true}" = "false" ]; then
        _think_args=(--reasoning-budget 0)
        echo -e "${ICON_GEAR} Thinking mode: ${YELLOW}disabled (--reasoning-budget 0)${NC}"
    elif [ "${MODEL_REASONING_PRESERVE:-false}" != "true" ] && \
         _llama_supports_flag "$ENGINE_IMAGE" --no-reasoning-preserve; then
        _think_args=(--no-reasoning-preserve)
        echo -e "${ICON_GEAR} Thinking mode: ${GREEN}enabled${NC} ${DIM}(past turns' reasoning dropped from context)${NC}"
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
    docker run -d --name "$GLOBAL_ENGINE_NAME" --network "$_hub_net" --gpus "$_gpus_flag" --restart no \
        "${_port_args[@]}" "${_cuda_env[@]}" \
        -v "${_models_src}:/models" \
        "$ENGINE_IMAGE" \
        -m "/models/$MODEL_FILE" --host 0.0.0.0 --port "$ENGINE_PORT" \
        --parallel "$MODEL_MAX_SLOTS" -ngl "${MODEL_NGL:-99}" -c "$MODEL_CTX_SIZE" --flash-attn on \
        -ctk "${MODEL_KV_TYPE:-q8_0}" -ctv "${MODEL_KV_TYPE_V:-${MODEL_KV_TYPE:-q8_0}}" \
        --batch-size "${MODEL_BATCH_SIZE:-1024}" --ubatch-size "${MODEL_UBATCH_SIZE:-${MODEL_BATCH_SIZE:-1024}}" --defrag-thold 0.1 \
        --cache-reuse "${MODEL_CACHE_REUSE:-256}" \
        ${LLAMA_SPEC_FLAGS} \
        "${_draft_args[@]}" "${_think_args[@]}" "${_rp_args[@]}" "${_jinja_args[@]}" "${_ts_args[@]}" > /dev/null
}

# Usage: _llama_supports_flag <image> <flag> — true when that image's
# llama-server --help lists <flag>. The stock image is pulled once and never
# refreshed, so an older one can predate a flag, and an unknown flag stops
# llama-server from starting at all. The --help run (a second or two) is
# cached in state.json per image ID and flag, so it happens once per image.
_llama_supports_flag() {
    local _img="$1" _flag="$2" _id _key _cached
    _id=$(docker image inspect -f '{{.Id}}' "$_img" 2>/dev/null | tr -d '\r') || return 1
    _key="llama_flag_${_flag//[^a-zA-Z0-9]/_}"
    _cached=$(read_pref "$STATE_FILE" "$_key" "")
    if [ "${_cached%%|*}" != "$_id" ]; then
        # Via a temp file, not a pipe: grep -q exiting early would fail the
        # docker run side under pipefail.
        local _res=no _tmp="${TMPDIR:-/tmp}/.ai-coder-llama-help.$$"
        MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /app/llama-server "$_img" --help > "$_tmp" 2>&1 || true
        grep -q -- "$_flag" "$_tmp" && _res=yes
        rm -f "$_tmp"
        _cached="$_id|$_res"
        write_pref "$STATE_FILE" "$_key" "$_cached"
    fi
    [ "${_cached##*|}" = "yes" ]
}

# Fetches .devops/cuda.Dockerfile at <ref> and prints (one per line) the
# resolved FROM images (ARG defaults substituted in), for pre-pulling ahead
# of `docker build`. Silent no-output (not a failure) if the fetch fails —
# callers just skip pre-pulling and let `docker build` fetch them itself.
_llama_dockerfile_base_images() {
    local _ref="$1" _proxy="$2"
    local _curl_args=(-fsSL --connect-timeout 10)
    [ -n "$_proxy" ] && _curl_args+=(--proxy "$_proxy")
    local _content
    _content=$(curl "${_curl_args[@]}" \
        "https://raw.githubusercontent.com/ggml-org/llama.cpp/${_ref}/.devops/cuda.Dockerfile" 2>/dev/null) || return 0
    [ -n "$_content" ] || return 0

    local -A _args=()
    local _line
    while IFS= read -r _line; do
        [[ "$_line" =~ ^ARG[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=(.+)$ ]] && _args["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    done <<< "$_content"

    # ARG defaults can reference earlier ARGs (e.g. BASE_CUDA_DEV_CONTAINER
    # embeds ${CUDA_VERSION}) — resolve the map against itself a few passes
    # deep before using it to substitute into FROM lines.
    local _pass _arg_name
    for _pass in 1 2 3 4 5; do
        for _arg_name in "${!_args[@]}"; do
            local _other
            for _other in "${!_args[@]}"; do
                _args["$_arg_name"]="${_args[$_arg_name]//\$\{$_other\}/${_args[$_other]}}"
                _args["$_arg_name"]="${_args[$_arg_name]//\$$_other/${_args[$_other]}}"
            done
        done
    done

    # Multi-stage builds: a FROM can reference an earlier stage's "AS <name>"
    # alias instead of a real registry image (e.g. "FROM build AS base") —
    # track aliases seen so far and skip those, since they aren't pullable.
    local -A _stage_names=()
    local _val _arg_name _alias
    while IFS= read -r _line; do
        [[ "$_line" =~ ^FROM[[:space:]]+([^[:space:]]+)([[:space:]]+[Aa][Ss][[:space:]]+([^[:space:]]+))? ]] || continue
        _val="${BASH_REMATCH[1]}"; _alias="${BASH_REMATCH[3]}"
        if [ -z "${_stage_names[$_val]:-}" ]; then
            # $VAR / ${VAR} can appear anywhere in the ref (e.g. "node:$NODE_VERSION").
            for _arg_name in "${!_args[@]}"; do
                _val="${_val//\$\{$_arg_name\}/${_args[$_arg_name]}}"
                _val="${_val//\$$_arg_name/${_args[$_arg_name]}}"
            done
            [ -n "$_val" ] && [ "$_val" != "scratch" ] && echo "$_val"
        fi
        [ -n "$_alias" ] && _stage_names["$_alias"]=1
    done <<< "$_content" | sort -u
}

# Builds LLAMA_ASYM_IMAGE (the llama.cpp server with a CUDA Flash Attention
# kernel for the q8_0 K / q4_0 V cache pair) when the asym KV mode selected
# it as ENGINE_IMAGE and it doesn't exist yet. No-op otherwise. Called from
# ai-coder BEFORE the hub lock: the build takes 10-30 minutes, far longer
# than the hub lock's wait, so it gets its own lock instead. Exits (it
# doesn't fall back to the stock image) on failure, since the stock image
# would run the mismatched pair on its much slower fallback path.
ensure_llama_asym_image() {
    [ "$ENGINE_IMAGE" = "$LLAMA_ASYM_IMAGE" ] || return 0
    docker image inspect "$LLAMA_ASYM_IMAGE" >/dev/null 2>&1 && return 0

    # Reads the setting directly: this runs before ensure_network_config sets
    # NETWORK_INTERNAL (so --build-only builds the image too).
    if [ "$(read_setting isolated)" = "yes" ]; then
        echo -e "${RED}✘ The asymmetric KV cache needs a locally built llama.cpp image (${LLAMA_ASYM_IMAGE}),${NC}"
        echo -e "${RED}  and network isolation blocks the download it needs.${NC}"
        echo -e "${YELLOW}  Pick another KV cache option with: ${CYAN}ai --model${NC}${YELLOW}, or load the image from an offline bundle.${NC}"
        exit 1
    fi

    # A concurrent session may be building it already: wait (up to ~1 hour)
    # and re-check before starting a second build. LLAMA_BUILD_LOCK_HELD
    # lets ai-coder's cleanup trap release the lock after a Ctrl-C mid-build.
    local _lock_dir="$USER_DIR/.llama-build.lock"
    acquire_lock "$_lock_dir" 2 1800
    LLAMA_BUILD_LOCK_HELD=true
    if docker image inspect "$LLAMA_ASYM_IMAGE" >/dev/null 2>&1; then
        release_lock "$_lock_dir"; LLAMA_BUILD_LOCK_HELD=false
        return 0
    fi

    local _http_proxy=""
    [ -n "${DOWNLOAD_PROXY:-}" ] && _http_proxy=$(resolve_proxy_to_ip "$(echo "$DOWNLOAD_PROXY" | sed "s|^https://|http://|")")

    # llama.cpp ref: pinned via LLAMA_BUILD_REF, else the latest release tag.
    local _ref="$LLAMA_BUILD_REF"
    if [ -z "$_ref" ]; then
        local _curl_args=(-fsSL --connect-timeout 10)
        [ -n "$_http_proxy" ] && _curl_args+=(--proxy "$_http_proxy")
        _ref=$(curl "${_curl_args[@]}" https://api.github.com/repos/ggml-org/llama.cpp/releases/latest 2>/dev/null \
            | "${JQ_CMD:-jq}" -r '.tag_name // empty' 2>/dev/null | tr -d '\r') || _ref=""
        [ -n "$_ref" ] || _ref=master
    fi

    # Compile for the detected GPUs only (e.g. compute_cap 8.9 -> 89): an
    # all-architectures build takes several times longer.
    local _archs
    _archs=$($SMI --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
        | tr -d '\r .' | grep -E '^[0-9]+$' | sort -u | paste -sd';' -) || _archs=""
    if [ -z "$_archs" ]; then
        _archs=default
        echo -e "${YELLOW}⚠ Couldn't detect the GPU architecture — building for all of them (much slower).${NC}"
    fi

    # FA kernel pairs: llama.cpp's default set plus q8_0-q4_0. The upstream
    # Dockerfile's only CMake hook is CUDA_DOCKER_ARCH, which it expands
    # unquoted into the cmake command line, so the extra -D flag rides along
    # after the architecture list.
    local _fa_quants="q4_0-q4_0;q8_0-q8_0;q8_0-q4_0;f16-f16;bf16-bf16"
    local _proxy_args=()
    [ -n "$_http_proxy" ] && _proxy_args=(
        --build-arg "http_proxy=$_http_proxy" --build-arg "https_proxy=$_http_proxy"
        --build-arg "HTTP_PROXY=$_http_proxy" --build-arg "HTTPS_PROXY=$_http_proxy")

    # Pre-pull the Dockerfile's own base images (nvidia/cuda, node) through
    # pull_image_if_missing rather than letting `docker build` fetch them: the
    # Docker Desktop "docker:default" builder resolves a FROM tag from the
    # local image store first and only hits the registry if it's missing, but
    # its own registry client doesn't share pull_base_image_via_proxy's
    # TLS/proxy handling — on a corporate MITM proxy that trips up buildkit's
    # fetch (auth.docker.io cert errors) but not a plain `docker pull`.
    local _base_img
    while IFS= read -r _base_img; do
        [ -n "$_base_img" ] || continue
        pull_image_if_missing "$_base_img" || {
            release_lock "$_lock_dir"; LLAMA_BUILD_LOCK_HELD=false
            echo -e "${RED}✘ Couldn't pull base image ${_base_img} needed for the build${NC}"
            exit 1
        }
    done < <(_llama_dockerfile_base_images "$_ref" "$_http_proxy")

    echo -e "${ICON_GEAR} Building llama.cpp ${CYAN}${_ref}${NC} with the asymmetric KV cache kernel (GPU arch ${_archs})..."
    echo -e "${YELLOW}  One-time build, typically 10-30 minutes. If it runs out of memory, give Docker Desktop more RAM.${NC}"
    # Retried once: transient Ubuntu/CUDA mirror hiccups inside the upstream
    # Dockerfile's apt-get step ("Mirror sync in progress?") are common and
    # BuildKit's layer cache means a retry only redoes the failed step, not
    # the whole build.
    local _attempt _build_ok=false
    for _attempt in 1 2; do
        if docker build \
            -f .devops/cuda.Dockerfile --target server \
            --build-arg "CUDA_DOCKER_ARCH=${_archs} -DGGML_CUDA_FA_QUANTS=${_fa_quants}" \
            --build-arg "APP_VERSION=${_ref}" \
            --label "ai-coder.llama-ref=${_ref}" \
            "${_proxy_args[@]}" \
            -t "$LLAMA_ASYM_IMAGE" \
            "https://github.com/ggml-org/llama.cpp.git#${_ref}"; then
            _build_ok=true
            break
        fi
        [ "$_attempt" = 1 ] && echo -e "${YELLOW}  Build failed — retrying once (may be a transient mirror error)...${NC}"
    done
    if [ "$_build_ok" != true ]; then
        release_lock "$_lock_dir"; LLAMA_BUILD_LOCK_HELD=false
        echo -e "${RED}✘ llama.cpp build failed${NC}"
        echo -e "${YELLOW}  Pick the full (q8_0/q8_0) or q4_0 KV cache with: ${CYAN}ai --model${NC}"
        exit 1
    fi
    release_lock "$_lock_dir"; LLAMA_BUILD_LOCK_HELD=false
    echo -e "${ICON_OK} Built ${LLAMA_ASYM_IMAGE} (llama.cpp ${_ref})."
}

start_hub_engine() {
    echo -e "${ICON_GEAR} Initializing Global GPU Hub ($(engine_display_name))..."

    docker stop "$GLOBAL_ENGINE_NAME" 2>/dev/null || true
    docker rm   "$GLOBAL_ENGINE_NAME" 2>/dev/null || true
    if [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ]; then
        docker stop "$GLOBAL_PROXY_NAME" 2>/dev/null || true
        docker rm   "$GLOBAL_PROXY_NAME" 2>/dev/null || true
    fi

    # The asymmetric-KV image is built locally at launch (before the hub
    # lock, see ensure_llama_asym_image) — there's no registry to pull it from.
    if [ "$ENGINE_IMAGE" = "$LLAMA_ASYM_IMAGE" ]; then
        docker image inspect "$ENGINE_IMAGE" >/dev/null 2>&1 || {
            echo -e "${RED}✘ Engine image ${ENGINE_IMAGE} is missing${NC}"; return 1; }
    else
        pull_image_if_missing "$ENGINE_IMAGE" || return 1
    fi
    if [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ]; then
        pull_image_if_missing "$LITELLM_IMAGE" || return 1
    fi

    # External draft model: a small GGUF that proposes tokens the main
    # model verifies in one pass — typically 1.5-2x generation speed on code.
    # (Never under SGLang: spec_decode_enabled is false there.)
    local _draft_args=() _vol_files=("$MODEL_FILE")
    if spec_decode_enabled && [ -f "$MODEL_STORAGE_DIR/$MODEL_DRAFT_FILE" ]; then
        _draft_args=(--model-draft "/models/$MODEL_DRAFT_FILE" -ngld 99)
        _vol_files+=("$MODEL_DRAFT_FILE")
        echo -e "${ICON_GEAR} External draft model: ${GREEN}enabled${NC} ${DIM}(draft: ${MODEL_DRAFT_FILE})${NC}"
    fi

    # Model mount: fast Docker volume when enabled (with fallback to the
    # direct host folder mount if the sync fails for any reason).
    local _models_src; _models_src="$(to_host_path "$MODEL_STORAGE_DIR")"
    if [ "$(read_setting model_volume)" = "yes" ]; then
        if ensure_model_in_volume "${_vol_files[@]}"; then
            _models_src="$MODEL_VOLUME_NAME"
            echo -e "${ICON_GEAR} Model storage: ${GREEN}fast volume (${MODEL_VOLUME_NAME})${NC}"
        else
            echo -e "${YELLOW}⚠ Falling back to direct host folder mount for models.${NC}"
        fi
    fi

    local _gpus_flag _ts_args=() _tp_args=() _cuda_env=()
    _resolve_engine_gpu_args

    local _hub_net="$HUB_NETWORK"
    [ "${NETWORK_INTERNAL:-false}" = "true" ] && _hub_net="$HUB_ISOLATED_NET"

    local _port_args=()
    if [ "$(read_setting expose_host_port)" = "yes" ]; then
        # Bind to localhost only so the engine is not reachable from the LAN.
        _port_args=(-p "127.0.0.1:${ENGINE_PORT}:${ENGINE_PORT}")
        echo -e "${ICON_GEAR} Engine port: ${GREEN}published on localhost:${ENGINE_PORT}${NC}"
    fi

    # --restart no (NOT on-failure), for both engines: a restart policy
    # persists across Docker daemon restarts, so after a crash/BSOD mid-load
    # the engine would reload the model at full GPU power unattended as soon
    # as Docker Desktop came back — exactly the wrong behaviour on a machine
    # that just crashed (observed 2026-07-15: overnight re-crash after a GPU
    # hardware failure). A failed engine stays down until a human relaunches it.
    LLAMA_SPEC_FLAGS=""
    if engine_is_sglang; then
        _run_sglang_engine
    else
        _run_llamacpp_engine
    fi || {
        echo -e "${RED}✘ Failed to start engine container${NC}"; return 1
    }

    write_pref "$STATE_FILE" engine_backend "$ENGINE_BACKEND"
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
    write_pref "$STATE_FILE" engine_kv "$(kv_type_label)"
    write_pref "$STATE_FILE" engine_batch "${MODEL_BATCH_SIZE:-1024}/${MODEL_UBATCH_SIZE:-${MODEL_BATCH_SIZE:-1024}}"
    write_pref "$STATE_FILE" engine_expose "$(read_setting expose_host_port)"
    write_pref "$STATE_FILE" engine_net "${NETWORK_INTERNAL:-false}"
    write_pref "$STATE_FILE" engine_mvol "$(read_setting model_volume)"
    write_pref "$STATE_FILE" engine_memfrac "$(_current_sgl_memfrac)"
    write_pref "$STATE_FILE" engine_thinking "$(_current_thinking)"
    local _spec_state="${MODEL_SPEC_STRATEGY:-none}"
    engine_is_sglang && _spec_state="none"
    [ "${#_draft_args[@]}" -gt 0 ] && _spec_state="external-draft"
    write_pref "$STATE_FILE" engine_spec "$_spec_state"

    # Informational, for the --status dashboard's size line: on-disk weights
    # (main model + draft), the estimated KV cache, and their estimated VRAM
    # total — weights scaled by the GPU share of layers under CPU offload.
    eval "$_MODEL_SZ_FN"
    local _f _w_bytes=0 _kv_bytes _vram_bytes
    for _f in "${_vol_files[@]}"; do
        _w_bytes=$(( _w_bytes + $(_msz "$MODEL_STORAGE_DIR/$_f") ))
    done
    _kv_bytes=$(_estimate_kv_bytes)
    _vram_bytes=$_w_bytes
    if [ "${MODEL_NGL:-99}" -lt 99 ] && [ "${MODEL_LAYERS:-0}" -gt 0 ] 2>/dev/null; then
        _vram_bytes=$(( _w_bytes * MODEL_NGL / MODEL_LAYERS ))
    fi
    write_pref "$STATE_FILE" engine_weights_bytes "$_w_bytes"
    write_pref "$STATE_FILE" engine_kv_bytes "$_kv_bytes"
    write_pref "$STATE_FILE" engine_vram_bytes "$(( _vram_bytes + _kv_bytes ))"

    start_gpu_guard

    if [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ]; then
        _start_litellm_proxy "$_hub_net" || return 1
    fi
}

# SGLang's mem-fraction for the engine_memfrac restart check — "-" under
# llama.cpp, which has no such setting, so it never triggers a restart there.
_current_sgl_memfrac() {
    engine_is_sglang && echo "${SGL_MEM_FRACTION:-0.85}" || echo "-"
}

# Thinking mode for the engine_thinking restart check — "-" under SGLang,
# where it's a per-request option rather than an engine flag. "true+preserve"
# when thinking is on and past reasoning is kept (MODEL_REASONING_PRESERVE).
_current_thinking() {
    if engine_is_sglang; then echo "-"; return; fi
    local _t="${MODEL_THINKING:-true}"
    [ "$_t" != "false" ] && [ "${MODEL_REASONING_PRESERVE:-false}" = "true" ] && _t="$_t+preserve"
    echo "$_t"
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
    else
        WORKBENCH_STARTED_BY_US=true
        # Always recreate rather than `docker start` a stopped container: every
        # bind mount/env var the workbench needs comes from start_workbench's
        # docker run flags, and a stopped container only has whatever flags were
        # current when it was first created. A stale container from before an
        # agent script added a new mount would silently launch without it.
        # Nothing of value lives in the container's own writable layer — the
        # workspace, npm cache, and every tool's config dir are all host-mounted
        # — so recreating a stopped container is safe and cheap (its entrypoint
        # is just a sleep loop).
        if [ -n "$(docker ps -aq -f name=^/${WORKBENCH}$ 2>/dev/null)" ]; then
            docker rm "$WORKBENCH" >/dev/null 2>&1 || true
        fi
        start_workbench || _rc=1
    fi

    release_lock "$_lock_dir"
    return $_rc
}
# --rebuild: collect every workbench image (current + historical naming
# conventions), stop/remove dependent containers, remove the images, and
# clear the .rebuild-needed flag so the next run rebuilds from scratch.
rebuild_workbench_images() {
    # Docker must be up — with the daemon down every docker call below fails
    # silently and the .rebuild-needed flag would be cleared without rebuilding.
    check_docker || exit 1
    # Collect every image name defined in any agent script (current version).
    # tr -d '\r' guards against CRLF on Windows-mounted filesystems.
    # Also sweep for any leftover images from previous version numbers by
    # matching the naming convention patterns used across all agent generations.
    _agents_dir="$ROOT_DIR/agents"
    _removed=0
    declare -A _seen_imgs=()
    for f in "$_agents_dir"/ai-coder-*.sh; do
        [ -f "$f" ] || continue
        _img=$(grep -m1 '^IMAGE_NAME=' "$f" | cut -d'"' -f2 | tr -d '\r')
        [ -z "$_img" ] && continue
        _seen_imgs["$_img"]=1
    done
    # Also include any Docker images whose name matches the historical naming
    # conventions: *-engineer-* and local-* (old naming from early versions).
    while IFS= read -r _img; do
        [ -n "$_img" ] && _seen_imgs["$_img"]=1
    done < <(docker images --format '{{.Repository}}' 2>/dev/null | grep -E '(-engineer-|^local-(claude|opencode|gemini|aider))' || true)
    for _img in "${!_seen_imgs[@]}"; do
        if docker image inspect "$_img" >/dev/null 2>&1; then
            echo -e "${CYAN}◈ Removing [$_img]...${NC}"
            # Stop and remove any containers using this image before trying rmi.
            while IFS= read -r _cid; do
                [ -z "$_cid" ] && continue
                _cname=$(docker inspect --format '{{.Name}}' "$_cid" 2>/dev/null | tr -d '/')
                echo -e "${YELLOW}  Stopping container [${_cname:-$_cid}]...${NC}"
                docker stop "$_cid" 2>/dev/null || true
                docker rm   "$_cid" 2>/dev/null || true
            done < <(docker ps -aq --filter "ancestor=$_img" 2>/dev/null)
            if docker rmi "$_img" 2>/dev/null; then
                echo -e "${GREEN}✔ Removed${NC}"
                _removed=$((_removed + 1))
            else
                echo -e "${YELLOW}  Could not remove [$_img]${NC}"
            fi
        fi
    done
    [ "$_removed" -eq 0 ] && \
        echo -e "${DIM}  No workbench images found — nothing to remove.${NC}" || \
        echo -e "${ICON_OK} Workbench images cleared. They will be rebuilt on next run."
    # The locally built asymmetric-KV llama.cpp image: removing it is how a
    # newer llama.cpp gets picked up (rebuilt on the next asym-mode launch).
    # Skipped while the engine is running on it.
    if docker image inspect "$LLAMA_ASYM_IMAGE" >/dev/null 2>&1; then
        if [ -n "$(docker ps -q --filter "ancestor=$LLAMA_ASYM_IMAGE" 2>/dev/null)" ]; then
            echo -e "${YELLOW}  Keeping [$LLAMA_ASYM_IMAGE] — the engine is running on it (stop it with ai --clean first).${NC}"
        elif docker rmi "$LLAMA_ASYM_IMAGE" >/dev/null 2>&1; then
            echo -e "${ICON_OK} Removed [$LLAMA_ASYM_IMAGE] — llama.cpp is rebuilt on the next asymmetric-KV launch."
        fi
    fi
    rm -f "$USER_DIR/.rebuild-needed"
}

# Decide whether the running Hub engine (if any) matches the current
# settings, and (re)start it when it does not — or when the LiteLLM proxy
# is missing. Must be called while the caller holds the hub-start lock
# (GLOBAL_ENGINE_NAME is a machine-wide singleton).
ensure_engine_currently_running() {
    _engine_running=false
    container_running "$GLOBAL_ENGINE_NAME" && _engine_running=true
    _need_engine_restart=false

    if $_engine_running; then
        # Restart if any engine-affecting setting changed since it was last
        # started. Each entry is "label|saved-state-value|current-value"; a
        # mismatch with a non-empty saved value (i.e. the engine actually
        # recorded one last start — absent on a first run) triggers a restart.
        # All entries are checked (not just the first mismatch), so one restart
        # reports every setting that actually changed. Add a new engine-affecting
        # setting by appending a line here rather than a whole branch.
        _cur_spec=no
        spec_decode_enabled && [ -f "$MODEL_STORAGE_DIR/${MODEL_DRAFT_FILE:-}" ] && _cur_spec=yes
        _restart_checks=(
            "Engine|$(read_pref "$STATE_FILE" engine_backend "")|${ENGINE_BACKEND:-llamacpp}"
            "SGLang memory fraction|$(read_pref "$STATE_FILE" engine_memfrac "")|$(_current_sgl_memfrac)"
            "GPU mode|$(read_pref "$STATE_FILE" engine_gpu_mode "")|${GPU_MODE:-multi}"
            "Model|$(read_pref "$STATE_FILE" engine_model "")|${MODEL_FILE:-}"
            "Context size|$(read_pref "$STATE_FILE" engine_ctx "")|${MODEL_CTX_SIZE:-}"
            "KV cache type|$(read_pref "$STATE_FILE" engine_kv "")|$(kv_type_label)"
            "Batch size|$(read_pref "$STATE_FILE" engine_batch "")|${MODEL_BATCH_SIZE:-1024}/${MODEL_UBATCH_SIZE:-${MODEL_BATCH_SIZE:-1024}}"
            "Host port exposure|$(read_pref "$STATE_FILE" engine_expose "")|$(read_setting expose_host_port)"
            "Network isolation|$(read_pref "$STATE_FILE" engine_net "")|${NETWORK_INTERNAL:-false}"
            "Model storage mode|$(read_pref "$STATE_FILE" engine_mvol "")|$(read_setting model_volume)"
            "Speculative decoding|$(read_pref "$STATE_FILE" engine_spec "")|$_cur_spec"
            "Thinking mode|$(read_pref "$STATE_FILE" engine_thinking "")|$(_current_thinking)"
        )
        for _check in "${_restart_checks[@]}"; do
            IFS='|' read -r _label _old _new <<< "$_check"
            if [ -n "$_old" ] && [ "$_old" != "$_new" ]; then
                echo -e "${YELLOW}◈ ${_label} changed (${_old} → ${_new}) — restarting engine...${NC}"
                _need_engine_restart=true
            fi
        done
    fi

    if ! $_engine_running || $_need_engine_restart; then
        docker rm "$GLOBAL_ENGINE_NAME" "$GLOBAL_PROXY_NAME" 2>/dev/null || true
        start_hub_engine || { echo -e "${RED}✘ Hub startup failed${NC}"; exit 1; }
    elif [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ] && \
         ! container_running "$GLOBAL_PROXY_NAME"; then
        # Engine is already up but proxy is missing (e.g. switched from a non-proxy
        # agent). Restart both so the proxy gets a clean start alongside the engine.
        docker rm "$GLOBAL_ENGINE_NAME" "$GLOBAL_PROXY_NAME" 2>/dev/null || true
        start_hub_engine || { echo -e "${RED}✘ Hub startup failed${NC}"; exit 1; }
    fi
}

# GET <url> from inside the engine container (2s timeout), printing the body.
# llama.cpp's image ships curl; SGLang's is only guaranteed to have Python,
# so it uses urllib there. Errors print nothing, which callers treat as down.
engine_http_get() {
    if engine_is_sglang; then
        docker exec "$GLOBAL_ENGINE_NAME" python3 -c '
import sys, urllib.request
try:
    sys.stdout.write(urllib.request.urlopen(sys.argv[1], timeout=2).read().decode())
except Exception:
    pass' "$1" 2>/dev/null
    else
        docker exec "$GLOBAL_ENGINE_NAME" curl -s -m 2 "$1" 2>/dev/null
    fi
}

# Wait until the engine (and the LiteLLM proxy, when in use) answers its
# readiness probes, printing progress as it polls; on success runs the VRAM
# oversubscription check, on timeout prints engine log diagnostics.
wait_for_engine_ready() {
    echo -ne "${CYAN}◈ Syncing VRAM Slots:${NC} "
    retry_count=0
    max_retries=300
    # SGLang's first start JIT-compiles kernels and captures CUDA graphs
    # before serving, which can take several minutes on its own.
    engine_is_sglang && max_retries=900
    engine_ready=false
    proxy_ready=false

    while [ "$retry_count" -lt "$max_retries" ]; do
        # Bail early if the engine container has stopped (e.g. unsupported flag, missing model).
        # The engine runs with --restart no, so any exit means it won't come back.
        if ! container_running "$GLOBAL_ENGINE_NAME"; then
            break
        fi
        # Reset every iteration: a probe that succeeded on an earlier loop but then
        # fails on a later one (transient hiccup, container still settling) must
        # not leave a stale "ready" from before make the loop declare success.
        engine_ready=false
        proxy_ready=false
        # Fire both checks in parallel to avoid waiting serially
        engine_http_get "http://localhost:${ENGINE_PORT}/v1/models" | grep -q '"id"' &
        _engine_pid=$!

        if [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ]; then
            # Probe the proxy from inside the Docker network (via the engine
            # container) — on the isolated internal network the proxy's published
            # port is not reachable from the host, so a host-side curl would
            # never succeed.
            engine_http_get "http://$GLOBAL_PROXY_NAME:${PROXY_PORT}/v1/models" | grep -q '"object"' &
            _proxy_pid=$!
            wait "$_engine_pid" && engine_ready=true
            wait "$_proxy_pid"  && proxy_ready=true
        else
            wait "$_engine_pid" && engine_ready=true
            proxy_ready=true
        fi

        if [ "$engine_ready" = "true" ] && [ "$proxy_ready" = "true" ]; then break; fi
        retry_count=$((retry_count + 1))
        echo -ne "◈"
        sleep 1
    done

    if [ "$engine_ready" = "true" ] && [ "$proxy_ready" = "true" ]; then
        echo -e " ${GREEN}READY${NC}"
        # The engine can report ready while a GPU is silently oversubscribed
        # (WDDM pages the overflow to system RAM) — check and warn before use.
        warn_if_vram_oversubscribed
    else
        echo -e " ${RED}TIMEOUT${NC}"
        echo -e "${RED}✘ Engine/Proxy failed to initialize after ~${retry_count} seconds${NC}"
        # Basic diagnostics
        _cid=$(docker ps -aq -f "name=$GLOBAL_ENGINE_NAME" 2>/dev/null) || true
        if [ -n "${_cid:-}" ]; then
            docker logs "$GLOBAL_ENGINE_NAME" 2>&1 | tail -20 | sed 's/^/    /'
        fi
        exit 1
    fi
}
