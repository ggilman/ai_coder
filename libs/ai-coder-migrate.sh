#!/bin/bash
# ==============================================================================
# AI-CODER-MIGRATE.SH | User-prefs JSON schema versioning & one-time migration
# Sourced by ai-coder-core.sh AFTER env.sh (for read_pref/write_pref) and
# after MODEL_VOLUME_DEFAULT is set, and BEFORE settings.sh/model.sh. Owns:
#   - pref_default  : the single source of truth for settings DEFAULTS
#   - read_setting  : read a settings key with its default resolved here
#   - migrate_user_prefs : per-file forward schema migration + the one-time
#                          old-format (flat .conf) cutover
# Values are stored as JSON strings; per-file schema version keys are
# settings_version / state_version.
# ==============================================================================

# ------------------------------------------------------------------------------
# Current schema versions. Bump these (and add a migrate_*_vN_to_vN+1 step)
# when the stored shape changes. migrate_user_prefs carries files forward from
# their stored version to the current one.
# ------------------------------------------------------------------------------
SETTINGS_SCHEMA_VERSION=1
STATE_SCHEMA_VERSION=1

# ------------------------------------------------------------------------------
# pref_default <key> - the DEFAULT value for a settings key (read-time
# registry). This is the single source of truth for settings defaults, so the
# scattered `read_pref ... <default>` literals never drift from the wizard's
# "keep current" behavior. Prints the default to stdout.
#   - proxy/git_email/git_name: "" (unset -> no proxy / empty identity)
#   - ctx_level: 64k (the wizard's "current" default). NOTE: the
#     ensure_ctx_config call site intentionally keeps an empty default
#     (empty = "user never chose" -> fall back to the env/family model
#     context), so it does NOT use read_setting.
# ------------------------------------------------------------------------------
pref_default() {
    case "$1" in
        proxy)            echo "" ;;
        isolated)         echo "no" ;;
        gpu_mode)         echo "multi" ;;
        ctx_level)        echo "64k" ;;
        kv_q4)            echo "no" ;;
        vram_overhead)    echo "1" ;;
        cpu_offload_pct) echo "90" ;;
        mcp_extras)       echo "no" ;;
        keep_hub)         echo "no" ;;
        keep_hub_timeout) echo "60" ;;
        model_volume)     echo "${MODEL_VOLUME_DEFAULT:-no}" ;;
        spec_decode)      echo "yes" ;;
        speed_tracking)   echo "no" ;;
        expose_host_port) echo "no" ;;
        git_email)        echo "" ;;
        git_name)         echo "" ;;
        *)                echo "" ;;
    esac
}

# ------------------------------------------------------------------------------
# read_setting <key> - read a SETTINGS_FILE key with its default resolved from
# pref_default. Use for settings reads where the inline literal default equals
# the registry default; keep read_pref with an explicit default where the
# intended default differs (e.g. ctx_level's intentional empty).
# ------------------------------------------------------------------------------
read_setting() {
    read_pref "$SETTINGS_FILE" "$1" "$(pref_default "$1")"
}

# ------------------------------------------------------------------------------
# _migrate_domain <domain> <file> <version_key> <current_version>
#
# Forward-migrate ONE user file from its stored schema version to the current
# one. A MISSING file is left missing (it is the "never set up in this
# format" signal the first-run gate keys on, and read_pref treats it as
# defaults), so this function never creates a file. Runs the step functions
# migrate_<domain>_vN_to_vN+1 while stored < current (skipping any step
# that isn't defined, so partial/unknown states degrade safely), then persists
# the final version.
# ------------------------------------------------------------------------------
_migrate_domain() {
    local domain="$1" file="$2" vkey="$3" current="$4"
    # Missing file: leave it missing (the first-run gate keys on this).
    [ -f "$file" ] || return 0
    local _jq="${JQ_CMD:-jq}"
    # A file that isn't valid JSON (hand-truncated, mid-write) is left as-is:
    # read_pref already degrades it to defaults and --doctor reports it -
    # stamping a version here would make write_pref rebuild it from an empty
    # object, resetting the file and hiding the corruption from --doctor.
    "$_jq" empty "$file" >/dev/null 2>&1 || return 0
    local stored
    stored=$("$_jq" -r "(${vkey} // empty)" "$file" 2>/dev/null) || stored=""
    # Absent or unparseable version = 1 (a file this version wrote is v1).
    case "$stored" in ''|*[!0-9]*) stored=1 ;; esac
    while [ "$stored" -lt "$current" ]; do
        local next=$((stored + 1))
        local fn="migrate_${domain}_v${stored}_to_v${next}"
        declare -f "$fn" &>/dev/null && "$fn"
        stored=$next
    done
    write_pref "$file" "$vkey" "$current"
}

# ------------------------------------------------------------------------------
# migrate_user_prefs - run at launch (before the first-run gate).
#
#  1. Forward-migrate settings.json / state.json on their stored version keys.
#  2. One-time old-format cutover: an old user has .setup-done (from the flat
#     .conf era) but no settings.json. Delete .setup-done so the first-run
#     gate fires and the user re-runs --setup ("like a new setup"). migrate
#     never creates missing files, so this is the only place the cutover
#     lives, and it self-disarms once settings.json exists.
# ------------------------------------------------------------------------------
migrate_user_prefs() {
    _migrate_domain "settings" "$SETTINGS_FILE" "settings_version" "$SETTINGS_SCHEMA_VERSION"
    _migrate_domain "state"    "$STATE_FILE"    "state_version"    "$STATE_SCHEMA_VERSION"

    if [ ! -f "$SETTINGS_FILE" ] && [ -f "$USER_DIR/.setup-done" ]; then
        rm -f "$USER_DIR/.setup-done"
    fi
}

# ------------------------------------------------------------------------------
# Migration step helpers (used by migrate_<domain>_vN_to_vN+1 steps).
#
# pref_rename <file> <old_key> <new_key> - move a key's value from old to new
#   if old is present and new is absent (preserving a newer explicit value).
# pref_drop <file> <key> - remove a retired key.
# ------------------------------------------------------------------------------
pref_rename() {
    local file="$1" old_key="$2" new_key="$3"
    local cur; cur=$(read_pref "$file" "$old_key" "")
    [ -n "$cur" ] || return 0
    local target; target=$(read_pref "$file" "$new_key" "")
    [ -z "$target" ] && write_pref "$file" "$new_key" "$cur"
    write_pref "$file" "$old_key" ""
}

pref_drop() {
    write_pref "$1" "$2" ""
}

# (No v1->v2 steps exist yet: this is the framework. Add e.g.
# migrate_settings_v1_to_v2 / migrate_state_v1_to_v2 here in a future release.)
