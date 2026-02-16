#!/bin/bash
set -e

# =============================================================================
# Crystal Incremental Compiler Benchmark
# =============================================================================
#
# Compares stock Crystal (system `crystal`) against the incremental compiler
# (`crystal-alpha` or `.build/crystal`) across multiple targets and scenarios.
#
# Usage:
#   scripts/benchmark.sh [OPTIONS]
#
# Options:
#   --include-self-compile   Include Tier 4 (self-compilation) benchmark
#   --tier N                 Run only the specified tier (1-4)
#   --no-color               Disable colored output
#   --help                   Show this help message
#
# =============================================================================

# -- Configuration ------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="/tmp/crystal-bench"
RESULTS_FILE="$REPO_ROOT/benchmark_results.txt"
INCLUDE_SELF_COMPILE=false
TIER_FILTER=""
USE_COLOR=true

# -- Color codes --------------------------------------------------------------

setup_colors() {
  if [ "$USE_COLOR" = true ] && [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    WHITE='\033[1;37m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
  else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    MAGENTA=''
    CYAN=''
    WHITE=''
    BOLD=''
    DIM=''
    RESET=''
  fi
}

# -- Argument parsing ---------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --include-self-compile)
      INCLUDE_SELF_COMPILE=true
      shift
      ;;
    --tier)
      TIER_FILTER="$2"
      shift 2
      ;;
    --no-color)
      USE_COLOR=false
      shift
      ;;
    --help|-h)
      echo "Usage: scripts/benchmark.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --include-self-compile   Include Tier 4 (self-compilation) benchmark"
      echo "  --tier N                 Run only the specified tier (1-4)"
      echo "  --no-color               Disable colored output"
      echo "  --help                   Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

setup_colors

# -- High-precision timing ----------------------------------------------------

# macOS `date` does not support %N (nanoseconds). We use perl as a portable
# fallback that provides sub-millisecond resolution.
now_ns() {
  if date +%s%N 2>/dev/null | grep -qE '^[0-9]+$'; then
    date +%s%N
  else
    perl -MTime::HiRes=time -e 'printf "%.0f\n", time*1e9'
  fi
}

# Measure the wall-clock time of a command in milliseconds.
# Usage: measure "label" command [args...]
# Globals set after call: LAST_ELAPSED_MS, LAST_STDERR
measure() {
  local label="$1"; shift
  local stderr_file
  stderr_file=$(mktemp)

  local start end_time
  start=$(now_ns)
  "$@" >"$OUTPUT_DIR/last_stdout.log" 2>"$stderr_file" || true
  end_time=$(now_ns)

  LAST_ELAPSED_MS=$(( (end_time - start) / 1000000 ))
  LAST_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"

  printf "    %-42s %6d ms\n" "$label" "$LAST_ELAPSED_MS"
}

# -- Cache stats extraction ---------------------------------------------------

# Parse cache stats from stderr output captured during --incremental --stats.
# Expected format from the compiler:
#   Parse cache:
#    - hits: N, misses: M (X.Y% hit rate)
#   Codegen (bc+obj):
#    - N/M .o files were reused
#    - Modules skipped: N of M (cached)
#   Signature tracking:
#    - Files with body-only changes: N
#    - Files with structural changes: N
extract_cache_stats() {
  local stderr_text="$1"
  local stats_line=""

  # Parse cache hits/misses
  local parse_hits parse_misses
  parse_hits=$(echo "$stderr_text" | grep -oE 'hits: [0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")
  parse_misses=$(echo "$stderr_text" | grep -oE 'misses: [0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")

  if [ -n "$parse_hits" ] && [ -n "$parse_misses" ]; then
    stats_line="[cache: ${parse_hits} hits, ${parse_misses} misses]"
  fi

  # Codegen reuse
  local codegen_reused
  codegen_reused=$(echo "$stderr_text" | grep -oE '[0-9]+/[0-9]+ \.o files were reused' | head -1 || echo "")
  if [ -n "$codegen_reused" ]; then
    stats_line="${stats_line:+$stats_line }[codegen: ${codegen_reused}]"
  fi

  # Module skip (Phase 4)
  local modules_skipped
  modules_skipped=$(echo "$stderr_text" | grep -oE 'Modules skipped: [0-9]+ of [0-9]+' | head -1 || echo "")
  if [ -n "$modules_skipped" ]; then
    stats_line="${stats_line:+$stats_line }[${modules_skipped}]"
  fi

  # Signature tracking (Phase 6)
  local body_only structural
  body_only=$(echo "$stderr_text" | grep -oE 'body-only changes: [0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")
  structural=$(echo "$stderr_text" | grep -oE 'structural changes: [0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")
  if [ -n "$body_only" ] || [ -n "$structural" ]; then
    stats_line="${stats_line:+$stats_line }[sig: ${body_only:-0} body-only, ${structural:-0} structural]"
  fi

  echo "$stats_line"
}

# -- Prerequisites ------------------------------------------------------------

check_prerequisites() {
  echo -e "${BOLD}Checking prerequisites...${RESET}"

  # Stock Crystal
  if ! command -v crystal &>/dev/null; then
    echo -e "${RED}Error: 'crystal' not found in PATH.${RESET}"
    echo "Install Crystal (https://crystal-lang.org/install/) or add it to PATH."
    exit 1
  fi
  STOCK_CRYSTAL=$(command -v crystal)
  STOCK_VERSION=$(crystal version 2>&1 | head -1)
  echo "  Stock Crystal:       $STOCK_CRYSTAL"
  echo "  Version:             $STOCK_VERSION"

  # Incremental compiler (crystal-alpha or .build/crystal)
  if command -v crystal-alpha &>/dev/null; then
    INCR_CRYSTAL=$(command -v crystal-alpha)
  elif [ -x "$REPO_ROOT/.build/crystal" ]; then
    INCR_CRYSTAL="$REPO_ROOT/.build/crystal"
  else
    echo -e "${RED}Error: Neither 'crystal-alpha' nor '$REPO_ROOT/.build/crystal' found.${RESET}"
    echo "Build the incremental compiler first:  make crystal"
    exit 1
  fi
  INCR_VERSION=$("$INCR_CRYSTAL" version 2>&1 | head -1)
  echo "  Incremental Crystal: $INCR_CRYSTAL"
  echo "  Version:             $INCR_VERSION"

  # Verify sample files exist
  local missing=false
  for sample in fibonacci.cr sieve.cr wordcount.cr binary-trees.cr havlak.cr; do
    if [ ! -f "$REPO_ROOT/samples/$sample" ]; then
      echo -e "${RED}Error: Missing sample file: samples/$sample${RESET}"
      missing=true
    fi
  done
  if [ "$INCLUDE_SELF_COMPILE" = true ] && [ ! -f "$REPO_ROOT/src/compiler/crystal.cr" ]; then
    echo -e "${RED}Error: Missing src/compiler/crystal.cr for self-compilation benchmark.${RESET}"
    missing=true
  fi
  if [ "$missing" = true ]; then
    exit 1
  fi

  echo ""
}

# -- Crystal cache directory management ---------------------------------------

# Get the Crystal cache directory (same logic the compiler uses)
get_crystal_cache_dir() {
  local cache_dir
  cache_dir="${CRYSTAL_CACHE_DIR:-}"
  if [ -z "$cache_dir" ]; then
    cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/crystal"
  fi
  echo "$cache_dir"
}

# Clean the Crystal compiler cache to force a true cold build.
# This removes the cache directory where .bc/.o files and incremental_cache.json
# are stored.
clean_crystal_cache() {
  local cache_dir
  cache_dir=$(get_crystal_cache_dir)
  if [ -d "$cache_dir" ]; then
    rm -rf "$cache_dir"
  fi
}

# -- Binary verification ------------------------------------------------------

# Run a quick verification of the built binary.
# For simple programs (fibonacci, sieve, binary-trees): execute and check exit code.
# For complex programs (havlak, self-compile): just check the binary exists.
verify_binary() {
  local binary="$1"
  local sample_name="$2"

  if [ ! -f "$binary" ]; then
    echo -e "    ${RED}FAIL: Binary not found: $binary${RESET}"
    return 1
  fi

  case "$sample_name" in
    fibonacci|sieve)
      if timeout 10 "$binary" >/dev/null 2>&1; then
        echo -e "    ${DIM}(verified: runs correctly)${RESET}"
      else
        echo -e "    ${YELLOW}WARN: Binary exited with non-zero status${RESET}"
      fi
      ;;
    binary-trees)
      # Run with a small depth to keep it quick
      if timeout 30 "$binary" 6 >/dev/null 2>&1; then
        echo -e "    ${DIM}(verified: runs correctly)${RESET}"
      else
        echo -e "    ${YELLOW}WARN: Binary exited with non-zero status${RESET}"
      fi
      ;;
    havlak|self-compile)
      echo -e "    ${DIM}(verified: binary exists, $(du -h "$binary" | awk '{print $1}'))${RESET}"
      ;;
    wordcount)
      # wordcount expects input; just verify it starts
      if echo "hello world" | timeout 10 "$binary" >/dev/null 2>&1; then
        echo -e "    ${DIM}(verified: runs correctly)${RESET}"
      else
        echo -e "    ${YELLOW}WARN: Binary exited with non-zero status${RESET}"
      fi
      ;;
  esac
}

# -- Result tracking ----------------------------------------------------------

# Associative arrays to store results for the final comparison table.
# We track: target_name -> scenario -> time_ms
declare -a RESULT_LINES=()

record_result() {
  local target="$1"
  local scenario="$2"
  local time_ms="$3"
  local stats="$4"
  RESULT_LINES+=("${target}|${scenario}|${time_ms}|${stats}")
}

# -- Benchmark functions ------------------------------------------------------

# Run all scenarios for a given source file.
# Arguments:
#   $1 - display name (e.g., "fibonacci.cr")
#   $2 - source file path
#   $3 - sample name for verification (e.g., "fibonacci")
#   $4 - extra build flags (optional)
benchmark_target() {
  local display_name="$1"
  local source_file="$2"
  local sample_name="$3"
  local extra_flags="${4:-}"
  local binary_base
  binary_base=$(basename "$source_file" .cr)
  local stock_binary="$OUTPUT_DIR/stock_${binary_base}"
  local incr_binary="$OUTPUT_DIR/incr_${binary_base}"

  echo -e "  ${CYAN}${display_name}${RESET}"

  # -- Scenario 1: Stock Crystal cold build ----------------------------------
  echo -e "    ${DIM}--- Stock Crystal ---${RESET}"
  clean_crystal_cache
  rm -f "$stock_binary"
  measure "Stock cold build:" \
    "$STOCK_CRYSTAL" build "$source_file" -o "$stock_binary" $extra_flags
  local stock_cold_ms=$LAST_ELAPSED_MS
  record_result "$display_name" "Stock cold build" "$stock_cold_ms" ""
  verify_binary "$stock_binary" "$sample_name"

  # -- Scenario 2: Stock Crystal cold build + --release ----------------------
  clean_crystal_cache
  rm -f "${stock_binary}_release"
  measure "Stock cold build + --release:" \
    "$STOCK_CRYSTAL" build "$source_file" -o "${stock_binary}_release" --release $extra_flags
  local stock_release_ms=$LAST_ELAPSED_MS
  record_result "$display_name" "Stock cold + --release" "$stock_release_ms" ""
  verify_binary "${stock_binary}_release" "$sample_name"

  # -- Scenario 3: Incremental cold build (no cache, --incremental) ----------
  echo ""
  echo -e "    ${DIM}--- Incremental Compiler ---${RESET}"
  clean_crystal_cache
  rm -f "$incr_binary"
  measure "Incremental cold build:" \
    "$INCR_CRYSTAL" build "$source_file" -o "$incr_binary" --incremental --stats $extra_flags
  local incr_cold_ms=$LAST_ELAPSED_MS
  local incr_cold_stats
  incr_cold_stats=$(extract_cache_stats "$LAST_STDERR")
  record_result "$display_name" "Incr cold build" "$incr_cold_ms" "$incr_cold_stats"
  if [ -n "$incr_cold_stats" ]; then
    echo -e "      ${DIM}${incr_cold_stats}${RESET}"
  fi
  verify_binary "$incr_binary" "$sample_name"

  # -- Scenario 4: Incremental cold build + --release ------------------------
  clean_crystal_cache
  rm -f "${incr_binary}_release"
  measure "Incremental cold + --release:" \
    "$INCR_CRYSTAL" build "$source_file" -o "${incr_binary}_release" --incremental --release --stats $extra_flags
  local incr_release_ms=$LAST_ELAPSED_MS
  local incr_release_stats
  incr_release_stats=$(extract_cache_stats "$LAST_STDERR")
  record_result "$display_name" "Incr cold + --release" "$incr_release_ms" "$incr_release_stats"
  if [ -n "$incr_release_stats" ]; then
    echo -e "      ${DIM}${incr_release_stats}${RESET}"
  fi
  verify_binary "${incr_binary}_release" "$sample_name"

  # -- Scenario 5: Incremental warm build (no changes, --incremental) --------
  # The cache was populated by Scenario 4 (release) which uses single-module
  # mode and different flags. We do a fresh cold build first to populate the
  # cache properly for a non-release warm build.
  rm -f "$incr_binary"
  clean_crystal_cache
  "$INCR_CRYSTAL" build "$source_file" -o "$incr_binary" --incremental $extra_flags \
    >"$OUTPUT_DIR/warmup_stdout.log" 2>"$OUTPUT_DIR/warmup_stderr.log" || true

  # Now run the warm build (no changes)
  measure "Incremental warm (no change):" \
    "$INCR_CRYSTAL" build "$source_file" -o "$incr_binary" --incremental --stats $extra_flags
  local incr_warm_ms=$LAST_ELAPSED_MS
  local incr_warm_stats
  incr_warm_stats=$(extract_cache_stats "$LAST_STDERR")
  record_result "$display_name" "Incr warm (no change)" "$incr_warm_ms" "$incr_warm_stats"
  if [ -n "$incr_warm_stats" ]; then
    echo -e "      ${DIM}${incr_warm_stats}${RESET}"
  fi

  # -- Scenario 6: Incremental warm build (touch source, --incremental) ------
  touch "$source_file"
  sleep 0.1  # Ensure mtime change is detected

  measure "Incremental warm (touched):" \
    "$INCR_CRYSTAL" build "$source_file" -o "$incr_binary" --incremental --stats $extra_flags
  local incr_touched_ms=$LAST_ELAPSED_MS
  local incr_touched_stats
  incr_touched_stats=$(extract_cache_stats "$LAST_STDERR")
  record_result "$display_name" "Incr warm (touched)" "$incr_touched_ms" "$incr_touched_stats"
  if [ -n "$incr_touched_stats" ]; then
    echo -e "      ${DIM}${incr_touched_stats}${RESET}"
  fi

  echo ""
}

# -- Print results table ------------------------------------------------------

print_separator() {
  local width=$1
  local char="${2:-─}"
  printf '%*s\n' "$width" '' | tr ' ' "$char"
}

print_results_table() {
  local width=78

  echo ""
  echo -e "${BOLD}╔$(printf '%*s' $((width - 2)) '' | tr ' ' '═')╗${RESET}"
  printf "${BOLD}║%-$((width - 2))s║${RESET}\n" "           Crystal Incremental Compiler Benchmark Results"
  echo -e "${BOLD}╠$(printf '%*s' $((width - 2)) '' | tr ' ' '═')╣${RESET}"
  printf "${BOLD}║${RESET} Stock Crystal: %-$((width - 18))s${BOLD}║${RESET}\n" "$STOCK_VERSION"
  printf "${BOLD}║${RESET} Incremental:   %-$((width - 18))s${BOLD}║${RESET}\n" "$INCR_VERSION"
  printf "${BOLD}║${RESET} Date:          %-$((width - 18))s${BOLD}║${RESET}\n" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf "${BOLD}║${RESET} Repo Root:     %-$((width - 18))s${BOLD}║${RESET}\n" "$REPO_ROOT"
  echo -e "${BOLD}╚$(printf '%*s' $((width - 2)) '' | tr ' ' '═')╝${RESET}"
  echo ""

  # Comparison table header
  printf "${BOLD}  %-24s %-20s %10s %10s %8s${RESET}\n" \
    "Target" "Scenario" "Stock(ms)" "Incr(ms)" "Delta"
  print_separator 78

  local current_target=""
  local stock_cold_time=""

  for line in "${RESULT_LINES[@]}"; do
    IFS='|' read -r target scenario time_ms stats <<< "$line"

    # Print target header when it changes
    if [ "$target" != "$current_target" ]; then
      if [ -n "$current_target" ]; then
        echo ""
      fi
      current_target="$target"
      stock_cold_time=""
    fi

    # Determine stock/incr columns and delta
    local stock_col="-"
    local incr_col="-"
    local delta=""

    case "$scenario" in
      "Stock cold build")
        stock_col="$time_ms"
        stock_cold_time="$time_ms"
        ;;
      "Stock cold + --release")
        stock_col="$time_ms"
        ;;
      "Incr cold build")
        incr_col="$time_ms"
        if [ -n "$stock_cold_time" ] && [ "$stock_cold_time" -gt 0 ]; then
          local diff=$(( time_ms - stock_cold_time ))
          local pct
          pct=$(awk "BEGIN { printf \"%.1f\", ($diff / $stock_cold_time) * 100 }")
          if [ "$diff" -le 0 ]; then
            delta="${GREEN}${pct}%${RESET}"
          else
            delta="${RED}+${pct}%${RESET}"
          fi
        fi
        ;;
      "Incr cold + --release")
        incr_col="$time_ms"
        ;;
      "Incr warm (no change)")
        incr_col="$time_ms"
        if [ -n "$stock_cold_time" ] && [ "$stock_cold_time" -gt 0 ]; then
          local diff=$(( time_ms - stock_cold_time ))
          local pct
          pct=$(awk "BEGIN { printf \"%.1f\", ($diff / $stock_cold_time) * 100 }")
          if [ "$diff" -le 0 ]; then
            delta="${GREEN}${pct}%${RESET}"
          else
            delta="${RED}+${pct}%${RESET}"
          fi
        fi
        ;;
      "Incr warm (touched)")
        incr_col="$time_ms"
        if [ -n "$stock_cold_time" ] && [ "$stock_cold_time" -gt 0 ]; then
          local diff=$(( time_ms - stock_cold_time ))
          local pct
          pct=$(awk "BEGIN { printf \"%.1f\", ($diff / $stock_cold_time) * 100 }")
          if [ "$diff" -le 0 ]; then
            delta="${GREEN}${pct}%${RESET}"
          else
            delta="${RED}+${pct}%${RESET}"
          fi
        fi
        ;;
    esac

    local stats_suffix=""
    if [ -n "$stats" ]; then
      stats_suffix=" ${DIM}${stats}${RESET}"
    fi

    printf "  %-24s %-20s %10s %10s %b${stats_suffix}\n" \
      "$target" "$scenario" "$stock_col" "$incr_col" "${delta:- }"
  done

  echo ""
  print_separator 78
  echo ""
}

# Save plain-text results (without ANSI escapes) to the results file.
save_results_file() {
  {
    local width=78

    echo "========================================================================"
    echo "   Crystal Incremental Compiler Benchmark Results"
    echo "========================================================================"
    echo " Stock Crystal: $STOCK_VERSION"
    echo " Incremental:   $INCR_VERSION"
    echo " Date:          $(date '+%Y-%m-%d %H:%M:%S')"
    echo " Repo Root:     $REPO_ROOT"
    echo "========================================================================"
    echo ""
    printf "  %-24s %-20s %10s %10s %8s\n" \
      "Target" "Scenario" "Stock(ms)" "Incr(ms)" "Stats"
    printf '  %s\n' "$(printf '%*s' 74 '' | tr ' ' '-')"

    local current_target=""

    for line in "${RESULT_LINES[@]}"; do
      IFS='|' read -r target scenario time_ms stats <<< "$line"

      if [ "$target" != "$current_target" ]; then
        if [ -n "$current_target" ]; then
          echo ""
        fi
        current_target="$target"
      fi

      local stock_col="-"
      local incr_col="-"

      case "$scenario" in
        Stock*)
          stock_col="$time_ms"
          ;;
        Incr*)
          incr_col="$time_ms"
          ;;
      esac

      printf "  %-24s %-20s %10s %10s  %s\n" \
        "$target" "$scenario" "$stock_col" "$incr_col" "$stats"
    done

    echo ""
    echo "========================================================================"
  } > "$RESULTS_FILE"

  echo -e "${DIM}Results saved to: $RESULTS_FILE${RESET}"
}

# -- Main execution -----------------------------------------------------------

main() {
  echo ""
  echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${BLUE}║       Crystal Incremental Compiler Benchmark Suite          ║${RESET}"
  echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""

  check_prerequisites

  # Prepare output directory
  rm -rf "$OUTPUT_DIR"
  mkdir -p "$OUTPUT_DIR"

  local total_start
  total_start=$(now_ns)

  # -- Tier 1: Quick ---------------------------------------------------------
  if [ -z "$TIER_FILTER" ] || [ "$TIER_FILTER" = "1" ]; then
    echo -e "${BOLD}${MAGENTA}── Tier 1: Quick ──────────────────────────────────────────────${RESET}"
    echo ""

    benchmark_target "fibonacci.cr" \
      "$REPO_ROOT/samples/fibonacci.cr" \
      "fibonacci"

    benchmark_target "sieve.cr" \
      "$REPO_ROOT/samples/sieve.cr" \
      "sieve"
  fi

  # -- Tier 2: Light ---------------------------------------------------------
  if [ -z "$TIER_FILTER" ] || [ "$TIER_FILTER" = "2" ]; then
    echo -e "${BOLD}${MAGENTA}── Tier 2: Light ──────────────────────────────────────────────${RESET}"
    echo ""

    benchmark_target "wordcount.cr" \
      "$REPO_ROOT/samples/wordcount.cr" \
      "wordcount"

    benchmark_target "binary-trees.cr" \
      "$REPO_ROOT/samples/binary-trees.cr" \
      "binary-trees"
  fi

  # -- Tier 3: Medium --------------------------------------------------------
  if [ -z "$TIER_FILTER" ] || [ "$TIER_FILTER" = "3" ]; then
    echo -e "${BOLD}${MAGENTA}── Tier 3: Medium ─────────────────────────────────────────────${RESET}"
    echo ""

    benchmark_target "havlak.cr" \
      "$REPO_ROOT/samples/havlak.cr" \
      "havlak"
  fi

  # -- Tier 4: Heavy (self-compilation) --------------------------------------
  if [ -z "$TIER_FILTER" ] || [ "$TIER_FILTER" = "4" ]; then
    if [ "$INCLUDE_SELF_COMPILE" = true ] || [ "$TIER_FILTER" = "4" ]; then
      echo -e "${BOLD}${MAGENTA}── Tier 4: Heavy (Self-Compilation) ───────────────────────────${RESET}"
      echo ""

      local self_compile_flags="-Dwithout_interpreter -Dwithout_libxml2 -Dwithout_openssl -Dwithout_zlib -Duse_pcre2"

      benchmark_target "crystal.cr (self)" \
        "$REPO_ROOT/src/compiler/crystal.cr" \
        "self-compile" \
        "$self_compile_flags"
    else
      echo -e "${DIM}Tier 4 (self-compilation) skipped. Use --include-self-compile to enable.${RESET}"
      echo ""
    fi
  fi

  # -- Summary ----------------------------------------------------------------
  local total_end
  total_end=$(now_ns)
  local total_elapsed_ms=$(( (total_end - total_start) / 1000000 ))
  local total_elapsed_sec=$(awk "BEGIN { printf \"%.1f\", $total_elapsed_ms / 1000 }")

  echo -e "${BOLD}Total benchmark time: ${total_elapsed_sec}s${RESET}"
  echo ""

  print_results_table
  save_results_file
}

main
