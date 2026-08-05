#!/usr/bin/env python3
"""
make_waveform.py - render docs/fp32_add_waveform.png from a REAL sim run.

Parses the VCD produced by Icarus Verilog (`tb_fp32_add_dump.vcd`, from
`make icarus_dump`) and draws the SHOWCASE window: ten headline binary32
operations pushed back to back, one per cycle, with results emerging exactly
LAT=3 cycles later. Reading the out_z row left to right:

    1.0 + 2.0            -> 3.0
    1.0 - 1.0            -> +0        (exact cancellation)
    1.0 + 2^-24          -> 1.0       (exact TIE, rounds to even, inexact)
    1.0 + 2^-23          -> 1.0+1ulp  (exactly one ULP, exact)
    maxsub + minsub      -> minnrm    (a subnormal carries INTO the normals)
    minnrm - minsub      -> maxsub    (and drops back OUT of them)
    maxnrm + maxnrm      -> +inf      (overflow, ovf+inx)
    (+inf) + (-inf)      -> qNaN      (INVALID)
    sNaN + 1.0           -> qNaN      (INVALID, canonicalised)
    (-0) + (-0)          -> -0        (the signed-zero rule)

Bus values are annotated with their floating-point meaning rather than raw hex,
because "1.0" and "maxsub" are what the reader needs; the hex is in the README.

This trace is captured from a genuine Icarus Verilog simulation of the RTL - it
is NOT hand-modeled.

Usage:
    make icarus_dump          # produces tb_fp32_add_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_fp32_add_dump.vcd]
"""
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
VCD = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "tb_fp32_add_dump.vcd")
OUT = os.path.join(HERE, "fp32_add_waveform.png")

# Display order (top -> bottom).
WANT = ["clk", "rst_n", "in_valid", "in_sub", "in_a", "in_b",
        "out_valid", "out_z", "out_inv", "out_ovf", "out_inx", "mark"]
LEVEL = {"clk", "rst_n", "in_valid", "in_sub", "out_valid",
         "out_inv", "out_ovf", "out_inx", "mark"}
HBUS = {"in_a", "in_b", "out_z"}
PS = 1000                                   # ps per ns

# Human-readable names for the binary32 patterns this showcase uses.
FPNAME = {
    0x00000000: "+0",       0x80000000: "-0",
    0x00000001: "minsub",   0x007FFFFF: "maxsub",   0x00800000: "minnrm",
    0x3F800000: "1.0",      0x3F800001: "1.0+1ulp", 0x3F7FFFFF: "1.0-1ulp",
    0x40000000: "2.0",      0x40400000: "3.0",      0xBF800000: "-1.0",
    0x33800000: "2^-24",    0x34000000: "2^-23",
    0x7F7FFFFF: "maxnrm",   0xFF7FFFFF: "-maxnrm",
    0x7F800000: "+inf",     0xFF800000: "-inf",
    0x7FC00000: "qNaN",     0x7F800001: "sNaN",
}


def parse_vcd(path):
    sym_of, width = {}, {}
    changes, depth, in_top, defining, t = [], 0, False, True, 0
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if defining:
                if line.startswith("$scope"):
                    depth += 1
                    in_top = (depth == 1)       # tb_fp32_add_dump = depth 1
                elif line.startswith("$upscope"):
                    depth -= 1
                    in_top = (depth == 1)
                elif line.startswith("$var"):
                    parts = line.split()
                    w, symbol, name = int(parts[2]), parts[3], parts[4]
                    if in_top and name in WANT and name not in sym_of:
                        sym_of[name] = symbol
                        width[name] = w
                elif line.startswith("$enddefinitions"):
                    defining = False
                continue
            if line[0] == "#":
                t = int(line[1:])
            elif line[0] in "01xz":
                changes.append((t, line[1:], line[0]))
            elif line[0] in "bB":
                val, symbol = line[1:].split()
                changes.append((t, symbol, val))
    return sym_of, width, changes


def build_series(sym_of, changes):
    want = set(sym_of.values())
    series = {s: [] for s in want}
    for t, sym, val in changes:
        if sym in want:
            series[sym].append((t, val))
    for s in series:
        series[s].sort(key=lambda x: x[0])
    return series


def value_at(seq, t):
    cur = None
    for (tt, v) in seq:
        if tt <= t:
            cur = v
        else:
            break
    return cur


def as_level(v):
    return 1 if v == "1" else 0


def as_fp(binstr, w):
    """Render a 32-bit VCD value as its floating-point meaning."""
    if binstr is None:
        return None
    try:
        v = int(binstr, 2)
    except (ValueError, TypeError):
        return None
    return FPNAME.get(v, "0x%08X" % v)


def window(series, sym_of):
    """The `mark`-delimited showcase section, padded so the pipeline fill at the
    start and the last drained result at the end are both on screen."""
    mk = series[sym_of["mark"]]
    t0 = next((t for (t, v) in mk if v == "1"), None)
    t1 = next((t for (t, v) in mk if v == "0" and t0 is not None and t > t0), None)
    if t0 is None or t1 is None:
        sys.exit("mark window not found in VCD")
    return t0 - 25 * PS, t1 - 10 * PS


def main():
    if not os.path.exists(VCD):
        sys.exit("VCD not found: %s  (run `make icarus_dump` first)" % VCD)
    sym_of, width, changes = parse_vcd(VCD)
    missing = [w for w in WANT if w not in sym_of]
    if missing:
        sys.exit("signals not found in VCD: %s" % missing)
    series = build_series(sym_of, changes)
    T0, T1 = window(series, sym_of)

    step = 200
    ts = list(range(T0, T1 + step, step))

    fig, axes = plt.subplots(len(WANT), 1, figsize=(14, 7.8), sharex=True)
    fig.suptitle(
        "IEEE-754 binary32 adder/subtractor - SHOWCASE WINDOW\n"
        "REAL Icarus Verilog capture (tb_fp32_add_dump.vcd) - ten operations, one per "
        "cycle, fixed latency LAT=3, zero bubble:\n"
        "tie-to-even, subnormal into and out of the normals, overflow to inf, "
        "invalid to qNaN, signed zero",
        fontsize=10.2, fontweight="bold")

    # one-cycle (10 ns) grid
    grid = [g * PS for g in range(0, 100000, 10) if T0 <= g * PS <= T1]

    color = {"clk": "#333333", "rst_n": "#8a6d3b",
             "in_valid": "#1f7a4d", "in_sub": "#1f7a4d",
             "out_valid": "#1f4e8c", "out_inv": "#a3282d",
             "out_ovf": "#a3282d", "out_inx": "#b5761f",
             "mark": "#5b2d91"}
    tint = {"in_a": "#dff0e6", "in_b": "#dff0e6", "out_z": "#dfe8f5"}

    def draw_bus(ax, seq, tint_c, w):
        pts = sorted(set([T0] + [tt for (tt, _) in seq if T0 < tt < T1] + [T1]))
        for i in range(len(pts) - 1):
            a_, b_ = pts[i], pts[i + 1]
            txt = as_fp(value_at(seq, a_), w)
            an, bn = a_ / PS, b_ / PS
            if txt is not None and (bn - an) > 1.0:
                ax.fill_between([an, bn], 0.16, 0.84, color=tint_c,
                                edgecolor="#1f4e8c", lw=1.0, zorder=2)
                ax.text((an + bn) / 2, 0.5, txt, ha="center", va="center",
                        fontsize=7.4, fontfamily="monospace", zorder=3)
        ax.set_ylim(0, 1)

    for ax, name in zip(axes, WANT):
        seq = series[sym_of[name]]
        ax.set_ylabel(name, rotation=0, ha="right", va="center",
                      fontsize=8.5, labelpad=32, fontfamily="monospace")
        ax.set_yticks([])
        for spine in ("top", "right", "left"):
            ax.spines[spine].set_visible(False)
        for g in grid:
            ax.axvline(g / PS, color="0.93", lw=0.6, zorder=0)

        if name in HBUS:
            draw_bus(ax, seq, tint[name], width[name])
        else:
            xs, ys, last = [], [], as_level(value_at(seq, T0) or "0")
            for t in ts:
                v = value_at(seq, t)
                lv = as_level(v) if v is not None else last
                last = lv
                xs.append(t / PS)
                ys.append(lv)
            ax.step(xs, ys, where="post", color=color[name], lw=1.4)
            ax.fill_between(xs, ys, step="post", color=color[name], alpha=0.08)
            ax.set_ylim(-0.25, 1.35)

    axes[-1].set_xlabel("time (ns)   -   one 10 ns cycle per operation", fontsize=10)
    axes[-1].set_xlim(T0 / PS, T1 / PS)

    fig.tight_layout(rect=[0, 0, 1, 0.87])
    fig.savefig(OUT, dpi=130)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
