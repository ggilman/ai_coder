# Agent Operational Guidelines

## Environment Architecture
This environment uses a **Hub & Spoke** model via Docker:
- **Hub**: Shared infrastructure containers (`ai-hub-engine` via llama.cpp and `ai-hub-proxy` via litellm).
- **Spoke**: Project-specific workbench containers named `coder-<project-id>`.

## Core Tools & Commands
- **Health Monitoring**: Run `./ai-status.sh` to check GPU utilization, VRAM, AI service status, and container health.
- **AI Coding (Claude)**: Use `./ai-coder.sh` (alias: `claude`). 
    - `claude spawn`: Enters the active workbench container to run `claude-code`.
- **OpenCode CLI**: Use `./ai-coder-oc.sh` (alias: `oc`).
    - `oc spawn`: Enters the active workbench container to run `opencode`.
- **Cleanup**: Use `--clean` with either script to stop and remove all Hub and Spoke containers.

## Operational Gotchas
- **Shell Compatibility**: Scripts are optimized for **WSL2** and **GitBash**.
- **Model Management**: LLM models are stored in `$HOME/ai-models`.
- **Troubleshooting**: If model loading fails, check GPU/VRAM availability using `./ai-status.sh`.
- **Network**: All containers reside on the `ai-engineering-net` Docker network.
- **Proxy**: For corporate environments, use the `DOWNLOAD_PROXY` environment variable.
