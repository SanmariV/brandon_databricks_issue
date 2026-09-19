-- Point-in-time spine: for every account, for every period where its
-- name AND its linked address stayed fixed, further splits that
-- period wherever the linked address's OWN name changed — producing
-- one segment per (account, address-name) combination actually in
-- effect at any moment, for every account.
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

with account_history as (

    select
        account_id,
        name as account_name,
        address_id,
        dbt_valid_from,
        coalesce(dbt_valid_to, timestamp '9999-12-31') as dbt_valid_to_capped
    from {{ ref('accountbase_snapshot') }}

),

postcode_history as (

    select
        address_id,
        log_name as postcode_name,
        dbt_valid_from,
        coalesce(dbt_valid_to, timestamp '9999-12-31') as dbt_valid_to_capped
    from {{ ref('log_postcodebase_snapshot') }}

),

overlapped as (

    select
        account_history.account_id,
        account_history.account_name,
        postcode_history.postcode_name,
        greatest(account_history.dbt_valid_from, postcode_history.dbt_valid_from) as seg_from,
        least(account_history.dbt_valid_to_capped, postcode_history.dbt_valid_to_capped) as seg_to_capped
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
    case when seg_to_capped = timestamp '9999-12-31' then null else seg_to_capped end as seg_to
from overlapped
order by account_id, seg_from
