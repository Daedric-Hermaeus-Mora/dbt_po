
{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key=['dim_device_user_sk'],
        tags=['matching', 'analytics'],
        partition_by={
          "field": "valid_from",
          "data_type": "timestamp",
          "granularity": "day"
        },
        cluster_by = ["device_id", "user_id"]
    )
}}

{% set null_user_placeholder = var('dim_null_user_placeholder', '___UNKNOWN_USER___') %}
{% set lookback_days = var('dim_device_users_lookback_days', 30) %}

-- Step 1: Get raw session events.
-- For incremental, this is a slice of recent events. For full refresh, it's all events.
WITH raw_source_events AS (
    SELECT
        device_id,
        user_id, -- Original user_id from source, can be NULL
        session_start_ts AS event_ts
    FROM {{ ref('stg_sessions') }} 
    WHERE device_id IS NOT NULL
  
),

{% if is_incremental() %}
-- Incremental Path Logic
-- Step 2i: Identify devices with new activity in the current processing window.
devices_to_recompute AS (
    SELECT DISTINCT device_id
    FROM raw_source_events
),

-- Step 3i: Fetch existing SCD history for these affected devices.
-- The user_id here is the one already effective in the dimension table.
existing_history_for_recompute AS (
    SELECT
        target.device_id,
        target.user_id,
        target.valid_from AS event_ts
    FROM {{ this }} target
    INNER JOIN devices_to_recompute dtr ON target.device_id = dtr.device_id
),

-- Step 4i: Combine existing history (for affected devices) with new raw events.
-- This forms the complete event timeline (with original/current user_ids) for devices needing SCD recalculation.
unioned_events_for_augmentation AS (
    SELECT device_id, user_id, event_ts FROM existing_history_for_recompute
    UNION ALL
    SELECT device_id, user_id, event_ts FROM raw_source_events -- user_id here is original from source
),

-- Step 5i: For each event in the combined pool, find the next non-NULL user_id looking forward.
events_with_next_user_info_incremental AS (
    SELECT
        device_id,
        user_id AS original_user_id, -- This is from {{this}} or new from source
        event_ts,
        FIRST_VALUE(user_id IGNORE NULLS) 
            OVER (PARTITION BY device_id ORDER BY event_ts ASC ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING) AS next_user_id_if_available
    FROM unioned_events_for_augmentation
),

-- Step 6i: Determine the effective_user_id using the simplified backfill rule.
augmented_events_intermediate_incremental AS (
    SELECT
        e.device_id,
        e.event_ts,
        CASE
            WHEN e.original_user_id IS NOT NULL THEN e.original_user_id
            ELSE e.next_user_id_if_available -- If original is NULL, use next available. If next is also NULL, this remains NULL.
        END AS effective_user_id
    FROM events_with_next_user_info_incremental e
),

-- Step 7i: Consolidate to unique states for SCD processing.
input_to_scd_logic AS (
    SELECT DISTINCT -- Important: after augmentation, states might become identical
        device_id,
        effective_user_id,
        event_ts
    FROM augmented_events_intermediate_incremental
)

{% else %}
-- Full Refresh Path Logic
-- Step 2f: For each raw source event, find the next non-NULL user_id looking forward.
events_with_next_user_info_full AS (
    SELECT
        device_id,
        user_id AS original_user_id,
        event_ts,
        FIRST_VALUE(user_id IGNORE NULLS) 
            OVER (PARTITION BY device_id ORDER BY event_ts ASC ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING) AS next_user_id_if_available
    FROM raw_source_events
),

-- Step 3f: Determine the effective_user_id using the simplified backfill rule.
augmented_events_intermediate_full AS (
    SELECT
        e.device_id,
        e.event_ts,
        CASE
            WHEN e.original_user_id IS NOT NULL THEN e.original_user_id
            ELSE e.next_user_id_if_available
        END AS effective_user_id
    FROM events_with_next_user_info_full e
),

-- Step 4f: Consolidate to unique states for SCD processing.
input_to_scd_logic AS (
    SELECT DISTINCT
        device_id,
        effective_user_id,
        event_ts
    FROM augmented_events_intermediate_full
)
{% endif %}
,

-- Common SCD Logic from this point onwards, using `input_to_scd_logic`
-- Step 8: Rank events to identify changes in effective_user_id for each device.
ranked_events_with_previous_user AS (
    SELECT
        device_id,
        effective_user_id,
        event_ts,
        LAG(effective_user_id, 1) OVER (
            PARTITION BY device_id
            ORDER BY event_ts ASC, COALESCE(effective_user_id, '{{ null_user_placeholder }}') ASC -- Deterministic order
        ) AS previous_effective_user_id_on_device,
        COALESCE(effective_user_id, '{{ null_user_placeholder }}') AS current_user_for_comparison,
        COALESCE(
            LAG(effective_user_id, 1) OVER (
                PARTITION BY device_id
                ORDER BY event_ts ASC, COALESCE(effective_user_id, '{{ null_user_placeholder }}') ASC
            ),
            '{{ null_user_placeholder }}' -- Ensure LAG itself doesn't yield SQL NULL for first record, for comparison
        ) AS previous_user_for_comparison
    FROM input_to_scd_logic -- This CTE is already distinct on (device_id, effective_user_id, event_ts)
),

-- Step 9: Filter to get only the events that mark the START of a new SCD period.
scd_period_start_events AS (
    SELECT
        device_id,
        effective_user_id AS user_id, -- This is the final user_id for the period
        event_ts AS valid_from
    FROM ranked_events_with_previous_user
    WHERE previous_effective_user_id_on_device IS NULL -- Catches the very first event for a device
       OR current_user_for_comparison != previous_user_for_comparison
),

-- Step 10: Calculate valid_to for each SCD period.
final_scd_records_intermediate AS (
    SELECT
        device_id,
        user_id,
        valid_from,
        COALESCE(
            TIMESTAMP_SUB(
                LEAD(valid_from, 1) OVER (PARTITION BY device_id ORDER BY valid_from ASC),
                INTERVAL 1 MICROSECOND
            ),
            TIMESTAMP('9999-12-31 23:59:59.999999 UTC') -- Standard 'infinity' timestamp
        ) AS valid_to
    FROM scd_period_start_events
),

-- Step 11: Generate the surrogate key for the dimension table.
final_scd_records AS (
    SELECT
        FARM_FINGERPRINT(CONCAT(
            CAST(device_id AS STRING), '|',
            CAST(valid_from AS STRING)
        )) AS dim_device_user_sk,
        device_id,
        user_id,
        valid_from,
        valid_to
    FROM final_scd_records_intermediate
)

-- Final Select: Output the records to be merged into the target table.
SELECT
    dim_device_user_sk,
    device_id,
    user_id,
    valid_from,
    valid_to
FROM final_scd_records