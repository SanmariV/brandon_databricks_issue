# brandon_databricks_issue

## Project layout

- `seeds/postcodebase.csv` / `accountbase.csv` — the raw, current-state-only
  fixture data, loaded via `dbt seed` into `landing_crm.postcodebase` /
  `landing_crm.accountbase`. `seeds/_landing__seeds.yml` has the PK
  (`unique`/`not_null`) and FK (`relationships`) tests on them.
- `snapshots/` — `log_postcodebase_snapshot` and `accountbase_snapshot`,
  the dbt snapshots that build full SCD2 history in `bronze_crm` from
  the seeds, referenced via `ref()` (not `source()` — the seeds are
  dbt-managed, not an external source, so `ref()` is what gives dbt a
  real dependency edge ensuring the seed loads before anything reads
  it; using `source()` here caused a real DAG race condition where
  tests ran concurrently with the seed still loading).
- `models/marts/crm_pit_spine.sql` — joins the two histories via
  `accountbase_snapshot.address_id = log_postcodebase_snapshot.address_id`
  into a point-in-time spine, one row per segment where an account's
  name and its linked address's name both stayed fixed.
- `macros/` — three custom generic tests (`no_scd_gaps`,
  `one_current_row`, `valid_to_after_valid_from`) applied to both the
  snapshots and the spine model.
- `notebooks/` — standalone Databricks SQL notebooks that test the same
  test logic directly against fake data, independent of dbt, useful for
  sanity-checking the SQL itself.
- `terraform/` — IaC for the Databricks job that runs `dbt seed` +
  `dbt build` on a schedule. See `terraform/README.md` for the full
  setup and troubleshooting guide.
- `.github/workflows/` — CI that runs `dbt seed` + `dbt build` against
  Databricks on every pull request. See
  `.github/workflows/README.md` for personal-account and
  team/service-principal setup.

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
