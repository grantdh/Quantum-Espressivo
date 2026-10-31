#!/usr/bin/env python3
"""The next GPU share per class, from qe_split's reports of runs made with the current shares.

usage: calibrate.py [--damp D] [--floor F] [--min-calls N] <run-dir> [<run-dir> ...] > shares.txt

For each class, the QE_SPLIT[pid] lines in the runs' err.txt (every rank of every run) give the
GFLOP and the seconds of the CPU and GPU parts of its split calls. Their ratios are the rates the
two engines reached while running together, under the power limit and with the other ranks'
work: r_cpu = GF_cpu / s_cpu and r_gpu = GF_gpu / s_gpu. The share at which both parts of a call
would have finished together is f_bal = r_gpu / (r_cpu + r_gpu). The next share moves the
fraction D (default 0.7) of the way from the current one to f_bal and is rounded to 0.01; below F
(default 0.08) the class goes to Accelerate (0). A class with fewer than N (default 20) split
calls takes the pooled estimate of its axis class (e.g. zUN). A class at 0 stays at 0.

Prints the table on one line in QE_SPLIT_F's syntax, and the estimates on stderr.
"""
import argparse
import sys
from collections import defaultdict

from analyze import NAN, rates, split_reports


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--damp", type=float, default=0.7)
    ap.add_argument("--floor", type=float, default=0.08)
    ap.add_argument("--min-calls", type=int, default=20)
    ap.add_argument("runs", nargs="+")
    a = ap.parse_args()
    tot, share = split_reports(*a.runs)
    pooled = defaultdict(lambda: defaultdict(float))
    for cls, t in tot.items():
        for k, v in t.items():
            pooled[cls.split(".")[0]][k] += v
    out = {}
    print(f"{'class':8s} {'share':>5s} {'calls':>7s} {'split':>6s} {'r_cpu':>7s} {'r_gpu':>7s} {'f_bal':>6s} {'source':>7s} {'next':>5s}",
          file=sys.stderr)
    for cls in sorted(share):
        f, t = share[cls], tot[cls]
        est, src = rates(t), "own"
        if t["split"] < a.min_calls:
            est, src = rates(pooled[cls.split(".")[0]]), "pooled"
        if f <= 0 or est is None:
            nxt, src = f, "kept"
        else:
            nxt = f + a.damp * (est[2] - f)
            nxt = 0.0 if nxt < a.floor else round(nxt, 2)
        out[cls] = nxt
        rc, rg, fb = est or (NAN,) * 3
        print(f"{cls:8s} {f:5.2f} {t['calls']:7.0f} {t['split']:6.0f} {rc:7.1f} {rg:7.1f} {fb:6.3f} {src:>7s} {nxt:5.2f}",
              file=sys.stderr)
    print(" ".join(f"{c}={v:.2f}" for c, v in sorted(out.items())))


if __name__ == "__main__":
    main()
