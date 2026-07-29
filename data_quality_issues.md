# Data Quality Issues Found & Handling

Source: `data/order_events.csv`, `data/order_items.csv`, `data/products.csv`, `data/stores.csv`.
Every item below is implemented in `sql/01_current_orders.sql`, `sql/02_clean_order_items.sql`,
and `sql/03_revenue_may2024.sql`, and verified against the raw CSVs (originally via
pandas; the Q3a/Q3b fix in item #4 was verified directly by running the SQL through DuckDB).

## order_events.csv

1. **`order_status` has 8 raw string variants for 4 logical statuses**
   (`pending`, `completed`/`Completed`/`COMPLETED`/`completed `/`  completed`,
   `refunded`, `voided`). Handling: `TRIM(LOWER(order_status))` applied once,
   in `01_current_orders.sql`, and reused everywhere downstream. Never compare
   raw `order_status` directly.

2. **`event_ts` has two formats**: 427 rows `YYYY-MM-DD HH:MM:SS`, 3 rows
   (O1026, O1027, O1028 — each row's op='c' / event_seq=1 event) as
   `MM/DD/YYYY HH:MM`. Handling: `TRY_STRPTIME` fallback chain trying both
   formats. A naive single-format parser silently drops/nulls these 3 rows'
   create timestamps, undercounting May-2024 creates (191 instead of 194) —
   verified this bug reproduces if the fallback is omitted, and confirmed our
   query returns the correct 194.

3. **"Latest event" must use `event_seq`, not `event_ts`.** event_ts is
   explicitly called out as unreliable/out-of-order; event_seq increments per
   order per the assignment's column description. Handling: latest event =
   `ROW_NUMBER() ... ORDER BY event_seq DESC`, never ORDER BY event_ts.

4. **8 of 210 orders have their latest event = delete (`op='d'`).** These are
   kept as one row each in the current-state table (210 rows total, not 202).
   `current_status` for these rows is always set to the literal string
   `'deleted'`, **unconditionally** — not derived from the raw `order_status`
   column on the delete row.

   **Bug found and fixed:** an earlier version of this logic only forced
   `current_status = 'deleted'` when the delete row's own `order_status` was
   null/blank, otherwise it trusted whatever raw status was on that row. In
   this dataset, all 8 of the 210 delete-latest orders carry a stale
   `order_status = 'completed'` on their delete row (a data-entry artifact —
   the status field apparently isn't cleared/updated on delete). Under the
   old conditional logic, `current_status` resolved to `'completed'` for all
   8 of them, so they were NOT falling out of scope — they leaked directly
   into the May-2024 "completed" revenue totals in `03_revenue_may2024.sql`,
   inflating Q3a/Q3b. Fixed by making the `CASE WHEN le.op = 'd' THEN
   'deleted' ...` branch unconditional in `01_current_orders.sql`, so deleted
   orders can never resolve to `'completed'` regardless of the raw column
   value. `03_revenue_may2024.sql` joins `current_orders` directly rather
   than re-deriving this logic, so the fix only ever has to live in one
   place. Verified: exactly 8 delete-latest orders had
   `order_status='completed'` pre-fix; Q3a total dropped from $27,174.68 to
   $26,086.52 after the fix.

5. **"Order belongs to the month of its create event"** — the month must come
   from the `op='c'` row (== `event_seq=1`, confirmed always true in this
   data), not from `MAX(event_ts)` or the current/latest status's timestamp.
   Handling: separate `create_event` CTE joined back in, used only for
   `create_month`, kept distinct from `latest_event` used for `current_status`.

## order_items.csv

6. **1 orphan `product_id` = 'P999'** (order O1011, item I5530), not present
   in `products.csv`. DECISION: kept the line item (it represents real
   quantity/price/revenue on a real order — dropping it would silently
   understate that order's total with no stated business reason) and
   `LEFT JOIN`ed to products, `COALESCE`ing category to `'Uncategorized'`.
   Flagged via an `is_orphan_product` boolean so a reviewer can filter it out
   if the alternative interpretation (exclude orphan-product lines) is
   preferred instead.

7. **`unit_price` has a literal `'$'` prefix in 5 rows** (e.g. `'$34.41'`),
   stored as text. Handling: `REPLACE(unit_price, '$', '')` before `CAST` to
   DOUBLE, applied to all rows (harmless no-op on rows without the prefix).

8. **`discount_amount` is NULL in 381 of 530 rows.** Handling:
   `COALESCE(discount_amount, 0)`. Left un-coalesced, NULL propagates through
   `quantity * unit_price - discount_amount` and would silently null out net
   revenue for 72% of line items — this is the single highest-impact fix in
   the whole assignment if missed.

9. **Known bad-value rows, all on order O1019:**
   - `I5041`: `unit_price = 0` -> net = 0. Kept (flagged via `has_zero_price`);
     a $0 line item could be a legitimate promo/comp item, and there's no
     stated rule to exclude free items.
   - `I5042`: `quantity = 0` -> net = 0 regardless of price. Kept (flagged via
     `has_zero_qty`); contributes nothing to revenue by construction, so
     keeping vs. dropping it is revenue-neutral, but it's surfaced as a flag
     since it's still a likely data-entry bug worth a human look.
   - `I5043`: `unit_price = -5.0`, `quantity = 3` -> net = -15.0. Kept AS
     COMPUTED (flagged via `has_negative_price`), not clipped to 0 and not
     excluded. Negative unit_price is implausible as a "price" but could
     represent a return/adjustment; silently clipping or excluding would be
     its own unstated assumption. Flag lets whoever owns this data decide.

10. **Duplicate line items**: two order/product pairs are identical on every
    business column (`order_id, product_id, quantity, unit_price,
    discount_amount`) across two different `order_item_id`s:
    - O1094 / P008: I5246 vs I5249
    - O1142 / P026: I5357 vs I5358

    DECISION: treated as true duplicates (not two legitimately separate line
    items that happen to share values) and deduped, keeping the
    lowest/first-seen `order_item_id`. Other repeated `(order_id, product_id)`
    pairs found in the data (e.g. O1030/P018, O1082/P024, O1146/P023,
    O1162/P011, O1204/P026, and O1019/P021 — the last being the
    quantity/price bad-data rows above) differ in quantity, unit_price, and/or
    discount_amount and were kept as separate legitimate line items — only
    exact full-row (business-column) matches were deduped.

## products.csv / stores.csv

11. **Inactive products (`is_active = false`) still appear in May 2024
    completed-order line items** (50 line items / $3,185.94 — re-verified
    directly in DuckDB with `is_active = false` as a boolean comparison, which
    correctly excludes both truly-active products AND the orphan `P999` row,
    which has no `is_active` value at all rather than `false`; earlier passes
    of this same check reported slightly different counts, traced to
    inconsistent handling of that orphan row and/or string- vs boolean-typed
    comparisons — this number is the reconciled, authoritative one).
    DECISION: NOT excluded. The assignment's revenue questions only filter on
    order status + create month; product active/inactive is an unrelated
    attribute, and excluding these would be an unrequested interpretation.
    Flagged as a comment in `03_revenue_may2024.sql` — if the intended report
    is meant to reflect only currently-sellable inventory, that's a follow-up
    question for stakeholders, not a silent default.

12. No orphan `order_id`s found in `order_items.csv` (all 530 rows reference
    a valid order_id present in `order_events.csv`).

13. No fully-duplicate rows (all columns identical, including
    `order_item_id`) found in `order_items.csv`.
