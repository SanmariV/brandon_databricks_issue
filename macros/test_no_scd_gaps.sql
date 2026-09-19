{% test no_scd_gaps(model, valid_from, valid_to, partition_by=none) %}

with ordered as (

    select
        {{ valid_from }} as valid_from,
        {{ valid_to }} as valid_to,
        lead({{ valid_from }}) over (
            {% if partition_by %} partition by {{ partition_by }} {% endif %}
            order by {{ valid_from }}
        ) as next_valid_from
    from {{ model }}

)

select *
from ordered
where next_valid_from is not null
  and valid_to <> next_valid_from

{% endtest %}
