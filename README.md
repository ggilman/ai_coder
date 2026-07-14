# AI Environment CLI Tools

This repository contains essential shell scripts for interacting with the AI Hub and managing development workflows within a Docker-based "Hub & Spoke" architecture.

## Architecture Overview

The environment uses a **Hub & Spoke** model:

- **Hub**: Centralized infrastructure providing AI capabilities, including `ai-hub-engine` (local model execution via `llama.cpp`) and `ai-hub-proxy` (unified API via `litellm`).
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
| `config/families/llama4.conf` | Llama 4 family config — Scout 17B×16E (10M context, consumer-feasible) |
| `config/families/devstral2.conf` | Devstral 2 family config — 24B coding-specialist (SWE-Bench 68.0%) |
| `agents/ai-coder-claude.sh` | Claude Code overrides (sourced automatically when Claude is selected) |
| `agents/ai-coder-opencode.sh` | OpenCode overrides (sourced automatically when OpenCode is selected) |
| `agents/ai-coder-aider.sh` | Aider overrides (sourced automatically when Aider is selected) |
| `agents/ai-coder-gemini.sh` | Gemini CLI overrides (sourced automatically when Gemini is selected) |
| `agents/ai-coder-hub.sh` | Hub-only mode — starts the engine without a coding tool; press any key to stop |
| `agents/ai-coder-webui.sh` | Open WebUI mode — starts the engine + Open WebUI chat interface at `localhost:3000` |
| `libs/ai-coder-menus.sh` | Interactive family and tool selection menus (sourced by `ai-coder`) |
| `libs/ai-coder-setup.sh` | Setup wizard and `--fix-project` command (sourced by `ai-coder`) |
| `ai-status.sh` | System health dashboard |
| `offline/bundle.sh` | Offline bundle creator — packages scripts, Docker images, and a model for air-gapped deployment |
| `offline/unbundle.sh` | Offline bundle installer — loads a bundle onto an isolated target machine |

## Family Configuration Format

Each family configuration file in `config/families/` defines an ordered candidate list (best quality first) and family-specific defaults.

**Core Variables:**
- `MODEL_COUNT`: Total number of candidates.
- `MODEL_N_FILE`: GGUF filename under `MODEL_STORAGE_DIR`.
- `MODEL_N_URL`: Direct download URL.
- `MODEL_N_DESC`: Human-readable label shown in logs and menus.
- `MODEL_N_SHA256`: Expected sha256 (blank = skip verification).
- `MODEL_N_WEIGHTS_GB`: Ceiling of model file size in GB; `0` = unconditional fallback.

**Speculative Decoding (Optional):**
- `MODEL_DRAFT_FILE`: Draft GGUF filename.
- `MODEL_DRAFT_URL`: Direct download URL.
- `MODEL_DRAFT_SHA256`: Expected sha256 (blank = skip verification).
- `MODEL_DRAFT_VRAM_GB`: VRAM reserved for the draft in tier selection (default 1).

**Family Defaults:**
- `MODEL_FAMILY`: Display name in the selection menu.
- `MODEL_KV_TYPE`: KV cache quantization (e.g., `q8_0`, `q4_0`).
- `MODEL_JINJA`: Enable model's built-in Jinja template.
- `MODEL_THINKING`: Toggle reasoning tokens (e.g., for Qwen3 family).

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
A single launcher for Claude Code, OpenCode, Aider, and Gemini CLI. On first run (or with `--menu`) it prompts you to select your preferred tool, which is saved to `user/state.conf` in the install directory. Subsequent runs launch the saved preference directly.

- **Alias**: `ai` (configure with `--setup`)
- **Model family selection**: On first run, prompts you to choose a model family (Gemma 4, Qwen3, Qwen3.6, Llama 4, Devstral 2, …). Within the chosen family, the best GGUF tier is selected automatically from detected VRAM **minus an estimated KV-cache reserve** for your chosen context level — so model + context actually fit together. If the reserve costs you a tier, the launcher says so; choose a smaller context level in `--setup` to unlock the bigger model.
- **Tool selection**: On first run, also prompts for your preferred coding tool (Claude, OpenCode, Aider, Gemini). Both choices are saved to `user/state.conf`.
- **Workspace mount**: Your project folder is mounted into the container as `/<foldername>` (e.g. `/my-project`), so the AI tool starts directly in your project directory.
- **Auto-cleanup**: When you exit the tool, the workbench container is stopped. If it was the last active spoke, the Hub (engine + proxy) is also shut down automatically — unless the *keep hub warm* setting is enabled (`--setup`), which leaves the engine loaded so the next session starts in seconds. A warm hub auto-stops after a configurable idle timeout (default 60 min, `0` = never) to release GPU VRAM; stop it immediately with `--clean`.
- **Agent-free commands**: `--help`, `--status`, `--clean`, `--rebuild`, `--menu`, and `--setup` run immediately without requiring a tool to be selected.
- **Setup required**: `--setup` must be run at least once before launching. This ensures all preferences are configured intentionally.

**Commands:**
| Command | Description |
| --- | --- |
| (no argument) | Launch the AI tool inside the active workbench container |
| `--menu` | Reset model family **and** tool preferences; show both selection menus |
| `--status` | Show the real-time GPU and engine status dashboard |
| `--setup` | First-time and re-configuration wizard: alias, proxy, network isolation, GPU mode, git identity |
| `--update` | Download and install the latest release from GitHub |
| `--fix-project` | Normalize line endings in the current project folder for AI editing (run once per project) |
| `--clean` | Stop and remove all Hub and Spoke containers |
| `--rebuild` | Remove all workbench images to force a full rebuild on next run |
| `--build-only` | Build the workbench image then exit (no Hub or agent launch) |
| `--help` | Show help information |

**Usage:**
```bash
./ai-coder [COMMAND]
# or, after --setup:
ai [COMMAND]
```

## Multi-GPU Support

When two or more NVIDIA GPUs are present, `--setup` will ask whether to use all cards for inference. Single-GPU machines skip this question automatically.

| Mode | Behaviour |
| --- | --- |
| **multi** (default) | All GPUs exposed to the engine container. `--tensor-split` is set automatically using each card's VRAM as proportional weights, so both compute *and* VRAM are distributed across GPUs. |
| **single** | Only GPU 0 is exposed (`--gpus device=0`). VRAM tier selection is also scoped to GPU 0 so the right model size is chosen. Useful when secondary GPUs are used for display output or other workloads. |

The choice is saved to `user/settings.conf`. To change it, run `./ai-coder --setup` again.

You can also override the preference for a single session without changing the saved value:

```bash
GPU_MODE=single ./ai-coder
```

## Model Storage

Models are downloaded once to `~/ai-models` on the host (Windows home on WSL/Git Bash, so both shells share the folder). That folder is the download cache and source of truth — `bundle.sh` and re-downloads use it.

**Fast model storage** (`--setup`, default **on** for WSL/Git Bash): the engine loads the model from a Docker named volume (`ai-coder-models`) instead of bind-mounting `~/ai-models`. On Windows hosts the bind mount goes through Docker Desktop's slow filesystem bridge, so reading a 5–27 GB GGUF on every engine cold start can take minutes; the named volume lives on the Docker VM's native disk and loads several times faster.

How it works:
- On engine start, the active model is copied into the volume **once per model** (with a progress ticker). Later starts skip the copy after a quick size check.
- Only the **active model** is kept in the volume — switching family or tier prunes the old one and syncs the new one, so hidden disk usage inside the Docker VM stays bounded at one model.
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
- Only applies to model families that define a draft in their family conf (`MODEL_DRAFT_FILE`/`URL`). Currently: **Qwen3** (Qwen3-0.6B, ~0.6 GB — drafts for every tier since the whole family shares one tokenizer). Other families note in their conf why no draft is wired.
- The draft is downloaded once (checksum-verified), synced into the fast-storage volume alongside the main model, and reserved (~1 GB, `MODEL_DRAFT_VRAM_GB`) in the VRAM tier calculation.
- If the draft can't be downloaded, the session degrades gracefully to normal decoding.
- Toggling the setting takes effect at the next launch via an automatic engine restart.

To judge the benefit on your hardware, run the same task with the setting on and off (`--setup`, then reopen a session) and compare tokens/sec in the engine logs or the feel of long generations.

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
| Add a new model family config (`config/families/*.conf`) | No | Read at launch time |
| Change GPU mode (`--setup`) | No | Passed as flags when the engine container starts |
| Toggle fast model storage (`--setup`) | No | Engine restarts with the new mount on next launch |
| Toggle speculative decoding (`--setup`) | No | Engine restarts with/without the draft model on next launch |
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
| `packages/mcp-common.txt` | Core servers — always registered for all MCP-capable agents (Claude, OpenCode, Gemini) |
| `packages/mcp-extra.txt` | Optional servers — installed in all images, but only registered when *MCP extras* is enabled in `--setup` |
| `packages/mcp-claude.txt` | Claude image only |
| `packages/mcp-opencode.txt` | OpenCode image only |
| `packages/mcp-gemini.txt` | Gemini CLI image only |

> **Why the core/extra split?** Every registered server's tool schemas are injected into the model's context on **every request**. A long tool list slows prompt processing and makes small local models measurably worse at choosing the right tool. Core covers day-to-day coding (filesystem, git, shell); enable the extras only if you use them. Toggling extras takes effect on the next launch — no rebuild needed, because extra servers are always pre-installed in the images.

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

#### Core servers (`mcp-common.txt`) — always registered

| Server | Key | What it does |
| --- | --- | --- |
| `mcp-server-git` | `git` | Git operations (status, diff, add, commit) within the workspace |
| `@modelcontextprotocol/server-filesystem` | `filesystem` | Reliable whole-file read/write across the workspace |
| `cli-mcp-server` | `shell` | Execute shell commands (cmake, make, ctest, bash scripts) scoped to the workspace |

#### Optional servers (`mcp-extra.txt`) — enable via `--setup` → MCP extras

| Server | Key | What it does |
| --- | --- | --- |
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
| OpenCode | Config, provider settings | `.ai-coder/opencode/opencode-config/` (per project) |
| Aider | Aider config, input history | `~/.aider-config/` (directory) |
| Gemini CLI | Auth tokens, session state, settings | `~/.gemini-config/` (directory) |
| ai-coder | **All settings** — proxy, isolation, GPU mode, context level, MCP extras, keep-hub, model volume, speculative decoding, port exposure, git identity | `<install-dir>/user/settings.conf` |
| ai-coder | **Runtime state** — tool + family preference, update-check hash/timestamp, running-engine settings | `<install-dir>/user/state.conf` |
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

---

## Setup

### Setup (`--setup`)

**`--setup` must be run once before first launch.** It walks through up to eleven configuration steps:

```bash
./ai-coder --setup
```

1. **Shell alias** — optionally adds an `ai` shortcut to your rc file. Skip if you prefer to manage your PATH yourself. Any previously added alias is removed if you decline.
2. **Proxy** — enter an HTTP proxy URL, or leave blank for none.
3. **Network isolation** — optionally block all internet access from containers.
4. **GPU mode** — only shown when 2+ GPUs are detected; choose multi (all GPUs) or single.
5. **Context window level** — how many tokens of context the model retains (4k–256k, default 64k). Higher values use more VRAM and slow responses; local coding agents rarely benefit past 64k.
6. **MCP extras** — register the optional MCP servers (memory, thinking, conan, context7, brave-search, github, fetch, time) with each agent. Off by default: fewer registered tools means faster prompts and better tool selection on small local models.
7. **Keep hub warm** — leave the engine loaded after the last session exits so the next launch skips the model load. Also asks for an idle timeout (default 60 min, `0` = forever) after which the warm hub stops itself to release VRAM; stop it immediately with `--clean`.
8. **Fast model storage** — cache the active model in a Docker volume so engine cold starts load from the VM's native disk instead of the slow Windows filesystem bridge. Default on for WSL/Git Bash; see [Model Storage](#model-storage).
9. **Speculative decoding** — use a small draft model to speed up generation, typically 1.5–2× on code. Default on; costs ~1 GB VRAM and applies only to families that define a draft (currently Qwen3). See [Speculative Decoding](#speculative-decoding).
10. **Host port exposure** — optionally publish the engine on `localhost:8080` so external apps (e.g. Open WebUI) can connect directly.
11. **Git identity** — name and email used for commits made inside the container. Falls back to your host global git config if already set.

After completing setup, if you added the alias:

```bash
source ~/.bash_profile   # Git Bash
# or
source ~/.bashrc         # WSL / Linux (bash)
# or
source ~/.zshrc          # WSL / Linux (zsh)
```

To change any setting, run `--setup` again.

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

The script then downloads the selected model (if not already cached), saves all required Docker images as `.tar.gz` archives, copies all project scripts (including `config/families/`), and writes a `bundle.manifest`. Everything lands in `bundle/`.

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
- **Tool call errors in Claude Code** (`missing parameter`): Claude Code requires llama.cpp's native Anthropic endpoint. The workbench connects directly to the engine at port 8080 (`/v1/messages`) to avoid format conversion errors.
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

