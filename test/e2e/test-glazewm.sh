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
    # user session. Normalise Windows-style paths to MSYS/MINGW form
    # (`C:\Program Files` → `/c/Program Files`) — bash exec fails with
    # `Permission denied` on mixed-slash paths.
    local localappdata="${LOCALAPPDATA:-}"
    local progfiles="${PROGRAMFILES:-${ProgramFiles:-C:/Program Files}}"
    if command -v cygpath >/dev/null 2>&1; then
        [[ -n "$localappdata" ]] && localappdata="$(cygpath -u "$localappdata")"
        progfiles="$(cygpath -u "$progfiles")"
    fi

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
                # Prefer the `cli/` shim — the top-level glazewm.exe carries
                # a manifest that asks for UAC elevation; the CLI shim
                # next to it does not.
                for candidate in \
                    "${progfiles}/glzr.io/GlazeWM/cli/glazewm.exe" \
                    "${localappdata}/Programs/glzr.io/GlazeWM/cli/glazewm.exe" \
                    "${localappdata}/Microsoft/WinGet/Links/glazewm.exe" \
                    "${progfiles}/glzr.io/GlazeWM/glazewm.exe" \
                    "${localappdata}/Programs/glzr.io/GlazeWM/glazewm.exe"
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

    # Minimal config: one workspace, no keybindings, no startup commands.
    # We drive focus through the IPC directly. Anything we don't set falls
    # back to GlazeWM defaults (the schema is strict — `outer_gap` for
    # example must be a RectDelta struct, not a string).
    cat > "$GLAZE_CONFIG" <<'GLAZECFG'
general:
  startup_commands: []
  shutdown_commands: []
  config_reload_commands: []
  focus_follows_cursor: false

workspaces:
  - name: '1'

# Manage *only* the notepad windows we spawn. The CI desktop has ambient
# windows (the runner's hosted-compute-agent, stray system dialogs) that
# would otherwise tile alongside our notepads and break the shared test's
# "go to leftmost, navigate right N times" assumptions. `not_regex` ignores
# every window whose process name isn't exactly "notepad".
window_rules:
  - commands: ['ignore']
    match:
      - window_process: { not_regex: '^notepad$' }

binding_modes: []

keybindings: []
GLAZECFG

    # Log to a path we know exists (RUNNER_TEMP on GH, $HOME otherwise).
    GLAZE_LOG="${RUNNER_TEMP:-$HOME}/glazewm.log"

    log_info "Starting GlazeWM (log: $GLAZE_LOG)..."
    "$GLAZE_BIN" start >"$GLAZE_LOG" 2>&1 &
    GLAZE_PID=$!
    track_pid "$GLAZE_PID"

    # Probe the IPC server via a direct TCP connect (bash `/dev/tcp`) — much
    # faster and more reliable than spawning `glazewm query`, which can hang
    # for seconds per call when the WM is not yet ready.
    # Do NOT watch the launcher PID: on Windows `glazewm start` may detach
    # into a child, leaving the launcher exited even though the WM is up.
    if ! wait_until \
        '(exec 3<>/dev/tcp/127.0.0.1/6123) 2>/dev/null && exec 3<&-' \
        30 "GlazeWM IPC port 6123"
    then
        log_warn "GlazeWM did not bind 127.0.0.1:6123 within 30s"
        if [[ -f "$GLAZE_LOG" ]]; then
            log_warn "GlazeWM stdout/stderr ($GLAZE_LOG):"
            cat "$GLAZE_LOG" >&2 || true
        else
            log_warn "no stdout/stderr log at $GLAZE_LOG"
        fi
        # GlazeWM writes its own error log to ~/.glzr/glazewm/errors.log
        # (~ = $USERPROFILE on Windows). Fatal startup errors land there and
        # are also shown as a Win32 message box — which on a CI runner
        # hangs invisibly forever.
        local glaze_errors="${USERPROFILE:-$HOME}/.glzr/glazewm/errors.log"
        if [[ -f "$glaze_errors" ]]; then
            log_warn "GlazeWM errors.log ($glaze_errors):"
            cat "$glaze_errors" >&2 || true
        else
            log_warn "no errors.log at $glaze_errors"
        fi
        if command -v tasklist >/dev/null 2>&1; then
            log_warn "running glazewm-like processes:"
            tasklist 2>/dev/null | grep -i glaze >&2 || log_warn "  (none)"
        fi
        if command -v netstat >/dev/null 2>&1; then
            log_warn "TCP listeners (port 6123 or first 10 listeners):"
            netstat -ano 2>/dev/null | grep -E '6123|LISTENING' | head -10 >&2 || true
        fi
        # Look for any open Win32 dialog windows — a fatal init error would
        # show one with a class like "#32770".
        if command -v powershell >/dev/null 2>&1; then
            log_warn "open Win32 top-level windows owned by glazewm:"
            powershell -NoProfile -Command "Get-Process glazewm -ErrorAction SilentlyContinue | Select-Object Id, MainWindowTitle, ProcessName | Format-Table -AutoSize" 2>/dev/null >&2 || true
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

# _focused_handle — print the handle (HWND) of the focused window, or empty.
_focused_handle() {
    "$GLAZE_BIN" query focused 2>/dev/null \
        | jq -r '.data.focused.handle // empty' 2>/dev/null || true
}

# glaze_cmd — run a GlazeWM command. `glazewm command` uses clap subcommands,
# so the command and its flags must be passed as SEPARATE arguments
# (`glazewm command focus --direction left`), NOT as one quoted string — a
# quoted string fails with "unrecognized subcommand".
glaze_cmd() {
    "$GLAZE_BIN" command "$@" >/dev/null 2>&1 || true
}

# spawn_window — open a new GUI window for GlazeWM to tile.
# We capture its PID so wm_cleanup can kill it without leaving zombies.
#
# We use notepad.exe rather than a `cmd.exe` console: a console started via
# `Start-Process` in CI has no real console stdin, so commands like
# `timeout`/`pause` abort immediately ("Input redirection is not supported")
# and the window closes before GlazeWM can tile it. notepad is a plain Win32
# top-level window that stays open until killed and is reliably managed by
# GlazeWM. On the windows-latest runner (Windows Server) this is classic
# single-window-per-process notepad, so each launch yields a new tiled window.
spawn_window() {
    # GlazeWM chooses each split's direction from the focused window's current
    # dimensions (BSP-style), so a third window nests *perpendicular* (e.g.
    # below window 2). That breaks the shared test's assumption of a flat
    # left-to-right row and leaves the last window unreachable via
    # `focus --direction right`. Insertion follows the focused container's
    # tiling direction, so force it horizontal *before* spawning — the new
    # window then joins the row as a flat sibling instead of nesting.
    glaze_cmd set-tiling-direction horizontal

    # Remember what was focused so we can detect when GlazeWM focuses the new
    # window (its handle will differ). All our windows are notepad, so the
    # handle — not the process name — is what distinguishes them.
    local before_handle
    before_handle=$(_focused_handle)

    # Launch notepad and wait until its UI message loop goes idle
    # (WaitForInputIdle), i.e. it has finished initializing and issuing its
    # startup foreground-focus grabs. A freshly launched notepad otherwise
    # re-asserts foreground a beat after creation and GlazeWM snaps focus back
    # to it — which races with, and clobbers, the directional-focus commands
    # the shared test issues immediately after spawning. `-PassThru` yields the
    # process object so we can print its PID for cleanup.
    local pid
    pid=$(powershell -NoProfile -Command \
        '$p = Start-Process -FilePath notepad.exe -PassThru; $p.WaitForInputIdle(5000) | Out-Null; $p.Id' \
        2>/dev/null | tr -d '\r\n')
    if [[ -n "$pid" ]]; then
        SPAWNED_PIDS+=("$pid")
    fi

    # Wait until GlazeWM has managed and focused the new window, then let focus
    # settle before the test starts issuing directional-focus commands.
    wait_until '[[ -n "$(_focused_handle)" && "$(_focused_handle)" != "'"$before_handle"'" ]]' \
        5 "GlazeWM focus on new window" || true
    sleep 1
    # Make the new window's container horizontal too (belt and suspenders).
    glaze_cmd set-tiling-direction horizontal

    # Diagnostic: dump the container tree so failures show the actual layout.
    if [[ -n "${GLAZE_DUMP_TREE:-}" ]]; then
        log_info "layout after spawn (pid=${pid:-?}):"
        "$GLAZE_BIN" query monitors 2>/dev/null | jq -r '
            def show(ind):
                (ind + .type
                    + (if .tilingDirection then " [" + .tilingDirection + "]" else "" end)
                    + (if .handle then " h=" + (.handle|tostring) + " " + (.processName // "") else "" end)),
                (.children[]? | show(ind + "  "));
            .data.monitors[]? | show("")
        ' >&2 2>/dev/null || true
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
    glaze_cmd focus --direction "$1"
}

run_nvg() {
    run_nvg_bin "$NVG_BIN" --wm glazewm "$1"
}

# ─── Run ───

run_tests
