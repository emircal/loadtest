#!/usr/bin/env bash
set -euo pipefail

# Executes the data seeding workload in two sequential phases:
#   Phase 1 — Insert accounts (unpaced, generates the accountId dictionary).
#   Phase 2 — Insert transactions and collections (paced, reads accountId dictionary).
#
# Run gen-harness.sh first to generate the configs consumed by this script.

usage() {
  cat <<'EOF'
Usage:
  ./seed-data.sh [options] [/path/to/SimRunner.jar]

Options:
  --harness-dir DIR   Directory containing generated configs (default: harness)
  --site N            Site index to seed (selects seed-accounts-site-N.json etc.).
                      Defaults to 1. Use the value matching this machine's --site
                      when gen-harness.sh was run with --sites > 1.
  -n, --dry-run       Print resolved config paths and exit without running SimRunner.
  -h, --help          Show this help.

The SimRunner.jar path can also be supplied via the SIMRUNNER_JAR environment variable.
EOF
}

HARNESS_DIR="harness"
SITE_INDEX=1
JAR_PATH="${SIMRUNNER_JAR:-}"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness-dir)  HARNESS_DIR="$2"; shift 2 ;;
    --site)         SITE_INDEX="$2";  shift 2 ;;
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

SEED_ACCOUNTS="${HARNESS_DIR}/seed-accounts-site-${SITE_INDEX}.json"
SEED_CHILDREN="${HARNESS_DIR}/seed-children-site-${SITE_INDEX}.json"

[[ -f "${SEED_ACCOUNTS}" ]] || \
  { echo "Config not found: ${SEED_ACCOUNTS}  (run gen-harness.sh first)"; exit 1; }
[[ -f "${SEED_CHILDREN}" ]] || \
  { echo "Config not found: ${SEED_CHILDREN}  (run gen-harness.sh first)"; exit 1; }

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "==> Dry run: would execute the following phases for site ${SITE_INDEX}"
  echo "    Phase 1: java -jar <SimRunner.jar> ${SEED_ACCOUNTS}"
  echo "    Phase 2: java -jar <SimRunner.jar> ${SEED_CHILDREN}"
  exit 0
fi

echo "==> Seeding phase 1/2 — accounts (${SEED_ACCOUNTS})"
java -jar "${JAR_PATH}" "${SEED_ACCOUNTS}"

echo "==> Seeding phase 2/2 — transactions and collections (${SEED_CHILDREN})"
java -jar "${JAR_PATH}" "${SEED_CHILDREN}"

echo "==> Seeding complete (site ${SITE_INDEX})."
