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
# This fork asks LLVM for the host CPU *name* only (src/compiler/crystal/codegen/target.cr),
# not its feature flags. On cloud VMs that mask features (e.g. AVX-512 on the GitHub
# runners' EPYC 9V74) the generated program can then hit an illegal instruction.
# Run the checks with the defaults first; if only that fails, say so loudly and fall
# back to a generic CPU so the rest of the package is still verified.
MCPU=()
if [ "$(crystal-alpha eval 'puts 40 + 2' 2>&1)" != "42" ]; then
  echo "--- default CPU autodetect failed; diagnostics"
  grep -m1 'model name' /proc/cpuinfo || true
  grep -m1 '^flags' /proc/cpuinfo | tr ' ' '\n' | grep -E '^avx512' | head -3 || echo "no avx512 flags exposed"
  [ "$(crystal-alpha eval --mcpu generic 'puts 40 + 2')" = "42" ] || fail "eval (even with --mcpu generic)"
  echo "::warning::crystal-alpha default CPU autodetect produced code this VM cannot run; using --mcpu generic"
  MCPU=(--mcpu generic)
fi
[ "$(crystal-alpha eval "${MCPU[@]}" 'puts 40 + 2')" = "42" ] || fail "eval"
[ "$(acrystal eval "${MCPU[@]}" 'puts 40 + 2')" = "42" ] || fail "acrystal eval"

tmp="$(mktemp -d)"
cat > "$tmp/hello.cr" <<'CR'
require "yaml"
require "big"
puts "hello from crystal-alpha #{YAML.parse("a: 1")["a"]} #{BigInt.new(2) ** 100}"
CR
crystal-alpha build "${MCPU[@]}" "$tmp/hello.cr" -o "$tmp/hello"
out="$("$tmp/hello")"; echo "$out"
[ "$out" = "hello from crystal-alpha 1 1267650600228229401496703205376" ] || fail "hello output"
crystal-alpha run "${MCPU[@]}" "$tmp/hello.cr" | grep -q "^hello from" || fail "run"
crystal-alpha i --help >/dev/null || fail "interpreter help"
watch_help="$(crystal-alpha watch --help)" || fail "watch --help"
echo "$watch_help" | head -3
pacman -Ql crystal-alpha | grep ' /usr/bin/'
echo "SMOKE OK (arch $(uname -m))"
