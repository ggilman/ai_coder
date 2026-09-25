# AI Environment CLI Tools

This repository contains essential shell scripts for interacting with the AI Hub and managing development workflows within a Docker-based "Hub & Spoke" architecture.

## Architecture Overview

The environment uses a **Hub & Spoke** model:

- **Hub**: Centralized infrastructure providing AI capabilities, including `ai-hub-engine` (local model execution via `llama.cpp` or, optionally, SGLang — see [Inference Engine](#inference-engine-llamacpp-or-sglang)) and `ai-hub-proxy` (unified API via `litellm`).
- **Spoke**: Individual workbench containers (`coder-<tool>-<project-id>`) where your development and coding tasks occur.

## Scripts

| File | Purpose |
| --- | --- |
| `install.sh` | Bootstrap installer — downloads and installs ai-coder from the `release` branch |
| `ai-coder` | Unified launcher — entry point for all AI coding tools |
| `libs/ai-coder-core.sh` | Shared infrastructure library (sourced by `ai-coder`) |
| `libs/ai-coder-graphics.sh` | Shared ANSI color and icon palette (sourced by core and status) |
| `config/ai-coder-model.conf` | Model framework config — GPU mode, inference settings, VRAM tier thresholds |
| `config/families/gemma4.conf` | Gemma 4 family config — model tiers (names, URLs, weights, SHA256) and optional speculative decoding draft |
| `config/families/qwen3.conf` | Qwen3 family config — model tiers (names, URLs, weights, SHA256) and speculative decoding draft |
| `config/families/qwen3.6.conf` | Qwen3.6 family config — 27B dense + 35B-A3B MoE (released April 2026) |
| `config/families/qwen3.6-reap.conf` | Qwen3.6 REAP family config — 28B-A3B MoE, 20% expert-pruned from Qwen3.6-35B-A3B for lower VRAM at higher quant precision |
| `config/families/qwen3.8.conf` | Qwen3.8 family config — 27B dense across 8 quant tiers (released August 2026) |
| `config/families/llama4.conf` | Llama 4 family config — Scout 17B×16E (10M context, consumer-feasible) |
| `config/families/devstral2.conf` | Devstral 2 family config — 24B coding-specialist (SWE-Bench 68.0%) |
| `config/families/gptoss20b.conf` | gpt-oss-20b family config — OpenAI 21B-A3.6B MoE, native MXFP4, Apache 2.0 |
| `config/families/glm4.7flash.conf` | GLM-4.7-Flash family config — Zhipu 31B-A3B MoE, local coding-agent focused |
| `agents/ai-coder-claude.sh` | Claude Code overrides (sourced automatically when Claude is selected) |
| `agents/ai-coder-opencode.sh` | OpenCode overrides (sourced automatically when OpenCode is selected) |
| `agents/ai-coder-aider.sh` | Aider overrides (sourced automatically when Aider is selected) |
| `agents/ai-coder-gemini.sh` | Gemini CLI overrides (sourced automatically when Gemini is selected) |
| `agents/ai-coder-qwencode.sh` | Qwen Code overrides (sourced automatically when Qwen Code is selected) |
| `agents/ai-coder-goose.sh` | Goose overrides (sourced automatically when Goose is selected) |
| `agents/ai-coder-hub.sh` | Hub-only mode — starts the engine without a coding tool; press any key to stop |
| `agents/ai-coder-webui.sh` | Open WebUI mode — starts the engine + Open WebUI chat interface at `localhost:3000` |
| `libs/ai-coder-sglang.sh` | SGLang engine support — Hugging Face snapshot download, tensor-parallel sizing, engine launch args (sourced by core) |
| `libs/ai-coder-commands.sh` | One-shot CLI commands: `--fix-project`, `--update`, `--version`, `--doctor`, `--logs` (sourced by `ai-coder`) |
| `libs/ai-coder-menus.sh` | Interactive family and tool selection menus (sourced by `ai-coder`) |
| `libs/ai-coder-setup.sh` | Setup wizard for `--setup` (sourced by `ai-coder`) |
| `libs/ai-coder-ui.sh` | Setup wizard UI helpers — gum dialogs with a plain-read fallback (sourced by `ai-coder`) |
| `libs/fixpath.sh` | WSL path resolver — converts Docker Desktop bind mounts to native WSL paths |
| `ai-status.sh` | System health dashboard |
| `offline/bundle.sh` | Offline bundle creator — packages scripts, Docker images, and a model for air-gapped deployment |
| `offline/unbundle.sh` | Offline bundle installer — loads a bundle onto an isolated target machine |
| `prompts/` | Agent instructions assembled at launch — see [Agent Instructions](#agent-instructions) |

## Family Configuration Format

Each family configuration file in `config/families/` defines an ordered candidate list (best quality first) and family-specific defaults.

**Core Variables:**
- `MODEL_COUNT`: Total number of candidates.
- `MODEL_N_FILE`: GGUF filename under `MODEL_STORAGE_DIR`, prefixed with the family's own subfolder (e.g. `qwen3.6/Qwen3.6-...gguf`) so families that happen to share a quant filename (like Qwen3.6 vs. Qwen3.6 MTP) never collide in the download cache.
- `MODEL_N_URL`: Direct download URL.
- `MODEL_N_DESC`: Human-readable label shown in logs and menus.
- `MODEL_N_SHA256`: Expected sha256 (blank = skip verification).
- `MODEL_N_WEIGHTS_GB`: Ceiling of model file size in GB; `0` = unconditional fallback.
- `MODEL_N_LAYERS`: Total transformer layer count (HF `config.json` `num_hidden_layers`). Optional; required for the entry to be reachable via partial CPU offload (see below).
- `MODEL_N_KV` / `MODEL_N_KV_SWA`: The model's KV cache geometry — cache elements per token as `<K>/<V>` over full-context layers, and `<K>/<V>@<window>` over sliding-window layers (which only ever cache the last `<window>` tokens). Optional, and never hand-written: `./ai-coder --kv-probe <family|all> --write` reads them from each tier's GGUF metadata header with a ranged HTTP request (no model download). KV size depends on the base model's architecture, not its quant, and one family's tiers often mix base models with KV costs several times apart, so each tier gets its own. Tiers without them fall back to the family's `MODEL_KV_BYTES_PER_TOKEN` (a q8_0 bytes-per-token estimate, default 96 KiB). SGLang candidates get the same fields (`MODEL_SGL_N_KV`/`MODEL_SGL_N_KV_SWA`, plus `MODEL_SGL_N_MAX_CTX`), read from the repo's `config.json` and laid out the way SGLang sizes its KV pool — see the field reference in `config/ai-coder-model.conf`.

The launcher normally picks the first (best) entry whose `WEIGHTS_GB` plus its own KV cache (at the chosen context size and KV cache type) fits in effective VRAM with all layers on GPU. After a fresh engine start, the launcher compares the KV cache size llama.cpp logs against that estimate and warns if it's more than 10% larger; `--status` shows the measured size. Under SGLang, which fills whatever VRAM is left with KV cache, it instead warns when that pool can't hold one full-length context. With partial CPU offload enabled (default), an entry ranked higher can win instead when at least the configured percentage of it fits (default 90%) — llama.cpp then runs the shortfall's worth of layers on the CPU (`-ngl` below the full count). This only happens between genuinely different models (detected by differing `MODEL_N_LAYERS`), never to reach a higher quant of the same model — each percent of layers on CPU costs roughly 9% generation speed, which is a bad trade for a quant bump.

**Speculative Decoding (Optional):**
- `MODEL_SPEC_STRATEGY`: `none` (external draft file via `--model-draft`, no `--spec-type` flag), `ngram` (hash-based, no draft file needed), or `mtp` (`--spec-type draft-mtp`, forces `--parallel 1`). Usually paired with draft heads baked into the main GGUF (no `MODEL_DRAFT_FILE`, e.g. Qwen3.6 MTP) — skipped automatically when the GGUF has no MTP layers; Qwen3.8 is the one exception pairing `mtp` with a real external `MODEL_DRAFT_FILE`.
- `MODEL_SPEC_DRAFT_N_MAX`: `--spec-draft-n-max` value for `MODEL_SPEC_STRATEGY=mtp` families (default 3) — verify against the specific model's docs rather than assuming the default fits.
- `MODEL_DRAFT_FILE`: Draft GGUF filename. With `MODEL_SPEC_STRATEGY=mtp` and this set (Qwen3.8), the `spec_decode` setting also gates whether the mtp flags are passed at all — see `libs/ai-coder-workbench.sh`.
- `MODEL_DRAFT_URL`: Direct download URL.
- `MODEL_DRAFT_SHA256`: Expected sha256 (blank = skip verification).
- `MODEL_DRAFT_VRAM_GB`: VRAM reserved for the draft in tier selection (default 1).

**SGLang Candidates (Optional):** a family runs under the [SGLang engine](#inference-engine-llamacpp-or-sglang) only if it defines this second, separate candidate list of Hugging Face repos. Same best-first order and `WEIGHTS_GB=0` fallback rule; no CPU offload.
- `MODEL_SGL_COUNT`: Total number of SGLang candidates.
- `MODEL_SGL_TOOL_PARSER`: SGLang `--tool-call-parser` (e.g. `qwen25`, `gpt-oss`, `mistral`, `llama3`). Required for agents — without it tool calls come back as plain text.
- `MODEL_SGL_REASONING_PARSER`: SGLang `--reasoning-parser` (e.g. `qwen3`, `gpt-oss`); blank for non-reasoning models.
- `MODEL_SGL_N_REPO`: Hugging Face repo id (`owner/name`), downloaded to `~/ai-models/sglang/<owner>--<name>/`.
- `MODEL_SGL_N_REVISION`: Commit hash to pin (blank = `main`) — the repo equivalent of the GGUF list's sha256 check.
- `MODEL_SGL_N_DESC`: Human-readable label shown in logs and menus.
- `MODEL_SGL_N_WEIGHTS_GB`: Ceiling of the repo's weight size in GB; `0` = unconditional fallback.
- `MODEL_SGL_N_QUANT`: Optional `--quantization` override (normally auto-detected from the repo's `config.json`).
- `MODEL_SGL_N_OVERRIDE_ARGS`: Optional JSON passed as `--json-model-override-args`, patching the repo's `config.json` at load time (nested objects merge into sub-configs) — for checkpoints SGLang misreads.
- `MODEL_SGL_N_PATCH`: Optional name of a bash snippet in `config/sglang-patches/` (without `.sh`), run inside the engine container before `launch_server` to work around an SGLang bug for this model. Snippets should do nothing once upstream fixes the bug.
- `MODEL_SGL_N_SIZE_GB`: Optional, for the `WEIGHTS_GB=0` fallback entry: its real size. SGLang can't offload to CPU, so the launcher warns up front when even the fallback won't fit.

**Family Defaults:**
- `MODEL_FAMILY`: Display name in the selection menu.
- `MODEL_KV_TYPE`: KV cache quantization (e.g., `q8_0`, `q4_0`). Applied to both K and V unless the `--model` KV cache choice overrides it (`MODEL_KV_TYPE_V` overrides the V side alone).
- `MODEL_JINJA`: Enable model's built-in Jinja template.
- `MODEL_THINKING`: Family default for reasoning tokens (`true`/`false`; e.g., for the Qwen3 family). The *Thinking mode* question in `--model` overrides it.
- `MODEL_SAMPLING` / `MODEL_SAMPLING_NOTHINK`: Engine sampling defaults from the model card, as `key=value` pairs (e.g. `temp=0.6 top_p=0.95 top_k=20 min_p=0`); the second applies when thinking is off. See [Sampling defaults per family](#sampling-defaults-per-family).

## Available Tools

### 1. System Health Dashboard (`ai-status.sh`)
Use this script to monitor the health of your environment.
- **Check GPU status**: Monitor utilization and VRAM.
- **Verify AI services**: Ensure `ai-hub-engine` and `ai-hub-proxy` are running.
- **Network status**: Shows whether containers are running in isolated or standard network mode.

**Usage:**
```bash
./ai-status.sh
```

### 2. Unified AI Coding Interface (`ai-coder`)
A single launcher for Claude Code, OpenCode, Aider, Gemini CLI, Qwen Code, and Goose. Model configuration is done once via `--model` (which asks for the model family, tool, Open WebUI, and all model-sizing settings and saves them to `user/state.json` and `user/settings.json`). A plain `ai-coder` launch verifies the configuration is complete and launches the saved preference directly; if it isn't complete it stops and tells you to run `--model` first.

- **Alias**: `ai` (configure with `--setup`)
- **Model family selection**: `--model` prompts you to choose a model family (Gemma 4, Qwen3, Qwen3.6, Llama 4, Devstral 2, …). Within the chosen family, the best GGUF tier is selected automatically from detected VRAM **minus an estimated KV-cache reserve** for your chosen context level **and a per-GPU overhead reserve** (CUDA context, compute buffers, display usage — `MODEL_VRAM_OVERHEAD_GB`) — so the model actually fits instead of silently paging to system RAM. If the reserves cost you a tier, the launcher says so; choose a smaller context level (or a lower overhead reserve) in `--model` to unlock the bigger model.
- **Tool selection**: `--model` also prompts for your preferred coding tool (Claude, OpenCode, Aider, Gemini, Qwen Code, Goose). Both choices are saved to `user/state.json`.
- **Gum-powered menus**: Family, tool, and Open WebUI prompts (asked during `--model`) render as [gum](https://github.com/charmbracelet/gum) pickers, same as `--setup`. Falls back to plain numbered/text prompts if gum can't be installed or run (or with `AI_CODER_NO_GUM=1`).
- **Open WebUI sidecar**: If host port exposure is enabled in `--setup`, `--model` asks whether to also start Open WebUI (`http://localhost:3000`) alongside your coding agent, so you can chat with the same local model while you code. The answer is saved like the other preferences. It shuts down together with the Hub.
- **Workspace mount**: Your project folder is mounted into the container as `/<foldername>` (e.g. `/my-project`), so the AI tool starts directly in your project directory.
- **Auto-cleanup**: When you exit the tool, the workbench container is stopped. If it was the last active spoke, the Hub (engine + proxy) is also shut down automatically — unless the *keep hub warm* setting is enabled (`--setup`), which leaves the engine loaded so the next session starts in seconds. A warm hub auto-stops after a configurable idle timeout (default 60 min, `0` = never) to release GPU VRAM; stop it immediately with `--clean`.
- **Agent-free commands**: `--help`, `--status`, `--clean`, `--rebuild`, `--model`, `--family`, `--kv-probe`, `--speed`, and `--setup` run immediately without requiring a tool to be selected.
- **Setup required**: `--setup` must be run at least once before launching. This ensures all preferences are configured intentionally.

**Commands:**
| Command | Description |
| --- | --- |
| (no argument) | Launch the AI tool inside the active workbench container |
| `--continue` | Resume the previous agent session — passes the tool's native continue flag (`--continue` for Claude/OpenCode/Aider, `--resume` for Gemini/Qwen Code/Goose) |
| `--model` | Configure the model: model family, tool, Open WebUI, the model-sizing preferences (context level, KV cache, VRAM overhead, CPU offload threshold / SGLang memory fraction) and thinking mode. A plain launch verifies these are set and stops with "run `--model`" if not |
| `--family [family]` | Dry-run model tier selection: hardware audit, VRAM reserves, and which tier a launch would pick — no Docker, no launch |
| `--kv-probe [family\|all] [--write]` | Read each tier's KV cache geometry — from its GGUF metadata header for llama.cpp (local file or a ranged download — never the whole model), from its repo's `config.json` for SGLang — and compare the resulting KV size with the conf's current estimate; `--write` records it in the family conf (`MODEL_N_KV`/`MODEL_N_KV_SWA`, `MODEL_SGL_N_*`) |
| `--speed [family]` | Generation-speed benchmark: run `llama-bench` on your model on a clean GPU and print tokens/s (requires the *generation speed tracking* setup option; llama.cpp engine only) |
| `--status` | Show the real-time GPU and engine status dashboard |
| `--setup` | First-time and re-configuration wizard: alias, proxy, network isolation, inference engine, GPU mode, git identity |
| `--update` | Download and install the latest release from GitHub (refused in a git checkout — use `git pull` there — unless `--update --force`) |
| `--fix-project` | Normalize line endings in the current project folder for AI editing (run once per project) |
| `--clean` | Stop and remove all Hub and Spoke containers |
| `--rebuild` | Remove all workbench images (and the locally built asymmetric-KV llama.cpp image) to force a full rebuild on next run |
| `--build-only` | Build the workbench image then exit (no Hub or agent launch) |
| `--help` | Show help information |

**Usage:**
```bash
./ai-coder [COMMAND]
# or, after --setup:
ai [COMMAND]
```

## Inference Engine (llama.cpp or SGLang)

The Hub engine can run on either of two inference servers, chosen in `--setup` (the *Inference engine* step, saved as `engine` in `user/settings.json`):

| | **llama.cpp** (default) | **SGLang** |
| --- | --- | --- |
| Model format | GGUF files | Hugging Face repos (AWQ / GPTQ / FP8 / MXFP4 safetensors) |
| Families | All | Only families that define `MODEL_SGL_*` candidates — currently **Gemma 4**, **Qwen3.8**, **Qwen3**, **Qwen 2.5 Coder**, and **gpt-oss-20b** (Qwen3.8's smallest SGLang build is ~19.5 GB, so it needs a ~24 GB+ GPU) |
| Image | `ghcr.io/ggml-org/llama.cpp:server-cuda-<LLAMA_CPP_VERSION>` (pinned) | `lmsysorg/sglang:v0.5.20-runtime` (~15 GB; CUDA 13, so Blackwell / RTX 50-series works) |
| Multi-GPU | Uneven `--tensor-split` by free VRAM | Even tensor parallel (`--tp`), power-of-two GPU count |
| CPU offload, speculative decoding, `--speed` | Yes | No — hidden in `--setup`/`--model` and skipped |
| VRAM sizing | Overhead reserve (`--model`) | Memory fraction (`--model`, default 0.85) — SGLang pre-allocates that share of each GPU for weights + KV pool |
| KV cache option (`--model`) | Family default (`q8_0`), asymmetric `q8_0` K / `q4_0` V ([locally built image](#asymmetric-kv-cache)), or `q4_0` | FP8 (`fp8_e4m3`) — one dtype for K and V, no asymmetric mode |

Both engines listen on the same port (8080) and serve the OpenAI `/v1` and Anthropic `/v1/messages` APIs, so every agent, Open WebUI and the status dashboard work unchanged. Claude Code additionally gets `CLAUDE_CODE_ATTRIBUTION_HEADER=0` under SGLang so its prefix cache is reused across turns.

Notes:
- **Switching engines** in `--setup` clears the saved model family, so the next launch shows the family menu for the new engine. A warm Hub restarts automatically on the next launch.
- **Downloads**: SGLang models are fetched with `huggingface_hub` inside the SGLang image into `~/ai-models/sglang/<owner>--<name>/` (resumable; a `.ai-coder-complete` marker is written last). Gated repos need `HF_TOKEN` — put it in `~/.ai-coder-env`. The engine itself runs with `HF_HUB_OFFLINE=1`, so network isolation still works.
- **Context**: SGLang refuses a context longer than the model was trained for, so the chosen level is capped at the model's `max_position_embeddings` (e.g. 40,960 for Qwen3).
- **Overrides**: `ENGINE_BACKEND=sglang|llamacpp` for one session, `SGLANG_IMAGE` for a different image tag, and `SGL_EXTRA_ARGS` for any other `sglang.launch_server` flags.
- Offline bundles (`offline/bundle.sh`) are llama.cpp-only for now.

### Asymmetric KV cache

The *asymmetric* KV cache option in `--model` keeps keys at `q8_0` and stores values at `q4_0`, which uses about 25% less KV VRAM than `q8_0`/`q8_0` for much less quality loss than `q4_0`/`q4_0` (keys are the quantization-sensitive side).

llama.cpp only compiles CUDA Flash Attention kernels for the K/V pairs listed in its `GGML_CUDA_FA_QUANTS` build option. The default list is `q4_0-q4_0;q8_0-q8_0;f16-f16;bf16-bf16`, so on the stock `server-cuda` image a mismatched pair falls back to a much slower path. Choosing asymmetric therefore builds a local image, `ai-coder/llama.cpp:server-cuda-asym-<version>`, the first time it's needed:

- It runs llama.cpp's own `.devops/cuda.Dockerfile` straight from GitHub (no local checkout), adds `q8_0-q4_0` to the kernel list, and compiles only for the GPU architectures `nvidia-smi` reports.
- The build is one-time and usually takes 10–30 minutes. It runs before the Hub starts; a second session launched meanwhile waits for it. nvcc needs a lot of memory, so if the build is killed for running out of memory, give Docker Desktop more RAM.
- It builds the same pinned llama.cpp release the stock images use (`LLAMA_CPP_VERSION` in `libs/ai-coder-core.sh`, overridable by exporting it), so every KV mode runs identical llama.cpp. Bumping the version pulls new stock images and builds a new asym image on the next launch; `--rebuild` removes the asym image (every version's tag) to force a rebuild. `--doctor` shows which llama.cpp release the image was built from.
- It needs internet access, so it won't build with network isolation on. An image built earlier (or loaded from an offline bundle, which includes it when present) still works.
- The q8_0/q8_0 and q4_0/q4_0 options keep using the stock image.

## Multi-GPU Support

When two or more NVIDIA GPUs are present, `--setup` will ask whether to use all cards for inference. Single-GPU machines skip this question automatically.

| Mode | Behaviour |
| --- | --- |
| **multi** (default) | All GPUs exposed to the engine container. `--tensor-split` is set automatically using each card's VRAM as proportional weights, so both compute *and* VRAM are distributed across GPUs. Under SGLang, `--tp` splits evenly across a power-of-two number of GPUs instead, so the smallest card sets the per-GPU budget. |
| **single** | Only GPU 0 is exposed (`--gpus device=0`). VRAM tier selection is also scoped to GPU 0 so the right model size is chosen. Useful when secondary GPUs are used for display output or other workloads. |

The choice is saved to `user/settings.json`. To change it, run `./ai-coder --setup` again.

You can also override the preference for a single session without changing the saved value:

```bash
GPU_MODE=single ./ai-coder
```

## Model Storage

Models are downloaded once to `~/ai-models` on the host (Windows home on WSL/Git Bash, so both shells share the folder). That folder is the download cache and source of truth — `bundle.sh` and re-downloads use it. Each family stores its GGUFs under its own subfolder (e.g. `~/ai-models/qwen3.6/`, `~/ai-models/qwen3.6MTP/`) so families that happen to share a quant filename never collide.

**Fast model storage** (`--setup`, default **on** for WSL/Git Bash): the engine loads the model from a Docker named volume (`ai-coder-models`) instead of bind-mounting `~/ai-models`. On Windows hosts the bind mount goes through Docker Desktop's slow filesystem bridge, so reading a 5–27 GB GGUF on every engine cold start can take minutes; the named volume lives on the Docker VM's native disk and loads several times faster.

How it works:
- On engine start, the active model is copied into the volume **once per model** (with a progress ticker). Later starts skip the copy after a quick size check.
- Previously synced models are **retained** in the volume — switching family or tier keeps the old models cached so switching back is instant. Note this hidden disk usage inside the Docker VM grows with each model you use; reclaim it by removing the volume (below).
- If the sync fails for any reason, the engine falls back to the direct host folder mount automatically.
- On native Linux the setting defaults to **off** (bind mounts are already fast).

Reclaim the volume's disk space at any time (models remain in `~/ai-models`):

```bash
./ai-coder --clean          # ensure the engine is stopped
docker volume rm ai-coder-models
```

## Speculative Decoding

When enabled (`--setup`, default **on**), the engine loads a small *draft model* alongside the main model. The draft cheaply proposes several tokens at a time; the main model verifies them in a single pass and keeps the ones it agrees with. Code is highly predictable, so acceptance rates are high — typically **1.5–2× faster generation** with identical output quality (verification guarantees the result matches what the main model would have produced alone).

Details:
- Only applies to model families that define an external draft in their family conf (`MODEL_DRAFT_FILE`/`URL`). Currently: **Qwen3** (Qwen3-0.6B, ~0.6 GB — drafts for every tier since the whole family shares one tokenizer, `MODEL_SPEC_STRATEGY=none`) and **Qwen3.8** (a small companion draft-head file from the same upstream repo, `MODEL_SPEC_STRATEGY=mtp` — this pairing hasn't been verified against a live llama.cpp run; if it errors on startup, switch that family's `MODEL_SPEC_STRATEGY` to `none`). Other families note in their conf why no draft is wired.
- Separately, **Qwen3.6 MTP** bakes its MTP draft heads into the main GGUF (no `MODEL_DRAFT_FILE`) and always uses them regardless of this setting — there's no toggle for it, and it forces `--parallel 1` since MTP doesn't support concurrent requests. `MODEL_SPEC_DRAFT_N_MAX` (default 3) tunes the draft depth per family when needed.
- The draft is downloaded once (checksum-verified), synced into the fast-storage volume alongside the main model, and reserved (~1-2 GB, `MODEL_DRAFT_VRAM_GB`) in the VRAM tier calculation.
- If the draft can't be downloaded, the session degrades gracefully to normal decoding.
- Toggling the setting takes effect at the next launch via an automatic engine restart.

To judge the benefit on your hardware, run the same task with the setting on and off (`--setup`, then reopen a session) and compare tokens/sec in the engine logs or the feel of long generations.

## Agent Instructions

ai-coder gives every coding tool a short set of working rules, written for small local models: read a file before editing it, re-read after a failed edit, emit the tool call instead of describing it, don't invent APIs, keep replies short. The text lives in `prompts/` and is assembled at each launch:

| File | Included |
| --- | --- |
| `prompts/common.md` | Always. `{workspace}` becomes the container workspace path |
| `prompts/offline.md` | When network isolation is on |
| `prompts/families/<family>.md` | For that family (named after its conf, e.g. `gptoss20b.md`), for known model quirks |
| `prompts/tools/<tool>.md` | For that tool |
| `prompts/tools/<tool>-mcp-extras.md` | For that tool, when MCP extras is on |

Every file after `common.md` continues its bullet list, so write them as `- ` bullets. Keep them short: each tool sends the text with every request, so it costs context the same way registered MCP tools do.

Each tool gets the text through its own instructions mechanism:

| Tool | Delivered as | Project instructions |
| --- | --- | --- |
| Claude Code | `--append-system-prompt-file` (`~/.claude-config/ai-coder-prompt.md`) | Claude runs with `--bare`, which skips CLAUDE.md discovery, so the project's `CLAUDE.md` (or else `AGENTS.md`) is appended to the same file at launch |
| OpenCode | `instructions` in `opencode.json` | OpenCode reads `AGENTS.md` itself |
| Aider | `read:` in `.aider.conf.yml` | The project's `AGENTS.md`, `CONVENTIONS.md` or `CLAUDE.md` (first found) is added as a read-only file |
| Gemini CLI | `~/.gemini-config/GEMINI.md` | Gemini reads the project's `GEMINI.md` itself |
| Qwen Code | `~/.qwen-config/QWEN.md` | Qwen Code reads the project's `QWEN.md` itself |
| Goose | `~/.goose-config/.goosehints` | Goose reads the project's `.goosehints` itself |

Generated files start with an `<!-- ai-coder: ... -->` marker line. A same-named file without it (for example your own `GEMINI.md`) is never overwritten or deleted; ai-coder warns and skips its instructions for that tool instead. Turn the feature off with *Agent instructions* in `--setup`, which also removes the generated files on the next launch. Editing `prompts/` needs no rebuild. `--update` replaces the shipped prompt files, so keep your own changes in new files (e.g. a family file) or re-apply them after updating.

### Sampling defaults per family

Prompt wording matters less to small models than sampling settings do, and every model vendor publishes its own. Each family conf sets `MODEL_SAMPLING` (and, for Qwen, `MODEL_SAMPLING_NOTHINK` for thinking-off mode) from its model card, and the engine starts with those as its defaults (`--temp`, `--top-p`, `--top-k`, `--min-p`, `--presence-penalty`). Without them, llama-server uses generic defaults (temperature 0.8) for every model. They are only defaults: a tool that sends its own value in the request wins. Aider sends temperature 0 unless told otherwise, so when a family sets sampling, ai-coder writes an Aider model settings file that stops it. Changing a family's sampling restarts the engine on the next launch. Override one session with, e.g., `MODEL_SAMPLING="temp=0.3" ./ai-coder`. llama.cpp only.

### Model-card and tool settings

Besides sampling, family confs can carry other settings from the model card:

- `MODEL_REASONING_PRESERVE`: keep earlier turns' reasoning in the prompt. Qwen3.6 and Qwen3.8 recommend this for agent work, so those families turn it on; everything else drops old reasoning to save context. When it's on, OpenCode is also configured to send its past reasoning back (`reasoning` + `interleaved` in `opencode.json`), because it drops it otherwise.
- `MODEL_CHAT_TEMPLATE_KWARGS`: options for the model's chat template, passed as `--chat-template-kwargs` (e.g. Qwen3.6's `{"preserve_thinking":true}`). Ignored for families running with `MODEL_JINJA=false`.
- `MODEL_MAX_OUTPUT`: the longest reply the model card recommends, capped at a quarter of the context size.

Each tool is also told about the local model where it has a setting for it:

| Tool | Settings passed |
| --- | --- |
| Claude Code | `CLAUDE_CODE_ATTRIBUTION_HEADER=0` (keeps the engine's prompt cache working across turns), `CLAUDE_CODE_MAX_CONTEXT_TOKENS` (the real context size, so it compacts in time), `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` |
| OpenCode | `limit.output`, and the reasoning send-back above |
| Aider | Model settings: diff edits and repo map (Aider's own settings for local coding models), no temperature when the family sets sampling |
| Gemini CLI | The LiteLLM proxy drops the temperature/top_p/top_k Gemini CLI sends, so the family's sampling applies |
| Qwen Code | `QWEN_CODE_MAX_OUTPUT_TOKENS` |
| Goose | `GOOSE_CONTEXT_LIMIT` (the real context size), `GOOSE_MAX_TOKENS` |

## Customising the Workbench Image

### When does a rebuild apply changes?

A rebuild (`./ai-coder --rebuild` followed by `./ai-coder`) is only needed when the Docker image itself must change. Many settings take effect immediately on the next launch without any rebuild (except for Git identity).

| Operation | Rebuild required? | Notes |
| --- | :---: | --- |
| Add / remove an apt package (`apt-*.txt`) | **Yes** | Packages are installed during the image build |
| Add / remove an MCP server (`mcp-*.txt`) — new npm or pip package | **Yes** | Packages are `npm install -g` / `pip install`'d during the image build |
| Change MCP server args or `{workspace}` substitution | No | Config is regenerated fresh on every launch |
| Enable/disable MCP extras (`--setup`) | No | Extra servers are pre-installed in every image; registration is decided per launch |
| Change an MCP env var value (e.g. `BRAVE_API_KEY`) | No | Value is read from your shell at launch time |
| Change model family or VRAM tier | No | Model is loaded by the engine container at runtime |
| Change `config/ai-coder-model.conf` settings | No | Read at launch time |
| Edit agent instructions (`prompts/*.md`) or a family's `MODEL_SAMPLING` | No | Instructions are rendered at launch; a sampling change restarts the engine |
| Add a new model family config (`config/families/*.conf`) | No | Read at launch time |
| Change GPU mode (`--setup`) | No | Passed as flags when the engine container starts |
| Toggle fast model storage (`--setup`) | No | Engine restarts with the new mount on next launch |
| Toggle speculative decoding (`--setup`) | No | Engine restarts with/without the draft model on next launch |
| Change the KV cache type (`--model`) | No | Engine restarts with the new KV cache type on next launch; the first switch to asymmetric builds llama.cpp locally (one time) |
| Switch inference engine (`--setup`) | No | Engine restarts on the new server on next launch; the workbench images are engine-independent |
| Change SGLang memory fraction, FP8 KV cache or thinking mode (`--model`) | No | Engine restarts with the new value on next launch |
| Change proxy or network isolation (`--setup`) | No | Applied at container start time |
| Change git identity (`--setup`) | **Yes** | Requires an `--rebuild` to bake into the image |
| Upgrade `BASE_IMAGE` in `ai-coder-core.sh` | **Yes** | The base layer must be pulled and rebuilt |
| Change the Dockerfile template in `build_standard_image` | **Yes** | Modifies the image build instructions |
| Change an agent's `configure_workbench` function | No | Config files are written to a host-mounted volume at launch |
| Change an agent's `start_workbench` / `run_workbench` flags | No | Flags are applied when the container is started |

### APT Packages

The apt packages installed into each workbench container are defined in plain text files under the `packages/` directory. One package per line; lines starting with `#` are ignored.

| File | Used by |
| --- | --- |
| `packages/apt-common.txt` | All agent images |
| `packages/apt-claude.txt` | Claude image only |
| `packages/apt-opencode.txt` | OpenCode image only |
| `packages/apt-aider.txt` | Aider image only |
| `packages/apt-gemini.txt` | Gemini CLI image only |
| `packages/apt-qwencode.txt` | Qwen Code image only |
| `packages/apt-goose.txt` | Goose image only |

To add a package, edit the relevant file and then force a rebuild:

```bash
echo "htop" >> packages/apt-common.txt
./ai-coder --rebuild
./ai-coder
```

### MCP Servers

MCP (Model Context Protocol) servers extend what the AI agent can do — web search, shell execution, database access, git operations, and more. They are configured in pipe-delimited text files under `packages/`.

| File | Used by |
| --- | --- |
| `packages/mcp-common.txt` | Core servers — always registered for all MCP-capable agents (Claude, OpenCode, Gemini, Qwen Code, Goose) |
| `packages/mcp-extra.txt` | Optional servers — installed in all images, but only registered when *MCP extras* is enabled in `--setup` |
| `packages/mcp-claude.txt` | Claude image only |
| `packages/mcp-opencode.txt` | OpenCode image only |
| `packages/mcp-gemini.txt` | Gemini CLI image only |
| `packages/mcp-qwencode.txt` | Qwen Code image only |
| `packages/mcp-goose.txt` | Goose image only — rendered into goose's YAML `extensions:` format instead of the JSON `mcpServers` the other agents use (see note below) |

> **Why the core/extra split?** Every registered server's tool schemas are injected into the model's context on **every request**. A long tool list slows prompt processing and makes small local models measurably worse at choosing the right tool. Core covers day-to-day coding (git, shell — every agent brings its own file tools); enable the extras only if you use them. Toggling extras takes effect on the next launch — no rebuild needed, because extra servers are always pre-installed in the images.

#### File format

```
npm-package | server-key | command | arg1 arg2 ... | ENV_VAR1,ENV_VAR2 | net
```

| Field | Required | Description |
| --- | --- | --- |
| `npm-package` | Yes | npm package name to install (`npm install -g`). Prefix with `pip:` for PyPI packages. |
| `server-key` | Yes | Unique JSON key used to identify this server in the generated config. |
| `command` | Yes | The executable to run (e.g. `mcp-server-git`, `npx`). |
| `arg1 arg2 ...` | No | Space-separated arguments. Use `{workspace}` as a placeholder for the container workspace path. |
| `ENV_VAR1,ENV_VAR2` | No | Comma-separated list of env var references. Two forms are supported: **bare name** (`MY_KEY`) expands the value from your host shell; **`NAME=value`** sets a literal value (supports `{workspace}` substitution). |
| `net` | No | Set to `online` to skip this server when network isolation is active. Leave blank for servers that work fully offline. |

Lines starting with `#` and blank lines are ignored.

> **Goose is the one exception.** It doesn't accept the Claude/Gemini-style JSON `mcpServers` config, so `_goose_mcp_extension_yaml()` in `agents/ai-coder-goose.sh` renders the same pipe-delimited files (walked by the shared `_mcp_each_server` in `libs/ai-coder-env.sh`) into goose's YAML `extensions:` block instead. The file format above is identical — only the agent-side renderer differs.

#### Core servers (`mcp-common.txt`) — always registered

| Server | Key | What it does |
| --- | --- | --- |
| `mcp-server-git` | `git` | Git operations (status, diff, add, commit) within the workspace |
| `cli-mcp-server` | `shell` | Execute shell commands (cmake, make, ctest, bash scripts) scoped to the workspace |

#### Optional servers (`mcp-extra.txt`) — enable via `--setup` → MCP extras

| Server | Key | What it does |
| --- | --- | --- |
| `@modelcontextprotocol/server-filesystem` | `filesystem` | Whole-file read/write and multi-block edits — off by default because it duplicates each agent's own file tools, and small models confuse the two schemas |
| `@modelcontextprotocol/server-memory` | `memory` | Persistent knowledge graph — survives across sessions within the container lifetime |
| `@modelcontextprotocol/server-sequential-thinking` | `thinking` | Structured multi-step problem decomposition |
| `conan-mcp` | `conan` | Manage C++ Conan dependencies, search Conan Center, check CVEs |
| `@upstash/context7-mcp` | `context7` | Fetch accurate, version-pinned library docs on demand — add `use context7` to any prompt |
| `@brave/brave-search-mcp-server` | `brave-search` | Web search and news — requires `BRAVE_API_KEY` in your shell environment |
| `@modelcontextprotocol/server-github` | `github` | GitHub issues, PRs, code search, file CRUD — requires `GITHUB_PERSONAL_ACCESS_TOKEN` |
| `mcp-server-fetch` | `fetch` | HTTP fetch for retrieving web pages and API responses |
| `mcp-server-time` | `time` | Current time and timezone conversion |

#### Adding an npm MCP server

```
# packages/mcp-common.txt
@some-org/some-mcp-server | my-tool | some-mcp-server | --some-arg {workspace}
```

Then rebuild:

```bash
./ai-coder --rebuild && ./ai-coder
```

#### Adding a pip MCP server

Prefix the package name with `pip:`:

```
pip:some-mcp-package | my-tool | some-mcp-server | --flag
```

#### Adding a server that needs an API key

Pass the environment variable **name** in the 5th field. Set the variable in your shell before launching:

```
@some-org/some-mcp-server | my-tool | npx | -y @some-org/some-mcp-server | MY_API_KEY
```

```bash
export MY_API_KEY=your-key-here
./ai-coder
```

The value is read from your environment at launch and embedded in the generated config. It is never stored on disk by ai-coder itself.

#### Adding a binary MCP server (e.g. Gitea MCP)

Some servers ship as compiled binaries rather than npm/pip packages. For those:

1. Download the binary and place it somewhere on your host (e.g. `~/.ai-coder/gitea-mcp`).
2. Mount it into the container by adding a `-v` flag to `run_workbench` in the relevant agent script (e.g. `agents/ai-coder-opencode.sh`).
3. Add the entry to the appropriate `mcp-*.txt` file using a placeholder package name and the binary as the command.

See the documented example in `packages/mcp-opencode.txt` for the full Gitea MCP setup.

#### Agent-specific servers

To add a server only for one agent, edit that agent's file instead of `mcp-common.txt`:

```bash
# OpenCode only
echo "@some-org/server | key | cmd | args" >> packages/mcp-opencode.txt
./ai-coder --rebuild && ./ai-coder
```

## Config Persistence

| Tool | What is persisted | Host path |
| --- | --- | --- |
| Claude Code | Conversation history, sessions, telemetry | `~/.claude-config/` (directory) |
| Claude Code | First-run preferences, accepted permissions, settings | `~/.claude-config.json` (file) |
| OpenCode | Config, provider settings | `~/.opencode-config/` (directory) |
| Aider | Aider config, input history | `~/.aider-config/` (directory) |
| Gemini CLI | Auth tokens, session state, settings | `~/.gemini-config/` (directory) |
| Qwen Code | Auth tokens, session state, settings | `~/.qwen-config/` (directory) |
| Goose | Config, provider settings, MCP extensions | `~/.goose-config/` (directory) |
| ai-coder | **All settings** — proxy, isolation, GPU mode, context level, KV cache type, VRAM overhead, CPU offload threshold, MCP extras, keep-hub, model volume, speculative decoding, speed tracking, port exposure, git identity | `<install-dir>/user/settings.json` |
| ai-coder | **Runtime state** — tool + family + Open WebUI preferences, update-check hash/timestamp, running-engine settings | `<install-dir>/user/state.json` |
| ai-coder | Setup completion sentinel | `<install-dir>/user/.setup-done` |
| ai-coder | Git identity mounted into containers as `/root/.gitconfig` | `~/.gitconfig-container` |
| ai-coder | Downloaded GGUF models (download cache) | `~/ai-models/` (Windows home on WSL/Git Bash) |
| ai-coder | Active model fast-storage cache | Docker volume `ai-coder-models` |
| ai-coder | **Session env vars** (API keys, secrets) | `~/.ai-coder-env` (WSL: Windows home) |

Agent config paths are volume-mounted into the workbench container, so settings survive container restarts without rebuilding the image. The `~/.claude-config.json` file is pre-created on first launch if it does not already exist. The `user/` directory lives inside the install directory and is preserved across `--update`.

### Session environment file (`~/.ai-coder-env`)

If `~/.ai-coder-env` exists, it is sourced automatically at the start of every `ai-coder` launch. This is the recommended place for API keys and other secrets that should be available to the agent session but are not appropriate for your shell profile. **On WSL**, the file is read from the Windows home directory (e.g. `C:\Users\<you>\.ai-coder-env`) so it is shared between Git Bash and WSL sessions.

Example `~/.ai-coder-env`:
```bash
export BRAVE_API_KEY=your-key-here
export SOME_OTHER_API_KEY=another-key
```

The file is plain bash, so any valid shell syntax works. Variables set here are available to all MCP server config generation (e.g. the `BRAVE_API_KEY` env var field in `mcp-extra.txt`). The path can be overridden with the `AI_CODER_ENV_FILE` environment variable.

## Installation

### Install (`install.sh`)

Run this one-liner to download and install ai-coder (installs to `~/ai-coder` by default):

```bash
curl -fsSL https://raw.githubusercontent.com/ggilman/ai_coder/release/install.sh | bash
```

If you are behind a proxy, use the `-x` flag with `curl`:

```bash
curl -x http://your-proxy:8080 -fsSL https://raw.githubusercontent.com/ggilman/ai_coder/release/install.sh | bash
```

To choose a different location, pass the path after `--`:

```bash
# Install to a specific directory
curl -fsSL https://raw.githubusercontent.com/ggilman/ai_coder/release/install.sh | bash -s -- ~/tools/ai-coder

# Install into the current directory
curl -fsSL https://raw.githubusercontent.com/ggilman/ai_coder/release/install.sh | bash -s -- .
```

After installation, run `--setup` to configure the tool:

```bash
~/ai-coder/ai-coder --setup
```

### Updating (`--update`)

Once installed, keep ai-coder up to date with:

```bash
ai --update
# or, without the alias:
~/ai-coder/ai-coder --update
```

ai-coder also checks for updates automatically once per day on launch and prints a notice if a new version is available on the `release` branch.

Git checkouts are tracked through git itself: `--version` reports the local `origin/release` ref (which `git push origin release` keeps current) and the daily check compares the release head against your `HEAD`, so publishing `release` from your own checkout never leaves a stale "update available" notice. The `release_hash` recorded in `user/state.json` is only used for tarball installs.

---

## Setup

### Setup (`--setup`)

**`--setup` must be run once before first launch.** It walks through up to thirteen configuration steps — which ones depends on the inference engine you choose, since options one engine doesn't use are not shown. On first run the installer downloads [gum](https://github.com/charmbracelet/gum) — a CLI tool for beautiful interactive prompts — and uses it for the wizard on both WSL and Git Bash. If gum is unavailable it falls back to plain text prompts. Either way the questions and defaults are the same:

```bash
./ai-coder --setup
```

1. **Shell alias** — optionally adds an `ai` shortcut to your rc file. Skip if you prefer to manage your PATH yourself. Any previously added alias is removed if you decline.
2. **Proxy** — enter an HTTP proxy URL, or leave blank for none.
3. **Network isolation** — optionally block all internet access from containers.
4. **Inference engine** — llama.cpp (default) or SGLang. See [Inference Engine](#inference-engine-llamacpp-or-sglang).
5. **GPU mode** — only shown when 2+ GPUs are detected; choose multi (all GPUs) or single.
6. **MCP extras** — register the optional MCP servers (memory, thinking, conan, context7, brave-search, github, fetch, time) with each agent. Off by default: fewer registered tools means faster prompts and better tool selection on small local models.
7. **Agent instructions** — give each coding tool a short set of working rules from `prompts/` (see [Agent Instructions](#agent-instructions)). On by default.
8. **Keep hub warm** — leave the engine loaded after the last session exits so the next launch skips the model load. Also asks for an idle timeout (default 60 min, `0` = forever) after which the warm hub stops itself to release VRAM; stop it immediately with `--clean`.
9. **Fast model storage** — cache models in a Docker volume so engine cold starts load from the VM's native disk instead of the slow Windows filesystem bridge. Default on for WSL/Git Bash; see [Model Storage](#model-storage).
10. **Speculative decoding** *(llama.cpp)* — use a small draft model to speed up generation, typically 1.5–2× on code. Default on; costs ~1 GB VRAM and applies only to families that define a draft (currently Qwen3). See [Speculative Decoding](#speculative-decoding).
11. **Generation speed tracking** *(llama.cpp)* — off by default. Enables the `--speed` command: a one-shot `llama-bench` pass on your model on a clean GPU that prints tokens-per-second (tg = generation, pp = prompt processing).
12. **Host port exposure** — optionally publish the engine on `localhost:8080` so external apps can connect directly. Enabling this also unlocks the [Open WebUI sidecar](#2-unified-ai-coding-interface-ai-coder) question on the next launch.
13. **Git identity** — name and email used for commits made inside the container. Falls back to your host global git config if already set.

Settings that change which model tier fits in VRAM are deliberately not wizard steps — `--model` asks them instead (along with the model family, tool, and Open WebUI), and a plain launch verifies they are set:

- **Context window level** — 4k–256k, default 64k.
- **KV cache** — llama.cpp: family default `q8_0`, [asymmetric](#asymmetric-kv-cache) `q8_0` K / `q4_0` V, or `q4_0`. SGLang: optional FP8 (off by default).
- **VRAM overhead reserve** *(llama.cpp)* — GB of VRAM held back for CUDA context, compute buffers and other apps on the GPU when sizing the model tier (default 1 GB). Raise it if the engine logs `failed to fit` or slows down from memory spilling to system RAM.
- **CPU offload threshold** *(llama.cpp)* — run a bigger model with a few layers on CPU when at least this percentage of it fits in VRAM (default 90, range 50–99, `0` disables). At 90% the worst case is roughly half generation speed; only fires for a genuinely bigger model, never for a higher quant of the same one. See [Family Configuration Format](#family-configuration-format).
- **SGLang memory fraction** *(SGLang)* — share of each GPU's VRAM SGLang pre-allocates for model + KV cache (default 0.85, range 0.50–0.95). Lower it if the GPU also drives your display.

`--model` also asks one question that doesn't affect sizing but is worth revisiting per model:

- **Thinking mode** *(llama.cpp)* — family default, on, or off. Reasoning models write a block of reasoning before every reply and tool call: better planning on hard tasks, but each agent turn produces many more tokens and takes longer. Off passes `--reasoning-budget 0`. When it's on, earlier turns' reasoning is dropped from the prompt (`--no-reasoning-preserve`) so it doesn't use up context, except for Qwen3.6 and Qwen3.8, whose model cards recommend keeping it for agent work (`MODEL_REASONING_PRESERVE`; see [Model-card and tool settings](#model-card-and-tool-settings)). The family default is on for the Qwen families and gpt-oss, off for GLM-4.7-Flash. (Under SGLang thinking is a per-request option, so there's no engine-level switch.)

In gum mode, pressing **Esc** or **Cancel** on any step keeps that setting unchanged and moves to the next question — nothing is lost mid-wizard. To force the plain-text prompts even where gum is installed, set `AI_CODER_NO_GUM=1`.

After completing setup, if you added the alias:

```bash
source ~/.bash_profile   # Git Bash
# or
source ~/.bashrc         # WSL / Linux (bash)
# or
source ~/.zshrc          # WSL / Linux (zsh)
```

To change any setting, run `--setup` again — except for the model-sizing settings listed above (context level, KV cache, VRAM overhead, CPU offload, SGLang memory fraction), which are re-prompted by `--model` instead.

## Offline / Air-Gapped Deployment

The `offline/` directory contains two scripts for deploying ai-coder onto machines with no internet access.

### Creating a bundle (`offline/bundle.sh`)

Run on the **source machine** (internet-connected):

```bash
cd ai_coder
./offline/bundle.sh
```

It will prompt for:
1. **Model family** — which family conf to use (e.g. Devstral 2)
2. **VRAM tier** — which quantization level to include

Bundles are llama.cpp-only: if your engine is set to SGLang, the script says so and packages the llama.cpp engine and a GGUF model anyway (the installed copy starts on llama.cpp).

The script then downloads the selected model (if not already cached), saves all required Docker images as `.tar.gz` archives, copies all project scripts (including `config/families/`), and writes a `bundle.manifest`. Everything lands in `bundle/`.

It also fetches both platform builds of [gum](https://github.com/charmbracelet/gum) and ships them at `scripts/.assets/` — since the target has no internet access to fetch gum itself, this is what gives it the same gum-powered prompts as the source machine (`--setup`, `--model`, `--status`, and `unbundle.sh`'s own prompts) instead of falling back to plain text.

Transfer the entire `bundle/` folder to the target machine (USB drive, internal file share, etc.).

### Installing a bundle (`offline/unbundle.sh`)

Run on the **target machine** from the bundle directory:

```bash
cd /path/to/bundle
./unbundle.sh
```

It will:
1. Load all Docker image archives into the local daemon
2. Copy the GGUF model to `~/ai-models/`
3. Install project scripts to a directory of your choice (default `~/ai-coder`)

No internet connection is required on the target machine.

## Troubleshooting

- **Model Loading Issues**: Run `./ai-status.sh` to check GPU availability and VRAM.
- **Tool call errors in Claude Code** (`missing parameter`): Claude Code requires the engine's native Anthropic endpoint (both llama.cpp and SGLang provide one). The workbench connects directly to the engine at port 8080 (`/v1/messages`) to avoid format conversion errors.
- **Connectivity Issues**: Ensure `DOWNLOAD_PROXY` is set correctly. The scripts use `getent`/`nslookup` to resolve proxy hostnames to IPs so Docker build containers can reach the proxy.
  > ⚠️ **Security note**: When a proxy is configured, image builds disable TLS certificate verification for apt, pip, and npm (many corporate proxies re-sign TLS traffic with an internal CA the build containers don't trust). This means packages baked into workbench images are not certificate-verified while the proxy is set. Only use a proxy you trust, and leave the proxy setting empty on networks with direct internet access.
- **Brave Search not working**: Ensure `BRAVE_API_KEY` is exported in your shell before running `./ai-coder`. Get a free key at [brave.com/search/api](https://brave.com/search/api).

- **Shell Compatibility**: The scripts support both **WSL2** and **Git Bash** on Windows.
- **Packages changed but image not rebuilt**: Run `./ai-coder --rebuild` then `./ai-coder`.
- **Claude Code "Error editing file"**: Caused by CRLF line endings in project files on Windows. Fix with:
  ```bash
  cd /your/project
  ai --fix-project
  git commit -m "chore: normalize line endings to LF"
  ```
  This adds `.gitattributes` (`eol=lf`), `.editorconfig`, and normalizes all tracked files in one step.

---

Licensed under the [MIT License](LICENSE). &copy; 2026 George Gilman — ggilman@gmail.com

