#!/bin/bash
GIT_USER_NAME='NSWCPCRDTE\george.h.gilman'
GIT_USER_EMAIL='george@example.com'

# The current implementation (simulated)
echo "--- Current Implementation ---"
cat <<GITCFG > simulated_container_gitconfig
[user]
    email = ${GIT_USER_EMAIL:-developer@localhost}
    name = ${GIT_USER_NAME:-Developer}
GITCFG
echo "Content of simulated_container_gitconfig:"
cat simulated_container_gitconfig
echo "Git reading it:"
git config -f simulated_container_gitconfig user.name || echo "Git failed to read!"

# The proposed fix
echo -e "\n--- Proposed Fix ---"
email="${GIT_USER_EMAIL:-developer@localhost}"
name="${GIT_USER_NAME:-Developer}"
# Escape backslashes for Git config file format
email="${email//\\/\\\\}"
name="${name//\\/\\\\}"
cat > simulated_container_gitconfig <<GITCFG
[user]
    email = ${email}
    name = ${name}
GITCFG
echo "Content of simulated_container_gitconfig:"
cat simulated_container_gitconfig
echo "Git reading it:"
git config -f simulated_container_gitconfig user.name || echo "Git failed to read!"
