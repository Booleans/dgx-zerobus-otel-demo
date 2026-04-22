# NVIDIA DGX GPU Telemetry → Databricks Zerobus OTEL

A runnable demo for the NVIDIA DGX team showing how to ingest DCGM GPU
telemetry from a multi-cloud DGX fleet (AWS, Azure, OCI, GCP) into a
Unity Catalog Delta table via Databricks' Zerobus OpenTelemetry endpoint.

```
 dcgm-exporter (or simulator)  →  OTel Collector  →  Zerobus OTLP  →  Delta (Unity Catalog)
                 :9400                   otlp/gRPC :443                   <catalog>.<schema>.<prefix>_otel_metrics
```

See `ARCHITECTURE.md` for the full data flow and design rationale.

The simulator in `simulator/` lets you run the whole demo on a laptop —
no real GPU, no Docker. Swap the scrape target for a real
`dcgm-exporter` when you're ready to point at a DGX fleet.

---

## Repo layout

```
.
├── README.md                          ← you are here
├── ARCHITECTURE.md                    ← data flow + design notes
├── .env.example                       ← fill this in, copy to .env
├── sql/
│   ├── 01_create_tables.sql           ← otel_metrics DDL + grants
│   └── 02_fleet_analysis_queries.sql  ← demo queries on the fleet
├── collector/
│   └── collector.yaml                 ← OTel Collector config
└── simulator/
    ├── pyproject.toml                 ← uv-managed Python project
    ├── .python-version
    └── dcgm_simulator.py              ← emits DCGM-shaped metrics on :9400
```

---

## Prerequisites

- Databricks workspace with Unity Catalog and **Zerobus Ingest (Beta)**
  enabled in its region (AWS, Azure, or GCP workspaces supported).
- A SQL warehouse on **DBR 15.3+** (17.2+ recommended for VARIANT
  shredding).
- Local tools:

  **macOS**
  ```bash
  brew install uv
  brew install open-telemetry/tap/otelcol-contrib  # OTel Collector contrib distro
  ```

  **Linux**
  ```bash
  curl -LsSf https://astral.sh/uv/install.sh | sh
  # grab the contrib collector binary for your arch from:
  # https://github.com/open-telemetry/opentelemetry-collector-releases/releases
  # (filename looks like otelcol-contrib_<ver>_linux_amd64.tar.gz)
  ```

  Verify:
  ```bash
  uv --version
  otelcol-contrib --version
  ```

---

## Step 1 — Create the target table in Unity Catalog

1. Open `sql/01_create_tables.sql` and replace every occurrence of
   `<catalog>`, `<schema>`, and `<prefix>` with real values (e.g.
   `main`, `dgx_telemetry`, `nvidia`). These must match what you put in
   `.env` later.
2. Run the `CREATE TABLE` block in the Databricks SQL editor.
3. Come back to the grants block later (Step 2 needs the service
   principal UUID).

The table uses the exact schema Zerobus expects for OTLP metrics,
including `gauge`, `sum`, `histogram`, `exponential_histogram`, and
`summary` structs, with attribute fields as `VARIANT`.

---

## Step 2 — Create the service principal + grants

1. In the Databricks workspace, go to **Settings → Identity and access
   → Service principals → Add service principal**. Give it a name
   (e.g. `zerobus-dgx-otel`).
2. On the service principal's **Configurations** tab, copy the
   **Application ID (UUID)** — this is both the OAuth `client_id` and
   the principal identifier used in `GRANT` statements.
3. Generate an **OAuth secret**: click **Generate secret** under the
   credentials section. Copy the `Client ID` and `Secret` now; the
   secret won't be shown again. (Do **not** use a PAT here — Zerobus
   OAuth requires a service principal secret.)
4. Back in `sql/01_create_tables.sql`, replace `<service-principal-uuid>`
   in the `GRANT` block with the Application ID from step 2, then run
   the grants.

> Important: `GRANT ALL PRIVILEGES` is **not** sufficient. You must
> explicitly grant `MODIFY` and `SELECT` on each table.

---

## Step 3 — Fill in environment variables

```bash
cp .env.example .env
```

Edit `.env`:

| Variable | Where to find it |
|---|---|
| `WORKSPACE_URL` | The host part of your workspace URL, no scheme (e.g. `dbc-a1b2c3d4-e5f6.cloud.databricks.com`). |
| `WORKSPACE_ID` | Numeric ID — look for `o=<digits>` in the workspace URL, or **Admin Settings → Workspace → Workspace ID**. |
| `REGION` | Cloud region of the workspace (e.g. `us-west-2`, `eastus2`, `us-central1`). |
| `DATABRICKS_CLIENT_ID` / `DATABRICKS_CLIENT_SECRET` | From Step 2. |
| `CATALOG` / `SCHEMA` / `TABLE_PREFIX` | Match exactly what you used in Step 1. |

The Zerobus gRPC endpoint is derived automatically:
`${WORKSPACE_ID}.zerobus.${REGION}.cloud.databricks.com:443`.

---

## Step 4 — Start the DCGM simulator

```bash
cd simulator
uv sync
uv run python dcgm_simulator.py
```

`uv sync` creates `.venv/` inside `simulator/` and installs
`prometheus-client`. `uv run` executes the script using that venv — no
manual `activate` needed. If you prefer, you can activate it yourself:

```bash
source .venv/bin/activate
python dcgm_simulator.py
```

You'll see:

```
Simulating 64 GPUs across 4 clouds, 8 hosts.
DCGM simulator listening on http://0.0.0.0:9400/metrics
```

Verify from another terminal:

```bash
curl -s localhost:9400/metrics | grep DCGM_FI_DEV_GPU_UTIL | head
```

You should see 64 rows (8 hosts × 8 GPUs) spanning `aws`, `azure`,
`oci`, `gcp`.

---

## Step 5 — Start the OpenTelemetry Collector

In a **second terminal** (leave the simulator running):

```bash
cd /Users/andrew.nicholls/Desktop/zerobus-otel-isaac
set -a; source .env; set +a
otelcol-contrib --config collector/collector.yaml
```

Watch for these signals in the collector logs:

- `Scrape pool started job=dcgm` — Prometheus receiver is live.
- `oauth2clientauth` startup without errors — it successfully minted
  the initial OAuth token.
- No red `Exporter failed` messages every ~5 seconds — metrics are
  flowing to Zerobus.

If you see `PERMISSION_DENIED`, re-check grants in Step 2. If you see
`UNAUTHENTICATED`, re-check `DATABRICKS_CLIENT_ID` /
`DATABRICKS_CLIENT_SECRET` and the `WORKSPACE_URL` (no `https://`
prefix, no trailing slash).

---

## Step 6 — Verify data in Databricks

Within ~10 seconds of a healthy collector run, rows should start
landing. In the Databricks SQL editor (replace the table name):

```sql
SELECT
  time,
  service_name,
  name,
  gauge.value,
  gauge:attributes:Hostname::string    AS host,
  gauge:attributes:cloud_provider::string AS cloud,
  gauge:attributes:cloud_region::string   AS region,
  gauge:attributes:gpu::string            AS gpu_idx
FROM main.dgx_telemetry.nvidia_otel_metrics
WHERE date = current_date()
ORDER BY time DESC
LIMIT 20;
```

You should see rows for `DCGM_FI_DEV_GPU_UTIL`,
`DCGM_FI_DEV_GPU_TEMP`, `DCGM_FI_DEV_POWER_USAGE`, etc.

---

## Step 7 — Run the fleet-analysis queries

Open `sql/02_fleet_analysis_queries.sql` and run each block. You'll
get:

- Ingest throughput over the last 15 minutes
- Per-cloud GPU utilization (p50 / p95 / p99)
- Top 10 hottest GPUs across the fleet, right now
- XID hardware-error rate by cloud/region (last 24h)
- Fleet power draw in kW by cloud (last 6h)
- Memory-pressured GPUs (FB > 80% used)
- Under-utilized GPUs (p95 util < 10% for an hour — cost-cut candidates)

Point a dashboard (Lakeview, Grafana via SQL warehouse, or a BI tool)
at these queries for a live fleet operations view.

---

## Swapping the simulator for a real DGX fleet

Everything to the right of `:9400` already works against real DCGM
data.

1. **Install `dcgm-exporter`** on each DGX host. NVIDIA publishes it as
   a container and a standalone binary; see
   `https://github.com/NVIDIA/dcgm-exporter`. It exposes the same
   Prometheus endpoint on `:9400`.

2. **Edit `collector/collector.yaml`**, replacing the simulator scrape
   target:

   ```yaml
   receivers:
     prometheus/dcgm:
       config:
         scrape_configs:
           - job_name: dcgm
             scrape_interval: 10s
             static_configs:
               - targets:
                   - dgx-host-01.aws.internal:9400
                   - dgx-host-02.aws.internal:9400
                   # ...
   ```

   Or use Kubernetes service discovery (`kubernetes_sd_configs`) if
   DCGM runs as a DaemonSet.

3. **Inject cloud context.** DCGM doesn't know which cloud or region
   it's running in. Use the `resource` processor (already in
   `collector.yaml` — just uncomment the commented block) or set
   Prometheus `external_labels` on each scrape job so those fields
   land on every metric:

   ```yaml
   scrape_configs:
     - job_name: dcgm-aws-us-east-1
       static_configs:
         - targets: [...]
           labels:
             cloud_provider: aws
             cloud_region: us-east-1
   ```

4. **One collector per cloud/region** is usually cleanest — keeps
   scrape traffic on-cloud and pushes only OTLP bytes egress. The same
   `collector.yaml` works; just deploy it as a systemd unit or a
   sidecar DaemonSet next to DCGM.

5. **Tune the batch exporter** for fleet size. For hundreds of hosts,
   `send_batch_size: 2000`, `timeout: 10s` is a reasonable starting
   point.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Collector logs `NOT_FOUND: table ...` | Table name in `.env` doesn't match what you created in Step 1, or the SP lacks `USE CATALOG` / `USE SCHEMA`. |
| `PERMISSION_DENIED` | SP missing `MODIFY` on the table. Re-run Step 2 grants. |
| `UNAUTHENTICATED` | Bad client ID/secret, or `WORKSPACE_URL` has a scheme/trailing slash. Strip it. |
| `INVALID_ARGUMENT: ... schema mismatch` | You edited the table DDL. Drop and re-create from `sql/01_create_tables.sql` unmodified. |
| No data in Databricks but collector logs look fine | Confirm `x-databricks-zerobus-table-name` header by enabling the `debug` exporter in `collector.yaml`. |
| `curl localhost:9400/metrics` returns nothing | Simulator isn't running or port 9400 is blocked. |

---

## References

- [Configure OpenTelemetry (OTLP) clients to send data to Unity Catalog](https://docs.databricks.com/aws/en/ingestion/opentelemetry/configure)
- [OpenTelemetry table reference for Zerobus Ingest](https://docs.databricks.com/aws/en/ingestion/opentelemetry/table-reference)
- [Zerobus Ingest connector overview](https://docs.databricks.com/aws/en/ingestion/zerobus-overview)
- [NVIDIA DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter)
- [Your Telemetry, Your Lakehouse: Introducing Native OpenTelemetry Support in Zerobus Ingest](https://community.databricks.com/t5/technical-blog/your-telemetry-your-lakehouse-introducing-native-opentelemetry/ba-p/153976)
