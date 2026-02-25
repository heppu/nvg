#!/usr/bin/env bash
# helpers.sh — Shared functions and test runner for nvg e2e tests.
#
# Source this file from per-WM test scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/helpers.sh"
#
# Each WM script must define the following adapter functions before calling
# run_tests:
#
#   install_deps          Install WM-specific packages
#   start_wm              Start the WM in headless mode
#   wm_cleanup            Clean up WM-specific resources, then call cleanup
#   spawn_window          Spawn a new window in the WM
#   wait_for_windows N    Wait until at least N windows are visible
#   get_focused           Return an identifier for the currently focused window
#   wm_focus DIRECTION    Move focus using the WM's native command
#   run_nvg DIRECTION     Invoke nvg with the correct env/args for this WM

set -euo pipefail

# ─── Configuration ───

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NVG_BIN="${NVG_BIN:?NVG_BIN must be set to the path of the nvg binary}"

# JUnit XML output. Set JUNIT_XML to a file path before calling print_summary
# to write test results in JUnit format. Set JUNIT_SUITE to name the test suite.
JUNIT_XML="${JUNIT_XML:-}"
JUNIT_SUITE="${JUNIT_SUITE:-e2e}"

# WM name for log output. Override in per-WM scripts.
WM_NAME="${WM_NAME:-unknown}"

# Per-command timeout (seconds) for run_test. Prevents a single hung
# command from blocking the entire test suite.
TEST_CMD_TIMEOUT="${TEST_CMD_TIMEOUT:-30}"

# ─── Coverage ───

# Set KCOV_DIR to a directory path to enable kcov coverage collection.
# Each run_nvg_bin invocation will be wrapped with kcov --collect-only,
# and finalize_coverage will generate the final Cobertura XML report.
KCOV_DIR="${KCOV_DIR:-}"

# run_nvg_bin [ENV...] BINARY ARGS...
#   Invoke the nvg binary, optionally under kcov for coverage collection.
#   Use this from each WM's run_nvg function instead of calling $NVG_BIN directly.
#   If KCOV_DIR is set, wraps the invocation with kcov --collect-only.
run_nvg_bin() {
    if [[ -n "$KCOV_DIR" ]]; then
        kcov --collect-only --include-pattern=src/ "$KCOV_DIR" "$@"
    else
        "$@"
    fi
}

# finalize_coverage
#   Generate the final Cobertura XML report from accumulated kcov data.
#   Call this after all tests have completed.
finalize_coverage() {
    [[ -z "$KCOV_DIR" ]] && return 0
    log_info "Generating coverage report..."
    kcov --report-only --cobertura-only "$KCOV_DIR" "$NVG_BIN" || true
    log_info "Coverage report written to $KCOV_DIR"
}

# ─── Counters ───

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# ─── JUnit result recording ───

# Parallel arrays to record test results for JUnit XML output.
JUNIT_NAMES=()
JUNIT_STATUSES=()   # "pass" or "fail"
JUNIT_MESSAGES=()

# _record_result NAME STATUS MESSAGE
#   Records a test result for JUnit XML generation.
_record_result() {
    JUNIT_NAMES+=("$1")
    JUNIT_STATUSES+=("$2")
    JUNIT_MESSAGES+=("$3")
}

# ─── PID tracking for cleanup ───

CLEANUP_PIDS=()

# ─── Colors ───

if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    GREEN='' RED='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

# ─── Logging ───

log_info()  { echo -e "${BLUE}[INFO]${RESET}  $*"; }
log_pass()  { echo -e "${GREEN}[PASS]${RESET}  $*"; }
log_fail()  { echo -e "${RED}[FAIL]${RESET}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }

# ─── Test assertions ───

# run_test LABEL EXPECTED_EXIT COMMAND [ARGS...]
#   Runs COMMAND, checks exit code matches EXPECTED_EXIT.
#   Each command is wrapped with a timeout (TEST_CMD_TIMEOUT seconds)
#   to prevent a single hung command from blocking the suite.
run_test() {
    local label="$1"
    local expected_exit="$2"
    shift 2

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    local actual_exit=0
    # Run the command in a background subshell with a timeout.
    # We can't use `timeout` directly because the command may be a shell
    # function (e.g. run_nvg) which isn't visible to external programs.
    ( "$@" ) >/dev/null 2>&1 &
    local cmd_pid=$!
    local timed_out=false
    ( sleep "$TEST_CMD_TIMEOUT" && kill "$cmd_pid" 2>/dev/null ) &
    local timer_pid=$!
    wait "$cmd_pid" 2>/dev/null || actual_exit=$?
    # Cancel the timer if the command finished before the timeout.
    kill "$timer_pid" 2>/dev/null || true
    wait "$timer_pid" 2>/dev/null || true
    # If the command was killed by our timer, treat it as a timeout (exit 124).
    if [[ "$actual_exit" -eq 137 || "$actual_exit" -eq 143 ]]; then
        timed_out=true
    fi

    if [[ "$timed_out" == true ]]; then
        local msg="command timed out after ${TEST_CMD_TIMEOUT}s"
        log_fail "$label ($msg)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        _record_result "$label" "fail" "$msg"
    elif [[ "$actual_exit" -eq "$expected_exit" ]]; then
        log_pass "$label (exit=$actual_exit)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        _record_result "$label" "pass" ""
    else
        local msg="expected exit=$expected_exit, got exit=$actual_exit"
        log_fail "$label ($msg)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        _record_result "$label" "fail" "$msg"
    fi
}

# assert_focus_changed LABEL BEFORE_ID AFTER_ID
#   Verifies that the focused window changed.
assert_focus_changed() {
    local label="$1"
    local before="$2"
    local after="$3"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [[ "$before" != "$after" && -n "$after" ]]; then
        log_pass "$label (focus moved: $before -> $after)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        _record_result "$label" "pass" ""
    else
        local msg="focus did not change: before=$before after=$after"
        log_fail "$label ($msg)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        _record_result "$label" "fail" "$msg"
    fi
}

# assert_focus_unchanged LABEL BEFORE_ID AFTER_ID
#   Verifies that the focused window stayed the same.
assert_focus_unchanged() {
    local label="$1"
    local before="$2"
    local after="$3"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [[ "$before" == "$after" ]]; then
        log_pass "$label (focus unchanged: $before)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        _record_result "$label" "pass" ""
    else
        local msg="focus unexpectedly changed: $before -> $after"
        log_fail "$label ($msg)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        _record_result "$label" "fail" "$msg"
    fi
}

# ─── Utilities ───

# wait_for_socket PATH [TIMEOUT_SEC]
#   Polls until a Unix socket exists at PATH, or times out.
wait_for_socket() {
    local sock_path="$1"
    local timeout="${2:-10}"
    local elapsed=0

    log_info "Waiting for socket: $sock_path (timeout: ${timeout}s)"
    while [[ ! -S "$sock_path" ]]; do
        sleep 0.2
        elapsed=$(echo "$elapsed + 0.2" | bc)
        if (( $(echo "$elapsed >= $timeout" | bc -l) )); then
            log_fail "Timed out waiting for socket: $sock_path"
            return 1
        fi
    done
    log_info "Socket ready (${elapsed}s)"
}

# track_pid PID
#   Adds a PID to the cleanup list.
track_pid() {
    CLEANUP_PIDS+=("$1")
}

# cleanup
#   Kills all tracked PIDs (best-effort). Called via trap.
cleanup() {
    log_info "Cleaning up..."
    for pid in "${CLEANUP_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 0.3
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    wait 2>/dev/null || true
}

# ─── JUnit XML generation ───

# _xml_escape STRING
#   Escapes special XML characters in STRING.
_xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    s="${s//\'/&apos;}"
    printf '%s' "$s"
}

# _write_junit_xml
#   Writes JUnit XML to JUNIT_XML if set.
_write_junit_xml() {
    [[ -z "$JUNIT_XML" ]] && return 0

    mkdir -p "$(dirname "$JUNIT_XML")"

    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuites tests=\"$TESTS_TOTAL\" failures=\"$TESTS_FAILED\">"
        echo "  <testsuite name=\"$(_xml_escape "$JUNIT_SUITE")\" tests=\"$TESTS_TOTAL\" failures=\"$TESTS_FAILED\">"

        for i in "${!JUNIT_NAMES[@]}"; do
            local name
            name=$(_xml_escape "${JUNIT_NAMES[$i]}")
            if [[ "${JUNIT_STATUSES[$i]}" == "pass" ]]; then
                echo "    <testcase name=\"$name\" />"
            else
                local msg
                msg=$(_xml_escape "${JUNIT_MESSAGES[$i]}")
                echo "    <testcase name=\"$name\">"
                echo "      <failure message=\"$msg\" />"
                echo "    </testcase>"
            fi
        done

        echo "  </testsuite>"
        echo "</testsuites>"
    } > "$JUNIT_XML"

    log_info "JUnit XML written to $JUNIT_XML"
}

# ─── Summary ───

# print_summary
#   Prints test results, writes JUnit XML if configured, and exits.
print_summary() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════${RESET}"
    echo -e "${BOLD} Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed, ${TESTS_TOTAL} total${RESET}"
    echo -e "${BOLD}═══════════════════════════════════════${RESET}"
    echo ""

    _write_junit_xml
    finalize_coverage

    if [[ "$TESTS_FAILED" -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

# ─── Shared test runner ───
#
# Requires the following adapter functions to be defined by the caller:
#   run_nvg DIRECTION     — invoke nvg for this WM
#   get_focused           — return focused window identifier
#   wm_focus DIRECTION    — move focus using the WM's native command
#   spawn_window          — spawn a new window
#   wait_for_windows N    — wait until N windows are visible
#   start_wm              — start the WM
#   wm_cleanup            — WM-specific cleanup (must call cleanup at the end)
#   install_deps          — install WM-specific packages

run_tests() {
    trap wm_cleanup EXIT

    log_info "=== nvg e2e tests: $WM_NAME ==="
    echo ""

    if [[ ! -x "$NVG_BIN" ]]; then
        log_fail "nvg binary not found: $NVG_BIN"
        exit 1
    fi
    log_info "Using nvg binary: $NVG_BIN"

    install_deps
    start_wm

    # ─── Test 1: No windows — nvg should exit 0 ───

    log_info "--- Test group: No windows ---"
    run_test "nvg left (no windows)" 0 run_nvg left
    run_test "nvg right (no windows)" 0 run_nvg right

    # ─── Test 2: Single window — nvg should exit 0, focus unchanged ───

    log_info "--- Test group: Single window ---"
    spawn_window
    wait_for_windows 1
    sleep 0.5

    # Wait until the WM has actually focused the new window.
    local _focus_wait=0
    while [[ -z "$(get_focused)" ]]; do
        sleep 0.2
        _focus_wait=$(echo "$_focus_wait + 0.2" | bc)
        if (( $(echo "$_focus_wait >= 5" | bc -l) )); then
            log_warn "Window spawned but never received focus"
            break
        fi
    done

    FOCUS_BEFORE=$(get_focused)
    run_test "nvg right (single window)" 0 run_nvg right
    sleep 0.1
    FOCUS_AFTER=$(get_focused)
    assert_focus_unchanged "single window: focus stays" "$FOCUS_BEFORE" "$FOCUS_AFTER"

    run_test "nvg left (single window)" 0 run_nvg left
    run_test "nvg up (single window)" 0 run_nvg up
    run_test "nvg down (single window)" 0 run_nvg down

    # ─── Test 3: Two windows — nvg should navigate between them ───

    log_info "--- Test group: Two windows (horizontal) ---"
    spawn_window
    wait_for_windows 2
    sleep 0.3

    # Focus the first window (leftmost) so we have a known starting state
    wm_focus left
    sleep 0.2

    FOCUS_BEFORE=$(get_focused)
    run_test "nvg right (two windows)" 0 run_nvg right
    sleep 0.1
    FOCUS_AFTER=$(get_focused)
    assert_focus_changed "two windows: nvg right moves focus" "$FOCUS_BEFORE" "$FOCUS_AFTER"

    # Navigate back
    FOCUS_BEFORE=$(get_focused)
    run_test "nvg left (two windows, back)" 0 run_nvg left
    sleep 0.1
    FOCUS_AFTER=$(get_focused)
    assert_focus_changed "two windows: nvg left moves focus back" "$FOCUS_BEFORE" "$FOCUS_AFTER"

    # ─── Test 4: Three windows — nvg navigates through all ───

    log_info "--- Test group: Three windows ---"
    spawn_window
    wait_for_windows 3
    sleep 0.3

    # Go to leftmost window
    wm_focus left
    wm_focus left
    sleep 0.2

    FOCUS_1=$(get_focused)
    run_test "nvg right (three windows, 1->2)" 0 run_nvg right
    sleep 0.1
    FOCUS_2=$(get_focused)
    assert_focus_changed "three windows: 1->2" "$FOCUS_1" "$FOCUS_2"

    run_test "nvg right (three windows, 2->3)" 0 run_nvg right
    sleep 0.1
    FOCUS_3=$(get_focused)
    assert_focus_changed "three windows: 2->3" "$FOCUS_2" "$FOCUS_3"

    # ─── Test 5: Edge behavior ───

    log_info "--- Test group: Edge behavior ---"
    # We're at the rightmost window after the previous tests.
    FOCUS_BEFORE=$(get_focused)
    run_test "nvg right (at right edge)" 0 run_nvg right
    sleep 0.1
    FOCUS_AFTER=$(get_focused)
    log_info "Edge behavior: focus before=$FOCUS_BEFORE after=$FOCUS_AFTER (wrapping depends on $WM_NAME config)"

    # ─── Test 6: All four directions work ───

    log_info "--- Test group: All directions ---"
    run_test "nvg left" 0 run_nvg left
    run_test "nvg right" 0 run_nvg right
    run_test "nvg up" 0 run_nvg up
    run_test "nvg down" 0 run_nvg down

    # ─── Summary ───

    print_summary
}
