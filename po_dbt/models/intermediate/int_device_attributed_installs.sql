{{
    config(
        unique_key='attribution_unique_id',
        tags=['attrib']
    )
}}

WITH stg_attribution AS (
    SELECT
        -- Fields from attribution
        installtime,
        mediasource,
        channel,
        campaign,
        adset,
        ad,
        adtype,
        appsflyerid,
        advertisingid,
        idfa AS attr_idfa, -- Alias to avoid confusion if stg_devices also has idfa
        idfv AS attr_idfv, -- Alias to avoid confusion
        platform,
        extraction_date,
        unique_id AS attribution_unique_id -- Important for lineage and potential unique key
    FROM
        {{ ref('stg_attribution') }}
),

stg_devices AS (
    SELECT
        device_id,
        platform AS device_platform, -- Alias to differentiate from attribution platform
        app_version,
        os_version,
        device_brand,
        device_manufacturer,
        device_model,
        adid,
        idfa AS device_idfa, -- Alias
        idfv AS device_idfv, -- Alias
        af_id, -- This is the AppsFlyer ID in the devices table
        first_touch_timestamp
    FROM
        {{ ref('stg_devices') }}
),

joined_data AS (
    SELECT
        attr.mediasource,
        attr.campaign,
        attr.adset,
        attr.installtime,
        attr.platform, -- This is the platform of the install/attribution event
        attr.attribution_unique_id,
        attr.appsflyerid,
        attr.advertisingid, -- Keep original advertisingid for potential debugging/matching
        attr.attr_idfa,     -- Keep original attr_idfa for potential debugging/matching
        attr.attr_idfv,     -- Keep original attr_idfv for potential debugging/matching

        -- Select device information using COALESCE based on join priority
        COALESCE(
            dev_primary.device_id,
            dev_android_fallback.device_id,
            dev_ios_fallback.device_id
        ) AS device_id,

        COALESCE(
            dev_primary.first_touch_timestamp,
            dev_android_fallback.first_touch_timestamp,
            dev_ios_fallback.first_touch_timestamp
        ) AS first_touch_timestamp,

        -- You might want to know which join succeeded for debugging/analysis
        CASE
            WHEN dev_primary.device_id IS NOT NULL THEN 'joined_on_appsflyerid_af_id'
            WHEN dev_android_fallback.device_id IS NOT NULL THEN 'joined_on_android_advertisingid_adid'
            WHEN dev_ios_fallback.device_id IS NOT NULL THEN 'joined_on_ios_idfv_idfv'
            ELSE 'no_device_match'
        END AS join_method

    FROM
        stg_attribution AS attr

    -- Primary Join: stg_attribution.appsflyerid = stg_devices.af_id
    LEFT JOIN stg_devices AS dev_primary
        ON attr.appsflyerid IS NOT NULL AND attr.appsflyerid = dev_primary.af_id

    -- Fallback 1: Android (advertisingid = adid)
    -- This join only attempts if the primary join did not match (dev_primary.af_id IS NULL)
    -- AND the platform is 'android'
    LEFT JOIN stg_devices AS dev_android_fallback
        ON attr.platform = 'android' -- Assuming platform is 'android' or 'ios'
        AND attr.advertisingid IS NOT NULL
        AND attr.advertisingid = dev_android_fallback.adid
        AND dev_primary.af_id IS NULL -- Ensures this join only "activates" if dev_primary didn't match

    -- Fallback 2: iOS (idfv = idfv)
    -- This join only attempts if both primary and android fallbacks did not match
    -- (dev_primary.af_id IS NULL AND dev_android_fallback.adid IS NULL)
    -- AND the platform is 'ios'
    LEFT JOIN stg_devices AS dev_ios_fallback
        ON attr.platform = 'ios'
        AND attr.attr_idfv IS NOT NULL -- Use aliased attr_idfv
        AND attr.attr_idfv = dev_ios_fallback.device_idfv -- Use aliased device_idfv
        AND dev_primary.af_id IS NULL -- Ensures this join only "activates" if dev_primary didn't match
        AND dev_android_fallback.adid IS NULL -- Ensures this join only "activates" if dev_android_fallback didn't match (or wasn't applicable for android)
)

-- Final selection of columns and de-duplication using QUALIFY
SELECT
    appsflyerid,
    device_id,
    mediasource,
    campaign,
    adset,
    installtime,
    platform, -- This is the attribution platform
    first_touch_timestamp,
    attribution_unique_id,
    join_method
FROM
    joined_data
QUALIFY ROW_NUMBER() OVER (PARTITION BY attribution_unique_id ORDER BY first_touch_timestamp ASC) = 1