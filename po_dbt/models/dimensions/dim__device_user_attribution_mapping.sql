-- dim__device_user_attribution_mapping
{{ config(
    materialized = 'incremental',
    unique_key = 'dim_device_user_attribution_mapping_sk', 
    incremental_strategy = 'merge',
    on_schema_change = 'sync_all_columns', 
    partition_by = {
        'field': 'valid_from',
        'data_type': 'timestamp',
        'granularity': 'day' 
    },
    cluster_by = ['dim_device_user_sk', 'attribution_unique_id'] 
) }}

{%- set future_timestamp = "TIMESTAMP('9999-12-31')" -%}
{# Use a single run_timestamp for consistency across valid_from and SK generation in this run #}
{%- set run_timestamp_cte = "SELECT CURRENT_TIMESTAMP() AS ts" -%}
{%- set run_ts_column = "(SELECT ts FROM run_timestamp_cte)" -%}


WITH run_timestamp_cte AS (
    {{ run_timestamp_cte }}
),

source_data AS (
    SELECT
        attrib.attribution_unique_id, -- Business key for the attribution event
        attrib.appsflyerid,
        attrib.device_id,
        attrib.mediasource,
        attrib.campaign,
        attrib.adset,
        attrib.installtime,
        attrib.platform,
        attrib.first_touch_timestamp,
        attrib.join_method,
        ddu.dim_device_user_sk, -- Foreign key to user/device dimension
        ddu.user_id,

        -- Hash of attributes that define a version of the attribution
        -- Not including attrib.installtime or attrib.first_touch_timestamp as they identify the event,
        -- not describe its mutable attributes for versioning.
        {{ dbt_utils.generate_surrogate_key([
            'ddu.dim_device_user_sk', 
            'attrib.mediasource',
            'attrib.campaign',
            'attrib.adset',
            'attrib.platform',
            'attrib.join_method'

        ]) }} AS version_hash

    FROM {{ ref('int_device_attributed_installs') }} attrib
    LEFT JOIN {{ ref('dim_device_users_scd') }} ddu
      ON attrib.device_id = ddu.device_id
     AND attrib.installtime BETWEEN ddu.valid_from AND ddu.valid_to -- Temporal join
    -- Optional: If stg_match_attrib is large, consider adding a WHERE clause here for incremental runs
    -- to only process recent attribution data, e.g., based on attrib.installtime or a load_timestamp.
    -- This depends on whether you expect very old attributions to change.
),

{% if is_incremental() %}

target_active_records AS (
    -- Select all columns needed for comparison and for re-selecting in records_to_update
    SELECT
        dim_device_user_attribution_mapping_sk,
        attribution_unique_id,
        appsflyerid,
        device_id,
        mediasource,
        campaign,
        adset,
        installtime,
        platform,
        first_touch_timestamp,
        join_method,
        dim_device_user_sk,
        user_id,
        version_hash, -- The hash of the currently active version in the target
        valid_from    -- Original valid_from of the active record
    FROM {{ this }}
    WHERE valid_to = {{ future_timestamp }}
),

-- Identifies records from source_data that are either brand new or are new versions of existing active records
new_or_updated_source_records AS (
    SELECT
        s.attribution_unique_id,
        s.appsflyerid,
        s.device_id,
        s.mediasource,
        s.campaign,
        s.adset,
        s.installtime,
        s.platform,
        s.first_touch_timestamp,
        s.join_method,
        s.dim_device_user_sk,
        s.user_id,
        s.version_hash,
        {{ run_ts_column }} AS new_valid_from -- All new/updated versions get the current run_timestamp
    FROM source_data s
    LEFT JOIN target_active_records ta
      ON s.attribution_unique_id = ta.attribution_unique_id
    WHERE ta.attribution_unique_id IS NULL -- Brand new attribution event
       OR s.version_hash != ta.version_hash -- Existing attribution event, but attributes changed
),

-- These are the new versions to be INSERTED.
-- Their dim_device_user_attribution_mapping_sk will be new.
records_to_insert AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['s.attribution_unique_id', 's.new_valid_from']) }} AS dim_device_user_attribution_mapping_sk,
        s.attribution_unique_id,
        s.appsflyerid,
        s.device_id,
        s.mediasource,
        s.campaign,
        s.adset,
        s.installtime,
        s.platform,
        s.first_touch_timestamp,
        s.join_method,
        s.dim_device_user_sk,
        s.user_id,
        s.version_hash,
        s.new_valid_from AS valid_from,
        {{ future_timestamp }} AS valid_to
    FROM new_or_updated_source_records s
),

-- These are existing active records in the target that need to be closed out (their valid_to updated).
-- Their dim_device_user_attribution_mapping_sk already exists, so MERGE will UPDATE them.
records_to_update_valid_to AS (
    SELECT
        ta.dim_device_user_attribution_mapping_sk, -- Use existing SK from target
        ta.attribution_unique_id,
        ta.appsflyerid,
        ta.device_id,
        ta.mediasource,
        ta.campaign,
        ta.adset,
        ta.installtime,
        ta.platform,
        ta.first_touch_timestamp,
        ta.join_method,
        ta.dim_device_user_sk,
        ta.user_id,
        ta.version_hash,    -- This is the old version_hash
        ta.valid_from,      -- This is the original valid_from
        upd.new_valid_from AS valid_to -- Expire with the valid_from of the new incoming version
    FROM target_active_records ta
    INNER JOIN new_or_updated_source_records upd -- Join to records identified as new/changed from source
      ON ta.attribution_unique_id = upd.attribution_unique_id
    -- This join ensures we only "expire" target records for which a new version (from upd) is being processed.
    -- The condition `upd.version_hash != ta.version_hash` is implicitly handled by how upd is built.
)

-- Union the records to be inserted (new versions) and records to be updated (old versions being closed)
SELECT * FROM records_to_insert
UNION ALL
SELECT * FROM records_to_update_valid_to

{% else %} -- This is for a full refresh (e.g., dbt run --full-refresh)
final AS (
SELECT
    {{ dbt_utils.generate_surrogate_key(['s.attribution_unique_id', run_ts_column]) }} AS dim_device_user_attribution_mapping_sk,
    s.attribution_unique_id,
    s.appsflyerid,
    s.device_id,
    s.mediasource,
    s.campaign,
    s.adset,
    s.installtime,
    s.platform,
    s.first_touch_timestamp,
    s.join_method,
    s.dim_device_user_sk,
    s.user_id,
    s.version_hash,
    {{ run_ts_column }} AS valid_from,
    {{ future_timestamp }} AS valid_to
FROM source_data s
)
select * from final
{% endif %}