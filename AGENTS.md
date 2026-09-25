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

## Agent instructions and sampling
- `prompts/*.md` → assembled by `render_agent_prompt` (`libs/ai-coder-env.sh`) into each tool's own instructions file/flag in its `configure_workbench`; gated by the `agent_prompt` setting; files carry `AGENT_PROMPT_MARKER` so user-written files are never overwritten
- Claude runs `--bare` (skips CLAUDE.md discovery), so it gets `--append-system-prompt-file` with the project's CLAUDE.md/AGENTS.md folded in
- Per-family sampling: `MODEL_SAMPLING`/`MODEL_SAMPLING_NOTHINK` in the family conf → llama-server `--temp/--top-p/...` via `resolve_model_sampling`; no rebuild, engine restarts on change
- Other model-card settings per family: `MODEL_REASONING_PRESERVE` (Qwen3.6/3.8; OpenCode then gets `interleaved` so it sends reasoning back), `MODEL_CHAT_TEMPLATE_KWARGS` (→ `--chat-template-kwargs`, jinja only), `MODEL_MAX_OUTPUT` (→ each tool's output limit via `agent_max_output_tokens`, capped at ctx/4). Tool-specific context/output env vars are set in each agent's `execute_tool`

## Config vs rebuild
- **Rebuild needed**: apt packages, MCP npm/pip packages, git identity, base image
- **No rebuild**: `prompts/*.md`, model family/tier, `config/ai-coder-model.conf` settings, MCP server args, GPU mode, most `--setup` toggles, KV cache type, speculative decoding, proxy/network isolation

Run `./ai-coder --rebuild` then `./ai-coder` for image changes.

## Package/MCP manifests
`packages/apt-*.txt` and `packages/mcp-*.txt` are pipe-delimited text. `mcp-common.txt` = always registered, `mcp-extra.txt` = opt-in via `--setup`. Format: `npm-package | server-key | command | args | ENV_VARS | net`

## Config persistence
- `user/` directory: **JSON** files, jq-backed `read_pref`/`write_pref` in `libs/ai-coder-env.sh` — **all values stored as JSON strings** (numbers included, e.g. `"vram_overhead": "1"`)
  - `user/settings.json`: all `--setup`/`--model` choices + `settings_version`
  - `user/state.json`: session state, running-engine settings + `state_version`
- **Defaults resolved at read time**, never materialized: `pref_default`/`read_setting` registry in `libs/ai-coder-migrate.sh` is the single source; a missing key returns its default (`state.json` has no defaults → absent keys re-prompt)
- **Forward-only migration** in `migrate_user_prefs` (same file, no re-prompt), keyed by `settings_version`/`state_version` (strings, start `"1"`); old `user/*.conf` are legacy (no longer read — `--doctor` flags them)
- **jq bootstrap** (`libs/ai-coder-jq.sh`): `ensure_jq`/`resolve_jq_cmd` resolve PATH > bundled `.assets/jq[.exe]`; first-run download fallback only, never at read time; offline bundles ship `.assets/jq`+`jq.exe`
- `user/.setup-done`: sentinel gating first launch
- Per-tool config volume-mounted into containers, survives restarts

## Changing stored data
Stored prefs live in `user/settings.json` / `user/state.json`. Never hand-edit — add a forward-only migration: bump `SETTINGS_SCHEMA_VERSION`/`STATE_SCHEMA_VERSION` in `libs/ai-coder-migrate.sh`, add `migrate_<domain>_v<old>_to_v<new>()` (using `pref_rename`/`pref_drop`/`write_pref`); `migrate_user_prefs` runs steps from the file's current version up to the new constant on first launch.

## Testing
No CI. Manual verification:
- `bash -n <script>.sh` or shellcheck for syntax (note `# shellcheck source=/dev/null` annotations in `ai-coder-core.sh` and `offline/unbundle.sh` for dynamic sourcing)
- Exercise flag/menu paths against real Docker Desktop instance
- Most logic is Docker/GPU state machine behavior that can't be unit tested
