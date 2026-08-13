#!/usr/bin/env python3
"""
make_waveform.py - render docs/router_pkt_waveform.png from a REAL simulator run.

This parses the VCD produced by Icarus Verilog (`tb_router_pkt_dump.vcd`, from
`make icarus_dump`) and draws the directed "showcase" window of the packet
router: after reset release, one packet is routed to each of the four output
ports in turn (dest 0 -> 1 -> 2 -> 3). You can see in_dest select the port,
in_ready honour backpressure, and the matching bit of out_valid assert as each
port drains its FIFO.

The waveform is therefore captured from a genuine simulation, not hand-modeled.

Usage:
    make icarus_dump          # produces tb_router_pkt_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_router_pkt_dump.vcd]
"""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon

HERE = os.path.dirname(os.path.abspath(__file__))
VCD  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "tb_router_pkt_dump.vcd")
OUT  = os.path.join(HERE, "router_pkt_waveform.png")

WANT = ["clk", "rst_n", "in_valid", "in_ready", "in_dest", "in_data",
        "in_last", "out_valid", "out_ready"]
BUS  = {"in_dest", "in_data", "out_valid", "out_ready"}


def parse_vcd(path):
    sym_of = {}
    changes = []
    depth = 0
    in_top = False
    with open(path) as f:
        defining = True
        t = 0
        for line in f:
            line = line.strip()
            if not line:
                continue
            if defining:
                if line.startswith("$scope"):
                    depth += 1
                    in_top = (depth == 1)          # tb_router_pkt_dump = depth 1
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
    want_syms = set(sym_of.values())
    series = {s: [] for s in want_syms}
    for t, sym, val in changes:
        if sym in want_syms:
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


def to_int(binstr):
    try:
        return int(binstr, 2)
    except ValueError:
        return None


def main():
    if not os.path.exists(VCD):
        sys.exit("VCD not found: %s  (run `make icarus_dump` first)" % VCD)
    sym_of, changes = parse_vcd(VCD)
    missing = [w for w in WANT if w not in sym_of]
    if missing:
        sys.exit("signals not found in VCD: %s" % missing)
    series = build_series(sym_of, changes)

    # Time window: reset release + one packet routed to each output port.
    PS_PER_NS = 1000
    t0, t1 = 25 * PS_PER_NS, 140 * PS_PER_NS
    step = 500
    ts = list(range(t0, t1 + step, step))

    fig, axes = plt.subplots(len(WANT), 1, figsize=(13, 9.2), sharex=True)
    fig.suptitle("router_pkt - store-and-forward 1->4 packet router: route dest 0,1,2,3\n"
                 "captured from Icarus Verilog (tb_router_pkt_dump.vcd) - REAL simulation",
                 fontsize=12, fontweight="bold")

    posedges = [(5 + 10*k) * PS_PER_NS for k in range(0, 16)]
    posedges = [p for p in posedges if t0 <= p <= t1]

    def draw_bus(ax, seq, hexfmt=True, width_hint=2):
        prev = None
        seg_start = t0

        def draw_seg(a, b, valstr):
            if a >= b:
                return
            an, bn = a / PS_PER_NS, b / PS_PER_NS
            iv = to_int(valstr) if valstr is not None else None
            y0, y1 = 0.18, 0.82
            if iv is not None and iv != 0:
                ax.add_patch(Polygon(
                    [(an, 0.5), (an + 0.4, y1), (bn - 0.4, y1),
                     (bn, 0.5), (bn - 0.4, y0), (an + 0.4, y0)],
                    closed=True, facecolor="#cfe3ff",
                    edgecolor="#1f4e8c", lw=1.0, zorder=2))
                if hexfmt:
                    label = "0x%0*X" % (width_hint, iv)
                else:
                    label = "%d" % iv
                ax.text((an + bn) / 2, 0.5, label, ha="center", va="center",
                        fontsize=7.5, fontfamily="monospace", zorder=3)
            else:
                ax.hlines(0.5, an, bn, color="0.55", lw=1.1, zorder=2)

        for (tt, v) in seq:
            if tt <= t0:
                prev = v
                continue
            if tt > t1:
                break
            draw_seg(seg_start, tt, prev)
            seg_start = tt
            prev = v
        draw_seg(seg_start, t1, prev)
        ax.set_ylim(0, 1)

    for ax, name in zip(axes, WANT):
        seq = series[sym_of[name]]
        ax.set_ylabel(name, rotation=0, ha="right", va="center",
                      fontsize=9.5, labelpad=30, fontfamily="monospace")
        ax.set_yticks([])
        for spine in ("top", "right", "left"):
            ax.spines[spine].set_visible(False)
        for p in posedges:
            ax.axvline(p / PS_PER_NS, color="0.90", lw=0.7, zorder=0)

        if name in BUS:
            if name == "in_dest":
                draw_bus(ax, seq, hexfmt=False)
            elif name in ("out_valid", "out_ready"):
                draw_bus(ax, seq, hexfmt=True, width_hint=1)
            else:  # in_data
                draw_bus(ax, seq, hexfmt=True, width_hint=2)
        else:
            xs, ys = [], []
            last = value_at(seq, t0) or "0"
            for t in ts:
                v = value_at(seq, t)
                if v is None:
                    v = last
                last = v
                lvl = 1 if v == "1" else 0
                xs.append(t / PS_PER_NS)
                ys.append(lvl)
            color = "#1f4e8c" if name == "clk" else "#0b6b3a"
            ax.step(xs, ys, where="post", color=color, lw=1.4)
            ax.fill_between(xs, ys, step="post", color=color, alpha=0.08)
            ax.set_ylim(-0.25, 1.35)

    axes[-1].set_xlabel("time (ns)   -   clock period 10 ns, posedge at 5 + 10k ns",
                        fontsize=10)
    axes[-1].set_xlim(t0 / PS_PER_NS, t1 / PS_PER_NS)

    # Annotate which port each packet is routed to.
    ann = axes[0]
    for x, txt in [(40, "-> port0"), (65, "-> port1 (3 beats)"),
                   (90, "-> port2"), (110, "-> port3")]:
        ann.text(x, 1.55, txt, ha="center", fontsize=8, color="#333",
                 fontfamily="monospace")

    fig.tight_layout(rect=[0, 0, 1, 0.95])
    fig.savefig(OUT, dpi=130)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
