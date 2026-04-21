# AI Environment CLI Tools

This repository contains essential shell scripts for interacting with the AI Hub and managing development workflows within a Docker-based "Hub & Spoke" architecture.

## Architecture Overview

The environment uses a **Hub & Spoke** model:

- **Hub**: Centralized infrastructure providing AI capabilities, including `ai-hub-engine` (local model execution via `llama.cpp`) and `ai-hub-proxy` (unified API via `litellm`).
- **Spoke**: Individual workbench containers (`coder-<project-id>`) where your development and coding tasks occur.

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

### 2. AI Coding Interface (`ai-coder.sh`)
The standard interface for AI-assisted coding tasks. It automatically handles model selection based on available VRAM.
- **Alias**: `claude`

**Commands:**
| Command | Description |
| --- | --- |
| `spawn` | Execute `claude` inside the active workbench container |
| `--status` | Show the real-time GPU and engine status dashboard |
| `--setup-path` | Automatically create a shell alias for this script |
| `--clean` | Stop and remove all Hub and Project containers |
| `--help` | Show help information |

**Usage:**
```bash
./ai-coder.sh [COMMAND]
# or
claude [COMMAND]
```

### 3. OpenCode CLI Interface (`ai-coder-oc.sh`)
A specialized version of the coding interface optimized for OpenCode-specific workflows.
- **Alias**: `oc`

**Commands:**
| Command | Description |
| --- | --- |
| `spawn` | Execute `opencode` inside the active workbench container |
| `--status` | Show the real-time GPU and engine status dashboard |
| `--setup-path` | Automatically create a shell alias for this script |
| `--clean` | Stop and remove all Hub and Project containers |
| `--help` | Show help information |

**Usage:**
```bash
./ai-coder-oc.sh [COMMAND]
# or
oc [COMMAND]
```

## Troubleshooting

- **Model Loading Issues**: If a model fails to load, run `./ai-status.sh` to check GPU availability and VRAM.
- **Connectivity Issues**: If you encounter network errors, ensure your environment's proxy settings are correctly configured. The scripts are designed to work with `crane` or `curl.exe` in corporate environments.
- **Shell Compatibility**: The scripts support both **WSL** and **GitBash**.

## Agent Guidelines

If you are an AI agent working in this environment, please refer to [AGENTS.md](./AGENTS.md) for detailed operational instructions and architectural context.
