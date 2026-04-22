#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly TOOLCHAIN_HOME="${CRYSTAL_TOOLCHAIN_HOME:-${XDG_DATA_HOME:-${HOME}/.local/share}/crystal-toolchain}"

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  crystal_toolchain.sh install <version> [<version>...]
  crystal_toolchain.sh list
  crystal_toolchain.sh which <version|fork|system>
  crystal_toolchain.sh run <version|fork|system> -- <command> [args...]
  crystal_toolchain.sh matrix <version> [<version>...] -- <command> [args...]

Aliases:
  system  Use the current `crystal` on PATH.
  fork    Use `CRYSTAL_TOOLCHAIN_FORK`, the repo `.build/crystal`, or the current fork command on PATH
          (`acrystal`, `agent-crystal`, or legacy `a-crystal` / `crystal-alpha`), exposed as `crystal`.

Examples:
  ./scripts/crystal_toolchain.sh install 1.19.1 1.20.0
  ./scripts/crystal_toolchain.sh run 1.19.1 -- crystal --version
  ./scripts/crystal_toolchain.sh matrix 1.19.1 1.20.0 fork -- make spec
EOF
}

find_fork_command() {
  local candidate

  if [[ -n "${CRYSTAL_TOOLCHAIN_FORK:-}" ]]; then
    if [[ -x "${CRYSTAL_TOOLCHAIN_FORK}" ]]; then
      echo "${CRYSTAL_TOOLCHAIN_FORK}"
      return 0
    fi
    if command -v "${CRYSTAL_TOOLCHAIN_FORK}" >/dev/null 2>&1; then
      command -v "${CRYSTAL_TOOLCHAIN_FORK}"
      return 0
    fi
  fi

  if [[ -x "${REPO_ROOT}/.build/crystal" ]]; then
    echo "${REPO_ROOT}/.build/crystal"
    return 0
  fi

  for candidate in acrystal agent-crystal a-crystal crystal-alpha; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      command -v "${candidate}"
      return 0
    fi
  done

  return 1
}

canonicalize_path() {
  local target="$1"
  local dir base
  dir="$(cd "$(dirname "${target}")" && pwd -P)"
  base="$(basename "${target}")"
  echo "${dir}/${base}"
}

is_repo_build_command() {
  local command_path="$1"
  [[ "$(canonicalize_path "${command_path}")" == "$(canonicalize_path "${REPO_ROOT}/.build/crystal")" ]]
}

require_command() {
  local command_name="$1"
  command -v "${command_name}" >/dev/null 2>&1 || die "missing required command: ${command_name}"
}

host_platform() {
  case "$(uname -s)" in
    Darwin)
      echo "darwin"
      ;;
    Linux)
      echo "linux"
      ;;
    *)
      die "unsupported platform: $(uname -s)"
      ;;
  esac
}

host_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      echo "x86_64"
      ;;
    arm64|aarch64)
      echo "aarch64"
      ;;
    *)
      die "unsupported architecture: $(uname -m)"
      ;;
  esac
}

release_asset_suffix() {
  local platform arch
  platform="$(host_platform)"
  arch="$(host_arch)"

  case "${platform}" in
    darwin)
      echo "darwin-universal"
      ;;
    linux)
      echo "linux-${arch}"
      ;;
    *)
      die "unsupported platform: ${platform}"
      ;;
  esac
}

release_url() {
  local version="$1"
  local suffix
  suffix="$(release_asset_suffix)"
  echo "https://github.com/crystal-lang/crystal/releases/download/${version}/crystal-${version}-1-${suffix}.tar.gz"
}

version_dir() {
  local version="$1"
  echo "${TOOLCHAIN_HOME}/versions/${version}"
}

fix_darwin_libyaml() {
  local install_path="$1"
  local shards_bin="${install_path}/embedded/bin/shards"
  local linked_libyaml

  if [[ "$(host_platform)" != "darwin" || ! -x "${shards_bin}" ]]; then
    return 0
  fi

  linked_libyaml="$(otool -L "${shards_bin}" | awk '/libyaml/ {print $1; exit}')"
  if [[ "${linked_libyaml}" == "/opt/crystal/embedded/lib/libyaml-0.2.dylib" ]]; then
    install_name_tool \
      -change "${linked_libyaml}" "${install_path}/embedded/lib/libyaml-0.2.dylib" \
      "${shards_bin}"
  fi
}

darwin_release_shim_dir() {
  local version="$1"
  echo "$(version_dir "${version}")/toolchain-shims"
}

prepare_darwin_release_shims() {
  local version="$1"
  local shim_dir resolved

  shim_dir="$(darwin_release_shim_dir "${version}")"
  mkdir -p "${shim_dir}"
  rm -f "${shim_dir}/pkg-config" "${shim_dir}/pkgconf"

  if resolved="$(command -v pkg-config 2>/dev/null)"; then
    ln -sf "${resolved}" "${shim_dir}/pkg-config"
  fi

  if resolved="$(command -v pkgconf 2>/dev/null)"; then
    ln -sf "${resolved}" "${shim_dir}/pkgconf"
  fi
}

install_release() {
  local version="$1"
  local destination url tmp_dir archive staging

  destination="$(version_dir "${version}")"
  if [[ -x "${destination}/bin/crystal" ]]; then
    echo "already installed: ${version}" >&2
    return 0
  fi

  require_command curl
  require_command tar

  url="$(release_url "${version}")"
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/crystal-toolchain.XXXXXX")"
  archive="${tmp_dir}/crystal.tar.gz"
  staging="${tmp_dir}/install"

  mkdir -p "$(dirname "${destination}")" "${staging}"

  echo "installing Crystal ${version} from ${url}" >&2
  if ! curl -fsSL "${url}" -o "${archive}"; then
    rm -rf "${tmp_dir}"
    die "could not download Crystal ${version}"
  fi

  tar -xzf "${archive}" -C "${staging}" --strip-components=1
  fix_darwin_libyaml "${staging}"

  rm -rf "${destination}"
  mv "${staging}" "${destination}"
  rm -rf "${tmp_dir}"
}

toolchain_path_prefix() {
  local version="$1"
  case "${version}" in
    system)
      command -v crystal >/dev/null 2>&1 || die "no `crystal` executable found on PATH"
      echo ""
      ;;
    fork)
      local fork_command
      fork_command="$(find_fork_command)" || die "no fork executable found via CRYSTAL_TOOLCHAIN_FORK, ${REPO_ROOT}/.build/crystal, or PATH (`acrystal`, `agent-crystal`, or legacy `a-crystal` / `crystal-alpha`)"
      local shim_dir
      shim_dir="$(mktemp -d "${TMPDIR:-/tmp}/crystal-toolchain-fork.XXXXXX")"
      ln -sf "${fork_command}" "${shim_dir}/crystal"
      echo "${shim_dir}"
      ;;
    *)
      install_release "${version}"
      if [[ "$(host_platform)" == "darwin" ]]; then
        prepare_darwin_release_shims "${version}"
        echo "$(version_dir "${version}")/bin:$(version_dir "${version}")/embedded/bin:$(darwin_release_shim_dir "${version}"):/usr/bin:/bin:/usr/sbin:/sbin"
      else
        echo "$(version_dir "${version}")/bin:$(version_dir "${version}")/embedded/bin"
      fi
      ;;
  esac
}

cleanup_path_prefix() {
  local version="$1"
  local prefix="$2"

  if [[ "${version}" == "fork" && -n "${prefix}" ]]; then
    rm -rf "${prefix}"
  fi
}

should_replace_path() {
  local version="$1"

  [[ "${version}" != "system" ]] &&
    [[ "${version}" != "fork" ]] &&
    [[ "$(host_platform)" == "darwin" ]]
}

with_toolchain() {
  local version="$1"
  shift

  local prefix
  local fork_command=""
  local status=0
  prefix="$(toolchain_path_prefix "${version}")"
  if [[ "${version}" == "fork" ]]; then
    fork_command="$(find_fork_command)" || die "no fork executable found via CRYSTAL_TOOLCHAIN_FORK, ${REPO_ROOT}/.build/crystal, or PATH (`acrystal`, `agent-crystal`, or legacy `a-crystal` / `crystal-alpha`)"
  fi
  if [[ -n "${prefix}" ]]; then
    if (
      export CRYSTAL_TOOLCHAIN_SELECTED="${version}"
      if should_replace_path "${version}"; then
        export PATH="${prefix}"
      else
        export PATH="${prefix}:${PATH}"
      fi
      if [[ "${version}" == "fork" ]] && [[ -n "${fork_command}" ]] && is_repo_build_command "${fork_command}"; then
        export CRYSTAL_PATH="${REPO_ROOT}/lib:${REPO_ROOT}/src"
        export CRYSTAL_EXEC_PATH="${REPO_ROOT}/bin"
      fi
      "$@"
    ); then
      status=0
    else
      status=$?
    fi
  else
    if (
      export CRYSTAL_TOOLCHAIN_SELECTED="${version}"
      "$@"
    ); then
      status=0
    else
      status=$?
    fi
  fi

  cleanup_path_prefix "${version}" "${prefix}"
  return "${status}"
}

list_installed() {
  local versions_dir="${TOOLCHAIN_HOME}/versions"

  if [[ ! -d "${versions_dir}" ]]; then
    return 0
  fi

  find "${versions_dir}" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort -V
}

which_toolchain() {
  local version="$1"
  case "${version}" in
    system)
      command -v crystal
      ;;
    fork)
      find_fork_command
      ;;
    *)
      install_release "${version}"
      echo "$(version_dir "${version}")/bin/crystal"
      ;;
  esac
}

run_matrix() {
  local versions=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    versions+=("$1")
    shift
  done

  [[ ${#versions[@]} -gt 0 ]] || die "matrix requires at least one version"
  [[ $# -gt 0 && "$1" == "--" ]] || die "matrix requires -- before the command"
  shift
  [[ $# -gt 0 ]] || die "matrix requires a command to run"

  local overall=0
  local version status
  for version in "${versions[@]}"; do
    echo
    echo "=== ${version} ==="
    if with_toolchain "${version}" "$@"; then
      echo "PASS ${version}"
    else
      status=$?
      overall=1
      echo "FAIL ${version} (exit ${status})"
    fi
  done

  return "${overall}"
}

main() {
  local subcommand="${1:-}"
  shift || true

  case "${subcommand}" in
    install)
      [[ $# -gt 0 ]] || die "install requires at least one version"
      local version
      for version in "$@"; do
        install_release "${version}"
      done
      ;;
    list)
      list_installed
      ;;
    which)
      [[ $# -eq 1 ]] || die "which requires exactly one version"
      which_toolchain "$1"
      ;;
    run)
      [[ $# -gt 0 ]] || die "run requires a version"
      local version="$1"
      shift
      [[ $# -gt 0 && "$1" == "--" ]] || die "run requires -- before the command"
      shift
      [[ $# -gt 0 ]] || die "run requires a command"
      with_toolchain "${version}" "$@"
      ;;
    matrix)
      run_matrix "$@"
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      die "unknown subcommand: ${subcommand}"
      ;;
  esac
}

main "$@"
