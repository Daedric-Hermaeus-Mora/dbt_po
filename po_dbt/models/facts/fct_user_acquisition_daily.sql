{{
    config(
        materialized='incremental',
        unique_key=['date', 'channel', 'campaign_name', 'ad_group'],
        tags=['marts', 'user_acquisition', 'daily'],
        partition_by={
            "field": "date",
            "data_type": "date",
            "granularity": "day"
        },
        cluster_by=['channel', 'campaign_name', 'ad_group'],
    )
}}

WITH ad_data AS (
    SELECT
        date,
        channel,
        campaign_name,
        ad_group,
        SUM(clicks) AS total_clicks,
        SUM(impressions) AS total_impressions,
        SUM(spend) AS total_spend,
        SUM(reach) AS total_reach
    FROM
        {{ ref('int_ad_platform') }}
    GROUP BY
        1, 2, 3, 4
),

install_data AS (
    SELECT
        install_date AS date,
        channel,
        campaign_name,
        ad_group,
        SUM(total_installs) AS total_installs
    FROM
        {{ ref('int_daily_installs_attributed') }}
    GROUP BY
        1, 2, 3, 4
)

SELECT
    COALESCE(ad.date, install.date) AS date,
    COALESCE(ad.channel, install.channel) AS channel,
    COALESCE(ad.campaign_name, install.campaign_name) AS campaign_name,
    COALESCE(ad.ad_group, install.ad_group) AS ad_group,
    COALESCE(ad.total_clicks, 0) AS total_clicks,
    COALESCE(ad.total_impressions, 0) AS total_impressions,
    COALESCE(ad.total_spend, 0) AS total_spend,
    COALESCE(ad.total_reach, 0) AS total_reach,
    COALESCE(install.total_installs, 0) AS total_installs
FROM
    ad_data ad
FULL OUTER JOIN -- Use FULL OUTER JOIN to capture all rows from both ad_data and install_data
    install_data install
    ON ad.date = install.date
    AND ad.channel = install.channel
    AND ad.campaign_name = install.campaign_name
    AND ad.ad_group = install.ad_group

--{% if is_incremental() %}
  -- This filter will only be applied on an incremental run
  -- It will only process data for dates greater than the max date already in the table
--  WHERE COALESCE(ad.date, install.date) >= (SELECT MAX(date) FROM {{ this }})
--{% endif %}