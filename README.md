# AI Environment CLI Tools

This repository contains essential shell scripts for interacting with the AI Hub and managing development workflows within a Docker-based "Hub & Spoke" architecture.

## Architecture Overview

The environment uses a **Hub & Spoke** model:

- **Hub**: Centralized infrastructure providing AI capabilities, including `ai-hub-engine` (local model execution via `llama.cpp`) and `ai-hub-proxy` (unified API via `litellm`).
- **Spoke**: Individual workbench containers (`coder-<project-id>`) where your development and coding tasks occur.

## Scripts

| File | Purpose |
| --- | --- |
| `ai-coder` | Unified launcher — entry point for all AI coding tools |
| `libs/ai-coder-core.sh` | Shared infrastructure library (sourced by `ai-coder`) |
| `libs/ai-coder-graphics.sh` | Shared ANSI color and icon palette (sourced by core and status) |
| `config/ai-coder-model.conf` | Model framework config — GPU mode, inference settings, VRAM tier thresholds |
| `config/families/gemma4.conf` | Gemma 4 family config — model names, download URLs, display labels per tier |
| `config/families/qwen3.conf` | Qwen3 family config — model names, download URLs, display labels per tier |
| `config/families/qwen3.6.conf` | Qwen3.6 family config — 27B dense + 35B-A3B MoE (released April 2026) |
| `config/families/llama4.conf` | Llama 4 family config — Scout 17B×16E (10M context, consumer-feasible) |
| `config/families/devstral2.conf` | Devstral 2 family config — 24B coding-specialist (SWE-Bench 68.0%) |
| `agents/ai-coder-claude.sh` | Claude Code overrides (sourced automatically when Claude is selected) |
| `agents/ai-coder-opencode.sh` | OpenCode overrides (sourced automatically when OpenCode is selected) |
| `agents/ai-coder-aider.sh` | Aider overrides (sourced automatically when Aider is selected) |
| `agents/ai-coder-gemini.sh` | Gemini CLI overrides (sourced automatically when Gemini is selected) |
| `ai-status.sh` | System health dashboard |
| `offline/bundle.sh` | Offline bundle creator — packages scripts, Docker images, and a model for air-gapped deployment |
| `offline/unbundle.sh` | Offline bundle installer — loads a bundle onto an isolated target machine |

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
A single launcher for Claude Code, OpenCode, Aider, and Gemini CLI. On first run (or with `--menu`) it prompts you to select your preferred tool, which is saved to `~/.ai-coder-pref`. Subsequent runs launch the saved preference directly.

- **Alias**: `ai` (configure with `--setup`)
- **Model family selection**: On first run, prompts you to choose a model family (Gemma 4, Qwen3, Qwen3.6, Llama 4, Devstral 2, …). The choice is saved to `~/.ai-coder-family`. Within the chosen family, the best GGUF tier is selected automatically based on detected VRAM.
- **Tool selection**: On first run, also prompts for your preferred coding tool (Claude, OpenCode, Aider, Gemini). Saved to `~/.ai-coder-pref`.
- **Workspace mount**: Your project folder is mounted into the container as `/<foldername>` (e.g. `/my-project`), so the AI tool starts directly in your project directory.
- **Auto-cleanup**: When you exit the tool, the workbench container is stopped. If it was the last active spoke, the Hub (engine + proxy) is also shut down automatically.
- **Agent-free commands**: `--help`, `--status`, `--clean`, and `--setup` run immediately without requiring a tool to be selected.

**Commands:**
| Command | Description |
| --- | --- |
| `spawn` | (or no argument) Launch the AI tool inside the active workbench container |
| `--menu` | Reset model family **and** tool preferences; show both selection menus |
| `--status` | Show the real-time GPU and engine status dashboard |
| `--setup` | Register shell alias, configure proxy, and set network isolation preference |
| `--clean` | Stop and remove all Hub and Spoke containers |
| `--rebuild` | Remove the workbench image to force a full rebuild on next run |
| `--build-only` | Build the workbench image then exit (no Hub or agent launch) |
| `--gpu-mode` | Reset GPU mode preference and be prompted again on next run |
| `--help` | Show help information |

**Usage:**
```bash
./ai-coder [COMMAND]
# or, after --setup:
ai [COMMAND]
```

## Multi-GPU Support

When two or more NVIDIA GPUs are present, `ai-coder` detects them on first run and asks whether to use all cards for inference:

```
◈ 2 GPUs detected. Use all GPUs for inference? [Y/n]:
```

| Mode | Behaviour |
| --- | --- |
| **multi** (default) | All GPUs exposed to the engine container. `--tensor-split` is set automatically using each card's VRAM as proportional weights, so both compute *and* VRAM are distributed across GPUs. |
| **single** | Only GPU 0 is exposed (`--gpus device=0`). VRAM tier selection is also scoped to GPU 0 so the right model size is chosen. Useful when secondary GPUs are used for display output or other workloads. |

The choice is saved to `~/.ai-coder-gpuconf`. To change it later:

```bash
./ai-coder --gpu-mode   # clears saved preference; re-prompts on next run
```

You can also override the preference for a single session without changing the saved value:

```bash
GPU_MODE=single ./ai-coder
```

## Customising the Workbench Image

The packages installed into each workbench container are defined in plain text files under the `packages/` directory. One package per line; lines starting with `#` are ignored.

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

## Config Persistence

| Tool | What is persisted | Host path |
| --- | --- | --- |
| Claude Code | Conversation history, sessions, telemetry | `~/.claude-config/` (directory) |
| Claude Code | First-run preferences, accepted permissions, settings | `~/.claude-config.json` (file) |
| OpenCode | Config, provider settings | `.ai-coder/opencode/opencode-config/` (per project) |
| Aider | Git identity, aider config, input history | `~/.aider-config/` (directory) |
| Gemini CLI | Auth tokens, session state, settings | `~/.gemini-config/` (directory) |
| ai-coder | Saved tool preference | `~/.ai-coder-pref` |
| ai-coder | Saved model family preference | `~/.ai-coder-family` |
| ai-coder | GPU mode preference (single/multi) | `~/.ai-coder-gpuconf` |
| ai-coder | Saved proxy URL | `~/.ai-coder-proxy` |
| ai-coder | Network isolation preference | `~/.ai-coder-netconfig` |
| ai-coder | Git identity (name + email) | `~/.ai-coder-gitconfig` |

All paths are volume-mounted into the workbench container, so settings survive container restarts without rebuilding the image. The `~/.claude-config.json` file is pre-created with `{}` on first launch if it does not already exist.

## Setup

### Shell Alias, Proxy & Network Isolation

Run `--setup` once after installation. It registers the `ai` shell alias, prompts for a proxy URL, and asks whether to enable network isolation for containers:

```bash
./ai-coder --setup
# → adds alias to ~/.bash_profile / ~/.bashrc / ~/.zshrc
# → prompts: Proxy URL: http://proxy.corp.com:8080
# → prompts: Isolate containers? [y/N]
# then: source ~/.bash_profile   # or ~/.bashrc
```

**Proxy**: The URL is saved to `~/.ai-coder-proxy` and automatically applied on every subsequent run for downloading GGUF model files, pulling Docker images, and passing proxy settings into workbench containers at build time. Leave blank for no proxy.

**Network isolation**: When enabled, all containers (engine, proxy, workbench) are placed on a Docker `--internal` network with no internet access. Proxy env vars are also stripped from the workbench in this mode to avoid interference. Setting saved to `~/.ai-coder-netconfig`.

To change either setting, run `--setup` again.

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
- **Connectivity Issues**: Ensure `DOWNLOAD_PROXY` is set correctly. The scripts use `nslookup` to resolve proxy hostnames to IPs so Docker build containers can reach the proxy.
- **Shell Compatibility**: The scripts support both **WSL2** and **Git Bash** on Windows.
- **Packages changed but image not rebuilt**: Run `./ai-coder --rebuild` then `./ai-coder`.

---

Licensed under the [MIT License](LICENSE). &copy; 2026 George Gilman — ggilman@gmail.com

