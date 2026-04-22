#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly TOOLCHAIN_SCRIPT="${SCRIPT_DIR}/crystal_toolchain.sh"

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

banner() {
  printf '\n==> %s\n' "$*"
}

version_check() {
  local expected_selector="$1"

  crystal eval '
    require "json"

    expected = ARGV[0]
    actual = ENV["CRYSTAL_TOOLCHAIN_SELECTED"]? || ""
    abort "expected CRYSTAL_TOOLCHAIN_SELECTED=#{expected.inspect}, got #{actual.inspect}" unless actual == expected

    payload = {
      "answer" => 42,
      "toolchain" => actual,
    }
    print payload.to_json
  ' -- "${expected_selector}"
  printf '\n'
}

format_check() {
  crystal tool format --check \
    "${REPO_ROOT}/samples/fibonacci.cr" \
    "${REPO_ROOT}/samples/wordcount.cr"
}

wordcount_check() {
  local work_dir input_file expected_file actual_file binary_path
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-crystal-wordcount.XXXXXX")"
  trap 'rm -rf "${work_dir}"' RETURN

  input_file="${work_dir}/input.txt"
  expected_file="${work_dir}/expected.txt"
  actual_file="${work_dir}/actual.txt"
  binary_path="${work_dir}/wordcount"

  printf 'Foo foo bar\n' > "${input_file}"
  printf '1\tbar\n2\tfoo\n' > "${expected_file}"

  crystal build "${REPO_ROOT}/samples/wordcount.cr" -o "${binary_path}"
  "${binary_path}" -i "${input_file}" > "${actual_file}"

  if ! cmp -s "${expected_file}" "${actual_file}"; then
    printf 'expected output:\n' >&2
    cat "${expected_file}" >&2
    printf 'actual output:\n' >&2
    cat "${actual_file}" >&2
    exit 1
  fi
}

fibonacci_check() {
  local work_dir output_file
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-crystal-fibonacci.XXXXXX")"
  trap 'rm -rf "${work_dir}"' RETURN

  output_file="${work_dir}/fibonacci.out"
  crystal run "${REPO_ROOT}/samples/fibonacci.cr" > "${output_file}"

  grep -Fqx 'First ten Fibonacci numbers:' "${output_file}" || exit 1
  grep -Fqx 'fibonacci(9) = 34' "${output_file}" || exit 1
}

run_main() {
  local versions=("$@")
  local upstream_versions=()
  local version

  if [[ ! -x "${TOOLCHAIN_SCRIPT}" ]]; then
    die "missing toolchain script: ${TOOLCHAIN_SCRIPT}"
  fi

  if [[ ${#versions[@]} -eq 0 ]]; then
    versions=(1.19.1 1.20.0 fork)
  fi

  for version in "${versions[@]}"; do
    case "${version}" in
      fork|system)
        ;;
      *)
        upstream_versions+=("${version}")
        ;;
    esac
  done

  if [[ ${#upstream_versions[@]} -gt 0 ]]; then
    banner "Installing upstream toolchains"
    "${TOOLCHAIN_SCRIPT}" install "${upstream_versions[@]}"
  fi

  for version in "${versions[@]}"; do
    banner "Compatibility smoke (${version})"
    "${TOOLCHAIN_SCRIPT}" run "${version}" -- crystal --version
    "${TOOLCHAIN_SCRIPT}" run "${version}" -- "${BASH_SOURCE[0]}" __version_check "${version}"
    "${TOOLCHAIN_SCRIPT}" run "${version}" -- "${BASH_SOURCE[0]}" __format_check
    "${TOOLCHAIN_SCRIPT}" run "${version}" -- "${BASH_SOURCE[0]}" __wordcount_check
    "${TOOLCHAIN_SCRIPT}" run "${version}" -- "${BASH_SOURCE[0]}" __fibonacci_check
  done

  banner "Compatibility smoke passed"
  log "Validated versions: ${versions[*]}"
}

case "${1:-}" in
  __version_check)
    shift
    version_check "$@"
    ;;
  __format_check)
    shift
    format_check "$@"
    ;;
  __wordcount_check)
    shift
    wordcount_check "$@"
    ;;
  __fibonacci_check)
    shift
    fibonacci_check "$@"
    ;;
  *)
    run_main "$@"
    ;;
esac
