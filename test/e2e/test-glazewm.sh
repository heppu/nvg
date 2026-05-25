#!/usr/bin/env bash
# test-glazewm.sh — E2E tests for nvg with GlazeWM (Windows).
#
# Starts GlazeWM, spawns plain `cmd.exe` windows, and verifies that nvg
# can navigate between them.
#
# Run under Git Bash on a Windows host (the GitHub `windows-latest` runner
# provides Git Bash by default). GlazeWM needs an interactive desktop
# session — this script will not work over plain SSH without one.
#
# Requirements: glazewm (winget/choco/scoop), jq
# Usage: NVG_BIN=./nvg.exe bash test/e2e/test-glazewm.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

WM_NAME="glazewm"
JUNIT_SUITE="e2e-glazewm"
JUNIT_XML="${JUNIT_XML:-$REPO_ROOT/test-results-glazewm.xml}"

# ─── Adapter functions ───

GLAZE_PID=""
GLAZE_CONFIG=""
SPAWNED_PIDS=()

# Path to the glazewm CLI. Overridable for non-standard install locations.
GLAZE_BIN="${GLAZE_BIN:-glazewm}"

install_deps() {
    log_info "Installing GlazeWM dependencies..."

    # GitHub Actions exports these as Windows env vars; treat missing as empty
    # so `set -u` doesn't fire when the script runs outside a real Windows
    # user session.
    local localappdata="${LOCALAPPDATA:-}"
    local progfiles="${PROGRAMFILES:-${ProgramFiles:-/c/Program Files}}"

    # Skip silently if glazewm is already on PATH.
    if ! command -v "$GLAZE_BIN" >/dev/null 2>&1; then
        if command -v winget >/dev/null 2>&1; then
            # --accept-source-agreements: skip the first-run TUI prompt
            # --accept-package-agreements: skip per-package licence prompts
            winget install --id glzr-io.GlazeWM \
                --accept-source-agreements --accept-package-agreements \
                --silent --disable-interactivity || true

            # winget drops a shim in %LOCALAPPDATA%\Microsoft\WinGet\Links\
            # that's added to the *user* PATH — invisible to the current
            # shell. Add it ourselves, then fall back to common install dirs.
            if [[ -n "$localappdata" ]]; then
                export PATH="$localappdata/Microsoft/WinGet/Links:$PATH"
            fi

            if ! command -v "$GLAZE_BIN" >/dev/null 2>&1; then
                for candidate in \
                    "${localappdata}/Programs/glzr.io/GlazeWM/glazewm.exe" \
                    "${progfiles}/glzr.io/GlazeWM/glazewm.exe" \
                    "${localappdata}/Microsoft/WinGet/Links/glazewm.exe"
                do
                    if [[ -n "$candidate" && -x "$candidate" ]]; then
                        GLAZE_BIN="$candidate"
                        break
                    fi
                done
            fi
        elif command -v choco >/dev/null 2>&1; then
            choco install glazewm -y --no-progress
        else
            log_fail "no installer available (winget/choco not found)"
            return 1
        fi
    fi

    if ! command -v "$GLAZE_BIN" >/dev/null 2>&1 && [[ ! -x "$GLAZE_BIN" ]]; then
        log_fail "GlazeWM CLI not on PATH after install (tried: $GLAZE_BIN)"
        return 1
    fi
    log_info "GlazeWM CLI: $GLAZE_BIN"

    if ! command -v jq >/dev/null 2>&1; then
        if command -v winget >/dev/null 2>&1; then
            winget install --id stedolan.jq \
                --accept-source-agreements --accept-package-agreements \
                --silent --disable-interactivity || true
        elif command -v choco >/dev/null 2>&1; then
            choco install jq -y --no-progress
        fi
    fi
}

start_wm() {
    GLAZE_CONFIG="${USERPROFILE:-$HOME}/.glzr/glazewm/config.yaml"
    mkdir -p "$(dirname "$GLAZE_CONFIG")"

    # Minimal config: tiling layout, no startup commands, no animations.
    # We rely on the IPC for everything — no keybindings needed in the
    # config because the tests drive focus directly through the CLI.
    cat > "$GLAZE_CONFIG" <<'GLAZECFG'
general:
  startup_commands: []
  shutdown_commands: []
  config_reload_commands: []
  focus_follows_cursor: false

gaps:
  inner_gap: '0px'
  outer_gap: '0px'

window_effects:
  focused_window:
    border:
      enabled: false

workspaces:
  - name: '1'

window_rules: []

binding_modes: []

keybindings: []
GLAZECFG

    # Log to a path we know exists (RUNNER_TEMP on GH, $HOME otherwise).
    GLAZE_LOG="${RUNNER_TEMP:-$HOME}/glazewm.log"

    log_info "Starting GlazeWM (log: $GLAZE_LOG)..."
    "$GLAZE_BIN" start >"$GLAZE_LOG" 2>&1 &
    GLAZE_PID=$!
    track_pid "$GLAZE_PID"

    # Wait until the IPC server is accepting connections. Do NOT watch the
    # launcher PID — on Windows `glazewm start` may detach into a child,
    # leaving the launcher process exited even though the WM is up. We rely
    # solely on the IPC probe to decide whether GlazeWM is alive.
    if ! wait_until \
        '"$GLAZE_BIN" query focused >/dev/null 2>&1' \
        30 "GlazeWM IPC"
    then
        log_warn "GlazeWM did not respond on the IPC socket"
        if [[ -f "$GLAZE_LOG" ]]; then
            log_warn "GlazeWM log ($GLAZE_LOG):"
            cat "$GLAZE_LOG" >&2 || true
        else
            log_warn "no log file at $GLAZE_LOG"
        fi
        # Dump anything resembling a glazewm process so we can see if it
        # detached but is hung.
        if command -v tasklist >/dev/null 2>&1; then
            log_warn "running glazewm-like processes:"
            tasklist 2>/dev/null | grep -i glaze >&2 || log_warn "  (none)"
        fi
        return 1
    fi

    log_info "GlazeWM running (launcher PID=$GLAZE_PID)"
}

wm_cleanup() {
    # Kill all spawned cmd windows by PID.
    for pid in "${SPAWNED_PIDS[@]}"; do
        if [[ -n "$pid" ]]; then
            powershell -NoProfile -Command "Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue" || true
        fi
    done

    # Ask GlazeWM to exit cleanly before falling back to the generic killer.
    if command -v "$GLAZE_BIN" >/dev/null 2>&1 || [[ -x "$GLAZE_BIN" ]]; then
        "$GLAZE_BIN" command wm-exit >/dev/null 2>&1 || true
        sleep 0.5
    fi

    [[ -n "$GLAZE_CONFIG" && -f "$GLAZE_CONFIG" ]] && rm -f "$GLAZE_CONFIG"
    cleanup
}

# spawn_window — open a new cmd.exe window that sleeps for 5 minutes.
# We capture its PID so wm_cleanup can kill it without leaving zombies.
spawn_window() {
    # `powershell Start-Process -PassThru` returns the process object; print
    # its PID so we can track it.
    local pid
    pid=$(powershell -NoProfile -Command \
        "(Start-Process -FilePath cmd.exe -ArgumentList '/c','timeout','/t','300','/nobreak' -PassThru).Id" \
        2>/dev/null | tr -d '\r\n')
    if [[ -n "$pid" ]]; then
        SPAWNED_PIDS+=("$pid")
    fi
}

count_windows() {
    "$GLAZE_BIN" query windows 2>/dev/null \
        | jq '.data.windows | length' 2>/dev/null \
        || echo 0
}

# get_focused — return the focused window's process ID (or empty string
# when a workspace is focused / nothing is visible).
get_focused() {
    "$GLAZE_BIN" query focused 2>/dev/null \
        | jq -r '.data.focused.processName + ":" + (.data.focused.handle|tostring)' 2>/dev/null \
        || echo ""
}

wm_focus() {
    "$GLAZE_BIN" command "focus --direction $1" >/dev/null 2>&1 || true
}

run_nvg() {
    run_nvg_bin "$NVG_BIN" --wm glazewm "$1"
}

# ─── Run ───

run_tests
