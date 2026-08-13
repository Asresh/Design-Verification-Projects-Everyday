#!/usr/bin/env python3
"""
make_waveform.py - render docs/coalescer_waveform.png from a REAL simulator run.

Parses the VCD produced by Icarus Verilog (`tb_coalescer_dump.vcd`, from
`make icarus_dump`) and draws the DIRECTED SHOWCASE warp of the GPU
memory-coalescing unit:

    8 active lanes (lane_en = 0xFF), byte addresses:
        lane 0,1,2,5,7 -> cache line 0x20   (0x1000-region)
        lane 3,4,6     -> cache line 0x40   (0x2000-region)

The story the window tells:
    * `req_valid` presents one warp of 8 per-lane addresses; `req_ready` accepts
      it (one warp in flight at a time),
    * the coalescer streams out the UNIQUE cache lines, one per cycle:
        - beat 0 : txn_line=0x20, txn_mask=10100111 (lanes 0,1,2,5,7), last=0
        - beat 1 : txn_line=0x40, txn_mask=01011000 (lanes 3,4,6),     last=1
    * `txn_last` marks the final line, so 8 lane accesses coalesced into 2 line
      transactions (a 4x memory-efficiency win).

The trace is captured from a genuine Icarus simulation - it is NOT hand-modeled.

Usage:
    make icarus_dump          # produces tb_coalescer_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_coalescer_dump.vcd]
"""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
VCD  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "tb_coalescer_dump.vcd")
OUT  = os.path.join(HERE, "coalescer_waveform.png")

# Display order (top -> bottom).
WANT = ["clk", "req_valid", "req_ready", "lane_en",
        "txn_valid", "txn_ready", "txn_line", "txn_mask", "txn_last"]
LEVEL  = {"clk", "req_valid", "req_ready", "txn_valid", "txn_ready", "txn_last"}
HEXBUS = {"txn_line"}                 # render as hex value
BINBUS = {"lane_en": 8, "txn_mask": 8}  # render as fixed-width binary mask

PS = 1000                             # ps per ns (Icarus dumps in ps)


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
                    in_top = (depth == 1)          # tb_coalescer_dump = depth 1
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


def bin_fixed(binstr, width):
    try:
        return format(int(binstr, 2), "0%db" % width)
    except (ValueError, TypeError):
        return None


def hex_of(binstr):
    try:
        return "0x%X" % int(binstr, 2)
    except (ValueError, TypeError):
        return None


def showcase_window(series, sym_of):
    """Return (T0, T1) bracketing the FIRST warp (the showcase)."""
    rv = series[sym_of["req_valid"]]
    tl = series[sym_of["txn_last"]]
    t_start = next((t for (t, v) in rv if v == "1"), None)
    if t_start is None:
        sys.exit("no req_valid pulse found in VCD")
    t_done = next((t for (t, v) in tl if v == "1" and t >= t_start), None)
    if t_done is None:
        t_done = t_start + 80 * PS
    return t_start - 25 * PS, t_done + 35 * PS


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

    fig, axes = plt.subplots(len(WANT), 1, figsize=(13, 9.2), sharex=True)
    fig.suptitle(
        "coalescer - warp showcase:  8 lanes (lane_en=0xFF) -> 2 cache lines\n"
        "REAL Icarus Verilog capture (tb_coalescer_dump.vcd), clk 10 ns - "
        "line 0x20 serves lanes {0,1,2,5,7}, line 0x40 serves {3,4,6}, txn_last on beat 1",
        fontsize=10.5, fontweight="bold")

    def draw_bus(ax, seq, kind, width=0):
        pts = sorted(set([T0] + [tt for (tt, _) in seq if T0 < tt < T1] + [T1]))
        for i in range(len(pts) - 1):
            a_, b_ = pts[i], pts[i + 1]
            raw = value_at(seq, a_)
            txt = hex_of(raw) if kind == "hex" else bin_fixed(raw, width)
            an, bn = a_ / PS, b_ / PS
            if txt is not None:
                ax.fill_between([an, bn], 0.16, 0.84, color="#cfe3ff",
                                edgecolor="#1f4e8c", lw=1.0, zorder=2)
                ax.text((an + bn) / 2, 0.5, txt, ha="center",
                        va="center", fontsize=8.0, fontfamily="monospace", zorder=3)
        ax.set_ylim(0, 1)

    posedges = [(5 + 10 * k) * PS for k in range(0, 400)]
    posedges = [p for p in posedges if T0 <= p <= T1]

    for ax, name in zip(axes, WANT):
        seq = series[sym_of[name]]
        ax.set_ylabel(name, rotation=0, ha="right", va="center",
                      fontsize=9.5, labelpad=30, fontfamily="monospace")
        ax.set_yticks([])
        for spine in ("top", "right", "left"):
            ax.spines[spine].set_visible(False)
        for p in posedges:
            ax.axvline(p / PS, color="0.93", lw=0.6, zorder=0)

        if name in HEXBUS:
            draw_bus(ax, seq, "hex")
        elif name in BINBUS:
            draw_bus(ax, seq, "bin", BINBUS[name])
        else:
            xs, ys, last = [], [], value_at(seq, T0) or "0"
            for t in ts:
                v = value_at(seq, t) or last
                last = v
                xs.append(t / PS)
                ys.append(1 if v == "1" else 0)
            if name == "clk":
                color = "#1f4e8c"      # blue: system clock
            elif name in ("req_valid", "req_ready"):
                color = "#5b2d91"      # violet: request handshake
            elif name in ("txn_valid", "txn_ready"):
                color = "#0b6b3a"      # green: line-stream handshake
            else:                      # txn_last
                color = "#d98a00"      # amber: last-line marker
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
