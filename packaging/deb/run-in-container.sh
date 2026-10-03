#!/usr/bin/env bash
# Run a deb script inside the pinned Ubuntu image (needs Docker).
#   packaging/deb/run-in-container.sh <24.04|26.04> <build-deb.sh|smoke-test.sh>
set -euo pipefail
distro="${1:?usage: run-in-container.sh <24.04|26.04> <build-deb.sh|smoke-test.sh>}"
script="${2:?script}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
# shellcheck disable=SC1091
. "$here/ubuntu-pins.env"
ref="UBUNTU_${distro//./}_IMAGE"
image="${!ref:?unsupported distro $distro}"
mkdir -p "$root/dist"
exec docker run --rm -e "DISTRO=$distro" ${DEB:+-e "DEB=$DEB"} \
  -v "$root:/work" -w /work "$image" bash "/work/packaging/deb/$script"
