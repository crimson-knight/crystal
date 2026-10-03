#!/usr/bin/env bash
# Install the built package and exercise it. Runs as root in the Arch container.
#   PKG=path to the .pkg.tar.zst
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$here/../pins.env"
pkg="${PKG:?set PKG to the .pkg.tar.zst}"
pacman -U --noconfirm "$pkg" >/dev/null

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
watch_help="$(crystal-alpha watch --help)" || fail "watch --help"
echo "$watch_help" | head -3
pacman -Ql crystal-alpha | grep ' /usr/bin/'
echo "SMOKE OK (arch $(uname -m))"
