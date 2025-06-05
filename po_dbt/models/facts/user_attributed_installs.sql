{{
    config(
        materialized='view'
    )
}}

WITH source_installs AS (
    SELECT
        install_time_mmp,
        attribution_unique_id,
        device_id,
        mediasource,
        campaign,
        adset,
        platform,
        join_method
    FROM
        {{ ref('fct_device_attributed_installs') }}
),

device_user_mapping AS (
    SELECT
        dim_device_user_sk,
        device_id,
        user_id,
        valid_from,
        COALESCE(valid_to, TIMESTAMP('9999-12-31T23:59:59')) AS valid_to_processed
    FROM
        {{ ref('dim_device_users_scd') }}
),

-- Join installs to all potentially relevant mappings (exact and future-window)
-- This might create duplicates per install if multiple mappings fit the criteria
joined_with_potential_mappings AS (
    SELECT
        installs.install_time_mmp,
        installs.attribution_unique_id,
        installs.device_id,
        mapping.user_id,
        mapping.dim_device_user_sk,
        installs.mediasource,
        installs.campaign,
        installs.adset,
        installs.platform,
        installs.join_method,
        mapping.valid_from AS mapping_valid_from,
        mapping.valid_to_processed AS mapping_valid_to,

        -- Calculate difference for future mappings
        TIMESTAMP_DIFF(mapping.valid_from, installs.install_time_mmp, DAY) AS days_diff_valid_from_after_install,

        -- Define match type for prioritization
        CASE
            -- Case 1: Exact temporal match
            WHEN installs.install_time_mmp >= mapping.valid_from
                 AND installs.install_time_mmp < mapping.valid_to_processed
            THEN 1 -- Highest priority

            -- Case 2: Mapping starts after install, but within 4 days
            WHEN mapping.valid_from > installs.install_time_mmp -- mapping starts AFTER install
                 AND mapping.valid_from <= TIMESTAMP_ADD(installs.install_time_mmp, INTERVAL 4 DAY) -- within 4 days
                 AND installs.install_time_mmp < mapping.valid_to_processed -- install still happened before mapping ended (important for short-lived future mappings)
            THEN 2 -- Second priority

            ELSE 99 -- Does not meet desired criteria
        END AS match_priority_type

    FROM
        source_installs AS installs
    LEFT JOIN
        device_user_mapping AS mapping
        ON installs.device_id = mapping.device_id
        -- Broaden the join condition initially to catch records where valid_from might be slightly after install_time_mmp
        -- We ensure the mapping didn't end *before* the install, and didn't start *too far after* the install.
        AND mapping.valid_to_processed > installs.install_time_mmp -- Mapping must not have ended before the install
        AND mapping.valid_from <= TIMESTAMP_ADD(installs.install_time_mmp, INTERVAL 4 DAY) -- Mapping must start within 4 days after install (or before)
)

SELECT
    install_time_mmp,
    attribution_unique_id,
    device_id,
    user_id,
    -- dim_device_user_sk, -- You might want this too
    mediasource,
    campaign,
    adset,
    platform,
    join_method
FROM
    joined_with_potential_mappings
WHERE match_priority_type != 99 -- Filter out non-matches
QUALIFY
    ROW_NUMBER() OVER (
        PARTITION BY attribution_unique_id
        ORDER BY
            match_priority_type ASC, -- Prioritize exact matches (1), then future window (2)
            -- For future window matches (type 2), pick the one with the smallest positive difference
            -- For exact matches (type 1), this diff will be <= 0, so it won't negatively impact their sort order against other type 1s
            CASE WHEN match_priority_type = 2 THEN days_diff_valid_from_after_install ELSE 0 END ASC,
            mapping_valid_from ASC -- Final tie-breaker: earliest valid_from among equally good matches
    ) = 1