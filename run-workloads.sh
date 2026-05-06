#!/usr/bin/env bash
set -euo pipefail

# Generates and executes test workloads that model application traffic against
# the MongoDB cluster.
#
# Run gen-harness.sh (and optionally seed-data.sh) before invoking this script.

usage() {
  cat <<'EOF'
Usage:
  ./run-workloads.sh [options] [/path/to/SimRunner.jar]

Options:
  --harness-dir DIR   Directory containing generated configs (default: harness)
  --mode MODE         Workload mode: read | write | mixed (default: mixed)
  --read-pct N        Read percentage (0-100) for mixed mode (default: 50)
  --threads N         Total client threads to allocate (default: 12)
  --dict-limit N      Max entries to preload per dictionary (default: 500000, max: 5000000)
  --disable-aggregates Exclude aggregate workloads from generated test config
  --duration-ms N     Global stopAfterDuration in milliseconds
  --duration-read-ms N  Read workload stopAfterDuration override in milliseconds
  --duration-write-ms N Write workload stopAfterDuration override in milliseconds
  --pace-ms N         Global pace in milliseconds
  --read-pace-ms N    Read workload pace override in milliseconds
  --write-pace-ms N   Write workload pace override in milliseconds
  --pace-find-ms N    find pace override in milliseconds
  --pace-aggregate-ms N aggregate pace override in milliseconds
  --pace-insert-ms N  insert pace override in milliseconds
  --pace-update-ms N  updateOne/updateMany pace override in milliseconds
  --pace-delete-ms N  deleteOne/deleteMany pace override in milliseconds
  --base-config FILE  Base config used as template source (default: auto-detect)
  -n, --dry-run       Print resolved config path and exit without running SimRunner.
  -h, --help          Show this help.

The SimRunner.jar path can also be supplied via the SIMRUNNER_JAR environment variable.

Examples:
  ./run-workloads.sh --mode write --threads 18 /path/to/SimRunner.jar
  ./run-workloads.sh --mode mixed --threads 40 --dict-limit 200000 /path/to/SimRunner.jar
  ./run-workloads.sh --mode read --threads 12 --dry-run
  ./run-workloads.sh --mode mixed --read-pct 70 --threads 20 /path/to/SimRunner.jar
  ./run-workloads.sh --mode mixed --read-pct 70 --threads 20 --disable-aggregates /path/to/SimRunner.jar
  ./run-workloads.sh --mode mixed --read-pct 70 --threads 20 --duration-ms 600000 --pace-ms 20 /path/to/SimRunner.jar
  ./run-workloads.sh --mode read --threads 12 --duration-ms 180000 --pace-find-ms 5 --pace-aggregate-ms 200 /path/to/SimRunner.jar
EOF
}

HARNESS_DIR="harness"
JAR_PATH="${SIMRUNNER_JAR:-}"
DRY_RUN=0
MODE="mixed"
READ_PCT=50
TOTAL_THREADS=12
BASE_CONFIG=""
DICT_LIMIT=500000
DISABLE_AGGREGATES=0
DURATION_MS=""
DURATION_READ_MS=""
DURATION_WRITE_MS=""
PACE_MS=""
READ_PACE_MS=""
WRITE_PACE_MS=""
PACE_FIND_MS=""
PACE_AGGREGATE_MS=""
PACE_INSERT_MS=""
PACE_UPDATE_MS=""
PACE_DELETE_MS=""

is_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -gt 0 ]]
}

is_non_negative_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

json_or_null() {
  local value="$1"
  if [[ -n "${value}" ]]; then
    echo "${value}"
  else
    echo "null"
  fi
}

is_percent_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 0 ]] && [[ "$1" -le 100 ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness-dir)  HARNESS_DIR="$2"; shift 2 ;;
    --mode)         MODE="$2"; shift 2 ;;
    --read-pct)     READ_PCT="$2"; shift 2 ;;
    --threads)      TOTAL_THREADS="$2"; shift 2 ;;
    --dict-limit)   DICT_LIMIT="$2"; shift 2 ;;
    --disable-aggregates) DISABLE_AGGREGATES=1; shift ;;
    --duration-ms)       DURATION_MS="$2"; shift 2 ;;
    --duration-read-ms)  DURATION_READ_MS="$2"; shift 2 ;;
    --duration-write-ms) DURATION_WRITE_MS="$2"; shift 2 ;;
    --pace-ms)           PACE_MS="$2"; shift 2 ;;
    --read-pace-ms)      READ_PACE_MS="$2"; shift 2 ;;
    --write-pace-ms)     WRITE_PACE_MS="$2"; shift 2 ;;
    --pace-find-ms)      PACE_FIND_MS="$2"; shift 2 ;;
    --pace-aggregate-ms) PACE_AGGREGATE_MS="$2"; shift 2 ;;
    --pace-insert-ms)    PACE_INSERT_MS="$2"; shift 2 ;;
    --pace-update-ms)    PACE_UPDATE_MS="$2"; shift 2 ;;
    --pace-delete-ms)    PACE_DELETE_MS="$2"; shift 2 ;;
    --base-config)  BASE_CONFIG="$2"; shift 2 ;;
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

case "${MODE}" in
  read|write|mixed) ;;
  *)
    echo "Error: --mode must be one of: read, write, mixed. Got: ${MODE}"
    exit 1
    ;;
esac

if ! is_percent_int "${READ_PCT}"; then
  echo "Error: --read-pct must be an integer between 0 and 100. Got: ${READ_PCT}"
  exit 1
fi

if ! is_positive_int "${TOTAL_THREADS}"; then
  echo "Error: --threads must be a positive integer. Got: ${TOTAL_THREADS}"
  exit 1
fi

if ! is_positive_int "${DICT_LIMIT}"; then
  echo "Error: --dict-limit must be a positive integer. Got: ${DICT_LIMIT}"
  exit 1
fi

if [[ "${DICT_LIMIT}" -gt 5000000 ]]; then
  echo "Error: --dict-limit exceeds max allowed value (5000000). Got: ${DICT_LIMIT}"
  exit 1
fi

for tuple in \
  "--duration-ms:${DURATION_MS}" \
  "--duration-read-ms:${DURATION_READ_MS}" \
  "--duration-write-ms:${DURATION_WRITE_MS}" \
  "--pace-ms:${PACE_MS}" \
  "--read-pace-ms:${READ_PACE_MS}" \
  "--write-pace-ms:${WRITE_PACE_MS}" \
  "--pace-find-ms:${PACE_FIND_MS}" \
  "--pace-aggregate-ms:${PACE_AGGREGATE_MS}" \
  "--pace-insert-ms:${PACE_INSERT_MS}" \
  "--pace-update-ms:${PACE_UPDATE_MS}" \
  "--pace-delete-ms:${PACE_DELETE_MS}"; do
  key="${tuple%%:*}"
  value="${tuple#*:}"
  if [[ -n "${value}" ]] && ! is_non_negative_int "${value}"; then
    echo "Error: ${key} must be a non-negative integer. Got: ${value}"
    exit 1
  fi
done

if [[ "${MODE}" != "mixed" ]] && [[ "${READ_PCT}" -ne 50 ]]; then
  echo "Warning: --read-pct is ignored when --mode is '${MODE}'."
fi

if [[ "${MODE}" == "mixed" ]] && { [[ "${READ_PCT}" -eq 0 ]] || [[ "${READ_PCT}" -eq 100 ]]; }; then
  echo "Error: --read-pct must be between 1 and 99 for mixed mode."
  echo "Use --mode write for 0% reads or --mode read for 100% reads."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: this script requires 'jq'."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

TEST_CONFIG="${HARNESS_DIR}/test.json"

if [[ -z "${BASE_CONFIG}" ]]; then
  if [[ -f "${HARNESS_DIR}/seed-accounts-site-1.json" ]]; then
    BASE_CONFIG="${HARNESS_DIR}/seed-accounts-site-1.json"
  elif [[ -f "simrunner-seed-paced.json" ]]; then
    BASE_CONFIG="simrunner-seed-paced.json"
  else
    echo "Error: could not auto-detect base config."
    echo "Provide one with --base-config FILE."
    exit 1
  fi
fi

# Verify base config is readable (prevents NFS stalls from hanging silently)
if [[ ! -r "${BASE_CONFIG}" ]]; then
  echo "Error: base config not found or not readable: ${BASE_CONFIG}"
  exit 1
fi

mkdir -p "${HARNESS_DIR}"

READ_WORKLOAD_COUNT=5
WRITE_WORKLOAD_COUNT=9

READ_POOL=0
WRITE_POOL=0

case "${MODE}" in
  read)
    READ_POOL="${TOTAL_THREADS}"
    ;;
  write)
    WRITE_POOL="${TOTAL_THREADS}"
    ;;
  mixed)
    READ_POOL=$(( TOTAL_THREADS * READ_PCT / 100 ))
    WRITE_POOL=$(( TOTAL_THREADS - READ_POOL ))

    if [[ "${READ_POOL}" -eq 0 ]]; then
      READ_POOL=1
      WRITE_POOL=$(( TOTAL_THREADS - 1 ))
    fi
    if [[ "${WRITE_POOL}" -eq 0 ]]; then
      WRITE_POOL=1
      READ_POOL=$(( TOTAL_THREADS - 1 ))
    fi
    ;;
esac

if [[ "${READ_POOL}" -gt 0 ]] && [[ "${READ_POOL}" -lt "${READ_WORKLOAD_COUNT}" ]]; then
  READ_POOL="${READ_WORKLOAD_COUNT}"
fi
if [[ "${WRITE_POOL}" -gt 0 ]] && [[ "${WRITE_POOL}" -lt "${WRITE_WORKLOAD_COUNT}" ]]; then
  WRITE_POOL="${WRITE_WORKLOAD_COUNT}"
fi

TOTAL_EFFECTIVE_THREADS=$(( READ_POOL + WRITE_POOL ))

if [[ "${TOTAL_EFFECTIVE_THREADS}" -gt "${TOTAL_THREADS}" ]]; then
  echo "Note: effective thread count increased from ${TOTAL_THREADS} to ${TOTAL_EFFECTIVE_THREADS}"
  echo "      to keep at least one thread per selected workload definition."
fi

jq -n \
  --arg mode "${MODE}" \
  --argjson readPool "${READ_POOL}" \
  --argjson writePool "${WRITE_POOL}" \
  --argjson dictLimit "${DICT_LIMIT}" \
  --argjson disableAggregates "${DISABLE_AGGREGATES}" \
  --argjson durationMs "$(json_or_null "${DURATION_MS}")" \
  --argjson durationReadMs "$(json_or_null "${DURATION_READ_MS}")" \
  --argjson durationWriteMs "$(json_or_null "${DURATION_WRITE_MS}")" \
  --argjson paceMs "$(json_or_null "${PACE_MS}")" \
  --argjson readPaceMs "$(json_or_null "${READ_PACE_MS}")" \
  --argjson writePaceMs "$(json_or_null "${WRITE_PACE_MS}")" \
  --argjson paceFindMs "$(json_or_null "${PACE_FIND_MS}")" \
  --argjson paceAggregateMs "$(json_or_null "${PACE_AGGREGATE_MS}")" \
  --argjson paceInsertMs "$(json_or_null "${PACE_INSERT_MS}")" \
  --argjson paceUpdateMs "$(json_or_null "${PACE_UPDATE_MS}")" \
  --argjson paceDeleteMs "$(json_or_null "${PACE_DELETE_MS}")" \
  --slurpfile base "${BASE_CONFIG}" \
  '
    def distribute($total; $items):
      ($items | length) as $n
      | if $n == 0 then
          []
        else
          ($total - $n) as $extra
          | ($extra / $n | floor) as $baseExtra
          | ($extra % $n) as $remainder
          | [range(0; $n) as $i
              | $items[$i] + {
                  threads: (1 + $baseExtra + (if $i < $remainder then 1 else 0 end))
                }
            ]
        end;

    def isReadOp($op):
      ($op == "find" or $op == "aggregate");

    def isWriteOp($op):
      ($op == "insert" or $op == "updateOne" or $op == "updateMany" or $op == "deleteOne" or $op == "deleteMany");

    def resolvedDuration($op):
      if isReadOp($op) then
        ($durationReadMs // $durationMs)
      elif isWriteOp($op) then
        ($durationWriteMs // $durationMs)
      else
        $durationMs
      end;

    def resolvedPace($op):
      if $op == "find" then
        ($paceFindMs // $readPaceMs // $paceMs)
      elif $op == "aggregate" then
        ($paceAggregateMs // $readPaceMs // $paceMs)
      elif $op == "insert" then
        ($paceInsertMs // $writePaceMs // $paceMs)
      elif ($op == "updateOne" or $op == "updateMany") then
        ($paceUpdateMs // $writePaceMs // $paceMs)
      elif ($op == "deleteOne" or $op == "deleteMany") then
        ($paceDeleteMs // $writePaceMs // $paceMs)
      else
        $paceMs
      end;

    def withTiming:
      . as $w
      | (resolvedDuration($w.op)) as $duration
      | (resolvedPace($w.op)) as $pace
      | (if $duration != null then . + { stopAfterDuration: $duration } else . end)
      | (if $pace != null then . + { pace: $pace } else . end);

    def readDefs:
      [
        {
          name: "ReadAcctById",
          template: "accounts",
          op: "find",
          params: {
            filter: { accountId: { "%dictionary": { name: "accountIds" } } },
            limit: 1
          }
        },
        {
          name: "ReadTxnById",
          template: "transactions",
          op: "find",
          params: {
            filter: { _id: { "%dictionary": { name: "transactionDocIds" } } },
            limit: 1
          }
        },
        {
          name: "ReadCollById",
          template: "collections",
          op: "find",
          params: {
            filter: { _id: { "%dictionary": { name: "collectionDocIds" } } },
            limit: 1
          }
        },
        {
          name: "ReadTxnByAcct",
          template: "transactions",
          op: "find",
          params: {
            filter: { accountId: { "%dictionary": { name: "accountIds" } } },
            sort: { "transactionDetails.postDate": -1 },
            limit: 20
          }
        },
        {
          name: "ReadCollByAcct",
          template: "collections",
          op: "find",
          params: {
            filter: { accountId: { "%dictionary": { name: "accountIds" } } },
            limit: 20
          }
        }
      ];

    def writeDefs:
      [
        {
          name: "InsAcct",
          template: "accounts",
          op: "insert"
        },
        {
          name: "UpdAcct",
          template: "accounts",
          op: "updateOne",
          params: {
            filter: { _id: { "%dictionary": { name: "accountDocIds" } } },
            update: {
              "$set": {
                "balances.currentBalance": { "%decimal": { min: 0, max: 15000 } },
                "status": {
                  "%oneOf": {
                    options: [
                      { code: "A", description: "Active", isClosed: false },
                      { code: "I", description: "Inactive", isClosed: false },
                      { code: "C", description: "Closed", isClosed: true }
                    ]
                  }
                }
              }
            }
          }
        },
        {
          name: "DelAcct",
          template: "accounts",
          op: "deleteOne",
          params: {
            filter: { _id: { "%dictionary": { name: "accountDocIds" } } }
          }
        },
        {
          name: "InsTxn",
          template: "transactions",
          op: "insert"
        },
        {
          name: "UpdTxn",
          template: "transactions",
          op: "updateOne",
          params: {
            filter: { _id: { "%dictionary": { name: "transactionDocIds" } } },
            update: {
              "$set": {
                "audit.rts": "%now",
                "transactionDetails.type": {
                  "%oneOf": {
                    options: ["PURCHASE", "REFUND", "WITHDRAWAL"]
                  }
                }
              }
            }
          }
        },
        {
          name: "DelTxn",
          template: "transactions",
          op: "deleteOne",
          params: {
            filter: { _id: { "%dictionary": { name: "transactionDocIds" } } }
          }
        },
        {
          name: "InsColl",
          template: "collections",
          op: "insert"
        },
        {
          name: "UpdColl",
          template: "collections",
          op: "updateOne",
          params: {
            filter: { _id: { "%dictionary": { name: "collectionDocIds" } } },
            update: {
              "$set": {
                "workflow.lastActionCode": {
                  "%oneOf": {
                    options: ["LM", "PM", "CC"]
                  }
                },
                "delinquency.daysPastDue": { "%number": { min: 0, max: 180 } }
              }
            }
          }
        },
        {
          name: "DelColl",
          template: "collections",
          op: "deleteOne",
          params: {
            filter: { _id: { "%dictionary": { name: "collectionDocIds" } } }
          }
        }
      ];

    ($base[0].templates) as $baseTemplates
    | (
        $baseTemplates
        | map(
            if .name == "accounts" then
              . + {
                dictionaries: {
                  accountIds: {
                    type: "collection",
                    db: .database,
                    collection: .collection,
                    query: {},
                    limit: $dictLimit,
                    attribute: "accountId"
                  },
                  accountDocIds: {
                    type: "collection",
                    db: .database,
                    collection: .collection,
                    query: {},
                    limit: $dictLimit,
                    attribute: "_id"
                  }
                }
              }
            elif .name == "transactions" then
              . + {
                dictionaries: ((.dictionaries // {}) + {
                  transactionIds: {
                    type: "collection",
                    db: .database,
                    collection: .collection,
                    query: {},
                    limit: $dictLimit,
                    attribute: "transactionId"
                  },
                  transactionDocIds: {
                    type: "collection",
                    db: .database,
                    collection: .collection,
                    query: {},
                    limit: $dictLimit,
                    attribute: "_id"
                  }
                })
              }
            elif .name == "collections" then
              . + {
                dictionaries: ((.dictionaries // {}) + {
                  collectionIds: {
                    type: "collection",
                    db: .database,
                    collection: .collection,
                    query: {},
                    limit: $dictLimit,
                    attribute: "collectionId"
                  },
                  collectionDocIds: {
                    type: "collection",
                    db: .database,
                    collection: .collection,
                    query: {},
                    limit: $dictLimit,
                    attribute: "_id"
                  }
                })
              }
            else
              .
            end
          )
      ) as $templates
    | (
        $templates
        | map(
            if .dictionaries? then
              .dictionaries |= with_entries(.value |= (. + { limit: $dictLimit }))
            else
              .
            end
          )
      ) as $templates
    | (
        if $mode == "read" then
          distribute($readPool; readDefs)
        elif $mode == "write" then
          distribute($writePool; writeDefs)
        else
          distribute($readPool; readDefs) + distribute($writePool; writeDefs)
        end
        | map(withTiming)
      ) as $workloads
    | {
        connectionString: $base[0].connectionString,
        reportInterval: ($base[0].reportInterval // 10000),
        http: ($base[0].http // {enabled: false, port: 3000, host: "localhost"}),
        templates: $templates,
        workloads: $workloads
      }
  ' > "${TEST_CONFIG}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "==> Generated workload config: ${TEST_CONFIG}"
  echo "mode=${MODE}, readPool=${READ_POOL}, writePool=${WRITE_POOL}, effectiveThreads=${TOTAL_EFFECTIVE_THREADS}, dictLimit=${DICT_LIMIT}"
  echo
  jq '{workloads: [.workloads[] | {name, op, template, threads, pace, stopAfterDuration}]}' "${TEST_CONFIG}"
  echo
  echo "==> Dry run: would execute java -jar <SimRunner.jar> ${TEST_CONFIG}"
  exit 0
fi

echo "==> Generated workload config: ${TEST_CONFIG}"
echo "mode=${MODE}, readPool=${READ_POOL}, writePool=${WRITE_POOL}, effectiveThreads=${TOTAL_EFFECTIVE_THREADS}, dictLimit=${DICT_LIMIT}"
echo "==> Starting SimRunner (initial dictionary preload may take time for large dict limits)"
echo "==> Running test workloads (${TEST_CONFIG})"
java -jar "${JAR_PATH}" "${TEST_CONFIG}"
