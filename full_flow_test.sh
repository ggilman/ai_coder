#!/bin/bash

# Mocking the environment
export HOME="/tmp/ai_coder_test"
mkdir -p "$HOME"
export GIT_IDENTITY_FILE="$HOME/.ai-coder-gitconfig"
export CONTAINER_GITCONFIG="$HOME/.gitconfig-container"

# Mock read_pref
read_pref() {
    local file="$1" key="$2" default="${3:-}"
    if [ -f "$file" ]; then
        local val; val=$(grep "^${key}=" "$file" 2>/dev/null | cut -d= -f2-)
        [ -n "$val" ] && echo "$val" || echo "$default"
    else
        echo "$default"
    fi
}

# Mock ensure_git_identity
ensure_git_identity() {
    local git_email; git_email=$(read_pref "$GIT_IDENTITY_FILE" email)
    local git_name;  git_name=$(read_pref  "$GIT_IDENTITY_FILE" name)
    export GIT_USER_EMAIL="${git_email:-}"
    export GIT_USER_NAME="${git_name:-}"
}

# The fixed ensure_container_gitconfig
ensure_container_gitconfig() {
    local gitcfg="$CONTAINER_GITCONFIG"
    local email="${GIT_USER_EMAIL:-developer@localhost}"
    local name="${GIT_USER_NAME:-Developer}"
    # Escape backslashes for Git config file format
    email="${email//\\/\\\\}"
    name="${name//\\/\\\\}"
    cat > "$gitcfg" <<GITCFG
[user]
    email = ${email}
    name = ${name}
GITCFG
}

run_test() {
    local input_name="$1"
    echo "--------------------------------------------------"
    echo "TESTING WITH NAME: $input_name"
    
    # 1. Simulate cmd_setup writing to .ai-coder-gitconfig
    # We use printf %s which is what the actual script uses
    printf 'email=george@example.com\nname=%s\n' "$input_name" > "$GIT_IDENTITY_FILE"
    echo "Step 1: Wrote to $GIT_IDENTITY_FILE"

    # 2. Run ensure_git_identity
    ensure_git_identity
    echo "Step 2: Ran ensure_git_identity. GIT_USER_NAME is: $GIT_USER_NAME"

    # 3. Run ensure_container_gitconfig
    ensure_container_gitconfig
    echo "Step 3: Ran ensure_container_gitconfig. Created $CONTAINER_GITCONFIG"

    # 4. Verify the container git config content
    echo "Content of $CONTAINER_GITCONFIG:"
    cat "$CONTAINER_GITCONFIG"

    # 5. Simulate Git reading it (using a real git repo to be sure)
    local test_repo="/tmp/test_repo_$RANDOM"
    mkdir -p "$test_repo"
    cd "$test_repo" || exit
    git init -q
    cp "$CONTAINER_GITCONFIG" .git/config
    
    echo "Git reading name from .git/config:"
    local final_name; final_name=$(git config user.name)
    if [ "$final_name" = "$input_name" ]; then
        echo "SUCCESS: Final name matches input: $final_name"
    else
        echo "FAILURE: Final name does NOT match input!"
        echo "Expected: $input_name"
        echo "Got     : $final_name"
    fi
    cd - > /dev/null || exit
    rm -rf "$test_repo"
}

# Case 1: Single backslash (Standard Windows username)
run_test 'NSWCPCRDTE\george.h.gilman'

# Case 2: Double backslash (User trying to escape it)
run_test 'NSWCPCRDTE\\george.h.gilman'

