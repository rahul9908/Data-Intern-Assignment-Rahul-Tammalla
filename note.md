# Take-Home Note

## Approach and assumptions

Current order state comes from each order's latest event by `event_seq`, not `event_ts` (that one had mixed formats, see below). Deletes get represented as a real `'deleted'` status instead of being dropped from the table entirely.

Two things in the wording I took literally: "an order belongs to the month of its create event" means the `op='c'` row's timestamp specifically, not any other event on the order. And "the category that drove the most" revenue means top-1 per store, four separate answers, not one global winner.

Ran everything against the raw CSVs in DuckDB and checked it against numbers I recomputed by hand rather than just trusting the query looked right.

## Data issues found and how I handled them

- `order_status` had 8 raw string variants for 4 real values (case/whitespace stuff). Normalized with `TRIM(LOWER())`.
- `event_ts` had two formats: 427 rows standard, 3 rows (O1026-O1028) as `MM/DD/YYYY HH:MM`. A single-format parser silently undercounts May-2024 orders by 3, so used a fallback that tries both.
- `discount_amount` was null on 72% of rows (381/530). Coalesced to 0, a null there would've silently zeroed out net revenue for most line items.
- `unit_price` had a literal `$` on 5 rows, stripped before casting.
- One order-item pointed at a product_id (`P999`) with no match in `products.csv`. Kept it, bucketed as `'Uncategorized'` instead of silently dropping via an inner join.
- Three line items on one order: zero quantity, zero price, negative price. Kept as-is and flagged, none of them is clearly wrong versus a legit edge case like a comp item or a return adjustment.
- Two line items were exact duplicates of another row, deduped, kept the first one.
- Inactive products (`is_active = false`) still generated $3,185.94 of May 2024 completed revenue (50 line items). Kept in since the assignment only asked to filter by status and month. Flagged this as a question for the business rather than deciding it myself.

### The bug I found and fixed

8 orders whose latest event was a delete still had a stale `order_status = 'completed'` sitting on that delete row, left over from before the delete happened. My first version of the SQL trusted that value, so those 8 orders quietly counted as completed revenue.

Fixed it by making the delete case unconditional, an order whose latest event is a delete always resolves to `'deleted'` regardless of the raw status column.

Impact: total May 2024 net revenue went from $27,174.68 to $26,086.52, and store S3's top category flipped from Concentrates to Accessories.

## What I'd do next with more time

Add real automated checks (every order should have exactly one create event, no null discount should ever slip into a revenue total unflagged), and get an actual answer on whether inactive-product revenue should count.

## AI tools used

Used Claude Code, and deliberately kept the writing and the verification as two separate passes so the pass that wrote the SQL wasn't also the only thing checking it.

That's what caught the bug above. A second, independent pass checked the SQL against the raw CSVs and found that the first delete-handling logic was conditional (only overrode status when the raw value was blank), which let 8 deleted orders leak $1,088.16 into completed revenue and changed S3's top category. Checked it against the raw data myself and fixed it before finalizing.

## Scaling "current orders" to hundreds of millions of rows

Wouldn't rebuild the whole current-orders table from scratch every run. Keep it as a persistent table keyed on `order_id`, plus a watermark tracking the last event processed. Each run, pull only events newer than the watermark and upsert by `order_id`, recomputing only the orders that actually changed, not a full scan.

I'd track the watermark by ingestion time, not just `event_ts`, since the mixed-format timestamp issue already showed `event_ts` alone can't be fully trusted for ordering. That also handles late-arriving updates to old orders, they get picked up whenever they actually show up. Partitioning the event log by `order_id` or ingestion date keeps the incremental pull cheap as things grow.
