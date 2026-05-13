#!/usr/bin/bash
set -euo pipefail

# Usage:
#   ./run-seed-then-test.sh [--dry-run|-n] "/path/to/SimRunner.jar"
# or set SIMRUNNER_JAR env var:
#   SIMRUNNER_JAR=/path/to/SimRunner.jar ./run-seed-then-test.sh [--dry-run|-n]

usage() {
  cat <<'EOF'
Usage:
  ./run-seed-then-test.sh [--dry-run|-n] [/path/to/SimRunner.jar]

Options:
  -n, --dry-run   Render and print final seed config, then exit without running SimRunner.
  -h, --help      Show this help.

Environment variables:
  SIMRUNNER_JAR      Path to SimRunner.jar (alternative to positional argument)
  NUMBER_ACCOUNTS    Default 1000000
  TX_PER_ACCOUNT     Default 260
  COLLECTIONS_RATIO  Default 0.035
EOF
}

DRY_RUN=0
JAR_PATH="${SIMRUNNER_JAR:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "${JAR_PATH}" ]]; then
        JAR_PATH="$1"
        shift
      else
        echo "Unexpected argument: $1"
        usage
        exit 1
      fi
      ;;
  esac
done

if [[ "${DRY_RUN}" -eq 0 ]] && [[ -z "${JAR_PATH}" ]]; then
  echo "Provide SimRunner.jar path as first argument or via SIMRUNNER_JAR env var."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

SEED_CONFIG_BASE="simrunner-seed-paced.json"

NUMBER_ACCOUNTS="${NUMBER_ACCOUNTS:-1000000}"
TX_PER_ACCOUNT="${TX_PER_ACCOUNT:-260}"
COLLECTIONS_RATIO="${COLLECTIONS_RATIO:-0.035}"

if ! [[ "${NUMBER_ACCOUNTS}" =~ ^[0-9]+$ ]] || [[ "${NUMBER_ACCOUNTS}" -le 0 ]]; then
  echo "NUMBER_ACCOUNTS must be a positive integer. Got: ${NUMBER_ACCOUNTS}"
  exit 1
fi

if ! [[ "${TX_PER_ACCOUNT}" =~ ^[0-9]+$ ]] || [[ "${TX_PER_ACCOUNT}" -le 0 ]]; then
  echo "TX_PER_ACCOUNT must be a positive integer. Got: ${TX_PER_ACCOUNT}"
  exit 1
fi

if ! [[ "${COLLECTIONS_RATIO}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "COLLECTIONS_RATIO must be a positive decimal number. Got: ${COLLECTIONS_RATIO}"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "This script requires 'jq' to generate a runtime seed config."
  exit 1
fi

ceil_div() {
  local n="$1"
  local d="$2"
  echo $(( (n + d - 1) / d ))
}

ACCOUNTS_THREADS="$(jq -r '.workloads[] | select(.name == "Insert accounts") | (.threads // 1)' "${SEED_CONFIG_BASE}")"
ACCOUNTS_BATCH="$(jq -r '.workloads[] | select(.name == "Insert accounts") | (.batch // 1)' "${SEED_CONFIG_BASE}")"
TX_THREADS="$(jq -r '.workloads[] | select(.name == "Insert transactions") | (.threads // 1)' "${SEED_CONFIG_BASE}")"
TX_BATCH="$(jq -r '.workloads[] | select(.name == "Insert transactions") | (.batch // 1)' "${SEED_CONFIG_BASE}")"
COL_THREADS="$(jq -r '.workloads[] | select(.name == "Insert collections") | (.threads // 1)' "${SEED_CONFIG_BASE}")"
COL_BATCH="$(jq -r '.workloads[] | select(.name == "Insert collections") | (.batch // 1)' "${SEED_CONFIG_BASE}")"

TARGET_TRANSACTIONS=$(( NUMBER_ACCOUNTS * TX_PER_ACCOUNT ))
TARGET_COLLECTIONS="$(awk -v n="${NUMBER_ACCOUNTS}" -v r="${COLLECTIONS_RATIO}" 'BEGIN { printf "%.0f", n * r }')"

ACCOUNTS_STOP_AFTER="$(ceil_div "${NUMBER_ACCOUNTS}" "$(( ACCOUNTS_THREADS * ACCOUNTS_BATCH ))")"
TX_STOP_AFTER="$(ceil_div "${TARGET_TRANSACTIONS}" "$(( TX_THREADS * TX_BATCH ))")"
COL_STOP_AFTER="$(ceil_div "${TARGET_COLLECTIONS}" "$(( COL_THREADS * COL_BATCH ))")"

ACTUAL_ACCOUNTS=$(( ACCOUNTS_STOP_AFTER * ACCOUNTS_THREADS * ACCOUNTS_BATCH ))
ACTUAL_TRANSACTIONS=$(( TX_STOP_AFTER * TX_THREADS * TX_BATCH ))
ACTUAL_COLLECTIONS=$(( COL_STOP_AFTER * COL_THREADS * COL_BATCH ))

SEED_CONFIG_ACCOUNTS="$(mktemp "${TMPDIR:-/tmp}/simrunner-seed-accounts.XXXXXX.json")"
SEED_CONFIG_CHILDREN="$(mktemp "${TMPDIR:-/tmp}/simrunner-seed-children.XXXXXX.json")"

jq \
  --argjson dictLimit "${NUMBER_ACCOUNTS}" \
  --argjson accountsStopAfter "${ACCOUNTS_STOP_AFTER}" \
  '
    .dictionaries.accountIds.limit = $dictLimit
    | .workloads |= map(
        if .name == "Insert accounts" then
          .stopAfter = $accountsStopAfter | del(.pace)
        else
          .
        end
      )
    | .workloads |= map(select(.name == "Insert accounts"))
  ' "${SEED_CONFIG_BASE}" > "${SEED_CONFIG_ACCOUNTS}"

jq \
  --argjson dictLimit "${NUMBER_ACCOUNTS}" \
  --argjson txStopAfter "${TX_STOP_AFTER}" \
  --argjson colStopAfter "${COL_STOP_AFTER}" \
  '
    .dictionaries.accountIds.limit = $dictLimit
    | .workloads |= map(
        if .name == "Insert transactions" then
          .stopAfter = $txStopAfter
        elif .name == "Insert collections" then
          .stopAfter = $colStopAfter
        else
          .
        end
      )
    | .workloads |= map(select(.name == "Insert transactions" or .name == "Insert collections"))
  ' "${SEED_CONFIG_BASE}" > "${SEED_CONFIG_CHILDREN}"

cleanup() {
  rm -f "${SEED_CONFIG_ACCOUNTS}" "${SEED_CONFIG_CHILDREN}"
}
trap cleanup EXIT

echo "==> Seeding parameters"
echo "NUMBER_ACCOUNTS=${NUMBER_ACCOUNTS}"
echo "TX_PER_ACCOUNT=${TX_PER_ACCOUNT}"
echo "COLLECTIONS_RATIO=${COLLECTIONS_RATIO}"
echo "Target docs: accounts=${NUMBER_ACCOUNTS}, transactions=${TARGET_TRANSACTIONS}, collections=${TARGET_COLLECTIONS}"
echo "Effective docs with current batch/thread settings: accounts=${ACTUAL_ACCOUNTS}, transactions=${ACTUAL_TRANSACTIONS}, collections=${ACTUAL_COLLECTIONS}"
if [[ "${ACTUAL_ACCOUNTS}" -ne "${NUMBER_ACCOUNTS}" ]] || [[ "${ACTUAL_TRANSACTIONS}" -ne "${TARGET_TRANSACTIONS}" ]] || [[ "${ACTUAL_COLLECTIONS}" -ne "${TARGET_COLLECTIONS}" ]]; then
  echo "Note: effective totals are rounded up because SimRunner stopAfter is iteration-based with fixed batch/thread settings."
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "==> Dry run: rendered seed config (phase 1 - accounts)"
  jq . "${SEED_CONFIG_ACCOUNTS}"
  echo
  echo "==> Dry run: rendered seed config (phase 2 - transactions and collections)"
  jq . "${SEED_CONFIG_CHILDREN}"
  exit 0
fi

echo "==> Seeding phase 1/2 (accounts only, unpaced)"
java -jar "${JAR_PATH}" "${SEED_CONFIG_ACCOUNTS}"

echo "==> Seeding phase 2/2 (transactions and collections, paced)"
java -jar "${JAR_PATH}" "${SEED_CONFIG_CHILDREN}"

echo "==> Running test workloads"
java -jar "${JAR_PATH}" simrunner-test.json
