# Shared helpers for the .deb build and smoke test. Meant to be sourced inside
# an Ubuntu container, as root. Expects DISTRO=24.04 or 26.04.

: "${DISTRO:?set DISTRO to 24.04 or 26.04}"
PKG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$PKG_ROOT/packaging/pins.env"
# shellcheck disable=SC1091
. "$PKG_ROOT/packaging/deb/ubuntu-pins.env"

tag="${DISTRO//./}"
for v in CODENAME LLVM_REPO LLVM_SUITE LLVM_VERSION; do
  ref="UBUNTU_${tag}_${v}"
  [ "${!ref+x}" = x ] || { echo "unsupported DISTRO=$DISTRO (no $ref)" >&2; exit 1; }
  printf -v "UBUNTU_$v" '%s' "${!ref}"
done

dpkg_arch="$(dpkg --print-architecture)"
case "$dpkg_arch" in
  amd64) boot_arch=x86_64; BOOT_SHA256="$BOOT_SHA256_X86_64" ;;
  arm64) boot_arch=aarch64; BOOT_SHA256="$BOOT_SHA256_AARCH64" ;;
  *) echo "unsupported architecture $dpkg_arch" >&2; exit 1 ;;
esac

# sha256_check <expected> <file>: fail closed on mismatch.
sha256_check() {
  echo "$1  $2" | sha256sum --check --strict - >/dev/null \
    || { echo "SHA256 MISMATCH for $2 (expected $1)" >&2; exit 1; }
}

# Point apt at the pinned Ubuntu snapshot, then add apt.llvm.org when the distro
# has no LLVM 21. The base image has no CA bundle and the snapshot service is
# https-only, so the three bootstrap tools (ca-certificates, curl, gnupg) come
# first from the image's own signed archive sources. Nothing else is installed
# before the switch, and every later fetch uses full TLS verification.
configure_apt() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg >/dev/null
  rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*
  cat > /etc/apt/sources.list.d/ubuntu-snapshot.sources <<SRC
Types: deb
URIs: https://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT}
Suites: ${UBUNTU_CODENAME} ${UBUNTU_CODENAME}-updates ${UBUNTU_CODENAME}-security
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SRC
  # The snapshot service serves expired-looking Release files by design.
  echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99snapshot
  echo 'APT::Install-Recommends "false";' > /etc/apt/apt.conf.d/99norecommends
  apt-get update -qq

  if [ -n "$UBUNTU_LLVM_REPO" ]; then
    curl -fsSL --retry 3 -o /usr/share/keyrings/apt.llvm.org.asc "$APT_LLVM_KEY_URL"
    sha256_check "$APT_LLVM_KEY_SHA256" /usr/share/keyrings/apt.llvm.org.asc
    gpg --show-keys --with-colons /usr/share/keyrings/apt.llvm.org.asc \
      | grep -q "^fpr:::::::::${APT_LLVM_KEY_FINGERPRINT}:" \
      || { echo "apt.llvm.org key fingerprint mismatch" >&2; exit 1; }
    cat > /etc/apt/sources.list.d/apt-llvm-org.sources <<SRC
Types: deb
URIs: ${UBUNTU_LLVM_REPO}
Suites: ${UBUNTU_LLVM_SUITE}
Components: main
Signed-By: /usr/share/keyrings/apt.llvm.org.asc
SRC
    apt-get update -qq
  fi
}

assert_llvm_version() {
  local got
  got="$(dpkg-query -W -f='${Version}' libllvm21)"
  [ "$got" = "$UBUNTU_LLVM_VERSION" ] \
    || { echo "libllvm21 is $got, pinned $UBUNTU_LLVM_VERSION" >&2; exit 1; }
}

# Debian-style version for this distro, e.g. 1.21.0.incremental1-1ubuntu24.04
deb_version() { echo "${CRYSTAL_ALPHA_PKGVER}-1ubuntu${DISTRO}"; }
