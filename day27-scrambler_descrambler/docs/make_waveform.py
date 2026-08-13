#!/usr/bin/env python3
"""
make_waveform.py - render docs/scrambler_waveform.png from a REAL sim run.

Parses the VCD produced by Icarus Verilog (`tb_scrambler_dump.vcd`, from
`make icarus_dump`) and draws the SELF-SYNCHRONIZATION window: the descrambler
is reset to a DIFFERENT seed than the scrambler, so as the mixed payload streams
through the link

    in_data --> [ scrambler SEED=all-ones ] --scr_data--> [ descrambler SEED=0 ] --> des_data

the recovered stream (des_data, 2 cycles behind in_data) starts as garbage and
then LOCKS - from word ceil(58/8)=8 on, des_data reproduces in_data exactly,
proving the multiplicative descrambler re-derived the transmitter state from the
received bits alone. scr_data shows the whitened (spectrum-spread) line data.

This trace is captured from a genuine Icarus Verilog simulation - it is NOT
hand-modeled.

Usage:
    make icarus_dump          # produces tb_scrambler_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_scrambler_dump.vcd]
"""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
VCD  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "tb_scrambler_dump.vcd")
OUT  = os.path.join(HERE, "scrambler_waveform.png")

# Display order (top -> bottom).
WANT  = ["clk", "in_valid", "in_data", "scr_data", "des_valid", "des_data", "mark"]
LEVEL = {"clk", "in_valid", "des_valid", "mark"}
HBUS  = {"in_data", "scr_data", "des_data"}
PS    = 1000                          # ps per ns


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
                    in_top = (depth == 1)           # tb_scrambler_dump = depth 1
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


def as_hex(binstr, w):
    try:
        return "0x%02X" % int(binstr, 2)
    except (ValueError, TypeError):
        return None


def window(series, sym_of):
    """The marked mixed-payload section, padded a little on each side so the
    2-cycle pipeline fill and the recovered words are both on screen."""
    mk = series[sym_of["mark"]]
    t0 = next((t for (t, v) in mk if v == "1"), None)
    t1 = next((t for (t, v) in mk if v == "0" and t0 is not None and t > t0), None)
    if t0 is None or t1 is None:
        sys.exit("mark window not found in VCD")
    return t0 - 40 * PS, t1 + 60 * PS


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

    fig, axes = plt.subplots(len(WANT), 1, figsize=(13, 6.6), sharex=True)
    fig.suptitle(
        "self-synchronizing scrambler/descrambler - SELF-SYNC RECOVERY "
        "(G(x)=1+x^39+x^58, 8 bit/cycle)\n"
        "REAL Icarus Verilog capture (tb_scrambler_dump.vcd): scrambler SEED=all-ones, "
        "descrambler SEED=0 -> des_data locks onto in_data (2-cyc latency) from word 8",
        fontsize=10.3, fontweight="bold")

    # coarse one-word (10 ns) grid.
    grid = [g * PS for g in range(0, 100000, 10) if T0 <= g * PS <= T1]

    color = {"clk": "#333333", "in_valid": "#1f7a4d",
             "des_valid": "#1f7a4d", "mark": "#5b2d91"}
    tint  = {"in_data": "#dff0e6", "scr_data": "#f5e6df", "des_data": "#dfe8f5"}

    def draw_hex_bus(ax, seq, tint_c, w):
        pts = sorted(set([T0] + [tt for (tt, _) in seq if T0 < tt < T1] + [T1]))
        for i in range(len(pts) - 1):
            a_, b_ = pts[i], pts[i + 1]
            txt = as_hex(value_at(seq, a_), w)
            an, bn = a_ / PS, b_ / PS
            if txt is not None and (bn - an) > 1.0:
                ax.fill_between([an, bn], 0.16, 0.84, color=tint_c,
                                edgecolor="#1f4e8c", lw=1.0, zorder=2)
                ax.text((an + bn) / 2, 0.5, txt, ha="center", va="center",
                        fontsize=7.6, fontfamily="monospace", zorder=3)
        ax.set_ylim(0, 1)

    for ax, name in zip(axes, WANT):
        seq = series[sym_of[name]]
        ax.set_ylabel(name, rotation=0, ha="right", va="center",
                      fontsize=8.6, labelpad=30, fontfamily="monospace")
        ax.set_yticks([])
        for spine in ("top", "right", "left"):
            ax.spines[spine].set_visible(False)
        for g in grid:
            ax.axvline(g / PS, color="0.93", lw=0.6, zorder=0)

        if name in HBUS:
            draw_hex_bus(ax, seq, tint[name], width[name])
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

    axes[-1].set_xlabel("time (ns)", fontsize=10)
    axes[-1].set_xlim(T0 / PS, T1 / PS)

    fig.tight_layout(rect=[0, 0, 1, 0.9])
    fig.savefig(OUT, dpi=130)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
