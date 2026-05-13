#!/usr/bin/bash
set -euo pipefail

# Generates SimRunner runtime config files into an output directory.
# Run once; produces one set of config files per site.

usage() {
  cat <<'EOF'
Usage:
  ./gen-harness.sh [options]

Required:
  --uri URI               MongoDB connection string (or MONGO_URI env var)

Options:
  --accounts N            Total number of accounts across all sites (default: 1000000)
  --tx-per-account N      Transactions per account (default: 260)
  --collections-ratio R   Collections-to-accounts ratio (default: 0.035)
  --db-name NAME          Database name for generated configs (default: simrunner)
  --sites N               Number of seeding partitions / machines (default: 1)
  --threads N             Threads for account and transaction insert workloads.
                          Collections always use 1 thread. (default: from base template)
  --batch-size N          Batch size for all seeding workloads.
                          (default: keep values from base template)
  --out-dir DIR           Output directory for generated configs (default: harness)
  --seed-base FILE        Base seed template (default: simrunner-seed-paced.json)
  --test-base FILE        Base test template (default: simrunner-test.json)
  -n, --dry-run           Print generated configs without writing files.
  -h, --help              Show this help.

Environment variables (fallback when flags are not provided):
  MONGO_URI, NUMBER_ACCOUNTS, TX_PER_ACCOUNT, COLLECTIONS_RATIO

Multi-site seeding:
  When --sites > 1 the script generates one set of config files per site:
    seed-accounts-site-1.json, seed-accounts-site-2.json, ...
    seed-children-site-1.json, seed-children-site-2.json, ...
  IDs are prefixed with "SITE<N>_" so that sequences from different machines
  never collide. Run seed-data.sh --site N on each machine with the matching files.
EOF
}

# ── Defaults ────────────────────────────────────────────────────────────────
MONGO_URI="${MONGO_URI:-}"
NUMBER_ACCOUNTS="${NUMBER_ACCOUNTS:-1000000}"
TX_PER_ACCOUNT="${TX_PER_ACCOUNT:-260}"
COLLECTIONS_RATIO="${COLLECTIONS_RATIO:-0.035}"
DB_NAME="simrunner"
SITES=1
THREADS=""   # empty = use value from base template
BATCH_SIZE="" # empty = use values from base template
OUT_DIR="harness"
SEED_BASE="simrunner-seed-paced.json"
TEST_BASE="simrunner-test.json"
DRY_RUN=0

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uri)                MONGO_URI="$2";          shift 2 ;;
    --accounts)           NUMBER_ACCOUNTS="$2";    shift 2 ;;
    --tx-per-account)     TX_PER_ACCOUNT="$2";     shift 2 ;;
    --collections-ratio)  COLLECTIONS_RATIO="$2";  shift 2 ;;
    --db-name)            DB_NAME="$2";            shift 2 ;;
    --sites)              SITES="$2";              shift 2 ;;
    --threads)            THREADS="$2";            shift 2 ;;
    --batch-size)         BATCH_SIZE="$2";         shift 2 ;;
    --out-dir)            OUT_DIR="$2";            shift 2 ;;
    --seed-base)          SEED_BASE="$2";          shift 2 ;;
    --test-base)          TEST_BASE="$2";          shift 2 ;;
    -n|--dry-run)         DRY_RUN=1;              shift ;;
    -h|--help)            usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

# ── Validation ───────────────────────────────────────────────────────────────
[[ -z "${MONGO_URI}" ]] && { echo "Error: --uri / MONGO_URI is required."; exit 1; }

[[ "${NUMBER_ACCOUNTS}" =~ ^[0-9]+$ && "${NUMBER_ACCOUNTS}" -gt 0 ]] || \
  { echo "NUMBER_ACCOUNTS must be a positive integer. Got: ${NUMBER_ACCOUNTS}"; exit 1; }

[[ "${TX_PER_ACCOUNT}" =~ ^[0-9]+$ && "${TX_PER_ACCOUNT}" -gt 0 ]] || \
  { echo "TX_PER_ACCOUNT must be a positive integer. Got: ${TX_PER_ACCOUNT}"; exit 1; }

[[ "${COLLECTIONS_RATIO}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || \
  { echo "COLLECTIONS_RATIO must be a positive decimal. Got: ${COLLECTIONS_RATIO}"; exit 1; }

[[ "${SITES}" =~ ^[0-9]+$ && "${SITES}" -gt 0 ]] || \
  { echo "SITES must be a positive integer. Got: ${SITES}"; exit 1; }

if [[ -n "${THREADS}" ]]; then
  [[ "${THREADS}" =~ ^[0-9]+$ && "${THREADS}" -gt 0 ]] || \
    { echo "--threads must be a positive integer. Got: ${THREADS}"; exit 1; }
fi

if [[ -n "${BATCH_SIZE}" ]]; then
  [[ "${BATCH_SIZE}" =~ ^[0-9]+$ && "${BATCH_SIZE}" -gt 0 ]] || \
    { echo "--batch-size must be a positive integer. Got: ${BATCH_SIZE}"; exit 1; }
fi

command -v jq >/dev/null 2>&1 || { echo "This script requires 'jq'."; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

[[ -f "${SEED_BASE}" ]] || { echo "Seed base config not found: ${SEED_BASE}"; exit 1; }
[[ -f "${TEST_BASE}" ]] || { echo "Test base config not found: ${TEST_BASE}"; exit 1; }

# ── Derived values ────────────────────────────────────────────────────────────
ceil_div() { echo $(( ($1 + $2 - 1) / $2 )); }

# Accounts assigned to each site (ceiling-divide so every account is covered)
PER_SITE_ACCOUNTS="$(ceil_div "${NUMBER_ACCOUNTS}" "${SITES}")"

# Read thread/batch settings from the base template
# --threads overrides the threads for accounts and transactions; collections = 1.
ACCOUNTS_THREADS_BASE="$(jq -r '.workloads[] | select(.name == "Insert accounts")     | (.threads // 1)' "${SEED_BASE}")"
ACCOUNTS_BATCH="$(       jq -r '.workloads[] | select(.name == "Insert accounts")     | (.batch   // 1)' "${SEED_BASE}")"
TX_THREADS_BASE="$(      jq -r '.workloads[] | select(.name == "Insert transactions") | (.threads // 1)' "${SEED_BASE}")"
TX_BATCH="$(             jq -r '.workloads[] | select(.name == "Insert transactions") | (.batch   // 1)' "${SEED_BASE}")"
COL_BATCH="$(            jq -r '.workloads[] | select(.name == "Insert collections")  | (.batch   // 1)' "${SEED_BASE}")"

ACCOUNTS_THREADS="${THREADS:-${ACCOUNTS_THREADS_BASE}}"
TX_THREADS="${THREADS:-${TX_THREADS_BASE}}"
COL_THREADS=1   # collections always use a single thread

if [[ -n "${BATCH_SIZE}" ]]; then
  ACCOUNTS_BATCH="${BATCH_SIZE}"
  TX_BATCH="${BATCH_SIZE}"
  COL_BATCH="${BATCH_SIZE}"
fi

TARGET_TRANSACTIONS=$(( PER_SITE_ACCOUNTS * TX_PER_ACCOUNT ))
TARGET_COLLECTIONS="$(awk -v n="${PER_SITE_ACCOUNTS}" -v r="${COLLECTIONS_RATIO}" \
  'BEGIN { printf "%.0f", n * r }')"

ACCOUNTS_STOP_AFTER="$(ceil_div "${PER_SITE_ACCOUNTS}"   "$(( ACCOUNTS_THREADS * ACCOUNTS_BATCH ))")"
TX_STOP_AFTER="$(      ceil_div "${TARGET_TRANSACTIONS}"  "$(( TX_THREADS       * TX_BATCH       ))")"
COL_STOP_AFTER="$(     ceil_div "${TARGET_COLLECTIONS}"   "$(( COL_THREADS      * COL_BATCH      ))")"

ACTUAL_ACCOUNTS=$(( ACCOUNTS_STOP_AFTER * ACCOUNTS_THREADS * ACCOUNTS_BATCH ))
ACTUAL_TRANSACTIONS=$(( TX_STOP_AFTER * TX_THREADS * TX_BATCH ))
ACTUAL_COLLECTIONS=$(( COL_STOP_AFTER * COL_THREADS * COL_BATCH ))

# ── jq filters ────────────────────────────────────────────────────────────────
#
# SITE_TRANSFORMS  : applied to both seed configs when a site prefix is in use
#   • accounts.accountId     : wrapped in %stringConcat to prepend the prefix
#   • transactions.transactionId prefix token : "TXN"  -> "<prefix>TXN"
#   • collections.collectionId  prefix token  : "COL-" -> "<prefix>COL-"
#
# DICT_QUERY_TRANSFORM : restricts per-template accountId dictionaries to this site's prefix
#
# THREAD_TRANSFORMS : overrides thread counts when --threads was supplied
#
# BATCH_TRANSFORMS : overrides batch sizes when --batch-size was supplied
#
# PACE_TRANSFORM : removes pacing from seeding workloads
#
# DB_TRANSFORMS : rewrites all database references in the generated configs
#
# DICT_LIMIT_TRANSFORM : sets the per-template accountId dictionary limits
#
SITE_TRANSFORMS='
  if $sitePrefix != "" then
    .templates |= map(
      if .name == "accounts" then
        .template.accountId = {
          "%stringConcat": { "of": [$sitePrefix, .template.accountId], "sep": "" }
        }
      else . end
    )
    | .templates |= map(
      if .name == "transactions" then
        .template.transactionId["%stringConcat"].of[0] = ($sitePrefix + "TXN")
      else . end
    )
    | .templates |= map(
      if .name == "collections" then
        .template.collectionId["%stringConcat"].of[0] = ($sitePrefix + "COL-")
      else . end
    )
  else . end
'

DICT_QUERY_TRANSFORM='
  if $sitePrefix != "" then
    .templates |= map(
      if .dictionaries.accountIds? then
        .dictionaries.accountIds.query = {
          "accountId": { "$regex": ("^" + $sitePrefix) }
        }
      else . end
    )
  else . end
'

# Always applied; sets the (possibly overridden) thread counts.
THREAD_TRANSFORMS='
  .workloads |= map(
    if   .name == "Insert accounts"     then .threads = $accountsThreads
    elif .name == "Insert transactions" then .threads = $txThreads
    elif .name == "Insert collections"  then .threads = $colThreads
    else . end
  )
'

BATCH_TRANSFORMS='
  .workloads |= map(
    if   .name == "Insert accounts"     then .batch = $accountsBatch
    elif .name == "Insert transactions" then .batch = $txBatch
    elif .name == "Insert collections"  then .batch = $colBatch
    else . end
  )
'

PACE_TRANSFORM='
  .workloads |= map(del(.pace))
'

DB_TRANSFORMS='
  .templates |= map(.database = $dbName)
  | .templates |= map(
      if .dictionaries.accountIds? then
        .dictionaries.accountIds.db = $dbName
      else . end
    )
'

DICT_LIMIT_TRANSFORM='
  .templates |= map(
    if .dictionaries.accountIds? then
      .dictionaries.accountIds.limit = $dictLimit
    else . end
  )
'

# ── Helper: generate configs for one site ─────────────────────────────────────
gen_site() {
  local site_index="$1"
  local site_prefix="SITE${site_index}_"

  local seed_accounts_json seed_children_json

  seed_accounts_json="$(jq \
    --arg  uri              "${MONGO_URI}" \
    --arg  dbName           "${DB_NAME}" \
    --arg  sitePrefix       "${site_prefix}" \
    --argjson dictLimit     "${PER_SITE_ACCOUNTS}" \
    --argjson stopAfter     "${ACCOUNTS_STOP_AFTER}" \
    --argjson accountsThreads "${ACCOUNTS_THREADS}" \
    --argjson accountsBatch "${ACCOUNTS_BATCH}" \
    --argjson txBatch       "${TX_BATCH}" \
    --argjson colBatch      "${COL_BATCH}" \
    --argjson txThreads     "${TX_THREADS}" \
    --argjson colThreads    "${COL_THREADS}" \
    "
      .connectionString = \$uri
      | ${DB_TRANSFORMS}
      | ${DICT_LIMIT_TRANSFORM}
      | .workloads |= map(
          if .name == \"Insert accounts\" then
            .stopAfter = \$stopAfter | del(.pace)
          else . end
        )
      | .workloads |= map(select(.name == \"Insert accounts\"))
      | ${THREAD_TRANSFORMS}
      | ${BATCH_TRANSFORMS}
      | ${PACE_TRANSFORM}
      | ${SITE_TRANSFORMS}
    " "${SEED_BASE}")"

  seed_children_json="$(jq \
    --arg  uri              "${MONGO_URI}" \
    --arg  dbName           "${DB_NAME}" \
    --arg  sitePrefix       "${site_prefix}" \
    --argjson dictLimit     "${PER_SITE_ACCOUNTS}" \
    --argjson txStopAfter   "${TX_STOP_AFTER}" \
    --argjson colStopAfter  "${COL_STOP_AFTER}" \
    --argjson accountsThreads "${ACCOUNTS_THREADS}" \
    --argjson accountsBatch "${ACCOUNTS_BATCH}" \
    --argjson txBatch       "${TX_BATCH}" \
    --argjson colBatch      "${COL_BATCH}" \
    --argjson txThreads     "${TX_THREADS}" \
    --argjson colThreads    "${COL_THREADS}" \
    "
      .connectionString = \$uri
      | ${DB_TRANSFORMS}
      | ${DICT_LIMIT_TRANSFORM}
      | ${DICT_QUERY_TRANSFORM}
      | .workloads |= map(
          if .name == \"Insert transactions\" then
            .stopAfter = \$txStopAfter
          elif .name == \"Insert collections\" then
            .stopAfter = \$colStopAfter
          else . end
        )
      | .workloads |= map(
          select(.name == \"Insert transactions\" or .name == \"Insert collections\")
        )
      | ${THREAD_TRANSFORMS}
      | ${BATCH_TRANSFORMS}
      | ${PACE_TRANSFORM}
      | ${SITE_TRANSFORMS}
    " "${SEED_BASE}")"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "==> [site ${site_index}] seed-accounts-site-${site_index}.json"
    echo "${seed_accounts_json}" | jq .
    echo
    echo "==> [site ${site_index}] seed-children-site-${site_index}.json"
    echo "${seed_children_json}" | jq .
    echo
  else
    echo "${seed_accounts_json}" > "${OUT_DIR}/seed-accounts-site-${site_index}.json"
    echo "${seed_children_json}" > "${OUT_DIR}/seed-children-site-${site_index}.json"
    echo "    seed-accounts-site-${site_index}.json  seed-children-site-${site_index}.json"
  fi
}

# ── Generate test config (same for every site) ────────────────────────────────
TEST_JSON="$(jq \
  --arg uri "${MONGO_URI}" \
  --arg dbName "${DB_NAME}" \
  '.connectionString = $uri | .templates |= map(.database = $dbName)' \
  "${TEST_BASE}")"

# ── Dry-run output ────────────────────────────────────────────────────────────
if [[ "${DRY_RUN}" -eq 1 ]]; then
  for (( i=1; i<=SITES; i++ )); do
    gen_site "${i}"
  done
  echo "==> test.json (shared across all sites)"
  echo "${TEST_JSON}" | jq .
  exit 0
fi

# ── Write files ───────────────────────────────────────────────────────────────
mkdir -p "${OUT_DIR}"
echo "==> Generated harness configs in ${OUT_DIR}/"
for (( i=1; i<=SITES; i++ )); do
  gen_site "${i}"
done
echo "${TEST_JSON}" > "${OUT_DIR}/test.json"
echo "    test.json  (shared)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "==> Seeding parameters  (${SITES} site(s))"
printf "    %-22s %s\n" "Accounts per site:"  "${PER_SITE_ACCOUNTS}"
printf "    %-22s %s\n" "TX per account:"     "${TX_PER_ACCOUNT}"
printf "    %-22s %s\n" "Collections ratio:"  "${COLLECTIONS_RATIO}"
printf "    %-22s %s\n" "Database name:"      "${DB_NAME}"
printf "    %-22s %s (accounts/transactions) / 1 (collections)\n" "Threads:" "${ACCOUNTS_THREADS}"
printf "    %-22s %s (all seeding workloads)\n" "Batch size:" "${ACCOUNTS_BATCH}"
echo ""
printf "    %-14s  target=%-12s  actual=%s\n" "accounts"     "${PER_SITE_ACCOUNTS}"    "${ACTUAL_ACCOUNTS}"
printf "    %-14s  target=%-12s  actual=%s\n" "transactions"  "${TARGET_TRANSACTIONS}"  "${ACTUAL_TRANSACTIONS}"
printf "    %-14s  target=%-12s  actual=%s\n" "collections"   "${TARGET_COLLECTIONS}"   "${ACTUAL_COLLECTIONS}"

if [[ "${ACTUAL_ACCOUNTS}"     -ne "${PER_SITE_ACCOUNTS}"   ]] ||
   [[ "${ACTUAL_TRANSACTIONS}"  -ne "${TARGET_TRANSACTIONS}" ]] ||
   [[ "${ACTUAL_COLLECTIONS}"   -ne "${TARGET_COLLECTIONS}"  ]]; then
  echo ""
  echo "    Note: actual totals are rounded up because SimRunner's stopAfter is"
  echo "    iteration-based and each iteration inserts (threads × batch) documents."
fi
