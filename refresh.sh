#!/usr/bin/env bash
#
# refresh.sh — rebuild every table and view so the sandbox expiry starts again.
#
# The BigQuery sandbox deletes each table 60 days after it was created, and it
# refuses to move that date: `bq update --expiration` fails with "Table
# expiration time must be less than 60 days while in sandbox mode". The only
# way to keep the warehouse alive is to create the objects again.
#
# A load with --replace may keep the old table and its old expiry, so the raw
# tables are removed first and loaded fresh. Everything downstream is
# CREATE OR REPLACE (or DROP + CREATE for the _opt copy), which sets a new
# expiry on its own. Both quality gates run at the end: a refresh that changes
# a number fails loudly instead of quietly feeding the dashboards.
#
# Run it a few days before the date the last run printed. Running it long
# before that gains little, because the new expiry is always 60 days from now.
#
# Needs the Olist CSVs in data/ (./data/download.sh fetches them).
#
# Usage:
#   ./refresh.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# shellcheck source=env.sh
source ./env.sh
export PROJECT_ID LOCATION RAW_DATASET MARTS_DATASET

RAW_TABLES=(orders order_items customers sellers)

log() { printf '[refresh] %s\n' "$*"; }
run_sql() {
  log "running $1"
  bqq --format=none < "$1"
}

log "project=${PROJECT_ID} location=${LOCATION}"

# Check the CSVs before deleting anything, so a missing file cannot leave the
# warehouse half empty.
for t in "${RAW_TABLES[@]}"; do
  [[ -f "data/olist_${t}_dataset.csv" ]] || {
    printf '[refresh] ERROR: data/olist_%s_dataset.csv is missing. Run ./data/download.sh first.\n' "$t" >&2
    exit 1
  }
done

for t in "${RAW_TABLES[@]}"; do
  log "removing ${RAW_DATASET}.${t}"
  bq --project_id="${PROJECT_ID}" rm -f -t "${PROJECT_ID}:${RAW_DATASET}.${t}"
done

./01_load.sh

run_sql sql/02_marts.sql
run_sql sql/03_quality_checks.sql
run_sql sql/04_partition_cluster.sql
run_sql sql/06_bi_views.sql
run_sql sql/07_bi_checks.sql

log "both quality gates passed. New expiry dates (UTC):"
for ds in "${RAW_DATASET}" "${MARTS_DATASET}"; do
  bqq --format=pretty "
    SELECT table_schema AS dataset, table_name, option_value AS expires
    FROM \`${PROJECT_ID}.${ds}.INFORMATION_SCHEMA.TABLE_OPTIONS\`
    WHERE option_name = 'expiration_timestamp'
    ORDER BY table_name"
done
