{% test one_current_row(model, valid_to, partition_by=none) %}

select
    {% if partition_by %} {{ partition_by }} as entity_id, {% endif %}
    sum(case when {{ valid_to }} is null then 1 else 0 end) as current_row_count
from {{ model }}
{% if partition_by %}
group by {{ partition_by }}
{% endif %}
having sum(case when {{ valid_to }} is null then 1 else 0 end) <> 1

{% endtest %}
