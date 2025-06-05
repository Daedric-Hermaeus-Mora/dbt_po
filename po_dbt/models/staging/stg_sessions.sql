{{
    config(
        materialized='table',
        tags=['staging', 'analytics'],
        cluster_by=['user_id', 'device_id'] 
    )
}}

with events as (
  select
    event_timestamp,
    event_id,
    user_id,
    device_id,
    platform,
    app_version,
    os_version,
    country,
    city,
    language,
    device_manufacturer,
    device_brand,
    device_model,
    adid,
    idfa,
    idfv,
    af_id,
    territory,
    if(event_name = 'Registration Completed', event_timestamp, null) as registration_completed_ts,
    if(event_name = 'Registration Completed', DATE(JSON_VALUE(event_properties.date_of_birth)), null) as date_of_birth,
  from {{ ref('stg_events') }}
  where
    event_source = 'frontend'
    and device_id is not null -- changed to filter out null device_ids
),

identity_map as (
  select
    device_id,
    user_id,
    event_timestamp
  from {{ ref('stg_events') }}
  where
    device_id is not null
    and user_id is not null
    and event_source = 'frontend'
  qualify row_number() over (
    partition by device_id
    order by event_timestamp 
  ) = 1
),

events_with_identity as (
  select
    e.*,
    coalesce(e.user_id, im.user_id) as stitched_user_id
  from events e
  left join identity_map im
    on e.device_id = im.device_id
),

sessionized as (
  select
    *,
    -- CAMBIO: La partición para session_number ahora incluye device_id
    sum(is_new_session) over (
        partition by coalesce(stitched_user_id, device_id), device_id
        order by event_timestamp
        rows between unbounded preceding and current row -- Asegura la suma acumulativa correcta
    ) as session_number_per_user_device
  from (
    select
      *,
      case
        -- CAMBIO: La partición para lag ahora incluye device_id
        when timestamp_diff(
            event_timestamp,
            lag(event_timestamp) over (
                partition by coalesce(stitched_user_id, device_id), device_id
                order by event_timestamp
            ),
            minute
        ) > {{ var('session_timeout_minutes', 10) }} -- Proporcionar un valor por defecto para la variable
          -- CAMBIO: La partición para lag(stitched_user_id) también incluye device_id
          -- y se usa IS DISTINCT FROM para manejar NULLs correctamente.
          -- Esta condición es útil si un device_id cambia de anónimo a identificado (stitched_user_id pasa de NULL a valor).
          or lag(stitched_user_id) over (
                partition by coalesce(stitched_user_id, device_id), device_id
                order by event_timestamp
             ) is distinct from stitched_user_id
          or lag(event_timestamp) over (
                partition by coalesce(stitched_user_id, device_id), device_id
                order by event_timestamp
             ) is null -- Primera actividad en la partición user-device
        then 1
        else 0
      end as is_new_session
    from events_with_identity
  )
),

sessions_aggregated as (
  select
    -- CAMBIO: El identificador principal de la sesión ahora se basa en el usuario/dispositivo anónimo Y el device_id específico.
    coalesce(stitched_user_id, device_id) as main_identifier_key, -- Este es el usuario o el device_id si el usuario es anónimo
    device_id as session_device_id_key, -- Este es el device_id específico de la sesión
    session_number_per_user_device,

    -- Usar el stitched_user_id obtenido consistentemente.
    -- Si es una sesión anónima (stitched_user_id es NULL), user_id será NULL.
    {{ get_first_value('stitched_user_id', 'event_timestamp') }} as user_id,
    -- device_id ya es constante dentro de la agrupación por session_device_id_key
    device_id,

    min(event_timestamp) as session_start_ts,
    max(event_timestamp) as session_end_ts,
    count(event_id) as event_count, -- Contar event_id en lugar de count(*) si event_id es la unidad de evento
    timestamp_diff(max(event_timestamp), min(event_timestamp), second) as session_length_seconds,

    {{ get_first_value('platform', 'event_timestamp') }} as platform,
    {{ get_first_value('app_version', 'event_timestamp') }} as app_version,
    {{ get_first_value('os_version', 'event_timestamp') }} as os_version,
    {{ get_first_value('device_brand', 'event_timestamp') }} as device_brand,
    {{ get_first_value('device_manufacturer', 'event_timestamp') }} as device_manufacturer,
    {{ get_first_value('device_model', 'event_timestamp') }} as device_model,
    {{ get_first_value('adid', 'event_timestamp') }} as adid,
    {{ get_first_value('idfa', 'event_timestamp') }} as idfa,
    {{ get_first_value('idfv', 'event_timestamp') }} as idfv,
    {{ get_first_value('af_id', 'event_timestamp') }} as af_id,
    {{ get_first_value('country', 'event_timestamp') }} as country,
    {{ get_first_value('city', 'event_timestamp') }} as city,
    {{ get_first_value('language', 'event_timestamp') }} as language,
    {{ get_first_value('territory', 'event_timestamp') }} as territory,
    {{ get_first_value('registration_completed_ts', 'event_timestamp') }} as registration_completed_ts,
    {{ get_first_value('date_of_birth', 'event_timestamp') }} as date_of_birth,

    array_agg(event_id ignore nulls order by event_timestamp) as event_ids_in_session
  from sessionized
  group by 1, 2, 3
)

select
  FARM_FINGERPRINT(
    concat(
      coalesce(user_id, 'ANONYMOUS'), 
      '|',                               
      device_id,
      '|',                               
      cast(session_start_ts as string)
    )
  ) as session_id,
  user_id,
  device_id,
  session_start_ts,
  session_end_ts,
  session_length_seconds,
  event_count,
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
  country,
  city,
  language,
  territory,
  registration_completed_ts,
  date_of_birth,
  event_ids_in_session
  -- main_identifier_key, session_device_id_key, session_number_per_user_device no son necesarios en el select final
  -- pero son útiles para depurar si se dejan temporalmente.
from sessions_aggregated