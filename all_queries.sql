-- ============================================================
-- How to run this file
-- ============================================================
-- In cmd/PowerShell:
--   cd "C:\Users\rahul\Documents\Data Intern"
--   duckdb treez.db
--
-- Then inside the DuckDB prompt, either paste blocks from this file directly,
-- or run the whole file at once with:
--   .read all_queries.sql
--
-- To exit when done:
--   .quit
--
-- Note: treez.db already has every table below built and saved. Re-running
-- CREATE TABLE on a table that already exists will error ("table already
-- exists") -- that's expected if you're just re-checking results, not
-- rebuilding from scratch. To rebuild from scratch instead, open a fresh
-- database file (e.g. `duckdb treez_fresh.db`) and run this file there.

-- ============================================================
-- Load raw CSVs
-- ============================================================
CREATE TABLE order_events AS SELECT * FROM 'data/order_events.csv';
CREATE TABLE order_items AS SELECT * FROM 'data/order_items.csv';
CREATE TABLE products AS SELECT * FROM 'data/products.csv';
CREATE TABLE stores AS SELECT * FROM 'data/stores.csv';

-- Check raw counts (430, 530, 28, 4)
SELECT
  (SELECT COUNT(*) FROM order_events) AS order_events_count,
  (SELECT COUNT(*) FROM order_items)  AS order_items_count,
  (SELECT COUNT(*) FROM products)     AS products_count,
  (SELECT COUNT(*) FROM stores)       AS stores_count;


-- ============================================================
-- Deliverable 1: current_orders (one row per order)
-- ============================================================
CREATE TABLE current_orders AS
WITH parsed_events AS (
    SELECT
        order_id, store_id, customer_id, event_seq, op,
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
)
SELECT
    le.order_id, le.store_id, le.customer_id,
    le.event_seq AS latest_event_seq, le.op AS latest_op,
    CASE WHEN le.op = 'd' THEN 'deleted' ELSE le.status_norm END AS current_status,
    le.event_ts_parsed AS latest_event_ts,
    ce.create_ts,
    DATE_TRUNC('month', ce.create_ts) AS create_month
FROM latest_event le
LEFT JOIN create_event ce USING (order_id)
ORDER BY le.order_id;

-- Check (210 rows, one per order)
SELECT COUNT(*) FROM current_orders;
SELECT * FROM current_orders WHERE current_status = 'deleted';   -- the 8 deleted orders
SELECT * FROM current_orders LIMIT 10;


-- ============================================================
-- Deliverable 2: clean_order_items (cleaned line items)
-- ============================================================
CREATE TABLE clean_order_items AS
WITH cleaned AS (
    SELECT
        oi.order_item_id, oi.order_id, oi.product_id, oi.quantity,
        CAST(REPLACE(oi.unit_price, '$', '') AS DOUBLE) AS unit_price,
        COALESCE(oi.discount_amount, 0) AS discount_amount,
        (oi.quantity = 0) AS has_zero_qty,
        (CAST(REPLACE(oi.unit_price, '$', '') AS DOUBLE) = 0) AS has_zero_price,
        (CAST(REPLACE(oi.unit_price, '$', '') AS DOUBLE) < 0) AS has_negative_price,
        (p.product_id IS NULL) AS is_orphan_product,
        COALESCE(p.category, 'Uncategorized') AS category,
        p.is_active,
        ROW_NUMBER() OVER (
            PARTITION BY oi.order_id, oi.product_id, oi.quantity,
                         CAST(REPLACE(oi.unit_price, '$', '') AS DOUBLE),
                         COALESCE(oi.discount_amount, 0)
            ORDER BY oi.order_item_id
        ) AS dup_rn
    FROM order_items oi
    LEFT JOIN products p ON p.product_id = oi.product_id
)
SELECT
    order_item_id, order_id, product_id, quantity, unit_price, discount_amount,
    category, is_active, is_orphan_product, has_zero_qty, has_zero_price, has_negative_price,
    (quantity * unit_price - discount_amount) AS net_revenue
FROM cleaned
WHERE dup_rn = 1
ORDER BY order_id, order_item_id;

-- Check (528 rows, 530 raw minus 2 exact duplicates)
SELECT COUNT(*) FROM clean_order_items;
SELECT * FROM clean_order_items
WHERE has_zero_qty OR has_zero_price OR has_negative_price OR is_orphan_product;
SELECT * FROM clean_order_items LIMIT 10;


-- ============================================================
-- Deliverable 3a: q3a_revenue_per_store (net revenue per store, May 2024)
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
)
SELECT store_id, SUM(net_revenue) AS net_revenue_may2024
FROM scoped_may2024_completed
GROUP BY store_id
ORDER BY store_id;

-- Check (S1 4931.07, S2 5441.48, S3 7123.14, S4 8590.83)
SELECT * FROM q3a_revenue_per_store;


-- ============================================================
-- Deliverable 3b: q3b_top_category_per_store (top category per store, May 2024)
-- ============================================================
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

-- Check (S1 Topicals, S2 Concentrates, S3 Accessories, S4 Vapes)
SELECT * FROM q3b_top_category_per_store;


-- ============================================================
-- Bonus: reproduce the pre-fix buggy revenue total for comparison
-- (trusts raw order_status on delete rows instead of forcing 'deleted')
-- ============================================================
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
buggy_current_orders AS (
    SELECT
        le.order_id,
        le.store_id,
        le.status_norm AS current_status,   -- BUG: no override for op='d'
        DATE_TRUNC('month', ce.create_ts) AS create_month
    FROM latest_event le
    LEFT JOIN create_event ce USING (order_id)
),
clean_items_tmp AS (
    SELECT
        oi.order_id, oi.product_id, oi.quantity,
        CAST(REPLACE(oi.unit_price, '$', '') AS DOUBLE) AS unit_price,
        COALESCE(oi.discount_amount, 0) AS discount_amount,
        ROW_NUMBER() OVER (
            PARTITION BY oi.order_id, oi.product_id, oi.quantity,
                         CAST(REPLACE(oi.unit_price, '$', '') AS DOUBLE),
                         COALESCE(oi.discount_amount, 0)
            ORDER BY oi.order_item_id
        ) AS dup_rn
    FROM order_items oi
)
SELECT co.store_id, SUM(ci.quantity * ci.unit_price - ci.discount_amount) AS buggy_revenue
FROM clean_items_tmp ci
JOIN buggy_current_orders co ON co.order_id = ci.order_id
WHERE ci.dup_rn = 1
  AND co.current_status = 'completed'
  AND co.create_month = DATE '2024-05-01'
GROUP BY co.store_id
ORDER BY co.store_id;
-- Total across all stores should be $27,174.68 (vs. the fixed $26,086.52)
