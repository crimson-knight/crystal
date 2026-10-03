#!/usr/bin/env bash
# Point every packaging pin at a release tag of crimson-knight/crystal.
#   packaging/update-pins.sh v1.21.0-incremental-2
# Downloads the tag archive, records its sha256 and the tag's commit, and
# rewrites pins.env, the PKGBUILD and the .SRCINFO. Review the diff, then commit.
# The bootstrap compiler pins are not touched; bump those by hand.
set -euo pipefail

tag="${1:?usage: update-pins.sh <tag, e.g. v1.21.0-incremental-2>}"
case "$tag" in v*-incremental-*) ;; *) echo "tag must look like v<ver>-incremental-<n>" >&2; exit 1 ;; esac
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pkgver="$(echo "${tag#v}" | sed -E 's/-incremental-/.incremental/')"

refs="$(git ls-remote https://github.com/crimson-knight/crystal "refs/tags/$tag" "refs/tags/$tag^{}")"
commit="$(echo "$refs" | awk '/\^\{\}$/ {print $1}')"
[ -n "$commit" ] || commit="$(echo "$refs" | awk 'NR==1 {print $1}')"
[ -n "$commit" ] || { echo "tag $tag not found on origin" >&2; exit 1; }

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp" "https://github.com/crimson-knight/crystal/archive/refs/tags/$tag.tar.gz"
if command -v sha256sum >/dev/null; then sha="$(sha256sum "$tmp" | cut -d' ' -f1)"; else sha="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"; fi

inplace() { if sed --version >/dev/null 2>&1; then sed -i -E "$@"; else sed -i '' -E "$@"; fi; }

inplace \
  -e "s|^CRYSTAL_ALPHA_TAG=.*|CRYSTAL_ALPHA_TAG=$tag|" \
  -e "s|^CRYSTAL_ALPHA_COMMIT=.*|CRYSTAL_ALPHA_COMMIT=$commit|" \
  -e "s|^CRYSTAL_ALPHA_SOURCE_SHA256=.*|CRYSTAL_ALPHA_SOURCE_SHA256=$sha|" \
  -e "s|^CRYSTAL_ALPHA_PKGVER=.*|CRYSTAL_ALPHA_PKGVER=$pkgver|" \
  "$here/pins.env"

pkgbuild="$here/arch/crystal-alpha/PKGBUILD"
inplace \
  -e "s|^pkgver=.*|pkgver=$pkgver|" \
  -e "s|^pkgrel=.*|pkgrel=1|" \
  -e "s|^_tag=.*|_tag=$tag|" \
  -e "s|^_commit=.*|_commit=$commit|" \
  -e "s|^sha256sums=\\('[0-9a-f]+'\\)|sha256sums=('$sha')|" \
  "$pkgbuild"

srcinfo="$here/arch/crystal-alpha/.SRCINFO"
inplace \
  -e "s|^(\tpkgver = ).*|\1$pkgver|" \
  -e "s|^(\tpkgrel = ).*|\11|" \
  -e "s|^(\tsource = crystal-alpha-)v[^:]*(\.tar\.gz::https://github.com/crimson-knight/crystal/archive/refs/tags/)[^/]+\.tar\.gz|\1$tag\2$tag.tar.gz|" \
  -e "s|^(\tsha256sums = ).*|\1$sha|" \
  "$srcinfo"

echo "pinned $tag  commit=$commit  sha256=$sha  pkgver=$pkgver"
