#!/usr/bin/env bash
# test-i3.sh — E2E tests for nvg with i3 (Xvfb headless X11).
#
# Starts Xvfb (virtual framebuffer) and i3 window manager, spawns xterm
# windows, and verifies that nvg can navigate between them.
#
# Requirements: i3, xvfb, xterm, xdotool, jq
# Usage: bash test/e2e/test-i3.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

WM_NAME="i3"
JUNIT_SUITE="e2e-i3"
JUNIT_XML="${JUNIT_XML:-$REPO_ROOT/test-results-i3.xml}"

# Ensure SWAYSOCK is not set — nvg's sway backend checks SWAYSOCK before I3SOCK.
unset SWAYSOCK 2>/dev/null || true

# ─── Adapter functions ───

I3_CONFIG=""
XVFB_PID=""
I3_PID=""
DISPLAY_NUM=":99"

install_deps() {
    log_info "Installing i3 dependencies..."
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends i3 xvfb xterm xdotool x11-utils xfonts-base jq
}

# _i3msg — wrapper to run i3-msg with the correct DISPLAY
_i3msg() {
    DISPLAY="$DISPLAY_NUM" i3-msg "$@"
}

start_wm() {
    # Start Xvfb (virtual framebuffer)
    log_info "Starting Xvfb on $DISPLAY_NUM..."
    Xvfb "$DISPLAY_NUM" -screen 0 1920x1080x24 +extension RANDR &>/dev/null &
    XVFB_PID=$!
    track_pid "$XVFB_PID"

    wait_until 'DISPLAY="$DISPLAY_NUM" xdpyinfo' 10 "Xvfb on $DISPLAY_NUM" "$XVFB_PID" || return 1
    log_info "Xvfb ready"

    # Write minimal i3 config
    I3_CONFIG=$(mktemp /tmp/i3-test-config.XXXXXX)
    cat > "$I3_CONFIG" <<'I3CFG'
# Minimal i3 config for e2e testing.
set $mod Mod4
default_orientation horizontal

# No i3bar
bar {
    mode invisible
}
I3CFG

    log_info "Starting i3..."
    DISPLAY="$DISPLAY_NUM" i3 -c "$I3_CONFIG" &>/dev/null &
    I3_PID=$!
    track_pid "$I3_PID"

    wait_until \
        'I3SOCK=$(DISPLAY="$DISPLAY_NUM" i3 --get-socketpath 2>/dev/null); [[ -S "$I3SOCK" ]]' \
        15 "i3 IPC socket" "$I3_PID" || return 1
    export I3SOCK

    log_info "i3 running (PID=$I3_PID, I3SOCK=$I3SOCK, DISPLAY=$DISPLAY_NUM)"
}

wm_cleanup() {
    [[ -n "$I3_CONFIG" && -f "$I3_CONFIG" ]] && rm -f "$I3_CONFIG"
    cleanup
}

spawn_window() {
    _i3msg exec "xterm -e sleep 120" >/dev/null 2>&1
}

count_windows() {
    DISPLAY="$DISPLAY_NUM" i3-msg -t get_tree 2>/dev/null \
        | jq '[.. | select(.type? == "con" and (.pid? > 0 or .window? > 0))] | length' 2>/dev/null || echo 0
}

get_focused() {
    DISPLAY="$DISPLAY_NUM" i3-msg -t get_tree 2>/dev/null \
        | jq -r '.. | select(.focused? == true and .type? == "con") | if .pid > 0 then .pid else .window end' 2>/dev/null \
        | head -1
}

wm_focus() {
    _i3msg "focus $1" >/dev/null 2>&1 || true
}

run_nvg() {
    DISPLAY="$DISPLAY_NUM" I3SOCK="$I3SOCK" run_nvg_bin "$NVG_BIN" --wm i3 "$1"
}

# ─── Run ───

run_tests
