#!/usr/bin/env bash
#
# Load the raw Olist CSVs into a BigQuery dataset.
#
# Safe to re-run: every table is loaded with --replace, so a second run leaves
# exactly the same rows behind instead of doubling them.
#
# Usage:
#   ./01_load.sh                       # uses the active gcloud project
#   PROJECT_ID=my-project ./01_load.sh
#   DATA_DIR=/path/to/csvs ./01_load.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
LOCATION="${LOCATION:-US}"
RAW_DATASET="${RAW_DATASET:-olist_raw}"
DATA_DIR="${DATA_DIR:-${SCRIPT_DIR}/data}"

# table name in BigQuery  ->  CSV file name
TABLES=(orders order_items customers sellers)
csv_for() { echo "${DATA_DIR}/olist_${1}_dataset.csv"; }

log() { printf '[load] %s\n' "$*"; }
die() { printf '[load] ERROR: %s\n' "$*" >&2; exit 1; }

# ── preflight ────────────────────────────────────────────────────────────────
command -v bq >/dev/null 2>&1 || die "bq not found. Install: brew install --cask google-cloud-sdk"
[[ -n "${PROJECT_ID}" ]] || die "no project set. Run: gcloud config set project <PROJECT_ID>"

missing=()
for t in "${TABLES[@]}"; do
  [[ -f "$(csv_for "$t")" ]] || missing+=("$(csv_for "$t")")
done
if (( ${#missing[@]} > 0 )); then
  printf '[load] ERROR: missing CSV files:\n' >&2
  printf '  %s\n' "${missing[@]}" >&2
  cat >&2 <<'HINT'

Download them first:
  pip install kaggle                       # needs ~/.kaggle/kaggle.json
  kaggle datasets download -d olistbr/brazilian-ecommerce -p ./data
  unzip -o ./data/brazilian-ecommerce.zip -d ./data
HINT
  exit 1
fi

log "project=${PROJECT_ID} location=${LOCATION} dataset=${RAW_DATASET}"

# ── dataset ──────────────────────────────────────────────────────────────────
if bq --project_id="${PROJECT_ID}" show --dataset "${PROJECT_ID}:${RAW_DATASET}" >/dev/null 2>&1; then
  log "dataset ${RAW_DATASET} already exists"
else
  log "creating dataset ${RAW_DATASET}"
  bq --project_id="${PROJECT_ID}" --location="${LOCATION}" mk \
    --dataset \
    --description "Raw Olist e-commerce CSVs, loaded as-is by 01_load.sh" \
    "${PROJECT_ID}:${RAW_DATASET}"
fi

# ── load ─────────────────────────────────────────────────────────────────────
# --autodetect reads the header row for names and infers types.
# --max_bad_records=0 means a malformed row fails the load instead of being
# skipped quietly — a bad row should be a decision, not a silent loss.
for t in "${TABLES[@]}"; do
  csv="$(csv_for "$t")"
  log "loading ${t} <- $(basename "${csv}")"
  bq --project_id="${PROJECT_ID}" --location="${LOCATION}" load \
    --source_format=CSV \
    --autodetect \
    --replace \
    --max_bad_records=0 \
    "${RAW_DATASET}.${t}" \
    "${csv}"
done

# ── row counts ───────────────────────────────────────────────────────────────
counts_sql=""
for t in "${TABLES[@]}"; do
  [[ -n "${counts_sql}" ]] && counts_sql+=" UNION ALL "
  counts_sql+="SELECT '${t}' AS table_name, COUNT(*) AS row_count FROM \`${RAW_DATASET}.${t}\`"
done

log "row counts after load:"
bq --project_id="${PROJECT_ID}" --location="${LOCATION}" query \
  --use_legacy_sql=false \
  --format=pretty \
  "${counts_sql} ORDER BY table_name"

log "done. Next: bq --location=${LOCATION} query --use_legacy_sql=false < sql/02_marts.sql"
