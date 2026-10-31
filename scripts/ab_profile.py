#!/usr/bin/env python3
"""Add up apple-bottom's profile of one run.

Usage: ab_profile.py PREFIX

Reads PREFIX.<pid>.json, the profiles that apple-bottom (1.4 and later) writes at exit in the
processes with-ab-profile.sh started, and prints one line:

    <gpu_calls> <cpu_calls> <gpu_time_pct> <build>

gpu_calls and cpu_calls are the BLAS calls the GPU computed and those that ran on the CPU,
summed over routines and processes; gpu_time_pct is the share of their wall time spent in the
GPU calls ("n/a" without calls); build is the library build as ab_build_info() reports it.
Exits with status 1 and a message if a process that started (PREFIX.<pid>.started) wrote no
profile, or if a profile lacks one of these keys. apple-bottom counts every dgemm_/zgemm_ call
it receives, in every AB_MODE, so a run without any is reported on stderr too: its GEMMs did
not bind to apple-bottom.
"""
import glob
import json
import sys


def summarize(prefix):
    stem = glob.escape(prefix)
    started = {p[:-len(".started")] for p in glob.glob(stem + ".*.started")}
    paths = sorted(glob.glob(stem + ".*.json"))
    if not started:
        sys.exit(f"ab_profile: no {prefix}.*.started (run the program through with-ab-profile.sh)")
    missing = sorted(started - {p[:-len(".json")] for p in paths})
    if missing:
        sys.exit(f"ab_profile: {len(missing)} of {len(started)} processes wrote no profile, e.g. "
                 f"{missing[0]}.json: did they exit normally?")
    total = dict(gpu_calls=0, cpu_calls=0, gpu_ns=0, cpu_ns=0)
    builds = set()
    for path in paths:
        with open(path) as f:
            profile = json.load(f)
        try:
            builds.add(profile["build"])
            for routine in profile["routines"]:
                for key in total:
                    total[key] += routine[key]
        except KeyError as e:
            sys.exit(f"ab_profile: {path} has no {e} key (apple-bottom before 1.4?)")
    if total["gpu_calls"] + total["cpu_calls"] == 0:
        print(f"ab_profile: {prefix}: no BLAS calls recorded; do the program's dgemm_ and "
              "zgemm_ bind to apple-bottom?", file=sys.stderr)
    ns = total["gpu_ns"] + total["cpu_ns"]
    total["gpu_time_pct"] = f"{100 * total['gpu_ns'] / ns:.1f}" if ns else "n/a"
    total["build"] = "; ".join(sorted(builds))
    return total


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    s = summarize(sys.argv[1])
    print(s["gpu_calls"], s["cpu_calls"], s["gpu_time_pct"], s["build"])
