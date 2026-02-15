#!/usr/bin/env bash
set -euo pipefail

# Crystal WASM Validation Script
# Validates that the WASM compilation target works correctly.
#
# Usage: ./scripts/validate_wasm.sh [--quick]
#   --quick: Only check tool versions, skip compilation tests

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMP_DIR=""
PASS=0
FAIL=0
SKIP=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

cleanup() {
  if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
    rm -rf "${TEMP_DIR}"
  fi
}
trap cleanup EXIT

log_pass() { echo -e "  ${GREEN}PASS${NC} $1"; ((PASS++)); }
log_fail() { echo -e "  ${RED}FAIL${NC} $1"; ((FAIL++)); }
log_skip() { echo -e "  ${YELLOW}SKIP${NC} $1"; ((SKIP++)); }
log_info() { echo -e "  ${BLUE}INFO${NC} $1"; }
log_section() { echo -e "\n${BLUE}=== $1 ===${NC}"; }

# ─── Tool Checks ───────────────────────────────────────────────
log_section "Tool Version Checks"

check_tool() {
  local name=$1
  local cmd=$2
  if command -v "$cmd" &>/dev/null; then
    local version
    version=$("$cmd" --version 2>&1 | head -1) || version="(version unknown)"
    log_pass "$name: $version"
    return 0
  else
    log_fail "$name: not found (install $cmd)"
    return 1
  fi
}

TOOLS_OK=true
check_tool "Crystal compiler" crystal || TOOLS_OK=false
check_tool "WASM linker (wasm-ld)" wasm-ld || TOOLS_OK=false
check_tool "Binaryen optimizer (wasm-opt)" wasm-opt || TOOLS_OK=false
check_tool "Wasmtime runtime" wasmtime || TOOLS_OK=false

# Also check for LLVM version
if command -v llvm-config &>/dev/null; then
  LLVM_VER=$(llvm-config --version 2>&1)
  log_pass "LLVM: $LLVM_VER"
elif command -v llvm-config-18 &>/dev/null; then
  LLVM_VER=$(llvm-config-18 --version 2>&1)
  log_pass "LLVM: $LLVM_VER (via llvm-config-18)"
else
  log_info "LLVM: version not detected (llvm-config not in PATH)"
fi

# ─── Environment Variables ──────────────────────────────────────
log_section "Environment Variables"

if [[ -n "${WASI_SDK_PATH:-}" ]]; then
  if [[ -d "${WASI_SDK_PATH}/share/wasi-sysroot" ]]; then
    log_pass "WASI_SDK_PATH: ${WASI_SDK_PATH} (sysroot found)"
  else
    log_fail "WASI_SDK_PATH: ${WASI_SDK_PATH} (sysroot NOT found at share/wasi-sysroot)"
  fi
else
  log_skip "WASI_SDK_PATH: not set"
fi

if [[ -n "${CRYSTAL_WASM_LIBS:-}" ]]; then
  if [[ -d "${CRYSTAL_WASM_LIBS}" ]]; then
    log_pass "CRYSTAL_WASM_LIBS: ${CRYSTAL_WASM_LIBS}"
  else
    log_fail "CRYSTAL_WASM_LIBS: ${CRYSTAL_WASM_LIBS} (directory not found)"
  fi
else
  log_skip "CRYSTAL_WASM_LIBS: not set"
fi

if [[ -n "${CRYSTAL_LIBRARY_PATH:-}" ]]; then
  log_info "CRYSTAL_LIBRARY_PATH: ${CRYSTAL_LIBRARY_PATH}"
else
  log_skip "CRYSTAL_LIBRARY_PATH: not set"
fi

# ─── Quick mode exits here ─────────────────────────────────────
if [[ "${1:-}" == "--quick" ]]; then
  log_section "Summary (quick mode)"
  echo -e "  Passed: ${GREEN}${PASS}${NC}  Failed: ${RED}${FAIL}${NC}  Skipped: ${YELLOW}${SKIP}${NC}"
  [[ $FAIL -eq 0 ]] && exit 0 || exit 1
fi

if [[ "$TOOLS_OK" != "true" ]]; then
  echo ""
  echo "Required tools are missing. Install them before running compilation tests."
  echo "See: https://github.com/crimson-knight/crystal/blob/wasm-support/WASM_GUIDE.md"
  exit 1
fi

# ─── Compilation Tests ──────────────────────────────────────────
TEMP_DIR=$(mktemp -d)
CRYSTAL="${PROJECT_DIR}/bin/crystal"
COMPILE_FLAGS="--target wasm32-unknown-wasi -Dwithout_iconv -Dwithout_openssl"

compile_and_run() {
  local name=$1
  local src=$2
  local wasm="${TEMP_DIR}/${name}.wasm"

  echo "$src" > "${TEMP_DIR}/${name}.cr"

  if ${CRYSTAL} build "${TEMP_DIR}/${name}.cr" -o "$wasm" ${COMPILE_FLAGS} 2>"${TEMP_DIR}/${name}.compile.log"; then
    if wasmtime run "$wasm" 2>"${TEMP_DIR}/${name}.run.log"; then
      log_pass "$name"
      return 0
    else
      log_fail "$name (runtime error, see ${TEMP_DIR}/${name}.run.log)"
      return 1
    fi
  else
    log_fail "$name (compile error, see ${TEMP_DIR}/${name}.compile.log)"
    return 1
  fi
}

log_section "Phase 1: Exception Handling"

compile_and_run "exception_basic" '
begin
  raise "Hello from WASM!"
rescue ex
  puts ex.message
end
puts "OK"
'

compile_and_run "exception_type_dispatch" '
begin
  raise ArgumentError.new("bad arg")
rescue ex : ArgumentError
  puts "Caught: #{ex.message}"
rescue ex
  puts "Wrong handler"
  exit 1
end
puts "OK"
'

compile_and_run "exception_ensure" '
ensured = false
begin
  raise "test"
rescue
  puts "rescued"
ensure
  ensured = true
end
puts ensured ? "OK" : "FAIL"
'

log_section "Phase 2: Garbage Collection"

compile_and_run "gc_allocation" '
1000.times do
  s = "hello" * 20
end
puts "OK"
'

compile_and_run "gc_collect" '
GC.collect
puts "OK"
'

log_section "Phase 3: Fibers"

compile_and_run "fiber_spawn" '
done = false
spawn do
  done = true
end
Fiber.yield
puts done ? "OK" : "FAIL"
'

compile_and_run "fiber_channel" '
ch = Channel(Int32).new
spawn do
  ch.send(42)
end
value = ch.receive
puts value == 42 ? "OK" : "FAIL"
'

log_section "Phase 5: Event Loop"

compile_and_run "event_loop_sleep" '
sleep 0.001
puts "OK"
'

# ─── Spec File Tests ────────────────────────────────────────────
log_section "Spec Files"

for spec_file in "${PROJECT_DIR}"/spec/wasm32/*.cr; do
  if [[ -f "$spec_file" ]]; then
    spec_name=$(basename "$spec_file" .cr)
    wasm="${TEMP_DIR}/${spec_name}.wasm"
    if ${CRYSTAL} build "$spec_file" -o "$wasm" ${COMPILE_FLAGS} 2>"${TEMP_DIR}/${spec_name}.compile.log"; then
      if wasmtime run "$wasm" 2>"${TEMP_DIR}/${spec_name}.run.log"; then
        log_pass "spec/wasm32/${spec_name}.cr"
      else
        log_fail "spec/wasm32/${spec_name}.cr (runtime error)"
      fi
    else
      log_fail "spec/wasm32/${spec_name}.cr (compile error)"
    fi
  fi
done

# ─── Summary ───────────────────────────────────────────────────
log_section "Summary"
echo -e "  Passed: ${GREEN}${PASS}${NC}  Failed: ${RED}${FAIL}${NC}  Skipped: ${YELLOW}${SKIP}${NC}"
echo ""

if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}Some tests failed. Check logs in ${TEMP_DIR}${NC}"
  exit 1
fi
