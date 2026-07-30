#!/usr/bin/env python3
"""
make_waveform.py - render docs/simt_stack_waveform.png from a REAL simulator run.

Parses the VCD produced by Icarus Verilog (`tb_simt_stack_dump.vcd`, from
`make icarus_dump`) and draws the DIRECTED SHOWCASE of the GPU SIMT
reconvergence stack:

    cmd 0  INIT    mask=0xFF pc=0x0010   -> launch an 8-lane warp        (sp 0->1)
    cmd 1  DIVERGE take={0..3}           -> branch DIVERGES the warp:     (sp 1->3)
                                            TOS = taken {0x0F} @ 0x0200
    cmd 2  POP                           -> taken path done, expose       (sp 3->2)
                                            fall-through {0xF0} @ 0x0300
    cmd 3  POP                           -> fall-through done, expose      (sp 2->1)
                                            RECONVERGED warp {0xFF} @ 0x0100
    cmd 4  POP                           -> warp retires                   (sp 1->0)

The story the window tells: the active mask (tos_mask) splits 0xFF -> 0x0F ->
0xF0 and then REUNITES to 0xFF at the reconvergence PC before the warp retires,
while the stack pointer sp rises to 3 and drains back to 0.

The trace is captured from a genuine Icarus simulation - it is NOT hand-modeled.

Usage:
    make icarus_dump          # produces tb_simt_stack_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_simt_stack_dump.vcd]
"""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
VCD  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "tb_simt_stack_dump.vcd")
OUT  = os.path.join(HERE, "simt_stack_waveform.png")

# Display order (top -> bottom).
WANT = ["clk", "cmd_valid", "cmd_ready", "op", "in_mask",
        "tos_mask", "tos_pc", "sp", "empty"]
LEVEL  = {"clk", "cmd_valid", "cmd_ready", "empty"}
OPBUS  = {"op"}                              # decode to INIT/DIV/POP
HEXBUS = {"tos_pc"}                          # render as hex value
DECBUS = {"sp"}                              # render as decimal
BINBUS = {"in_mask": 8, "tos_mask": 8}       # fixed-width binary mask

OP_NAME = {0: "INIT", 1: "DIVERGE", 2: "POP", 3: "?"}
PS = 1000                                    # ps per ns (Icarus dumps in ps)


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
                    in_top = (depth == 1)          # tb_simt_stack_dump = depth 1
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


def dec_of(binstr):
    try:
        return "%d" % int(binstr, 2)
    except (ValueError, TypeError):
        return None


def op_of(binstr):
    try:
        return OP_NAME.get(int(binstr, 2), "?")
    except (ValueError, TypeError):
        return None


def showcase_window(series, sym_of):
    """Return (T0, T1) bracketing the FIRST warp: from the first cmd_valid to
    the empty=1 edge that marks the warp retiring."""
    cv = series[sym_of["cmd_valid"]]
    em = series[sym_of["empty"]]
    t_start = next((t for (t, v) in cv if v == "1"), None)
    if t_start is None:
        sys.exit("no cmd_valid pulse found in VCD")
    # first empty->1 transition strictly after launch = warp retired
    t_retire = None
    prev = "1"
    for (t, v) in em:
        if t > t_start and prev == "0" and v == "1":
            t_retire = t
            break
        prev = v
    if t_retire is None:
        t_retire = t_start + 110 * PS
    return t_start - 20 * PS, t_retire + 30 * PS


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

    fig, axes = plt.subplots(len(WANT), 1, figsize=(13, 9.4), sharex=True)
    fig.suptitle(
        "simt_stack - SIMT reconvergence showcase:  launch -> DIVERGE -> reconverge\n"
        "REAL Icarus Verilog capture (tb_simt_stack_dump.vcd), clk 10 ns - "
        "tos_mask 0xFF -> 0x0F -> 0xF0 -> 0xFF (reunited), sp 0->1->3->2->1->0",
        fontsize=10.5, fontweight="bold")

    def draw_bus(ax, seq, kind, width=0):
        pts = sorted(set([T0] + [tt for (tt, _) in seq if T0 < tt < T1] + [T1]))
        for i in range(len(pts) - 1):
            a_, b_ = pts[i], pts[i + 1]
            raw = value_at(seq, a_)
            if kind == "hex":
                txt = hex_of(raw)
            elif kind == "dec":
                txt = dec_of(raw)
            elif kind == "op":
                txt = op_of(raw)
            else:
                txt = bin_fixed(raw, width)
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

        if name in OPBUS:
            draw_bus(ax, seq, "op")
        elif name in HEXBUS:
            draw_bus(ax, seq, "hex")
        elif name in DECBUS:
            draw_bus(ax, seq, "dec")
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
            elif name in ("cmd_valid", "cmd_ready"):
                color = "#5b2d91"      # violet: command handshake
            else:                      # empty
                color = "#d98a00"      # amber: warp-retired marker
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
