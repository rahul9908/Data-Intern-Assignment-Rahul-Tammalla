-- 03_revenue_may2024.sql
-- Deliverable 3: the two May 2024 revenue questions.
--
-- With order state and clean line items both figured out, the last step
-- is scoping revenue down to completed orders created in May 2024, then
-- answering (a) total per store, (b) top category per store. This file
-- reuses the current_orders table (01_current_orders.sql) and the
-- clean_order_items table (02_clean_order_items.sql) directly, rather than
-- re-deriving the same "latest event" / "clean line item" logic again --
-- one shared source of truth for both, no duplicated delete-handling logic
-- to drift out of sync.

-- Setup: run 01_current_orders.sql and 02_clean_order_items.sql first, so
-- current_orders and clean_order_items already exist.

-- Wording issue 1: "an order belongs to the month of its create event", easy
-- to misread as the month of its current/latest status.
--
-- Assumption 6: if an order was created in April but marked completed in
-- May, it still belongs to April. The month always comes from the order's
-- create (op='c') event, never from its latest event. current_orders
-- already carries this as create_month.
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
SELECT
    co.store_id,
    SUM(ci.quantity * ci.unit_price - ci.discount_amount) AS net_revenue_may2024
FROM current_orders co
JOIN clean_order_items ci ON ci.order_id = co.order_id
WHERE co.current_status = 'completed'
  AND co.create_month = DATE '2024-05-01'
GROUP BY co.store_id
ORDER BY co.store_id;

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
WITH store_category AS (
    SELECT
        co.store_id,
        ci.category,
        SUM(ci.quantity * ci.unit_price - ci.discount_amount) AS category_revenue
    FROM current_orders co
    JOIN clean_order_items ci ON ci.order_id = co.order_id
    WHERE co.current_status = 'completed'
      AND co.create_month = DATE '2024-05-01'
    GROUP BY co.store_id, ci.category
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
-- 01_current_orders.sql) only forced 'deleted' when the raw status was
-- blank. 8 delete-latest orders carried a stale order_status='completed',
-- so they leaked into these totals. Fixing the override to be
-- unconditional moved the May-2024 total from $27,174.68 down to
-- $26,086.52, and flipped store S3's top category from Concentrates to
-- Accessories.
