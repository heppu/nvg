#!/usr/bin/env bash
# test-river.sh — E2E tests for nvg with River (headless Wayland).
#
# Starts River in headless mode (WLR_BACKENDS=headless) and verifies that
# nvg can navigate between windows using the Wayland protocol.
#
# River and wlroots are not packaged for Ubuntu 24.04, so we build them
# from source (wlroots 0.17.x + river 0.3.4). We also build lswt from
# source to query focused window state.
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

# Source versions — wlroots 0.17.x is the newest series compatible with
# Ubuntu 24.04's system libraries (libdisplay-info 0.1.x, libinput 1.25).
WLROOTS_VERSION="0.17.4"
RIVER_VERSION="0.3.4"
ZIG_VERSION="0.13.0"

# lswt source (small C project for querying Wayland toplevels)
# We need a version newer than v2.0.0 for --force-protocol support,
# which is required to get activated/focused state from the wlr protocol.
LSWT_COMMIT="e6e93345"
LSWT_URL="https://git.sr.ht/~leon_plickat/lswt/archive/${LSWT_COMMIT}.tar.gz"

install_deps() {
    log_info "Installing river build and runtime dependencies..."

    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends \
        foot jq \
        meson ninja-build cmake pkg-config \
        libwayland-dev wayland-protocols \
        libwayland-client0 libwayland-server0 \
        libxkbcommon-dev libinput-dev libevdev-dev \
        libpixman-1-dev libdrm-dev libgbm-dev \
        libegl-dev libgles-dev \
        libseat-dev libudev-dev \
        libdisplay-info-dev liblcms2-dev \
        libxcb1-dev libxcb-composite0-dev libxcb-render0-dev \
        libxcb-render-util0-dev libxcb-xinput-dev libxcb-ewmh-dev \
        libxcb-icccm4-dev libxcb-res0-dev libxcb-dri3-dev \
        libxcb-present-dev libxcb-shm0-dev libxcb-xfixes0-dev \
        hwdata xwayland

    # Build wlroots from source
    if ! pkg-config --exists wlroots 2>/dev/null; then
        log_info "Building wlroots ${WLROOTS_VERSION} from source..."
        local tmpdir
        tmpdir=$(mktemp -d)
        curl -sLo "$tmpdir/wlroots.tar.gz" \
            "https://gitlab.freedesktop.org/wlroots/wlroots/-/archive/${WLROOTS_VERSION}/wlroots-${WLROOTS_VERSION}.tar.gz"
        tar -xzf "$tmpdir/wlroots.tar.gz" -C "$tmpdir"
        (cd "$tmpdir/wlroots-${WLROOTS_VERSION}" && meson setup build -Dprefix=/usr/local && ninja -C build)
        sudo ninja -C "$tmpdir/wlroots-${WLROOTS_VERSION}/build" install
        sudo ldconfig
        rm -rf "$tmpdir"
    fi

    # Build river from source (requires Zig 0.13.x)
    if ! command -v river &>/dev/null; then
        log_info "Building river ${RIVER_VERSION} from source..."
        local tmpdir
        tmpdir=$(mktemp -d)

        # Download Zig 0.13.x (river 0.3.4 requires this version)
        curl -sLo "$tmpdir/zig.tar.xz" \
            "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz"
        tar -xJf "$tmpdir/zig.tar.xz" -C "$tmpdir"
        local zig="$tmpdir/zig-linux-x86_64-${ZIG_VERSION}/zig"

        # Download and build river
        curl -sLo "$tmpdir/river.tar.gz" \
            "https://codeberg.org/river/river/archive/v${RIVER_VERSION}.tar.gz"
        tar -xzf "$tmpdir/river.tar.gz" -C "$tmpdir"
        (cd "$tmpdir/river" && "$zig" build -Doptimize=ReleaseSafe -Dpie=true --summary none)
        sudo install -m 755 "$tmpdir/river/zig-out/bin/river" /usr/local/bin/river
        sudo install -m 755 "$tmpdir/river/zig-out/bin/riverctl" /usr/local/bin/riverctl
        sudo install -m 755 "$tmpdir/river/zig-out/bin/rivertile" /usr/local/bin/rivertile
        rm -rf "$tmpdir"
    fi

    # Build lswt from source for querying Wayland toplevels
    if ! command -v lswt &>/dev/null; then
        log_info "Building lswt from source..."
        local tmpdir
        tmpdir=$(mktemp -d)
        curl -sLo "$tmpdir/lswt.tar.gz" "$LSWT_URL"
        tar -xzf "$tmpdir/lswt.tar.gz" -C "$tmpdir"
        (cd "$tmpdir/lswt-${LSWT_COMMIT}" && make)
        sudo install -m 755 "$tmpdir/lswt-${LSWT_COMMIT}/lswt" /usr/local/bin/lswt
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

    # Start rivertile layout generator so views get tiled with proper geometry.
    # Without a layout generator, views have no spatial position and
    # directional focus (left/right/up/down) won't work.
    # Set the default layout before starting rivertile.
    riverctl default-layout rivertile

    env WAYLAND_DISPLAY="$WAYLAND_DISPLAY" rivertile -view-padding 0 -outer-padding 0 -main-location top -main-count 999 &
    local rivertile_pid=$!
    track_pid "$rivertile_pid"
    sleep 0.5
    log_info "rivertile layout generator started (PID=$rivertile_pid)"
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
        count=$(lswt --force-protocol zwlr-foreign-toplevel-management-unstable-v1 -c t 2>/dev/null | wc -l) || count=0
        if [[ "$count" -ge "$expected" ]]; then
            return 0
        fi
        sleep 0.3
        elapsed=$(echo "$elapsed + 0.3" | bc)
        if (( $(echo "$elapsed >= $timeout" | bc -l) )); then
            log_warn "Timed out waiting for $expected windows (have $count)"
            log_warn "lswt output:"
            lswt --force-protocol zwlr-foreign-toplevel-management-unstable-v1 2>&1 || true
            return 1
        fi
    done
}

get_focused() {
    # Use lswt with wlr protocol to get activated state.
    # The ext-foreign-toplevel protocol lacks state info, so we force wlr.
    # lswt CSV mode uses comma as delimiter: "title,true/false"
    lswt --force-protocol zwlr-foreign-toplevel-management-unstable-v1 -c tA 2>/dev/null \
        | awk -F',' '$2 == "true" { print $1 }' \
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
