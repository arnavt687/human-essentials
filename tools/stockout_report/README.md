# Stockout Risk Report

Turns a diaper bank's spreadsheet into a one-page report showing which items are likely to run out, how much to reorder, and how accurate the forecast would have been on the bank's own history.

It uses the same forecasting and reorder math as the Replenishment Planner (`app/services/replenishment/`). It needs plain Ruby 3.2+ only, with no database or Rails.

## What to ask the bank for

1. **Monthly distribution totals per item** for the last 12–24 months. Either layout works:
   - one row per item per month: `Item, Month, Quantity`
   - one row per item, one column per month: `Item, Jan 2025, Feb 2025, ...`
2. **Optional:** current stock per item, as `Item, On hand`. Without it the report still gives forecasts and reorder points, but it can't say what's at risk right now.

No family or client information is needed.

## Run it

```bash
ruby tools/stockout_report/stockout_report.rb distributions.csv \
  --on-hand on_hand.csv \
  --bank "Athens Area Diaper Bank" \
  --lead-time 30 --review 14 --service-level 0.95 \
  --out athens_report.html
```

This writes `athens_report.html` (open it in a browser, and print to PDF to send) and `athens_report.csv` with the same numbers.

Try it on the made-up data in `sample/`:

```bash
ruby tools/stockout_report/stockout_report.rb tools/stockout_report/sample/distributions_long.csv \
  --on-hand tools/stockout_report/sample/on_hand.csv --bank "Sample Diaper Bank"
```

## Handling a bank's data

- Keep their files out of git (`tools/stockout_report/private/` is ignored).
- Delete their data after sending the report, and tell them you did.
