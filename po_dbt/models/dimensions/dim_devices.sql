{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key=['device_id'],
        tags=['dim', 'analytics'],
    )
}}

with source_data as(
  select
    device_id,
    {{ get_first_value('platform', 'first_touch_timestamp') }} as platform,
    {{ get_first_value('app_version', 'first_touch_timestamp') }} as first_app_version,
    {{ get_first_value('os_version', 'first_touch_timestamp') }} as first_os_version,
    {{ get_first_value('device_brand', 'first_touch_timestamp') }} as device_brand,
    {{ get_first_value('device_manufacturer', 'first_touch_timestamp') }} as device_manufacturer,
    {{ get_first_value('device_model', 'first_touch_timestamp') }} as device_model,
    {{ get_first_value('adid', 'first_touch_timestamp') }} as adid,
    {{ get_first_value('idfa', 'first_touch_timestamp') }} as idfa,
    {{ get_first_value('idfv', 'first_touch_timestamp') }} as idfv,
    min(first_touch_timestamp) as first_touch_timestamp
from {{ ref('stg_devices') }}
where device_id is not null
group by 1 
),


{% if is_incremental() %}
    update_devices as (
        select
            daily.device_id,
            if(daily.first_touch_timestamp< historical.first_touch_timestamp, coalesce(daily.platform,historical.platform),coalesce(historical.platform,daily.platform)) as platform,
            if(daily.first_touch_timestamp< historical.first_touch_timestamp, coalesce(daily.first_app_version,historical.first_app_version),coalesce(historical.first_app_version,daily.first_app_version)) as first_app_version,
            if(daily.first_touch_timestamp< historical.first_touch_timestamp, coalesce(daily.first_os_version,historical.first_os_version),coalesce(historical.first_os_version,daily.first_os_version)) as first_os_version,
            if(daily.first_touch_timestamp< historical.first_touch_timestamp, coalesce(daily.device_brand,historical.device_brand),coalesce(historical.device_brand,daily.device_brand)) as device_brand,
            if(daily.first_touch_timestamp< historical.first_touch_timestamp, coalesce(daily.device_manufacturer,historical.device_manufacturer),coalesce(historical.device_manufacturer,daily.device_manufacturer)) as device_manufacturer,
            if(daily.first_touch_timestamp< historical.first_touch_timestamp, coalesce(daily.device_model,historical.device_model),coalesce(historical.device_model,daily.device_model)) as device_model,
            if(daily.first_touch_timestamp< historical.first_touch_timestamp, coalesce(daily.adid,historical.adid),coalesce(historical.adid,daily.adid)) as adid,
            if(daily.first_touch_timestamp< historical.first_touch_timestamp, coalesce(daily.idfa,historical.idfa),coalesce(historical.idfa,daily.idfa)) as idfa,
            if(daily.first_touch_timestamp< historical.first_touch_timestamp, coalesce(daily.idfv,historical.idfv),coalesce(historical.idfv,daily.idfv)) as idfv,
            if(daily.first_touch_timestamp< historical.first_touch_timestamp, coalesce(daily.first_touch_timestamp,historical.first_touch_timestamp),coalesce(historical.first_touch_timestamp,daily.first_touch_timestamp)) as first_touch_timestamp,
        from source_data as daily
        inner join {{ this }} as historical on daily.device_id = historical.device_id
    ),
    new_devices as (
        select source_data.*
            from source_data
            left join
                {{ this }} as historical
            on source_data.device_id = historical.device_id
            where historical.device_id is null
        ),
        devices as (
            select *
            from update_devices
            union all
            select *
            from new_devices
        )
{% else %} devices as (select * from source_data)
{% endif %}

select * from devices
