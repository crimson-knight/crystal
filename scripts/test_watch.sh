#!/bin/bash
# ==============================================================================
#  Crystal Watch Mode - Interactive Test & Demo Script
# ==============================================================================
#
#  This script walks you through testing `crystal watch`, a new command on the
#  incremental-compilation branch that watches source files for changes and
#  automatically recompiles (and optionally re-runs) your program.
#
#  The watcher supports:
#    --run              Run the compiled binary after each successful build
#    --clear            Clear the terminal before each compilation
#    --debounce MS      Debounce window in milliseconds (default: 300)
#    --poll             Force polling mode instead of kqueue/inotify
#    --poll-interval MS Polling interval in milliseconds (default: 1000)
#    --incremental      Incremental compilation (enabled by default in watch)
#
#  Three tests are executed:
#    1. Basic watch mode   - compile, prompt user to edit, verify recompilation
#    2. Error recovery     - inject syntax error, verify detection, fix, verify
#    3. Incremental + Watch - restart with --incremental, verify cache usage
#
#  Usage:
#    ./scripts/test_watch.sh
#
# ==============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_DIR="/tmp/crystal-watch-test"
WATCH_LOG="${TEST_DIR}/watch.log"
WATCH_PID=""

# How long to wait for compilation output before declaring a timeout (seconds).
COMPILE_TIMEOUT=120
# How long to wait for recompilation after a file change (seconds).
RECOMPILE_TIMEOUT=60

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    BOLD=''
    DIM=''
    RESET=''
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

banner() {
    echo ""
    echo -e "${BOLD}============================================================${RESET}"
    echo -e "${BOLD}  $1${RESET}"
    echo -e "${BOLD}============================================================${RESET}"
    echo ""
}

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }

pass_test() {
    TESTS_TOTAL=$(( TESTS_TOTAL + 1 ))
    TESTS_PASSED=$(( TESTS_PASSED + 1 ))
    echo -e "  ${GREEN}${BOLD}PASS${RESET}  $1"
}

fail_test() {
    TESTS_TOTAL=$(( TESTS_TOTAL + 1 ))
    TESTS_FAILED=$(( TESTS_FAILED + 1 ))
    echo -e "  ${RED}${BOLD}FAIL${RESET}  $1"
    if [ -n "${2:-}" ]; then
        echo -e "        ${DIM}$2${RESET}"
    fi
}

# Wait until a pattern appears in the log file, or until a timeout elapses.
# Returns 0 on match, 1 on timeout.
wait_for_log() {
    local pattern="$1"
    local timeout_secs="${2:-$COMPILE_TIMEOUT}"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout_secs" ]; do
        if [ -f "$WATCH_LOG" ] && grep -q "$pattern" "$WATCH_LOG" 2>/dev/null; then
            return 0
        fi
        sleep 1
        elapsed=$(( elapsed + 1 ))
    done
    return 1
}

# Wait until a pattern appears in the log file *after* a given line count
# (i.e., new output only). Returns 0 on match, 1 on timeout.
wait_for_new_log() {
    local pattern="$1"
    local baseline_lines="$2"
    local timeout_secs="${3:-$RECOMPILE_TIMEOUT}"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout_secs" ]; do
        if [ -f "$WATCH_LOG" ]; then
            local current_lines
            current_lines=$(wc -l < "$WATCH_LOG" | tr -d ' ')
            if [ "$current_lines" -gt "$baseline_lines" ]; then
                if tail -n +"$(( baseline_lines + 1 ))" "$WATCH_LOG" | grep -q "$pattern" 2>/dev/null; then
                    return 0
                fi
            fi
        fi
        sleep 1
        elapsed=$(( elapsed + 1 ))
    done
    return 1
}

# Get the current line count of the watch log (used as a baseline).
log_line_count() {
    if [ -f "$WATCH_LOG" ]; then
        wc -l < "$WATCH_LOG" | tr -d ' '
    else
        echo 0
    fi
}

# Start `crystal watch` in the background, redirecting all output to the log.
start_watch() {
    local extra_args=("$@")
    info "Starting: ${CRYSTAL} watch --run --poll --poll-interval 500 ${extra_args[*]:-} main.cr"
    info "Working directory: ${TEST_DIR}"
    info "Log file: ${WATCH_LOG}"
    echo ""

    # Truncate the log before each fresh start.
    > "$WATCH_LOG"

    cd "$TEST_DIR"
    "${CRYSTAL}" watch --run --poll --poll-interval 500 "${extra_args[@]}" main.cr \
        > "$WATCH_LOG" 2>&1 &
    WATCH_PID=$!
    cd "$REPO_ROOT"

    # Give it a moment to start up.
    sleep 1

    # Verify the process is actually running.
    if ! kill -0 "$WATCH_PID" 2>/dev/null; then
        error "Watch process exited immediately. Log contents:"
        cat "$WATCH_LOG" 2>/dev/null || true
        WATCH_PID=""
        return 1
    fi
}

# Stop any running watch process.
stop_watch() {
    if [ -n "$WATCH_PID" ] && kill -0 "$WATCH_PID" 2>/dev/null; then
        info "Stopping watch process (PID ${WATCH_PID})..."
        kill "$WATCH_PID" 2>/dev/null || true
        # Wait up to 5 seconds for graceful exit.
        local waited=0
        while kill -0 "$WATCH_PID" 2>/dev/null && [ "$waited" -lt 5 ]; do
            sleep 1
            waited=$(( waited + 1 ))
        done
        # Force kill if still alive.
        if kill -0 "$WATCH_PID" 2>/dev/null; then
            kill -9 "$WATCH_PID" 2>/dev/null || true
        fi
        wait "$WATCH_PID" 2>/dev/null || true
        WATCH_PID=""
    fi
}

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------

cleanup() {
    echo ""
    info "Cleaning up..."
    stop_watch
    if [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
        info "Removed ${TEST_DIR}"
    fi
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

banner "Crystal Watch Mode - Interactive Test & Demo"

echo -e "  This script tests the ${BOLD}crystal watch${RESET} command, which watches"
echo    "  source files for changes and automatically recompiles."
echo ""
echo -e "  ${DIM}Branch: incremental-compilation${RESET}"
echo -e "  ${DIM}Temp directory: ${TEST_DIR}${RESET}"
echo ""

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

banner "Prerequisites"

# Locate the Crystal compiler.
CRYSTAL=""
if command -v crystal-alpha >/dev/null 2>&1; then
    CRYSTAL="$(command -v crystal-alpha)"
    info "Found crystal-alpha in PATH: ${CRYSTAL}"
elif [ -x "${REPO_ROOT}/.build/crystal" ]; then
    CRYSTAL="${REPO_ROOT}/.build/crystal"
    info "Using local build: ${CRYSTAL}"
else
    error "Could not find crystal-alpha in PATH or ${REPO_ROOT}/.build/crystal"
    error "Please build the compiler first:  ./scripts/build_incremental.sh"
    exit 1
fi

CRYSTAL_VERSION="$("${CRYSTAL}" --version 2>&1 | head -1)"
info "Compiler version: ${CRYSTAL_VERSION}"

# Verify the compiler supports the watch command by checking help output.
if ! "${CRYSTAL}" help 2>&1 | grep -q "watch"; then
    error "This compiler does not appear to support 'crystal watch'."
    error "Make sure you are using the incremental-compilation branch build."
    exit 1
fi
success "Compiler supports 'crystal watch'"
echo ""

# Verify the fibonacci sample exists.
FIBONACCI_SRC="${REPO_ROOT}/samples/fibonacci.cr"
if [ ! -f "$FIBONACCI_SRC" ]; then
    error "Sample file not found: ${FIBONACCI_SRC}"
    exit 1
fi
success "Sample source found: ${FIBONACCI_SRC}"

# ---------------------------------------------------------------------------
# Set up test directory
# ---------------------------------------------------------------------------

info "Creating test directory: ${TEST_DIR}"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

cp "$FIBONACCI_SRC" "${TEST_DIR}/main.cr"
success "Copied fibonacci.cr -> ${TEST_DIR}/main.cr"
echo ""

# ===========================================================================
#  Test 1: Basic Watch Mode
# ===========================================================================

banner "Test 1: Basic Watch Mode"

echo -e "  This test verifies that ${BOLD}crystal watch --run${RESET} performs an"
echo    "  initial compilation, then detects file changes and recompiles."
echo ""

start_watch || { fail_test "Basic watch mode - failed to start"; }

if [ -n "$WATCH_PID" ]; then
    info "Waiting for initial compilation (up to ${COMPILE_TIMEOUT}s)..."

    if wait_for_log "Compiled successfully" "$COMPILE_TIMEOUT"; then
        success "Initial compilation succeeded"
        echo ""
        echo -e "  ${DIM}--- Watch log (initial) ---${RESET}"
        cat "$WATCH_LOG" | while IFS= read -r line; do echo "  $line"; done
        echo -e "  ${DIM}--- end ---${RESET}"
        echo ""

        # -- Interactive prompt: ask the user to edit the file --
        BASELINE=$(log_line_count)
        echo -e "${YELLOW}${BOLD}  ACTION REQUIRED:${RESET}"
        echo -e "  Edit ${BOLD}${TEST_DIR}/main.cr${RESET} in your editor."
        echo -e "  For example, change the range (0..9) to (0..14) and save."
        echo ""
        read -rp "  Press Enter after saving your changes... "
        echo ""

        info "Watching for recompilation (up to ${RECOMPILE_TIMEOUT}s)..."

        if wait_for_new_log "Compiled successfully" "$BASELINE" "$RECOMPILE_TIMEOUT"; then
            echo ""
            echo -e "  ${DIM}--- Watch log (recompilation) ---${RESET}"
            tail -n +"$(( BASELINE + 1 ))" "$WATCH_LOG" | while IFS= read -r line; do echo "  $line"; done
            echo -e "  ${DIM}--- end ---${RESET}"
            echo ""
            pass_test "Basic watch mode - recompilation detected"
        else
            echo ""
            echo -e "  ${DIM}--- Watch log (full) ---${RESET}"
            cat "$WATCH_LOG" | while IFS= read -r line; do echo "  $line"; done
            echo -e "  ${DIM}--- end ---${RESET}"
            echo ""
            fail_test "Basic watch mode - recompilation not detected" "Timed out waiting for recompilation"
        fi
    else
        echo ""
        echo -e "  ${DIM}--- Watch log ---${RESET}"
        cat "$WATCH_LOG" 2>/dev/null | while IFS= read -r line; do echo "  $line"; done
        echo -e "  ${DIM}--- end ---${RESET}"
        echo ""
        fail_test "Basic watch mode - initial compilation" "Timed out waiting for 'Compiled successfully'"
    fi

    stop_watch
fi

# ===========================================================================
#  Test 2: Error Recovery
# ===========================================================================

banner "Test 2: Error Recovery"

echo -e "  This test verifies that ${BOLD}crystal watch${RESET} detects syntax errors"
echo    "  and recovers when the error is fixed."
echo ""

# Reset the source file to a known good state.
cp "$FIBONACCI_SRC" "${TEST_DIR}/main.cr"

start_watch || { fail_test "Error recovery - failed to start"; }

if [ -n "$WATCH_PID" ]; then
    info "Waiting for initial compilation (up to ${COMPILE_TIMEOUT}s)..."

    if wait_for_log "Compiled successfully" "$COMPILE_TIMEOUT"; then
        success "Initial compilation succeeded"
        echo ""

        # -- Inject a syntax error --
        BASELINE=$(log_line_count)
        info "Injecting syntax error into main.cr..."
        echo "" >> "${TEST_DIR}/main.cr"
        echo "end end  # deliberate syntax error" >> "${TEST_DIR}/main.cr"
        info "Added 'end end' to the bottom of the file"

        if wait_for_new_log "Compilation failed" "$BASELINE" "$RECOMPILE_TIMEOUT"; then
            success "Syntax error was detected by the watcher"
            echo ""
            echo -e "  ${DIM}--- Error output ---${RESET}"
            tail -n +"$(( BASELINE + 1 ))" "$WATCH_LOG" | while IFS= read -r line; do echo "  $line"; done
            echo -e "  ${DIM}--- end ---${RESET}"
            echo ""

            # -- Fix the error --
            BASELINE=$(log_line_count)
            info "Fixing syntax error (restoring original file)..."
            cp "$FIBONACCI_SRC" "${TEST_DIR}/main.cr"

            if wait_for_new_log "Compiled successfully" "$BASELINE" "$RECOMPILE_TIMEOUT"; then
                success "Recovery compilation succeeded after fixing the error"
                echo ""
                pass_test "Error recovery - detected error and recovered"
            else
                echo ""
                echo -e "  ${DIM}--- Watch log (recovery) ---${RESET}"
                tail -n +"$(( BASELINE + 1 ))" "$WATCH_LOG" | while IFS= read -r line; do echo "  $line"; done
                echo -e "  ${DIM}--- end ---${RESET}"
                echo ""
                fail_test "Error recovery - did not recompile after fix" "Timed out waiting for successful recompilation"
            fi
        else
            echo ""
            echo -e "  ${DIM}--- Watch log ---${RESET}"
            tail -n +"$(( BASELINE + 1 ))" "$WATCH_LOG" | while IFS= read -r line; do echo "  $line"; done
            echo -e "  ${DIM}--- end ---${RESET}"
            echo ""
            fail_test "Error recovery - error not detected" "Timed out waiting for 'Compilation failed'"
        fi
    else
        fail_test "Error recovery - initial compilation" "Timed out waiting for 'Compiled successfully'"
    fi

    stop_watch
fi

# ===========================================================================
#  Test 3: Incremental + Watch
# ===========================================================================

banner "Test 3: Incremental + Watch"

echo -e "  This test verifies that ${BOLD}crystal watch --incremental${RESET} uses"
echo    "  the incremental compilation cache across recompilations."
echo -e "  ${DIM}(Note: watch mode enables --incremental by default, but we"
echo -e "  pass it explicitly here for clarity.)${RESET}"
echo ""

# Reset the source file.
cp "$FIBONACCI_SRC" "${TEST_DIR}/main.cr"

# Clean any leftover incremental cache.
rm -rf "${TEST_DIR}/.crystal" 2>/dev/null || true

start_watch --incremental || { fail_test "Incremental watch - failed to start"; }

if [ -n "$WATCH_PID" ]; then
    info "Waiting for initial compilation (up to ${COMPILE_TIMEOUT}s)..."

    if wait_for_log "Compiled successfully" "$COMPILE_TIMEOUT"; then
        success "Initial incremental compilation succeeded"
        echo ""

        # Check if an incremental cache directory was created.
        CACHE_EXISTS=false
        if [ -d "${TEST_DIR}/.crystal" ]; then
            CACHE_EXISTS=true
            CACHE_FILES=$(find "${TEST_DIR}/.crystal" -type f 2>/dev/null | wc -l | tr -d ' ')
            success "Incremental cache directory found (${CACHE_FILES} file(s))"
        else
            info "No .crystal cache directory found (may be stored elsewhere)"
        fi

        # -- Touch the file to trigger recompilation --
        BASELINE=$(log_line_count)
        info "Touching main.cr to trigger recompilation..."
        sleep 1  # Ensure mtime changes by at least 1 second.
        touch "${TEST_DIR}/main.cr"

        if wait_for_new_log "Compiled successfully" "$BASELINE" "$RECOMPILE_TIMEOUT"; then
            success "Recompilation with incremental cache succeeded"
            echo ""
            echo -e "  ${DIM}--- Recompilation log ---${RESET}"
            tail -n +"$(( BASELINE + 1 ))" "$WATCH_LOG" | while IFS= read -r line; do echo "  $line"; done
            echo -e "  ${DIM}--- end ---${RESET}"
            echo ""

            # If there is a cache directory, check it still has files.
            if [ "$CACHE_EXISTS" = true ]; then
                CACHE_FILES_AFTER=$(find "${TEST_DIR}/.crystal" -type f 2>/dev/null | wc -l | tr -d ' ')
                info "Incremental cache after recompilation: ${CACHE_FILES_AFTER} file(s)"
            fi

            pass_test "Incremental + watch - recompilation with cache"
        else
            echo ""
            echo -e "  ${DIM}--- Watch log ---${RESET}"
            tail -n +"$(( BASELINE + 1 ))" "$WATCH_LOG" | while IFS= read -r line; do echo "  $line"; done
            echo -e "  ${DIM}--- end ---${RESET}"
            echo ""
            fail_test "Incremental + watch - recompilation after touch" "Timed out waiting for recompilation"
        fi
    else
        echo ""
        echo -e "  ${DIM}--- Watch log ---${RESET}"
        cat "$WATCH_LOG" 2>/dev/null | while IFS= read -r line; do echo "  $line"; done
        echo -e "  ${DIM}--- end ---${RESET}"
        echo ""
        fail_test "Incremental + watch - initial compilation" "Timed out waiting for 'Compiled successfully'"
    fi

    stop_watch
fi

# ===========================================================================
#  Summary
# ===========================================================================

banner "Test Summary"

echo -e "  Total:   ${TESTS_TOTAL}"
echo -e "  Passed:  ${GREEN}${TESTS_PASSED}${RESET}"
echo -e "  Failed:  ${RED}${TESTS_FAILED}${RESET}"
echo ""

if [ "$TESTS_FAILED" -eq 0 ] && [ "$TESTS_TOTAL" -gt 0 ]; then
    echo -e "  ${GREEN}${BOLD}All tests passed.${RESET}"
else
    echo -e "  ${RED}${BOLD}Some tests failed.${RESET} Review the output above for details."
fi

echo ""
info "Done. $(date '+%Y-%m-%d %H:%M:%S')"

# Exit with non-zero if any tests failed.
exit "$TESTS_FAILED"
