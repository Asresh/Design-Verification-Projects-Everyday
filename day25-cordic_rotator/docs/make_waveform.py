#!/usr/bin/env python3
"""
make_waveform.py - render docs/cordic_rotation_waveform.png from a REAL sim run.

Parses the VCD produced by Icarus Verilog (`tb_cordic_rotation_dump.vcd`, from
`make icarus_dump`) and draws the DIRECTED SHOWCASE of the rotation-mode CORDIC
engine: a back-to-back (zero-bubble) sin/cos sweep. The start vector is preloaded
to x_in = round(2^13/K) = 4975, y_in = 0, so after the fixed LAT = NITER+1 = 17
cycle latency the outputs read directly as scaled cosine and sine:

    out_x ~= cos(angle) * 8192      out_y ~= sin(angle) * 8192

The angle sweeps -pi/2, -pi/4, 0, pi/6, pi/4, pi/3, pi/2, 2*pi/3, 3*pi/4, 5*pi/6,
so the trace shows out_x falling as cosine and out_y rising as sine across all
quadrants - the last three angles exceed pi/2 and exercise the combinational
QUADRANT-FOLD. All values are signed Q2.13 fixed-point (8192 = 1.0).

The trace is captured from a genuine Icarus simulation - it is NOT hand-modeled.

Usage:
    make icarus_dump          # produces tb_cordic_rotation_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_cordic_rotation_dump.vcd]
"""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
VCD  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "tb_cordic_rotation_dump.vcd")
OUT  = os.path.join(HERE, "cordic_rotation_waveform.png")

# Display order (top -> bottom).
WANT   = ["clk", "in_valid", "in_angle", "out_valid", "out_x", "out_y"]
LEVEL  = {"clk", "in_valid", "out_valid"}
SBUS   = {"in_angle", "out_x", "out_y"}        # signed-decimal buses (gated)
GATEOF = {"in_angle": "in_valid", "out_x": "out_valid", "out_y": "out_valid"}

PS = 1000                                       # ps per ns


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
                    in_top = (depth == 1)       # tb_cordic_rotation_dump = depth 1
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


def as_signed(binstr, w):
    try:
        v = int(binstr, 2)
        if v >= (1 << (w - 1)):
            v -= (1 << w)
        return str(v)
    except (ValueError, TypeError):
        return None


def showcase_window(series, sym_of):
    """From just before the first in_valid pulse to a few cycles past the tenth
    result, so all ten sin/cos points (input + output phase) are on screen."""
    iv = series[sym_of["in_valid"]]
    t_start = next((t for (t, v) in iv if v == "1"), None)
    if t_start is None:
        sys.exit("no in_valid pulse found in VCD")
    return t_start - 20 * PS, t_start + 290 * PS


def main():
    if not os.path.exists(VCD):
        sys.exit("VCD not found: %s  (run `make icarus_dump` first)" % VCD)
    sym_of, width, changes = parse_vcd(VCD)
    missing = [w for w in WANT if w not in sym_of]
    if missing:
        sys.exit("signals not found in VCD: %s" % missing)
    series = build_series(sym_of, changes)
    T0, T1 = showcase_window(series, sym_of)

    step = 250
    ts = list(range(T0, T1 + step, step))

    fig, axes = plt.subplots(len(WANT), 1, figsize=(13, 6.6), sharex=True)
    fig.suptitle(
        "cordic_rotation - rotation-mode CORDIC sin/cos sweep (x_in=4975=1/K, y_in=0)\n"
        "REAL Icarus Verilog capture (tb_cordic_rotation_dump.vcd), clk 10 ns, LAT=17 - "
        "out_x~=cos*8192, out_y~=sin*8192; last 3 angles exceed pi/2 (quadrant-fold)",
        fontsize=10.5, fontweight="bold")

    def draw_signed_bus(ax, seq, tint, w, gate_seq):
        pts = sorted(set([T0] + [tt for (tt, _) in seq if T0 < tt < T1] +
                         [tt for (tt, _) in gate_seq if T0 < tt < T1] + [T1]))
        for i in range(len(pts) - 1):
            a_, b_ = pts[i], pts[i + 1]
            if value_at(gate_seq, (a_ + b_) // 2) != "1":
                continue
            txt = as_signed(value_at(seq, a_), w)
            an, bn = a_ / PS, b_ / PS
            if txt is not None:
                ax.fill_between([an, bn], 0.16, 0.84, color=tint,
                                edgecolor="#1f4e8c", lw=1.0, zorder=2)
                ax.text((an + bn) / 2, 0.5, txt, ha="center", va="center",
                        fontsize=7.6, fontfamily="monospace", zorder=3)
        ax.set_ylim(0, 1)

    posedges = [(5 + 10 * k) * PS for k in range(0, 400)]
    posedges = [p for p in posedges if T0 <= p <= T1]

    tint = {"in_angle": "#dfe8f5", "out_x": "#dff0e6", "out_y": "#f3e7dd"}

    for ax, name in zip(axes, WANT):
        seq = series[sym_of[name]]
        ax.set_ylabel(name, rotation=0, ha="right", va="center",
                      fontsize=8.6, labelpad=30, fontfamily="monospace")
        ax.set_yticks([])
        for spine in ("top", "right", "left"):
            ax.spines[spine].set_visible(False)
        for p in posedges:
            ax.axvline(p / PS, color="0.93", lw=0.6, zorder=0)

        if name in SBUS:
            draw_signed_bus(ax, seq, tint[name], width[name],
                            series[sym_of[GATEOF[name]]])
        else:
            xs, ys, last = [], [], value_at(seq, T0) or "0"
            for t in ts:
                v = value_at(seq, t) or last
                last = v
                xs.append(t / PS)
                ys.append(1 if v == "1" else 0)
            color = {"clk": "#1f4e8c", "in_valid": "#5b2d91",
                     "out_valid": "#1f7a4d"}[name]
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
