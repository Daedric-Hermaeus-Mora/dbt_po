{{
    config(
        materialized='table',
        tags=['staging', 'analytics'],
    )
}}

{%- set execution_date = get_date_range(
    var("start_date", None), var("end_date", None)
) -%}


with source_data as (
    select
        TIMESTAMP_MILLIS(int64(data.timestamp)) as event_timestamp,
        json_value(data.event_name) as event_name,
        coalesce (json_value(data.event_id),to_hex(sha1(to_json_string(data)))) as event_id,
        NULLIF(TRIM(JSON_VALUE(data.properties.user_id)), '') as user_id,
        NULLIF(TRIM(JSON_VALUE(data.properties.device_id)), '') as device_id,
        NULLIF(TRIM(LOWER(JSON_VALUE(data.properties.platform))), '') as platform,
        NULLIF(TRIM(JSON_VALUE(data.properties.app_version)), '') as app_version,
        NULLIF(TRIM(JSON_VALUE(data.properties.os_version)), '') as os_version,
        NULLIF(TRIM(JSON_VALUE(data.properties.country)), '') as country,
        NULLIF(TRIM(JSON_VALUE(data.properties.city)), '') as city,
        NULLIF(TRIM(JSON_VALUE(data.properties.language)), '') as language,
        NULLIF(TRIM(JSON_VALUE(data.properties.device_manufacturer)), '') as device_manufacturer,
        NULLIF(TRIM(JSON_VALUE(data.properties.device_brand)), '') as device_brand,
        NULLIF(TRIM(JSON_VALUE(data.properties.device_model)), '') as device_model,
        if(
            (TRIM(JSON_VALUE(data.properties.adid))
            in ('', '00000000-0000-0000-0000-000000000000', '0000-0000') AND LOWER(JSON_VALUE(data.properties.platform)) = 'android'),
            null,
            TRIM(JSON_VALUE(data.properties.adid))
        ) as adid,
        if(
            (TRIM(JSON_VALUE(data.properties.idfa))
            in ('', '00000000-0000-0000-0000-000000000000', '0000-0000') AND LOWER(JSON_VALUE(data.properties.platform)) = 'ios'),
            null,
            TRIM(JSON_VALUE(data.properties.idfa))
        ) as idfa,
        NULLIF(TRIM(JSON_VALUE(data.properties.idfv)), '') as idfv,
        NULLIF(TRIM(JSON_VALUE(data.properties.af_id)), '') as af_id,
        NULLIF(TRIM(if(json_value(data.properties.ftue_step) = 'territory', json_value(data.properties.ftue_value), json_value(data.properties.territory))), '') as territory,
        data.properties as event_properties
    from {{ source('analytics_events', 'analytics_events_table') }}
    where date(publish_time) >= '{{execution_date.from}}' and date(publish_time) < '{{execution_date.to}}'
    --where date(publish_time) >= '2025-01-06' and date(publish_time) < '2025-01-13'
    qualify row_number() over (partition by event_id order by event_timestamp desc) = 1

)
select 
    source_data.*, 
    es.event_source 
from source_data 
left join {{ ref('events_source') }} as es using (event_name)