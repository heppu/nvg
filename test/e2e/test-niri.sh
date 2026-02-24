#!/usr/bin/env bash
# test-niri.sh — E2E tests for nvg with niri (headless Wayland).
#
# Starts niri in headless mode (no GPU/display needed), spawns windows
# using foot, and verifies that nvg can navigate between them.
#
# Requirements: niri, foot, jq
# Usage: bash test/e2e/test-niri.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

WM_NAME="niri"
JUNIT_SUITE="e2e-niri"
JUNIT_XML="${JUNIT_XML:-$REPO_ROOT/test-results-niri.xml}"

# ─── Adapter functions ───

NIRI_CONFIG=""
NIRI_PID=""

install_deps() {
    log_info "Installing niri dependencies..."

    # niri is not in the Ubuntu archive; install from PPAs.
    sudo add-apt-repository -y ppa:avengemedia/danklinux
    sudo add-apt-repository -y ppa:avengemedia/dms
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends niri foot jq
}

start_wm() {
    NIRI_CONFIG=$(mktemp /tmp/niri-test-config.XXXXXX.kdl)

    cat > "$NIRI_CONFIG" <<'NIRICFG'
// Minimal niri config for e2e testing.
output "headless-1" {
    mode "1920x1080@60.000"
}

layout {
    gaps 0
    default-column-width { proportion 0.5; }
}

animations {
    off
}
NIRICFG

    log_info "Starting niri (headless)..."

    niri --config "$NIRI_CONFIG" --backend headless &>/dev/null &
    NIRI_PID=$!
    track_pid "$NIRI_PID"

    # Wait for the niri IPC socket to appear.
    # niri creates its socket at $XDG_RUNTIME_DIR/niri.<pid>.sock
    local timeout=15
    local elapsed=0
    while [[ -z "${NIRI_SOCKET:-}" ]]; do
        local sock
        sock=$(find "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
            -maxdepth 1 -name "niri.${NIRI_PID}.*.sock" -type s 2>/dev/null \
            | head -1) || true
        if [[ -n "$sock" ]]; then
            export NIRI_SOCKET="$sock"
            break
        fi
        sleep 0.3
        elapsed=$(echo "$elapsed + 0.3" | bc)
        if (( $(echo "$elapsed >= $timeout" | bc -l) )); then
            log_fail "Timed out waiting for niri to start"
            log_warn "Looking for niri sockets:"
            find "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" -maxdepth 1 -name 'niri*' 2>&1 || true
            return 1
        fi
        if ! kill -0 "$NIRI_PID" 2>/dev/null; then
            log_fail "niri process died during startup"
            return 1
        fi
    done

    log_info "niri running (PID=$NIRI_PID, NIRI_SOCKET=$NIRI_SOCKET)"
}

wm_cleanup() {
    [[ -n "$NIRI_CONFIG" && -f "$NIRI_CONFIG" ]] && rm -f "$NIRI_CONFIG"
    cleanup
}

spawn_window() {
    niri msg action spawn -- foot -e sleep 120 >/dev/null 2>&1
}

wait_for_windows() {
    local expected="$1"
    local timeout="${2:-10}"
    local elapsed=0

    while true; do
        local count
        count=$(niri msg --json windows 2>/dev/null | jq 'length' 2>/dev/null) || count=0
        if [[ "$count" -ge "$expected" ]]; then
            return 0
        fi
        sleep 0.3
        elapsed=$(echo "$elapsed + 0.3" | bc)
        if (( $(echo "$elapsed >= $timeout" | bc -l) )); then
            log_warn "Timed out waiting for $expected windows (have $count)"
            log_warn "niri windows dump:"
            niri msg --json windows 2>&1 | jq '.' 2>&1 || true
            return 1
        fi
    done
}

get_focused() {
    niri msg --json focused-window 2>/dev/null | jq -r '.pid' 2>/dev/null
}

wm_focus() {
    case "$1" in
        left)  niri msg action focus-column-left  >/dev/null 2>&1 || true ;;
        right) niri msg action focus-column-right >/dev/null 2>&1 || true ;;
        up)    niri msg action focus-window-up    >/dev/null 2>&1 || true ;;
        down)  niri msg action focus-window-down  >/dev/null 2>&1 || true ;;
        *)     log_warn "Unknown direction: $1" ;;
    esac
}

run_nvg() {
    "$NVG_BIN" --wm niri "$1"
}

# ─── Run ───

run_tests
