# AI Environment CLI Tools

This repository contains essential shell scripts for interacting with the AI Hub and managing development workflows within a Docker-based "Hub & Spoke" architecture.

## Architecture Overview

The environment uses a **Hub & Spoke** model:

- **Hub**: Centralized infrastructure providing AI capabilities, including `ai-hub-engine` (local model execution via `llama.cpp`) and `ai-hub-proxy` (unified API via `litellm`).
- **Spoke**: Individual workbench containers (`coder-<project-id>`) where your development and coding tasks occur.

## Scripts

| File | Purpose |
| --- | --- |
| `ai-coder` | Unified launcher — entry point for both Claude and OpenCode |
| `ai-coder-core.sh` | Shared infrastructure library (sourced by `ai-coder`) |
| `ai-coder-claude.sh` | Claude-specific overrides (sourced automatically when Claude is selected) |
| `ai-coder-opencode.sh` | OpenCode-specific overrides (sourced automatically when OpenCode is selected) |
| `ai-status.sh` | System health dashboard |

## Available Tools

### 1. System Health Dashboard (`ai-status.sh`)
Use this script to monitor the health of your environment.
- **Check GPU status**: Monitor utilization and VRAM.
- **Verify AI services**: Ensure `ai-hub-engine` and `ai-hub-proxy` are running.
- **Container status**: View active Docker containers.

**Usage:**
```bash
./ai-status.sh
```

### 2. Unified AI Coding Interface (`ai-coder`)
A single launcher for both Claude Code and OpenCode. On first run (or with `--menu`) it prompts you to select your preferred tool, which is saved to `~/.ai-coder-pref`. Subsequent runs launch the saved preference directly.

- **Alias**: `ai` (configure with `--setup-path`)
- **Model selection**: Automatically picks the best Gemma 4 GGUF model based on detected VRAM.
- **Auto-cleanup**: When you exit the tool, the workbench container is stopped. If it was the last active spoke, the Hub (engine + proxy) is also shut down automatically.

**Commands:**
| Command | Description |
| --- | --- |
| `spawn` | Execute the AI tool inside the active workbench container |
| `--menu` | Reset tool preference and show the selection menu |
| `--status` | Show the real-time GPU and engine status dashboard |
| `--setup-path` | Create a shell alias (`ai`) for this script |
| `--clean` | Stop and remove all Hub and Spoke containers |
| `--rebuild` | Remove the workbench image to force a full rebuild on next run |
| `--help` | Show help information |

**Usage:**
```bash
./ai-coder [COMMAND]
# or, after --setup-path:
ai [COMMAND]
```

## Customising the Workbench Image

The packages installed into each workbench container are defined in plain text files under the `packages/` directory. One package per line; lines starting with `#` are ignored.

| File | Used by |
| --- | --- |
| `packages/apt-common.txt` | Both Claude and OpenCode images |
| `packages/apt-claude.txt` | Claude image only |
| `packages/apt-opencode.txt` | OpenCode image only |

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
| OpenCode | Config, provider settings, conversation history | `.oc-stack/opencode-config/` (per project) |

Both paths are volume-mounted into the workbench container, so settings survive container restarts without rebuilding the image. The `~/.claude-config.json` file is pre-created with `{}` on first launch if it does not already exist.

## Setup

### Corporate / Proxy Networks

If your machine routes traffic through an HTTP proxy, set the `DOWNLOAD_PROXY` environment variable before running any script. It is used for:
- Downloading GGUF model files
- Pulling Docker images
- Passing proxy settings into workbench containers at build time

**Git Bash** (`~/.bash_profile`):
```bash
export DOWNLOAD_PROXY="http://proxy.corp.com:8080"
```

**WSL / Linux** (`~/.bashrc`):
```bash
export DOWNLOAD_PROXY="http://proxy.corp.com:8080"
```

Then reload your shell (`source ~/.bash_profile` or `source ~/.bashrc`) or open a new terminal.

If you are on a network without a proxy, leave `DOWNLOAD_PROXY` unset (the default).

## Troubleshooting

- **Model Loading Issues**: Run `./ai-status.sh` to check GPU availability and VRAM.
- **Tool call errors in Claude Code** (`missing parameter`): Claude Code requires llama.cpp's native Anthropic endpoint. The workbench connects directly to the engine at port 8080 (`/v1/messages`) to avoid format conversion errors.
- **Connectivity Issues**: Ensure `DOWNLOAD_PROXY` is set correctly. The scripts use `nslookup` to resolve proxy hostnames to IPs so Docker build containers can reach the proxy.
- **Shell Compatibility**: The scripts support both **WSL2** and **Git Bash** on Windows.
- **Packages changed but image not rebuilt**: Run `./ai-coder --rebuild` then `./ai-coder`.

## Agent Guidelines

If you are an AI agent working in this environment, please refer to [AGENTS.md](./AGENTS.md) for detailed operational instructions and architectural context.
