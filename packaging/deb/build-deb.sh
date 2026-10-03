#!/usr/bin/env bash
# Build crystal-alpha_<version>_<arch>.deb from the pinned release tag.
# Runs as root inside an Ubuntu container (see run-in-container.sh).
#   DISTRO=24.04|26.04  which Ubuntu release to build for
#   OUT_DIR             where the .deb goes (default: <repo>/dist)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$here/lib.sh"
OUT_DIR="${OUT_DIR:-$PKG_ROOT/dist}"
work="${WORK_DIR:-/tmp/crystal-alpha-build}"
rm -rf "$work"
mkdir -p "$work" "$OUT_DIR"

configure_apt

# Build dependencies. LLVM is installed at the exact pinned version.
apt-get install -y -qq --no-install-recommends \
  build-essential pkg-config xz-utils file \
  "llvm-21-dev=${UBUNTU_LLVM_VERSION}" "libllvm21=${UBUNTU_LLVM_VERSION}" \
  libgc-dev libpcre2-dev libevent-dev libyaml-dev libgmp-dev libssl-dev \
  libffi-dev zlib1g-dev libxml2-dev libzstd-dev libedit-dev >/dev/null
assert_llvm_version

# Source tarball (verified).
src_tgz="$work/source.tar.gz"
curl -fsSL --retry 3 -o "$src_tgz" \
  "https://github.com/crimson-knight/crystal/archive/refs/tags/${CRYSTAL_ALPHA_TAG}.tar.gz"
sha256_check "$CRYSTAL_ALPHA_SOURCE_SHA256" "$src_tgz"
tar -C "$work" -xzf "$src_tgz"
src="$work/crystal-${CRYSTAL_ALPHA_TAG#v}"
[ -d "$src" ] || { echo "unexpected tarball layout" >&2; exit 1; }

# Bootstrap compiler (verified).
boot_tgz="$work/boot.tar.gz"
curl -fsSL --retry 3 -o "$boot_tgz" \
  "https://github.com/crystal-lang/crystal/releases/download/${BOOT_RELEASE}/crystal-${BOOT_VERSION}-linux-${boot_arch}.tar.gz"
sha256_check "$BOOT_SHA256" "$boot_tgz"
tar -C "$work" -xzf "$boot_tgz"
boot="$work/crystal-${BOOT_VERSION}"
export PATH="$boot/bin:$PATH"
[ -d "$boot/embedded/bin" ] && export PATH="$boot/embedded/bin:$PATH"

# Compile. The stdlib lives at <bin dir>/../src, i.e. /usr/lib/crystal-alpha/src.
export LLVM_CONFIG=/usr/bin/llvm-config-21
cd "$src"
mkdir -p .build
make deps
make crystal \
  release=1 interpreter=1 FLAGS=--no-debug \
  CRYSTAL_CONFIG_PATH="'\$\$ORIGIN/../src'" \
  CRYSTAL_CONFIG_LIBRARY_PATH="'\$\$ORIGIN/../lib'" \
  CRYSTAL_CONFIG_BUILD_COMMIT="${CRYSTAL_ALPHA_COMMIT:0:9}"

# Stage the package tree.
stage="$work/stage"
lib="$stage/usr/lib/crystal-alpha"
install -d -m 0755 "$lib/bin" "$stage/usr/bin"
install -m 0755 .build/crystal "$lib/bin/crystal-alpha-bin"
cp -R -P src "$lib/src"
rm -f "$lib/src/llvm/ext/llvm_ext.o"

# Wrappers (mirrors the Homebrew formula: fixed CRYSTAL_PATH, real binary behind it).
cat > "$stage/usr/bin/crystal-alpha" <<'WRAP'
#!/bin/sh
CRYSTAL_PATH="lib:/usr/lib/crystal-alpha/src"
export CRYSTAL_PATH
exec /usr/lib/crystal-alpha/bin/crystal-alpha-bin "$@"
WRAP
chmod 0755 "$stage/usr/bin/crystal-alpha"
ln -s crystal-alpha "$stage/usr/bin/acrystal"

# Shell completions for both command names.
bash_dir="$stage/usr/share/bash-completion/completions"
zsh_dir="$stage/usr/share/zsh/vendor-completions"
fish_dir="$stage/usr/share/fish/vendor_completions.d"
install -d -m 0755 "$bash_dir" "$zsh_dir" "$fish_dir"
for cmd in crystal-alpha acrystal; do
  sed "s/complete -o default -F _crystal crystal/complete -o default -F _crystal $cmd/" \
    etc/completion.bash > "$bash_dir/$cmd"
  sed -e "s/#compdef crystal/#compdef $cmd/" -e "s/compdef _crystal crystal/compdef _crystal $cmd/" \
    etc/completion.zsh > "$zsh_dir/_$cmd"
  sed "s/complete -c crystal/complete -c $cmd/g" \
    etc/completion.fish > "$fish_dir/$cmd.fish"
done
chmod 0644 "$bash_dir"/* "$zsh_dir"/* "$fish_dir"/*

# Docs / license.
doc="$stage/usr/share/doc/crystal-alpha"
install -d -m 0755 "$doc"
install -m 0644 LICENSE "$doc/LICENSE"
cat > "$doc/copyright" <<'COPY'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Crystal
Source: https://github.com/crimson-knight/crystal

Files: *
Copyright: Manas Technology Solutions and the Crystal contributors; crimson-knight and fork contributors
License: Apache-2.0
 On Debian and Ubuntu systems the full text of the Apache License 2.0 is in
 /usr/share/common-licenses/Apache-2.0, and a copy of the project license is
 in /usr/share/doc/crystal-alpha/LICENSE.
COPY

# Runtime dependencies from the binary's real shared-library needs.
mkdir -p "$work/shlibs/debian"
printf 'Source: crystal-alpha\n\nPackage: crystal-alpha\nArchitecture: any\n' > "$work/shlibs/debian/control"
shlibs="$(cd "$work/shlibs" && dpkg-shlibdeps -O -e"$lib/bin/crystal-alpha-bin" 2>/dev/null \
  | sed -n 's/^shlibs:Depends=//p')"
[ -n "$shlibs" ] || { echo "dpkg-shlibdeps produced no dependencies" >&2; exit 1; }
# Everything a user program built with crystal-alpha can link against, plus a C
# toolchain for the linker step. llvm is a real runtime dependency: the compiler
# links libLLVM dynamically (the interpreter lives in the same binary).
devlibs="gcc, libc6-dev, pkgconf | pkg-config, libgc-dev, libpcre2-dev, libevent-dev, libyaml-dev, libgmp-dev, libssl-dev, libffi-dev, zlib1g-dev, libxml2-dev"
depends="$shlibs, $devlibs"

mkdir -p "$stage/DEBIAN"
(cd "$stage" && find usr -type f -exec md5sum {} + | sort -k2 > DEBIAN/md5sums)
installed_kb="$(du -sk --exclude=DEBIAN "$stage" | cut -f1)"
version="$(deb_version)"
cat > "$stage/DEBIAN/control" <<CTRL
Package: crystal-alpha
Version: ${version}
Architecture: ${dpkg_arch}
Maintainer: crimson-knight <noreply@users.noreply.github.com>
Installed-Size: ${installed_kb}
Depends: ${depends}
Section: devel
Priority: optional
Homepage: https://github.com/crimson-knight/crystal/tree/incremental-compilation
Description: Crystal compiler fork with incremental compilation (crystal-alpha)
 AgentC-enhanced Crystal ${CRYSTAL_ALPHA_PKGVER%%.incremental*} compiler with incremental
 compilation, a file watcher, mobile and WebAssembly targets, and the
 interpreter. Installs as crystal-alpha (alias acrystal) under
 /usr/lib/crystal-alpha and does not provide /usr/bin/crystal, so it coexists
 with any distribution or upstream crystal package.
 .
 This build needs libllvm21. Ubuntu 26.04 ships it; on Ubuntu 24.04 add the
 apt.llvm.org llvm-toolchain-noble-21 repository first.
CTRL

deb="$OUT_DIR/crystal-alpha_${version}_${dpkg_arch}.deb"
dpkg-deb --root-owner-group -Zxz --build "$stage" "$deb"
echo "built $deb"
dpkg-deb --info "$deb"
ls -l "$deb"
