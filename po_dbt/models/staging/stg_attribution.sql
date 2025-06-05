{{
    config(
        materialized='table',
        tags=['staging', 'appsflyer'],
    )
}}


{%- set execution_date = get_date_range(
    var("start_date", None), var("end_date", None)
) -%}

with organic_installs as (
    select
        TIMESTAMP(installtime) AS installtime,
        'organic' as mediasource,
        channel,
        campaign,
        adset,
        ad,
        adtype,
        appsflyerid,
        advertisingid,
        idfa,
        idfv,
        LOWER(platform) AS platform,
        extraction_date,
        -- Create a unique ID by combining all relevant fields
        FARM_FINGERPRINT(CONCAT( COALESCE(`advertisingid`, ''), COALESCE(`appsflyerid`, ''), COALESCE(`campaign`, ''), COALESCE(`channel`, ''), COALESCE(`eventtime`, ''), COALESCE(`idfa`, ''), COALESCE(`idfv`, ''), COALESCE(`installtime`, ''), COALESCE(`mediasource`, ''), COALESCE(`platform`, '') )) AS unique_id
    from {{ source('appsflyer', 'raw_organic_installs_report') }}
    where date(extraction_date) >= '{{execution_date.from}}' and date(extraction_date) <= '{{execution_date.to}}'
    --where date(extraction_date) >= '2025-01-06' and date(extraction_date) < '2025-01-14'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY unique_id ORDER BY extraction_date ASC) = 1

),

paid_installs as (
    select
        TIMESTAMP(installtime) AS installtime,
        mediasource,
        channel,
        campaign,
        adset,
        ad,
        adtype,
        appsflyerid,
        advertisingid,
        idfa,
        idfv,
        LOWER(platform) AS platform,
        extraction_date,
        -- Create a unique ID by combining all relevant fields
        FARM_FINGERPRINT(CONCAT( COALESCE(`advertisingid`, ''), COALESCE(`appsflyerid`, ''), COALESCE(`campaign`, ''), COALESCE(`channel`, ''), COALESCE(`eventtime`, ''), COALESCE(`idfa`, ''), COALESCE(`idfv`, ''), COALESCE(`installtime`, ''), COALESCE(`mediasource`, ''), COALESCE(`platform`, '') )) AS unique_id
    from {{ source('appsflyer', 'raw_installs_report2') }}
    where date(extraction_date) >= '{{execution_date.from}}' and date(extraction_date) <= '{{execution_date.to}}'
    --where date(extraction_date) >= '2025-01-06' and date(extraction_date) < '2025-01-14'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY unique_id ORDER BY extraction_date ASC) = 1

),
installs as (
    select * from organic_installs
    union all
    select * from paid_installs
)
select * from installs
