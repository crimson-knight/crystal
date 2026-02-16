#!/bin/bash
set -e

# ==============================================================================
#  Crystal Watch Mode Recompilation Benchmark
# ==============================================================================
#
#  Measures watch mode recompilation performance and compares it with
#  sequential `crystal-alpha build` invocations. Watch mode keeps the compiler
#  instance alive between compilations, so the parse cache persists in memory.
#
#  Test targets:
#    - kemal           (popular web framework)
#    - spider-gazelle  (alternative web framework)
#    - havlak.cr       (non-framework baseline)
#
#  Usage:
#    ./scripts/benchmark_watch.sh [OPTIONS]
#
#  Options:
#    --target NAME     Run only the specified target (kemal, spider-gazelle, havlak)
#    --iterations N    Number of recompilation cycles in watch mode (default: 3)
#    --no-color        Disable colored output
#    --help            Show this help message
#
# ==============================================================================

# -- Configuration ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BENCH_DIR="/tmp/crystal-bench-frameworks"
OUTPUT_DIR="/tmp/crystal-bench-watch"
RESULTS_FILE="${REPO_ROOT}/benchmark_watch_results.txt"

TARGET_FILTER=""
ITERATIONS=3
USE_COLOR=true

# Timeouts (seconds)
INITIAL_COMPILE_TIMEOUT=300
RECOMPILE_TIMEOUT=120

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
    --target)
      TARGET_FILTER="$2"
      shift 2
      ;;
    --iterations)
      ITERATIONS="$2"
      shift 2
      ;;
    --no-color)
      USE_COLOR=false
      shift
      ;;
    --help|-h)
      echo "Usage: scripts/benchmark_watch.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --target NAME     Run only the specified target (kemal, spider-gazelle, havlak)"
      echo "  --iterations N    Number of watch recompilation cycles (default: 3)"
      echo "  --no-color        Disable colored output"
      echo "  --help            Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

setup_colors

# -- High-precision timing (macOS-compatible) ---------------------------------

now_ns() {
  perl -MTime::HiRes=time -e 'printf "%.0f\n", time*1e9'
}

ns_to_ms() {
  echo $(( $1 / 1000000 ))
}

# -- Logging ------------------------------------------------------------------

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERR]${RESET}   $*" >&2; }

# -- Crystal cache management -------------------------------------------------

get_crystal_cache_dir() {
  local cache_dir
  cache_dir="${CRYSTAL_CACHE_DIR:-}"
  if [ -z "$cache_dir" ]; then
    cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/crystal"
  fi
  echo "$cache_dir"
}

clean_crystal_cache() {
  local cache_dir
  cache_dir=$(get_crystal_cache_dir)
  rm -rf "$cache_dir" 2>/dev/null || true
}

# -- Watch log helpers --------------------------------------------------------

# Get current line count of a log file.
log_line_count() {
  local logfile="$1"
  if [ -f "$logfile" ]; then
    wc -l < "$logfile" | tr -d ' '
  else
    echo 0
  fi
}

# Wait until a pattern appears in the log file (searching the whole file).
# Returns 0 on match, 1 on timeout.
wait_for_log() {
  local logfile="$1"
  local pattern="$2"
  local timeout_secs="${3:-$INITIAL_COMPILE_TIMEOUT}"
  local deadline_ns=$(( $(now_ns) + timeout_secs * 1000000000 ))

  while [ "$(now_ns)" -lt "$deadline_ns" ]; do
    if [ -f "$logfile" ] && grep -q "$pattern" "$logfile" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# Wait until a pattern appears in NEW lines of the log file (after baseline).
# Returns 0 on match, 1 on timeout.
wait_for_new_log() {
  local logfile="$1"
  local pattern="$2"
  local baseline_lines="$3"
  local timeout_secs="${4:-$RECOMPILE_TIMEOUT}"
  local deadline_ns=$(( $(now_ns) + timeout_secs * 1000000000 ))

  while [ "$(now_ns)" -lt "$deadline_ns" ]; do
    if [ -f "$logfile" ]; then
      local current_lines
      current_lines=$(wc -l < "$logfile" | tr -d ' ')
      if [ "$current_lines" -gt "$baseline_lines" ]; then
        if tail -n +"$(( baseline_lines + 1 ))" "$logfile" | grep -q "$pattern" 2>/dev/null; then
          return 0
        fi
      fi
    fi
    sleep 0.05
  done
  return 1
}

# Extract the execution time from watch output lines after a baseline.
# The -t flag prints a line like: "Execution time: 0.001234s" or the
# watch mode may include timing in its own format. We look for patterns
# that indicate elapsed compilation time.
extract_watch_compile_time_ms() {
  local logfile="$1"
  local baseline_lines="$2"

  # The watch mode logs lines between "[watch] Compiling..." and
  # "[watch] Compiled successfully". We look for the stats output
  # which includes "Parse:" or "Codegen:" timing, or we can measure
  # the wall-clock time between events. For now, extract the total
  # time if printed, otherwise return empty.
  local new_output
  new_output=$(tail -n +"$(( baseline_lines + 1 ))" "$logfile" 2>/dev/null || echo "")

  # Look for explicit time output (e.g., "Total: XXXms" or similar)
  local total_time
  total_time=$(echo "$new_output" | grep -oE 'Total[[:space:]]*:[[:space:]]*[0-9]+(\.[0-9]+)?ms' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?ms' | head -1 || echo "")
  if [ -n "$total_time" ]; then
    # Strip the 'ms' suffix and return
    echo "$total_time" | sed 's/ms$//'
    return
  fi

  # Look for execution time in seconds format
  total_time=$(echo "$new_output" | grep -oE 'Execution time:[[:space:]]*[0-9]+\.[0-9]+s' | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "")
  if [ -n "$total_time" ]; then
    # Convert seconds to ms
    echo "$total_time" | awk '{ printf "%.0f", $1 * 1000 }'
    return
  fi

  echo ""
}

# Extract cache stats from watch output lines after a baseline.
extract_watch_stats() {
  local logfile="$1"
  local baseline_lines="$2"
  local new_output
  new_output=$(tail -n +"$(( baseline_lines + 1 ))" "$logfile" 2>/dev/null || echo "")

  local stats_line=""

  # Parse cache hits/misses
  local parse_hits parse_misses
  parse_hits=$(echo "$new_output" | grep -oE 'hits: [0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")
  parse_misses=$(echo "$new_output" | grep -oE 'misses: [0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")
  if [ -n "$parse_hits" ] && [ -n "$parse_misses" ]; then
    stats_line="[cache: ${parse_hits} hits, ${parse_misses} misses]"
  fi

  # Codegen reuse
  local codegen_reused
  codegen_reused=$(echo "$new_output" | grep -oE '[0-9]+/[0-9]+ \.o files were reused' | head -1 || echo "")
  if [ -n "$codegen_reused" ]; then
    stats_line="${stats_line:+$stats_line }[codegen: ${codegen_reused}]"
  fi

  # Module skip
  local modules_skipped
  modules_skipped=$(echo "$new_output" | grep -oE 'Modules skipped: [0-9]+ of [0-9]+' | head -1 || echo "")
  if [ -n "$modules_skipped" ]; then
    stats_line="${stats_line:+$stats_line }[${modules_skipped}]"
  fi

  echo "$stats_line"
}

# -- Process management -------------------------------------------------------

WATCH_PID=""

stop_watch() {
  if [ -n "$WATCH_PID" ] && kill -0 "$WATCH_PID" 2>/dev/null; then
    info "Stopping watch process (PID ${WATCH_PID})..."
    kill "$WATCH_PID" 2>/dev/null || true
    local waited=0
    while kill -0 "$WATCH_PID" 2>/dev/null && [ "$waited" -lt 5 ]; do
      sleep 1
      waited=$(( waited + 1 ))
    done
    if kill -0 "$WATCH_PID" 2>/dev/null; then
      kill -9 "$WATCH_PID" 2>/dev/null || true
    fi
    wait "$WATCH_PID" 2>/dev/null || true
    WATCH_PID=""
  fi
}

cleanup() {
  stop_watch
}

trap cleanup EXIT

# -- Prerequisites ------------------------------------------------------------

check_prerequisites() {
  echo -e "${BOLD}Checking prerequisites...${RESET}"

  # Incremental compiler (crystal-alpha or .build/crystal)
  if command -v crystal-alpha &>/dev/null; then
    CRYSTAL="$(command -v crystal-alpha)"
  elif [ -x "$REPO_ROOT/.build/crystal" ]; then
    CRYSTAL="$REPO_ROOT/.build/crystal"
  else
    error "Neither 'crystal-alpha' nor '${REPO_ROOT}/.build/crystal' found."
    error "Build the incremental compiler first:  make crystal"
    exit 1
  fi
  CRYSTAL_VERSION=$("$CRYSTAL" version 2>&1 | head -1)
  info "Crystal compiler: $CRYSTAL"
  info "Version:          $CRYSTAL_VERSION"

  # Verify watch command support
  if ! "$CRYSTAL" help 2>&1 | grep -q "watch"; then
    error "This compiler does not support 'crystal watch'."
    error "Make sure you are using the incremental-compilation branch build."
    exit 1
  fi
  success "Compiler supports 'crystal watch'"

  # Verify havlak sample
  if [ ! -f "$REPO_ROOT/samples/havlak.cr" ]; then
    error "Missing sample file: samples/havlak.cr"
    exit 1
  fi

  echo ""
}

# -- Result storage (file-based, Bash 3.2 compatible) -------------------------

RESULTS_STORE="${OUTPUT_DIR}/.results"

store_result() {
  local target="$1" key="$2" value="$3"
  mkdir -p "${RESULTS_STORE}/${target}"
  echo "${value}" > "${RESULTS_STORE}/${target}/${key}"
}

get_result() {
  local target="$1" key="$2" default="${3:-N/A}"
  local file="${RESULTS_STORE}/${target}/${key}"
  if [ -f "${file}" ]; then
    cat "${file}"
  else
    echo "${default}"
  fi
}

# ==============================================================================
# Sequential build benchmark for a single target
# ==============================================================================

# Arguments:
#   $1 - target name (display label)
#   $2 - working directory (cd into this before building)
#   $3 - source file (relative to working directory)
#   $4 - output binary path (relative to working directory)
benchmark_sequential() {
  local target_name="$1"
  local work_dir="$2"
  local source_file="$3"
  local output_binary="$4"

  echo -e "  ${DIM}--- Sequential builds ---${RESET}"

  # Cold build (clean cache)
  clean_crystal_cache
  rm -f "${work_dir}/${output_binary}"

  local t_start t_end elapsed_ms
  t_start=$(now_ns)
  (cd "$work_dir" && "$CRYSTAL" build "$source_file" -o "$output_binary" --incremental --stats 2>&1) \
    > "${OUTPUT_DIR}/seq_cold.log" 2>&1 || true
  t_end=$(now_ns)
  elapsed_ms=$(ns_to_ms $(( t_end - t_start )))
  store_result "$target_name" "seq_cold_ms" "$elapsed_ms"
  printf "  %-36s ${BOLD}%6d${RESET} ms\n" "Cold build:" "$elapsed_ms"

  # Warm build (no changes)
  t_start=$(now_ns)
  (cd "$work_dir" && "$CRYSTAL" build "$source_file" -o "$output_binary" --incremental --stats 2>&1) \
    > "${OUTPUT_DIR}/seq_warm_noop.log" 2>&1 || true
  t_end=$(now_ns)
  elapsed_ms=$(ns_to_ms $(( t_end - t_start )))
  store_result "$target_name" "seq_warm_noop_ms" "$elapsed_ms"
  printf "  %-36s ${BOLD}%6d${RESET} ms\n" "Warm (no change):" "$elapsed_ms"

  # Warm build (touched source)
  touch "${work_dir}/${source_file}"
  sleep 0.1

  t_start=$(now_ns)
  (cd "$work_dir" && "$CRYSTAL" build "$source_file" -o "$output_binary" --incremental --stats 2>&1) \
    > "${OUTPUT_DIR}/seq_warm_touch.log" 2>&1 || true
  t_end=$(now_ns)
  elapsed_ms=$(ns_to_ms $(( t_end - t_start )))
  store_result "$target_name" "seq_warm_touch_ms" "$elapsed_ms"
  printf "  %-36s ${BOLD}%6d${RESET} ms\n" "Warm (file touched):" "$elapsed_ms"

  echo ""
}

# ==============================================================================
# Watch mode benchmark for a single target
# ==============================================================================

# Arguments:
#   $1 - target name (display label)
#   $2 - working directory
#   $3 - source file (relative to working directory)
benchmark_watch_mode() {
  local target_name="$1"
  local work_dir="$2"
  local source_file="$3"
  local watch_log="${OUTPUT_DIR}/watch_${target_name}.log"

  echo -e "  ${DIM}--- Watch mode ---${RESET}"

  # Clean cache so watch starts cold
  clean_crystal_cache

  # Start watch mode in background
  > "$watch_log"

  local watch_start_ns
  watch_start_ns=$(now_ns)

  (cd "$work_dir" && "$CRYSTAL" watch -t -s --debounce 100 --incremental "$source_file") \
    > "$watch_log" 2>&1 &
  WATCH_PID=$!

  sleep 1

  # Verify the watch process started
  if ! kill -0 "$WATCH_PID" 2>/dev/null; then
    error "Watch process exited immediately. Log:"
    cat "$watch_log" 2>/dev/null || true
    WATCH_PID=""
    store_result "$target_name" "watch_initial_ms" "FAIL"
    return 1
  fi

  # Wait for initial compilation
  info "Waiting for initial compilation (up to ${INITIAL_COMPILE_TIMEOUT}s)..."

  if ! wait_for_log "$watch_log" "Compiled successfully" "$INITIAL_COMPILE_TIMEOUT"; then
    error "Initial compilation timed out. Log:"
    cat "$watch_log" 2>/dev/null || true
    stop_watch
    store_result "$target_name" "watch_initial_ms" "TIMEOUT"
    return 1
  fi

  local watch_compiled_ns
  watch_compiled_ns=$(now_ns)
  local initial_ms
  initial_ms=$(ns_to_ms $(( watch_compiled_ns - watch_start_ns )))
  store_result "$target_name" "watch_initial_ms" "$initial_ms"
  printf "  %-36s ${BOLD}%6d${RESET} ms\n" "Initial compilation:" "$initial_ms"

  # Extract stats from initial compilation
  local initial_stats
  initial_stats=$(extract_watch_stats "$watch_log" 0)
  if [ -n "$initial_stats" ]; then
    echo -e "    ${DIM}${initial_stats}${RESET}"
  fi

  # -- Recompilation cycles --
  local total_recompile_ms=0
  local successful_iterations=0
  local i

  for i in $(seq 1 "$ITERATIONS"); do
    local baseline
    baseline=$(log_line_count "$watch_log")

    # Touch the source file to trigger recompilation
    sleep 1  # Ensure mtime changes
    touch "${work_dir}/${source_file}"

    local recompile_start_ns
    recompile_start_ns=$(now_ns)

    # Wait for recompilation to complete
    if wait_for_new_log "$watch_log" "Compiled successfully" "$baseline" "$RECOMPILE_TIMEOUT"; then
      local recompile_end_ns
      recompile_end_ns=$(now_ns)
      local recompile_ms
      recompile_ms=$(ns_to_ms $(( recompile_end_ns - recompile_start_ns )))

      # Try to extract the compiler-reported time; fall back to wall-clock
      local reported_ms
      reported_ms=$(extract_watch_compile_time_ms "$watch_log" "$baseline")
      if [ -n "$reported_ms" ] && [ "$reported_ms" != "0" ]; then
        # Use reported time if available
        recompile_ms=$(printf "%.0f" "$reported_ms")
      fi

      store_result "$target_name" "watch_recompile_${i}_ms" "$recompile_ms"
      total_recompile_ms=$(( total_recompile_ms + recompile_ms ))
      successful_iterations=$(( successful_iterations + 1 ))

      # Extract stats
      local recompile_stats
      recompile_stats=$(extract_watch_stats "$watch_log" "$baseline")
      if [ -n "$recompile_stats" ]; then
        printf "  %-36s ${BOLD}%6d${RESET} ms  ${DIM}%s${RESET}\n" \
          "Recompilation #${i} (touched):" "$recompile_ms" "$recompile_stats"
      else
        printf "  %-36s ${BOLD}%6d${RESET} ms\n" \
          "Recompilation #${i} (touched):" "$recompile_ms"
      fi
    else
      warn "Recompilation #${i} timed out"
      store_result "$target_name" "watch_recompile_${i}_ms" "TIMEOUT"
      echo -e "  ${DIM}--- Watch log tail ---${RESET}"
      tail -20 "$watch_log" 2>/dev/null | while IFS= read -r line; do echo "    $line"; done
      echo -e "  ${DIM}--- end ---${RESET}"
    fi
  done

  # Calculate average
  if [ "$successful_iterations" -gt 0 ]; then
    local avg_ms=$(( total_recompile_ms / successful_iterations ))
    store_result "$target_name" "watch_avg_recompile_ms" "$avg_ms"
    printf "  %-36s ${GREEN}${BOLD}%6d${RESET} ms\n" "Average recompilation:" "$avg_ms"
  else
    store_result "$target_name" "watch_avg_recompile_ms" "N/A"
  fi

  echo ""

  # Stop the watch process
  stop_watch
}

# ==============================================================================
# Compare watch vs sequential and print results for a target
# ==============================================================================

print_target_comparison() {
  local target_name="$1"

  local seq_cold=$(get_result "$target_name" "seq_cold_ms" "N/A")
  local seq_noop=$(get_result "$target_name" "seq_warm_noop_ms" "N/A")
  local seq_touch=$(get_result "$target_name" "seq_warm_touch_ms" "N/A")
  local watch_init=$(get_result "$target_name" "watch_initial_ms" "N/A")
  local watch_avg=$(get_result "$target_name" "watch_avg_recompile_ms" "N/A")

  # Calculate advantage
  local advantage="N/A"
  if [ "$seq_touch" != "N/A" ] && [ "$seq_touch" != "FAIL" ] && \
     [ "$watch_avg" != "N/A" ] && [ "$watch_avg" != "FAIL" ] && \
     [ "$seq_touch" -gt 0 ] 2>/dev/null && [ "$watch_avg" -gt 0 ] 2>/dev/null; then
    advantage=$(awk "BEGIN { printf \"%.0f\", (1 - ($watch_avg / $seq_touch)) * 100 }")
  fi

  store_result "$target_name" "advantage_pct" "$advantage"
}

# ==============================================================================
# Full benchmark for a single target
# ==============================================================================

# Arguments:
#   $1 - target display name
#   $2 - working directory
#   $3 - source file (relative to work dir)
#   $4 - output binary (relative to work dir)
run_target_benchmark() {
  local target_name="$1"
  local work_dir="$2"
  local source_file="$3"
  local output_binary="$4"

  echo ""
  echo -e "${BOLD}${MAGENTA}--- Target: ${target_name} ---${RESET}"
  echo -e "${DIM}  Directory: ${work_dir}${RESET}"
  echo -e "${DIM}  Source:    ${source_file}${RESET}"
  echo ""

  # Verify the source file exists
  if [ ! -f "${work_dir}/${source_file}" ]; then
    error "Source file not found: ${work_dir}/${source_file}"
    store_result "$target_name" "status" "SKIPPED"
    return
  fi

  # Sequential builds
  benchmark_sequential "$target_name" "$work_dir" "$source_file" "$output_binary"

  # Watch mode
  benchmark_watch_mode "$target_name" "$work_dir" "$source_file"

  # Comparison
  print_target_comparison "$target_name"

  store_result "$target_name" "status" "OK"
}

# ==============================================================================
# Print the final report
# ==============================================================================

print_report() {
  local targets=("$@")
  local width=60

  echo ""
  echo -e "${BOLD}${BLUE}"
  echo "Watch Mode Benchmark Results"
  printf '%*s\n' "$width" '' | tr ' ' '='
  echo -e "${RESET}"

  for target_name in "${targets[@]}"; do
    local status=$(get_result "$target_name" "status" "UNKNOWN")
    if [ "$status" != "OK" ]; then
      echo -e "${BOLD}Target: ${target_name}${RESET}  (${YELLOW}${status}${RESET})"
      echo ""
      continue
    fi

    echo -e "${BOLD}Target: ${target_name}${RESET}"
    echo ""

    local seq_cold=$(get_result "$target_name" "seq_cold_ms")
    local seq_noop=$(get_result "$target_name" "seq_warm_noop_ms")
    local seq_touch=$(get_result "$target_name" "seq_warm_touch_ms")

    echo -e "${CYAN}Sequential builds:${RESET}"
    printf "  Cold build:                  %8s ms\n" "$seq_cold"
    printf "  Warm (no change):            %8s ms\n" "$seq_noop"
    printf "  Warm (file touched):         %8s ms\n" "$seq_touch"
    echo ""

    local watch_init=$(get_result "$target_name" "watch_initial_ms")
    echo -e "${CYAN}Watch mode:${RESET}"
    printf "  Initial compilation:         %8s ms\n" "$watch_init"

    local i
    for i in $(seq 1 "$ITERATIONS"); do
      local recomp=$(get_result "$target_name" "watch_recompile_${i}_ms" "N/A")
      printf "  Recompilation #%d (touched):  %8s ms\n" "$i" "$recomp"
    done

    local watch_avg=$(get_result "$target_name" "watch_avg_recompile_ms")
    printf "  Average recompilation:       ${GREEN}${BOLD}%8s${RESET} ms\n" "$watch_avg"
    echo ""

    local advantage=$(get_result "$target_name" "advantage_pct" "N/A")
    if [ "$advantage" != "N/A" ]; then
      if [ "$advantage" -gt 0 ] 2>/dev/null; then
        printf "  Watch mode advantage:        ${GREEN}${BOLD}%7s%% faster${RESET}\n" "$advantage"
      elif [ "$advantage" -lt 0 ] 2>/dev/null; then
        local abs_adv=$(( -1 * advantage ))
        printf "  Watch mode advantage:        ${RED}${BOLD}%7s%% slower${RESET}\n" "$abs_adv"
      else
        printf "  Watch mode advantage:        ${YELLOW}${BOLD}    ~0%% (same)${RESET}\n"
      fi
    else
      printf "  Watch mode advantage:        ${DIM}%8s${RESET}\n" "N/A"
    fi

    echo ""
    printf '%*s\n' "$width" '' | tr ' ' '-'
    echo ""
  done
}

# Save a plain-text copy of the report (no ANSI escapes).
save_report() {
  local targets=("$@")

  {
    echo "========================================================================"
    echo "   Crystal Watch Mode Benchmark Results"
    echo "========================================================================"
    echo " Compiler:  $CRYSTAL_VERSION"
    echo " Date:      $(date '+%Y-%m-%d %H:%M:%S')"
    echo " Machine:   $(uname -m) / $(sw_vers -productName 2>/dev/null || uname -s) $(sw_vers -productVersion 2>/dev/null || uname -r)"
    echo " Iterations: $ITERATIONS"
    echo "========================================================================"
    echo ""

    for target_name in "${targets[@]}"; do
      local status=$(get_result "$target_name" "status" "UNKNOWN")
      if [ "$status" != "OK" ]; then
        echo "Target: ${target_name}  (${status})"
        echo ""
        continue
      fi

      echo "Target: ${target_name}"
      echo ""

      local seq_cold=$(get_result "$target_name" "seq_cold_ms")
      local seq_noop=$(get_result "$target_name" "seq_warm_noop_ms")
      local seq_touch=$(get_result "$target_name" "seq_warm_touch_ms")

      echo "Sequential builds:"
      printf "  Cold build:                  %8s ms\n" "$seq_cold"
      printf "  Warm (no change):            %8s ms\n" "$seq_noop"
      printf "  Warm (file touched):         %8s ms\n" "$seq_touch"
      echo ""

      local watch_init=$(get_result "$target_name" "watch_initial_ms")
      echo "Watch mode:"
      printf "  Initial compilation:         %8s ms\n" "$watch_init"

      local i
      for i in $(seq 1 "$ITERATIONS"); do
        local recomp=$(get_result "$target_name" "watch_recompile_${i}_ms" "N/A")
        printf "  Recompilation #%d (touched):  %8s ms\n" "$i" "$recomp"
      done

      local watch_avg=$(get_result "$target_name" "watch_avg_recompile_ms")
      printf "  Average recompilation:       %8s ms\n" "$watch_avg"
      echo ""

      local advantage=$(get_result "$target_name" "advantage_pct" "N/A")
      if [ "$advantage" != "N/A" ]; then
        if [ "$advantage" -gt 0 ] 2>/dev/null; then
          printf "  Watch mode advantage:        %7s%% faster\n" "$advantage"
        elif [ "$advantage" -lt 0 ] 2>/dev/null; then
          local abs_adv=$(( -1 * advantage ))
          printf "  Watch mode advantage:        %7s%% slower\n" "$abs_adv"
        else
          printf "  Watch mode advantage:            ~0%% (same)\n"
        fi
      else
        printf "  Watch mode advantage:        %8s\n" "N/A"
      fi

      echo ""
      echo "------------------------------------------------------------------------"
      echo ""
    done

    echo "========================================================================"
  } > "$RESULTS_FILE"

  info "Results saved to: ${RESULTS_FILE}"
}

# ==============================================================================
# Main
# ==============================================================================

main() {
  echo ""
  echo -e "${BOLD}${BLUE}"
  echo "  Crystal Watch Mode Recompilation Benchmark"
  echo "  ==========================================="
  echo -e "${RESET}"

  check_prerequisites

  # Prepare output directory
  rm -rf "$OUTPUT_DIR"
  mkdir -p "$OUTPUT_DIR" "$RESULTS_STORE"

  local total_start
  total_start=$(now_ns)

  # Track which targets we actually ran
  local -a ran_targets=()

  # -- Target: kemal ---------------------------------------------------------
  if [ -z "$TARGET_FILTER" ] || [ "$TARGET_FILTER" = "kemal" ]; then
    local kemal_dir="${BENCH_DIR}/kemal"
    local kemal_src="src/app.cr"

    if [ -d "$kemal_dir" ] && [ -f "${kemal_dir}/${kemal_src}" ]; then
      run_target_benchmark "kemal" "$kemal_dir" "$kemal_src" "bin/app"
      ran_targets+=("kemal")
    else
      warn "Kemal project not found at ${kemal_dir}"
      warn "Run scripts/benchmark_frameworks.sh first to scaffold framework projects."
      store_result "kemal" "status" "SKIPPED"
      ran_targets+=("kemal")
    fi
  fi

  # -- Target: spider-gazelle ------------------------------------------------
  if [ -z "$TARGET_FILTER" ] || [ "$TARGET_FILTER" = "spider-gazelle" ]; then
    local sg_dir="${BENCH_DIR}/spider-gazelle"
    local sg_src="src/app.cr"

    if [ -d "$sg_dir" ] && [ -f "${sg_dir}/${sg_src}" ]; then
      run_target_benchmark "spider-gazelle" "$sg_dir" "$sg_src" "bin/app"
      ran_targets+=("spider-gazelle")
    else
      warn "Spider-Gazelle project not found at ${sg_dir}"
      warn "Run scripts/benchmark_frameworks.sh first to scaffold framework projects."
      store_result "spider-gazelle" "status" "SKIPPED"
      ran_targets+=("spider-gazelle")
    fi
  fi

  # -- Target: havlak --------------------------------------------------------
  if [ -z "$TARGET_FILTER" ] || [ "$TARGET_FILTER" = "havlak" ]; then
    # havlak.cr lives in the repo samples directory; no cd needed, but
    # we use REPO_ROOT as the working directory.
    run_target_benchmark "havlak" "$REPO_ROOT" "samples/havlak.cr" "/tmp/crystal-bench-watch/havlak"
    ran_targets+=("havlak")
  fi

  # -- Summary ----------------------------------------------------------------
  local total_end
  total_end=$(now_ns)
  local total_elapsed_ms=$(( (total_end - total_start) / 1000000 ))
  local total_elapsed_sec
  total_elapsed_sec=$(awk "BEGIN { printf \"%.1f\", $total_elapsed_ms / 1000 }")

  echo ""
  echo -e "${BOLD}Total benchmark time: ${total_elapsed_sec}s${RESET}"

  # Print and save the report
  print_report "${ran_targets[@]}"
  save_report "${ran_targets[@]}"

  echo ""
  info "Benchmark complete. $(date '+%Y-%m-%d %H:%M:%S')"
}

main
