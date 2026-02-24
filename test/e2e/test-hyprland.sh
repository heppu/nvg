#!/usr/bin/env bash
# test-hyprland.sh — E2E tests for nvg with Hyprland.
#
# Starts Hyprland and spawns windows using foot, then verifies that nvg
# can navigate between them.
#
# NOTE: Hyprland 0.41+ uses Aquamarine which requires a DRM render node
# (/dev/dri/renderD*). This script cannot run in CI without a GPU.
# It is kept for local testing on machines with GPU hardware.
#
# Requirements: hyprland, foot, jq
# Usage: NVG_BIN=./nvg bash test/e2e/test-hyprland.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

WM_NAME="hyprland"
JUNIT_SUITE="e2e-hyprland"
JUNIT_XML="${JUNIT_XML:-$REPO_ROOT/test-results-hyprland.xml}"

# ─── Adapter functions ───

HYPR_CONFIG=""
HYPR_PID=""

install_deps() {
    log_info "Installing Hyprland dependencies..."

    # Hyprland is not in Ubuntu 24.04 (noble); pull it from plucky (25.04).
    # We need both main (for deps like libdisplay-info2, libudis86-0, newer
    # libinput10) and universe (for hyprland itself).
    sudo tee /etc/apt/sources.list.d/plucky.sources > /dev/null <<'EOF'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: plucky
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

    # Pin plucky at the same priority as noble (500) so apt can freely
    # resolve newer versions of shared libraries (e.g. libinput10 >= 1.26,
    # libxcb-icccm4 >= 0.4.2) that hyprland requires.
    sudo tee /etc/apt/preferences.d/plucky-pin > /dev/null <<'EOF'
Package: *
Pin: release n=plucky
Pin-Priority: 500
EOF

    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends hyprland foot jq
}

start_wm() {
    HYPR_CONFIG=$(mktemp -d /tmp/hypr-test-config.XXXXXX)
    HYPR_LOG="$HYPR_CONFIG/hyprland.log"

    # Hyprland expects config at $XDG_CONFIG_HOME/hypr/hyprland.conf
    mkdir -p "$HYPR_CONFIG/hypr"
    cat > "$HYPR_CONFIG/hypr/hyprland.conf" <<'HYPRCFG'
# Minimal Hyprland config for e2e testing.
general {
    layout = dwindle
}

dwindle {
    force_split = 2
}

# No animations for faster test execution.
animations {
    enabled = false
}

# Headless monitor output.
monitor = ,preferred,auto,1
HYPRCFG

    log_info "Starting Hyprland..."

    # Hyprland 0.41+ uses Aquamarine (not wlroots). It requires a DRM render
    # node for its GBM allocator. This means it cannot run in pure headless
    # mode on machines without a GPU — a real /dev/dri/renderD* is needed.
    # In CI (no GPU), this test is skipped. Run locally with a GPU or under
    # a Wayland session where Aquamarine's Wayland fallback backend can get
    # a DRM FD from the parent compositor.
    env \
        XDG_CONFIG_HOME="$HYPR_CONFIG" \
        Hyprland >"$HYPR_LOG" 2>&1 &
    HYPR_PID=$!
    track_pid "$HYPR_PID"

    # Wait for Hyprland to set up its IPC socket.
    # The socket is at $XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock
    local timeout=15
    local elapsed=0
    while [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; do
        # Find the newest Hyprland socket directory
        local his
        his=$(find "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr" \
            -maxdepth 2 -name '.socket.sock' -type s 2>/dev/null \
            | head -1) || true
        if [[ -n "$his" ]]; then
            # Extract the instance signature from the path
            # Path: $XDG_RUNTIME_DIR/hypr/<signature>/.socket.sock
            local sig_dir
            sig_dir=$(dirname "$his")
            export HYPRLAND_INSTANCE_SIGNATURE
            HYPRLAND_INSTANCE_SIGNATURE=$(basename "$sig_dir")
            break
        fi
        sleep 0.3
        elapsed=$(echo "$elapsed + 0.3" | bc)
        if (( $(echo "$elapsed >= $timeout" | bc -l) )); then
            log_fail "Timed out waiting for Hyprland to start"
            [[ -f "$HYPR_LOG" ]] && log_warn "Hyprland log:" && cat "$HYPR_LOG" >&2
            return 1
        fi
        if ! kill -0 "$HYPR_PID" 2>/dev/null; then
            log_fail "Hyprland process died during startup"
            [[ -f "$HYPR_LOG" ]] && log_warn "Hyprland log:" && cat "$HYPR_LOG" >&2
            return 1
        fi
    done

    log_info "Hyprland running (PID=$HYPR_PID, HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE)"
}

wm_cleanup() {
    [[ -n "$HYPR_CONFIG" && -d "$HYPR_CONFIG" ]] && rm -rf "$HYPR_CONFIG"
    cleanup
}

spawn_window() {
    hyprctl dispatch exec -- foot -e sleep 120 >/dev/null 2>&1
}

wait_for_windows() {
    local expected="$1"
    local timeout="${2:-10}"
    local elapsed=0

    while true; do
        local count
        count=$(hyprctl clients -j 2>/dev/null | jq 'length' 2>/dev/null) || count=0
        if [[ "$count" -ge "$expected" ]]; then
            return 0
        fi
        sleep 0.3
        elapsed=$(echo "$elapsed + 0.3" | bc)
        if (( $(echo "$elapsed >= $timeout" | bc -l) )); then
            log_warn "Timed out waiting for $expected windows (have $count)"
            log_warn "hyprctl clients dump:"
            hyprctl clients -j 2>&1 | jq '.' 2>&1 || true
            return 1
        fi
    done
}

get_focused() {
    hyprctl activewindow -j 2>/dev/null | jq -r '.pid' 2>/dev/null
}

wm_focus() {
    local dir
    case "$1" in
        left)  dir="l" ;;
        right) dir="r" ;;
        up)    dir="u" ;;
        down)  dir="d" ;;
        *)     dir="$1" ;;
    esac
    hyprctl dispatch movefocus "$dir" >/dev/null 2>&1 || true
}

run_nvg() {
    "$NVG_BIN" --wm hyprland "$1"
}

# ─── Run ───

run_tests
