-- 01_current_orders.sql
-- Deliverable 1: reconstruct exactly one current-state row per order.
--
-- order_events.csv is a change log, every order shows up as several rows
-- (a create, some updates, sometimes a delete). The job here is to
-- collapse that history down to one row per order, showing its current
-- status.

-- Setup: load the raw CSVs as tables (run once).
CREATE TABLE order_events AS SELECT * FROM 'data/order_events.csv';
CREATE TABLE order_items AS SELECT * FROM 'data/order_items.csv';
CREATE TABLE products AS SELECT * FROM 'data/products.csv';
CREATE TABLE stores AS SELECT * FROM 'data/stores.csv';

-- Check: 430 events, 530 line items, 28 products, 4 stores
SELECT
  (SELECT COUNT(*) FROM order_events) AS order_events_count,
  (SELECT COUNT(*) FROM order_items)  AS order_items_count,
  (SELECT COUNT(*) FROM products)     AS products_count,
  (SELECT COUNT(*) FROM stores)       AS stores_count;

-- Issue 1: how do you know which row is "latest"? There are two candidates,
-- event_seq (a plain sequence number) and event_ts (a timestamp). They
-- should agree, but 3 rows (O1026/O1027/O1028's create events) turned out
-- to have event_ts in a completely different date format than the rest.
--
-- Assumption 1: trust event_seq, not event_ts, since the assignment itself
-- describes event_seq as "increments per order" -- it's built to be
-- reliable in a way a timestamp isn't.

-- Issue 2: what happens to the 8 orders whose most recent event is a
-- delete? Do they disappear from this table, or stay visible?
--
-- Assumption 2: keep them as one row each, with status forced to 'deleted'.
-- "Derive exactly one current row per order" means every order gets a row,
-- deletion is a status, not a disappearance.

CREATE TABLE current_orders AS
WITH parsed_events AS (
    -- Clean up two things before anything else: normalize inconsistent
    -- status spelling, and parse both event_ts formats so nothing silently
    -- fails or gets miscounted.
    SELECT
        order_id,
        store_id,
        customer_id,
        event_seq,
        op,
        TRIM(LOWER(order_status)) AS status_norm,
        COALESCE(
            TRY_STRPTIME(event_ts, '%Y-%m-%d %H:%M:%S'),
            TRY_STRPTIME(event_ts, '%m/%d/%Y %H:%M')
        ) AS event_ts_parsed
    FROM order_events
),
latest_event AS (
    -- One row per order_id: the row with the max event_seq.
    SELECT *
    FROM (
        SELECT
            *,
            ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY event_seq DESC) AS rn
        FROM parsed_events
    ) t
    WHERE rn = 1
),
create_event AS (
    -- The op='c' row per order (== event_seq = 1), needed separately from
    -- the "latest" row because the May-2024 question later asks for the
    -- month of the CREATE event, not whatever the order's current status is.
    SELECT
        order_id,
        event_ts_parsed AS create_ts
    FROM parsed_events
    WHERE op = 'c'
)
SELECT
    le.order_id,
    le.store_id,
    le.customer_id,
    le.event_seq        AS latest_event_seq,
    le.op                AS latest_op,
    -- The actual bug-fix line: deleted rows ALWAYS resolve to 'deleted',
    -- regardless of the raw order_status on that delete row. 8 of the 210
    -- delete rows carry a stale order_status of 'completed' left over from
    -- before the delete happened (a data-entry artifact) -- an earlier
    -- version of this logic only forced 'deleted' when that raw value was
    -- blank, which let those 8 orders leak into "completed" revenue later.
    -- This override is unconditional on purpose.
    CASE
        WHEN le.op = 'd' THEN 'deleted'
        ELSE le.status_norm
    END AS current_status,
    le.event_ts_parsed  AS latest_event_ts,
    ce.create_ts,
    DATE_TRUNC('month', ce.create_ts) AS create_month
FROM latest_event le
LEFT JOIN create_event ce USING (order_id)
ORDER BY le.order_id;

-- Check: 210 rows, one per order, including the 8 deleted ones.
SELECT COUNT(*) FROM current_orders;
SELECT * FROM current_orders WHERE current_status = 'deleted';
