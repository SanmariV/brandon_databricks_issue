-- Databricks notebook source
-- Self-contained test of the three bronze SCD2 tests (no_scd_gaps,
-- one_current_row, valid_to_after_valid_from) against fake data shaped
-- like actual dbt snapshot OUTPUT (dbt_valid_from / dbt_valid_to, with
-- dbt_valid_to = NULL for the current row) — run straight in Databricks
-- SQL / a notebook. No dbt project required for this — it proves the
-- test LOGIC catches the bug before wiring it into the real snapshots.
--
-- How to use:
--   1. Import this file into Databricks as a notebook (File > Import,
--      or open a SQL editor and run section by section), OR paste each
--      "COMMAND" block into its own SQL editor tab.
--   2. Edit CATALOG/SCHEMA below to somewhere you're allowed to write
--      (a sandbox catalog/schema, not production bronze).
--   3. Run top to bottom. Each test's result is interpreted right
--      after it: 0 rows = PASS, any rows returned = FAIL (and the rows
--      returned ARE the offending records).

-- COMMAND ----------

-- Step 0: sandbox schema — edit this to your own catalog
CREATE SCHEMA IF NOT EXISTS main.brandon_databricks_test;
USE SCHEMA main.brandon_databricks_test;

-- COMMAND ----------

-- Step 1: fake data reproducing the ORIGINAL BUG, reshaped as snapshot
-- output. Cape Town's row (dbt_valid_from 2024-03-15, dbt_valid_to
-- 2024-10-01) is missing, exactly like the watermark filter dropped it
-- in the original hand-rolled mechanism.

CREATE OR REPLACE TABLE log_postcodebase_snapshot_broken (
    address_id      STRING,
    log_name        STRING,
    dbt_valid_from  TIMESTAMP,
    dbt_valid_to    TIMESTAMP
);

INSERT INTO log_postcodebase_snapshot_broken VALUES
    ('addr-1', 'Cape Twn', TIMESTAMP'2024-01-01', TIMESTAMP'2024-03-15'),
    -- 'Cape Town' row missing here — this is the bug
    ('addr-1', 'Kaapstad', TIMESTAMP'2024-10-01', NULL);

-- COMMAND ----------

-- Step 2: the SAME table with the bug fixed (Cape Town restored), to
-- confirm the tests pass cleanly on correct data — a test that always
-- fails is as useless as one that never fails.

CREATE OR REPLACE TABLE log_postcodebase_snapshot_fixed (
    address_id      STRING,
    log_name        STRING,
    dbt_valid_from  TIMESTAMP,
    dbt_valid_to    TIMESTAMP
);

INSERT INTO log_postcodebase_snapshot_fixed VALUES
    ('addr-1', 'Cape Twn',  TIMESTAMP'2024-01-01', TIMESTAMP'2024-03-15'),
    ('addr-1', 'Cape Town', TIMESTAMP'2024-03-15', TIMESTAMP'2024-10-01'),
    ('addr-1', 'Kaapstad',  TIMESTAMP'2024-10-01', NULL);

-- COMMAND ----------

-- Step 3: fake accountbase snapshot data, same rename history as
-- before. No bug — used as the clean baseline for all three tests.

CREATE OR REPLACE TABLE accountbase_snapshot_valid (
    account_id      STRING,
    name            STRING,
    dbt_valid_from  TIMESTAMP,
    dbt_valid_to    TIMESTAMP
);

INSERT INTO accountbase_snapshot_valid VALUES
    ('acct-1', 'Acme Ltd',      TIMESTAMP'2024-01-01', TIMESTAMP'2024-06-01'),
    ('acct-1', 'Acme Group',    TIMESTAMP'2024-06-01', TIMESTAMP'2024-09-01'),
    ('acct-1', 'Acme Holdings', TIMESTAMP'2024-09-01', TIMESTAMP'2024-11-01'),
    ('acct-1', 'Acme Global',   TIMESTAMP'2024-11-01', NULL);

-- COMMAND ----------

-- Step 4: a copy of accountbase with TWO current rows (two NULL
-- dbt_valid_to), to exercise one_current_row specifically — e.g. the
-- previous "current" row never got closed out when the new one arrived.

CREATE OR REPLACE TABLE accountbase_snapshot_bad_current AS
SELECT * REPLACE (
    CASE WHEN name = 'Acme Holdings' THEN NULL ELSE dbt_valid_to END AS dbt_valid_to
)
FROM accountbase_snapshot_valid;

-- COMMAND ----------

-- Step 5: a copy of accountbase with one row's dates inverted, to
-- exercise valid_to_after_valid_from specifically.

CREATE OR REPLACE TABLE accountbase_snapshot_bad_dates AS
SELECT * REPLACE (
    CASE WHEN name = 'Acme Group' THEN TIMESTAMP'2024-05-01' ELSE dbt_valid_to END AS dbt_valid_to
)
FROM accountbase_snapshot_valid;

-- COMMAND ----------

-- ============================================================
-- TEST 1: no_scd_gaps
-- Every row's dbt_valid_to must equal the next row's dbt_valid_from.
-- 0 rows = PASS. Any row returned = the row AFTER a gap.
-- ============================================================

-- Expect FAIL (1 row) — Cape Twn's dbt_valid_to (2024-03-15) doesn't
-- match Kaapstad's dbt_valid_from (2024-10-01) because Cape Town is missing.
WITH ordered AS (
    SELECT
        log_name,
        dbt_valid_from,
        dbt_valid_to,
        LEAD(dbt_valid_from) OVER (ORDER BY dbt_valid_from) AS next_valid_from
    FROM log_postcodebase_snapshot_broken
)
SELECT * FROM ordered
WHERE next_valid_from IS NOT NULL AND dbt_valid_to <> next_valid_from;

-- COMMAND ----------

-- Expect PASS (0 rows) — same test against the fixed table.
WITH ordered AS (
    SELECT
        log_name,
        dbt_valid_from,
        dbt_valid_to,
        LEAD(dbt_valid_from) OVER (ORDER BY dbt_valid_from) AS next_valid_from
    FROM log_postcodebase_snapshot_fixed
)
SELECT * FROM ordered
WHERE next_valid_from IS NOT NULL AND dbt_valid_to <> next_valid_from;

-- COMMAND ----------

-- ============================================================
-- TEST 2: one_current_row
-- Exactly one dbt_valid_to IS NULL row expected (per entity, or
-- overall for a single-entity table like these examples).
-- 0 rows = PASS. A row with current_row_count <> 1 = FAIL.
-- ============================================================

-- Expect PASS (0 rows) — accountbase_snapshot_valid has exactly one
-- open-ended (current) row.
SELECT
    SUM(CASE WHEN dbt_valid_to IS NULL THEN 1 ELSE 0 END) AS current_row_count
FROM accountbase_snapshot_valid
HAVING SUM(CASE WHEN dbt_valid_to IS NULL THEN 1 ELSE 0 END) <> 1;

-- COMMAND ----------

-- Expect FAIL (1 row, current_row_count = 2) —
-- accountbase_snapshot_bad_current has both Acme Holdings and
-- Acme Global marked current (dbt_valid_to IS NULL).
SELECT
    SUM(CASE WHEN dbt_valid_to IS NULL THEN 1 ELSE 0 END) AS current_row_count
FROM accountbase_snapshot_bad_current
HAVING SUM(CASE WHEN dbt_valid_to IS NULL THEN 1 ELSE 0 END) <> 1;

-- COMMAND ----------

-- ============================================================
-- TEST 3: valid_to_after_valid_from
-- No row should have dbt_valid_to earlier than its own dbt_valid_from.
-- A NULL dbt_valid_to (current row) never satisfies "< dbt_valid_from",
-- so it's naturally excluded without special-casing it.
-- 0 rows = PASS. Any row returned = an inverted interval.
-- ============================================================

-- Expect PASS (0 rows).
SELECT * FROM accountbase_snapshot_valid WHERE dbt_valid_to < dbt_valid_from;

-- COMMAND ----------

-- Expect FAIL (1 row) — Acme Group's dbt_valid_to (2024-05-01) is
-- before its dbt_valid_from (2024-06-01).
SELECT * FROM accountbase_snapshot_bad_dates WHERE dbt_valid_to < dbt_valid_from;

-- COMMAND ----------

-- Cleanup — drop the sandbox tables once you're done confirming results.
-- DROP TABLE IF EXISTS log_postcodebase_snapshot_broken;
-- DROP TABLE IF EXISTS log_postcodebase_snapshot_fixed;
-- DROP TABLE IF EXISTS accountbase_snapshot_valid;
-- DROP TABLE IF EXISTS accountbase_snapshot_bad_current;
-- DROP TABLE IF EXISTS accountbase_snapshot_bad_dates;
