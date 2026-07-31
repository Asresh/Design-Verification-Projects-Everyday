#!/usr/bin/env python3
"""
make_waveform.py - render docs/warp_bitonic_sort_waveform.png from a REAL sim run.

Parses the VCD produced by Icarus Verilog (`tb_warp_bitonic_sort_dump.vcd`, from
`make icarus_dump`) and draws the DIRECTED SHOWCASE of the GPU warp-level
bitonic sorting network: an ASCENDING sort of a fully reverse-sorted 8-record
warp.

    input lane 0..7 (each record = {6-bit key, 2-bit tag}, tag 0):
        0x70 0x60 0x50 0x40 0x30 0x20 0x10 0x00     (keys 28..0, descending)

LAT = 7 cycles later the eight output lanes come out as a clean monotonic ramp:

        out0=0x00 out1=0x10 out2=0x20 out3=0x30
        out4=0x40 out5=0x50 out6=0x60 out7=0x70     (ascending)

The story the window tells: a jumbled vector is presented for one cycle
(in_valid pulse, in_dir=0), streams through the 6-layer Batcher pipeline, and
exactly LAT cycles later out_valid pulses with the fully sorted vector - lane 0
the smallest record, lane 7 the largest.

The trace is captured from a genuine Icarus simulation - it is NOT hand-modeled.

Usage:
    make icarus_dump          # produces tb_warp_bitonic_sort_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_warp_bitonic_sort_dump.vcd]
"""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
VCD  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "tb_warp_bitonic_sort_dump.vcd")
OUT  = os.path.join(HERE, "warp_bitonic_sort_waveform.png")

# Display order (top -> bottom).
WANT = ["clk", "in_valid", "in_dir", "in_data",
        "out_valid", "out_dir",
        "out0", "out1", "out2", "out3", "out4", "out5", "out6", "out7"]
LEVEL  = {"clk", "in_valid", "in_dir", "out_valid", "out_dir"}
# name -> nibble width for fixed-width hex buses
HEXBUS = {"in_data": 16,
          "out0": 2, "out1": 2, "out2": 2, "out3": 2,
          "out4": 2, "out5": 2, "out6": 2, "out7": 2}

PS = 1000                                         # ps per ns (Icarus dumps in ps)


def parse_vcd(path):
    sym_of, changes = {}, []
    depth, in_top, defining, t = 0, False, True, 0
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if defining:
                if line.startswith("$scope"):
                    depth += 1
                    in_top = (depth == 1)          # tb_warp_bitonic_sort_dump = depth 1
                elif line.startswith("$upscope"):
                    depth -= 1
                    in_top = (depth == 1)
                elif line.startswith("$var"):
                    parts = line.split()
                    symbol, name = parts[3], parts[4]
                    if in_top and name in WANT and name not in sym_of:
                        sym_of[name] = symbol
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
    return sym_of, changes


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


def hex_fixed(binstr, nibbles):
    try:
        return "%0*X" % (nibbles, int(binstr, 2))
    except (ValueError, TypeError):
        return None


def showcase_window(series, sym_of):
    """Return (T0, T1) bracketing the FIRST vector: from the first in_valid
    pulse to shortly after the out_valid pulse it produces."""
    iv = series[sym_of["in_valid"]]
    ov = series[sym_of["out_valid"]]
    t_start = next((t for (t, v) in iv if v == "1"), None)
    if t_start is None:
        sys.exit("no in_valid pulse found in VCD")
    t_out = next((t for (t, v) in ov if t > t_start and v == "1"), None)
    if t_out is None:
        t_out = t_start + 80 * PS
    return t_start - 25 * PS, t_out + 45 * PS


def main():
    if not os.path.exists(VCD):
        sys.exit("VCD not found: %s  (run `make icarus_dump` first)" % VCD)
    sym_of, changes = parse_vcd(VCD)
    missing = [w for w in WANT if w not in sym_of]
    if missing:
        sys.exit("signals not found in VCD: %s" % missing)
    series = build_series(sym_of, changes)
    T0, T1 = showcase_window(series, sym_of)

    step = 250
    ts = list(range(T0, T1 + step, step))

    fig, axes = plt.subplots(len(WANT), 1, figsize=(13, 10.6), sharex=True)
    fig.suptitle(
        "warp_bitonic_sort - GPU warp-level bitonic sorting network showcase\n"
        "REAL Icarus Verilog capture (tb_warp_bitonic_sort_dump.vcd), clk 10 ns - "
        "ascending sort of a reverse ramp -> out lanes 0x00..0x70 monotonic, LAT=7",
        fontsize=10.5, fontweight="bold")

    def draw_bus(ax, seq, nibbles):
        pts = sorted(set([T0] + [tt for (tt, _) in seq if T0 < tt < T1] + [T1]))
        for i in range(len(pts) - 1):
            a_, b_ = pts[i], pts[i + 1]
            raw = value_at(seq, a_)
            txt = hex_fixed(raw, nibbles)
            an, bn = a_ / PS, b_ / PS
            if txt is not None:
                ax.fill_between([an, bn], 0.16, 0.84, color="#cfe3ff",
                                edgecolor="#1f4e8c", lw=1.0, zorder=2)
                ax.text((an + bn) / 2, 0.5, "0x" + txt, ha="center",
                        va="center", fontsize=7.6, fontfamily="monospace", zorder=3)
        ax.set_ylim(0, 1)

    posedges = [(5 + 10 * k) * PS for k in range(0, 400)]
    posedges = [p for p in posedges if T0 <= p <= T1]

    for ax, name in zip(axes, WANT):
        seq = series[sym_of[name]]
        ax.set_ylabel(name, rotation=0, ha="right", va="center",
                      fontsize=9.0, labelpad=30, fontfamily="monospace")
        ax.set_yticks([])
        for spine in ("top", "right", "left"):
            ax.spines[spine].set_visible(False)
        for p in posedges:
            ax.axvline(p / PS, color="0.93", lw=0.6, zorder=0)

        if name in HEXBUS:
            draw_bus(ax, seq, HEXBUS[name])
        else:
            xs, ys, last = [], [], value_at(seq, T0) or "0"
            for t in ts:
                v = value_at(seq, t) or last
                last = v
                xs.append(t / PS)
                ys.append(1 if v == "1" else 0)
            if name == "clk":
                color = "#1f4e8c"      # blue: system clock
            elif name == "in_valid":
                color = "#5b2d91"      # violet: input strobe
            elif name == "out_valid":
                color = "#1f7a4d"      # green: sorted-vector strobe
            else:                      # in_dir / out_dir
                color = "#d98a00"      # amber: sort direction
            ax.step(xs, ys, where="post", color=color, lw=1.5)
            ax.fill_between(xs, ys, step="post", color=color, alpha=0.08)
            ax.set_ylim(-0.25, 1.35)

    axes[-1].set_xlabel("time (ns)", fontsize=10)
    axes[-1].set_xlim(T0 / PS, T1 / PS)

    fig.tight_layout(rect=[0, 0, 1, 0.94])
    fig.savefig(OUT, dpi=130)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
