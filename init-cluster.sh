#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./init-cluster.sh --uri URI --db-name NAME [options]

Options:
  --uri URI          MongoDB connection string for mongosh.
  --db-name NAME     Database name to initialize.
  --sites N          Number of site prefixes to pre-split for (default: 1).
  --api-version N    Pass through mongosh --apiVersion (optional).
  -h, --help         Show this help.

Examples:
  ./init-cluster.sh --uri "mongodb://localhost:27017" --db-name simrunner
  ./init-cluster.sh --uri "mongodb://localhost:27017" --db-name simrunner --sites 3 --api-version 1
EOF
}

URI=""
DB_NAME=""
SITES=1
API_VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uri)          URI="$2"; shift 2 ;;
    --db-name)      DB_NAME="$2"; shift 2 ;;
    --sites)        SITES="$2"; shift 2 ;;
    --api-version)  API_VERSION="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

[[ -n "${URI}" ]] || { echo "Error: --uri is required."; exit 1; }
[[ -n "${DB_NAME}" ]] || { echo "Error: --db-name is required."; exit 1; }
[[ "${SITES}" =~ ^[0-9]+$ && "${SITES}" -gt 0 ]] || {
  echo "Error: --sites must be a positive integer. Got: ${SITES}"
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

cmd=(mongosh "${URI}")
if [[ -n "${API_VERSION}" ]]; then
  cmd+=(--apiVersion "${API_VERSION}")
fi
cmd+=(init-cluster.mongosh.js)

INIT_CLUSTER_DB_NAME="${DB_NAME}" INIT_CLUSTER_SITES="${SITES}" "${cmd[@]}"
