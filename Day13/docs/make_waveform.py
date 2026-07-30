#!/usr/bin/env python3
"""
make_waveform.py - render docs/mac_dot_waveform.png from a REAL simulator run.

Parses the VCD produced by Icarus Verilog (`tb_mac_dot_dump.vcd`, from
`make icarus_dump`) and draws the DIRECTED SHOWCASE dot product of the
mac_dot tensor-core-style multiply-accumulate engine:

    a = [ 3,  5, -2,  4]
    b = [ 2,  4,  7,  1]
    result = 3*2 + 5*4 + (-2)*7 + 4*1 = 6 + 20 - 14 + 4 = 16

The story the window tells:
    * `in_valid` is high for 4 consecutive clocks streaming the operand pairs,
    * `in_a` / `in_b` present each element on the buses,
    * `acc` (the DUT's internal accumulator, mirrored to the top level) builds
      up the running sum:  6 -> 26 -> 12 -> 16,
    * `in_last` marks the 4th element,
    * one clock later `out_valid` pulses for exactly one cycle and `out_result`
      latches 16, and the accumulator restarts clean for the next vector.

The trace is captured from a genuine Icarus simulation - it is NOT hand-modeled.

Usage:
    make icarus_dump          # produces tb_mac_dot_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_mac_dot_dump.vcd]
"""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
VCD  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "tb_mac_dot_dump.vcd")
OUT  = os.path.join(HERE, "mac_dot_waveform.png")

# Display order (top -> bottom).
WANT = ["clk", "in_valid", "in_a", "in_b", "in_last",
        "acc_mirror", "out_valid", "out_result"]
LEVEL   = {"clk", "in_valid", "in_last", "out_valid"}
# Signed decimal buses, with their bit widths for two's-complement decode.
SIGNED  = {"in_a": 8, "in_b": 8, "acc_mirror": 32, "out_result": 32}
# Friendlier row labels.
LABEL   = {"acc_mirror": "acc", "out_result": "out_result"}

PS = 1000                              # ps per ns (Icarus dumps in ps)


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
                    in_top = (depth == 1)          # tb_mac_dot_dump = depth 1
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


def to_signed(binstr, width):
    try:
        v = int(binstr, 2)
    except (ValueError, TypeError):
        return None
    if v >= (1 << (width - 1)):
        v -= (1 << width)
    return v


def showcase_window(series, sym_of):
    """Return (T0, T1) bracketing the FIRST dot product (the showcase)."""
    iv = series[sym_of["in_valid"]]
    ov = series[sym_of["out_valid"]]
    t_start = next((t for (t, v) in iv if v == "1"), None)
    if t_start is None:
        sys.exit("no in_valid pulse found in VCD")
    t_done = next((t for (t, v) in ov if v == "1" and t >= t_start), None)
    if t_done is None:
        t_done = t_start + 80 * PS
    return t_start - 30 * PS, t_done + 40 * PS


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

    fig, axes = plt.subplots(len(WANT), 1, figsize=(13, 8.6), sharex=True)
    fig.suptitle(
        "mac_dot - dot-product showcase:  a=[3,5,-2,4] . b=[2,4,7,1] = 16\n"
        "REAL Icarus Verilog capture (tb_mac_dot_dump.vcd), clk 10 ns - "
        "4 operand pairs streamed, acc builds 6->26->12->16, out_valid pulses, result=16",
        fontsize=10.5, fontweight="bold")

    def draw_bus(ax, seq, width):
        pts = sorted(set([T0] + [tt for (tt, _) in seq if T0 < tt < T1] + [T1]))
        for i in range(len(pts) - 1):
            a_, b_ = pts[i], pts[i + 1]
            iv = to_signed(value_at(seq, a_), width)
            an, bn = a_ / PS, b_ / PS
            if iv is not None:
                ax.fill_between([an, bn], 0.16, 0.84, color="#cfe3ff",
                                edgecolor="#1f4e8c", lw=1.0, zorder=2)
                ax.text((an + bn) / 2, 0.5, "%d" % iv, ha="center",
                        va="center", fontsize=8.5, fontfamily="monospace", zorder=3)
        ax.set_ylim(0, 1)

    # Light gridlines at each system-clock posedge in the window.
    posedges = [(5 + 10 * k) * PS for k in range(0, 400)]
    posedges = [p for p in posedges if T0 <= p <= T1]

    for ax, name in zip(axes, WANT):
        seq = series[sym_of[name]]
        ax.set_ylabel(LABEL.get(name, name), rotation=0, ha="right", va="center",
                      fontsize=9.5, labelpad=30, fontfamily="monospace")
        ax.set_yticks([])
        for spine in ("top", "right", "left"):
            ax.spines[spine].set_visible(False)
        for p in posedges:
            ax.axvline(p / PS, color="0.93", lw=0.6, zorder=0)

        if name in SIGNED:
            draw_bus(ax, seq, SIGNED[name])
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
                color = "#5b2d91"      # violet: operand-stream valid
            elif name == "in_last":
                color = "#0b6b3a"      # green: last-element marker
            else:                      # out_valid
                color = "#d98a00"      # amber: result pulse
            ax.step(xs, ys, where="post", color=color, lw=1.5)
            ax.fill_between(xs, ys, step="post", color=color, alpha=0.08)
            ax.set_ylim(-0.25, 1.35)

    axes[-1].set_xlabel("time (ns)", fontsize=10)
    axes[-1].set_xlim(T0 / PS, T1 / PS)

    fig.tight_layout(rect=[0, 0, 1, 0.93])
    fig.savefig(OUT, dpi=130)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
