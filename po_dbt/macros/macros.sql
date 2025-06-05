{% macro get_date_range(from=None, to=None) %}

    -- from
    {% if from is none %}
        {%- set from = (
            modules.datetime.date.today()
            - modules.datetime.timedelta(days=var('activity_refresh_days', 7))
        ).strftime("%Y-%m-%d") %}
    {% endif %}

    -- to
    {% if to is none %}
        {%- set to = (modules.datetime.date.today()).strftime("%Y-%m-%d") %}
    {% endif %}

    -- result
    {%- set result = {
        "from": from,
        "to": to
    } %}

    {{ return(result) }}
{% endmacro %}

{% macro get_first_value(value_column, order_by_column, order_direction='ASC') %}
    ARRAY_AGG({{ value_column }} IGNORE NULLS ORDER BY {{ order_by_column }} {{ order_direction }} LIMIT 1)[OFFSET(0)]
{% endmacro %}

