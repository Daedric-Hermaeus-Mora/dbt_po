{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key=['id'],
        tags=['analytics'],
    )
}}

with source_data as(
  select
    to_hex(sha1(concat(device_id, platform, app_version, os_version))) as id,
    device_id,
    app_version,
    os_version,
    adid,
    idfv,
    idfa,
    min(first_touch_timestamp) as valid_from
from {{ ref('stg_devices') }}
where device_id is not null
and 
    app_version is not null 
and 
    os_version is not null
group by all 
),


{% if is_incremental() %}
combined_data as(
    select
        * EXCEPT(valid_to)
    from {{ this }}
    union all
    select * from source_data
),
{% else %}
combined_data as(
    select
        *
    from source_data
),
{% endif %}


dedup as(
    select
        *
    from combined_data
    qualify row_number() over (partition by id order by valid_from asc) = 1
)

select
    *,
    coalesce(
        datetime_sub(
            lead(valid_from, 1) over (
                partition by device_id order by valid_from
            ),
            interval 1 microsecond
        ),
        timestamp('9999-12-31 23:59:59')
    ) as valid_to
from dedup