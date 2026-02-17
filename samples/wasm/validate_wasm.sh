#!/usr/bin/env bash
# validate_wasm.sh - Validate a Crystal WASM binary against the browser WASI shim
#
# Checks that every WASI function imported by the .wasm file is implemented
# in the browser shim (index.html). Run this after compiling to catch missing
# imports BEFORE trying to load in the browser.
#
# Usage: ./validate_wasm.sh <file.wasm> [index.html]
#
# Requires: wasm-objdump (from wabt or wasi-sdk)

set -euo pipefail

WASM_FILE="${1:?Usage: $0 <file.wasm> [index.html]}"
SHIM_FILE="${2:-$(dirname "$0")/index.html}"

if [ ! -f "$WASM_FILE" ]; then
  echo "ERROR: WASM file not found: $WASM_FILE" >&2
  exit 1
fi

if [ ! -f "$SHIM_FILE" ]; then
  echo "ERROR: WASI shim file not found: $SHIM_FILE" >&2
  exit 1
fi

# Extract WASI imports from the .wasm binary
WASM_IMPORTS=$(wasm-objdump -x -j Import "$WASM_FILE" 2>/dev/null \
  | grep 'wasi_snapshot_preview1\.' \
  | sed 's/.*wasi_snapshot_preview1\.\([a-z_]*\).*/\1/' \
  | sort -u)

if [ -z "$WASM_IMPORTS" ]; then
  echo "OK: No WASI imports found in $WASM_FILE"
  exit 0
fi

# Extract implemented functions from the browser shim
# Looks for function names in the wasi object literal (e.g., "fd_write(" or "fd_write(")
SHIM_FUNCTIONS=$(grep -oE '^\s+[a-z_]+\(' "$SHIM_FILE" \
  | sed 's/[[:space:]]*//;s/(//' \
  | sort -u)

MISSING=()
FOUND=0
TOTAL=0

echo "Validating WASI imports in $(basename "$WASM_FILE") against $(basename "$SHIM_FILE")"
echo ""

for import in $WASM_IMPORTS; do
  TOTAL=$((TOTAL + 1))
  if echo "$SHIM_FUNCTIONS" | grep -qx "$import"; then
    FOUND=$((FOUND + 1))
  else
    MISSING+=("$import")
  fi
done

if [ ${#MISSING[@]} -eq 0 ]; then
  echo "OK: All $TOTAL WASI imports are implemented in the browser shim."
  echo ""
  echo "Imports: $(echo "$WASM_IMPORTS" | tr '\n' ', ' | sed 's/,$//')"
  exit 0
else
  echo "FAIL: ${#MISSING[@]} of $TOTAL WASI imports are MISSING from the browser shim!"
  echo ""
  echo "Missing functions (add these to index.html):"
  for fn in "${MISSING[@]}"; do
    echo "  - $fn"
  done
  echo ""
  echo "Implemented ($FOUND/$TOTAL):"
  for import in $WASM_IMPORTS; do
    if echo "$SHIM_FUNCTIONS" | grep -qx "$import"; then
      echo "  + $import"
    fi
  done
  exit 1
fi
