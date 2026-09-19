# brandon_databricks_issue

This is a prototype dbt project trying to solve Brandon's bronze-layer
issue: a hand-rolled watermark mechanism was silently dropping historical
rows, breaking the client's request for full history in the bronze CRM
tables. See `bronze_scd_test_macros.md` for the full write-up of the bug
and the approach taken here (dbt snapshots + custom tests instead of a
hand-rolled watermark filter).

## Project layout

- `models/staging/_landing__sources.yml` — the raw, current-state-only
  `landing_crm` source tables (`postcodebase`, `accountbase`), with PK
  (`unique`/`not_null`) and FK (`relationships`) tests.
- `snapshots/` — `log_postcodebase_snapshot` and `accountbase_snapshot`,
  the dbt snapshots that build full SCD2 history in `bronze_crm` from
  the current-state landing tables.
- `models/marts/crm_pit_spine.sql` — joins the two histories via
  `accountbase_snapshot.address_id = log_postcodebase_snapshot.address_id`
  into a point-in-time spine, one row per segment where an account's
  name and its linked address's name both stayed fixed.
- `macros/` — three custom generic tests (`no_scd_gaps`,
  `one_current_row`, `valid_to_after_valid_from`) applied to both the
  snapshots and the spine model.
- `seeds/` — fake fixture data (5 accounts, 3 addresses) loaded into
  `landing_crm` via `dbt seed`.
- `notebooks/` — standalone Databricks SQL notebooks that test the same
  test logic directly against fake data, independent of dbt, useful for
  sanity-checking the SQL itself.

## Setup

### 1. In the Databricks web UI (one-time)

1. **Compute → SQL Warehouses** — confirm one exists and is running (or
   start it). This is what dbt connects to.
2. Click into it → **Connection details** tab → copy the **Server
   hostname** and **HTTP path**.
3. **Settings → Developer → Access tokens** — generate a Personal
   Access Token if you don't already have one.
4. **Catalog Explorer** — note which catalog you're using (a dev/sandbox
   one, not production).

### 2. On your machine, in a terminal, inside this project folder

```bash
pip install -r requirements.txt
```

Then check `~/.dbt/profiles.yml` has the host / http_path / token /
catalog from step 1 filled in under the `brandon_databricks_issue`
profile (this file lives outside the project folder — credentials never
belong in git).

```bash
dbt debug   # confirms dbt can reach Databricks — don't move on until this passes
dbt seed    # loads the fixture data into landing_crm.postcodebase / accountbase
dbt build   # runs the snapshots, the crm_pit_spine model, and every test, in order
```

If `dbt build` fails, the terminal output names exactly which
model/test/seed failed.

### 3. Back in the Databricks web UI, to confirm it actually worked

Open **Catalog Explorer** and check:

- `landing_crm.postcodebase` / `landing_crm.accountbase` — 3 and 5 rows.
- `bronze_crm.log_postcodebase_snapshot` / `accountbase_snapshot` — more
  rows than the source (one per historical version), with
  `dbt_valid_from` / `dbt_valid_to` columns.
- `crm_pit_spine` (in your default target schema) — around 14 rows.

## Next steps

Once `dbt build` runs clean against real Databricks, the same commands
(`dbt seed`, `dbt build`) are what a GitHub Actions CI pipeline would
run on every pull request — this manual run is the dry run for that.
