#!/usr/bin/env bash
# Run the Arch build inside the pinned archlinux image (needs Docker; x86_64 only).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
# shellcheck disable=SC1091
. "$here/arch-pins.env"
mkdir -p "$root/dist"
exec docker run --rm --platform linux/amd64 -v "$root:/work" -w /work "$ARCH_IMAGE" \
  bash /work/packaging/arch/build-in-container.sh
