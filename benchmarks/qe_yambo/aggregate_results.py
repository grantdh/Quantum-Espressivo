#!/usr/bin/env python3
"""Aggregate QE+Yambo three-way benchmark results into a CSV + summary plot.

Produces:
  results/summary.csv
  results/summary.md     (human-readable table)
  results/speedup.png    (if matplotlib is installed)
"""
from __future__ import annotations

import csv
import os
import sys
from pathlib import Path

ROOT = Path(__file__).parent / "results"
MODES = ["cpu", "gpu", "auto"]


def read_int(p: Path) -> int | None:
    try:
        return int(p.read_text().strip())
    except Exception:
        return None


def collect():
    rows = []
    if not ROOT.exists():
        print(f"No results directory at {ROOT}")
        return rows
    for run_dir in sorted(ROOT.iterdir()):
        if not run_dir.is_dir():
            continue
        name = run_dir.name  # e.g. qe_si32, yambo_gaas
        for mode in MODES:
            mode_dir = run_dir / mode
            if not mode_dir.is_dir():
                continue
            wall = read_int(mode_dir / "wall_seconds.txt")
            # GEMM dispatch counts
            cpu_calls = gpu_calls = 0
            for f in mode_dir.glob("gemm_profile*.txt"):
                try:
                    with f.open() as fh:
                        next(fh, None)  # header
                        for line in fh:
                            parts = line.split()
                            if len(parts) >= 6:
                                (cpu_calls, gpu_calls) = (
                                    (cpu_calls + 1, gpu_calls)
                                    if parts[5] == "0"
                                    else (cpu_calls, gpu_calls + 1)
                                )
                except Exception:
                    pass
            rows.append(
                dict(
                    run=name,
                    mode=mode,
                    wall_s=wall if wall is not None else "",
                    cpu_calls=cpu_calls,
                    gpu_calls=gpu_calls,
                )
            )
    return rows


def write_csv(rows):
    out = ROOT / "summary.csv"
    with out.open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["run", "mode", "wall_s", "cpu_calls", "gpu_calls"])
        w.writeheader()
        w.writerows(rows)
    print(f"  wrote {out}")


def write_markdown(rows):
    out = ROOT / "summary.md"
    runs = {}
    for r in rows:
        runs.setdefault(r["run"], {})[r["mode"]] = r
    lines = ["# Benchmark Summary\n",
             "| Run | cpu (s) | gpu (s) | auto (s) | best | gpu×cpu | auto×cpu |",
             "|---|---:|---:|---:|---|---:|---:|"]
    for run, byMode in sorted(runs.items()):
        def w(m): return byMode.get(m, {}).get("wall_s", "")
        try:
            cpu = float(w("cpu")); gpu = float(w("gpu")); auto = float(w("auto"))
            best = min(("cpu", cpu), ("gpu", gpu), ("auto", auto), key=lambda x: x[1])[0]
            g_ratio = f"{cpu/gpu:.2f}x" if gpu else "—"
            a_ratio = f"{cpu/auto:.2f}x" if auto else "—"
        except Exception:
            best = "?"
            g_ratio = a_ratio = "—"
        lines.append(f"| {run} | {w('cpu')} | {w('gpu')} | {w('auto')} | {best} | {g_ratio} | {a_ratio} |")
    out.write_text("\n".join(lines) + "\n")
    print(f"  wrote {out}")


def try_plot(rows):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("  (matplotlib not installed — skipping plot)")
        return
    runs = {}
    for r in rows:
        runs.setdefault(r["run"], {})[r["mode"]] = r.get("wall_s") or 0
    if not runs:
        return
    labels = sorted(runs)
    import numpy as np
    x = np.arange(len(labels))
    w = 0.28
    fig, ax = plt.subplots(figsize=(max(6, len(labels) * 1.2), 4))
    for i, mode in enumerate(MODES):
        ys = [float(runs[r].get(mode) or 0) for r in labels]
        ax.bar(x + (i - 1) * w, ys, w, label=f"AB_MODE={mode}")
    ax.set_xticks(x)
    ax.set_xticklabels(labels, rotation=30, ha="right")
    ax.set_ylabel("Wall time (s)")
    ax.set_title("apple-bottom dispatch comparison")
    ax.legend()
    fig.tight_layout()
    out = ROOT / "speedup.png"
    fig.savefig(out, dpi=140)
    print(f"  wrote {out}")


def main():
    rows = collect()
    if not rows:
        print("No results yet.")
        sys.exit(0)
    ROOT.mkdir(exist_ok=True)
    write_csv(rows)
    write_markdown(rows)
    try_plot(rows)


if __name__ == "__main__":
    main()
