#!/bin/bash
set -e

# ==============================================================================
#  Crystal Web Framework Compilation Benchmark
# ==============================================================================
#
#  Scaffolds minimal Crystal web framework apps, compiles them with both the
#  stock Crystal compiler and the incremental compiler (crystal-alpha), then
#  verifies each binary serves JSON correctly.
#
#  Frameworks tested:
#    - Kemal         (kemalcr/kemal ~> 1.5)
#    - Athena        (athena-framework/framework ~> 0.21.0)
#    - Spider-Gazelle (spider-gazelle/action-controller ~> 7.0)
#    - Lucky         (luckyframework/lucky ~> 1.4.0)
#
#  Usage:
#    ./scripts/benchmark_frameworks.sh
#
# ==============================================================================

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BENCH_DIR="/tmp/crystal-bench-frameworks"
RESULTS_DIR="${BENCH_DIR}/.results"
RESULTS_FILE="${REPO_ROOT}/benchmark_frameworks_results.txt"

DEFAULT_PORT=3000
LUCKY_PORT=5000

STOCK_CRYSTAL="$(command -v crystal 2>/dev/null || true)"
INCREMENTAL_CRYSTAL="$(command -v crystal-alpha 2>/dev/null || true)"
if [ -z "${INCREMENTAL_CRYSTAL}" ]; then
    if [ -x "${REPO_ROOT}/.build/crystal" ]; then
        INCREMENTAL_CRYSTAL="${REPO_ROOT}/.build/crystal"
    fi
fi

FRAMEWORKS="kemal athena spider-gazelle lucky amber-v1 amber-v2"

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

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
# File size helper (macOS)
# ---------------------------------------------------------------------------

file_size_bytes() {
    stat -f%z "$1" 2>/dev/null || echo 0
}

format_size_mb() {
    awk "BEGIN { printf \"%.1f MB\", $1 / 1048576 }"
}

# ---------------------------------------------------------------------------
# Result storage (file-based, Bash 3.2 compatible)
# ---------------------------------------------------------------------------

store_result() {
    # Usage: store_result <framework> <key> <value>
    local fw="$1" key="$2" value="$3"
    mkdir -p "${RESULTS_DIR}/${fw}"
    echo "${value}" > "${RESULTS_DIR}/${fw}/${key}"
}

get_result() {
    # Usage: get_result <framework> <key> [default]
    local fw="$1" key="$2" default="${3:-N/A}"
    local file="${RESULTS_DIR}/${fw}/${key}"
    if [ -f "${file}" ]; then
        cat "${file}"
    else
        echo "${default}"
    fi
}

# ---------------------------------------------------------------------------
# Port management
# ---------------------------------------------------------------------------

kill_port() {
    local port="$1"
    local pid
    pid=$(lsof -ti :"${port}" 2>/dev/null || true)
    if [ -n "${pid}" ]; then
        kill -9 ${pid} 2>/dev/null || true
        sleep 0.5
    fi
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

echo ""
echo -e "${BOLD}============================================================${RESET}"
echo -e "${BOLD}  Crystal Web Framework Compilation Benchmark${RESET}"
echo -e "${BOLD}============================================================${RESET}"
echo ""

info "Repository root: ${REPO_ROOT}"
info "Benchmark dir:   ${BENCH_DIR}"
info "Results file:    ${RESULTS_FILE}"
echo ""

if [ -z "${STOCK_CRYSTAL}" ]; then
    error "Stock Crystal compiler not found in PATH."
    exit 1
fi
STOCK_VERSION="$(${STOCK_CRYSTAL} --version 2>&1 | head -1)"
info "Stock Crystal:       ${STOCK_CRYSTAL}"
info "  Version:           ${STOCK_VERSION}"

if [ -z "${INCREMENTAL_CRYSTAL}" ]; then
    error "Incremental Crystal compiler (crystal-alpha or .build/crystal) not found."
    exit 1
fi
INCR_VERSION="$(${INCREMENTAL_CRYSTAL} --version 2>&1 | head -1)"
info "Incremental Crystal: ${INCREMENTAL_CRYSTAL}"
info "  Version:           ${INCR_VERSION}"
echo ""

# ---------------------------------------------------------------------------
# Clean up previous run
# ---------------------------------------------------------------------------

info "Cleaning previous benchmark directory..."
rm -rf "${BENCH_DIR}"
mkdir -p "${BENCH_DIR}" "${RESULTS_DIR}"

# ===========================================================================
# Scaffold functions
# ===========================================================================

scaffold_kemal() {
    local dir="${BENCH_DIR}/kemal"
    mkdir -p "${dir}/src"

    cat > "${dir}/shard.yml" <<'SHARD'
name: bench-kemal
version: 0.1.0

dependencies:
  kemal:
    github: kemalcr/kemal
    version: ~> 1.5

crystal: ">= 1.0.0, < 2.0"
SHARD

    cat > "${dir}/src/app.cr" <<'SRC'
require "kemal"

get "/health" do |env|
  env.response.content_type = "application/json"
  {"status" => "ok"}.to_json
end

Kemal.config.host_binding = "127.0.0.1"
Kemal.config.port = 3000
Kemal.run
SRC
}

scaffold_amber_v1() {
    local dir="${BENCH_DIR}/amber-v1"
    mkdir -p "${dir}/src/controllers" "${dir}/config/environments"

    cat > "${dir}/shard.yml" <<'SHARD'
name: bench-amber-v1
version: 0.1.0

dependencies:
  amber:
    github: amberframework/amber
    version: ~> 1.4.1

crystal: ">= 1.0.0, < 2.0"
SHARD

    cat > "${dir}/config/environments/development.yml" <<'YML'
name: bench-amber-v1
port: 3000
host: 127.0.0.1
secret_key_base: benchmark-test-key-not-for-production
session:
  key: bench.session
  store: signed_cookie
  expires: 0
YML

    cat > "${dir}/src/controllers/health_controller.cr" <<'SRC'
class HealthController < Amber::Controller::Base
  def index
    respond_with do
      json({"status" => "ok"}.to_json)
    end
  end
end
SRC

    cat > "${dir}/src/app.cr" <<'SRC'
require "amber"
require "./controllers/health_controller"

Amber::Server.configure do
  pipeline :api do
    plug Amber::Pipe::Logger.new
  end
  routes :api do
    get "/health", HealthController, :index
  end
end

Amber::Server.start
SRC
}

scaffold_amber_v2() {
    local dir="${BENCH_DIR}/amber-v2"
    mkdir -p "${dir}/src/controllers" "${dir}/config/environments"

    cat > "${dir}/shard.yml" <<'SHARD'
name: bench-amber-v2
version: 0.1.0

dependencies:
  amber:
    github: crimson-knight/amber
    branch: master

crystal: ">= 1.0.0, < 2.0"
SHARD

    cat > "${dir}/config/environments/development.yml" <<'YML'
name: bench-amber-v2
port: 3000
host: 127.0.0.1
secret_key_base: benchmark-test-key-not-for-production
session:
  key: bench.session
  store: signed_cookie
  expires: 0
YML

    cat > "${dir}/src/controllers/health_controller.cr" <<'SRC'
class HealthController < Amber::Controller::Base
  def index
    respond_with do
      json({"status" => "ok"}.to_json)
    end
  end
end
SRC

    cat > "${dir}/src/app.cr" <<'SRC'
require "amber"
require "./controllers/health_controller"

Amber::Server.configure do
  pipeline :api do
    plug Amber::Pipe::Logger.new
  end
  routes :api do
    get "/health", HealthController, :index
  end
end

Amber::Server.start
SRC
}

scaffold_athena() {
    local dir="${BENCH_DIR}/athena"
    mkdir -p "${dir}/src/controllers"

    cat > "${dir}/shard.yml" <<'SHARD'
name: bench-athena
version: 0.1.0

dependencies:
  athena:
    github: athena-framework/framework
    version: ~> 0.21.0

crystal: ">= 1.14.0"
SHARD

    cat > "${dir}/src/controllers/health_controller.cr" <<'SRC'
class HealthController < ATH::Controller
  @[ARTA::Get("/health")]
  def health : ATH::Response
    ATH::Response.new(
      {"status": "ok"}.to_json,
      headers: HTTP::Headers{"content-type" => "application/json"}
    )
  end
end
SRC

    cat > "${dir}/src/main.cr" <<'SRC'
require "athena"
require "./controllers/*"
SRC

    cat > "${dir}/src/server.cr" <<'SRC'
require "./main"
ATH.run
SRC
}

scaffold_spider_gazelle() {
    local dir="${BENCH_DIR}/spider-gazelle"
    mkdir -p "${dir}/src/controllers"

    cat > "${dir}/shard.yml" <<'SHARD'
name: bench-spider-gazelle
version: 0.1.0

dependencies:
  action-controller:
    github: spider-gazelle/action-controller
    version: ~> 7.0

crystal: ">= 1.9.0"
SHARD

    cat > "${dir}/src/controllers/health.cr" <<'SRC'
require "action-controller"

class Health < ActionController::Base
  base "/health"

  @[AC::Route::GET("/")]
  def index : NamedTuple(status: String)
    {status: "ok"}
  end
end
SRC

    cat > "${dir}/src/app.cr" <<'SRC'
require "action-controller"
require "action-controller/server"
require "./controllers/*"

server = ActionController::Server.new(port: 3000, host: "127.0.0.1")
server.run
SRC
}

scaffold_lucky() {
    local dir="${BENCH_DIR}/lucky"
    mkdir -p "${dir}/src/actions/health"

    cat > "${dir}/shard.yml" <<'SHARD'
name: bench-lucky
version: 0.1.0

dependencies:
  lucky:
    github: luckyframework/lucky
    version: ~> 1.4.0

crystal: ">= 1.10.0"
SHARD

    cat > "${dir}/src/actions/health/show.cr" <<'SRC'
class Health::Show < Lucky::Action
  accepted_formats [:json], default: :json

  get "/health" do
    json({status: "ok"})
  end
end
SRC

    cat > "${dir}/src/app.cr" <<'SRC'
require "lucky"
require "./actions/**"

Lucky::Server.configure do |settings|
  settings.secret_key_base = "benchmark-test-key-not-for-production-use"
  settings.host = "127.0.0.1"
  settings.port = 5000
end

server = HTTP::Server.new([
  Lucky::HttpMethodOverrideHandler.new,
  Lucky::RouteHandler.new,
])
server.bind_tcp("127.0.0.1", 5000)
puts "Listening on http://127.0.0.1:5000"
server.listen
SRC
}

# ===========================================================================
# Framework metadata
# ===========================================================================

entry_file_for() {
    case "$1" in
        kemal)          echo "src/app.cr" ;;
        athena)         echo "src/server.cr" ;;
        spider-gazelle) echo "src/app.cr" ;;
        lucky)          echo "src/app.cr" ;;
        amber-v1)       echo "src/app.cr" ;;
        amber-v2)       echo "src/app.cr" ;;
    esac
}

port_for() {
    case "$1" in
        lucky) echo "${LUCKY_PORT}" ;;
        *)     echo "${DEFAULT_PORT}" ;;
    esac
}

# ===========================================================================
# Health check verification
# ===========================================================================

verify_health() {
    local binary="$1"
    local port="$2"
    local pid response

    kill_port "${port}"

    "${binary}" &
    pid=$!
    sleep 3

    if ! kill -0 "${pid}" 2>/dev/null; then
        warn "Server process died immediately."
        return 1
    fi

    response=$(curl -s --max-time 5 "http://127.0.0.1:${port}/health" 2>/dev/null || echo "")

    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
    kill_port "${port}"

    if echo "${response}" | grep -q '"status"' && echo "${response}" | grep -q '"ok"'; then
        return 0
    else
        warn "Unexpected response: ${response}"
        return 1
    fi
}

# ===========================================================================
# Cache cleanup
# ===========================================================================

clean_crystal_cache() {
    local project_dir="$1"
    rm -rf "${project_dir}/.crystal" 2>/dev/null || true
    rm -f "${project_dir}/bin/app" 2>/dev/null || true
    rm -rf "${HOME}/.cache/crystal" 2>/dev/null || true
}

# ===========================================================================
# Timeout helper for macOS (no coreutils needed)
# ===========================================================================

run_with_timeout() {
    local timeout_secs="$1"
    shift
    "$@" &
    local cmd_pid=$!
    ( sleep "${timeout_secs}" && kill -9 ${cmd_pid} 2>/dev/null ) &
    local timer_pid=$!
    wait ${cmd_pid} 2>/dev/null
    local result=$?
    kill ${timer_pid} 2>/dev/null 2>&1
    wait ${timer_pid} 2>/dev/null 2>&1
    return ${result}
}

# ===========================================================================
# Main benchmark loop
# ===========================================================================

info "Starting benchmarks for 6 frameworks..."
echo ""

for fw in ${FRAMEWORKS}; do
    echo ""
    echo -e "${BOLD}------------------------------------------------------------${RESET}"
    echo -e "${BOLD}  Framework: ${fw}${RESET}"
    echo -e "${BOLD}------------------------------------------------------------${RESET}"

    fw_dir="${BENCH_DIR}/${fw}"
    entry_file=$(entry_file_for "${fw}")
    port=$(port_for "${fw}")

    # -- Scaffold --
    info "Scaffolding ${fw}..."
    case "${fw}" in
        kemal)          scaffold_kemal ;;
        athena)         scaffold_athena ;;
        spider-gazelle) scaffold_spider_gazelle ;;
        lucky)          scaffold_lucky ;;
        amber-v1)       scaffold_amber_v1 ;;
        amber-v2)       scaffold_amber_v2 ;;
    esac
    success "Scaffold complete."

    # -- Install dependencies (with 180s timeout) --
    info "Running shards install for ${fw} (timeout: 180s)..."
    set +e
    # Run shards install in background with timeout
    (cd "${fw_dir}" && shards install --without-development 2>&1) &
    shards_pid=$!
    ( sleep 180 && kill -9 ${shards_pid} 2>/dev/null ) &
    timer_pid=$!
    wait ${shards_pid} 2>/dev/null
    shards_exit=$?
    kill ${timer_pid} 2>/dev/null 2>&1
    wait ${timer_pid} 2>/dev/null 2>&1
    set -e

    if [ ${shards_exit} -ne 0 ]; then
        if [ ${shards_exit} -eq 137 ]; then
            warn "shards install timed out for ${fw} (killed after 180s)"
            store_result "${fw}" "status" "SKIPPED"
            store_result "${fw}" "skip_reason" "shards install timed out (180s)"
        else
            warn "shards install failed for ${fw} (exit code ${shards_exit})"
            store_result "${fw}" "status" "SKIPPED"
            store_result "${fw}" "skip_reason" "shards install failed (exit code ${shards_exit})"
        fi
        echo ""
        continue
    fi
    success "Dependencies installed."

    # -- Benchmark compilations --
    mkdir -p "${fw_dir}/bin"

    # Stock debug build
    info "Stock debug build..."
    clean_crystal_cache "${fw_dir}"
    set +e
    t_start=$(now_ns)
    (cd "${fw_dir}" && "${STOCK_CRYSTAL}" build "${entry_file}" -o bin/app 2>&1)
    stock_debug_exit=$?
    t_end=$(now_ns)
    set -e
    stock_debug_ms=$(ns_to_ms $(( t_end - t_start )))

    if [ ${stock_debug_exit} -ne 0 ]; then
        warn "Stock debug build failed for ${fw} (may be version-incompatible)."
        store_result "${fw}" "stock_debug_ms" "FAIL"
        store_result "${fw}" "stock_debug_size" "0"
    else
        stock_debug_size=$(file_size_bytes "${fw_dir}/bin/app")
        store_result "${fw}" "stock_debug_ms" "${stock_debug_ms}"
        store_result "${fw}" "stock_debug_size" "${stock_debug_size}"
        success "Stock debug: ${stock_debug_ms} ms ($(format_size_mb ${stock_debug_size}))"
    fi

    # Stock release build
    info "Stock release build..."
    rm -f "${fw_dir}/bin/app"
    clean_crystal_cache "${fw_dir}"
    set +e
    t_start=$(now_ns)
    (cd "${fw_dir}" && "${STOCK_CRYSTAL}" build "${entry_file}" -o bin/app --release 2>&1)
    stock_release_exit=$?
    t_end=$(now_ns)
    set -e
    stock_release_ms=$(ns_to_ms $(( t_end - t_start )))

    if [ ${stock_release_exit} -ne 0 ]; then
        warn "Stock release build failed for ${fw}."
        store_result "${fw}" "stock_release_ms" "FAIL"
        store_result "${fw}" "stock_release_size" "0"
    else
        stock_release_size=$(file_size_bytes "${fw_dir}/bin/app")
        store_result "${fw}" "stock_release_ms" "${stock_release_ms}"
        store_result "${fw}" "stock_release_size" "${stock_release_size}"
        success "Stock release: ${stock_release_ms} ms ($(format_size_mb ${stock_release_size}))"
    fi

    # Incremental debug build (cold)
    info "Incremental debug build (cold)..."
    rm -f "${fw_dir}/bin/app"
    clean_crystal_cache "${fw_dir}"
    set +e
    t_start=$(now_ns)
    (cd "${fw_dir}" && "${INCREMENTAL_CRYSTAL}" build "${entry_file}" -o bin/app --incremental --stats 2>&1)
    incr_debug_exit=$?
    t_end=$(now_ns)
    set -e
    incr_debug_ms=$(ns_to_ms $(( t_end - t_start )))

    if [ ${incr_debug_exit} -ne 0 ]; then
        warn "Incremental debug build failed for ${fw}."
        store_result "${fw}" "incr_debug_ms" "FAIL"
        store_result "${fw}" "incr_debug_size" "0"
    else
        incr_debug_size=$(file_size_bytes "${fw_dir}/bin/app")
        store_result "${fw}" "incr_debug_ms" "${incr_debug_ms}"
        store_result "${fw}" "incr_debug_size" "${incr_debug_size}"
        success "Incremental debug: ${incr_debug_ms} ms ($(format_size_mb ${incr_debug_size}))"
    fi

    # Incremental release build (cold)
    info "Incremental release build (cold)..."
    rm -f "${fw_dir}/bin/app"
    clean_crystal_cache "${fw_dir}"
    set +e
    t_start=$(now_ns)
    (cd "${fw_dir}" && "${INCREMENTAL_CRYSTAL}" build "${entry_file}" -o bin/app --release --incremental --stats 2>&1)
    incr_release_exit=$?
    t_end=$(now_ns)
    set -e
    incr_release_ms=$(ns_to_ms $(( t_end - t_start )))

    if [ ${incr_release_exit} -ne 0 ]; then
        warn "Incremental release build failed for ${fw}."
        store_result "${fw}" "incr_release_ms" "FAIL"
        store_result "${fw}" "incr_release_size" "0"
    else
        incr_release_size=$(file_size_bytes "${fw_dir}/bin/app")
        store_result "${fw}" "incr_release_ms" "${incr_release_ms}"
        store_result "${fw}" "incr_release_size" "${incr_release_size}"
        success "Incremental release: ${incr_release_ms} ms ($(format_size_mb ${incr_release_size}))"
    fi

    # Warm incremental (no change)
    info "Warm incremental build (no change)..."
    set +e
    t_start=$(now_ns)
    incr_warm_output=$(cd "${fw_dir}" && "${INCREMENTAL_CRYSTAL}" build "${entry_file}" -o bin/app --incremental --stats 2>&1)
    t_end=$(now_ns)
    set -e
    warm_noop_ms=$(ns_to_ms $(( t_end - t_start )))
    store_result "${fw}" "warm_noop_ms" "${warm_noop_ms}"
    store_result "${fw}" "warm_noop_output" "${incr_warm_output}"
    success "Warm (no change): ${warm_noop_ms} ms"

    # Warm incremental (touch source)
    info "Warm incremental build (touched source)..."
    touch "${fw_dir}/${entry_file}"
    set +e
    t_start=$(now_ns)
    incr_touch_output=$(cd "${fw_dir}" && "${INCREMENTAL_CRYSTAL}" build "${entry_file}" -o bin/app --incremental --stats 2>&1)
    t_end=$(now_ns)
    set -e
    warm_touch_ms=$(ns_to_ms $(( t_end - t_start )))
    store_result "${fw}" "warm_touch_ms" "${warm_touch_ms}"
    store_result "${fw}" "warm_touch_output" "${incr_touch_output}"
    success "Warm (touched): ${warm_touch_ms} ms"

    # -- Verify health check --
    info "Verifying health endpoint on port ${port}..."
    set +e
    verify_health "${fw_dir}/bin/app" "${port}"
    health_exit=$?
    set -e

    if [ ${health_exit} -eq 0 ]; then
        store_result "${fw}" "health_check" "PASS"
        success "Health check: PASS"
    else
        store_result "${fw}" "health_check" "FAIL"
        warn "Health check: FAIL"
    fi

    store_result "${fw}" "status" "OK"
    echo ""
done

# ===========================================================================
# Generate report
# ===========================================================================

echo ""
echo ""

{
    echo "=================================================================="
    echo "            Crystal Web Framework Compilation Benchmark"
    echo "=================================================================="
    echo ""
    echo "  Date:                $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Stock Crystal:       ${STOCK_VERSION}"
    echo "  Incremental Crystal: ${INCR_VERSION}"
    echo "  Machine:             $(uname -m) / $(sw_vers -productName 2>/dev/null || uname -s) $(sw_vers -productVersion 2>/dev/null || uname -r)"
    echo ""
    echo "------------------------------------------------------------------"

    for fw in ${FRAMEWORKS}; do
        echo ""
        echo "  Framework: ${fw}"
        echo ""

        status=$(get_result "${fw}" "status" "UNKNOWN")

        if [ "${status}" = "SKIPPED" ]; then
            reason=$(get_result "${fw}" "skip_reason" "unknown reason")
            echo "    SKIPPED -- ${reason}"
            echo ""
            echo "------------------------------------------------------------------"
            continue
        fi

        if [ "${status}" = "UNKNOWN" ]; then
            echo "    NOT RUN"
            echo ""
            echo "------------------------------------------------------------------"
            continue
        fi

        sd_ms=$(get_result "${fw}" "stock_debug_ms")
        sd_size=$(get_result "${fw}" "stock_debug_size" "0")
        sd_size_fmt=$(format_size_mb "${sd_size}")
        printf "    %-34s %8s ms    (binary: %s)\n" "Stock debug build:" "${sd_ms}" "${sd_size_fmt}"

        sr_ms=$(get_result "${fw}" "stock_release_ms")
        sr_size=$(get_result "${fw}" "stock_release_size" "0")
        sr_size_fmt=$(format_size_mb "${sr_size}")
        printf "    %-34s %8s ms    (binary: %s)\n" "Stock release build:" "${sr_ms}" "${sr_size_fmt}"

        id_ms=$(get_result "${fw}" "incr_debug_ms")
        id_size=$(get_result "${fw}" "incr_debug_size" "0")
        id_size_fmt=$(format_size_mb "${id_size}")
        printf "    %-34s %8s ms    (binary: %s)\n" "Incremental debug build:" "${id_ms}" "${id_size_fmt}"

        ir_ms=$(get_result "${fw}" "incr_release_ms")
        ir_size=$(get_result "${fw}" "incr_release_size" "0")
        ir_size_fmt=$(format_size_mb "${ir_size}")
        printf "    %-34s %8s ms    (binary: %s)\n" "Incremental release build:" "${ir_ms}" "${ir_size_fmt}"

        wn_ms=$(get_result "${fw}" "warm_noop_ms")
        printf "    %-34s %8s ms\n" "Warm incremental (no change):" "${wn_ms}"

        wt_ms=$(get_result "${fw}" "warm_touch_ms")
        printf "    %-34s %8s ms\n" "Warm incremental (touched):" "${wt_ms}"

        hc=$(get_result "${fw}" "health_check")
        printf "    %-34s %s\n" "JSON health check:" "${hc}"

        # Speedups
        if [ "${sd_ms}" != "N/A" ] && [ "${sd_ms}" != "FAIL" ] && \
           [ "${id_ms}" != "N/A" ] && [ "${id_ms}" != "FAIL" ]; then
            debug_speedup=$(awk "BEGIN { printf \"%.2f\", ${sd_ms} / ${id_ms} }" 2>/dev/null || echo "N/A")
            printf "    %-34s %s\n" "Speedup (debug):" "${debug_speedup}x"
        fi

        if [ "${sr_ms}" != "N/A" ] && [ "${sr_ms}" != "FAIL" ] && \
           [ "${ir_ms}" != "N/A" ] && [ "${ir_ms}" != "FAIL" ]; then
            release_speedup=$(awk "BEGIN { printf \"%.2f\", ${sr_ms} / ${ir_ms} }" 2>/dev/null || echo "N/A")
            printf "    %-34s %s\n" "Speedup (release):" "${release_speedup}x"
        fi

        echo ""
        echo "------------------------------------------------------------------"
    done

    echo ""
    echo "=================================================================="
    echo ""
} | tee "${RESULTS_FILE}"

info "Results saved to: ${RESULTS_FILE}"
info "Benchmark complete. $(date '+%Y-%m-%d %H:%M:%S')"
