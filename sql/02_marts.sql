-- 02_marts.sql — build the analytics layer on top of olist_raw.
--
-- Run:
--   bq --location=US query --use_legacy_sql=false < sql/02_marts.sql
--
-- Every statement is CREATE OR REPLACE, so re-running rebuilds the layer from
-- raw without leaving half-old tables behind.
--
-- Grain:
--   stg_orders                 1 row per order        (typed, unfiltered)
--   fct_delivery_performance   1 row per delivered order
--                              carries order_month (YYYYMM) as the range-partition key
--   dim_seller                 1 row per seller

CREATE SCHEMA IF NOT EXISTS olist_marts;

-- ── staging ──────────────────────────────────────────────────────────────────
-- SAFE_CAST rather than a bare CAST: the load autodetects types, and if a column
-- ever arrives as STRING the view still builds and the bad value lands as NULL
-- where 03_quality_checks.sql will catch it.
CREATE OR REPLACE VIEW olist_marts.stg_orders AS
SELECT
  order_id,
  customer_id,
  order_status,
  SAFE_CAST(order_purchase_timestamp      AS TIMESTAMP) AS purchased_at,
  SAFE_CAST(order_delivered_customer_date AS TIMESTAMP) AS delivered_at,
  SAFE_CAST(order_estimated_delivery_date AS TIMESTAMP) AS estimated_at
FROM olist_raw.orders;

CREATE OR REPLACE VIEW olist_marts.stg_order_items AS
SELECT
  order_id,
  order_item_id,
  product_id,
  seller_id,
  SAFE_CAST(price         AS NUMERIC) AS price,
  SAFE_CAST(freight_value AS NUMERIC) AS freight_value
FROM olist_raw.order_items;

-- ── fact: delivery performance ───────────────────────────────────────────────
-- One row per delivered order. An order with several items from several sellers
-- is attributed to the seller holding the most items on it, so the grain stays
-- one-row-per-order and a join never fans the numbers out.
CREATE OR REPLACE TABLE olist_marts.fct_delivery_performance AS
WITH items_per_order AS (
  SELECT
    order_id,
    seller_id,
    COUNT(*)           AS item_count,
    SUM(price)         AS order_value,
    SUM(freight_value) AS freight_value
  FROM olist_marts.stg_order_items
  GROUP BY order_id, seller_id
),
primary_seller AS (
  SELECT order_id, seller_id
  FROM (
    SELECT
      order_id,
      seller_id,
      ROW_NUMBER() OVER (
        PARTITION BY order_id
        ORDER BY item_count DESC, seller_id       -- seller_id breaks ties deterministically
      ) AS rn
    FROM items_per_order
  )
  WHERE rn = 1
),
order_totals AS (
  SELECT
    order_id,
    SUM(item_count)    AS item_count,
    SUM(order_value)   AS order_value,
    SUM(freight_value) AS freight_value
  FROM items_per_order
  GROUP BY order_id
)
SELECT
  o.order_id,
  DATE(o.purchased_at)                                   AS order_date,
  -- YYYYMM as an INT so the table can be RANGE-partitioned; see 04_partition_cluster.sql
  CAST(FORMAT_DATE('%Y%m', DATE(o.purchased_at)) AS INT64) AS order_month,
  ps.seller_id,
  s.seller_state,
  c.customer_state,
  DATE(o.delivered_at)                                   AS delivered_date,
  DATE(o.estimated_at)                                   AS estimated_date,
  DATE_DIFF(DATE(o.delivered_at), DATE(o.estimated_at), DAY) AS late_days,
  DATE_DIFF(DATE(o.delivered_at), DATE(o.estimated_at), DAY) > 0 AS is_late,
  DATE_DIFF(DATE(o.delivered_at), DATE(o.purchased_at), DAY) AS delivery_days,
  t.item_count,
  t.order_value,
  t.freight_value
FROM olist_marts.stg_orders o
JOIN primary_seller  ps ON ps.order_id = o.order_id
JOIN order_totals    t  ON t.order_id  = o.order_id
JOIN olist_raw.customers c ON c.customer_id = o.customer_id
JOIN olist_raw.sellers   s ON s.seller_id  = ps.seller_id
WHERE o.order_status = 'delivered'
  AND o.delivered_at IS NOT NULL
  AND o.estimated_at IS NOT NULL
  AND o.purchased_at IS NOT NULL;

-- ── dimension: seller ────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE olist_marts.dim_seller AS
SELECT
  f.seller_id,
  ANY_VALUE(f.seller_state)                              AS seller_state,
  COUNT(*)                                               AS delivered_orders,
  ROUND(1 - SAFE_DIVIDE(COUNTIF(f.is_late), COUNT(*)), 4) AS on_time_rate,
  ROUND(AVG(f.delivery_days), 2)                         AS avg_delivery_days,
  ROUND(AVG(f.freight_value), 2)                         AS avg_freight_value,
  MIN(f.order_date)                                      AS first_order_date,
  MAX(f.order_date)                                      AS last_order_date
FROM olist_marts.fct_delivery_performance f
GROUP BY f.seller_id;
