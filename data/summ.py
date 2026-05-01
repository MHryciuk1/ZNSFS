#!/usr/bin/env python3

import pandas as pd
from pathlib import Path

INPUT_FILES = [
    "zlfs_results1.csv",
    "zlfs_results2.csv",
    "zlfs_results3.csv",
]

OUT = "zlfs_results_aggregated.csv"

group_cols = [
    "filesystem",
    "workload",
    "block_size",
    "queue_depth",
]

metric_cols = [
    "bandwidth_KBps",
    "iops",
    "lat_mean_ns",
    "lat_p99_ns",
    "lat_p999_ns",
    "lat_p9999_ns",
    "write_amplification",
    "zone_resets",
]

dfs = []

for i, filename in enumerate(INPUT_FILES, start=1):
    path = Path(filename)
    if not path.exists():
        raise FileNotFoundError(f"Missing input file: {filename}")

    df = pd.read_csv(path)
    df["source_run"] = i
    dfs.append(df)

combined = pd.concat(dfs, ignore_index=True)

for col in metric_cols:
    combined[col] = pd.to_numeric(combined[col], errors="coerce")

aggregated = (
    combined
    .groupby(group_cols, as_index=False)[metric_cols]
    .mean()
)

# Keep original-style run column
aggregated.insert(4, "run", 1)

# Match original column order
original_cols = [
    "filesystem",
    "workload",
    "block_size",
    "queue_depth",
    "run",
    "bandwidth_KBps",
    "iops",
    "lat_mean_ns",
    "lat_p99_ns",
    "lat_p999_ns",
    "lat_p9999_ns",
    "write_amplification",
    "zone_resets",
]

aggregated = aggregated[original_cols]
aggregated.to_csv(OUT, index=False)

print(f"Wrote: {OUT}")
