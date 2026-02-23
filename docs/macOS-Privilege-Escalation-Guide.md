# macOS Privilege Escalation & Credential Harvesting — Operator Guide

## Overview

This guide covers practical macOS privilege escalation techniques for red team engagements, ordered from lowest risk/noise to highest capability. Each technique includes MITRE ATT&CK mapping, TCC requirements, operational notes, and implementation references.

---

## Phase 1: Passive Collection (Zero UI, Zero TCC)

### 1.1 Clipboard Sniffer

**MITRE:** T1115 (Clipboard Data)  
**TCC:** None  
**Detection Risk:** Low  
**Implementation:** `credential-capture/clipboard-sniffer/`

Password managers (1Password, Bitwarden, LastPass, Dashlane) copy credentials to the clipboard when users autofill or manually copy. `NSPasteboard` monitoring requires zero TCC permissions.

**How it works:**
- Poll `NSPasteboard.general.changeCount` every 500ms
- When clipboard changes, check content against password heuristics (mixed case + digits + special chars, 8-64 chars, no spaces)
- Track `NSWorkspace.shared.frontmostApplication` for context (which app was active)
- Flag content from known password manager bundle IDs as high-confidence credentials

**Operational notes:**
- Deploy first, always. It's free intelligence with zero risk.
- Password managers clear clipboard after 30-90 seconds — poll interval must be faster.
- Bitwarden copies to clipboard on autofill even when using browser extension.
- 1Password's clipboard clearing can be disabled by users (common).

### 1.2 Sudo PATH Hijack

**MITRE:** T1574.007 (Path Interception by PATH Environment Variable)  
**TCC:** None  
**Detection Risk:** Low  
**Implementation:** `credential-capture/sudo-hijack/`

If `/opt/homebrew/bin` or `/usr/local/bin` appears in `$PATH` before `/usr/bin` (true for virtually all developers with Homebrew), place a fake `sudo` there.

**How it works:**
- Drop a bash script named `sudo` in a writable PATH directory
- Script mimics real sudo's password prompt exactly
- Captures password, then passes through to `/usr/bin/sudo`
- User sees normal sudo behavior — completely transparent

**Operational notes:**
- Only works for Terminal users (developers, admins)
- Check `which sudo` to verify hijack is working
- The prompt `[sudo] password for username:` must match exactly
- Handle `-S` flag (stdin) and `-n` (non-interactive) passthrough

### 1.3 Shell Profile Injection

**MITRE:** T1546.004 (Unix Shell Configuration Modification)  
**TCC:** None  
**Detection Risk:** Low-Medium  
**Implementation:** `credential-capture/profile-injection/`

Inject a sudo function alias into `.zshrc` or `.bash_profile`. Similar to PATH hijack but modifies the user's shell config directly.

**Operational notes:**
- More persistent than PATH hijack (survives PATH changes)
- Visible if user inspects their shell profile
- Use benign-looking comments ("Adobe Document Cloud sync helper")

---

## Phase 2: Active Collection (Dialog-Based)

### 2.1 Finder Dialog (Recommended First Active Technique)

**MITRE:** T1056.002 (GUI Input Capture), T1059.002 (AppleScript)  
**TCC:** None  
**Detection Risk:** Medium  
**Implementation:** `credential-capture/finder-dialog/`

The strongest dialog-based approach. Uses `tell application "Finder"` — the dialog shows **"Finder"** as the requesting application with the real Finder icon.

**How it works:**
```applescript
tell application "Finder"
    activate
    set pw to text returned of (display dialog "Finder needs your password to verify your identity." ¬
        default answer "" with hidden answer ¬
        buttons {"OK"} default button 1 ¬
        with icon file "System:Library:CoreServices:Finder.app:Contents:Resources:Finder.icns")
end tell
```

**Why "Finder" wins:**
- Every Mac user knows Finder
- Finder legitimately requests passwords for file operations
- The system dialog shows "Finder" with the real icon — not "osascript" or "Terminal"
- Users don't question Finder asking for authentication

**Always combine with `dscl` validation:**
```bash
dscl . -authonly "$USER" "$PASSWORD" 2>/dev/null
```
This validates the password against the local directory service. Only accept confirmed passwords.

**Timing matters:**
- Use `lsappinfo` or Sliver's `ps` to verify user is actively working
- Never prompt during idle or when screensaver is active
- Best timing: user is actively using Finder (copying files, navigating)

### 2.2 Privileged Helper Tool Spoofing (SentinelOne)

**MITRE:** T1056.002 (GUI Input Capture)  
**TCC:** None  
**Detection Risk:** Medium  
**Implementation:** `credential-capture/privileged-helper-spoof/`

Enumerate installed privileged helper tools in `/Library/PrivilegedHelperTools/`, find their parent applications, and show a credential prompt that appears to come from the real app.

**Kill chain:**
1. Enumerate helpers: `ls /Library/PrivilegedHelperTools/`
2. Extract parent app from `AuthorizedClients` in helper binary
3. Get parent app's icon from `CFBundleIconFile`
4. Wait for user to actively use the parent app
5. Show prompt with real app name and icon
6. If cancelled → kill the app → user relaunches → re-prompt

**Operational notes:**
- The helper tool name is real and verifiable by the user
- "Cancel" killing the app is a powerful social engineering trick
- Common targets: Docker, VMware, 1Password, VS Code
- Only works if third-party helpers are installed (check first)

### 2.3 Dock Impersonation

**MITRE:** T1574.009 (Path Interception), T1056.002 (GUI Input Capture)  
**TCC:** None  
**Detection Risk:** Medium-High  
**Implementation:** `credential-capture/dock-impersonation/`

Replace a Dock icon with a trojanized `.app` bundle. When user clicks, your app runs (shows prompt + launches real app).

**Operational notes:**
- `killall Dock` causes a brief visual flash — user may notice
- One-shot technique: restore original Dock entry after capture
- Best targets: Chrome, Slack, VS Code (frequently clicked)
- Less reliable than Finder dialog — use as backup

---

## Phase 3: Escalation (Password → Root)

Once you have a validated password, escalate:

```bash
# Use captured password for sudo
echo "$PASSWORD" | sudo -S <command>

# Verify root access
echo "$PASSWORD" | sudo -S id
```

### Post-Root Priorities

1. **Install Authorization Plugin** — persistent cred capture (see Phase 4)
2. **Grant TCC permissions** for surveillance capabilities:
   ```bash
   # Grant Input Monitoring (enables keylogger)
   sudo tccutil reset InputMonitoring
   # Or directly modify TCC.db (requires SIP bypass on newer macOS)
   ```
3. **Install LaunchDaemon** — root-level persistence
4. **Deploy keylogger** — full keystroke capture with app context

---

## Phase 4: Persistence & Continuous Collection (Post-Root)

### 4.1 Authorization Plugin

**MITRE:** T1556 (Modify Authentication Process)  
**TCC:** None (runs in authorization framework)  
**Detection Risk:** Low (runs inside `authorizationhosthelper`)  
**Implementation:** `credential-capture/auth-plugin/`

The gold standard for persistent credential capture. Hooks into the macOS login process and receives **cleartext passwords** through the Authorization framework.

**What it captures:**
- Login passwords
- Screen unlock passwords
- Screensaver wake passwords
- Sudo passwords (if auth UI is involved)

**How it works:**
- Compile an Objective-C bundle implementing `AuthorizationPluginCreate`
- Install to `/Library/Security/SecurityAgentPlugins/`
- Register mechanism in `system.login.console` authorization rule
- Plugin's `mechInvoke` function reads `kAuthorizationEnvironmentPassword` from context

**Operational notes:**
- Runs inside Apple's `authorizationhosthelper` XPC service
- Not visible to user at all — no UI, no process in Activity Monitor
- Survives reboots
- Apple moved plugin execution from `authorizationhost` to XPC service on Sonoma — still works but lost some TCC-bypass entitlements
- Use `security authorizationdb read system.login.console` to verify installation

### 4.2 Keylogger (Post-TCC Grant)

**MITRE:** T1056.001 (Keylogging)  
**TCC:** Input Monitoring  
**Detection Risk:** Low (if TCC is pre-granted)  
**Implementation:** `keylogger/`

Swift-based keylogger using `CGEventTap` API. Captures all keystrokes with active application and window title context.

**Features:**
- Tracks frontmost app name (no TCC needed)
- Tracks window title (Screen Recording permission needed on Sonoma+)
- Maps special keys (Return, Tab, Delete, arrow keys)
- Logs modifier combinations (Cmd+C, Ctrl+A, etc.)
- Periodic buffer flush (2 second interval)
- Runs completely hidden (no Dock icon, no menu bar)
- LaunchAgent persistence with crash recovery

**Deployment:**
1. Upload Swift source to target
2. Compile on-device: `swiftc -O keylogger.swift -o AdobeHelperService`
3. Create `.app` bundle with Adobe branding
4. Install LaunchAgent with `KeepAlive` + `ThrottleInterval`
5. If Input Monitoring wasn't pre-granted, user gets a permission prompt

---

## TCC Permission Matrix

| Capability | TCC Category | Pre-Root | Post-Root |
|-----------|-------------|----------|-----------|
| Clipboard monitoring | None | Yes | Yes |
| Frontmost app name | None | Yes | Yes |
| Password dialogs (osascript) | None | Yes | Yes |
| Keylogging (CGEventTap) | Input Monitoring | Prompt | Grant via tccutil |
| Screen recording | Screen & System Audio Recording | Prompt | Grant via tccutil |
| Camera | Camera | Prompt | Grant via tccutil |
| Microphone | Microphone | Prompt | Grant via tccutil |
| Full Disk Access | Full Disk Access | Prompt | Grant via tccutil |
| Accessibility | Accessibility | Prompt | Grant via tccutil |
| Window titles (Sonoma+) | Screen Recording | Prompt | Grant via tccutil |

**Post-root TCC manipulation:**
```bash
# Reset and re-grant (may trigger user notification)
sudo tccutil reset InputMonitoring
sudo tccutil reset ScreenCapture

# Direct TCC.db edit (requires SIP disabled or bypass)
sudo sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
  "INSERT OR REPLACE INTO access VALUES('kTCCServiceInputMonitoring','com.adobe.acrobat.helperservice',0,2,4,1,NULL,NULL,0,NULL,NULL,0,$(date +%s));"
```

---

## OPSEC Considerations

1. **Dialog source app name matters most.** "Finder" > any brand name > "System Events" > "osascript"
2. **Never show repeated prompts.** One attempt → if cancelled, use a different technique.
3. **Validate before using.** Always `dscl . -authonly` before `sudo -S`.
4. **Time prompts contextually.** During active use, never idle.
5. **Clean up temp files.** Remove `/tmp/.aupd_*`, source files after compilation.
6. **Use benign process names.** "AdobeHelperService", "AdobeCloudSync", not "keylogger" or "stealer".
7. **Base64 encode detection strings** in stagers to avoid static analysis hits.
8. **LaunchAgent plists should look legitimate.** Use real Adobe bundle IDs and version numbers.

---

## Real-World APT Comparison

| APT/Malware | Technique | Sophistication |
|------------|-----------|---------------|
| Atomic Stealer (AMOS) | Simple osascript `with administrator privileges` | Low |
| Cthulhu Stealer | osascript + `dscl` validation loop | Medium |
| RustBucket (Lazarus) | No cred prompt — persistence + data exfil | Medium |
| LightSpy (APT41) | Full implant — screen, keylog, keychain | High |
| BeaverTail (DPRK) | Social engineering via fake apps | Medium |
| SilentSwift | Contextual prompts + auth plugin + keylogger | High |

---

## References

- [SentinelOne: Spoofing Privileged Helpers](https://www.sentinelone.com/blog/macos-red-team-spoofing-privileged-helpers-and-others-to-gain-root/)
- [SentinelOne: Calling Apple APIs Without Binaries](https://www.sentinelone.com/blog/macos-red-team-calling-apple-apis-without-building-binaries/)
- [SpecterOps: Persistent Credential Theft with Auth Plugins](https://posts.specterops.io/persistent-credential-theft-with-authorization-plugins-d17b34719d65)
- [theevilbit: Beyond LaunchAgents #28](https://theevilbit.github.io/beyond/beyond_0028/)
- [HackTricks: macOS Privilege Escalation](https://book.hacktricks.xyz/macos-hardening/macos-security-and-privilege-escalation/macos-privilege-escalation)
- [Embrace The Red: Spoofing Credential Dialogs](https://embracethered.com/blog/posts/2021/spoofing-credential-dialogs/)
- [cedowens/Swift-Attack](https://github.com/cedowens/Swift-Attack)
- [xorrior/macOSTools/auth_plugins](https://github.com/xorrior/macOSTools/tree/master/auth_plugins)
