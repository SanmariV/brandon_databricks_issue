{% snapshot log_postcodebase_snapshot %}

{{
    config(
        target_schema='bronze_crm',
        unique_key='address_id',
        strategy='check',
        check_cols=['log_name']
    )
}}

select
    address_id,
    log_name
from {{ ref('postcodebase') }}

{% endsnapshot %}
