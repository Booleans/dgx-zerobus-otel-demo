-- Fleet analysis queries — run these against the otel_metrics table
-- after Steps 4–6 of the README are producing data.
--
-- Replace <catalog>.<schema>.<prefix> with your values.

USE CATALOG <catalog>;
USE SCHEMA  <schema>;

-- =====================================================================
-- 0. Ingest sanity — rows landing per minute over the last 15 minutes
-- =====================================================================
SELECT
  date_trunc('minute', time) AS minute,
  count(*)                   AS rows_ingested,
  count(DISTINCT name)       AS distinct_metrics
FROM <prefix>_otel_metrics
WHERE date >= current_date() - 1
  AND time >= current_timestamp() - INTERVAL 15 MINUTES
GROUP BY minute
ORDER BY minute DESC;

-- =====================================================================
-- 1. Per-cloud / per-region GPU utilization (p50 / p95 / p99), last hour
-- =====================================================================
SELECT
  gauge:attributes:cloud_provider::string AS cloud,
  gauge:attributes:cloud_region::string   AS region,
  percentile(gauge.value, 0.50) AS util_p50_pct,
  percentile(gauge.value, 0.95) AS util_p95_pct,
  percentile(gauge.value, 0.99) AS util_p99_pct,
  count(*)                      AS samples
FROM <prefix>_otel_metrics
WHERE name = 'DCGM_FI_DEV_GPU_UTIL'
  AND time >= current_timestamp() - INTERVAL 1 HOUR
GROUP BY cloud, region
ORDER BY cloud, region;

-- =====================================================================
-- 2. Top 10 hottest GPUs across the fleet right now
-- =====================================================================
WITH latest AS (
  SELECT
    gauge:attributes:Hostname::string       AS host,
    gauge:attributes:cloud_provider::string AS cloud,
    gauge:attributes:cloud_region::string   AS region,
    gauge:attributes:gpu::string            AS gpu_idx,
    gauge:attributes:uuid::string           AS gpu_uuid,
    gauge.value                             AS temp_c,
    time,
    row_number() OVER (
      PARTITION BY gauge:attributes:uuid::string
      ORDER BY time DESC
    ) AS rn
  FROM <prefix>_otel_metrics
  WHERE name = 'DCGM_FI_DEV_GPU_TEMP'
    AND time >= current_timestamp() - INTERVAL 5 MINUTES
)
SELECT host, cloud, region, gpu_idx, gpu_uuid, temp_c, time
FROM latest
WHERE rn = 1
ORDER BY temp_c DESC
LIMIT 10;

-- =====================================================================
-- 3. XID hardware error rate by cloud/region, last 24h
--    XID > 0 signals a driver/hardware event — these are what the
--    DGX ops team wants to see immediately.
-- =====================================================================
SELECT
  gauge:attributes:cloud_provider::string AS cloud,
  gauge:attributes:cloud_region::string   AS region,
  max(gauge.value)                        AS max_xid_seen,
  count(DISTINCT gauge:attributes:uuid::string) AS gpus_affected
FROM <prefix>_otel_metrics
WHERE name = 'DCGM_FI_DEV_XID_ERRORS'
  AND time >= current_timestamp() - INTERVAL 24 HOURS
  AND gauge.value > 0
GROUP BY cloud, region
ORDER BY gpus_affected DESC, max_xid_seen DESC;

-- =====================================================================
-- 4. Fleet power draw timeseries (kW) by cloud, last 6 hours
-- =====================================================================
SELECT
  gauge:attributes:cloud_provider::string AS cloud,
  date_trunc('minute', time)              AS minute,
  sum(gauge.value) / 1000.0               AS kilowatts
FROM <prefix>_otel_metrics
WHERE name = 'DCGM_FI_DEV_POWER_USAGE'
  AND time >= current_timestamp() - INTERVAL 6 HOURS
GROUP BY cloud, minute
ORDER BY minute DESC, cloud;

-- =====================================================================
-- 5. GPU memory pressure — GPUs with > 80% framebuffer used
-- =====================================================================
WITH latest_mem AS (
  SELECT
    gauge:attributes:Hostname::string AS host,
    gauge:attributes:uuid::string     AS gpu_uuid,
    name,
    gauge.value                       AS mib,
    time,
    row_number() OVER (
      PARTITION BY gauge:attributes:uuid::string, name
      ORDER BY time DESC
    ) AS rn
  FROM <prefix>_otel_metrics
  WHERE name IN ('DCGM_FI_DEV_FB_USED', 'DCGM_FI_DEV_FB_FREE')
    AND time >= current_timestamp() - INTERVAL 5 MINUTES
),
pivot AS (
  SELECT
    host,
    gpu_uuid,
    max(CASE WHEN name = 'DCGM_FI_DEV_FB_USED' THEN mib END) AS used_mib,
    max(CASE WHEN name = 'DCGM_FI_DEV_FB_FREE' THEN mib END) AS free_mib
  FROM latest_mem
  WHERE rn = 1
  GROUP BY host, gpu_uuid
)
SELECT
  host,
  gpu_uuid,
  used_mib,
  free_mib,
  round(100.0 * used_mib / (used_mib + free_mib), 1) AS pct_used
FROM pivot
WHERE used_mib / nullif(used_mib + free_mib, 0) > 0.80
ORDER BY pct_used DESC;

-- =====================================================================
-- 6. Under-utilized GPUs (p95 util < 10% over last hour)
--    Candidates for cost reclamation / right-sizing.
-- =====================================================================
SELECT
  gauge:attributes:cloud_provider::string AS cloud,
  gauge:attributes:cloud_region::string   AS region,
  gauge:attributes:Hostname::string       AS host,
  gauge:attributes:uuid::string           AS gpu_uuid,
  percentile(gauge.value, 0.95)           AS util_p95,
  avg(gauge.value)                        AS util_avg,
  count(*)                                AS samples
FROM <prefix>_otel_metrics
WHERE name = 'DCGM_FI_DEV_GPU_UTIL'
  AND time >= current_timestamp() - INTERVAL 1 HOUR
GROUP BY cloud, region, host, gpu_uuid
HAVING percentile(gauge.value, 0.95) < 10
ORDER BY util_avg ASC;

-- =====================================================================
-- 7. Thermal throttling events — SM clock below rated 1980 MHz
--    while temp above 85C. Correlates environmental/cooling issues
--    to performance loss.
-- =====================================================================
WITH per_gpu AS (
  SELECT
    time,
    gauge:attributes:Hostname::string       AS host,
    gauge:attributes:cloud_provider::string AS cloud,
    gauge:attributes:uuid::string           AS gpu_uuid,
    name,
    gauge.value                             AS val
  FROM <prefix>_otel_metrics
  WHERE name IN ('DCGM_FI_DEV_GPU_TEMP', 'DCGM_FI_DEV_SM_CLOCK')
    AND time >= current_timestamp() - INTERVAL 1 HOUR
),
pivot AS (
  SELECT
    date_trunc('minute', time) AS minute,
    host, cloud, gpu_uuid,
    max(CASE WHEN name = 'DCGM_FI_DEV_GPU_TEMP' THEN val END)  AS temp_c,
    max(CASE WHEN name = 'DCGM_FI_DEV_SM_CLOCK' THEN val END) AS sm_clock_mhz
  FROM per_gpu
  GROUP BY minute, host, cloud, gpu_uuid
)
SELECT cloud, host, gpu_uuid, minute, temp_c, sm_clock_mhz
FROM pivot
WHERE temp_c > 85
  AND sm_clock_mhz < 1980
ORDER BY minute DESC, temp_c DESC;
