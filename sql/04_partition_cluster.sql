-- 04_partition_cluster.sql — build a partitioned + clustered copy of the fact table.
--
-- Run:
--   bq --location=US query --use_legacy_sql=false < sql/04_partition_cluster.sql
--
-- ── why RANGE_BUCKET(order_month) and not PARTITION BY order_date ────────────
--
-- The obvious choice is date partitioning:
--
--     PARTITION BY order_date CLUSTER BY seller_state, seller_id
--
-- That was the first version, and it produced an EMPTY table. The BigQuery
-- sandbox forces a 60-day partition expiration on every time-unit-partitioned
-- table (the dataset shows defaultPartitionExpirationMs = 5184000000, and
-- OPTIONS(partition_expiration_days = NULL) is silently overridden). Olist runs
-- from 2016-09 to 2018-08, so every partition was already past its expiry the
-- moment it was written and all 96,470 rows were dropped on creation.
--
-- Integer RANGE partitioning is not covered by that expiration policy, so the
-- table survives in the sandbox. order_month is YYYYMM as an INT64, built in
-- 02_marts.sql and checked against order_date in 03_quality_checks.sql.
--
-- On a billed project, use the date version — it is the better key: daily grain,
-- no synthetic column, and DATE filters prune directly.
--
-- ── what each clause buys ────────────────────────────────────────────────────
--
--   PARTITION BY RANGE_BUCKET(order_month, ...)
--     One physical partition per month. A query filtering on order_month reads
--     only the matching partitions, so bytes scanned fall with the range. This
--     shows up in `bq query --dry_run`, because the planner resolves partitions
--     before the query runs.
--
--   CLUSTER BY seller_state, seller_id
--     Sorts rows inside each partition and records per-block ranges, so a filter
--     on seller_state skips blocks that cannot match. This does NOT show up in
--     --dry_run: the dry run reports an upper bound, and block pruning happens at
--     execution time. Measure it with the real total_bytes_processed from
--     INFORMATION_SCHEMA.JOBS instead — 05_benchmark.sh reports both numbers.
--     Cluster columns prune left to right, so seller_state (low cardinality,
--     filtered often) comes before seller_id.

-- CREATE OR REPLACE refuses to change an existing table's partitioning spec
-- ("Cannot replace a table with a different partitioning spec"), so the old copy
-- is removed first. Nothing is lost: this table is derived, and 02_marts.sql
-- rebuilds its source from olist_raw at any time.
DROP TABLE IF EXISTS olist_marts.fct_delivery_performance_opt;

CREATE TABLE olist_marts.fct_delivery_performance_opt
PARTITION BY RANGE_BUCKET(order_month, GENERATE_ARRAY(201601, 201912, 1))
CLUSTER BY seller_state, seller_id
AS SELECT * FROM olist_marts.fct_delivery_performance;
