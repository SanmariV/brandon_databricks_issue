{% test valid_to_after_valid_from(model, valid_from, valid_to) %}

select *
from {{ model }}
where {{ valid_to }} < {{ valid_from }}

{% endtest %}
