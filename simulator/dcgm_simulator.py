"""DCGM-exporter-shaped Prometheus simulator.

Emits NVIDIA DCGM metrics in the exact Prometheus label/name shape that
``dcgm-exporter`` uses, for a fake fleet of DGX hosts spread across
AWS, Azure, OCI, and GCP. Useful for developing and demoing telemetry
pipelines without a real GPU.

Run:
    uv sync
    uv run python dcgm_simulator.py
"""

from __future__ import annotations

import argparse
import random
import signal
import sys
import time
import uuid
from dataclasses import dataclass, field

from prometheus_client import Gauge, start_http_server


# ─────────────────────────────────────────────────────────────────────
# Fleet definition — 8 hosts × 8 GPUs each = 64 fake H100s across 4 clouds.
# Edit fleet_spec below to grow/shrink the fleet.
# ─────────────────────────────────────────────────────────────────────

@dataclass
class FakeGpu:
    hostname: str
    cloud_provider: str
    cloud_region: str
    gpu_index: int
    gpu_uuid: str
    pci_bus_id: str
    model_name: str
    # mutable state (advances on each tick)
    util: float = 0.0
    temp: float = 40.0
    power: float = 80.0
    fb_used: float = 0.0
    fb_total: float = 81920.0  # 80 GiB H100, in MiB
    sm_clock: float = 1980.0
    mem_clock: float = 2619.0
    xid_last: int = 0
    nvlink_bw: float = 0.0


def build_fleet() -> list[FakeGpu]:
    fleet_spec = [
        ("aws",   "us-east-1",    "dgx-aws-ue1-01"),
        ("aws",   "us-west-2",    "dgx-aws-uw2-01"),
        ("azure", "eastus2",      "dgx-az-eu2-01"),
        ("azure", "westeurope",   "dgx-az-weu-01"),
        ("oci",   "us-phoenix-1", "dgx-oci-phx-01"),
        ("oci",   "uk-london-1",  "dgx-oci-lhr-01"),
        ("gcp",   "us-central1",  "dgx-gcp-usc1-01"),
        ("gcp",   "europe-west4", "dgx-gcp-ew4-01"),
    ]
    fleet: list[FakeGpu] = []
    for cloud, region, host in fleet_spec:
        for gpu_idx in range(8):  # 8 GPUs/host, typical DGX H100
            fleet.append(FakeGpu(
                hostname=host,
                cloud_provider=cloud,
                cloud_region=region,
                gpu_index=gpu_idx,
                gpu_uuid=f"GPU-{uuid.uuid5(uuid.NAMESPACE_DNS, f'{host}-{gpu_idx}')}",
                pci_bus_id=f"00000000:{0x10 + gpu_idx:02X}:00.0",
                model_name="NVIDIA H100 80GB HBM3",
            ))
    return fleet


# ─────────────────────────────────────────────────────────────────────
# Metric definitions — names, help text, and labels match dcgm-exporter.
# ─────────────────────────────────────────────────────────────────────

LABELS = [
    "gpu", "uuid", "device", "modelName", "Hostname",
    "pci_bus_id", "cloud_provider", "cloud_region",
]

METRICS = {
    "DCGM_FI_DEV_GPU_UTIL":
        Gauge("DCGM_FI_DEV_GPU_UTIL",
              "GPU utilization (in %)", LABELS),
    "DCGM_FI_DEV_MEM_COPY_UTIL":
        Gauge("DCGM_FI_DEV_MEM_COPY_UTIL",
              "Memory utilization (in %)", LABELS),
    "DCGM_FI_DEV_GPU_TEMP":
        Gauge("DCGM_FI_DEV_GPU_TEMP",
              "GPU temperature (in C)", LABELS),
    "DCGM_FI_DEV_POWER_USAGE":
        Gauge("DCGM_FI_DEV_POWER_USAGE",
              "Power draw (in W)", LABELS),
    "DCGM_FI_DEV_FB_USED":
        Gauge("DCGM_FI_DEV_FB_USED",
              "Framebuffer memory used (in MiB)", LABELS),
    "DCGM_FI_DEV_FB_FREE":
        Gauge("DCGM_FI_DEV_FB_FREE",
              "Framebuffer memory free (in MiB)", LABELS),
    "DCGM_FI_DEV_SM_CLOCK":
        Gauge("DCGM_FI_DEV_SM_CLOCK",
              "SM clock frequency (in MHz)", LABELS),
    "DCGM_FI_DEV_MEM_CLOCK":
        Gauge("DCGM_FI_DEV_MEM_CLOCK",
              "Memory clock frequency (in MHz)", LABELS),
    "DCGM_FI_DEV_XID_ERRORS":
        Gauge("DCGM_FI_DEV_XID_ERRORS",
              "Value of the last XID error encountered", LABELS),
    "DCGM_FI_PROF_GR_ENGINE_ACTIVE":
        Gauge("DCGM_FI_PROF_GR_ENGINE_ACTIVE",
              "Ratio of time the graphics engine is active (0-1)", LABELS),
    "DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL":
        Gauge("DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL",
              "Total NVLink bandwidth counter (MB)", LABELS),
}


# ─────────────────────────────────────────────────────────────────────
# Dynamics — advance state plausibly each tick and write Prometheus values.
# ─────────────────────────────────────────────────────────────────────

def step_gpu(gpu: FakeGpu) -> None:
    # Utilization: mostly busy, occasional dip to simulate job transitions.
    target_util = 95.0 if random.random() < 0.85 else 10.0
    gpu.util += (target_util - gpu.util) * 0.3 + random.uniform(-5, 5)
    gpu.util = max(0.0, min(100.0, gpu.util))

    # Framebuffer: busy GPUs hold ~75% of VRAM; idle ones ~10%.
    target_fb = gpu.fb_total * (0.75 if gpu.util > 50 else 0.1)
    gpu.fb_used += (target_fb - gpu.fb_used) * 0.1 + random.uniform(-500, 500)
    gpu.fb_used = max(0.0, min(gpu.fb_total, gpu.fb_used))

    # Temperature and power track utilization.
    target_temp = 40.0 + gpu.util * 0.5
    gpu.temp += (target_temp - gpu.temp) * 0.2 + random.uniform(-1, 1)
    target_power = 80.0 + gpu.util * 6.0  # H100 TDP ~700W
    gpu.power += (target_power - gpu.power) * 0.3 + random.uniform(-10, 10)
    gpu.power = max(50.0, gpu.power)

    # Clocks: throttle if running hot (>85C).
    gpu.sm_clock = 1410.0 if gpu.temp > 85.0 else 1980.0

    # NVLink bandwidth: cumulative counter, grows with utilization.
    gpu.nvlink_bw += gpu.util * 50.0 + random.uniform(0, 500)

    # Rare XID hardware event — ~1 per ~2000 ticks per GPU.
    if random.random() < 0.0005:
        gpu.xid_last = random.choice([13, 31, 43, 74, 79])


def emit(gpu: FakeGpu) -> None:
    labels = {
        "gpu":            str(gpu.gpu_index),
        "uuid":           gpu.gpu_uuid,
        "device":         f"nvidia{gpu.gpu_index}",
        "modelName":      gpu.model_name,
        "Hostname":       gpu.hostname,
        "pci_bus_id":     gpu.pci_bus_id,
        "cloud_provider": gpu.cloud_provider,
        "cloud_region":   gpu.cloud_region,
    }
    METRICS["DCGM_FI_DEV_GPU_UTIL"].labels(**labels).set(gpu.util)
    METRICS["DCGM_FI_DEV_MEM_COPY_UTIL"].labels(**labels).set(gpu.util * 0.7)
    METRICS["DCGM_FI_DEV_GPU_TEMP"].labels(**labels).set(gpu.temp)
    METRICS["DCGM_FI_DEV_POWER_USAGE"].labels(**labels).set(gpu.power)
    METRICS["DCGM_FI_DEV_FB_USED"].labels(**labels).set(gpu.fb_used)
    METRICS["DCGM_FI_DEV_FB_FREE"].labels(**labels).set(gpu.fb_total - gpu.fb_used)
    METRICS["DCGM_FI_DEV_SM_CLOCK"].labels(**labels).set(gpu.sm_clock)
    METRICS["DCGM_FI_DEV_MEM_CLOCK"].labels(**labels).set(gpu.mem_clock)
    METRICS["DCGM_FI_DEV_XID_ERRORS"].labels(**labels).set(gpu.xid_last)
    METRICS["DCGM_FI_PROF_GR_ENGINE_ACTIVE"].labels(**labels).set(gpu.util / 100.0)
    METRICS["DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL"].labels(**labels).set(gpu.nvlink_bw)


# ─────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=9400,
                        help="port to expose /metrics on (default: 9400)")
    parser.add_argument("--interval", type=float, default=1.0,
                        help="seconds between state updates (default: 1.0)")
    parser.add_argument("--seed", type=int, default=42,
                        help="random seed for reproducible demos")
    args = parser.parse_args()

    random.seed(args.seed)
    fleet = build_fleet()

    n_clouds = len({g.cloud_provider for g in fleet})
    n_hosts = len({g.hostname for g in fleet})
    print(f"Simulating {len(fleet)} GPUs across {n_clouds} clouds, "
          f"{n_hosts} hosts.", file=sys.stderr, flush=True)

    # Warm up state so the first scrape isn't all zeros.
    for gpu in fleet:
        for _ in range(10):
            step_gpu(gpu)
        emit(gpu)

    start_http_server(args.port)
    print(f"DCGM simulator listening on http://0.0.0.0:{args.port}/metrics",
          file=sys.stderr, flush=True)

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    try:
        while True:
            for gpu in fleet:
                step_gpu(gpu)
                emit(gpu)
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("shutting down", file=sys.stderr)


if __name__ == "__main__":
    main()
