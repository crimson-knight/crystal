#!/usr/bin/env bash
set -euo pipefail

# Crystal WASM Validation Script
# Validates that the WASM compilation target works correctly.
#
# Usage: ./scripts/validate_wasm.sh [--quick]
#   --quick: Only check tool versions, skip compilation tests
#
# Prerequisites:
#   - wasi-sdk installed at /opt/wasi-sdk
#   - lld installed (brew install lld)
#   - binaryen installed (brew install binaryen)
#   - wasmtime installed (curl https://wasmtime.dev/install.sh -sSf | bash)
#   - wasm_eh_support.o compiled and placed in wasi-sysroot (see WASM_GUIDE.md)
#   - CRYSTAL_LIBRARY_PATH set to /opt/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi

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

# Check for the locally built Crystal compiler
if [[ -x "${PROJECT_DIR}/bin/crystal" ]]; then
  log_pass "Crystal compiler: ${PROJECT_DIR}/bin/crystal"
else
  log_fail "Crystal compiler: not found at ${PROJECT_DIR}/bin/crystal (build with make crystal)"
  TOOLS_OK=false
fi

check_tool "WASM linker (wasm-ld)" wasm-ld || TOOLS_OK=false
check_tool "Binaryen optimizer (wasm-opt)" wasm-opt || TOOLS_OK=false
check_tool "Wasmtime runtime" wasmtime || TOOLS_OK=false

# ─── Prerequisites ─────────────────────────────────────────────
log_section "Prerequisites"

# Check wasi-sdk installation
WASI_SDK_PATH="${WASI_SDK_PATH:-/opt/wasi-sdk}"
if [[ -d "${WASI_SDK_PATH}/share/wasi-sysroot" ]]; then
  log_pass "wasi-sdk: ${WASI_SDK_PATH} (sysroot found)"
else
  log_fail "wasi-sdk: not found at ${WASI_SDK_PATH}/share/wasi-sysroot"
  log_info "Install wasi-sdk from https://github.com/WebAssembly/wasi-sdk/releases"
  TOOLS_OK=false
fi

# Check wasm_eh_support.o
WASM_EH_SUPPORT="${WASI_SDK_PATH}/share/wasi-sysroot/lib/wasm32-wasi/wasm_eh_support.o"
if [[ -f "${WASM_EH_SUPPORT}" ]]; then
  log_pass "wasm_eh_support.o: found at ${WASM_EH_SUPPORT}"
else
  log_fail "wasm_eh_support.o: not found at ${WASM_EH_SUPPORT}"
  log_info "Compile it with wasi-sdk clang++ (see WASM_GUIDE.md setup section)"
  TOOLS_OK=false
fi

# Check CRYSTAL_LIBRARY_PATH
EXPECTED_LIB_PATH="${WASI_SDK_PATH}/share/wasi-sysroot/lib/wasm32-wasi"
if [[ -n "${CRYSTAL_LIBRARY_PATH:-}" ]]; then
  log_pass "CRYSTAL_LIBRARY_PATH: ${CRYSTAL_LIBRARY_PATH}"
else
  log_skip "CRYSTAL_LIBRARY_PATH: not set (will use default: ${EXPECTED_LIB_PATH})"
  export CRYSTAL_LIBRARY_PATH="${EXPECTED_LIB_PATH}"
fi

# Check libc++abi is available
if [[ -f "${EXPECTED_LIB_PATH}/libc++abi.a" ]]; then
  log_pass "libc++abi.a: found"
else
  log_fail "libc++abi.a: not found at ${EXPECTED_LIB_PATH}/libc++abi.a"
  TOOLS_OK=false
fi

# ─── Quick mode exits here ─────────────────────────────────────
if [[ "${1:-}" == "--quick" ]]; then
  log_section "Summary (quick mode)"
  echo -e "  Passed: ${GREEN}${PASS}${NC}  Failed: ${RED}${FAIL}${NC}  Skipped: ${YELLOW}${SKIP}${NC}"
  [[ $FAIL -eq 0 ]] && exit 0 || exit 1
fi

if [[ "$TOOLS_OK" != "true" ]]; then
  echo ""
  echo "Required tools or prerequisites are missing. Install them before running compilation tests."
  echo "See: WASM_GUIDE.md for setup instructions."
  exit 1
fi

# ─── Compilation Tests ──────────────────────────────────────────
TEMP_DIR=$(mktemp -d)
CRYSTAL="${PROJECT_DIR}/bin/crystal"
COMPILE_FLAGS="--target wasm32-unknown-wasi -Dwithout_iconv -Dwithout_openssl"
LINK_FLAGS="--allow-undefined ${WASM_EH_SUPPORT} -lc++abi"

compile_and_run() {
  local name=$1
  local src=$2
  local expected_output="${3:-}"
  local wasm="${TEMP_DIR}/${name}.wasm"

  echo "$src" > "${TEMP_DIR}/${name}.cr"

  if ${CRYSTAL} build "${TEMP_DIR}/${name}.cr" -o "$wasm" ${COMPILE_FLAGS} --link-flags="${LINK_FLAGS}" 2>"${TEMP_DIR}/${name}.compile.log"; then
    local actual_output
    if actual_output=$(wasmtime run -W exceptions "$wasm" 2>"${TEMP_DIR}/${name}.run.log"); then
      if [[ -n "${expected_output}" ]]; then
        if [[ "$actual_output" == "$expected_output" ]]; then
          log_pass "$name"
          return 0
        else
          log_fail "$name (output mismatch)"
          log_info "  Expected: ${expected_output}"
          log_info "  Actual:   ${actual_output}"
          return 1
        fi
      else
        log_pass "$name"
        return 0
      fi
    else
      log_fail "$name (runtime error, see ${TEMP_DIR}/${name}.run.log)"
      return 1
    fi
  else
    log_fail "$name (compile error, see ${TEMP_DIR}/${name}.compile.log)"
    return 1
  fi
}

log_section "Phase 1: Basic Output"

compile_and_run "hello_world" '
puts "Hello from Crystal on WebAssembly!"
' "Hello from Crystal on WebAssembly!"

compile_and_run "string_interpolation" '
puts "1 + 2 = #{1 + 2}"
' "1 + 2 = 3"

compile_and_run "multiple_puts" '
puts "Hello from Crystal on WebAssembly!"
puts "1 + 2 = #{1 + 2}"
puts "Array: #{[1, 2, 3]}"
puts "It works!"
' "Hello from Crystal on WebAssembly!
1 + 2 = 3
Array: [1, 2, 3]
It works!"

log_section "Phase 2: Data Structures"

compile_and_run "array_operations" '
arr = [1, 2, 3, 4, 5]
puts arr.size
puts arr.sum
' "5
15"

compile_and_run "hash_operations" '
h = {"a" => 1, "b" => 2, "c" => 3}
puts h.size
puts h["b"]
' "3
2"

compile_and_run "string_operations" '
s = "Hello, WebAssembly!"
puts s.size
puts s.upcase
puts s.includes?("WASM")
' "19
HELLO, WEBASSEMBLY!
false"

log_section "Phase 3: Computation"

compile_and_run "math_operations" '
puts 2 ** 10
puts 100 / 3
puts 3.14159 * 2
' "1024
33
6.28318"

compile_and_run "iteration" '
total = 0
10.times do |i|
  total += i
end
puts total
' "45"

compile_and_run "gc_allocation" '
1000.times do
  s = "hello" * 20
end
puts "OK"
' "OK"

# ─── Spec File Tests ────────────────────────────────────────────
log_section "Spec Files"

if [[ -d "${PROJECT_DIR}/spec/wasm32" ]]; then
  for spec_file in "${PROJECT_DIR}"/spec/wasm32/*.cr; do
    if [[ -f "$spec_file" ]]; then
      spec_name=$(basename "$spec_file" .cr)
      wasm="${TEMP_DIR}/${spec_name}.wasm"
      if ${CRYSTAL} build "$spec_file" -o "$wasm" ${COMPILE_FLAGS} --link-flags="${LINK_FLAGS}" 2>"${TEMP_DIR}/${spec_name}.compile.log"; then
        if wasmtime run -W exceptions "$wasm" 2>"${TEMP_DIR}/${spec_name}.run.log"; then
          log_pass "spec/wasm32/${spec_name}.cr"
        else
          log_fail "spec/wasm32/${spec_name}.cr (runtime error)"
        fi
      else
        log_fail "spec/wasm32/${spec_name}.cr (compile error)"
      fi
    fi
  done
else
  log_skip "spec/wasm32/ directory not found"
fi

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
