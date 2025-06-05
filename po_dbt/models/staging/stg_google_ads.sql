{{
    config(
        materialized='view',
        tags=['staging', 'facebook', 'ads', 'cost'],
    )
}}

with ag as (
SELECT
    ad_group_id,
    ad_group_name
FROM
   {{ source('google_ads', 'p_ads_AdGroup_3206313825') }}
WHERE
    -- Highly Recommended: Filter by _PARTITIONTIME for performance and cost control.
    -- Example: Last 30 days of data. Adjust based on your needs.
    _PARTITIONTIME BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY) AND CURRENT_TIMESTAMP()
    -- Or, for the latest available full day's data:
    -- _PARTITIONTIME = (SELECT MAX(_PARTITIONTIME) FROM `po-analytics-production.source_google_ads.p_ads_AdGroup_3206313825`)
QUALIFY
    ROW_NUMBER() OVER(PARTITION BY ad_group_id ORDER BY _PARTITIONTIME DESC) = 1
ORDER BY
    ad_group_id DESC
),
cp as(
  SELECT
    campaign_id,
    campaign_name
FROM
    {{ source('google_ads', 'p_ads_Campaign_3206313825') }}
WHERE
    -- Highly Recommended: Filter by _PARTITIONTIME for performance and cost control.
    -- Example: Last 30 days of data. Adjust based on your needs.
    _PARTITIONTIME BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY) AND CURRENT_TIMESTAMP()
    -- Or, for the latest available full day's data:
    -- _PARTITIONTIME = (SELECT MAX(_PARTITIONTIME) FROM `po-analytics-production.source_google_ads.p_ads_AdGroup_3206313825`)
QUALIFY
    ROW_NUMBER() OVER(PARTITION BY campaign_id ORDER BY _PARTITIONTIME DESC) = 1
ORDER BY
    campaign_id DESC
)
SELECT
  DATE (_PARTITIONTIME) AS date,  
  cp.campaign_name,
  ag.ad_group_name as ad_group,
  SUM(metrics_clicks) as clicks,
  SUM(metrics_impressions) as impressions,
  (SUM(metrics_cost_micros) / 1000000) AS spend
FROM
  {{ source('google_ads', 'p_ads_AdGroupBasicStats_3206313825') }}
left join 
  ag
  USING(ad_group_id) 
left join 
  cp USING(campaign_id)   
group by 1,2,3