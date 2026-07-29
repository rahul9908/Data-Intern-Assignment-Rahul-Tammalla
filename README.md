# Treez Assignment - Rahul Tammalla

This is my submission. Everything's DuckDB SQL, and I actually ran every query against the CSVs in `data/` to check the numbers instead of just trusting the logic looked right.

## Why this role

This assignment confirmed why I am excited about the Data Platform Intern role at Treez. I enjoyed working with DuckDB and messy CDC-style data, but the most valuable part was seeing how easily a transformation can produce a believable but incorrect result. Eight deleted orders still carried an earlier "completed" status, and my first query incorrectly included their revenue. Catching that issue reinforced the kind of data engineering I care about: building models that remain accurate and trustworthy as the data changes.

This role stands out because it focuses on one meaningful production problem: rebuilding the transformation layer into clean bronze, silver, and gold models that refresh faster, cost less, and reliably support analytics and customer-facing dashboards. I already have experience building SQL and ETL pipelines, designing layered models in Snowflake and Redshift, adding validation checks, and improving pipeline performance.

I also use AI tools like Claude to explore solutions and move faster, while independently testing and validating the output. At Treez, I would bring that foundation, contribute carefully reviewed work, and deepen my experience with dbt testing, Dagster, lineage, and production benchmarking. The opportunity to go deep, learn from senior engineers, and help build a dependable data platform is exactly what I am looking for.

## The numbers

**Net revenue per store, May 2024, completed orders:**

| store | net revenue |
|---|---|
| S1 | $4,931.07 |
| S2 | $5,441.48 |
| S3 | $7,123.14 |
| S4 | $8,590.83 |
| **total** | **$26,086.52** |

**Top category per store:**

| store | category | net revenue |
|---|---|---|
| S1 | Topicals | $1,507.57 |
| S2 | Concentrates | $1,349.16 |
| S3 | Accessories | $1,441.80 |
| S4 | Vapes | $1,744.85 |

More detail on both in `results.md`. One assumption baked into these totals: line items from products marked inactive (`is_active = false`) are still included, since the assignment only asked to filter by order status and month, not product activity. That's about $3,185.94 across 50 line items. If Treez wants revenue restricted to currently-sellable inventory, that's a follow-up question rather than something I decided silently.

## What's in here
- `sql/01_current_orders.sql`: rebuilds one current row per order from the event log
- `sql/02_clean_order_items.sql`: cleans up the line items
- `sql/03_revenue_may2024.sql`: the two revenue questions
- `results.md`: the actual numbers
- `data_quality_issues.md`: every messy thing I found in the data and what I did about it
- `stretch_layering.md`: the optional stretch

## My Approach

An order's current state is whatever its latest event says, using `event_seq` to determine "latest," not `event_ts`, since a few timestamps turned out to be in a different format (more on that below). Deleted orders still show up as one row with status `'deleted'` rather than disappearing from the table entirely.

Two places where the wording mattered enough to call out explicitly:
- "An order belongs to the month of its create event" means the month comes from the order's `create` (`op='c'`) event specifically, not from whichever event is currently latest.
- "The category that drove the most revenue" is scoped per store, so each store gets its own top category, four separate answers, not one winner across all stores combined.

The data itself had a bunch of real messiness worth calling out: status values written inconsistently (`completed`, `Completed`, `  completed`, etc.), a handful of timestamps in a different date format than the rest, a large share of null discounts that would've silently zeroed out revenue if left uncoalesced, a stray `$` sitting inside some prices, one line item pointing at a product that doesn't exist in the catalog, a couple of bad rows (zero price, zero quantity, one negative price), and two exact duplicate line items. Every issue I found and exactly how I handled it, including a couple not covered here, is in `data_quality_issues.md`.

The one real bug I caught mid-way: 8 orders that had been deleted still had `order_status = 'completed'` sitting on their delete row, left over from before the delete happened, and my first pass at the query trusted that leftover value instead of overriding it. So those 8 deleted orders were quietly counted as completed revenue. Fixed it by making deletes always resolve to `'deleted'`, regardless of what the raw status column says. That changed the May 2024 total from $27,174.68 to $26,086.52 and flipped store S3's top category from Concentrates to Accessories. Full write-up of the bug and the fix is also in `note.md`, along with my full approach, assumptions, what I'd do next with more time, and my answer to the scaling question.

## AI tools

Used Claude Code, and made a point of not letting the same pass that wrote a query also be the only thing checking it. Ran the writing and the verification separately. That's exactly what caught the delete-status bug above. A second pass checked the SQL against the raw CSVs and found the $1,088.16 that was leaking in from deleted orders, and I verified that myself before fixing it.

## Scaling this up

If this event log never stopped and had hundreds of millions of rows, I wouldn't rebuild the whole current-orders table every run. I'd keep it as a persistent table and track a watermark (last event processed, by ingestion time rather than `event_ts`, since I already found `event_ts` isn't fully reliable for ordering). Each run would just grab events newer than the watermark and upsert them in by order_id, only recomputing the orders that actually changed. Using ingestion time for the watermark instead of event time is also what handles late updates to old orders. They still get picked up whenever they actually show up, no matter how old the order is.

## What I'd do with more time

Add some actual automated checks (every order should have exactly one create event, no null discount should ever sneak into a revenue total unflagged), and get a real answer on whether inactive-product revenue should even count here.
