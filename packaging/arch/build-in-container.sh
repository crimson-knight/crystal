#!/usr/bin/env bash
# Build the PKGBUILD in the pinned Arch image, as a non-root user, then run the
# smoke test against the resulting package. Runs as root; needs Docker only via
# run-in-container.sh. Output lands in <repo>/dist.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
# shellcheck disable=SC1091
. "$here/arch-pins.env"

# Pin the whole repository state to one Arch Linux Archive day (signed packages,
# verified by pacman against the archlinux-keyring), then sync to it.
echo "Server = https://archive.archlinux.org/repos/${ARCH_SNAPSHOT}/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist
pacman -Syyu --noconfirm
pacman -S --needed --noconfirm base-devel llvm21 gc pcre2 libevent libyaml gmp openssl \
  libffi zlib libxml2 pkgconf gcc

# makepkg refuses to run as root.
id builder >/dev/null 2>&1 || useradd -m builder
build="/home/builder/build"
rm -rf "$build"; mkdir -p "$build" /out
cp "$here/crystal-alpha/PKGBUILD" "$build/"
chown -R builder:builder /home/builder

# The committed .SRCINFO must match the PKGBUILD.
cp "$here/crystal-alpha/.SRCINFO" /tmp/committed.SRCINFO
su builder -c "cd $build && makepkg --printsrcinfo" > /tmp/generated.SRCINFO
diff -u /tmp/committed.SRCINFO /tmp/generated.SRCINFO \
  || { echo ".SRCINFO is out of date; regenerate with makepkg --printsrcinfo" >&2; exit 1; }

# makepkg verifies every source against the sha256sums and fails closed.
su builder -c "cd $build && makepkg --noconfirm --cleanbuild --force"
pkg="$(ls "$build"/crystal-alpha-*.pkg.tar.zst | head -1)"
mkdir -p "$root/dist"
cp "$pkg" "$root/dist/"
ls -l "$root/dist/$(basename "$pkg")"

PKG="$pkg" bash "$here/smoke-test.sh"
