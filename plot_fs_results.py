#!/usr/bin/env python3

import argparse
from pathlib import Path

import pandas as pd
import matplotlib.pyplot as plt


METRICS = {
    "bandwidth_MBps": "Bandwidth (MB/s)",
    "iops": "IOPS",
    "lat_mean_us": "Mean latency (us)",
    "lat_p99_us": "P99 latency (us)",
    "lat_p999_us": "P99.9 latency (us)",
    "write_amplification": "Write amplification",
}


def load_csv(path: Path, fs_name: str | None) -> pd.DataFrame:
    df = pd.read_csv(path)

    if fs_name is not None:
        df["filesystem"] = fs_name

    required = {
        "filesystem",
        "workload",
        "block_size",
        "queue_depth",
        "bandwidth_KBps",
        "iops",
        "lat_mean_ns",
        "lat_p99_ns",
        "lat_p999_ns",
        "write_amplification",
    }

    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"{path} is missing columns: {sorted(missing)}")

    numeric_cols = [
        "queue_depth",
        "bandwidth_KBps",
        "iops",
        "lat_mean_ns",
        "lat_p99_ns",
        "lat_p999_ns",
        "write_amplification",
    ]

    for col in numeric_cols:
        df[col] = pd.to_numeric(df[col], errors="coerce")

    # Derived units for nicer plots
    df["bandwidth_MBps"] = df["bandwidth_KBps"] / 1024.0
    df["lat_mean_us"] = df["lat_mean_ns"] / 1000.0
    df["lat_p99_us"] = df["lat_p99_ns"] / 1000.0
    df["lat_p999_us"] = df["lat_p999_ns"] / 1000.0

    return df


def block_size_sort_key(bs: str) -> int:
    bs = str(bs).strip().lower()

    if bs.endswith("k"):
        return int(float(bs[:-1]) * 1024)
    if bs.endswith("m"):
        return int(float(bs[:-1]) * 1024 * 1024)
    if bs.endswith("g"):
        return int(float(bs[:-1]) * 1024 * 1024 * 1024)

    return int(float(bs))


def aggregate(df: pd.DataFrame) -> pd.DataFrame:
    group_cols = ["filesystem", "workload", "block_size", "queue_depth"]

    metric_cols = list(METRICS.keys())

    agg = (
        df.groupby(group_cols, as_index=False)
        .agg({col: ["mean", "std"] for col in metric_cols})
    )

    agg.columns = [
        "_".join(c).strip("_") if isinstance(c, tuple) else c
        for c in agg.columns
    ]

    return agg


def plot_metric_vs_block_size(
    df: pd.DataFrame,
    metric: str,
    workload: str,
    output_dir: Path,
) -> None:
    data = df[df["workload"] == workload].copy()
    if data.empty:
        return

    for qd in sorted(data["queue_depth"].dropna().unique()):
        qd_data = data[data["queue_depth"] == qd].copy()
        if qd_data.empty:
            continue

        plt.figure(figsize=(9, 5))

        for fs in sorted(qd_data["filesystem"].unique()):
            fs_data = qd_data[qd_data["filesystem"] == fs].copy()
            fs_data["block_size_bytes"] = fs_data["block_size"].map(
                block_size_sort_key)
            fs_data = fs_data.sort_values("block_size_bytes")

            x = fs_data["block_size"]
            y = fs_data[f"{metric}_mean"]
            yerr = fs_data[f"{metric}_std"]

            plt.errorbar(
                x,
                y,
                yerr=yerr,
                marker="o",
                capsize=3,
                label=fs,
            )

        plt.xlabel("Block size")
        plt.ylabel(METRICS[metric])
        plt.title(f"{METRICS[metric]} vs Block Size ({
                  workload}, qd={int(qd)})")
        plt.grid(True, alpha=0.3)
        plt.legend()
        plt.tight_layout()

        out = output_dir / f"{workload}_{metric}_vs_block_size_qd{int(qd)}.png"
        plt.savefig(out, dpi=200)
        plt.close()


def plot_metric_vs_queue_depth(
    df: pd.DataFrame,
    metric: str,
    workload: str,
    output_dir: Path,
) -> None:
    data = df[df["workload"] == workload].copy()
    if data.empty:
        return

    block_sizes = sorted(data["block_size"].unique(), key=block_size_sort_key)

    for bs in block_sizes:
        bs_data = data[data["block_size"] == bs].copy()
        if bs_data.empty:
            continue

        plt.figure(figsize=(9, 5))

        for fs in sorted(bs_data["filesystem"].unique()):
            fs_data = bs_data[bs_data["filesystem"] == fs].copy()
            fs_data = fs_data.sort_values("queue_depth")

            x = fs_data["queue_depth"]
            y = fs_data[f"{metric}_mean"]
            yerr = fs_data[f"{metric}_std"]

            plt.errorbar(
                x,
                y,
                yerr=yerr,
                marker="o",
                capsize=3,
                label=fs,
            )

        plt.xlabel("Queue depth")
        plt.ylabel(METRICS[metric])
        plt.title(f"{METRICS[metric]} vs Queue Depth ({workload}, bs={bs})")
        plt.grid(True, alpha=0.3)
        plt.legend()
        plt.tight_layout()

        out = output_dir / f"{workload}_{metric}_vs_queue_depth_bs{bs}.png"
        plt.savefig(out, dpi=200)
        plt.close()


def make_plots(df: pd.DataFrame, output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)

    agg = aggregate(df)
    agg.to_csv(output_dir / "aggregated_results.csv", index=False)

    workloads = sorted(agg["workload"].unique())

    for workload in workloads:
        for metric in METRICS:
            plot_metric_vs_block_size(agg, metric, workload, output_dir)
            plot_metric_vs_queue_depth(agg, metric, workload, output_dir)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Plot Z-LFS, Btrfs, and F2FS benchmark results against each other."
    )

    parser.add_argument("--zlfs", nargs="+", required=True,
                        help="Z-LFS CSV file(s)")
    parser.add_argument("--btrfs", nargs="+", required=True,
                        help="Btrfs CSV file(s)")
    parser.add_argument("--f2fs", nargs="+", required=True,
                        help="F2FS CSV file(s)")
    parser.add_argument(
        "--out-dir",
        default="plots",
        help="Directory to write plots and aggregated CSV",
    )

    args = parser.parse_args()

    dfs = []

    for path in args.zlfs:
        dfs.append(load_csv(Path(path), "zlfs"))

    for path in args.btrfs:
        dfs.append(load_csv(Path(path), "btrfs"))

    for path in args.f2fs:
        dfs.append(load_csv(Path(path), "f2fs"))

    combined = pd.concat(dfs, ignore_index=True)

    output_dir = Path(args.out_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    combined.to_csv(output_dir / "combined_raw_results.csv", index=False)

    make_plots(combined, output_dir)

    print(f"Wrote plots to: {output_dir}")
    print(f"Wrote combined raw CSV to: {
          output_dir / 'combined_raw_results.csv'}")
    print(f"Wrote aggregated CSV to: {output_dir / 'aggregated_results.csv'}")


if __name__ == "__main__":
    main()
