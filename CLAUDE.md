# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`ai-coder` is a bash CLI that launches AI coding tools (Claude Code, OpenCode, Aider, Gemini CLI) inside Docker containers wired up to a **local** LLM inference backend (llama.cpp via `llama-server`), so coding agents run against a self-hosted model instead of a cloud API. There is no compiled/interpreted application here — the entire project is orchestration shell scripts, Dockerfile templates generated inline, and plain-text config.

Everything targets **Windows** via **WSL2 or Git Bash**, with a secondary path for native Linux. There is no macOS support and no CI — verification is manual (source the script, exercise the relevant flag/menu against a real Docker Desktop instance).

## Architecture: Hub & Spoke

- **Hub** — shared infrastructure, one instance for the whole machine:
  - `ai-hub-engine`: llama.cpp server container running the selected GGUF model (`ghcr.io/ggml-org/llama.cpp:server-cuda`)
  - `ai-hub-proxy`: LiteLLM container providing an OpenAI-compatible endpoint, started only when the selected tool needs format translation (`NEEDS_LITELLM_PROXY`) — Claude Code talks directly to the engine's native `/v1/messages` instead, to avoid conversion errors
  - `ai-hub-webui`: optional Open WebUI sidecar for chatting with the same local model
- **Spoke** — one workbench container per project+tool, named `coder-<tool>-<project-id>`, torn down on exit. If it was the last spoke, the Hub shuts down too (unless "keep hub warm" is enabled in `--setup`).

Both are Docker containers on a shared network (`ai-engineering-net`, or `ai-engineering-isolated` when network isolation is enabled).

## Entry point and script loading order

`ai-coder` (root script) sources, in order: `libs/fixpath.sh` → `libs/ai-coder-core.sh` → `libs/ai-coder-ui.sh` → `libs/ai-coder-setup.sh` → `libs/ai-coder-menus.sh` → the selected `config/families/<family>.conf` → the selected `agents/ai-coder-<tool>.sh`. Every script assumes this sourcing order and relies on globals/functions defined earlier in the chain — none of the `libs/*.sh` or `agents/*.sh` files are meant to be run standalone.

- **`libs/ai-coder-core.sh`** — the shared infrastructure library: Docker lifecycle (`check_docker`, `build_image`, `start_hub_engine`, `run_workbench`, `ensure_workbench_running`), model selection/download (`select_model_for_vram`, `download_model`, `detect_model`), MCP config JSON generation (`make_agent_mcp_json`), VRAM/GPU helpers (`_estimate_kv_reserve_gb`, `_resolve_engine_gpu_args`, `warn_if_vram_oversubscribed`), and preference I/O (`read_pref`/`write_pref` against the `key=value` files in `user/`).
- **`config/ai-coder-model.conf`** — infra defaults that aren't tied to a model family (GPU mode, context size, KV cache type, VRAM overhead reserve, CPU offload threshold, thermal guard). Every setting follows `VAR="${VAR:-default}"` so an exported env var always wins.
- **`config/families/*.conf`** — one file per model family (Gemma 4, Qwen3, Qwen3.6, Llama 4, Devstral 2, Qwen2.5-Instruct). Each defines an ordered, best-quality-first list of `MODEL_N_*` candidates (file, URL, sha256, weight ceiling, layer count) plus family defaults (KV type, Jinja template, thinking mode, optional speculative-decoding draft). `select_model_for_vram()` walks the list and picks the first entry that fits in detected VRAM minus reserves; the CPU-offload feature can instead pick a bigger model with some layers on CPU (see the "Family Configuration Format" section of `README.md` for the exact rule — never triggers for a quant bump of the same model, only for a genuinely different model per `MODEL_N_LAYERS`). The last entry in every family must have `WEIGHTS_GB=0` as the unconditional fallback.
- **`agents/ai-coder-<tool>.sh`** — per-tool overrides implementing a fixed interface: `build_image`, `configure_workbench`, `start_workbench`, `execute_tool` (all called by the core lifecycle in `ai-coder`). `IMAGE_NAME` and `TOOL_NAME` are also set here. `agents/ai-coder-hub.sh` and `agents/ai-coder-webui.sh` are agent-free modes (hub-only, or Open WebUI) that implement the same interface minimally.
- **`libs/ai-coder-setup.sh`** — the `--setup` wizard (14 steps) and `--fix-project` (CRLF→LF normalization for a target project).
- **`libs/ai-coder-menus.sh`** — interactive family/tool/Open WebUI selection menus.
- **`libs/ai-coder-ui.sh`** — gum-based prompt helpers with a plain-text fallback (`AI_CODER_NO_GUM=1` forces plain text).
- **`libs/fixpath.sh`** — WSL path resolver for Docker Desktop bind mounts.

## Adding a new AI tool

1. Create `agents/ai-coder-<name>.sh` implementing `build_image`, `configure_workbench`, `start_workbench`, `execute_tool` (see `agents/ai-coder-claude.sh` or `agents/ai-coder-opencode.sh` as templates), setting `IMAGE_NAME` and `TOOL_NAME`.
2. Add `packages/apt-<name>.txt` and, if the tool supports MCP, `packages/mcp-<name>.txt`.
3. Register the tool in `libs/ai-coder-menus.sh`'s selection menu.
4. Add a "Config Persistence" row to `README.md` if the tool has its own config/auth state that needs a host volume mount.

## Adding a new model family

Copy an existing `config/families/*.conf` (e.g. `qwen3.conf`), keep the guard-against-double-sourcing block, fill in `MODEL_FAMILY`, `MODEL_N_*` candidates ordered best-quality-first with a `WEIGHTS_GB=0` fallback last, and set `MODEL_N_LAYERS` for any tier that should be reachable via partial CPU offload. No code changes to `libs/` are needed — family confs are read at launch time only.

## Config persistence model

Runtime state lives under `user/` (gitignored) as flat `key=value` files read/written via `read_pref`/`write_pref` in `libs/ai-coder-core.sh`:
- `user/settings.conf` — all `--setup` choices (proxy, GPU mode, context level, KV type, MCP extras, keep-hub, model volume, speculative decoding, port exposure, git identity, etc.)
- `user/state.conf` — session state (tool/family/webui preference, update-check cache, running-engine settings used to detect when the engine needs a restart)
- `user/.setup-done` — sentinel gating first launch

Per-tool config (Claude's `~/.claude-config*`, OpenCode's `.ai-coder/opencode/opencode-config/`, Aider's `~/.aider-config/`, Gemini's `~/.gemini-config/`) is volume-mounted into the workbench container by each agent's `configure_workbench`/`start_workbench`, so it survives container restarts without an image rebuild. `README.md`'s "Config Persistence" table is the source of truth for exact paths.

## Rebuild vs. no-rebuild changes

Whether a change needs `./ai-coder --rebuild` depends on whether it touches the Docker image build (apt packages, MCP npm/pip installs, base image, git identity) versus something read at launch time (model family/tier, `config/*.conf` settings, MCP server args, GPU mode, most `--setup` toggles). See the full table in `README.md` under "Customising the Workbench Image" before assuming a change needs a rebuild — most don't.

## Package/MCP server manifests

`packages/apt-*.txt` and `packages/mcp-*.txt` are plain pipe-delimited text (see `README.md`'s "MCP Servers" section for the exact field format), split into `mcp-common.txt` (always registered) and `mcp-extra.txt` (opt-in via `--setup` — kept separate because every registered server's schema is injected into every model request, which measurably hurts small local models' tool selection).

## Testing / verification

There is no automated test suite or CI. `test_*` files are gitignored, implying ad-hoc local test scripts are expected to stay untracked. To verify a change:
- `bash -n <script>.sh` (or open in an editor with shellcheck) to catch syntax errors — `libs/ai-coder-core.sh` and `offline/unbundle.sh` are explicitly annotated with `# shellcheck source=/dev/null` where dynamic sourcing defeats static analysis.
- Exercise the actual flag/menu path against a real Docker Desktop instance (`./ai-coder --setup`, `./ai-coder --status`, `./ai-coder --menu`, etc.) — most logic is Docker/GPU state machine behavior that can't be meaningfully unit tested.
- All scripts run under `set -euo pipefail`; preserve that discipline (explicit `|| true` / `|| return` at call sites that intend to tolerate failure) when adding code.

## Key runtime conventions

- Every tunable is `VAR="${VAR:-default}"` so an exported env var always overrides both the family conf and `config/ai-coder-model.conf` — preserve this pattern for new settings rather than hardcoding.
- Windows path handling is centralized: `to_host_path()` converts a path for `-v` mounts depending on shell (WSL passes through, Git Bash uses `cygpath -m`), and `WIN_HOME` is resolved once so WSL and Git Bash share the same host directories (`~/ai-models`, `~/.ai-coder-env`, etc.).
- The `cleanup()` trap in `ai-coder` (EXIT/INT/TERM) is the single place that decides whether to stop the workbench and/or the Hub — don't add a second exit path that bypasses it.
