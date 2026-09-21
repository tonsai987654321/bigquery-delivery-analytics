-- 07_bi_checks.sql — assert the optimized copy and the BI views before a
-- dashboard is pointed at them.
--
-- Run (after 04 and 06):
--   bq --location=US query --use_legacy_sql=false < sql/07_bi_checks.sql
--
-- 03_quality_checks.sql gates the marts. This one gates everything built on top
-- of them, which is where a dashboard can start showing confident wrong numbers:
-- an optimized copy that silently lost rows, or an aggregate view that no longer
-- adds back up to its source.

CREATE TEMP TABLE bi_checks AS

-- the optimized copy must be the same data, not merely a table of the same shape
SELECT 'opt_row_count_mismatch' AS check_name,
       IF((SELECT COUNT(*) FROM olist_marts.fct_delivery_performance)
          = (SELECT COUNT(*) FROM olist_marts.fct_delivery_performance_opt), 0, 1) AS bad_rows,
       'fct_delivery_performance_opt must hold exactly the rows of its source' AS description

UNION ALL
SELECT 'opt_on_time_rate_drift',
       IF(ABS((SELECT AVG(IF(is_late, 0, 1)) FROM olist_marts.fct_delivery_performance)
            - (SELECT AVG(IF(is_late, 0, 1)) FROM olist_marts.fct_delivery_performance_opt))
          > 0.00005, 1, 0),
       'the headline metric must be identical in both layouts'

-- aggregate views must add back up to the detail they summarise
UNION ALL
SELECT 'bi_orders_row_mismatch',
       IF((SELECT COUNT(*) FROM olist_marts.vw_bi_orders)
          = (SELECT COUNT(*) FROM olist_marts.fct_delivery_performance_opt), 0, 1),
       'vw_bi_orders is a pass-through — one row per order, no filtering'

UNION ALL
SELECT 'bi_monthly_order_mismatch',
       IF((SELECT SUM(orders) FROM olist_marts.vw_bi_monthly)
          = (SELECT COUNT(*) FROM olist_marts.fct_delivery_performance_opt), 0, 1),
       'orders summed across vw_bi_monthly must equal the fact row count'

UNION ALL
SELECT 'bi_state_order_mismatch',
       IF((SELECT SUM(orders) FROM olist_marts.vw_bi_by_state)
          = (SELECT COUNT(*) FROM olist_marts.fct_delivery_performance_opt), 0, 1),
       'orders summed across vw_bi_by_state must equal the fact row count'

-- fields the dashboard binds to directly
UNION ALL
SELECT 'bi_month_start_mismatch',
       (SELECT COUNTIF(month_start IS NULL
                       OR FORMAT_DATE('%Y%m', month_start) <> CAST(order_month AS STRING))
        FROM olist_marts.vw_bi_monthly),
       'month_start is the time axis — it must round-trip back to order_month'

UNION ALL
SELECT 'bi_region_code_malformed',
       (SELECT COUNTIF(NOT REGEXP_CONTAINS(customer_region_code, r'^BR-[A-Z]{2}$'))
        FROM olist_marts.vw_bi_by_state),
       'a map resolves customer_region_code as ISO 3166-2, so it must look like BR-SP'

UNION ALL
SELECT 'bi_on_time_rate_out_of_range',
       (SELECT COUNTIF(on_time_rate < 0 OR on_time_rate > 1) FROM olist_marts.vw_bi_monthly)
     + (SELECT COUNTIF(on_time_rate < 0 OR on_time_rate > 1) FROM olist_marts.vw_bi_by_state),
       'every rate a chart plots must sit between 0 and 1'

-- the leaderboard floor is a stated rule, so enforce it
UNION ALL
SELECT 'leaderboard_below_floor',
       (SELECT COUNTIF(delivered_orders < 20) FROM olist_marts.vw_bi_seller_leaderboard),
       'the leaderboard excludes sellers under 20 delivered orders'
;

SELECT
  check_name,
  bad_rows,
  IF(bad_rows = 0, 'PASS', 'FAIL') AS status,
  description
FROM bi_checks
ORDER BY bad_rows DESC, check_name;

ASSERT (SELECT COALESCE(SUM(bad_rows), 0) FROM bi_checks) = 0
  AS 'BI layer checks failed — read the result table above for which check and how many rows';
