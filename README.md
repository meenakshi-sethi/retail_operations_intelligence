# Retail Operations Intelligence: Sales, Returns & Inventory

**SQL analytics project — PostgreSQL** | [View the interactive report](report.html)

An end-to-end business health analysis of an e-commerce operation: 4.5 years of transaction data (Jan 2020 – Jul 2024) across a 9-table relational schema — orders, payments, shipments, returns, and inventory — turned into the KPIs a leadership team actually needs, plus an automated inventory procedure that keeps stock in sync with sales.

> **Data note:** the dataset is a synthetic, Amazon-like e-commerce dataset (~88,500 records, ~3 MB). It is not real Amazon data.

---

## Executive summary

**What I found:** Electronics generate ~90% of revenue, but the operation leaks money at the edges — a **13% return rate**, **40% of shipments delayed** beyond 3 days, **13% of payments refunded or failed**, and **212 of 898 registered customers (24%) have never placed an order**. 51 products sit below the 10-unit stock threshold.

**Why it matters:** revenue is concentrated in one category while operational friction (returns, delays, payment failures) erodes it — a classic profile where fixing operations beats chasing new sales.

**What I'd recommend:** (1) investigate root causes for the top returned products, (2) renegotiate or rebalance volume away from the worst-performing shipping providers on delay rate, (3) run a reactivation campaign targeting the 212 never-purchased customers, and (4) set up automated restock triggers off the stock-alert view.

---

## Key results (all verified by execution)

| Metric | Value |
|---|---|
| Orders analyzed | 21,629 (Jan 2020 – Jul 2024) |
| Total revenue | ~$12.6M |
| Average order value | ~$583 |
| Return rate | 13.4% of shipments |
| Shipments delayed > 3 days | 40% (8,452 shipments) |
| Payment success / refunded / failed | 84.6% / 13.1% / 2.3% |
| Never-purchased customers | 212 of 898 (24%) |
| Products below stock threshold | 51 |
| Top category share | Electronics — 89.7% of revenue |

---

## What's in this repo

```
├── report.html          Interactive report (open in any browser — self-contained)
├── setup.sql            Schema, indexes, KPI views, hardened stored procedure
├── solutions.sql        19 business questions with verified SQL answers
├── datasets/            9 CSVs (~88,500 records)
└── README.md
```

**Stack:** PostgreSQL (runs as-is on [Supabase](https://supabase.com) — free tier is more than enough). Load the CSVs, run `setup.sql`, then `solutions.sql`.

---

## The three-act story

**1. Clean the data.** Reconciled payment statuses against order statuses, handled nulls contextually (null payment status → "Pending"; null return dates left as-is since most shipments aren't returned), removed duplicates, and derived `total_sale` from quantity × unit price.

**2. Surface the KPIs.** 19 business questions spanning revenue analysis (category contribution, AOV, profit margins), customer analytics (CLTV ranking, segmentation, never-purchased identification), operations (shipping delays by provider, payment success), and inventory (stock alerts, declining products year-over-year).

**3. Automate the fix.** A `add_sales` stored procedure that records a sale and decrements inventory atomically — hardened with `SELECT ... FOR UPDATE` row locking against race conditions, single-warehouse-row updates, and explicit order status. Recurring KPI reporting runs off views (`v_category_revenue`, `v_customer_cltv`, `v_return_rates`, `v_stock_alerts`, `v_shipping_performance`) instead of re-executing 9-table joins.

---

## Query audit — bugs found and fixed

I executed every query and cross-checked results against an independent pandas implementation. Four bugs in the original analysis were found and fixed (each fix is documented inline in `solutions.sql`):

1. **Relative-date queries returned zero rows.** `WHERE order_date >= CURRENT_DATE - 1 year` is empty on stale data (data ends Jul 2024). Fixed by anchoring to `MAX(order_date)`.
2. **Float-noise "declines" in the YoY analysis.** Products with *identical* 2022/2023 revenue passed the `ls > cs` filter by ~1e-12, and the sort order put 0.00% non-declines at the top of the "top decliners" list. Fixed by rounding before comparison and sorting ASC.
3. **"Average delivery time" was not delivery time.** The original computed `AVG(return_date - shipping_date)` — the ship-to-return interval on the 13% of shipments that were returned. There is no delivery date in the data, so I replaced it with delay rate and delivered rate, which the schema supports.
4. **Misleading return-rate rankings.** Products with 1–7 units sold produced "100% return rate" artifacts. Fixed with a minimum sample size (≥ 20 units).

Also solved two business questions the original listed but never answered: **orders pending shipment** and **inactive sellers** (with the same relative-date fix).

---

## Performance notes

Indexes on all join/filter columns are included in `setup.sql` (`orders(order_date)`, `order_items(order_id)`, etc.). At ~88K rows, PostgreSQL's planner often still prefers sequential scans — that is correct optimizer behavior at this scale, verified with `EXPLAIN ANALYZE`. The index benefit emerges as data grows; the methodology (profile → index → re-profile) is the transferable skill.

---

## Skills demonstrated

- Multi-table joins across a 9-table normalized schema
- Window functions (LAG, RANK, DENSE_RANK with partitioning)
- CTEs for multi-step analysis (YoY revenue decline)
- Conditional aggregation (CASE-based KPIs)
- Data quality: null handling, duplicate removal, status reconciliation
- Stored procedures (plpgsql) with row-level locking
- Views as a recurring KPI layer
- Query auditing and root-causing incorrect metrics

---

*Built and verified by Meenakshi Sethi. Dataset: synthetic Amazon-like e-commerce data.*
