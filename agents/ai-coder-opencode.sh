#!/bin/bash
# ==============================================================================
# AI-CODER-OPENCODE.SH | OpenCode Variant Overrides
# ==============================================================================

IMAGE_NAME="ai-coder-opencode"
TOOL_NAME="OpenCode"

build_image() {
    build_npm_agent_image "Dockerfile.oc" "apt-opencode.txt" "mcp-opencode.txt" \
        "opencode-ai" "" "RUN opencode --version"
}

configure_workbench() {
    local config_dir="$HOME/.opencode-config"
    # Docker runs as root so mounted dir files can become root-owned on the WSL host.
    ensure_host_dir_writable "$config_dir"
    cat > "$config_dir/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "share": "disabled",
  "permission": {
    "write": "deny"
  },
  "model": "local/hub-model",
  "provider": {
    "local": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Local $MODEL_FAMILY (llama.cpp)",
      "options": {
        "baseURL": "http://$GLOBAL_ENGINE_NAME:8080/v1",
        "apiKey": "$LOCAL_API_KEY"
      },
      "models": {
        "hub-model": {
          "name": "$MODEL_FAMILY Local",
          "contextLength": $MODEL_CTX_SIZE
        }
      }
    }
  },
  "mcp": {
$(make_agent_mcp_json "/$WORKSPACE_DIR" opencode mcp-opencode.txt)
  }
}
EOF
}

start_workbench() {
    run_workbench \
        -e OPENCODE_DISABLE_MODELS_FETCH=1 \
        -v "$(to_host_path "$HOME/.npm-cache"):/root/.npm" \
        -v "$(to_host_path "$HOME/.opencode-config"):/root/.config/opencode"
}

execute_tool() {
#exec_in_container "$WORKBENCH" opencode
#Lengthy setup to ignore Ctrl-C in Opencode
    exec_in_container "$WORKBENCH" python3 -c '
import pty, os, sys, termios, struct, fcntl, select

# 1. Capture current host window dimensions
def get_terminal_size():
    try:
        return struct.unpack("hh", fcntl.ioctl(sys.stdout.fileno(), termios.TIOCGWINSZ, "1234"))
    except OSError:
        return 24, 80

# 2. Advanced filter: Remove Ctrl-C completely without closing the stream
def filter_stdin(fd):
    try:
        data = os.read(fd, 4096)
    except OSError:
        return b""
    # If the user pressed Ctrl-C, remove it entirely from the byte stream
    clean_data = data.replace(b"\x03", b"")
    return clean_data

# 3. Custom spawn implementation that explicitly sizes the PTY
def spawn_with_dimensions(argv):
    rows, cols = get_terminal_size()
    
    try:
        mode = termios.tcgetattr(sys.stdin.fileno())
    except termios.error:
        mode = None

    master_fd, slave_fd = pty.openpty()
    
    # Push terminal size
    try:
        fcntl.ioctl(master_fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    except OSError:
        pass

    pid = os.fork()
    if pid == 0:
        # Child process configuration
        os.setsid()
        os.dup2(slave_fd, 0)
        os.dup2(slave_fd, 1)
        os.dup2(slave_fd, 2)
        if master_fd >= 3:
            os.close(master_fd)
        if slave_fd >= 3:
            os.close(slave_fd)
        
        try:
            fcntl.ioctl(0, termios.TIOCSPGRP, struct.pack("i", os.getpgrp()))
        except OSError:
            pass

        os.execvp(argv[0], argv)
    else:
        # Parent process: handle raw terminal routing cleanly
        os.close(slave_fd)
        if mode:
            import tty
            tty.setraw(sys.stdin.fileno())

        try:
            # Custom copy loop to prevent the EOF lockup when discarding bytes
            while True:
                # Wait for input
                rfds, _, _ = select.select([sys.stdin.fileno(), master_fd], [], [])
                
                if sys.stdin.fileno() in rfds:
                    data = filter_stdin(sys.stdin.fileno())
                    if not data and not select.select([sys.stdin.fileno()], [], [], 0)[0]:
                        # If truly closed from system, exit loop
                        pass
                    else:
                        os.write(master_fd, data)
                        
                if master_fd in rfds:
                    try:
                        data = os.read(master_fd, 4096)
                    except OSError:
                        break
                    if not data:
                        break
                    os.write(sys.stdout.fileno(), data)
        except OSError:
            pass
        finally:
            if mode:
                termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, mode)

# Launch
spawn_with_dimensions(["bash", "-c", "opencode"])
'
}
