-- 06_bi_views.sql — the layer a BI tool reads.
--
-- Run:
--   bq --location=US query --use_legacy_sql=false < sql/06_bi_views.sql
--
-- Looker Studio (or Power BI, or anything else) points at these views rather
-- than at the fact table directly, for three reasons:
--
--   1. Metric definitions live in SQL, in this repo, under review — not in a
--      calculated field inside one person's dashboard where nobody can diff it.
--   2. Booleans become 0/1 columns, so "on-time rate" is a plain AVG() that any
--      tool can compute without dialect-specific tricks.
--   3. The dashboard can be rebuilt from scratch against the same contract if
--      the sandbox expires the tables.
--
-- They read from fct_delivery_performance_opt, so a filter on order_month still
-- prunes partitions all the way through the view. Measured, not assumed — the
-- same 3-month filter, same projection:
--
--   through vw_bi_orders (partitioned source)   185,643 bytes
--   against fct_delivery_performance (plain)    868,230 bytes   -> 78.6% less
--
-- which is the same ratio 05_benchmark.sh reports querying the tables directly.
-- A view does not flatten the physical layout underneath it.

-- ── per-order grain: the detail table behind every drill-down ────────────────
CREATE OR REPLACE VIEW olist_marts.vw_bi_orders AS
SELECT
  order_id,
  order_date,
  order_month,
  seller_id,
  seller_state,
  customer_state,
  -- ISO 3166-2 subdivision code, which is what a mapping tool can resolve
  CONCAT('BR-', customer_state) AS customer_region_code,
  delivered_date,
  estimated_date,
  delivery_days,
  late_days,
  is_late,
  IF(is_late, 0, 1) AS on_time_flag,   -- AVG(on_time_flag) = on-time rate
  item_count,
  order_value,
  freight_value
FROM olist_marts.fct_delivery_performance_opt;

-- ── monthly trend ───────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW olist_marts.vw_bi_monthly AS
SELECT
  order_month,
  -- a real DATE so a time-series chart sorts and spaces the axis correctly
  PARSE_DATE('%Y%m', CAST(order_month AS STRING)) AS month_start,
  COUNT(*)                                 AS orders,
  ROUND(AVG(IF(is_late, 0, 1)), 4)         AS on_time_rate,
  ROUND(AVG(delivery_days), 2)             AS avg_delivery_days,
  ROUND(AVG(freight_value), 2)             AS avg_freight_value,
  ROUND(SUM(order_value), 2)               AS order_value
FROM olist_marts.fct_delivery_performance_opt
GROUP BY order_month;

-- ── geography: where the delays and the freight cost sit ────────────────────
CREATE OR REPLACE VIEW olist_marts.vw_bi_by_state AS
SELECT
  customer_state,
  CONCAT('BR-', customer_state)            AS customer_region_code,
  COUNT(*)                                 AS orders,
  ROUND(AVG(IF(is_late, 0, 1)), 4)         AS on_time_rate,
  ROUND(AVG(delivery_days), 2)             AS avg_delivery_days,
  ROUND(AVG(freight_value), 2)             AS avg_freight_value
FROM olist_marts.fct_delivery_performance_opt
GROUP BY customer_state;

-- ── seller leaderboard ──────────────────────────────────────────────────────
-- Sellers with a handful of orders produce 100% on-time rates that mean nothing.
-- The 20-order floor is a judgement call, stated here rather than buried in a
-- dashboard filter, so the number on screen can be traced back to a rule.
CREATE OR REPLACE VIEW olist_marts.vw_bi_seller_leaderboard AS
SELECT
  seller_id,
  seller_state,
  delivered_orders,
  on_time_rate,
  avg_delivery_days,
  avg_freight_value,
  first_order_date,
  last_order_date
FROM olist_marts.dim_seller
WHERE delivered_orders >= 20;
