#!/bin/bash
#
# Runs the Lume benchmark suite and prints the measurements.
#
# The benchmarks live in their own target/scheme so they never slow down a normal
# `xcodebuild test`, and they build under the **Benchmark** configuration
# (Release + ENABLE_TESTABILITY): Debug builds are `-Onone`, which makes parser
# and import numbers meaningless.
#
# Usage:
#   Scripts/run-performance-tests.sh                       # whole suite
#   Scripts/run-performance-tests.sh ParsingBenchmarks     # one suite
#   Scripts/run-performance-tests.sh ParsingBenchmarks/testXMLTVDateParsing
#
# Environment:
#   LUME_PERF_SIM   simulator name or UDID (default: newest available iPhone
#                   running iOS 26.4 or later — 26.2 fails the deployment target)
#   LUME_PERF_DD    derived data path (default: /tmp/lume-perf-dd)
#
# NOTE ON NUMBERS: results are only comparable against runs on the *same*
# machine, at the same thermal state, with nothing else building. Committed
# `.xcbaseline`s are per-device for exactly this reason. For a shared gate, pin
# one machine or compare allocation counts rather than wall clock.

set -euo pipefail

cd "$(dirname "$0")/.."

DERIVED_DATA="${LUME_PERF_DD:-/tmp/lume-perf-dd}"
LOG_DIR="${DERIVED_DATA}/perf-logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/perf-$(date +%Y%m%d-%H%M%S).log"

# --- Pick a simulator ------------------------------------------------------
if [[ -n "${LUME_PERF_SIM:-}" ]]; then
    DESTINATION="platform=iOS Simulator,name=${LUME_PERF_SIM}"
    # A UDID works in the `id=` form; detect one by shape.
    if [[ "$LUME_PERF_SIM" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
        DESTINATION="platform=iOS Simulator,id=${LUME_PERF_SIM}"
    fi
else
    # The tests deploy to a recent iOS only; a 26.2 simulator fails with a
    # deployment-target mismatch (exit 65), so resolve a 26.4+ device.
    UDID=$(xcrun simctl list devices available |
        awk '/-- iOS 2[6-9]\.[4-9]|-- iOS [3-9][0-9]\./ {ok=1; next} /^-- /{ok=0} ok && /iPhone/ {print; exit}' |
        sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
    if [[ -z "$UDID" ]]; then
        echo "error: no iOS 26.4+ iPhone simulator found. Create one, or set LUME_PERF_SIM." >&2
        exit 1
    fi
    DESTINATION="platform=iOS Simulator,id=${UDID}"
fi

# --- Optional test filter --------------------------------------------------
FILTER_ARGS=()
if [[ $# -gt 0 ]]; then
    FILTER_ARGS=(-only-testing:"LumePerformanceTests/$1")
    echo "Filter:      LumePerformanceTests/$1"
fi

echo "Destination: ${DESTINATION}"
echo "Log:         ${LOG_FILE}"
echo

set +e
# `${arr[@]+"${arr[@]}"}` rather than `"${arr[@]}"`: macOS ships bash 3.2, where
# expanding an empty array under `set -u` is an "unbound variable" error.
xcodebuild test \
    -project Lume.xcodeproj \
    -scheme LumePerformance \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    ${FILTER_ARGS[@]+"${FILTER_ARGS[@]}"} \
    >"$LOG_FILE" 2>&1
STATUS=$?
set -e

# --- Report ---------------------------------------------------------------
echo "=== Measurements ==="
# One line per metric: test name, metric, average, and the run-to-run spread.
# A relative standard deviation above ~10% means the number is too noisy to
# compare — close other apps and re-run before believing a "regression".
grep -o "Test Case '-\[[^]]*\]' measured \[[^]]*\] average: [0-9.]*, relative standard deviation: [0-9.]*%" "$LOG_FILE" |
    sed -E "s/Test Case '-\[LumePerformanceTests\.([^ ]+) ([^]]+)\]' measured \[([^]]+)\] average: ([0-9.]+), relative standard deviation: ([0-9.]+)%/\1.\2  \3  avg=\4  rsd=\5%/" ||
    echo "(no measurements found — see the log)"

echo
echo "=== Result ==="
grep -E "^Test Suite '(Selected tests|All tests)' (passed|failed)" "$LOG_FILE" | tail -2 || true
grep -E "error:|failed \(" "$LOG_FILE" | head -20 || true

if [[ $STATUS -ne 0 ]]; then
    echo
    echo "xcodebuild exited $STATUS — full log: $LOG_FILE" >&2
fi
exit $STATUS
