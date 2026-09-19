{% snapshot accountbase_snapshot %}

{{
    config(
        target_schema='bronze_crm',
        unique_key='account_id',
        strategy='check',
        check_cols=['name', 'address_id']
    )
}}

select
    account_id,
    name,
    address_id
from {{ ref('accountbase') }}

{% endsnapshot %}
