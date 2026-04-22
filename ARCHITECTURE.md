# Architecture

## Data flow

```
┌───────────────────────────────────────────────────────────────────────┐
│  DGX host(s) — AWS / Azure / OCI / GCP                                │
│                                                                       │
│   ┌────────────────────┐       :9400                                  │
│   │  dcgm-exporter     │  ──── Prometheus text exposition ─┐          │
│   │  (NVIDIA)          │                                   │          │
│   └────────────────────┘                                   ▼          │
│                                        ┌──────────────────────────┐   │
│                                        │ OpenTelemetry Collector  │   │
│                                        │ (otelcol-contrib)        │   │
│                                        │                          │   │
│                                        │  prometheusreceiver      │   │
│                                        │    ↓                     │   │
│                                        │  resourceprocessor       │   │
│                                        │    (service.name, etc.)  │   │
│                                        │    ↓                     │   │
│                                        │  batchprocessor          │   │
│                                        │    ↓                     │   │
│                                        │  otlpexporter (gRPC)     │   │
│                                        │    + oauth2clientauth    │   │
│                                        └────────────┬─────────────┘   │
└─────────────────────────────────────────────────────┼─────────────────┘
                                                      │ OTLP/gRPC :443
                                                      │ Authorization: Bearer <token>
                                                      │ x-databricks-zerobus-table-name
                                                      ▼
        ┌──────────────────────────────────────────────────────────┐
        │  Databricks Zerobus Ingest (OTLP)                        │
        │  <workspace-id>.zerobus.<region>.cloud.databricks.com    │
        │                                                          │
        │  • validates each record against target table schema     │
        │  • flattens OTLP resource/scope/record into rows         │
        │  • persists attribute fields as VARIANT                  │
        │  • writes optimized Delta commits                        │
        └──────────────────────┬───────────────────────────────────┘
                               ▼
        ┌──────────────────────────────────────────────────────────┐
        │  Unity Catalog                                           │
        │  <catalog>.<schema>.<prefix>_otel_metrics                │
        │    USING DELTA                                           │
        │    CLUSTER BY (time, service_name)                       │
        │                                                          │
        │  Queryable immediately via Databricks SQL, Lakeview,     │
        │  Grafana (SQL warehouse), or any BI tool.                │
        └──────────────────────────────────────────────────────────┘
```

## Design rationale

### Collector-at-the-edge, not direct SDK export

Applications could technically open an OTLP gRPC stream to Zerobus
directly. Two reasons not to for a DGX fleet:

1. **OAuth token refresh.** Zerobus requires a service-principal OAuth
   token that expires every 60 minutes. The Collector's
   `oauth2clientauthextension` mints and rotates tokens against
   Databricks' OIDC endpoint automatically.
2. **Decoupling.** One collector owns the Databricks credentials; DGX
   hosts only need network path to the collector. Rotating a secret
   doesn't require redeploying any host agent.

### Prometheus receiver (not a DCGM-native OTel component)

NVIDIA ships DCGM telemetry as a Prometheus text exporter on :9400.
That's the de facto standard — every observability vendor scrapes it.
The OTel Collector's Prometheus receiver handles the scrape, relabel,
and conversion to OTLP, so we don't need to introduce a bespoke DCGM
OTel exporter.

### One collector per cloud/region

Each collector deployment can be scoped to a single cloud/region and
tagged accordingly, which keeps scrape traffic local (no
cross-cloud Prometheus pulls), minimizes cross-region OTLP egress, and
makes `cloud.provider` / `cloud.region` resource attributes trivial
to set authoritatively.

### Metric labels → OTLP datapoint attributes → VARIANT column

The mapping is:

| DCGM Prometheus label | OTLP datapoint attribute | Databricks column |
|---|---|---|
| `gpu="3"` | `gpu="3"` | `gauge:attributes:gpu::string` |
| `Hostname="dgx-aws-ue1-01"` | `Hostname="dgx-aws-ue1-01"` | `gauge:attributes:Hostname::string` |
| `cloud_provider="aws"` | `cloud_provider="aws"` | `gauge:attributes:cloud_provider::string` |

All of them land inside the `attributes` VARIANT in each metric's
struct (`gauge.attributes`, `sum.attributes`, etc.). `VARIANT` preserves
original types and supports shredding when `delta.enableVariantShredding`
is on, so attribute-key filters are fast.

`service.name` is special — it's promoted to a top-level column by
Zerobus, which is why the `resource` processor sets it explicitly
(`dgx-fleet-dcgm`). Queries can filter efficiently with
`WHERE service_name = 'dgx-fleet-dcgm'`.

## Scaling notes

- **Batching.** `send_batch_size: 500` in the demo config is modest.
  For real fleets tune to `send_batch_size: 2000`, `timeout: 10s`, and
  keep an eye on `exporter_sent_metric_points` / `exporter_send_failed`
  internal metrics in the collector.
- **Per-signal exporter is mandatory.** Every OTLP request goes to a
  single target table via the `x-databricks-zerobus-table-name`
  header. A collector exporting traces, logs, and metrics needs three
  exporters and three OAuth extensions (this demo only uses metrics).
- **Backpressure.** If the collector starts buffering, add a
  `memory_limiter` processor **before** `batch` — it will drop batches
  and surface clear errors instead of OOMing the host.
- **High availability.** Run N collector replicas behind a load
  balancer and let OTLP clients pick randomly; Zerobus handles the
  concurrent writers. Each replica manages its own OAuth token.

## Security considerations

- Service principal secret lives only on the collector host(s). DGX
  hosts never see it.
- `oauth2clientauthextension` scopes each token with explicit Unity
  Catalog privileges (`USE CATALOG`, `USE SCHEMA`, `SELECT`,
  `MODIFY`) in `authorization_details` — the token can't write to any
  other table in the workspace even if leaked.
- OTLP connection to Zerobus is gRPC over TLS (port 443). The
  collector-to-DCGM Prometheus scrape is plain HTTP on the internal
  network; enable HTTPS on `dcgm-exporter` if scraping across trust
  boundaries.
