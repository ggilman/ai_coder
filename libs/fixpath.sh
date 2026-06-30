#!/bin/bash
# file: fixpath.sh
# description: Resolves Docker Desktop WSL bind mounts to standard WSL paths for any drive.

fixpath() {
    # Check if we are inside the Docker Desktop bind mount directory
    if [[ "$PWD" == /mnt/wsl/docker-desktop-bind-mounts/* ]]; then
        # Grab the full mountinfo line for the exact current directory
        MOUNT_INFO=$(awk -v dir="$PWD" '$5 == dir' /proc/self/mountinfo | head -n 1)
        
        if [ -n "$MOUNT_INFO" ]; then
            # Extract column 4 (the root of the mount on the Windows side)
            ORIGINAL_MOUNT=$(echo "$MOUNT_INFO" | awk '{print $4}')
            
            # Extract column 10 (the drvfs device, e.g., D:\134) and isolate the lowercase drive letter
            DRIVE_LETTER=$(echo "$MOUNT_INFO" | awk '{print $10}' | cut -c 1 | tr '[:upper:]' '[:lower:]')
            
            # Ensure we successfully parsed a valid a-z drive letter
            if [[ -n "$DRIVE_LETTER" && "$DRIVE_LETTER" =~ [a-z] ]]; then
                # Reconstruct the absolute native WSL path and decode \040 -> space
                TARGET_DIR="/mnt/${DRIVE_LETTER}${ORIGINAL_MOUNT}"
                TARGET_DIR="${TARGET_DIR//\\040/ }"
                
                # Verify the directory exists before attempting to switch
                if [ -d "$TARGET_DIR" ]; then
                    cd "$TARGET_DIR" || return
                    echo "Path resolved. Switched to: $TARGET_DIR"
                else
                    echo "Error: Reconstructed directory does not exist: $TARGET_DIR"
                fi
            else
                echo "Error: Could not parse a valid Windows drive letter from mount info."
            fi
        else
            echo "Error: No matching mount record found in /proc/self/mountinfo."
        fi
    fi
}