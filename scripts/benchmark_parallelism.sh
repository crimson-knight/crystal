#!/bin/bash
set -e

# ==============================================================================
#  Crystal Incremental Compiler - Parallelism Benchmark
# ==============================================================================
#
#  Measures the impact of parallelism features in the Crystal incremental
#  compiler across three dimensions:
#
#    1. Thread count for codegen (--threads 1/2/4/8)
#    2. Parallel parsing (CRYSTAL_PARALLEL_PARSE=0 vs =1)
#    3. Combined effect (best parallel vs fully sequential)
#
#  Test targets (complex to simple):
#    - Kemal framework app
#    - Athena framework
#    - Spider-Gazelle framework
#    - Lucky framework
#    - havlak.cr (non-framework baseline)
#
#  Usage:
#    ./scripts/benchmark_parallelism.sh [OPTIONS]
#
#  Options:
#    --targets LIST   Comma-separated list of targets (default: all)
#    --runs N         Number of runs per configuration (default: 1)
#    --no-color       Disable colored output
#    --help           Show this help message
#
# ==============================================================================

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BENCH_DIR="/tmp/crystal-bench-frameworks"
RESULTS_DIR="/tmp/crystal-bench-parallelism"
RESULTS_FILE="${REPO_ROOT}/benchmark_parallelism_results.txt"

INCR_CRYSTAL="/opt/homebrew/bin/crystal-alpha"

# Parallelism dimensions
THREAD_COUNTS="1 2 4 8"
PARSE_MODES="0 1"  # 0=sequential, 1=parallel

# Options
TARGET_FILTER=""
NUM_RUNS=1
USE_COLOR=true

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --targets)
            TARGET_FILTER="$2"
            shift 2
            ;;
        --runs)
            NUM_RUNS="$2"
            shift 2
            ;;
        --no-color)
            USE_COLOR=false
            shift
            ;;
        --help|-h)
            echo "Usage: scripts/benchmark_parallelism.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --targets LIST   Comma-separated targets (kemal,athena,spider-gazelle,lucky,havlak)"
            echo "  --runs N         Number of runs per configuration (default: 1)"
            echo "  --no-color       Disable colored output"
            echo "  --help           Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Color codes
# ---------------------------------------------------------------------------

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

setup_colors

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# ---------------------------------------------------------------------------
# Timing (macOS-compatible nanosecond precision)
# ---------------------------------------------------------------------------

now_ns() {
    perl -MTime::HiRes=time -e 'printf "%.0f\n", time*1e9'
}

ns_to_ms() {
    echo $(( $1 / 1000000 ))
}

# ---------------------------------------------------------------------------
# Crystal cache directory management
# ---------------------------------------------------------------------------

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
    if [ -d "$cache_dir" ]; then
        rm -rf "$cache_dir"
    fi
    # Also remove per-project .crystal directories if a project dir is given
    if [ -n "${1:-}" ] && [ -d "${1}/.crystal" ]; then
        rm -rf "${1}/.crystal"
    fi
}

# ---------------------------------------------------------------------------
# Result storage (file-based, Bash 3.2 compatible)
# ---------------------------------------------------------------------------

store_result() {
    local key="$1" value="$2"
    mkdir -p "${RESULTS_DIR}/data"
    echo "${value}" > "${RESULTS_DIR}/data/${key}"
}

get_result() {
    local key="$1" default="${2:-N/A}"
    local file="${RESULTS_DIR}/data/${key}"
    if [ -f "${file}" ]; then
        cat "${file}"
    else
        echo "${default}"
    fi
}

# ---------------------------------------------------------------------------
# Stats extraction from compiler --stats output
# ---------------------------------------------------------------------------

extract_phase_times() {
    local stderr_text="$1"
    local phases=""

    # The --stats output looks like:
    #   Parse:                             0.12s
    #   Semantic (top level):              0.45s
    #   Codegen (crystal):                 1.23s
    #   Codegen (bc+obj):                  2.34s
    #   Codegen (linking):                 0.56s
    # Extract key phase times

    local parse_time semantic_time codegen_cr_time codegen_obj_time link_time
    parse_time=$(echo "$stderr_text" | grep -oE 'Parse:[ ]+[0-9]+\.[0-9]+s' | grep -oE '[0-9]+\.[0-9]+' || echo "")
    semantic_time=$(echo "$stderr_text" | grep -oE 'Semantic \(top level\):[ ]+[0-9]+\.[0-9]+s' | grep -oE '[0-9]+\.[0-9]+' || echo "")
    codegen_cr_time=$(echo "$stderr_text" | grep -oE 'Codegen \(crystal\):[ ]+[0-9]+\.[0-9]+s' | grep -oE '[0-9]+\.[0-9]+' || echo "")
    codegen_obj_time=$(echo "$stderr_text" | grep -oE 'Codegen \(bc\+obj\):[ ]+[0-9]+\.[0-9]+s' | grep -oE '[0-9]+\.[0-9]+' || echo "")
    link_time=$(echo "$stderr_text" | grep -oE 'Codegen \(linking\):[ ]+[0-9]+\.[0-9]+s' | grep -oE '[0-9]+\.[0-9]+' || echo "")

    if [ -n "$parse_time" ]; then
        phases="Parse=${parse_time}s"
    fi
    if [ -n "$codegen_obj_time" ]; then
        phases="${phases:+$phases, }Codegen(bc+obj)=${codegen_obj_time}s"
    fi
    if [ -n "$link_time" ]; then
        phases="${phases:+$phases, }Link=${link_time}s"
    fi

    echo "$phases"
}

# ---------------------------------------------------------------------------
# Target definitions
# ---------------------------------------------------------------------------

# Each target: name|entry_file|project_dir|needs_cd
# needs_cd: "yes" means cd into project_dir for shards resolution
ALL_TARGETS="kemal athena spider-gazelle lucky havlak"

entry_file_for() {
    case "$1" in
        kemal)          echo "src/app.cr" ;;
        athena)         echo "src/server.cr" ;;
        spider-gazelle) echo "src/app.cr" ;;
        lucky)          echo "src/app.cr" ;;
        havlak)         echo "samples/havlak.cr" ;;
    esac
}

project_dir_for() {
    case "$1" in
        kemal)          echo "${BENCH_DIR}/kemal" ;;
        athena)         echo "${BENCH_DIR}/athena" ;;
        spider-gazelle) echo "${BENCH_DIR}/spider-gazelle" ;;
        lucky)          echo "${BENCH_DIR}/lucky" ;;
        havlak)         echo "${REPO_ROOT}" ;;
    esac
}

is_framework() {
    case "$1" in
        havlak) return 1 ;;
        *)      return 0 ;;
    esac
}

# ---------------------------------------------------------------------------
# Build a single configuration and return the wall-clock time in ms
# ---------------------------------------------------------------------------

# Globals set by run_build:
#   BUILD_TIME_MS  - wall-clock time in milliseconds
#   BUILD_STDERR   - captured stderr (contains --stats output)
#   BUILD_EXIT     - exit code

run_build() {
    local target="$1"
    local threads="$2"
    local parse_mode="$3"  # 0 or 1

    local entry=$(entry_file_for "$target")
    local proj_dir=$(project_dir_for "$target")
    local output_file="${RESULTS_DIR}/bin/${target}_t${threads}_p${parse_mode}"
    local stderr_file="${RESULTS_DIR}/stderr_${target}_t${threads}_p${parse_mode}.log"

    mkdir -p "${RESULTS_DIR}/bin"
    mkdir -p "$(dirname "$stderr_file")"

    # Clean cache for cold build
    clean_crystal_cache "$proj_dir"
    rm -f "$output_file"

    local t_start t_end

    t_start=$(now_ns)
    set +e
    (
        cd "$proj_dir"
        CRYSTAL_PARALLEL_PARSE="$parse_mode" \
        "$INCR_CRYSTAL" build "$entry" \
            -o "$output_file" \
            --incremental \
            --stats \
            --threads "$threads" \
            2>"$stderr_file" \
            >/dev/null
    )
    BUILD_EXIT=$?
    set -e
    t_end=$(now_ns)

    BUILD_TIME_MS=$(ns_to_ms $(( t_end - t_start )))
    BUILD_STDERR=""
    if [ -f "$stderr_file" ]; then
        BUILD_STDERR=$(cat "$stderr_file")
    fi
}

# ---------------------------------------------------------------------------
# Run N iterations and return the best (minimum) time
# ---------------------------------------------------------------------------

run_build_best_of() {
    local target="$1"
    local threads="$2"
    local parse_mode="$3"
    local runs="$4"
    local best_ms=999999999
    local best_stderr=""
    local best_exit=0
    local i

    for (( i=1; i<=runs; i++ )); do
        run_build "$target" "$threads" "$parse_mode"
        if [ "$BUILD_TIME_MS" -lt "$best_ms" ]; then
            best_ms="$BUILD_TIME_MS"
            best_stderr="$BUILD_STDERR"
            best_exit="$BUILD_EXIT"
        fi
    done

    BUILD_TIME_MS="$best_ms"
    BUILD_STDERR="$best_stderr"
    BUILD_EXIT="$best_exit"
}

# ---------------------------------------------------------------------------
# Check if framework projects exist
# ---------------------------------------------------------------------------

check_framework_exists() {
    local target="$1"
    local proj_dir=$(project_dir_for "$target")
    local entry=$(entry_file_for "$target")

    if [ ! -f "${proj_dir}/${entry}" ]; then
        return 1
    fi

    # For framework targets, check that shards have been installed
    if is_framework "$target"; then
        if [ ! -d "${proj_dir}/lib" ]; then
            return 1
        fi
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

echo ""
echo -e "${BOLD}${BLUE}================================================================${RESET}"
echo -e "${BOLD}${BLUE}   Crystal Incremental Compiler - Parallelism Benchmark${RESET}"
echo -e "${BOLD}${BLUE}================================================================${RESET}"
echo ""

if [ ! -x "$INCR_CRYSTAL" ]; then
    error "Incremental compiler not found at: $INCR_CRYSTAL"
    exit 1
fi

INCR_VERSION=$("$INCR_CRYSTAL" --version 2>&1 | head -1)
info "Compiler:        $INCR_CRYSTAL"
info "Version:         $INCR_VERSION"
info "Repo root:       $REPO_ROOT"
info "Framework dir:   $BENCH_DIR"
info "Results dir:     $RESULTS_DIR"
info "Runs per config: $NUM_RUNS"
info "Thread counts:   $THREAD_COUNTS"
info "Date:            $(date '+%Y-%m-%d %H:%M:%S')"
info "Machine:         $(uname -m) / $(sw_vers -productName 2>/dev/null || uname -s) $(sw_vers -productVersion 2>/dev/null || uname -r)"

# CPU info for context
NCPUS=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo "?")
info "CPU cores:       $NCPUS"
echo ""

# Clean results directory
rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR/data" "$RESULTS_DIR/bin"

# Determine which targets to run
TARGETS=""
if [ -n "$TARGET_FILTER" ]; then
    # Replace commas with spaces
    TARGETS=$(echo "$TARGET_FILTER" | tr ',' ' ')
else
    TARGETS="$ALL_TARGETS"
fi

# Validate targets
VALID_TARGETS=""
for target in $TARGETS; do
    if check_framework_exists "$target"; then
        VALID_TARGETS="${VALID_TARGETS:+$VALID_TARGETS }$target"
        success "Target available: $target"
    else
        proj_dir=$(project_dir_for "$target")
        entry=$(entry_file_for "$target")
        warn "Target SKIPPED: $target (missing ${proj_dir}/${entry} or lib/)"
        warn "  Run scripts/benchmark_frameworks.sh first to scaffold framework projects"
    fi
done

if [ -z "$VALID_TARGETS" ]; then
    error "No valid targets found. Ensure framework projects exist at $BENCH_DIR"
    error "Run scripts/benchmark_frameworks.sh first, or use --targets havlak for baseline only."
    exit 1
fi

echo ""
info "Running benchmarks for: $VALID_TARGETS"
echo ""

# ===========================================================================
# DIMENSION 1: Thread count for codegen
# ===========================================================================

echo -e "${BOLD}${MAGENTA}================================================================${RESET}"
echo -e "${BOLD}${MAGENTA}  Dimension 1: Thread Count for Codegen${RESET}"
echo -e "${BOLD}${MAGENTA}  (CRYSTAL_PARALLEL_PARSE=1, --threads varies)${RESET}"
echo -e "${BOLD}${MAGENTA}================================================================${RESET}"
echo ""

for target in $VALID_TARGETS; do
    echo -e "  ${BOLD}${CYAN}Target: ${target}${RESET}"
    echo -e "  ${DIM}$(printf '%0.s─' {1..56})${RESET}"

    for threads in $THREAD_COUNTS; do
        run_build_best_of "$target" "$threads" "1" "$NUM_RUNS"

        local_key="dim1_${target}_t${threads}"
        store_result "$local_key" "$BUILD_TIME_MS"

        phase_info=$(extract_phase_times "$BUILD_STDERR")

        if [ "$BUILD_EXIT" -ne 0 ]; then
            echo -e "    Threads=${BOLD}${threads}${RESET}:  ${RED}FAILED${RESET} (exit code $BUILD_EXIT)"
        else
            # Highlight the default (4 threads)
            suffix=""
            if [ "$threads" = "4" ]; then
                suffix=" ${DIM}(default)${RESET}"
            fi
            printf "    Threads=${BOLD}%-2s${RESET}: %7d ms${suffix}" "$threads" "$BUILD_TIME_MS"
            if [ -n "$phase_info" ]; then
                echo -e "  ${DIM}[${phase_info}]${RESET}"
            else
                echo ""
            fi
        fi
    done

    # Calculate speedup from 1 to 4 threads
    t1_ms=$(get_result "dim1_${target}_t1" "0")
    t4_ms=$(get_result "dim1_${target}_t4" "0")
    if [ "$t1_ms" != "0" ] && [ "$t1_ms" != "N/A" ] && [ "$t4_ms" != "0" ] && [ "$t4_ms" != "N/A" ]; then
        speedup=$(awk "BEGIN { printf \"%.2f\", $t1_ms / $t4_ms }")
        echo -e "    ${GREEN}Speedup (1->4 threads): ${BOLD}${speedup}x${RESET}"
    fi

    # Also 1 to 8
    t8_ms=$(get_result "dim1_${target}_t8" "0")
    if [ "$t1_ms" != "0" ] && [ "$t1_ms" != "N/A" ] && [ "$t8_ms" != "0" ] && [ "$t8_ms" != "N/A" ]; then
        speedup_8=$(awk "BEGIN { printf \"%.2f\", $t1_ms / $t8_ms }")
        echo -e "    ${GREEN}Speedup (1->8 threads): ${BOLD}${speedup_8}x${RESET}"
    fi
    echo ""
done

# ===========================================================================
# DIMENSION 2: Parallel parsing
# ===========================================================================

echo -e "${BOLD}${MAGENTA}================================================================${RESET}"
echo -e "${BOLD}${MAGENTA}  Dimension 2: Parallel Parsing${RESET}"
echo -e "${BOLD}${MAGENTA}  (--threads 4, CRYSTAL_PARALLEL_PARSE varies)${RESET}"
echo -e "${BOLD}${MAGENTA}================================================================${RESET}"
echo ""

for target in $VALID_TARGETS; do
    echo -e "  ${BOLD}${CYAN}Target: ${target}${RESET}"
    echo -e "  ${DIM}$(printf '%0.s─' {1..56})${RESET}"

    for parse_mode in $PARSE_MODES; do
        run_build_best_of "$target" "4" "$parse_mode" "$NUM_RUNS"

        local_key="dim2_${target}_p${parse_mode}"
        store_result "$local_key" "$BUILD_TIME_MS"

        phase_info=$(extract_phase_times "$BUILD_STDERR")

        if [ "$parse_mode" = "0" ]; then
            label="SEQ"
        else
            label="PAR"
        fi

        if [ "$BUILD_EXIT" -ne 0 ]; then
            echo -e "    Parse=${BOLD}${label}${RESET}:  ${RED}FAILED${RESET} (exit code $BUILD_EXIT)"
        else
            printf "    Parse=${BOLD}%-3s${RESET}: %7d ms" "$label" "$BUILD_TIME_MS"
            if [ -n "$phase_info" ]; then
                echo -e "  ${DIM}[${phase_info}]${RESET}"
            else
                echo ""
            fi
        fi
    done

    # Calculate parse speedup
    seq_ms=$(get_result "dim2_${target}_p0" "0")
    par_ms=$(get_result "dim2_${target}_p1" "0")
    if [ "$seq_ms" != "0" ] && [ "$seq_ms" != "N/A" ] && [ "$par_ms" != "0" ] && [ "$par_ms" != "N/A" ]; then
        parse_speedup=$(awk "BEGIN { printf \"%.2f\", $seq_ms / $par_ms }")
        parse_diff=$(( seq_ms - par_ms ))
        echo -e "    ${GREEN}Parse speedup: ${BOLD}${parse_speedup}x${RESET} ${DIM}(${parse_diff} ms saved)${RESET}"
    fi
    echo ""
done

# ===========================================================================
# DIMENSION 3: Combined effect (best parallel vs fully sequential)
# ===========================================================================

echo -e "${BOLD}${MAGENTA}================================================================${RESET}"
echo -e "${BOLD}${MAGENTA}  Dimension 3: Combined Effect${RESET}"
echo -e "${BOLD}${MAGENTA}  (Full sequential vs best parallel)${RESET}"
echo -e "${BOLD}${MAGENTA}================================================================${RESET}"
echo ""

for target in $VALID_TARGETS; do
    echo -e "  ${BOLD}${CYAN}Target: ${target}${RESET}"
    echo -e "  ${DIM}$(printf '%0.s─' {1..56})${RESET}"

    # Fully sequential: threads=1, parse=SEQ
    run_build_best_of "$target" "1" "0" "$NUM_RUNS"
    seq_all_ms="$BUILD_TIME_MS"
    seq_all_exit="$BUILD_EXIT"
    seq_phases=$(extract_phase_times "$BUILD_STDERR")
    store_result "dim3_${target}_seq" "$seq_all_ms"

    if [ "$seq_all_exit" -ne 0 ]; then
        echo -e "    Threads=1, Parse=SEQ:  ${RED}FAILED${RESET}"
    else
        printf "    Threads=1, Parse=SEQ:  %7d ms" "$seq_all_ms"
        if [ -n "$seq_phases" ]; then
            echo -e "  ${DIM}[${seq_phases}]${RESET}"
        else
            echo ""
        fi
    fi

    # Also run the intermediate combos for a complete picture
    # threads=1, parse=PAR
    run_build_best_of "$target" "1" "1" "$NUM_RUNS"
    t1_par_ms="$BUILD_TIME_MS"
    t1_par_exit="$BUILD_EXIT"
    store_result "dim3_${target}_t1_par" "$t1_par_ms"

    if [ "$t1_par_exit" -ne 0 ]; then
        echo -e "    Threads=1, Parse=PAR:  ${RED}FAILED${RESET}"
    else
        printf "    Threads=1, Parse=PAR:  %7d ms\n" "$t1_par_ms"
    fi

    # threads=2, parse=PAR
    run_build_best_of "$target" "2" "1" "$NUM_RUNS"
    t2_par_ms="$BUILD_TIME_MS"
    t2_par_exit="$BUILD_EXIT"
    store_result "dim3_${target}_t2_par" "$t2_par_ms"

    if [ "$t2_par_exit" -ne 0 ]; then
        echo -e "    Threads=2, Parse=PAR:  ${RED}FAILED${RESET}"
    else
        printf "    Threads=2, Parse=PAR:  %7d ms\n" "$t2_par_ms"
    fi

    # threads=4, parse=PAR (default)
    run_build_best_of "$target" "4" "1" "$NUM_RUNS"
    t4_par_ms="$BUILD_TIME_MS"
    t4_par_exit="$BUILD_EXIT"
    store_result "dim3_${target}_t4_par" "$t4_par_ms"

    if [ "$t4_par_exit" -ne 0 ]; then
        echo -e "    Threads=4, Parse=PAR:  ${RED}FAILED${RESET} ${DIM}(default)${RESET}"
    else
        printf "    Threads=4, Parse=PAR:  %7d ms  ${DIM}(default)${RESET}\n" "$t4_par_ms"
    fi

    # threads=8, parse=PAR (max)
    run_build_best_of "$target" "8" "1" "$NUM_RUNS"
    t8_par_ms="$BUILD_TIME_MS"
    t8_par_exit="$BUILD_EXIT"
    t8_phases=$(extract_phase_times "$BUILD_STDERR")
    store_result "dim3_${target}_t8_par" "$t8_par_ms"

    if [ "$t8_par_exit" -ne 0 ]; then
        echo -e "    Threads=8, Parse=PAR:  ${RED}FAILED${RESET}"
    else
        printf "    Threads=8, Parse=PAR:  %7d ms" "$t8_par_ms"
        if [ -n "$t8_phases" ]; then
            echo -e "  ${DIM}[${t8_phases}]${RESET}"
        else
            echo ""
        fi
    fi

    # Overall speedup
    if [ "$seq_all_exit" -eq 0 ] && [ "$t4_par_exit" -eq 0 ] && \
       [ "$seq_all_ms" -gt 0 ] && [ "$t4_par_ms" -gt 0 ]; then
        combined_speedup=$(awk "BEGIN { printf \"%.2f\", $seq_all_ms / $t4_par_ms }")
        combined_diff=$(( seq_all_ms - t4_par_ms ))
        echo -e "    ${GREEN}Combined speedup (seq->4T+PAR): ${BOLD}${combined_speedup}x${RESET} ${DIM}(${combined_diff} ms saved)${RESET}"
    fi

    if [ "$seq_all_exit" -eq 0 ] && [ "$t8_par_exit" -eq 0 ] && \
       [ "$seq_all_ms" -gt 0 ] && [ "$t8_par_ms" -gt 0 ]; then
        combined_speedup_8=$(awk "BEGIN { printf \"%.2f\", $seq_all_ms / $t8_par_ms }")
        echo -e "    ${GREEN}Combined speedup (seq->8T+PAR): ${BOLD}${combined_speedup_8}x${RESET}"
    fi
    echo ""
done

# ===========================================================================
# Summary table
# ===========================================================================

echo ""
echo -e "${BOLD}${BLUE}================================================================${RESET}"
echo -e "${BOLD}${BLUE}   Summary: Parallelism Benchmark Results${RESET}"
echo -e "${BOLD}${BLUE}================================================================${RESET}"
echo ""
echo -e "${DIM}  Compiler: $INCR_VERSION${RESET}"
echo -e "${DIM}  Date:     $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
echo -e "${DIM}  Machine:  $(uname -m), $NCPUS cores${RESET}"
echo -e "${DIM}  Runs/cfg: $NUM_RUNS (best of N)${RESET}"
echo ""

# Print the summary table header
printf "${BOLD}  %-18s %8s %8s %8s %8s %8s %8s %8s${RESET}\n" \
    "Target" "T=1,SEQ" "T=1,PAR" "T=2,PAR" "T=4,PAR" "T=8,PAR" "1->4x" "1->8x"
echo -e "  $(printf '%0.s─' {1..80})"

for target in $VALID_TARGETS; do
    # Gather times
    seq_ms=$(get_result "dim3_${target}_seq" "-")
    t1p_ms=$(get_result "dim3_${target}_t1_par" "-")
    t2p_ms=$(get_result "dim3_${target}_t2_par" "-")
    t4p_ms=$(get_result "dim3_${target}_t4_par" "-")
    t8p_ms=$(get_result "dim3_${target}_t8_par" "-")

    # Speedups
    speedup_4="-"
    speedup_8="-"
    if [ "$seq_ms" != "-" ] && [ "$seq_ms" != "N/A" ] && [ "$seq_ms" -gt 0 ] 2>/dev/null; then
        if [ "$t4p_ms" != "-" ] && [ "$t4p_ms" != "N/A" ] && [ "$t4p_ms" -gt 0 ] 2>/dev/null; then
            speedup_4=$(awk "BEGIN { printf \"%.2fx\", $seq_ms / $t4p_ms }")
        fi
        if [ "$t8p_ms" != "-" ] && [ "$t8p_ms" != "N/A" ] && [ "$t8p_ms" -gt 0 ] 2>/dev/null; then
            speedup_8=$(awk "BEGIN { printf \"%.2fx\", $seq_ms / $t8p_ms }")
        fi
    fi

    # Format times with ms suffix
    fmt_seq="${seq_ms}ms"
    fmt_t1p="${t1p_ms}ms"
    fmt_t2p="${t2p_ms}ms"
    fmt_t4p="${t4p_ms}ms"
    fmt_t8p="${t8p_ms}ms"

    [ "$seq_ms" = "-" ] || [ "$seq_ms" = "N/A" ] && fmt_seq="-"
    [ "$t1p_ms" = "-" ] || [ "$t1p_ms" = "N/A" ] && fmt_t1p="-"
    [ "$t2p_ms" = "-" ] || [ "$t2p_ms" = "N/A" ] && fmt_t2p="-"
    [ "$t4p_ms" = "-" ] || [ "$t4p_ms" = "N/A" ] && fmt_t4p="-"
    [ "$t8p_ms" = "-" ] || [ "$t8p_ms" = "N/A" ] && fmt_t8p="-"

    printf "  %-18s %8s %8s %8s %8s %8s %8s %8s\n" \
        "$target" "$fmt_seq" "$fmt_t1p" "$fmt_t2p" "$fmt_t4p" "$fmt_t8p" "$speedup_4" "$speedup_8"
done

echo -e "  $(printf '%0.s─' {1..80})"
echo ""

# Per-target detailed output
echo -e "${BOLD}  Per-Target Breakdown:${RESET}"
echo ""

for target in $VALID_TARGETS; do
    echo -e "  ${BOLD}${CYAN}Target: ${target}${RESET}"

    seq_ms=$(get_result "dim3_${target}_seq" "-")
    t1p_ms=$(get_result "dim3_${target}_t1_par" "-")
    t2p_ms=$(get_result "dim3_${target}_t2_par" "-")
    t4p_ms=$(get_result "dim3_${target}_t4_par" "-")
    t8p_ms=$(get_result "dim3_${target}_t8_par" "-")

    printf "    Threads=1, Parse=SEQ:    %7sms\n" "$seq_ms"
    printf "    Threads=1, Parse=PAR:    %7sms\n" "$t1p_ms"
    printf "    Threads=2, Parse=PAR:    %7sms\n" "$t2p_ms"
    printf "    Threads=4, Parse=PAR:    %7sms  ${DIM}(default)${RESET}\n" "$t4p_ms"
    printf "    Threads=8, Parse=PAR:    %7sms\n" "$t8p_ms"

    if [ "$seq_ms" != "-" ] && [ "$seq_ms" != "N/A" ] && [ "$seq_ms" -gt 0 ] 2>/dev/null; then
        if [ "$t4p_ms" != "-" ] && [ "$t4p_ms" != "N/A" ] && [ "$t4p_ms" -gt 0 ] 2>/dev/null; then
            speedup=$(awk "BEGIN { printf \"%.2f\", $seq_ms / $t4p_ms }")
            echo -e "    ${GREEN}Speedup (1T,SEQ -> 4T,PAR): ${BOLD}${speedup}x${RESET}"
        fi
    fi

    # Parse-only effect (same threads, different parse mode)
    if [ "$seq_ms" != "-" ] && [ "$seq_ms" != "N/A" ] && [ "$seq_ms" -gt 0 ] 2>/dev/null && \
       [ "$t1p_ms" != "-" ] && [ "$t1p_ms" != "N/A" ] && [ "$t1p_ms" -gt 0 ] 2>/dev/null; then
        parse_effect=$(awk "BEGIN { printf \"%.2f\", $seq_ms / $t1p_ms }")
        echo -e "    ${DIM}Parse-only effect (T=1):    ${parse_effect}x${RESET}"
    fi

    # Thread-only effect (same parse mode, different threads)
    dim1_t1=$(get_result "dim1_${target}_t1" "-")
    dim1_t4=$(get_result "dim1_${target}_t4" "-")
    if [ "$dim1_t1" != "-" ] && [ "$dim1_t1" != "N/A" ] && [ "$dim1_t1" -gt 0 ] 2>/dev/null && \
       [ "$dim1_t4" != "-" ] && [ "$dim1_t4" != "N/A" ] && [ "$dim1_t4" -gt 0 ] 2>/dev/null; then
        thread_effect=$(awk "BEGIN { printf \"%.2f\", $dim1_t1 / $dim1_t4 }")
        echo -e "    ${DIM}Thread-only effect (PAR):   ${thread_effect}x${RESET}"
    fi
    echo ""
done

# ===========================================================================
# Save plain-text results
# ===========================================================================

{
    echo "=================================================================="
    echo "   Crystal Incremental Compiler - Parallelism Benchmark Results"
    echo "=================================================================="
    echo ""
    echo "  Compiler:     $INCR_VERSION"
    echo "  Date:         $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Machine:      $(uname -m), $NCPUS cores"
    echo "  Runs/config:  $NUM_RUNS (best of N)"
    echo ""
    echo "=================================================================="
    echo ""
    printf "  %-18s %8s %8s %8s %8s %8s %8s %8s\n" \
        "Target" "T=1,SEQ" "T=1,PAR" "T=2,PAR" "T=4,PAR" "T=8,PAR" "1->4x" "1->8x"
    printf '  %s\n' "$(printf '%*s' 80 '' | tr ' ' '-')"

    for target in $VALID_TARGETS; do
        seq_ms=$(get_result "dim3_${target}_seq" "-")
        t1p_ms=$(get_result "dim3_${target}_t1_par" "-")
        t2p_ms=$(get_result "dim3_${target}_t2_par" "-")
        t4p_ms=$(get_result "dim3_${target}_t4_par" "-")
        t8p_ms=$(get_result "dim3_${target}_t8_par" "-")

        speedup_4="-"
        speedup_8="-"
        if [ "$seq_ms" != "-" ] && [ "$seq_ms" != "N/A" ] && [ "$seq_ms" -gt 0 ] 2>/dev/null; then
            if [ "$t4p_ms" != "-" ] && [ "$t4p_ms" != "N/A" ] && [ "$t4p_ms" -gt 0 ] 2>/dev/null; then
                speedup_4=$(awk "BEGIN { printf \"%.2fx\", $seq_ms / $t4p_ms }")
            fi
            if [ "$t8p_ms" != "-" ] && [ "$t8p_ms" != "N/A" ] && [ "$t8p_ms" -gt 0 ] 2>/dev/null; then
                speedup_8=$(awk "BEGIN { printf \"%.2fx\", $seq_ms / $t8p_ms }")
            fi
        fi

        fmt_seq="${seq_ms}ms"; [ "$seq_ms" = "-" ] || [ "$seq_ms" = "N/A" ] && fmt_seq="-"
        fmt_t1p="${t1p_ms}ms"; [ "$t1p_ms" = "-" ] || [ "$t1p_ms" = "N/A" ] && fmt_t1p="-"
        fmt_t2p="${t2p_ms}ms"; [ "$t2p_ms" = "-" ] || [ "$t2p_ms" = "N/A" ] && fmt_t2p="-"
        fmt_t4p="${t4p_ms}ms"; [ "$t4p_ms" = "-" ] || [ "$t4p_ms" = "N/A" ] && fmt_t4p="-"
        fmt_t8p="${t8p_ms}ms"; [ "$t8p_ms" = "-" ] || [ "$t8p_ms" = "N/A" ] && fmt_t8p="-"

        printf "  %-18s %8s %8s %8s %8s %8s %8s %8s\n" \
            "$target" "$fmt_seq" "$fmt_t1p" "$fmt_t2p" "$fmt_t4p" "$fmt_t8p" "$speedup_4" "$speedup_8"
    done

    echo ""
    printf '  %s\n' "$(printf '%*s' 80 '' | tr ' ' '-')"
    echo ""

    for target in $VALID_TARGETS; do
        echo "  Target: $target"
        seq_ms=$(get_result "dim3_${target}_seq" "-")
        t1p_ms=$(get_result "dim3_${target}_t1_par" "-")
        t2p_ms=$(get_result "dim3_${target}_t2_par" "-")
        t4p_ms=$(get_result "dim3_${target}_t4_par" "-")
        t8p_ms=$(get_result "dim3_${target}_t8_par" "-")
        printf "    Threads=1, Parse=SEQ:    %7sms\n" "$seq_ms"
        printf "    Threads=1, Parse=PAR:    %7sms\n" "$t1p_ms"
        printf "    Threads=2, Parse=PAR:    %7sms\n" "$t2p_ms"
        printf "    Threads=4, Parse=PAR:    %7sms  (default)\n" "$t4p_ms"
        printf "    Threads=8, Parse=PAR:    %7sms\n" "$t8p_ms"

        if [ "$seq_ms" != "-" ] && [ "$seq_ms" != "N/A" ] && [ "$seq_ms" -gt 0 ] 2>/dev/null && \
           [ "$t4p_ms" != "-" ] && [ "$t4p_ms" != "N/A" ] && [ "$t4p_ms" -gt 0 ] 2>/dev/null; then
            speedup=$(awk "BEGIN { printf \"%.2f\", $seq_ms / $t4p_ms }")
            echo "    Speedup (1T,SEQ -> 4T,PAR): ${speedup}x"
        fi
        echo ""
    done

    echo "=================================================================="
} > "$RESULTS_FILE"

echo ""
echo -e "${BOLD}${GREEN}================================================================${RESET}"
echo -e "${BOLD}${GREEN}  Benchmark complete!${RESET}"
echo -e "${BOLD}${GREEN}================================================================${RESET}"
echo ""
info "Results saved to: $RESULTS_FILE"
info "Raw data in:      $RESULTS_DIR/data/"
info "Stderr logs in:   $RESULTS_DIR/"
info "Finished at:      $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
