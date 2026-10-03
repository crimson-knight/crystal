#!/usr/bin/env bash
# Install the built .deb into a clean Ubuntu container (so Depends must resolve
# from the pinned archives alone) and exercise it. Runs as root.
#   DISTRO=24.04|26.04   DEB=path to the .deb (default: newest in <repo>/dist)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$here/lib.sh"
deb="${DEB:-$(ls -t "$PKG_ROOT"/dist/crystal-alpha_*"ubuntu${DISTRO}"_"${dpkg_arch}".deb | head -1)}"
[ -f "$deb" ] || { echo "no .deb found" >&2; exit 1; }

configure_apt
cp "$deb" /tmp/crystal-alpha.deb
apt-get install -y -qq /tmp/crystal-alpha.deb >/dev/null
assert_llvm_version

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }

[ ! -e /usr/bin/crystal ] || fail "package must not ship /usr/bin/crystal"
for c in crystal-alpha acrystal; do
  out="$($c --version)"; echo "$c --version: $out"
  case "$out" in *"Crystal ${CRYSTAL_ALPHA_PKGVER%%.incremental*}"*) ;; *) fail "$c --version: $out" ;; esac
done
[ "$(crystal-alpha eval 'puts 40 + 2')" = "42" ] || fail "eval"
[ "$(acrystal eval 'puts 40 + 2')" = "42" ] || fail "acrystal eval"

tmp="$(mktemp -d)"
cat > "$tmp/hello.cr" <<'CR'
require "yaml"
require "big"
puts "hello from crystal-alpha #{YAML.parse("a: 1")["a"]} #{BigInt.new(2) ** 100}"
CR
crystal-alpha build "$tmp/hello.cr" -o "$tmp/hello"
out="$("$tmp/hello")"; echo "$out"
[ "$out" = "hello from crystal-alpha 1 1267650600228229401496703205376" ] || fail "hello output"
crystal-alpha run "$tmp/hello.cr" | grep -q "^hello from" || fail "run"
crystal-alpha i --help >/dev/null || fail "interpreter help"
crystal-alpha watch --help | head -3 || fail "watch --help"
dpkg -L crystal-alpha | grep -E "^/usr/bin/" 
echo "SMOKE OK ($DISTRO $dpkg_arch)"
