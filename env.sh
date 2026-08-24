# Project settings for this portfolio build.
# Usage:  source ./env.sh   then run ./01_load.sh and the bq commands below.
export PROJECT_ID="bq-scg-portfolio"
export LOCATION="US"
export RAW_DATASET="olist_raw"
export MARTS_DATASET="olist_marts"

# Handy shorthand — same location on every job, which BigQuery is strict about.
bqq() { bq --project_id="$PROJECT_ID" --location="$LOCATION" query --use_legacy_sql=false "$@"; }
