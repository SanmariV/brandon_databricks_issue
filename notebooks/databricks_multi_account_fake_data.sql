-- Databricks notebook source
-- Multi-entity fake data: a PK/FK relationship (accountbase.address_id
-- -> postcodebase.address_id) and 5 accounts, to prove two things the
-- single-entity notebook (databricks_fake_data_test.sql) never
-- exercised:
--   1. partition_by on no_scd_gaps / one_current_row correctly scopes
--      each check to ONE entity, so a broken account doesn't get
--      masked by (or falsely implicate) a healthy one.
--   2. PK uniqueness and FK integrity, checked the same way dbt's
--      built-in unique/not_null/relationships tests would, run here
--      as plain SQL since Unity Catalog PK/FK constraints are
--      informational only, not enforced.
--
-- How to use: same as databricks_fake_data_test.sql — import as a
-- notebook or run section by section, top to bottom.

-- COMMAND ----------

CREATE SCHEMA IF NOT EXISTS main.brandon_databricks_test;
USE SCHEMA main.brandon_databricks_test;

-- COMMAND ----------

-- ============================================================
-- Step 1: current-state landing tables (PK/FK live here — the
-- snapshot's job is history, not constraint-checking).
-- ============================================================

CREATE OR REPLACE TABLE postcodebase_current (
    address_id  STRING,  -- PK
    log_name    STRING
);

INSERT INTO postcodebase_current VALUES
    ('addr-1', 'Kaapstad'),    -- Acme's and Initech's shared address
    ('addr-2', 'Sandton'),     -- Globex's address
    ('addr-3', 'Rondebosch');  -- Umbrella's address; also where Stark relocates to

-- COMMAND ----------

CREATE OR REPLACE TABLE accountbase_current (
    account_id  STRING,  -- PK
    name        STRING,
    address_id  STRING   -- FK -> postcodebase_current.address_id
);

INSERT INTO accountbase_current VALUES
    ('acct-1', 'Acme Global',      'addr-1'),
    ('acct-2', 'Globex Corp',      'addr-2'),
    ('acct-3', 'Initech',          'addr-1'),  -- shares addr-1 with Acme
    ('acct-4', 'Umbrella Corp',    'addr-3'),
    ('acct-5', 'Stark Industries', 'addr-3');  -- currently at addr-3 (relocated — see history below)

-- COMMAND ----------

-- PK check (mirrors dbt's `unique` + `not_null` tests): 0 rows = PASS.
SELECT account_id, COUNT(*) AS row_count
FROM accountbase_current
GROUP BY account_id
HAVING COUNT(*) > 1 OR account_id IS NULL;

-- COMMAND ----------

-- FK check (mirrors dbt's `relationships` test): every accountbase
-- address_id must exist in postcodebase_current. 0 rows = PASS.
SELECT a.account_id, a.address_id
FROM accountbase_current a
LEFT JOIN postcodebase_current p ON a.address_id = p.address_id
WHERE p.address_id IS NULL;

-- COMMAND ----------

-- FK check, FAIL case — same query against a table with one
-- orphaned address_id, to confirm the check actually catches it.
CREATE OR REPLACE TABLE accountbase_current_bad_fk AS
SELECT * REPLACE ('addr-99' AS address_id)
FROM accountbase_current
WHERE account_id = 'acct-2';

SELECT a.account_id, a.address_id
FROM accountbase_current_bad_fk a
LEFT JOIN postcodebase_current p ON a.address_id = p.address_id
WHERE p.address_id IS NULL;
-- Expect FAIL (1 row): acct-2 now points at an address_id that
-- doesn't exist in postcodebase_current.

-- COMMAND ----------

-- ============================================================
-- Step 2: snapshot-shaped history (dbt_valid_from/dbt_valid_to) for
-- all 5 accounts — CLEAN version. acct-1 keeps its rename history
-- from before; acct-4 renames once; acct-5's ADDRESS changes (not
-- its name) partway through, proving an FK change alone must open a
-- new version once address_id is in check_cols.
-- ============================================================

CREATE OR REPLACE TABLE accountbase_snapshot_multi_clean (
    account_id      STRING,
    name            STRING,
    address_id      STRING,
    dbt_valid_from  TIMESTAMP,
    dbt_valid_to    TIMESTAMP
);

INSERT INTO accountbase_snapshot_multi_clean VALUES
    -- acct-1: Acme's full rename history, address never changes
    ('acct-1', 'Acme Ltd',      'addr-1', TIMESTAMP'2024-01-01', TIMESTAMP'2024-06-01'),
    ('acct-1', 'Acme Group',    'addr-1', TIMESTAMP'2024-06-01', TIMESTAMP'2024-09-01'),
    ('acct-1', 'Acme Holdings', 'addr-1', TIMESTAMP'2024-09-01', TIMESTAMP'2024-11-01'),
    ('acct-1', 'Acme Global',   'addr-1', TIMESTAMP'2024-11-01', NULL),

    -- acct-2: single version, no history
    ('acct-2', 'Globex Corp',   'addr-2', TIMESTAMP'2024-02-01', NULL),

    -- acct-3: single version, shares addr-1 with acct-1
    ('acct-3', 'Initech',       'addr-1', TIMESTAMP'2024-03-01', NULL),

    -- acct-4: one rename, address never changes
    ('acct-4', 'Umbrella LLC',  'addr-3', TIMESTAMP'2024-01-01', TIMESTAMP'2024-07-01'),
    ('acct-4', 'Umbrella Corp', 'addr-3', TIMESTAMP'2024-07-01', NULL),

    -- acct-5: name never changes, but address_id does (relocated addr-2 -> addr-3)
    ('acct-5', 'Stark Industries', 'addr-2', TIMESTAMP'2024-01-01', TIMESTAMP'2024-08-01'),
    ('acct-5', 'Stark Industries', 'addr-3', TIMESTAMP'2024-08-01', NULL);

-- COMMAND ----------

-- ============================================================
-- Step 3: the SAME 5 accounts, BROKEN two different ways:
--   - acct-1 loses its 'Acme Group' row (a mid-history gap, same
--     shape as the original Cape Town bug)
--   - acct-4 ends up with TWO current rows (Umbrella LLC never got
--     closed out when Umbrella Corp was created)
-- acct-2, acct-3, acct-5 are untouched and should stay clean.
-- ============================================================

CREATE OR REPLACE TABLE accountbase_snapshot_multi_broken (
    account_id      STRING,
    name            STRING,
    address_id      STRING,
    dbt_valid_from  TIMESTAMP,
    dbt_valid_to    TIMESTAMP
);

INSERT INTO accountbase_snapshot_multi_broken VALUES
    -- acct-1: 'Acme Group' row missing -> gap between 2024-06-01 and 2024-09-01
    ('acct-1', 'Acme Ltd',      'addr-1', TIMESTAMP'2024-01-01', TIMESTAMP'2024-06-01'),
    ('acct-1', 'Acme Holdings', 'addr-1', TIMESTAMP'2024-09-01', TIMESTAMP'2024-11-01'),
    ('acct-1', 'Acme Global',   'addr-1', TIMESTAMP'2024-11-01', NULL),

    ('acct-2', 'Globex Corp',   'addr-2', TIMESTAMP'2024-02-01', NULL),
    ('acct-3', 'Initech',       'addr-1', TIMESTAMP'2024-03-01', NULL),

    -- acct-4: both rows left open (dbt_valid_to NULL) -> two current rows
    ('acct-4', 'Umbrella LLC',  'addr-3', TIMESTAMP'2024-01-01', NULL),
    ('acct-4', 'Umbrella Corp', 'addr-3', TIMESTAMP'2024-07-01', NULL),

    ('acct-5', 'Stark Industries', 'addr-2', TIMESTAMP'2024-01-01', TIMESTAMP'2024-08-01'),
    ('acct-5', 'Stark Industries', 'addr-3', TIMESTAMP'2024-08-01', NULL);

-- COMMAND ----------

-- ============================================================
-- TEST: no_scd_gaps, partitioned by account_id
-- Expect PASS (0 rows) on the clean table.
-- ============================================================

WITH ordered AS (
    SELECT
        account_id,
        dbt_valid_from,
        dbt_valid_to,
        LEAD(dbt_valid_from) OVER (PARTITION BY account_id ORDER BY dbt_valid_from) AS next_valid_from
    FROM accountbase_snapshot_multi_clean
)
SELECT * FROM ordered
WHERE next_valid_from IS NOT NULL AND dbt_valid_to <> next_valid_from;

-- COMMAND ----------

-- Expect FAIL: exactly ONE row back, and it's acct-1 only — acct-2/3/4/5
-- must NOT appear, proving partition_by isolates the gap to the one
-- broken account instead of it going unnoticed or flagging everyone.

WITH ordered AS (
    SELECT
        account_id,
        dbt_valid_from,
        dbt_valid_to,
        LEAD(dbt_valid_from) OVER (PARTITION BY account_id ORDER BY dbt_valid_from) AS next_valid_from
    FROM accountbase_snapshot_multi_broken
)
SELECT * FROM ordered
WHERE next_valid_from IS NOT NULL AND dbt_valid_to <> next_valid_from;

-- COMMAND ----------

-- ============================================================
-- TEST: one_current_row, partitioned by account_id
-- Expect PASS (0 rows, all 5 accounts) on the clean table.
-- ============================================================

SELECT
    account_id,
    SUM(CASE WHEN dbt_valid_to IS NULL THEN 1 ELSE 0 END) AS current_row_count
FROM accountbase_snapshot_multi_clean
GROUP BY account_id
HAVING SUM(CASE WHEN dbt_valid_to IS NULL THEN 1 ELSE 0 END) <> 1;

-- COMMAND ----------

-- Expect FAIL: exactly ONE row back (acct-4, current_row_count = 2) —
-- acct-1's gap doesn't trip this test, and acct-2/3/5 stay silent.

SELECT
    account_id,
    SUM(CASE WHEN dbt_valid_to IS NULL THEN 1 ELSE 0 END) AS current_row_count
FROM accountbase_snapshot_multi_broken
GROUP BY account_id
HAVING SUM(CASE WHEN dbt_valid_to IS NULL THEN 1 ELSE 0 END) <> 1;

-- COMMAND ----------

-- ============================================================
-- Step 4: historized postcode data, to run crm_pit_spine.sql's join
-- logic end to end against the multi-account clean dataset.
-- addr-1 keeps its 3-version rename history (Cape Twn -> Cape Town ->
-- Kaapstad); addr-2 and addr-3 never rename. This is what actually
-- exercises the two things the spine model needs to get right:
--   - acct-1 and acct-3 both link to addr-1, so its rename history
--     must correctly split BOTH of their account periods.
--   - acct-5's own address_id change (addr-2 -> addr-3, see Step 2)
--     must line up with the right postcode on each side.
-- ============================================================

CREATE OR REPLACE TABLE postcodebase_snapshot_multi (
    address_id      STRING,
    log_name        STRING,
    dbt_valid_from  TIMESTAMP,
    dbt_valid_to    TIMESTAMP
);

INSERT INTO postcodebase_snapshot_multi VALUES
    ('addr-1', 'Cape Twn',   TIMESTAMP'2024-01-01', TIMESTAMP'2024-03-15'),
    ('addr-1', 'Cape Town',  TIMESTAMP'2024-03-15', TIMESTAMP'2024-10-01'),
    ('addr-1', 'Kaapstad',   TIMESTAMP'2024-10-01', NULL),
    ('addr-2', 'Sandton',    TIMESTAMP'2024-01-01', NULL),
    ('addr-3', 'Rondebosch', TIMESTAMP'2024-01-01', NULL);

-- COMMAND ----------

-- The spine query itself — same overlapping-interval join as
-- models/marts/crm_pit_spine.sql, run here against the fake tables
-- instead of the real snapshots.
--
-- Expected segment counts per account (verify against the output):
--   acct-1 (Acme,   4 name versions x addr-1's 3 postcode versions,
--           only overlapping pairs) -> 6 segments
--   acct-2 (Globex, 1 version x addr-2's 1 version)                -> 1 segment
--   acct-3 (Initech,1 version x addr-1's 3 versions)                -> 3 segments
--   acct-4 (Umbrella,2 versions x addr-3's 1 version)               -> 2 segments
--   acct-5 (Stark,  2 versions, each against its own address's
--           1 version)                                              -> 2 segments
-- Total: 14 rows.

WITH account_history AS (
    SELECT
        account_id,
        name AS account_name,
        address_id,
        dbt_valid_from,
        COALESCE(dbt_valid_to, TIMESTAMP'9999-12-31') AS dbt_valid_to_capped
    FROM accountbase_snapshot_multi_clean
),

postcode_history AS (
    SELECT
        address_id,
        log_name AS postcode_name,
        dbt_valid_from,
        COALESCE(dbt_valid_to, TIMESTAMP'9999-12-31') AS dbt_valid_to_capped
    FROM postcodebase_snapshot_multi
),

overlapped AS (
    SELECT
        account_history.account_id,
        account_history.account_name,
        postcode_history.postcode_name,
        GREATEST(account_history.dbt_valid_from, postcode_history.dbt_valid_from) AS seg_from,
        LEAST(account_history.dbt_valid_to_capped, postcode_history.dbt_valid_to_capped) AS seg_to_capped
    FROM account_history
    LEFT JOIN postcode_history
        ON account_history.address_id = postcode_history.address_id
       AND account_history.dbt_valid_from < postcode_history.dbt_valid_to_capped
       AND postcode_history.dbt_valid_from < account_history.dbt_valid_to_capped
)

SELECT
    account_id,
    account_name,
    postcode_name,
    seg_from,
    CASE WHEN seg_to_capped = TIMESTAMP'9999-12-31' THEN NULL ELSE seg_to_capped END AS seg_to
FROM overlapped
ORDER BY account_id, seg_from;

-- COMMAND ----------

-- Sanity check on the result above: count of segments per account
-- should match the expected counts in the comment before the query
-- (acct-1: 6, acct-2: 1, acct-3: 3, acct-4: 2, acct-5: 2).
SELECT account_id, COUNT(*) AS segment_count
FROM (
    WITH account_history AS (
        SELECT account_id, address_id, dbt_valid_from,
               COALESCE(dbt_valid_to, TIMESTAMP'9999-12-31') AS dbt_valid_to_capped
        FROM accountbase_snapshot_multi_clean
    ),
    postcode_history AS (
        SELECT address_id, dbt_valid_from,
               COALESCE(dbt_valid_to, TIMESTAMP'9999-12-31') AS dbt_valid_to_capped
        FROM postcodebase_snapshot_multi
    )
    SELECT account_history.account_id
    FROM account_history
    LEFT JOIN postcode_history
        ON account_history.address_id = postcode_history.address_id
       AND account_history.dbt_valid_from < postcode_history.dbt_valid_to_capped
       AND postcode_history.dbt_valid_from < account_history.dbt_valid_to_capped
) segments
GROUP BY account_id
ORDER BY account_id;

-- COMMAND ----------

-- Cleanup.
-- DROP TABLE IF EXISTS postcodebase_current;
-- DROP TABLE IF EXISTS accountbase_current;
-- DROP TABLE IF EXISTS accountbase_current_bad_fk;
-- DROP TABLE IF EXISTS accountbase_snapshot_multi_clean;
-- DROP TABLE IF EXISTS accountbase_snapshot_multi_broken;
-- DROP TABLE IF EXISTS postcodebase_snapshot_multi;
