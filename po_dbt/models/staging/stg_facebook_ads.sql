{{
    config(
        materialized='view',
        tags=['staging', 'facebook', 'ads', 'cost'],
    )
}}



SELECT
DateStart as date,
CampaignName as campaign_name,
AdSetName as ad_group,
SUM(clicks) as clicks,
SUM(Impressions) as impressions,
SUM(Spend) as spend,
Sum(reach) as reach
FROM
  {{ source('facebook_ads', 'AdInsights') }}
GROUP BY 1,2,3
