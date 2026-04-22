#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

die() {
  echo "error: $*" >&2
  exit 1
}

have_ref() {
  git rev-parse --verify --quiet "$1" >/dev/null
}

stable_tag() {
  git tag --list '[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | head -n 1
}

overlap_files() {
  local base_ref="$1"
  local upstream_ref="$2"
  local feature_ref="$3"

  comm -12 \
    <(git diff --name-only "${base_ref}..${upstream_ref}" | sort) \
    <(git diff --name-only "${upstream_ref}...${feature_ref}" | sort)
}

print_branch_row() {
  local ref="$1"
  local upstream_ref="$2"
  local base_ref="$3"
  local ahead behind overlap_count

  read -r ahead behind < <(git rev-list --left-right --count "${ref}...${upstream_ref}")
  overlap_count="$(overlap_files "${base_ref}" "${upstream_ref}" "${ref}" | wc -l | tr -d ' ')"
  printf "%-28s %8s %8s %8s\n" "${ref}" "${ahead}" "${behind}" "${overlap_count}"
}

main() {
  local should_fetch=0
  if [[ "${1:-}" == "--fetch" ]]; then
    should_fetch=1
  elif [[ $# -gt 0 ]]; then
    die "unsupported argument: $1"
  fi

  cd "${REPO_ROOT}"

  if (( should_fetch )); then
    git fetch origin --tags
    git fetch fork --tags
  fi

  local upstream_ref="origin/master"
  local base_ref="fork/master"
  local feature_refs=(
    "fork/incremental-compilation"
    "fork/wasm-support"
  )

  have_ref "${upstream_ref}" || die "missing ref: ${upstream_ref}"
  have_ref "${base_ref}" || die "missing ref: ${base_ref}"

  local latest_tag
  latest_tag="$(stable_tag)"

  echo "Repository: ${REPO_ROOT}"
  echo "Upstream head: ${upstream_ref} ($(git rev-parse --short "${upstream_ref}"))"
  echo "Fork base: ${base_ref} ($(git rev-parse --short "${base_ref}"))"
  if [[ -n "${latest_tag}" ]]; then
    echo "Latest stable upstream tag: ${latest_tag} ($(git log -1 --format=%cs "${latest_tag}^{}"))"
  fi
  echo

  printf "%-28s %8s %8s %8s\n" "branch" "ahead" "behind" "overlap"
  printf "%-28s %8s %8s %8s\n" "------" "-----" "------" "-------"
  print_branch_row "${base_ref}" "${upstream_ref}" "${base_ref}"
  local ref
  for ref in "${feature_refs[@]}"; do
    if have_ref "${ref}"; then
      print_branch_row "${ref}" "${upstream_ref}" "${base_ref}"
    fi
  done

  echo
  echo "Recent upstream commits since ${base_ref}:"
  git log --oneline "${base_ref}..${upstream_ref}" | sed -n '1,12p'

  echo
  for ref in "${feature_refs[@]}"; do
    if ! have_ref "${ref}"; then
      continue
    fi

    echo "Recent commits unique to ${ref}:"
    git log --oneline "${upstream_ref}..${ref}" | sed -n '1,10p'
    echo

    echo "Overlapping files between ${upstream_ref} drift and ${ref}:"
    overlap_files "${base_ref}" "${upstream_ref}" "${ref}" | sed -n '1,20p'
    echo
  done
}

main "$@"
