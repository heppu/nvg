#!/usr/bin/env bash
# test-niri.sh — E2E tests for nvg with niri (nested Wayland).
#
# Niri does not expose its headless backend via CLI, so we run it nested
# inside a headless Sway instance.  When WAYLAND_DISPLAY is set niri
# automatically selects its Winit backend, which renders into the parent
# compositor.  IPC, window spawning and focus management all work normally.
#
# Niri is not packaged for Ubuntu 24.04 so we grab the pre-built binary
# from the Fedora COPR maintained by niri's author and pull
# libdisplay-info.so.2 from Ubuntu plucky (25.04).
#
# Requirements (installed by install_deps): sway, foot, jq, niri + runtime libs
# Usage: NVG_BIN=./nvg bash test/e2e/test-niri.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

WM_NAME="niri"
JUNIT_SUITE="e2e-niri"
JUNIT_XML="${JUNIT_XML:-$REPO_ROOT/test-results-niri.xml}"

# ─── Adapter functions ───

NIRI_CONFIG=""
NIRI_PID=""
NIRI_LOG=""
SWAY_CONFIG=""
SWAY_PID=""

NIRI_RPM_URL="https://download.copr.fedorainfracloud.org/results/yalter/niri/fedora-42-x86_64/09901731-niri/niri-25.11-2.fc42.x86_64.rpm"

install_deps() {
    log_info "Installing niri runtime dependencies..."

    # libdisplay-info.so.2 is not in noble (24.04) but is in plucky (25.04).
    # Use apt pinning to pull just that library from plucky.
    sudo tee /etc/apt/sources.list.d/plucky.sources > /dev/null <<'EOF'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: plucky
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    sudo tee /etc/apt/preferences.d/plucky-pin > /dev/null <<'EOF'
Package: *
Pin: release n=plucky
Pin-Priority: -10

Package: libdisplay-info2
Pin: release n=plucky
Pin-Priority: 500
EOF

    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends \
        sway foot jq rpm2cpio \
        libegl-mesa0 libgles2 libgl1-mesa-dri \
        libgbm1 libxkbcommon0 libwayland-client0 libinput10 \
        libseat1 libpipewire-0.3-0 libpango-1.0-0 libpangocairo-1.0-0 \
        libpixman-1-0 libdisplay-info2

    if ! command -v niri &>/dev/null; then
        log_info "Installing niri from Fedora COPR..."
        local tmpdir
        tmpdir=$(mktemp -d)
        curl -sLo "$tmpdir/niri.rpm" "$NIRI_RPM_URL"
        rpm2cpio "$tmpdir/niri.rpm" | (cd "$tmpdir" && cpio -idm './usr/bin/niri' 2>/dev/null)
        sudo install -m 755 "$tmpdir/usr/bin/niri" /usr/local/bin/niri
        rm -rf "$tmpdir"
    fi

    log_info "niri installed: $(niri --version 2>&1 || true)"
}

start_wm() {
    # ── Start Sway as the parent headless compositor ──

    SWAY_CONFIG=$(mktemp /tmp/sway-niri-parent.XXXXXX)
    cat > "$SWAY_CONFIG" <<'SWAYCFG'
set $mod Mod4
default_orientation horizontal
SWAYCFG

    log_info "Starting parent Sway (headless)..."

    WLR_BACKENDS=headless \
    WLR_LIBINPUT_NO_DEVICES=1 \
        sway -c "$SWAY_CONFIG" &>/dev/null &
    SWAY_PID=$!
    track_pid "$SWAY_PID"

    local timeout=15
    local elapsed=0
    local swaysock=""
    while [[ -z "$swaysock" ]]; do
        swaysock=$(find "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
            -maxdepth 1 -name 'sway-ipc.*.sock' -type s 2>/dev/null \
            | head -1) || true
        if [[ -n "$swaysock" ]]; then
            export SWAYSOCK="$swaysock"
            break
        fi
        sleep 0.3
        elapsed=$(echo "$elapsed + 0.3" | bc)
        if (( $(echo "$elapsed >= $timeout" | bc -l) )); then
            log_fail "Timed out waiting for parent Sway to start"
            return 1
        fi
        if ! kill -0 "$SWAY_PID" 2>/dev/null; then
            log_fail "Parent Sway process died during startup"
            return 1
        fi
    done

    log_info "Parent Sway running (PID=$SWAY_PID, SWAYSOCK=$SWAYSOCK)"

    # Find the Wayland display socket that sway is listening on.
    local wayland_display=""
    wayland_display=$(find "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
        -maxdepth 1 -name 'wayland-*' -type s 2>/dev/null \
        | head -1) || true
    if [[ -z "$wayland_display" ]]; then
        log_fail "Could not find Sway's Wayland display socket"
        return 1
    fi
    wayland_display=$(basename "$wayland_display")
    log_info "Parent Sway Wayland display: $wayland_display"

    # ── Start niri nested inside Sway (Winit backend) ──

    NIRI_CONFIG=$(mktemp /tmp/niri-test-config.XXXXXX.kdl)
    NIRI_LOG="/tmp/niri-test-$$.log"

    cat > "$NIRI_CONFIG" <<'NIRICFG'
// Minimal niri config for e2e testing.
layout {
    gaps 0
    default-column-width { proportion 0.5; }
}

animations {
    off
}
NIRICFG

    log_info "Starting niri (nested in Sway)..."

    # Setting WAYLAND_DISPLAY makes niri use the Winit backend, connecting
    # to the parent Sway as a Wayland client.  LIBGL_ALWAYS_SOFTWARE forces
    # Mesa to use llvmpipe (software OpenGL ES) so niri's EGL/GLES renderer
    # works without a GPU.
    env \
        WAYLAND_DISPLAY="$wayland_display" \
        LIBGL_ALWAYS_SOFTWARE=1 \
        niri --config "$NIRI_CONFIG" >"$NIRI_LOG" 2>&1 &
    NIRI_PID=$!
    track_pid "$NIRI_PID"

    # Wait for the niri IPC socket to appear.
    # Socket format: $XDG_RUNTIME_DIR/niri.<wayland_socket_name>.<pid>.sock
    local timeout=30
    elapsed=0
    while [[ -z "${NIRI_SOCKET:-}" ]]; do
        local sock
        sock=$(find "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
            -maxdepth 1 -name "niri.*.${NIRI_PID}.sock" -type s 2>/dev/null \
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
            [[ -f "$NIRI_LOG" ]] && log_warn "niri log:" && cat "$NIRI_LOG" >&2
            return 1
        fi
        if ! kill -0 "$NIRI_PID" 2>/dev/null; then
            log_fail "niri process died during startup"
            [[ -f "$NIRI_LOG" ]] && log_warn "niri log:" && cat "$NIRI_LOG" >&2
            return 1
        fi
    done

    log_info "niri running (PID=$NIRI_PID, NIRI_SOCKET=$NIRI_SOCKET)"
}

wm_cleanup() {
    [[ -n "$NIRI_CONFIG" && -f "$NIRI_CONFIG" ]] && rm -f "$NIRI_CONFIG"
    [[ -n "$SWAY_CONFIG" && -f "$SWAY_CONFIG" ]] && rm -f "$SWAY_CONFIG"
    [[ -n "$NIRI_LOG" && -f "$NIRI_LOG" ]] && rm -f "$NIRI_LOG"
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
    run_nvg_bin "$NVG_BIN" --wm niri "$1"
}

# ─── Run ───

run_tests
