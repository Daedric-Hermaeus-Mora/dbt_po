{{
    config(
        materialized='table',
        tags=['staging', 'analytics'],
    )
}}

select
    device_id,
    platform,
    app_version,
    os_version,
    device_brand,
    device_manufacturer,
    device_model,
    adid,
    idfa,
    idfv,
    af_id,
    min(session_start_ts) as first_touch_timestamp,
from {{ ref('stg_sessions') }}
where device_id is not null
group by all
