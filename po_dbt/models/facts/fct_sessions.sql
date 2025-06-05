{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        partition_by={
            "field": "session_start_ts",
            "data_type": "timestamp",
            "granularity": "day",
        },
        unique_key=['session_id'],
        tags=['fact', 'analytics'],
    )
}}

SELECT
    s.session_id,
    s.user_id,
    s.device_id,
    s.session_start_ts,
    s.session_end_ts,
    s.session_length_seconds,
    s.event_count,
    coalesce(s.platform, d.platform) as platform,
    coalesce(s.device_model, d.device_model) as device_model,
    coalesce(s.app_version, scd.app_version) as app_version,
    coalesce(s.os_version, scd.os_version) as os_version,
    coalesce(s.country, users.country) as country,
    coalesce(s.city, users.city) as city,
    coalesce(s.language, users.language) as language,
    coalesce(s.territory, users.territory) as territory,
    s.event_ids_in_session
FROM
    {{ ref('stg_sessions') }} as s
left join {{ ref('dim_users') }} as users on users.user_id = s.user_id 
left join {{ ref('dim_devices_scd') }} as scd
    on s.device_id = scd.device_id
    and s.session_start_ts >= scd.valid_from
    and s.session_start_ts < scd.valid_to
left join {{ ref('dim_devices') }} as d
    on s.device_id = d.device_id



