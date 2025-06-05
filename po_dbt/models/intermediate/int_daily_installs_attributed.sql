{{
    config(
        materialized='view',
        tags=['intermediate', 'installs', 'attributed'],
    )
}}

SELECT
    CAST(installtime AS DATE) AS install_date,
    CASE
        WHEN mediasource = 'Facebook Ads' THEN 'facebook'
        WHEN mediasource = 'googleadwords_int' THEN 'google'
        ELSE mediasource
    END AS channel,
    -- Handle NULLs for campaign and adgroup for joining consistency
    COALESCE(campaign, 'Unknown Campaign') AS campaign_name,
    COALESCE(adset, 'Unknown Adgroup') AS ad_group,
    COUNT(unique_id) AS total_installs
FROM
    {{ ref('stg_attribution') }}
GROUP BY
    1, 2, 3, 4