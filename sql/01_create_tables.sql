-- NVIDIA DGX GPU Telemetry → Databricks Zerobus OTEL
-- =====================================================================
-- Before running: find-and-replace all three placeholders below
--   <catalog>                e.g. main
--   <schema>                 e.g. dgx_telemetry
--   <prefix>                 e.g. nvidia
--   <service-principal-uuid> e.g. 00000000-0000-0000-0000-000000000000
-- =====================================================================

-- Optional — skip if the catalog/schema already exist.
CREATE CATALOG IF NOT EXISTS <catalog>;
CREATE SCHEMA  IF NOT EXISTS <catalog>.<schema>;

-- ── Metrics table ─────────────────────────────────────────────────────
-- Schema is the exact shape Zerobus Ingest expects for OTLP metrics.
-- Any deviation will cause INVALID_ARGUMENT errors from the collector.

CREATE TABLE <catalog>.<schema>.<prefix>_otel_metrics (
  record_id            STRING,
  time                 TIMESTAMP,
  date                 DATE,
  service_name         STRING,
  start_time_unix_nano LONG,
  time_unix_nano       LONG,
  name                 STRING,
  description          STRING,
  unit                 STRING,
  metric_type          STRING,
  gauge STRUCT<
    value:       DOUBLE,
    exemplars:   ARRAY<STRUCT<
                   time_unix_nano:      LONG,
                   value:               DOUBLE,
                   span_id:             STRING,
                   trace_id:            STRING,
                   filtered_attributes: VARIANT>>,
    attributes:  VARIANT,
    flags:       INT>,
  sum STRUCT<
    value:                  DOUBLE,
    exemplars:              ARRAY<STRUCT<
                              time_unix_nano:      LONG,
                              value:               DOUBLE,
                              span_id:             STRING,
                              trace_id:            STRING,
                              filtered_attributes: VARIANT>>,
    attributes:             VARIANT,
    flags:                  INT,
    aggregation_temporality: STRING,
    is_monotonic:           BOOLEAN>,
  histogram STRUCT<
    count:                  LONG,
    sum:                    DOUBLE,
    bucket_counts:          ARRAY<LONG>,
    explicit_bounds:        ARRAY<DOUBLE>,
    exemplars:              ARRAY<STRUCT<
                              time_unix_nano:      LONG,
                              value:               DOUBLE,
                              span_id:             STRING,
                              trace_id:            STRING,
                              filtered_attributes: VARIANT>>,
    attributes:             VARIANT,
    flags:                  INT,
    min:                    DOUBLE,
    max:                    DOUBLE,
    aggregation_temporality: STRING>,
  exponential_histogram STRUCT<
    attributes:             VARIANT,
    count:                  LONG,
    sum:                    DOUBLE,
    scale:                  INT,
    zero_count:             LONG,
    positive_bucket:        STRUCT<offset: INT, bucket_counts: ARRAY<LONG>>,
    negative_bucket:        STRUCT<offset: INT, bucket_counts: ARRAY<LONG>>,
    flags:                  INT,
    exemplars:              ARRAY<STRUCT<
                              time_unix_nano:      LONG,
                              value:               DOUBLE,
                              span_id:             STRING,
                              trace_id:            STRING,
                              filtered_attributes: VARIANT>>,
    min:                    DOUBLE,
    max:                    DOUBLE,
    zero_threshold:         DOUBLE,
    aggregation_temporality: STRING>,
  summary STRUCT<
    count:           LONG,
    sum:             DOUBLE,
    quantile_values: ARRAY<STRUCT<quantile: DOUBLE, value: DOUBLE>>,
    attributes:      VARIANT,
    flags:           INT>,
  metadata              VARIANT,
  resource STRUCT<
    attributes:              VARIANT,
    dropped_attributes_count: INT>,
  resource_schema_url   STRING,
  instrumentation_scope STRUCT<
    name:                     STRING,
    version:                  STRING,
    attributes:               VARIANT,
    dropped_attributes_count: INT>,
  metric_schema_url     STRING
)
USING DELTA
CLUSTER BY (time, service_name)
TBLPROPERTIES (
  'otel.schemaVersion'                    = 'v2',
  'delta.checkpointPolicy'                = 'classic',
  'delta.enableVariantShredding'          = 'true',      -- optional, DBR 17.2+
  'delta.feature.variantShredding-preview' = 'supported', -- optional, DBR 17.2+
  'delta.feature.variantType-preview'     = 'supported'  -- optional, DBR 17.2+
);

-- ── Grants for the service principal ──────────────────────────────────
-- `GRANT ALL PRIVILEGES` is NOT sufficient. You must explicitly grant
-- MODIFY + SELECT on the table.

GRANT USE CATALOG ON CATALOG <catalog>                       TO `<service-principal-uuid>`;
GRANT USE SCHEMA  ON SCHEMA  <catalog>.<schema>              TO `<service-principal-uuid>`;
GRANT MODIFY, SELECT ON TABLE <catalog>.<schema>.<prefix>_otel_metrics TO `<service-principal-uuid>`;

-- Sanity check — should show USE CATALOG / USE SCHEMA / MODIFY / SELECT.
SHOW GRANTS `<service-principal-uuid>` ON TABLE <catalog>.<schema>.<prefix>_otel_metrics;
