{#
    Without this override, a custom schema (e.g. the seeds' `landing_crm`
    below) gets concatenated onto the target schema by default
    (`<target_schema>_landing_crm`), so the seed wouldn't land in
    the exact `landing_crm` schema that models/staging/_landing__sources.yml
    declares as the source. This makes a custom schema authoritative on
    its own, and falls back to dbt's normal default when none is set.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
