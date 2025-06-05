{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        partition_by={
            "field": "event_timestamp",
            "data_type": "timestamp",
            "granularity": "day",
        },
        unique_key=['event_id'],
        tags=['fact', 'analytics'],
    )
}}

SELECT
    e.event_timestamp,
    e.event_name,
    e.event_id,
    COALESCE(NULLIF(e.user_id, ''), s.user_id) AS user_id,
    COALESCE(NULLIF(e.device_id, ''), s.device_id) AS device_id,
    e.event_properties,
    s.platform,
    s.app_version,
    s.os_version,
    s.device_model,
    s.country,
    s.city,
    s.territory,
    s.language,
    s.session_id,
    e.event_source,

FROM
    {{ ref('stg_events') }} AS e

LEFT JOIN (
  SELECT
    s.session_id,
    s.platform,
    s.app_version,
    s.os_version,
    s.country,
    s.city,
    s.language,
    s.user_id,
    s.device_id,
    s.territory,
    s.device_model,
    event_id
  FROM {{ ref('fct_sessions') }} AS s,
  UNNEST(s.event_ids_in_session) AS event_id
  {% if is_incremental() %}
    WHERE s.session_start_ts >= (SELECT MIN(event_timestamp) FROM {{ ref('stg_events') }})
    AND s.session_start_ts <= (SELECT MAX(event_timestamp) FROM {{ ref('stg_events') }})
  {% endif %}
) AS s ON e.event_id = s.event_id  

--maybe a coalece with device dim to get device info that is not available in the sessions