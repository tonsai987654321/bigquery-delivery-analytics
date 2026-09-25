# Power BI report — build guide

The same warehouse views that feed the Looker Studio report, modelled as a star
schema in Power BI Desktop. Everything below was prepared on the BigQuery side
first, so the report itself only connects, relates and lays out.

Time: about 2–3 hours the first time.

## 0. Before you start

- **Power BI Desktop** — free from the Microsoft Store. Skip the sign-in prompt; a
  report builds and saves without an account.
- **Google account** — sign in to BigQuery as the account that owns
  `bq-scg-portfolio`. If the browser holds several Google accounts, pick that one.
- **Deadline** — the sandbox expires the tables 60 days after they are built
  (`./refresh.sh` prints the current date and pushes it back). Build in
  **Import** mode: the data is copied into the `.pbix`, so the report keeps
  working after the tables are gone. Re-running the SQL chain restores them.

## 1. Connect and import

Home → Get data → More… → search **Google BigQuery** → Connect → sign in.

In the Navigator: `bq-scg-portfolio` → `olist_marts`, tick exactly three objects:

| View | Role in the model | Rows |
|---|---|---:|
| `vw_bi_orders` | fact — one delivered order | 96,470 |
| `vw_bi_calendar` | date dimension — one row per day | 730 |
| `vw_bi_seller_leaderboard` | seller dimension — sellers with 20+ orders | 796 |

Choose **Load** and, if asked, **Import** (not DirectQuery).

If the connector asks for a billing project, choose `bq-scg-portfolio`. The
BigQuery Storage API is already enabled on the project.

## 2. Model

Model view → drag to create two relationships, both **one-to-many, single
direction**:

- `vw_bi_calendar[date]` → `vw_bi_orders[order_date]`
- `vw_bi_seller_leaderboard[seller_id]` → `vw_bi_orders[seller_id]`

Then:

- Select `vw_bi_calendar` → Table tools → **Mark as date table** → `date`.
- Select `vw_bi_calendar[month_label]` → Column tools → **Sort by column** →
  `order_month`, so months sort in time order and not alphabetically.
- Select `vw_bi_orders[customer_state_geo]` → Column tools → Data category →
  **Place**. The value reads "São Paulo, Brazil", which the map resolves without
  confusing PA with Panama or Pennsylvania.

The leaderboard relationship means a seller table built from leaderboard columns
plus order measures responds to the date slicer, while the 20-order rule still
comes from SQL.

## 3. Measures

Create a measure table (Home → Enter data → name it `_Measures`, delete the
column after adding the first measure), then paste each measure from
[`measures.dax`](measures.dax). Set the formats written above each one —
**On-time Rate must be Percentage**, which scales 0.9323 to 93.23% on its own.

## 4. Theme

View → Themes → Browse for themes → [`theme.json`](theme.json). Navy palette,
Segoe UI, matching the rest of the portfolio.

## 5. Layout — one 16:9 page, on a grid

```
┌───────────────────────────────────────────────────────────────┐
│ Olist delivery performance            [Date range] [Region ▾] │
├───────────────┬───────────────┬───────────────┬───────────────┤
│Delivered orders│ On-time rate │ Avg delivery  │ Avg freight   │
│    96,470     │    93.23%     │  12.5 days    │  BRL 22.79    │
├───────────────┴───────────────┴───────────────┴───────────────┤
│  Orders (columns) and on-time rate (line) by month            │
├───────────────────────────────┬───────────────────────────────┤
│  On-time rate by state (bar,  │  Top 10 sellers (table)       │
│  worst first)                 │                               │
└───────────────────────────────┴───────────────────────────────┘
```

| Visual | Fields |
|---|---|
| Slicer | `vw_bi_calendar[date]`, style *Between* |
| Slicer | `vw_bi_orders[customer_region]`, style *Dropdown* |
| 4 × Card | Delivered Orders · On-time Rate · Avg Delivery Days · Avg Freight (BRL) |
| **Line and clustered column chart** | X: `vw_bi_calendar[month_start]` (hierarchy off) · Columns: Delivered Orders · Line: On-time Rate |
| Clustered bar chart | Y: `customer_state_name` · X: On-time Rate · sort ascending, so the worst state is on top |
| Table | `seller_id`, `seller_state` from the leaderboard · Delivered Orders · On-time Rate · Avg Delivery Days · Filters on this visual: *Top N 10 by Delivered Orders*, and leaderboard `seller_id` with *(Blank)* unticked |

Why a column-plus-line chart rather than the plain line in the Looker report:
plotting volume next to the rate shows at a glance that 2016-09 and 2016-12 hold
a single order each and 2016-11 has none, so nobody reads the swing at the left
edge as a real collapse. The months with no orders show as a gap here, not as a
zero, because the calendar supplies the empty month.

The filled map was the first choice and was dropped: Power BI's Bing geocoder
placed some states outside Brazil, and Microsoft is retiring the map visuals. A
bar chart sorted worst first answers the same question with nothing to geocode.

The table needs the *(Blank)* filter because 11,853 orders come from sellers
under the 20-order floor. They have no leaderboard row, so Power BI groups them
under a blank seller, which Top N then ranks first. Two traps:

- Filter the **leaderboard's** `seller_id`. The fact table's `seller_id` and
  `seller_state` are never blank, so a filter on them removes nothing.
- Put the filter under **Filters on this visual**. On the page it cuts every card
  to leaderboard sellers only (84,617 orders, 93.24 %).

Use View → **Gridlines** and **Snap to grid**, and Format → **Align** /
**Distribute** with several visuals selected. Give every visual a plain-English
title instead of the field name.

## 6. Check the numbers before trusting the report

With no slicer applied, the report must show:

| Figure | Expected |
|---|---:|
| Delivered Orders | 96,470 |
| On-time Rate | 93.23% |
| Avg Delivery Days | 12.5 |
| Avg Freight (BRL) | 22.79 |
| Date range | 2016-09-15 → 2018-08-29 |
| Top seller | `6560211a…`, SP, 1,812 orders, 94.70% |
| Orders from leaderboard sellers | 84,617 |

On-time rate by region:

| Region | Orders | On-time |
|---|---:|---:|
| Sudeste | 66,193 | 93.88% |
| Sul | 13,813 | 94.10% |
| Nordeste | 9,044 | **87.28%** |
| Centro-Oeste | 5,624 | 93.47% |
| Norte | 1,796 | 91.43% |

States range from **78.59% (Alagoas)** to **97.24% (Amazonas)**.

A mismatch means a relationship or a measure is wrong — usually a relationship
pointing the wrong way, or On-time Rate built on `on_time_pct` instead of
`on_time_flag`.

## 7. Save into the repo

- Save as `powerbi/olist_delivery_performance.pbix`.
- Export the page: File → Export → Export to PDF, as
  `powerbi/olist_delivery_performance.pdf`.
- The screenshot `powerbi/screenshots/dashboard.png` is rendered from that PDF
  (`sips -s format png --resampleWidth 2400 … --out …` on macOS).
- Upload both through GitHub (Add file → Upload files, into `powerbi/`), or copy
  them across and commit.
