-- 03_revenue_may2024.sql
-- Deliverable 3: the two May 2024 revenue questions.
--
-- With order state and clean line items both figured out, the last step
-- is scoping revenue down to completed orders created in May 2024, then
-- answering (a) total per store, (b) top category per store. This file is
-- written to stand alone, so the CTE chain from 01 and 02 is re-derived
-- here rather than reused.

-- Setup: assumes order_events, order_items, products, stores already exist
-- (created in 01_current_orders.sql). If running this file standalone:
-- CREATE TABLE order_events AS SELECT * FROM 'data/order_events.csv';
-- CREATE TABLE order_items AS SELECT * FROM 'data/order_items.csv';
-- CREATE TABLE products AS SELECT * FROM 'data/products.csv';

-- Wording issue 1: "an order belongs to the month of its create event", easy
-- to misread as the month of its current/latest status.
--
-- Assumption 6: if an order was created in April but marked completed in
-- May, it still belongs to April. The month always comes from the order's
-- create (op='c') event, never from its latest event.
--
-- Wording issue 2: "the category that drove the most revenue", easy to
-- misread as one single winner across everything.
--
-- Assumption 7: answered per store, four separate answers, not one global
-- winner across all stores combined.

-- ============================================================
-- Q3a: net revenue per store
-- ============================================================
CREATE TABLE q3a_revenue_per_store AS
WITH parsed_events AS (
    SELECT
        order_id, store_id, event_seq, op,
        TRIM(LOWER(order_status)) AS status_norm,
        COALESCE(
            TRY_STRPTIME(event_ts, '%Y-%m-%d %H:%M:%S'),
            TRY_STRPTIME(event_ts, '%m/%d/%Y %H:%M')
        ) AS event_ts_parsed
    FROM order_events
),
latest_event AS (
    SELECT * FROM (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY event_seq DESC) AS rn
        FROM parsed_events
    ) t WHERE rn = 1
),
create_event AS (
    SELECT order_id, event_ts_parsed AS create_ts
    FROM parsed_events WHERE op = 'c'
),
current_orders_tmp AS (
    SELECT
        le.order_id,
        le.store_id,
        -- same unconditional delete-override as 01_current_orders.sql --
        -- see that file for the bug this fixes.
        CASE WHEN le.op = 'd' THEN 'deleted' ELSE le.status_norm END AS current_status,
        DATE_TRUNC('month', ce.create_ts) AS create_month
    FROM latest_event le
    LEFT JOIN create_event ce USING (order_id)
),
clean_items_tmp AS (
    SELECT
        oi.order_id, oi.product_id,
        oi.quantity,
        CAST(REPLACE(oi.unit_price, '$', '') AS DOUBLE) AS unit_price,
        COALESCE(oi.discount_amount, 0) AS discount_amount,
        COALESCE(p.category, 'Uncategorized') AS category,
        ROW_NUMBER() OVER (
            PARTITION BY oi.order_id, oi.product_id, oi.quantity,
                         CAST(REPLACE(oi.unit_price, '$', '') AS DOUBLE),
                         COALESCE(oi.discount_amount, 0)
            ORDER BY oi.order_item_id
        ) AS dup_rn
    FROM order_items oi
    LEFT JOIN products p ON p.product_id = oi.product_id
),
scoped_may2024_completed AS (
    -- This is where both wording assumptions become real filters:
    -- current_status = 'completed' and create_month = May 2024.
    SELECT
        co.store_id,
        ci.category,
        (ci.quantity * ci.unit_price - ci.discount_amount) AS net_revenue
    FROM clean_items_tmp ci
    JOIN current_orders_tmp co ON co.order_id = ci.order_id
    WHERE ci.dup_rn = 1
      AND co.current_status = 'completed'
      AND co.create_month = DATE '2024-05-01'
)
SELECT store_id, SUM(net_revenue) AS net_revenue_may2024
FROM scoped_may2024_completed
GROUP BY store_id
ORDER BY store_id;

-- Check: S1 4931.07, S2 5441.48, S3 7123.14, S4 8590.83 (total 26,086.52)
SELECT * FROM q3a_revenue_per_store;

-- ============================================================
-- Q3b: top category per store
-- ============================================================
-- Same filtering as Q3a, but grouped by (store_id, category) instead of
-- just store_id, then ranked within each store so only the single
-- best-performing category per store survives (RANK() PARTITION BY
-- store_id, not a global top-N -- exactly one row per store expected).
CREATE TABLE q3b_top_category_per_store AS
WITH parsed_events AS (
    SELECT
        order_id, store_id, event_seq, op,
        TRIM(LOWER(order_status)) AS status_norm,
        COALESCE(
            TRY_STRPTIME(event_ts, '%Y-%m-%d %H:%M:%S'),
            TRY_STRPTIME(event_ts, '%m/%d/%Y %H:%M')
        ) AS event_ts_parsed
    FROM order_events
),
latest_event AS (
    SELECT * FROM (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY event_seq DESC) AS rn
        FROM parsed_events
    ) t WHERE rn = 1
),
create_event AS (
    SELECT order_id, event_ts_parsed AS create_ts
    FROM parsed_events WHERE op = 'c'
),
current_orders_tmp AS (
    SELECT
        le.order_id,
        le.store_id,
        CASE WHEN le.op = 'd' THEN 'deleted' ELSE le.status_norm END AS current_status,
        DATE_TRUNC('month', ce.create_ts) AS create_month
    FROM latest_event le
    LEFT JOIN create_event ce USING (order_id)
),
clean_items_tmp AS (
    SELECT
        oi.order_id, oi.product_id,
        oi.quantity,
        CAST(REPLACE(oi.unit_price, '$', '') AS DOUBLE) AS unit_price,
        COALESCE(oi.discount_amount, 0) AS discount_amount,
        COALESCE(p.category, 'Uncategorized') AS category,
        ROW_NUMBER() OVER (
            PARTITION BY oi.order_id, oi.product_id, oi.quantity,
                         CAST(REPLACE(oi.unit_price, '$', '') AS DOUBLE),
                         COALESCE(oi.discount_amount, 0)
            ORDER BY oi.order_item_id
        ) AS dup_rn
    FROM order_items oi
    LEFT JOIN products p ON p.product_id = oi.product_id
),
scoped_may2024_completed AS (
    SELECT
        co.store_id,
        ci.category,
        (ci.quantity * ci.unit_price - ci.discount_amount) AS net_revenue
    FROM clean_items_tmp ci
    JOIN current_orders_tmp co ON co.order_id = ci.order_id
    WHERE ci.dup_rn = 1
      AND co.current_status = 'completed'
      AND co.create_month = DATE '2024-05-01'
),
store_category AS (
    SELECT store_id, category, SUM(net_revenue) AS category_revenue
    FROM scoped_may2024_completed
    GROUP BY store_id, category
),
ranked AS (
    SELECT *,
           RANK() OVER (PARTITION BY store_id ORDER BY category_revenue DESC) AS rnk
    FROM store_category
)
SELECT store_id, category, category_revenue
FROM ranked
WHERE rnk = 1
ORDER BY store_id;

-- Check: S1 Topicals, S2 Concentrates, S3 Accessories, S4 Vapes
SELECT * FROM q3b_top_category_per_store;

-- Inactive products (is_active=false) are NOT excluded from either result
-- above -- the assignment only asked to filter by order status + month,
-- product active/inactive is a separate attribute.
--
-- Assumption 8: leave inactive products in (50 line items / $3,185.94 of
-- the total). Flagged as a question for the business rather than deciding
-- silently.

-- Bug found and fixed: an earlier version of the delete-status logic (see
-- current_orders_tmp above) only forced 'deleted' when the raw status was
-- blank. 8 delete-latest orders carried a stale order_status='completed',
-- so they leaked into these totals. Fixing the override to be
-- unconditional moved the May-2024 total from $27,174.68 down to
-- $26,086.52, and flipped store S3's top category from Concentrates to
-- Accessories.
