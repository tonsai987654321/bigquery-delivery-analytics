-- 03_quality_checks.sql — assert the marts are sane before anyone builds a report on them.
--
-- Run:
--   bq --location=US query --use_legacy_sql=false < sql/03_quality_checks.sql
--
-- Prints one row per check, then fails the job if any check found bad rows.
-- The failing ASSERT is what makes this usable in CI: a non-zero exit code,
-- not a table a human has to remember to read.

CREATE TEMP TABLE checks AS

-- structural: the grain must hold
SELECT 'fct_is_empty' AS check_name,
       IF(COUNT(*) = 0, 1, 0) AS bad_rows,
       'fct_delivery_performance has no rows at all' AS description
FROM olist_marts.fct_delivery_performance

UNION ALL
SELECT 'fct_duplicate_order_id',
       COUNT(*) - COUNT(DISTINCT order_id),
       'order_id must be unique — the grain is one row per delivered order'
FROM olist_marts.fct_delivery_performance

UNION ALL
SELECT 'fct_null_key',
       COUNTIF(order_id IS NULL OR seller_id IS NULL OR order_date IS NULL),
       'keys and the partition column must never be NULL'
FROM olist_marts.fct_delivery_performance

UNION ALL
SELECT 'order_month_mismatch',
       COUNTIF(order_month IS NULL
               OR order_month <> CAST(FORMAT_DATE('%Y%m', order_date) AS INT64)),
       'order_month is the range-partition key — it must always agree with order_date'
FROM olist_marts.fct_delivery_performance

-- referential: every fact row points at a real seller
UNION ALL
SELECT 'fct_orphan_seller',
       COUNTIF(d.seller_id IS NULL),
       'seller_id in the fact has no matching row in dim_seller'
FROM olist_marts.fct_delivery_performance f
LEFT JOIN olist_marts.dim_seller d ON d.seller_id = f.seller_id

-- business rules: values that cannot be true
UNION ALL
SELECT 'negative_money',
       COUNTIF(order_value < 0 OR freight_value < 0),
       'order value and freight cannot be negative'
FROM olist_marts.fct_delivery_performance

UNION ALL
SELECT 'delivered_before_purchase',
       COUNTIF(delivered_date < order_date),
       'an order cannot be delivered before it was placed'
FROM olist_marts.fct_delivery_performance

UNION ALL
SELECT 'null_late_flag',
       COUNTIF(is_late IS NULL OR late_days IS NULL),
       'is_late drives every headline number — it must always be computable'
FROM olist_marts.fct_delivery_performance

UNION ALL
SELECT 'implausible_delivery_days',
       COUNTIF(delivery_days < 0 OR delivery_days > 365),
       'delivery time outside 0–365 days means a broken timestamp, not a slow courier'
FROM olist_marts.fct_delivery_performance

-- dimension sanity
UNION ALL
SELECT 'dim_duplicate_seller',
       COUNT(*) - COUNT(DISTINCT seller_id),
       'dim_seller is one row per seller'
FROM olist_marts.dim_seller

UNION ALL
SELECT 'on_time_rate_out_of_range',
       COUNTIF(on_time_rate < 0 OR on_time_rate > 1),
       'a rate outside 0–1 means the ratio is wrong'
FROM olist_marts.dim_seller

-- reconciliation: the dimension must add back up to the fact
UNION ALL
SELECT 'dim_order_count_mismatch',
       IF((SELECT SUM(delivered_orders) FROM olist_marts.dim_seller)
          = (SELECT COUNT(*) FROM olist_marts.fct_delivery_performance), 0, 1),
       'orders summed across dim_seller must equal rows in the fact table'
;

SELECT
  check_name,
  bad_rows,
  IF(bad_rows = 0, 'PASS', 'FAIL') AS status,
  description
FROM checks
ORDER BY bad_rows DESC, check_name;

ASSERT (SELECT COALESCE(SUM(bad_rows), 0) FROM checks) = 0
  AS 'data quality checks failed — read the result table above for which check and how many rows';
