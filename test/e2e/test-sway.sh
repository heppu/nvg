#!/usr/bin/env bash
# test-sway.sh — E2E tests for nvg with Sway (headless Wayland).
#
# Starts Sway in headless mode (no GPU/display needed), spawns windows
# using foot, and verifies that nvg can navigate between them.
#
# Requirements: sway, foot, jq
# Usage: bash test/e2e/test-sway.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

WM_NAME="sway"
JUNIT_SUITE="e2e-sway"
JUNIT_XML="${JUNIT_XML:-$REPO_ROOT/test-results-sway.xml}"

# ─── Adapter functions ───

SWAY_CONFIG=""
SWAY_PID=""

install_deps() {
    log_info "Installing sway dependencies..."
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends sway foot jq
}

start_wm() {
    SWAY_CONFIG=$(mktemp /tmp/sway-test-config.XXXXXX)

    cat > "$SWAY_CONFIG" <<'SWAYCFG'
# Minimal Sway config for e2e testing.
# No bar, no wallpaper, no idle — just a WM.
set $mod Mod4
default_orientation horizontal
SWAYCFG

    log_info "Starting Sway (headless)..."

    # WLR_BACKENDS=headless: use headless wlroots backend (no GPU)
    # WLR_LIBINPUT_NO_DEVICES=1: don't fail on missing input devices
    WLR_BACKENDS=headless \
    WLR_LIBINPUT_NO_DEVICES=1 \
        sway -c "$SWAY_CONFIG" &>/dev/null &
    SWAY_PID=$!
    track_pid "$SWAY_PID"

    # Wait for the Sway IPC socket to appear.
    # Sway sets SWAYSOCK for child processes, but since we started it as
    # a background process, we need to find the socket ourselves.
    local timeout=15
    local elapsed=0
    while [[ -z "${SWAYSOCK:-}" ]]; do
        # Sway socket is typically at $XDG_RUNTIME_DIR/sway-ipc.*.sock
        local sock
        sock=$(find "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
            -maxdepth 1 -name 'sway-ipc.*.sock' -type s 2>/dev/null \
            | head -1) || true
        if [[ -n "$sock" ]]; then
            export SWAYSOCK="$sock"
            break
        fi
        sleep 0.3
        elapsed=$(echo "$elapsed + 0.3" | bc)
        if (( $(echo "$elapsed >= $timeout" | bc -l) )); then
            log_fail "Timed out waiting for Sway to start"
            return 1
        fi
        if ! kill -0 "$SWAY_PID" 2>/dev/null; then
            log_fail "Sway process died during startup"
            return 1
        fi
    done

    log_info "Sway running (PID=$SWAY_PID, SWAYSOCK=$SWAYSOCK)"
}

wm_cleanup() {
    [[ -n "$SWAY_CONFIG" && -f "$SWAY_CONFIG" ]] && rm -f "$SWAY_CONFIG"
    cleanup
}

spawn_window() {
    swaymsg exec "foot -e sleep 120" >/dev/null 2>&1
}

wait_for_windows() {
    local expected="$1"
    local timeout="${2:-10}"
    local elapsed=0

    while true; do
        local count
        count=$(swaymsg -t get_tree 2>/dev/null \
            | jq '[.. | select(.pid? > 0 and .type? == "con")] | length' 2>/dev/null) || count=0
        if [[ "$count" -ge "$expected" ]]; then
            return 0
        fi
        sleep 0.3
        elapsed=$(echo "$elapsed + 0.3" | bc)
        if (( $(echo "$elapsed >= $timeout" | bc -l) )); then
            log_warn "Timed out waiting for $expected windows (have $count)"
            return 1
        fi
    done
}

get_focused() {
    swaymsg -t get_tree 2>/dev/null \
        | jq -r '.. | select(.focused? == true and .pid? > 0) | .pid' 2>/dev/null \
        | head -1
}

wm_focus() {
    swaymsg "focus $1" >/dev/null 2>&1 || true
}

run_nvg() {
    "$NVG_BIN" --wm sway "$1"
}

# ─── Run ───

run_tests
