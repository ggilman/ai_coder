# AGENTS.md

## What this is
Bash CLI that launches AI coding tools (Claude, OpenCode, Aider, Gemini) inside Docker containers backed by a **local** llama.cpp inference engine. No compiled code — all shell scripts, Dockerfile templates, and plain-text config. Targets **Windows via WSL2/Git Bash** first, secondary Linux path. No macOS support, no CI.

## Key conventions
- All scripts run `set -euo pipefail` — use `|| true` / `|| return` where failure is tolerated
- Config follows `VAR="${VAR:-default}"` pattern — exported env vars always win over defaults
- Windows paths: `to_host_path()` converts for `-v` mounts (WSL passthrough, Git Bash `cygpath -m`)
- The `cleanup()` trap in `ai-coder` is the single exit path — don't add bypass exits

## Script loading order
`ai-coder` sources: `libs/fixpath.sh` → `libs/ai-coder-core.sh` → `libs/ai-coder-ui.sh` → `libs/ai-coder-setup.sh` → `libs/ai-coder-commands.sh` → `libs/ai-coder-menus.sh` → selected `config/families/<family>.conf` → selected `agents/ai-coder-<tool>.sh`. All libs/agents files assume this sourcing chain — none run standalone.

## Adding a tool
1. Create `agents/ai-coder-<name>.sh` with `build_image`, `configure_workbench`, `start_workbench`, `execute_tool` (see `ai-coder-opencode.sh` template), set `IMAGE_NAME` and `TOOL_NAME`
2. Add `packages/apt-<name>.txt` and `packages/mcp-<name>.txt` if MCP supported
3. Register in `libs/ai-coder-menus.sh` selection menu
4. Add Config Persistence row to README.md if tool has config/auth state

## Adding a model family
Copy existing `config/families/<family>.conf`, keep double-sourcing guard, fill `MODEL_FAMILY` and ordered `MODEL_N_*` candidates (best quality first, `WEIGHTS_GB=0` last). Family confs are read at launch time only — no code changes needed.

## Config vs rebuild
- **Rebuild needed**: apt packages, MCP npm/pip packages, git identity, base image
- **No rebuild**: model family/tier, `config/ai-coder-model.conf` settings, MCP server args, GPU mode, most `--setup` toggles, KV cache type, speculative decoding, proxy/network isolation

Run `./ai-coder --rebuild` then `./ai-coder` for image changes.

## Package/MCP manifests
`packages/apt-*.txt` and `packages/mcp-*.txt` are pipe-delimited text. `mcp-common.txt` = always registered, `mcp-extra.txt` = opt-in via `--setup`. Format: `npm-package | server-key | command | args | ENV_VARS | net`

## Config persistence
- `user/` directory: flat `key=value` files read via `read_pref`/`write_pref` in `libs/ai-coder-env.sh`
- `user/settings.conf`: all `--setup`/`--model` choices
- `user/state.conf`: session state, running-engine settings
- `user/.setup-done`: sentinel gating first launch
- Per-tool config volume-mounted into containers, survives restarts

## Testing
No CI. Manual verification:
- `bash -n <script>.sh` or shellcheck for syntax (note `# shellcheck source=/dev/null` annotations in `ai-coder-core.sh` and `offline/unbundle.sh` for dynamic sourcing)
- Exercise flag/menu paths against real Docker Desktop instance
- Most logic is Docker/GPU state machine behavior that can't be unit tested