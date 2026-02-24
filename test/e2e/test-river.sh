#!/usr/bin/env bash
# test-river.sh — E2E tests for nvg with River (headless Wayland).
#
# Starts River in headless mode (WLR_BACKENDS=headless) and verifies that
# nvg can navigate between windows using the Wayland protocol.
#
# River is not packaged for Ubuntu 24.04, so we download pre-built binaries
# from the Fedora repos and extract libwlroots from the matching RPM.
# We also build lswt from source to query focused window state.
#
# Requirements (installed by install_deps): river, riverctl, foot, lswt, jq
# Usage: NVG_BIN=./nvg bash test/e2e/test-river.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

WM_NAME="river"
JUNIT_SUITE="e2e-river"
JUNIT_XML="${JUNIT_XML:-$REPO_ROOT/test-results-river.xml}"

# ─── Adapter functions ───

RIVER_PID=""
RIVER_LOG=""
WINDOW_COUNTER=0

# Fedora 42 RPM URLs for river and wlroots
RIVER_RPM_URL="https://rpmfind.net/linux/fedora/linux/updates/42/Everything/x86_64/Packages/r/river-0.3.11-1.fc42.x86_64.rpm"
WLROOTS_RPM_URL="https://rpmfind.net/linux/fedora/linux/updates/42/Everything/x86_64/Packages/w/wlroots-0.19.2-1.fc42.x86_64.rpm"

# lswt source (small C project for querying Wayland toplevels)
LSWT_VERSION="v2.0.0"
LSWT_URL="https://git.sr.ht/~leon_plickat/lswt/archive/${LSWT_VERSION}.tar.gz"

install_deps() {
    log_info "Installing river runtime dependencies..."

    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends \
        foot jq rpm2cpio \
        libwayland-client0 libwayland-server0 \
        libxkbcommon0 libinput10 libevdev2 \
        libpixman-1-0 libgbm1 libdrm2 \
        libegl-mesa0 libgles2 libgl1-mesa-dri \
        libseat1 libudev1 libsystemd0 \
        libxcb-composite0 libxcb-render0 libxcb-xinput0 libxcb-ewmh2 \
        libxcb-icccm4 libxcb-res0 \
        libdisplay-info1 libliftoff0 libxcb1 \
        xwayland \
        meson ninja-build pkg-config libwayland-dev wayland-protocols

    # Install river from Fedora RPMs
    if ! command -v river &>/dev/null; then
        log_info "Installing river and wlroots from Fedora RPMs..."
        local tmpdir
        tmpdir=$(mktemp -d)

        # Download and extract river
        curl -sLo "$tmpdir/river.rpm" "$RIVER_RPM_URL"
        (cd "$tmpdir" && rpm2cpio river.rpm | cpio -idm 2>/dev/null)
        sudo install -m 755 "$tmpdir/usr/bin/river" /usr/local/bin/river
        sudo install -m 755 "$tmpdir/usr/bin/riverctl" /usr/local/bin/riverctl
        sudo install -m 755 "$tmpdir/usr/bin/rivertile" /usr/local/bin/rivertile

        # Download and extract wlroots shared library
        curl -sLo "$tmpdir/wlroots.rpm" "$WLROOTS_RPM_URL"
        (cd "$tmpdir" && rpm2cpio wlroots.rpm | cpio -idm 2>/dev/null)
        # Install libwlroots and its symlinks
        sudo find "$tmpdir" -name 'libwlroots*' -exec cp -a {} /usr/local/lib/ \;
        sudo ldconfig

        rm -rf "$tmpdir"
    fi

    # Build lswt from source for querying Wayland toplevels
    if ! command -v lswt &>/dev/null; then
        log_info "Building lswt from source..."
        local tmpdir
        tmpdir=$(mktemp -d)
        curl -sLo "$tmpdir/lswt.tar.gz" "$LSWT_URL"
        tar -xzf "$tmpdir/lswt.tar.gz" -C "$tmpdir"
        (cd "$tmpdir/lswt-${LSWT_VERSION}" && meson setup build && ninja -C build)
        sudo install -m 755 "$tmpdir/lswt-${LSWT_VERSION}/build/lswt" /usr/local/bin/lswt
        rm -rf "$tmpdir"
    fi

    log_info "river installed: $(river -version 2>&1 || echo unknown)"
    log_info "riverctl installed: $(riverctl -version 2>&1 || echo unknown)"
    log_info "lswt installed: $(lswt --version 2>&1 || echo unknown)"

    # Verify river can load its shared libraries
    if ! river -version &>/dev/null 2>&1; then
        log_warn "river binary may have missing shared libraries:"
        ldd /usr/local/bin/river 2>&1 | grep "not found" || true
    fi
}

start_wm() {
    RIVER_LOG="/tmp/river-test-$$.log"

    log_info "Starting River (headless)..."

    # River is wlroots-based, so WLR_BACKENDS=headless works.
    # WLR_RENDERER=pixman avoids needing a GPU.
    env \
        WLR_BACKENDS=headless \
        WLR_LIBINPUT_NO_DEVICES=1 \
        WLR_RENDERER=pixman \
        XDG_CURRENT_DESKTOP=river \
        river >"$RIVER_LOG" 2>&1 &
    RIVER_PID=$!
    track_pid "$RIVER_PID"

    # Wait for the Wayland display socket to appear.
    local timeout=15
    local elapsed=0
    while [[ -z "${WAYLAND_DISPLAY:-}" ]]; do
        local sock
        sock=$(find "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
            -maxdepth 1 -name 'wayland-*' -type s 2>/dev/null \
            | head -1) || true
        if [[ -n "$sock" ]]; then
            export WAYLAND_DISPLAY
            WAYLAND_DISPLAY=$(basename "$sock")
            break
        fi
        sleep 0.3
        elapsed=$(echo "$elapsed + 0.3" | bc)
        if (( $(echo "$elapsed >= $timeout" | bc -l) )); then
            log_fail "Timed out waiting for River to start"
            [[ -f "$RIVER_LOG" ]] && log_warn "river log:" && cat "$RIVER_LOG" >&2
            return 1
        fi
        if ! kill -0 "$RIVER_PID" 2>/dev/null; then
            log_fail "River process died during startup"
            [[ -f "$RIVER_LOG" ]] && log_warn "river log:" && cat "$RIVER_LOG" >&2
            return 1
        fi
    done

    # Set XDG_CURRENT_DESKTOP for nvg auto-detection
    export XDG_CURRENT_DESKTOP=river

    log_info "River running (PID=$RIVER_PID, WAYLAND_DISPLAY=$WAYLAND_DISPLAY)"
}

wm_cleanup() {
    [[ -n "$RIVER_LOG" && -f "$RIVER_LOG" ]] && rm -f "$RIVER_LOG"
    cleanup
}

spawn_window() {
    WINDOW_COUNTER=$((WINDOW_COUNTER + 1))
    # Give each window a unique title so get_focused can distinguish them.
    riverctl spawn "foot --title window-${WINDOW_COUNTER} -e sleep 120" >/dev/null 2>&1
}

wait_for_windows() {
    local expected="$1"
    local timeout="${2:-10}"
    local elapsed=0

    while true; do
        local count
        # Use lswt CSV mode to count toplevels.
        # Format: 't' = title, one line per toplevel.
        count=$(lswt -c t 2>/dev/null | wc -l) || count=0
        if [[ "$count" -ge "$expected" ]]; then
            return 0
        fi
        sleep 0.3
        elapsed=$(echo "$elapsed + 0.3" | bc)
        if (( $(echo "$elapsed >= $timeout" | bc -l) )); then
            log_warn "Timed out waiting for $expected windows (have $count)"
            log_warn "lswt output:"
            lswt 2>&1 || true
            return 1
        fi
    done
}

get_focused() {
    # Use lswt CSV mode: 't' = title, 'A' = activated state.
    # Output is tab-separated: "title\ttrue/false"
    # Each window has a unique title (window-1, window-2, ...) set at spawn.
    lswt -c tA 2>/dev/null \
        | awk -F'\t' '$2 == "true" { print $1 }' \
        | head -1
}

wm_focus() {
    riverctl focus-view "$1" >/dev/null 2>&1 || true
}

run_nvg() {
    "$NVG_BIN" --wm river "$1"
}

# ─── Run ───

run_tests
