#!/usr/bin/env bash
# aggregate.sh — collect all per-system summary.txt files into:
#   results/summary.csv        — machine-readable
#   results/speedup_table.txt  — human-readable with PASS/FAIL markers
#   results/speedup.png        — bar chart if matplotlib is available
#
# Reads:
#   results/qe_<sys>/<mode>/summary.txt          (QE)
#   results/yambo_<sys>/<mode>/summary_<stage>.txt (Yambo, per stage)
#   results/qe_<sys>/agreement.txt               (energy-agreement verdict)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/config.sh"

RESULTS="${HERE}/results"
CSV="${RESULTS}/summary.csv"
TBL="${RESULTS}/speedup_table.txt"

mkdir -p "${RESULTS}"

# --- CSV ------------------------------------------------------------------
echo "code,system,stage,mode,wall_seconds,total_energy_Ry,converged,status" > "${CSV}"

for d in "${RESULTS}"/qe_*/; do
    [[ -d "${d}" ]] || continue
    sys="$(basename "${d}" | sed 's/^qe_//')"
    for mode in cpu gpu auto; do
        s="${d}/${mode}/summary.txt"
        [[ -f "${s}" ]] || continue
        w=$(grep ^wall_seconds=     "${s}" | cut -d= -f2)
        e=$(grep ^total_energy_Ry=  "${s}" | cut -d= -f2)
        c=$(grep ^converged=        "${s}" | cut -d= -f2)
        st=$(grep ^status=          "${s}" | cut -d= -f2)
        echo "qe,${sys},scf,${mode},${w},${e},${c},${st}" >> "${CSV}"
    done
done

for d in "${RESULTS}"/yambo_*/; do
    [[ -d "${d}" ]] || continue
    sys="$(basename "${d}" | sed 's/^yambo_//')"
    for mode in cpu gpu auto; do
        for stage in ip_rpa gw_ppa; do
            s="${d}/${mode}/summary_${stage}.txt"
            [[ -f "${s}" ]] || continue
            w=$(grep ^wall_seconds= "${s}" | cut -d= -f2)
            st=$(grep ^status=      "${s}" | cut -d= -f2)
            echo "yambo,${sys},${stage},${mode},${w},,,${st}" >> "${CSV}"
        done
    done
done
echo "${C_GRN}[wrote]${C_RST} ${CSV}"

# --- human-readable table ------------------------------------------------
{
    echo "apple-bottom A/B/C benchmark results — $(ts)"
    echo "====================================================================="
    echo ""
    printf "%-18s %8s %8s %8s %8s %8s  %s\n" \
           "system(stage)" "cpu_s" "gpu_s" "auto_s" "gpu/cpu" "auto/cpu" "energy"
    printf "%-18s %8s %8s %8s %8s %8s  %s\n" \
           "------------------" "------" "------" "------" "------" "------" "------"

    # helper: per-row (system, stage) -> three mode walls + ratios
    emit_row() {
        local label="$1" f_cpu="$2" f_gpu="$3" f_auto="$4" agreement="$5"
        local wc wg wa
        wc=$(grep ^wall_seconds= "${f_cpu}"  2>/dev/null | cut -d= -f2)
        wg=$(grep ^wall_seconds= "${f_gpu}"  2>/dev/null | cut -d= -f2)
        wa=$(grep ^wall_seconds= "${f_auto}" 2>/dev/null | cut -d= -f2)
        [[ -z "${wc}" ]] && wc="-"
        [[ -z "${wg}" ]] && wg="-"
        [[ -z "${wa}" ]] && wa="-"
        local rgc rac
        rgc=$(awk -v a="${wc}" -v b="${wg}" \
                  'BEGIN { if (a+0>0 && b+0>0) printf "%.2fx", a/b; else print "-" }')
        rac=$(awk -v a="${wc}" -v b="${wa}" \
                  'BEGIN { if (a+0>0 && b+0>0) printf "%.2fx", a/b; else print "-" }')
        printf "%-18s %8s %8s %8s %8s %8s  %s\n" \
               "${label}" "${wc}" "${wg}" "${wa}" "${rgc}" "${rac}" "${agreement}"
    }

    # QE rows
    for d in "${RESULTS}"/qe_*/; do
        [[ -d "${d}" ]] || continue
        sys="$(basename "${d}" | sed 's/^qe_//')"
        ag="$(cat "${d}/agreement.txt" 2>/dev/null | sed 's/^agreement=//' || echo '?')"
        emit_row "qe:${sys}" \
                 "${d}/cpu/summary.txt" \
                 "${d}/gpu/summary.txt" \
                 "${d}/auto/summary.txt" \
                 "${ag}"
    done

    # Yambo rows (one per stage)
    for d in "${RESULTS}"/yambo_*/; do
        [[ -d "${d}" ]] || continue
        sys="$(basename "${d}" | sed 's/^yambo_//')"
        for stage in ip_rpa gw_ppa; do
            emit_row "yambo:${sys}:${stage}" \
                     "${d}/cpu/summary_${stage}.txt" \
                     "${d}/gpu/summary_${stage}.txt" \
                     "${d}/auto/summary_${stage}.txt" \
                     "-"
        done
    done
    echo ""
    echo "Legend:"
    echo "  gpu/cpu   > 1  means gpu-forced mode was FASTER than cpu baseline."
    echo "  auto/cpu  > 1  means smart-dispatch was FASTER than cpu baseline."
    echo "  energy=PASS means total_E across cpu/gpu/auto agree to conv_thr (1e-6 Ry)."
} | tee "${TBL}"

echo ""
echo "${C_GRN}[wrote]${C_RST} ${TBL}"

# --- plot (optional) -----------------------------------------------------
if command -v python3 >/dev/null 2>&1 && python3 -c "import matplotlib" 2>/dev/null; then
    python3 - <<'PY'
import csv, os
from collections import defaultdict
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

here = os.path.dirname(os.path.realpath(__file__)) if "__file__" in dir() else os.getcwd()
# Script runs from the benchmark dir; results/summary.csv is relative.
csvf = os.path.join("results", "summary.csv")
walls = defaultdict(dict)  # (code, sys, stage) -> {mode: seconds}
with open(csvf) as f:
    for r in csv.DictReader(f):
        try:
            walls[(r["code"], r["system"], r["stage"])][r["mode"]] = float(r["wall_seconds"])
        except (KeyError, ValueError):
            pass

labels, cpu, gpu, auto = [], [], [], []
for key, mw in sorted(walls.items()):
    if {"cpu","gpu","auto"}.issubset(mw):
        labels.append(f"{key[0]}:{key[1]}:{key[2]}")
        cpu.append(mw["cpu"]); gpu.append(mw["gpu"]); auto.append(mw["auto"])

if not labels:
    print("[plot] no rows with all three modes — skipping speedup.png")
    raise SystemExit(0)

import numpy as np
x = np.arange(len(labels)); w = 0.27
fig, ax = plt.subplots(figsize=(max(7, 0.9*len(labels)), 4.5))
ax.bar(x - w, cpu,  w, label="cpu  (Accelerate)")
ax.bar(x,     gpu,  w, label="gpu  (forced, AB_MIN_GPU_DIM=0)")
ax.bar(x + w, auto, w, label="auto (smart dispatch)")
ax.set_ylabel("wall time (s)")
ax.set_title("apple-bottom A/B/C — lower is better")
ax.set_xticks(x); ax.set_xticklabels(labels, rotation=20, ha="right")
ax.legend(); ax.grid(axis="y", alpha=0.3)
plt.tight_layout()
out = os.path.join("results", "speedup.png")
plt.savefig(out, dpi=140)
print(f"[plot] wrote {out}")
PY
    echo "${C_GRN}[wrote]${C_RST} ${RESULTS}/speedup.png"
else
    echo "${C_YLW}[skip plot]${C_RST} python3 + matplotlib not available."
fi
