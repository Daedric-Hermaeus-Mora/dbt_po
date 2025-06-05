{{
    config(
        materialized='view',
        tags=['intermediate', 'ad_data'],
    )
}}

WITH facebook_ads AS (
    SELECT
        date,
        campaign_name,
        ad_group,
        'facebook' AS channel,
        clicks,
        impressions,
        spend,
        reach
    FROM
        {{ ref('stg_facebook_ads') }}
),

google_ads AS (
    SELECT
        date,
        campaign_name,
        ad_group,
        'google' AS channel,
        clicks,
        impressions,
        spend,
        null AS reach
    FROM
        {{ ref('stg_google_ads') }}
)

SELECT * FROM facebook_ads
UNION ALL
SELECT * FROM google_ads