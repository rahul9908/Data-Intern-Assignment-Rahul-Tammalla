# Stretch: raw → clean → business-ready layers

The three SQL files already implicitly follow this shape (`01` builds current order state, `02` cleans line items, `03` joins both to answer the revenue questions); here's how I'd formalize it as dbt-style layers rather than one-off scripts, since a real pipeline needs these fixes to persist and be re-runnable, not re-derived by hand each time.

**Bronze (raw).** `order_events`, `order_items`, `products`, `stores` loaded as-is, untouched — including every one of the messy rows found here (mixed date formats, `$`-prefixed prices, stale statuses on deleted orders). This layer's only job is being an honest copy of the source; no cleaning happens here, so nothing found downstream can ever be "unrecoverable."

**Silver (clean).** One model per bronze source, each owning exactly one category of fix so the fix lives in exactly one place:
- `stg_current_orders` — one row per order_id, latest event by `event_seq`, `current_status` normalized (`TRIM(LOWER())`) and unconditionally forced to `'deleted'` when the latest event is a delete, `create_month` derived from the `op='c'` row only.
- `stg_order_items` — `$`-stripped and cast `unit_price`, `discount_amount` coalesced to 0, dedup on business key, orphan `product_id` left-joined with `'Uncategorized'` fallback, and flag columns (`has_zero_price`, `has_negative_price`, `is_orphan_product`) preserved rather than silently dropped, so gold-layer consumers can decide whether to include or exclude them.

**Gold (business-ready).** `fct_order_revenue` — one row per (order, line item), joining `stg_current_orders` to `stg_order_items` to `products`/`stores`, with `net_revenue` pre-computed. Q3a/Q3b become simple aggregations over this one table. A BI tool or analyst queries only this layer and never needs to know about `$` prefixes or delete-status bugs.

**Why this matters here specifically:** the delete-status bug reviewer caught existed because an early version of the fix lived in more than one place and could drift out of sync. `03_revenue_may2024.sql` now joins `01`'s and `02`'s tables directly instead of re-deriving that logic, which already removes most of that risk within this take-home. A real dbt setup with bronze/silver/gold layers plus a test like `assert count(current_status='deleted' and current_status='completed') == 0` per order would go one step further and catch that class of bug automatically on every run, not just when a human happens to review it.
