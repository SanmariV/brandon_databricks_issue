-- Point-in-time spine: for every account, for every period where its
-- name AND its linked address stayed fixed, further splits that
-- period wherever the linked address's OWN name changed — producing
-- one segment per (account, address-name) combination actually in
-- effect at any moment, for every account.
--
-- INCREMENTAL: on each run only accounts affected by new snapshot rows are
-- recomputed, and ALL of their segments are replaced (delete+insert on
-- account_id) — a late change can split or close an existing segment, so
-- merging individual segments would leave stale rows behind.
-- An account is affected when its own snapshot has a new row, or when a
-- new row landed in log_postcodebase_snapshot for an address it points to.
-- Watermark = max(source_updated_at) already stored in this table, where
-- source_updated_at is the snapshot run time (dbt_updated_at) of the newest
-- snapshot row feeding the segment. Every change inserts a new snapshot row
-- stamped with the run time, so dbt_updated_at > watermark catches them all.
-- The watermark is a LOAD time, never a business date, so it cannot drop
-- backdated rows.
--
-- Joined via accountbase_snapshot.address_id = log_postcodebase_snapshot.address_id
-- (an overlapping-interval join, not an equi-join on time), which is
-- what makes this work per account rather than assuming a single
-- account/address pair:
--   - account_history rows already carry one row per (name, address_id)
--     version, since address_id is tracked in the snapshot's check_cols
--     — so a relocation (address_id changes, name doesn't) already
--     produces a new account_history row on its own.
--   - postcode_history can still rename independently *within* a
--     period where the account's address_id didn't change (e.g. the
--     linked address gets renamed while the account stays put) — the
--     overlap join splits that account period into sub-segments to
--     capture it.
--
-- NULL dbt_valid_to (still current) is capped to a sentinel far-future
-- timestamp for the overlap arithmetic, then converted back to NULL —
-- a segment stays open only when BOTH sides are still current.

{{
    config(
        materialized='incremental',
        incremental_strategy='delete+insert',
        unique_key='account_id'
    )
}}

with changed_accounts as (

    {% if is_incremental() %}
    select account_id
    from {{ ref('accountbase_snapshot') }}
    where dbt_updated_at > (
        select coalesce(max(source_updated_at), timestamp '1900-01-01') from {{ this }}
    )

    union

    select account_snap.account_id
    from {{ ref('accountbase_snapshot') }} as account_snap
    inner join {{ ref('log_postcodebase_snapshot') }} as postcode_snap
        on account_snap.address_id = postcode_snap.address_id
    where postcode_snap.dbt_updated_at > (
        select coalesce(max(source_updated_at), timestamp '1900-01-01') from {{ this }}
    )
    {% else %}
    select distinct account_id
    from {{ ref('accountbase_snapshot') }}
    {% endif %}

),

account_history as (

    select
        account_id,
        name as account_name,
        address_id,
        dbt_valid_from,
        coalesce(dbt_valid_to, timestamp '9999-12-31') as dbt_valid_to_capped,
        dbt_updated_at
    from {{ ref('accountbase_snapshot') }}
    where account_id in (select account_id from changed_accounts)

),

postcode_history as (

    select
        address_id,
        log_name as postcode_name,
        dbt_valid_from,
        coalesce(dbt_valid_to, timestamp '9999-12-31') as dbt_valid_to_capped,
        dbt_updated_at
    from {{ ref('log_postcodebase_snapshot') }}
    where address_id in (select address_id from account_history)

),

overlapped as (

    select
        account_history.account_id,
        account_history.account_name,
        postcode_history.postcode_name,
        greatest(account_history.dbt_valid_from, postcode_history.dbt_valid_from) as seg_from,
        least(account_history.dbt_valid_to_capped, postcode_history.dbt_valid_to_capped) as seg_to_capped,
        greatest(account_history.dbt_updated_at, postcode_history.dbt_updated_at) as source_updated_at
    from account_history
    left join postcode_history
        on account_history.address_id = postcode_history.address_id
       and account_history.dbt_valid_from < postcode_history.dbt_valid_to_capped
       and postcode_history.dbt_valid_from < account_history.dbt_valid_to_capped

)

select
    account_id,
    account_name,
    postcode_name,
    seg_from,
    case when seg_to_capped = timestamp '9999-12-31' then null else seg_to_capped end as seg_to,
    source_updated_at
from overlapped
