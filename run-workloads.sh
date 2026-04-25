#!/usr/bin/env bash
set -euo pipefail

# Executes the test workload that models normal application traffic against
# the MongoDB cluster.
#
# Run gen-harness.sh (and optionally seed-data.sh) before invoking this script.

usage() {
  cat <<'EOF'
Usage:
  ./run-workloads.sh [options] [/path/to/SimRunner.jar]

Options:
  --harness-dir DIR   Directory containing generated configs (default: harness)
  -n, --dry-run       Print resolved config path and exit without running SimRunner.
  -h, --help          Show this help.

The SimRunner.jar path can also be supplied via the SIMRUNNER_JAR environment variable.
EOF
}

HARNESS_DIR="harness"
JAR_PATH="${SIMRUNNER_JAR:-}"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness-dir)  HARNESS_DIR="$2"; shift 2 ;;
    -n|--dry-run)   DRY_RUN=1;        shift ;;
    -h|--help)      usage; exit 0 ;;
    *)
      if [[ -z "${JAR_PATH}" ]]; then
        JAR_PATH="$1"; shift
      else
        echo "Unexpected argument: $1"; usage; exit 1
      fi
      ;;
  esac
done

if [[ "${DRY_RUN}" -eq 0 ]] && [[ -z "${JAR_PATH}" ]]; then
  echo "Error: provide SimRunner.jar as a positional argument or via SIMRUNNER_JAR."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

TEST_CONFIG="${HARNESS_DIR}/test.json"

[[ -f "${TEST_CONFIG}" ]] || \
  { echo "Config not found: ${TEST_CONFIG}  (run gen-harness.sh first)"; exit 1; }

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "==> Dry run: would execute java -jar <SimRunner.jar> ${TEST_CONFIG}"
  exit 0
fi

echo "==> Running test workloads (${TEST_CONFIG})"
java -jar "${JAR_PATH}" "${TEST_CONFIG}"
