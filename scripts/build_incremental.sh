#!/bin/bash
set -e

# ==============================================================================
#  Crystal Incremental Compiler - Build & Install
# ==============================================================================
#
#  Builds the Crystal compiler from the incremental-compilation branch and
#  optionally reinstalls the crystal-alpha Homebrew formula.
#
#  Usage:
#    ./scripts/build_incremental.sh
#
# ==============================================================================

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

EXPECTED_BRANCH="incremental-compilation"
LLVM_CONFIG="/opt/homebrew/Cellar/llvm/21.1.8_1/bin/llvm-config"

# Resolve the repository root relative to this script's location, regardless
# of where the script is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

banner() {
    echo ""
    echo "============================================================"
    echo "  $1"
    echo "============================================================"
    echo ""
}

info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*"; }
error() { echo "[ERROR] $*" >&2; }
die()   { error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

banner "Crystal Incremental Compiler - Build & Install"

info "Repository root: ${REPO_ROOT}"
info "Script started at $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Verify we are inside a git repository.
if ! git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "Directory ${REPO_ROOT} is not a git repository."
fi

# Verify the current branch is the expected one.
CURRENT_BRANCH="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD)"
if [ "${CURRENT_BRANCH}" != "${EXPECTED_BRANCH}" ]; then
    die "Expected branch '${EXPECTED_BRANCH}' but currently on '${CURRENT_BRANCH}'. Please switch branches first."
fi
info "Branch: ${CURRENT_BRANCH}"

# Verify llvm-config is available.
if [ ! -x "${LLVM_CONFIG}" ]; then
    die "llvm-config not found at ${LLVM_CONFIG}. Is LLVM installed via Homebrew?"
fi

LLVM_VERSION="$("${LLVM_CONFIG}" --version)"
info "LLVM version: ${LLVM_VERSION}"

# Show the short SHA so builds are easy to correlate with commits.
HEAD_SHA="$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
info "HEAD commit: ${HEAD_SHA}"
echo ""

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

banner "Building the compiler (make crystal)"

export LLVM_CONFIG

BUILD_START="$(date +%s)"

make -C "${REPO_ROOT}" crystal

BUILD_END="$(date +%s)"
BUILD_ELAPSED=$(( BUILD_END - BUILD_START ))
BUILD_MIN=$(( BUILD_ELAPSED / 60 ))
BUILD_SEC=$(( BUILD_ELAPSED % 60 ))

echo ""
info "Build completed in ${BUILD_MIN}m ${BUILD_SEC}s"

# Quick sanity check -- the binary should exist after a successful build.
BUILT_BINARY="${REPO_ROOT}/.build/crystal"
if [ ! -x "${BUILT_BINARY}" ]; then
    die "Build appeared to succeed but ${BUILT_BINARY} was not found."
fi

LOCAL_VERSION="$("${BUILT_BINARY}" --version 2>&1 | head -1)"
info "Built compiler version: ${LOCAL_VERSION}"

# ---------------------------------------------------------------------------
# Homebrew reinstall (optional)
# ---------------------------------------------------------------------------

HOMEBREW_INSTALLED=false

if command -v brew >/dev/null 2>&1 && brew list crystal-alpha >/dev/null 2>&1; then
    banner "Reinstalling crystal-alpha via Homebrew"
    brew reinstall crystal-alpha
    HOMEBREW_INSTALLED=true
else
    info "crystal-alpha is not installed via Homebrew -- skipping reinstall."
fi

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

banner "Verification"

if [ "${HOMEBREW_INSTALLED}" = true ] && command -v crystal-alpha >/dev/null 2>&1; then
    INSTALLED_VERSION="$(crystal-alpha --version 2>&1 | head -1)"
    info "Installed (Homebrew) crystal-alpha version: ${INSTALLED_VERSION}"
else
    info "Local build crystal version: ${LOCAL_VERSION}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

banner "Summary"

echo "  Branch:          ${CURRENT_BRANCH}"
echo "  Commit:          ${HEAD_SHA}"
echo "  LLVM:            ${LLVM_VERSION}"
echo "  Build time:      ${BUILD_MIN}m ${BUILD_SEC}s"
echo "  Binary:          ${BUILT_BINARY}"
echo "  Version:         ${LOCAL_VERSION}"
if [ "${HOMEBREW_INSTALLED}" = true ]; then
    echo "  Homebrew:        crystal-alpha reinstalled"
else
    echo "  Homebrew:        skipped (crystal-alpha not installed)"
fi
echo ""
info "Done. $(date '+%Y-%m-%d %H:%M:%S')"
