-- 02_clean_order_items.sql
-- Deliverable 2: clean order_items.csv.
--
-- Once order state was figured out (see 01_current_orders.sql), the next
-- problem was the line items themselves, several real data-quality issues
-- showed up here, each one handled deliberately instead of silently
-- dropped or guessed at.

-- Setup: assumes order_events, order_items, products, stores already exist
-- (created in 01_current_orders.sql). If running this file standalone:
-- CREATE TABLE order_items AS SELECT * FROM 'data/order_items.csv';
-- CREATE TABLE products AS SELECT * FROM 'data/products.csv';

-- Issue 1: unit_price had a literal '$' prefix on 5 rows (e.g. '$34.41'),
-- stored as text. Stripped '$' before casting to a number.
--
-- Issue 2: discount_amount was NULL on 381 of 530 rows. Left alone, NULL
-- propagates through arithmetic (NULL * x = NULL), which would silently
-- drop these rows from any revenue SUM.
--
-- Assumption 3: a missing discount means 0, not "unknown". COALESCE'd to 0.
--
-- Issue 3: one line item (product_id 'P999') references a product that
-- isn't in products.csv.
--
-- Assumption 4: keep the line item, don't drop it, the transaction is real
-- money, dropping it would silently understate that order's total. Labeled
-- 'Uncategorized' via a LEFT JOIN instead of guessed, flagged via
-- is_orphan_product so it's easy to find and re-decide on later.
--
-- Issue 4: a few individually odd rows on order O1019: I5041 has
-- unit_price=0, I5042 has quantity=0, I5043 has unit_price=-5.0.
--
-- Assumption 5: none of these is clearly a data error versus a legitimate
-- edge case (a promo item, a return adjustment), so all three are kept
-- as-is and flagged (has_zero_price, has_zero_qty, has_negative_price)
-- rather than silently clipped or excluded.
--
-- Issue 5: two pairs of rows are exact duplicates (same order, product,
-- quantity, price, discount, just a different order_item_id):
-- (O1094, P008) and (O1142, P026). These get deduplicated, keeping the
-- first-seen order_item_id. Not really a judgment call, they're genuinely
-- identical.

CREATE TABLE clean_order_items AS
WITH cleaned AS (
    SELECT
        oi.order_item_id,
        oi.order_id,
        oi.product_id,
        oi.quantity,
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
    order_item_id,
    order_id,
    product_id,
    quantity,
    unit_price,
    discount_amount,
    category,
    is_active,
    is_orphan_product,
    has_zero_qty,
    has_zero_price,
    has_negative_price,
    (quantity * unit_price - discount_amount) AS net_revenue
FROM cleaned
WHERE dup_rn = 1  -- drops the 2 exact-duplicate rows (I5249, I5358), keeps first-seen
ORDER BY order_id, order_item_id;

-- Check: 528 rows (530 raw minus 2 exact duplicates).
SELECT COUNT(*) FROM clean_order_items;
SELECT * FROM clean_order_items
WHERE has_zero_qty OR has_zero_price OR has_negative_price OR is_orphan_product;
