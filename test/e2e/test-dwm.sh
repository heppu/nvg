#!/usr/bin/env bash
# test-dwm.sh — E2E tests for nvg with dwm (Xvfb headless X11 + dwmfifo).
#
# Starts Xvfb (virtual framebuffer) and dwm with the dwmfifo patch, spawns
# xterm windows, and verifies that nvg can navigate between them.
#
# Requirements: dwm (with dwmfifo patch), xvfb, xterm, xdotool, jq, x11-utils
# Usage: bash test/e2e/test-dwm.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

WM_NAME="dwm"
JUNIT_SUITE="e2e-dwm"
JUNIT_XML="${JUNIT_XML:-$REPO_ROOT/test-results-dwm.xml}"

# ─── Adapter functions ───

DWM_PID=""
XVFB_PID=""
DISPLAY_NUM=":99"
DWM_FIFO_PATH="/tmp/dwm.fifo"

install_deps() {
    log_info "Installing dwm build dependencies..."
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends \
        build-essential libx11-dev libxft-dev libxinerama-dev \
        xvfb xterm xdotool x11-utils xfonts-base jq git

    # Build dwm from source with the dwmfifo patch applied.
    # The stock dwm package does not include the dwmfifo patch.
    local build_dir
    build_dir=$(mktemp -d)
    log_info "Building dwm with dwmfifo patch in $build_dir..."

    git clone --depth=50 https://git.suckless.org/dwm "$build_dir"
    git -C "$build_dir" checkout e81f17d

    wget -q "https://dwm.suckless.org/patches/dwmfifo/dwm-dwmfifo-20230714-e81f17d.diff" \
        -O "$build_dir/dwmfifo.diff"

    (
        cd "$build_dir"
        patch -p1 < dwmfifo.diff
        sudo make clean install
    )
    rm -rf "$build_dir"
    log_info "dwm with dwmfifo installed at $(command -v dwm)"
}

start_wm() {
    # Start Xvfb (virtual framebuffer)
    log_info "Starting Xvfb on $DISPLAY_NUM..."
    Xvfb "$DISPLAY_NUM" -screen 0 1920x1080x24 +extension RANDR &>/dev/null &
    XVFB_PID=$!
    track_pid "$XVFB_PID"

    # Wait for Xvfb to be ready
    local timeout=10
    local elapsed=0
    while ! DISPLAY="$DISPLAY_NUM" xdpyinfo &>/dev/null; do
        sleep 0.2
        elapsed=$(echo "$elapsed + 0.2" | bc)
        if (( $(echo "$elapsed >= $timeout" | bc -l) )); then
            log_fail "Timed out waiting for Xvfb"
            return 1
        fi
    done
    log_info "Xvfb ready"

    # Clean up any stale FIFO from a previous run and create a fresh one.
    # The dwmfifo patch expects the FIFO to already exist — dwm opens it
    # with O_RDWR but does not create it.
    if [[ -e "$DWM_FIFO_PATH" ]]; then
        rm -f "$DWM_FIFO_PATH"
    fi
    mkfifo "$DWM_FIFO_PATH"
    log_info "Created FIFO at $DWM_FIFO_PATH"

    # Start dwm
    log_info "Starting dwm..."
    DISPLAY="$DISPLAY_NUM" dwm &>/dev/null &
    DWM_PID=$!
    track_pid "$DWM_PID"

    # Wait for dwm to be ready (check that it's managing the root window)
    local elapsed=0
    local timeout=15
    while true; do
        if DISPLAY="$DISPLAY_NUM" xdotool getactivewindow &>/dev/null 2>&1 ||
           DISPLAY="$DISPLAY_NUM" xprop -root _NET_SUPPORTING_WM_CHECK &>/dev/null 2>&1; then
            break
        fi
        sleep 0.3
        elapsed=$(echo "$elapsed + 0.3" | bc)
        if (( $(echo "$elapsed >= $timeout" | bc -l) )); then
            log_fail "Timed out waiting for dwm to start"
            return 1
        fi
        if ! kill -0 "$DWM_PID" 2>/dev/null; then
            log_fail "dwm process died during startup"
            return 1
        fi
    done

    export DWM_FIFO="$DWM_FIFO_PATH"
    log_info "dwm running (PID=$DWM_PID, DWM_FIFO=$DWM_FIFO_PATH, DISPLAY=$DISPLAY_NUM)"
}

wm_cleanup() {
    [[ -e "$DWM_FIFO_PATH" ]] && rm -f "$DWM_FIFO_PATH"
    cleanup
}

spawn_window() {
    DISPLAY="$DISPLAY_NUM" xterm -e sleep 120 &
    track_pid "$!"
}

wait_for_windows() {
    local expected="$1"
    local timeout="${2:-10}"
    local elapsed=0

    while true; do
        local count
        count=$(DISPLAY="$DISPLAY_NUM" xdotool search --onlyvisible --name "" 2>/dev/null | wc -l) || count=0
        if [[ "$count" -ge "$expected" ]]; then
            return 0
        fi
        sleep 0.3
        elapsed=$(echo "$elapsed + 0.3" | bc)
        if (( $(echo "$elapsed >= $timeout" | bc -l) )); then
            log_warn "Timed out waiting for $expected windows (have $count)"
            log_warn "xterm processes:"
            ps aux | grep xterm || true
            return 1
        fi
    done
}

get_focused() {
    DISPLAY="$DISPLAY_NUM" xdotool getactivewindow 2>/dev/null || echo ""
}

wm_focus() {
    local direction="$1"
    # dwm uses focusstack for cycling through windows via the FIFO.
    # left/up = previous (focusstack-), right/down = next (focusstack+)
    case "$direction" in
        left|up)
            echo "focusstack-" > "$DWM_FIFO_PATH"
            ;;
        right|down)
            echo "focusstack+" > "$DWM_FIFO_PATH"
            ;;
    esac
}

run_nvg() {
    env DISPLAY="$DISPLAY_NUM" DWM_FIFO="$DWM_FIFO_PATH" "$NVG_BIN" --wm dwm "$1"
}

# ─── Run ───

run_tests
