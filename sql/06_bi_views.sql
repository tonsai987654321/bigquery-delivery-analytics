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

-- ── reference: Brazilian states ─────────────────────────────────────────────
-- Olist stores states as two-letter UF codes. A code like "SP" or "PA" is
-- ambiguous to a map service (PA is also Panama and Pennsylvania), so the BI
-- layer carries the full state name and a "<name>, Brazil" string a geocoder
-- resolves without guessing, plus the IBGE macro-region for regional roll-ups.
CREATE OR REPLACE VIEW olist_marts.ref_br_state AS
SELECT code, name, region
FROM UNNEST([
  STRUCT('AC' AS code, 'Acre' AS name, 'Norte' AS region),
  ('AP', 'Amapá', 'Norte'), ('AM', 'Amazonas', 'Norte'), ('PA', 'Pará', 'Norte'),
  ('RO', 'Rondônia', 'Norte'), ('RR', 'Roraima', 'Norte'), ('TO', 'Tocantins', 'Norte'),
  ('AL', 'Alagoas', 'Nordeste'), ('BA', 'Bahia', 'Nordeste'), ('CE', 'Ceará', 'Nordeste'),
  ('MA', 'Maranhão', 'Nordeste'), ('PB', 'Paraíba', 'Nordeste'), ('PE', 'Pernambuco', 'Nordeste'),
  ('PI', 'Piauí', 'Nordeste'), ('RN', 'Rio Grande do Norte', 'Nordeste'), ('SE', 'Sergipe', 'Nordeste'),
  ('DF', 'Distrito Federal', 'Centro-Oeste'), ('GO', 'Goiás', 'Centro-Oeste'),
  ('MT', 'Mato Grosso', 'Centro-Oeste'), ('MS', 'Mato Grosso do Sul', 'Centro-Oeste'),
  ('ES', 'Espírito Santo', 'Sudeste'), ('MG', 'Minas Gerais', 'Sudeste'),
  ('RJ', 'Rio de Janeiro', 'Sudeste'), ('SP', 'São Paulo', 'Sudeste'),
  ('PR', 'Paraná', 'Sul'), ('RS', 'Rio Grande do Sul', 'Sul'), ('SC', 'Santa Catarina', 'Sul')
]);

-- ── per-order grain: the detail table behind every drill-down ────────────────
CREATE OR REPLACE VIEW olist_marts.vw_bi_orders AS
SELECT
  f.order_id,
  f.order_date,
  f.order_month,
  f.seller_id,
  f.seller_state,
  f.customer_state,
  -- ISO 3166-2 subdivision code, which Looker Studio's geo chart resolves
  CONCAT('BR-', f.customer_state) AS customer_region_code,
  st.name   AS customer_state_name,
  st.region AS customer_region,
  -- unambiguous string for Power BI's map geocoding
  CONCAT(st.name, ', Brazil') AS customer_state_geo,
  f.delivered_date,
  f.estimated_date,
  f.delivery_days,
  f.late_days,
  f.is_late,
  IF(f.is_late, 0, 1)   AS on_time_flag,  -- AVG(on_time_flag) = on-time rate, 0-1
  -- Same fact on a 0-100 scale. Looker Studio's percent format appends '%'
  -- without scaling, so a 0-1 rate renders as "0.93%". Exposing the scaled
  -- column here keeps the dashboard free of calculated fields: every number
  -- on screen is defined in this file. Power BI's Percentage format does
  -- scale, so a Power BI report should average on_time_flag instead.
  IF(f.is_late, 0, 100) AS on_time_pct,   -- AVG(on_time_pct) = on-time rate, 0-100
  f.item_count,
  f.order_value,
  f.freight_value
FROM olist_marts.fct_delivery_performance_opt AS f
LEFT JOIN olist_marts.ref_br_state AS st ON st.code = f.customer_state;

-- ── monthly trend ───────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW olist_marts.vw_bi_monthly AS
SELECT
  order_month,
  -- a real DATE so a time-series chart sorts and spaces the axis correctly
  PARSE_DATE('%Y%m', CAST(order_month AS STRING)) AS month_start,
  COUNT(*)                                 AS orders,
  ROUND(AVG(IF(is_late, 0, 1)), 4)         AS on_time_rate,
  ROUND(AVG(IF(is_late, 0, 100)), 2)       AS on_time_pct,
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
  ROUND(AVG(IF(is_late, 0, 100)), 2)       AS on_time_pct,
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
  ROUND(on_time_rate * 100, 2) AS on_time_pct,   -- same 0-100 twin as the other views
  avg_delivery_days,
  avg_freight_value,
  first_order_date,
  last_order_date
FROM olist_marts.dim_seller
WHERE delivered_orders >= 20;

-- ── calendar: one row per day across the order history ──────────────────────
-- A BI tool needs a continuous date dimension to slice by month and year and
-- to show a month with no orders as a gap rather than silently skipping it.
-- Built here instead of in DAX so the date logic is reviewed with the rest of
-- the SQL. The range derives from the data, so it follows a reload.
CREATE OR REPLACE VIEW olist_marts.vw_bi_calendar AS
SELECT
  d                                   AS date,
  DATE_TRUNC(d, MONTH)                AS month_start,
  EXTRACT(YEAR FROM d)                AS year,
  EXTRACT(MONTH FROM d)               AS month_number,
  FORMAT_DATE('%b %Y', d)             AS month_label,
  CAST(FORMAT_DATE('%Y%m', d) AS INT64) AS order_month
FROM UNNEST(GENERATE_DATE_ARRAY(
  (SELECT DATE_TRUNC(MIN(order_date), MONTH) FROM olist_marts.fct_delivery_performance_opt),
  (SELECT LAST_DAY(MAX(order_date), MONTH) FROM olist_marts.fct_delivery_performance_opt)
)) AS d;
