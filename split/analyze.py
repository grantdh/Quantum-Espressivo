#!/usr/bin/env python3
"""Tables for the split prototype's runs (split/run.sh output), in Markdown.

usage: analyze.py <out-dir> [--ref cpu] [--base cpu8]
       analyze.py <out-dir> --gate CONFIG [--ref off]   (exit status 1 if CONFIG fails the gate)

A configuration's reference is the configuration named --ref plus anything (cpu8, off4) that ran
with the same label, input, ranks and threads; --base names one configuration every other is also
compared with (the best CPU layout). Only runs that ended with rc 0 on AC power count.
- Wall time per label, input and configuration: median [min-max], with QE's main timers, and the
  speedups over the reference and over --base (ratios of medians).
- Physics against the reference's first run: final energy, SCF iterations, every iteration's
  energy and accuracy estimate, every printed band energy, the highest occupied and lowest
  unoccupied levels.
- qe_split's report per class (QE_SPLIT lines in err.txt), summed over ranks: calls, split calls,
  GFLOP, the seconds of the CPU and GPU parts and of the wait for the GPU, the rates the engines
  reached together and the share that would balance them.
- Where the library computed each GPU part: qe_split's log (split.<pid>) joined with apple-bottom's
  AB_TRACE (trace.<pid>) on the GPU part's sequence number (the rule follows apple-bottom's
  benchmarks/split/classify_trace.py). A trace's staged field, when the library writes one, says
  whether the staged result stood (kept, kept_4m) or why the call went to the host path. Without it
  (apple-bottom 1.5.0), a call with path=gpu, alpha = 1 and beta 0 or 1 was staged if it had no host
  epilogue and took the host path if it had one; any other scalars leave it unclassified.
  path=fallback:<reason> means Accelerate computed it.
--gate: every input's CONFIG runs against the reference's first run; fails if a run is missing or
its final energy differs by more than 1e-5 Ry or its SCF iteration count by more than 2.
"""
import argparse
import csv
import functools
import glob
import os
import re
import statistics
from collections import defaultdict

KV = re.compile(r"(\w+)=(\S+)")
REPORT = re.compile(r"QE_SPLIT\[\d+\] ([zd](?:UN|UM|RK)\.[kt]\d|[zd]pass) (.*)")
TIMERS = ["cegterg_s", "h_psi_s", "s_psi_s", "calbec_s", "add_vuspsi_s", "vloc_psi_s", "fftw_s", "sum_band_s", "PAW_pot_s"]
NAN = float("nan")


def med(v):
    return statistics.median(v) if v else NAN


def fmt_range(v):
    return f"{med(v):.2f} [{min(v):.2f}–{max(v):.2f}]" if v else "–"


def table(*cols):
    print("| " + " | ".join(cols) + " |")
    print("|" + "---|" * len(cols))


def row(*cells):
    print("| " + " | ".join(str(c) for c in cells) + " |")


# ---------------------------------------------------------------- QE output
@functools.lru_cache(maxsize=None)
def parse_out(path):
    txt = open(path, errors="replace").read()
    it_e = [float(x) for x in re.findall(r"^ {5}total energy\s+=\s+(-?\d+\.\d+) Ry", txt, re.M)]
    it_a = [float(x) for x in re.findall(r"estimated scf accuracy\s+<\s+(\d+\.\d+(?:E[-+]\d+)?) Ry", txt, re.M)]
    fin = re.findall(r"^!\s+total energy\s+=\s+(-?\d+\.\d+) Ry", txt, re.M)
    iters = re.findall(r"convergence has been achieved in\s+(\d+) iterations", txt)
    end = txt.find("End of self-consistent calculation")
    bands, hl = [], None
    if end >= 0:
        tail = txt[end:]
        stop = tail.find("highest occupied")
        for kb in re.split(r"\n\s+k =", tail[:stop if stop > 0 else len(tail)])[1:]:
            body = kb.split("bands (ev):", 1)[1].split("occupation numbers")[0] if "bands (ev):" in kb else ""
            bands.append([float(x) for x in re.findall(r"-?\d+\.\d+", body)])
        m = re.search(r"highest occupied, lowest unoccupied level \(ev\):\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)", tail)
        hl = (float(m.group(1)), float(m.group(2))) if m else None
    return {"E": float(fin[-1]) if fin else None, "iters": int(iters[-1]) if iters else None,
            "it_e": it_e, "it_a": it_a, "bands": bands, "hl": hl}


def compare(a, b):
    d = {"dE": b["E"] - a["E"], "iters": (a["iters"], b["iters"])}
    d["it_e"] = max((abs(x - y) for x, y in zip(a["it_e"], b["it_e"])), default=0.0)
    d["it_a"] = max((abs(x - y) / max(x, 1e-300) for x, y in zip(a["it_a"], b["it_a"])), default=0.0)
    fa = [x for k in a["bands"] for x in k]
    fb = [x for k in b["bands"] for x in k]
    d["nb"] = len(fa)
    if [len(k) for k in a["bands"]] == [len(k) for k in b["bands"]]:
        diffs = [abs(x - y) for x, y in zip(fa, fb)]
        d["band_max"], d["band_ndiff"] = max(diffs, default=0.0), sum(x != 0 for x in diffs)
    else:
        d["band_max"], d["band_ndiff"] = NAN, -1
    d["hl"] = max(abs(x - y) for x, y in zip(a["hl"], b["hl"])) if a["hl"] and b["hl"] else NAN
    return d


# ---------------------------------------------------------------- qe_split and AB_TRACE
def split_reports(*run_dirs):
    """({class: {field: sum}}, {class: share}) over the QE_SPLIT lines of every rank of every run;
    the calls outside every class are under zpass and dpass. A missing err.txt raises."""
    tot, share = defaultdict(lambda: defaultdict(float)), {}
    for d in run_dirs:
        with open(os.path.join(d, "err.txt"), errors="replace") as f:
            for line in f:
                m = REPORT.match(line)
                if not m:
                    continue
                kv = dict(KV.findall(m.group(2)))
                if "f" in kv:
                    share[m.group(1)] = float(kv["f"])
                for k, v in kv.items():
                    if k != "f" and not k.startswith(("r_", "f_")):
                        tot[m.group(1)][k] += float(v)
    return tot, share


def rates(t):
    """(r_cpu, r_gpu, f_bal) from summed report fields, or None without split work on both engines."""
    gf_cpu, gf_gpu = t["gf_split"] - t["gf_gpu"], t["gf_gpu"]
    if t["cpu_s"] <= 0 or t["gpu_s"] <= 0 or gf_cpu <= 0 or gf_gpu <= 0:
        return None
    rc, rg = gf_cpu / t["cpu_s"], gf_gpu / t["gpu_s"]
    return rc, rg, rg / (rc + rg)


def hexpair(s):
    return tuple(float.fromhex(x) for x in s.split(","))


def path_of(t):
    """Where the library computed a traced GPU part: staged, host, fallback:<reason>, cpu, unclassified."""
    p = t["path"]
    if p != "gpu":
        return p
    if "staged" in t:
        return "staged" if t["staged"] in ("kept", "kept_4m") else "host"
    if "alpha" not in t or "beta" not in t:
        return "unclassified"
    a, b = hexpair(t["alpha"]), hexpair(t["beta"])
    if a[0] != 1 or any(a[1:]) or b[0] not in (0, 1) or any(b[1:]):
        return "unclassified"
    return "staged" if int(t.get("epilogue_ns", 0)) == 0 else "host"


def guard(run_dirs):
    """({class: {path: [GPU part seconds]}}, {class: {host-path reason: calls}}, unmatched GPU parts)."""
    out, why, bad = defaultdict(lambda: defaultdict(list)), defaultdict(lambda: defaultdict(int)), 0
    for d in run_dirs:
        for sf in glob.glob(os.path.join(d, "split.*")):
            tr = {}
            tf = os.path.join(d, "trace." + sf.rsplit(".", 1)[1])
            if os.path.exists(tf):
                for line in open(tf):
                    if not line.startswith("#") and "path=" in line:
                        kv = dict(KV.findall(line))
                        tr[int(kv["seq"])] = kv
            for line in open(sf):
                if line.startswith("#") or "gseq=" not in line:
                    continue
                kv = dict(KV.findall(line))
                t = tr.get(int(kv["gseq"]))
                if not t or (t["M"], t["N"], t["K"], t["ta"].upper()) != (kv["gM"], kv["gN"], kv["gK"], kv["ta"]):
                    bad += 1
                    continue
                p = path_of(t)
                out[kv["cls"]][p].append(int(kv["tg_ns"]) * 1e-9)
                if p == "host" and "staged" in t:
                    why[kv["cls"]][t["staged"]] += 1
                if p == "staged" and t.get("staged") == "kept_4m":
                    why[kv["cls"]]["kept_4m"] += 1
    return out, why, bad


# ---------------------------------------------------------------- runs and references
def ok_rows(out):
    with open(os.path.join(out, "results.csv")) as f:
        return [r for r in csv.DictReader(f) if r["rc"] == "0" and r["power_start"] == "AC Power"
                and r["power_end"] == "AC Power" and r["energy_Ry"] and ".bad" not in r["run_dir"]]


class Runs:
    def __init__(self, out, ref):
        self.out, self.ref = out, ref
        self.by = defaultdict(list)
        for r in ok_rows(out):
            self.by[(r["label"], r["input"], r["config"])].append(r)
        for rs in self.by.values():
            rs.sort(key=lambda r: int(r["rep"]))

    def layout(self, key):
        rs = self.by.get(key)
        return (rs[0]["np"], rs[0]["threads"]) if rs else None

    def refcfg(self, lab, inp, cfg):
        """The configuration named --ref... with cfg's label, input, ranks and threads."""
        lay = self.layout((lab, inp, cfg))
        for (l2, i2, c2) in self.by:
            if (l2, i2) == (lab, inp) and c2.startswith(self.ref) and self.layout((l2, i2, c2)) == lay:
                return c2
        return None

    def out_txt(self, r):
        return os.path.join(self.out, r["run_dir"], "out.txt")

    def dirs(self, key):
        return [os.path.join(self.out, r["run_dir"]) for r in self.by.get(key, [])]


def gate(R, cfg):
    ok = True
    keys = sorted({(lab, inp) for (lab, inp, _) in R.by})
    for lab, inp in keys:
        if not R.by.get((lab, inp, cfg)):
            print(f"gate {lab} {inp} {cfg}: no run that ended with rc 0 on AC power: FAIL")
            ok = False
            continue
        rc = R.refcfg(lab, inp, cfg)
        if not rc or rc == cfg:
            print(f"gate {lab} {inp} {cfg}: no {R.ref} run with the same ranks and threads: FAIL")
            ok = False
            continue
        ref = parse_out(R.out_txt(R.by[(lab, inp, rc)][0]))
        for r in R.by[(lab, inp, cfg)]:
            run = parse_out(R.out_txt(r))
            d = compare(ref, run)
            good = abs(d["dE"]) <= 1e-5 and abs(run["iters"] - ref["iters"]) <= 2
            ok &= good
            print(f"gate {lab} {inp} {cfg} r{r['rep']} against {rc}: dE {d['dE']:.2e} Ry, iterations {d['iters']}, "
                  f"band energies differing {d['band_ndiff']} of {d['nb']} (max {d['band_max']:.4f} eV): "
                  f"{'pass' if good else 'FAIL'}")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--ref", default="cpu")
    ap.add_argument("--base", default=None, help="the best CPU layout's configuration")
    ap.add_argument("--gate", default=None)
    a = ap.parse_args()
    R = Runs(a.out, a.ref)
    if a.gate:
        raise SystemExit(0 if gate(R, a.gate) else 1)
    keys = sorted(R.by)

    print("## Wall time (s): median [min–max] over runs\n")
    print("Speedups are ratios of medians: the reference configuration's over this one's.\n")
    table("label", "input", "config", "np×threads", "runs", "wall", "vs reference",
          *([f"vs {a.base}"] if a.base else []), *(t[:-2] for t in TIMERS))
    for lab, inp, cfg in keys:
        rs = R.by[(lab, inp, cfg)]
        w = [float(r["wall_s"]) for r in rs]
        rc = R.refcfg(lab, inp, cfg)
        ref = [float(r["wall_s"]) for r in R.by.get((lab, inp, rc), [])]
        base = [float(r["wall_s"]) for r in R.by.get((lab, inp, a.base), [])]
        cells = [lab, inp, cfg, "×".join(R.layout((lab, inp, cfg))), len(rs), fmt_range(w),
                 f"{med(ref) / med(w):.3f}× ({rc})" if ref else "–"]
        if a.base:
            cells.append(f"{med(base) / med(w):.3f}×" if base else "–")
        cells += [f"{med([float(r[t]) for r in rs if r[t]]):.2f}" if any(r[t] for r in rs) else "–" for t in TIMERS]
        row(*cells)

    print("\n## Physics against the reference's first run\n")
    table("label", "input", "config", "reference", "runs", "final energy − ref (Ry), max", "SCF iterations (ref; runs)",
          "iteration energies, max |Δ| (Ry)", "accuracy estimates, max rel. Δ",
          "band energies differing (of n), max |Δ| (eV)", "HOMO/LUMO, max |Δ| (eV)")
    for lab, inp, cfg in keys:
        rc = R.refcfg(lab, inp, cfg)
        if not rc:
            continue
        ref = parse_out(R.out_txt(R.by[(lab, inp, rc)][0]))
        cs = [compare(ref, parse_out(R.out_txt(r))) for r in R.by[(lab, inp, cfg)]]
        row(lab, inp, cfg, rc, len(cs), f"{max(abs(c['dE']) for c in cs):.1e}",
            f"{ref['iters']}; {','.join(map(str, sorted({c['iters'][1] for c in cs})))}",
            f"{max(c['it_e'] for c in cs):.1e}", f"{max(c['it_a'] for c in cs):.1e}",
            f"{max(c['band_ndiff'] for c in cs)} of {cs[0]['nb']}, {max(c['band_max'] for c in cs):.4f}",
            f"{max(c['hl'] for c in cs):.4f}")
    for lab, inp in sorted({(l, i) for (l, i, _) in keys}):
        refs = sorted({R.refcfg(lab, inp, c) for (l, i, c) in keys if (l, i) == (lab, inp)} - {None})
        for c2 in refs[1:]:
            d = compare(parse_out(R.out_txt(R.by[(lab, inp, refs[0])][0])), parse_out(R.out_txt(R.by[(lab, inp, c2)][0])))
            print(f"\n{lab} {inp}, first {c2} run − first {refs[0]} run: ΔE {d['dE']:.1e} Ry, iterations {d['iters']}, "
                  f"band energies differing {d['band_ndiff']} of {d['nb']} (max {d['band_max']:.4f} eV)")

    print("\n## qe_split per class, summed over ranks and runs, divided by the runs\n")
    table("label", "input", "config", "class", "share", "calls", "split", "GF", "Accelerate-only s", "split calls s",
          "CPU part s", "GPU part s", "wait for GPU s", "r_cpu GF/s", "r_gpu GF/s", "f_bal", "GPU parts on Accelerate")
    for lab, inp, cfg in keys:
        n = len(R.by[(lab, inp, cfg)])
        tot, share = split_reports(*R.dirs((lab, inp, cfg)))
        for c in sorted(tot):
            t = tot[c]
            rc, rg, fb = rates(t) or (NAN,) * 3
            row(lab, inp, cfg, c, f"{share[c]:.2f}" if c in share else "", f"{t['calls'] / n:.0f}", f"{t['split'] / n:.0f}",
                f"{t['gf'] / n:.0f}", f"{(t['wall_s'] - t['split_wall_s']) / n:.2f}", f"{t['split_wall_s'] / n:.2f}",
                f"{t['cpu_s'] / n:.2f}", f"{t['gpu_s'] / n:.2f}", f"{t['wait_s'] / n:.2f}", f"{rc:.0f}", f"{rg:.0f}",
                f"{fb:.3f}", f"{t['gpu_on_cpu'] / n:.0f}")

    print("\n## Where the library computed the GPU parts (all runs of the configuration)\n")
    table("label", "input", "config", "class", "GPU parts", "staged", "host path", "Accelerate (fallback)",
          "unclassified", "median GPU part s: staged / host", "host-path reasons; kept_4m")
    for lab, inp, cfg in keys:
        g, why, bad = guard(R.dirs((lab, inp, cfg)))
        for c in sorted(g):
            n = sum(len(v) for v in g[c].values())
            pct = lambda p: f"{len(g[c].get(p, []))} ({100 * len(g[c].get(p, [])) / n:.0f}%)"
            fb = ", ".join(f"{p.split(':', 1)[1]} {len(v)}" for p, v in sorted(g[c].items()) if p.startswith("fallback")) or "0"
            row(lab, inp, cfg, c, n, pct("staged"), pct("host"), fb, len(g[c].get("unclassified", [])) + len(g[c].get("cpu", [])),
                f"{med(g[c].get('staged', [])):.4f} / {med(g[c].get('host', [])):.4f}",
                ", ".join(f"{k} {v}" for k, v in sorted(why[c].items())) or "–")
        if bad:
            row(lab, inp, cfg, "(not matched to a trace line)", bad, "", "", "", "", "", "")


if __name__ == "__main__":
    main()
