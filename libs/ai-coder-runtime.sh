#!/bin/bash
# ==============================================================================
# AI-CODER-RUNTIME.SH | Container Runtime Abstraction (Docker / WSL Containers)
# Every container command goes through `ctr` (or one of the ctr_* helpers
# below), never a literal `docker`, so the "container_runtime" setting can
# swap Docker Desktop for WSL Containers (wslc.exe, WSL >= 2.9.3).
#
# Docker: `ctr` is plain `docker "$@"` and every helper runs the exact docker
# command the launcher has always used. wslc: its CLI follows Docker's, so
# most commands pass straight through to $CTR_BIN; `ctr` translates only the
# known differences (checked against wslc 2.9.4):
#   - run/create: no --restart (dropped), no --ipc=host (-> --shm-size), and
#     --gpus accepts only "all" (single-GPU mode relies on the
#     CUDA_VISIBLE_DEVICES=0 the caller already sets)
#   - stop/rm/kill take one container per call (looped)
#   - load reads only `-i <file>`, not stdin (spooled to a temp file)
#   - no `info` (probed with `list -q`, which needs the session service)
#   - no Go-template --format and no regex name filters: the ctr_* helpers
#     read `--format json` / inspect JSON through jq instead
#   - no git-URL build context (ctr_build_from_git clones first)
#   - wslc.exe is a Windows binary, so host paths must be Windows paths —
#     to_host_path (ai-coder-env.sh) converts under WSL as well when wslc is
#     selected.
#
# Self-contained like ai-coder-jq.sh: sourced by ai-coder-core.sh and
# standalone by ai-coder-watch.sh, ai-coder-status-common.sh and
# offline/unbundle.sh. Needs only IS_WSL/IS_GITBASH (ai-coder-detect-env.sh)
# and JQ_CMD (falls back to jq on PATH).
# ==============================================================================

CTR_RUNTIME="${CTR_RUNTIME:-docker}"
CTR_BIN="${CTR_BIN:-docker}"

# Prints the wslc binary to run, or returns 1 when WSL Containers isn't
# installed. PATH first; WSL's own install dir as the fallback (under WSL the
# Windows PATH may not be appended).
_find_wslc_bin() {
    local _c
    for _c in wslc wslc.exe; do
        command -v "$_c" >/dev/null 2>&1 && { echo "$_c"; return 0; }
    done
    for _c in "/c/Program Files/WSL/wslc.exe" "/mnt/c/Program Files/WSL/wslc.exe"; do
        [ -f "$_c" ] && { echo "$_c"; return 0; }
    done
    return 1
}

wslc_available() {
    _find_wslc_bin >/dev/null
}

# Usage: resolve_container_runtime <docker|wslc> — sets CTR_RUNTIME/CTR_BIN.
# Anything unrecognised is docker. wslc is Windows-only: on native Linux the
# request falls back to docker. A missing wslc binary is left for the
# preflight (check_container_runtime) to report.
resolve_container_runtime() {
    if [ "${1:-}" = "wslc" ] && { [ "${IS_WSL:-false}" = "true" ] || [ "${IS_GITBASH:-false}" = "true" ]; }; then
        CTR_RUNTIME=wslc
        CTR_BIN=$(_find_wslc_bin) || CTR_BIN="wslc.exe"
    else
        CTR_RUNTIME=docker
        CTR_BIN=docker
    fi
}

# Usage: resolve_container_runtime_standalone <settings-file>
# For entry points that run without the launch chain's pref I/O (dashboards,
# watchers, offline/unbundle.sh): AI_CODER_RUNTIME env > settings.json's
# container_runtime > docker. JQ_CMD must already be resolved (or jq on PATH).
resolve_container_runtime_standalone() {
    local _rt="${AI_CODER_RUNTIME:-}"
    if [ -z "$_rt" ] && [ -f "${1:-}" ]; then
        _rt=$("${JQ_CMD:-jq}" -r '(.container_runtime // empty)' "$1" 2>/dev/null | tr -d '\r') || _rt=""
    fi
    resolve_container_runtime "${_rt:-docker}"
}

runtime_is_wslc() {
    [ "${CTR_RUNTIME:-docker}" = "wslc" ]
}

# Human-readable runtime name for messages and menus.
runtime_display_name() {
    runtime_is_wslc && echo "WSL Containers (wslc)" || echo "Docker"
}

# The runtime's CLI as users type it, for hints like "<cli> volume rm ...".
runtime_cli_name() {
    runtime_is_wslc && echo "wslc" || echo "docker"
}

# A host file path in the form $CTR_BIN can open: Windows form for wslc.exe
# (cygpath on Git Bash, wslpath under WSL), unchanged for docker.
_ctr_host_file() {
    if ! runtime_is_wslc; then echo "$1"; return 0; fi
    if [ "${IS_GITBASH:-false}" = "true" ]; then
        cygpath -m "$1"
    elif [ "${IS_WSL:-false}" = "true" ]; then
        wslpath -m "$1"
    else
        echo "$1"
    fi
}

# A temp file wslc.exe can read and write. Under WSL, mktemp's /tmp is inside
# the distro, which wslc.exe would only reach over \\wsl.localhost — use the
# Windows user's temp dir instead when WIN_HOME is known.
_ctr_mktemp() {
    local _dir=""
    if [ "${IS_WSL:-false}" = "true" ] && [ -n "${WIN_HOME:-}" ] && [ -d "$WIN_HOME/AppData/Local/Temp" ]; then
        _dir="$WIN_HOME/AppData/Local/Temp"
    fi
    if [ -n "$_dir" ]; then
        mktemp "$_dir/ai-coder-ctr.XXXXXX"
    else
        mktemp
    fi
}

# wslc counts every distinct host folder bind-mounted during a session's
# lifetime against a limit of 15 (wslc 2.9.4): removing the containers
# doesn't release them, reusing a folder is free, named volumes don't count.
# One launch binds several folders (project, gitconfig, the agent's config
# dirs, models, LiteLLM config), so a long-lived session runs out after a
# few projects/tools. Restarting the session (~3s) resets the count; images
# and volumes survive it. Only done when the session holds no containers at
# all, so a running Hub or workbench is never touched — though an image
# pull/build another launcher is running at that moment would be cut off.
# Returns 1 when the session was busy and left alone.
wslc_reset_session_if_idle() {
    runtime_is_wslc || return 0
    local _ids
    _ids=$("$CTR_BIN" list -a -q 2>/dev/null | tr -d '\r') || return 0
    [ -z "$_ids" ] || return 1
    "$CTR_BIN" system session terminate >/dev/null 2>&1 || return 0
    "$CTR_BIN" list -q >/dev/null 2>&1 || true
}

# After a container failed to start: under wslc, explain the per-session
# folder limit, since its own error text ("Too many volumes have been
# mounted") doesn't say how to recover.
wslc_mount_limit_hint() {
    runtime_is_wslc || return 0
    echo -e "${YELLOW:-}  If the error above says \"Too many volumes have been mounted\": WSL Containers allows"
    echo -e "  15 distinct host folders per session. Reset the session with: ${CYAN:-}$(basename "$0") --clean${NC:-}"
}

# Usage: ctr <subcommand> [args...] — the container CLI. See the header for
# what is translated under wslc; everything else passes through unchanged.
ctr() {
    if ! runtime_is_wslc; then
        docker "$@"
        return
    fi
    local _sub="${1:-}"
    [ $# -gt 0 ] && shift
    case "$_sub" in
        info)        "$CTR_BIN" list -q >/dev/null ;;
        ps)          "$CTR_BIN" list "$@" ;;
        run|create)  _wslc_run "$_sub" "$@" ;;
        stop|rm|kill) _wslc_each "$_sub" "$@" ;;
        load)        _wslc_load "$@" ;;
        network|volume)
            local _verb="${1:-}"
            [ $# -gt 0 ] && shift
            [ "$_verb" = "rm" ] && _verb=remove
            "$CTR_BIN" "$_sub" "$_verb" "$@" ;;
        *)           "$CTR_BIN" "$_sub" "$@" ;;
    esac
}

# A Docker size ("16g", "512m") in the upper-case unit form wslc requires.
_wslc_size() {
    echo "${1^^}"
}

# run/create with the docker-only flags translated. Only the option section
# (before the image) is rewritten — the container's own command line after
# the image is passed through verbatim.
_wslc_run() {
    local _sub="$1"; shift
    local _out=() _a
    while [ $# -gt 0 ]; do
        _a="$1"
        case "$_a" in
            --restart)   shift 2 ;;
            --restart=*) shift ;;
            --ipc)       _out+=(--shm-size "$(_wslc_size "${SGL_SHM_SIZE:-16G}")"); shift 2 ;;
            --ipc=*)     _out+=(--shm-size "$(_wslc_size "${SGL_SHM_SIZE:-16G}")"); shift ;;
            --gpus)      _out+=(--gpus all); shift 2 ;;
            --gpus=*)    _out+=(--gpus all); shift ;;
            # Flags without a value.
            -d|--detach|--rm|-i|-t|-it|-ti|--interactive|--tty|-P|--publish-all|--no-healthcheck)
                _out+=("$_a"); shift ;;
            --*=*)       _out+=("$_a"); shift ;;
            -*)          _out+=("$_a" "${2:-}"); shift; [ $# -gt 0 ] && shift ;;
            *)           break ;;   # the image: the rest is the container command
        esac
    done
    "$CTR_BIN" "$_sub" "${_out[@]}" "$@"
}

# stop/rm/kill: wslc takes one container per call. Options (and their values
# for -t/-s) come first, then the containers. Returns 1 if any call failed.
_wslc_each() {
    local _sub="$1"; shift
    local _opts=() _id _rc=0
    while [ $# -gt 0 ] && [[ "$1" == -* ]]; do
        case "$1" in
            -t|--time|-s|--signal) _opts+=("$1" "${2:-}"); shift; [ $# -gt 0 ] && shift ;;
            *) _opts+=("$1"); shift ;;
        esac
    done
    for _id in "$@"; do
        "$CTR_BIN" "$_sub" "${_opts[@]}" "$_id" || _rc=1
    done
    return "$_rc"
}

# load: `-i <file>` passes through (path converted); a tar on stdin — gzipped
# or not, as docker load accepts both — is spooled to a temp file first.
_wslc_load() {
    if [ "${1:-}" = "-i" ] || [ "${1:-}" = "--input" ]; then
        "$CTR_BIN" load -i "$(_ctr_host_file "$2")"
        return
    fi
    local _tmp _rc=0
    _tmp=$(_ctr_mktemp) || return 1
    gzip -dcf > "$_tmp" || { rm -f "$_tmp"; return 1; }
    "$CTR_BIN" load -i "$(_ctr_host_file "$_tmp")" || _rc=$?
    rm -f "$_tmp"
    return "$_rc"
}

# --- [ QUERY HELPERS ] --------------------------------------------------------
# Docker branches keep the launcher's original docker commands; wslc reads
# `list -a --format json` (one object per container, fields ID, Names, State
# with a textual value such as "running") and inspect JSON through jq.

# Usage: _wslc_container_ids <jq-select-expression> [--arg k v ...]
# wslc's list JSON differs from Docker's: one object per line rather than an
# array, "Names" (primary name, aliases comma-separated) rather than "Name",
# "ID" rather than "Id", and a textual "State" rather than a number. Each
# object is normalized to the shape the selection expression expects —
# Name (primary), State 1 created / 2 running / 3 exited — before select.
_wslc_container_ids() {
    local _sel="$1"; shift
    "$CTR_BIN" list -a --format json 2>/dev/null | tr -d '\r' \
        | "${JQ_CMD:-jq}" -r "$@" \
            'if type == "array" then .[] else . end |
             ((.State // "") | ascii_downcase) as $s |
             {Name: ((.Names // "") | split(",")[0]),
              State: (if ($s | startswith("running")) then 2 elif ($s | startswith("exited")) then 3 else 1 end),
              Id: (.ID // "")} | select('$_sel') | .Id' 2>/dev/null
}

# Usage: ctr_container_running <name> — true if a container with exactly
# this name is running.
ctr_container_running() {
    if runtime_is_wslc; then
        [ -n "$(_wslc_container_ids '.Name == $n and .State == 2' --arg n "$1")" ]
    else
        [ -n "$(docker ps -q -f "name=^/${1}$" 2>/dev/null)" ]
    fi
}

# Usage: ctr_container_exists <name> — true if a container with exactly this
# name exists in any state.
ctr_container_exists() {
    if runtime_is_wslc; then
        [ -n "$(_wslc_container_ids '.Name == $n' --arg n "$1")" ]
    else
        [ -n "$(docker ps -aq -f "name=^/${1}$" 2>/dev/null)" ]
    fi
}

# Usage: ctr_list_containers <name-prefix> <running|exited|all>
# Prints the IDs of containers whose name starts with <name-prefix>.
ctr_list_containers() {
    local _prefix="$1" _state="${2:-running}"
    if runtime_is_wslc; then
        local _st=""
        case "$_state" in
            running) _st=' and .State == 2' ;;
            exited)  _st=' and .State == 3' ;;
        esac
        _wslc_container_ids "(.Name | startswith(\$p))$_st" --arg p "$_prefix"
    else
        case "$_state" in
            running) docker ps -q --filter "name=^/${_prefix}" 2>/dev/null ;;
            exited)  docker ps -aq --filter "status=exited" --filter "name=^/${_prefix}" 2>/dev/null ;;
            *)       docker ps -aq --filter "name=^/${_prefix}" 2>/dev/null ;;
        esac
    fi
}

# Usage: ctr_containers_from_image <image> [running|all]
# Prints the IDs of containers created from <image>.
ctr_containers_from_image() {
    local _all=-a
    [ "${2:-all}" = "running" ] && _all=""
    if runtime_is_wslc; then
        "$CTR_BIN" list $_all -q -f "ancestor=$1" 2>/dev/null | tr -d '\r'
    else
        docker ps $_all -q --filter "ancestor=$1" 2>/dev/null
    fi
}

# Usage: ctr_inspect_field <object> <field>
# Container fields: image (the image it runs), exit_code, name (no leading /).
# Image fields:     id, label:<key> (empty when unset).
# Returns non-zero when the object doesn't exist.
ctr_inspect_field() {
    local _obj="$1" _field="$2"
    if runtime_is_wslc; then
        local _json _expr
        case "$_field" in
            image)     _expr='.[0].Image' ;;
            exit_code) _expr='.[0].State.ExitCode' ;;
            name)      _expr='.[0].Name' ;;
            id)        _expr='.[0].Id' ;;
            label:*)   _expr='(.[0].Config.Labels // .[0].Labels // {})[$k] // empty' ;;
            *)         return 2 ;;
        esac
        _json=$("$CTR_BIN" inspect "$_obj" 2>/dev/null | tr -d '\r') || return 1
        printf '%s' "$_json" | "${JQ_CMD:-jq}" -r --arg k "${_field#label:}" "$_expr // empty" 2>/dev/null
    else
        case "$_field" in
            image)     docker inspect -f '{{.Config.Image}}' "$_obj" 2>/dev/null ;;
            exit_code) docker inspect -f '{{.State.ExitCode}}' "$_obj" 2>/dev/null ;;
            name)      docker inspect --format '{{.Name}}' "$_obj" 2>/dev/null | tr -d '/' ;;
            id)        docker image inspect -f '{{.Id}}' "$_obj" 2>/dev/null ;;
            label:*)   docker image inspect --format "{{ index .Config.Labels \"${_field#label:}\" }}" "$_obj" 2>/dev/null ;;
            *)         return 2 ;;
        esac
    fi
}

# Usage: ctr_image_exists <image> — true if the image is in the local store.
ctr_image_exists() {
    ctr image inspect "$1" >/dev/null 2>&1
}

# Usage: ctr_image_repos — every local image's repository, one per line.
# wslc may report Docker Hub names fully qualified (docker.io/[library/]x);
# they're printed in Docker's short form so name matching works unchanged.
ctr_image_repos() {
    if runtime_is_wslc; then
        "$CTR_BIN" images --format json 2>/dev/null | tr -d '\r' \
            | "${JQ_CMD:-jq}" -r 'if type == "array" then .[] else . end | .Repository | sub("^docker\\.io/(library/)?"; "")' 2>/dev/null
    else
        docker images --format '{{.Repository}}' 2>/dev/null
    fi
}

# Usage: ctr_image_refs <repository> — every local <repository>:<tag>.
ctr_image_refs() {
    if runtime_is_wslc; then
        "$CTR_BIN" images --format json 2>/dev/null | tr -d '\r' \
            | "${JQ_CMD:-jq}" -r --arg r "$1" \
                'if type == "array" then .[] else . end | select(.Repository == $r or .Repository == ("docker.io/" + $r)) | "\($r):\(.Tag)"' 2>/dev/null
    else
        docker images --format '{{.Repository}}:{{.Tag}}' "$1" 2>/dev/null
    fi
}

# Usage: ctr_build_from_git <git-url> <ref> [docker build options...]
# Docker builds straight from the "<url>#<ref>" context. wslc only builds
# from a local directory, so the ref is fetched to a temp dir first; a
# relative -f/--file is resolved inside that checkout, as Docker resolves
# it inside the git context. The fetch goes through DOWNLOAD_PROXY when set
# (TLS unverified there, like the other host-side downloads behind the
# re-signing proxy — see _asset_curl).
ctr_build_from_git() {
    local _url="$1" _ref="$2"; shift 2
    if ! runtime_is_wslc; then
        docker build "$@" "${_url}#${_ref}"
        return
    fi
    local _dir _rc=0
    _dir=$(_ctr_mktemp) && rm -f "$_dir" && mkdir -p "$_dir" || return 1
    # wslc's git is linked against a libcurl that only offers the GnuTLS SSL
    # backend, while the session pins GIT_SSL_BACKEND=schannel, so git's http
    # transport dies before it can even connect ("Unsupported SSL backend").
    # Fetch the ref as a GitHub source tarball through curl instead; fall
    # back to a shallow clone when that route isn't available.
    local _proxy="" _tar_url="" _tgz="" _fetched=false
    [ -n "${DOWNLOAD_PROXY:-}" ] && _proxy=$(resolve_proxy_env_url)
    if [[ "$_url" == https://github.com/* ]]; then
        _tar_url="${_url%.git}"
        _tar_url="${_tar_url/github.com/codeload.github.com}/tar.gz/${_ref}"
    fi
    if [ -n "$_tar_url" ] && command -v curl >/dev/null 2>&1; then
        _tgz=$(_ctr_mktemp)
        local _curl_args=(-fsSL --connect-timeout 30 --speed-limit 1024 --speed-time 120)
        [ -n "$_proxy" ] && _curl_args+=(-x "$_proxy" -k)
        if curl "${_curl_args[@]}" -o "$_tgz" "$_tar_url" 2>/dev/null; then
            tar xzf "$_tgz" -C "$_dir" --strip-components=1 || {
                rm -rf "$_dir"; [ -n "$_tgz" ] && rm -f "$_tgz"; return 1
            }
            _fetched=true
        fi
    fi
    if [ "$_fetched" != true ]; then
        command -v git >/dev/null 2>&1 || {
            rm -rf "$_dir"; [ -n "$_tgz" ] && rm -f "$_tgz"
            echo "✘ git is needed to build from ${_url} with WSL Containers." >&2; return 1
        }
        [ -n "$_tar_url" ] && echo -e "${YELLOW:-}  Tarball fetch failed — falling back to git clone...${NC:-}" >&2
        local _git=(git -c advice.detachedHead=false)
        [ -n "${DOWNLOAD_PROXY:-}" ] && _git+=(-c "http.proxy=$DOWNLOAD_PROXY" -c http.sslVerify=false)
        # Git Bash's git.exe is a Windows program: with MSYS_NO_PATHCONV=1 (set by
        # the launch chain) a /tmp/... argument reaches it unconverted and lands
        # under <drive>:\tmp, so it gets the Windows form.
        local _clone_dir="$_dir"
        [ "${IS_GITBASH:-false}" = "true" ] && _clone_dir=$(cygpath -m "$_dir")
        # Unset GIT_SSL_BACKEND: the session can pin it to a backend this git
        # can't use (see above); the compiled-in default works.
        if ! env -u GIT_SSL_BACKEND "${_git[@]}" clone --quiet --depth 1 --branch "$_ref" "$_url" "$_clone_dir"; then
            rm -rf "$_dir"; [ -n "$_tgz" ] && rm -f "$_tgz"; return 1
        fi
    fi
    local _args=() _a
    while [ $# -gt 0 ]; do
        _a="$1"; shift
        case "$_a" in
            -f|--file)
                local _df="${1:-}"; [ $# -gt 0 ] && shift
                [[ "$_df" == /* || "$_df" == - ]] || _df="$_dir/$_df"
                [ "$_df" = - ] || _df=$(_ctr_host_file "$_df")
                _args+=("$_a" "$_df") ;;
            *) _args+=("$_a") ;;
        esac
    done
    "$CTR_BIN" build "${_args[@]}" "$(_ctr_host_file "$_dir")" || _rc=$?
    rm -rf "$_dir"; [ -n "$_tgz" ] && rm -f "$_tgz"
    return "$_rc"
}
