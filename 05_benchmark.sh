#!/usr/bin/env bash
#
# 05_benchmark.sh — measure what partitioning and clustering actually save.
#
# Runs each benchmark query twice — once against the plain fact table, once
# against the partitioned + clustered copy — and reports two numbers per run:
#
#   dry-run bytes    what the planner commits to before executing. Reflects
#                    PARTITION pruning only; for a clustered table BigQuery
#                    reports it as an "upper bound".
#   real bytes       what the query actually read, pulled from
#                    INFORMATION_SCHEMA.JOBS. Reflects partition AND cluster
#                    (block) pruning, so it is the honest number.
#
# Real runs pass --nouse_cache: a cached result reports 0 bytes and would make
# the comparison meaningless.
#
# Usage:
#   ./05_benchmark.sh
#   ./05_benchmark.sh > results/benchmark.md
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
LOCATION="${LOCATION:-US}"
REGION="region-$(printf %s "${LOCATION}" | tr "[:upper:]" "[:lower:]")"   # bash 3.2 on macOS has no ${var,,}
MARTS_DATASET="${MARTS_DATASET:-olist_marts}"
BASE_TABLE="fct_delivery_performance"
OPT_TABLE="fct_delivery_performance_opt"

RUN_ID="bench$(date +%Y%m%d%H%M%S)"

command -v bq >/dev/null 2>&1 || { echo "bq not found" >&2; exit 1; }
[[ -n "${PROJECT_ID}" ]] || { echo "no project set" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

QUERIES="q1_quarter_by_state q2_one_state_all_time q3_state_and_range"

# The query text is identical for both variants — only the table name changes.
# That is the whole point: same question, two physical layouts.
build_sql() {
  local name="$1" table="$2" body
  case "${name}" in
    q1_quarter_by_state)
      # narrow month range, no state filter -> partitioning should carry this one
      body="SELECT seller_state, ROUND(AVG(late_days), 2) AS avg_late_days, COUNT(*) AS orders
FROM \`${MARTS_DATASET}.${table}\`
WHERE order_month BETWEEN 201801 AND 201803
GROUP BY seller_state
ORDER BY orders DESC" ;;
    q2_one_state_all_time)
      # no month filter, one state -> clustering should carry this one
      body="SELECT order_month, COUNT(*) AS orders, ROUND(AVG(freight_value), 2) AS avg_freight
FROM \`${MARTS_DATASET}.${table}\`
WHERE seller_state = 'SP'
GROUP BY order_month
ORDER BY order_month" ;;
    q3_state_and_range)
      # both filters -> both prunings apply
      body="SELECT seller_id, COUNT(*) AS orders, ROUND(AVG(delivery_days), 2) AS avg_delivery_days
FROM \`${MARTS_DATASET}.${table}\`
WHERE order_month BETWEEN 201801 AND 201806
  AND seller_state = 'SP'
GROUP BY seller_id
ORDER BY orders DESC
LIMIT 10" ;;
    *) echo "unknown query ${name}" >&2; exit 1 ;;
  esac
  local variant="base"
  [[ "${table}" == "${OPT_TABLE}" ]] && variant="opt"
  printf '%s\n-- %s %s %s\n' "${body}" "${RUN_ID}" "${name}" "${variant}"
}

# "will process 12345 bytes" and "will process upper bound of 12345 bytes"
dry_bytes() {
  bq --project_id="${PROJECT_ID}" --location="${LOCATION}" query \
     --use_legacy_sql=false --dry_run "$1" 2>&1 \
  | sed -nE 's/.*process (upper bound of )?([0-9]+) bytes.*/\2/p' | head -1
}

run_real() {
  bq --project_id="${PROJECT_ID}" --location="${LOCATION}" query \
     --use_legacy_sql=false --nouse_cache --format=none "$1" >/dev/null 2>&1
}

echo "# Benchmark — partitioning and clustering" >&2
echo "run_id=${RUN_ID} project=${PROJECT_ID}" >&2

for name in ${QUERIES}; do
  for table in "${BASE_TABLE}" "${OPT_TABLE}"; do
    variant="base"; [[ "${table}" == "${OPT_TABLE}" ]] && variant="opt"
    sql="$(build_sql "${name}" "${table}")"
    echo "  ${name} / ${variant} ..." >&2
    printf '%s|%s|%s\n' "${name}" "${variant}" "$(dry_bytes "${sql}")" >> "${TMP}/dry.psv"
    run_real "${sql}"
  done
done

# Real bytes come from the job history. The marker comment carries the run id,
# so this picks up exactly the jobs this script just launched.
# NOT LIKE '%INFORMATION_SCHEMA%' keeps this query from matching itself.
bq --project_id="${PROJECT_ID}" --location="${LOCATION}" query \
   --use_legacy_sql=false --format=csv "
SELECT
  REGEXP_EXTRACT(query, r'-- ${RUN_ID} ([a-z0-9_]+) ') AS query_name,
  REGEXP_EXTRACT(query, r'-- ${RUN_ID} [a-z0-9_]+ ([a-z]+)') AS variant,
  total_bytes_processed,
  total_slot_ms
FROM \`${REGION}\`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
WHERE creation_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 HOUR)
  AND job_type = 'QUERY'
  AND state = 'DONE'
  AND query LIKE '%-- ${RUN_ID} %'
  AND query NOT LIKE '%INFORMATION_SCHEMA%'
" 2>/dev/null | tail -n +2 > "${TMP}/real.csv"

awk -F'|' '{ dry[$1"/"$2] = $3 } END { for (k in dry) print k"\t"dry[k] }' \
  "${TMP}/dry.psv" > "${TMP}/dry.tsv"

awk -F',' '{ print $1"/"$2"\t"$3"\t"$4 }' "${TMP}/real.csv" > "${TMP}/real.tsv"

printf '# Benchmark — partitioning and clustering\n\n'
printf 'run_id: `%s` · project: `%s` · generated: %s\n\n' \
  "${RUN_ID}" "${PROJECT_ID}" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

awk -F'\t' '
  FILENAME == ARGV[1] { dry[$1] = $2; next }
  { real[$1] = $2; slot[$1] = $3 }
  END {
    split("q1_quarter_by_state q2_one_state_all_time q3_state_and_range", qs, " ")
    label["q1_quarter_by_state"]  = "Q1  3-month range, all states"
    label["q2_one_state_all_time"]= "Q2  one state, full history"
    label["q3_state_and_range"]   = "Q3  6-month range + one state"
    printf "| Query | Layout | dry-run bytes | real bytes | slot ms |\n"
    printf "|---|---|---:|---:|---:|\n"
    for (i = 1; i <= 3; i++) {
      q = qs[i]
      for (v = 1; v <= 2; v++) {
        variant = (v == 1 ? "base" : "opt")
        k = q"/"variant
        printf "| %s | %s | %s | %s | %s |\n", (v == 1 ? label[q] : ""), \
               (variant == "base" ? "plain table" : "partition + cluster"), \
               dry[k], real[k], slot[k]
      }
      b = real[q"/base"] + 0; o = real[q"/opt"] + 0
      if (b > 0) printf "| | **reduction (real bytes)** | | **%.1f%%** | |\n", (b - o) * 100.0 / b
    }
  }
' "${TMP}/dry.tsv" "${TMP}/real.tsv"
