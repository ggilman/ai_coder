#!/bin/bash
# ==============================================================================
# AI-CODER-IMAGE.SH | Workbench & llama.cpp Image Builds
# Dockerfile generation and image builds shared by every npm-based agent
# (build_standard_image, build_npm_agent_image), the locally built
# asymmetric-KV llama.cpp image (ensure_llama_asym_image), and the --rebuild
# image sweep. Sourced by ai-coder-core.sh — not run standalone.
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

    # Same llama.cpp release as the stock images (LLAMA_CPP_VERSION).
    local _ref="$LLAMA_CPP_VERSION"

    # Compile for the detected GPUs only (e.g. compute_cap 8.9 -> 89): an
    # all-architectures build takes several times longer.
    local _archs
    _archs=$(gpu_query compute_cap | tr -d ' .' | grep -E '^[0-9]+$' | sort -u | paste -sd';' -) || _archs=""
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
                remove_containers "$_cid"
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
    # The locally built asymmetric-KV llama.cpp images — every version's tag,
    # so ones left behind by a LLAMA_CPP_VERSION bump go too. Rebuilt on the
    # next asym-mode launch. Skipped while the engine is running on one.
    local _asym
    while IFS= read -r _asym; do
        [ -n "$_asym" ] || continue
        if [ -n "$(docker ps -q --filter "ancestor=$_asym" 2>/dev/null)" ]; then
            echo -e "${YELLOW}  Keeping [$_asym] — the engine is running on it (stop it with ai --clean first).${NC}"
        elif docker rmi "$_asym" >/dev/null 2>&1; then
            echo -e "${ICON_OK} Removed [$_asym] — llama.cpp is rebuilt on the next asymmetric-KV launch."
        fi
    done < <(docker images --format '{{.Repository}}:{{.Tag}}' "${LLAMA_ASYM_IMAGE%:*}" 2>/dev/null)
    rm -f "$USER_DIR/.rebuild-needed"
}
