#!/usr/bin/env python3
"""
make_waveform.py - render docs/apb_regfile_waveform.png from a REAL simulator run.

This parses the VCD produced by Icarus Verilog (`tb_apb_dump.vcd`, from
`make icarus_dump`) and draws a cycle-accurate digital timing diagram of the
APB "showcase" window: reset release, a write handshake, a read hit, and a
PSLVERR error on an out-of-range address.

The waveform is therefore captured from a genuine simulation, not hand-modeled.

Usage:
    make icarus_dump          # produces tb_apb_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_apb_dump.vcd]
"""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon

HERE = os.path.dirname(os.path.abspath(__file__))
VCD  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "tb_apb_dump.vcd")
OUT  = os.path.join(HERE, "apb_regfile_waveform.png")

# Signals to plot (top-level tb scope), in display order top->bottom.
WANT = ["PCLK", "PRESETn", "PSEL", "PENABLE", "PWRITE",
        "PADDR", "PWDATA", "PSTRB", "PREADY", "PRDATA", "PSLVERR"]
BUS  = {"PADDR", "PWDATA", "PSTRB", "PRDATA"}   # drawn as value bars


def parse_vcd(path):
    """Return (name->symbol map, list of (time, symbol, value))."""
    sym_of = {}
    changes = []
    depth = 0
    in_top = False
    with open(path) as f:
        t = 0
        defining = True
        for line in f:
            line = line.strip()
            if not line:
                continue
            if defining:
                if line.startswith("$scope"):
                    depth += 1
                    in_top = (depth == 1)          # tb_apb_dump is scope depth 1
                elif line.startswith("$upscope"):
                    depth -= 1
                    in_top = (depth == 1)
                elif line.startswith("$var"):
                    # $var <type> <width> <symbol> <name> ... $end
                    parts = line.split()
                    symbol, name = parts[3], parts[4]
                    if in_top and name in WANT and name not in sym_of:
                        sym_of[name] = symbol
                elif line.startswith("$enddefinitions"):
                    defining = False
                continue
            # value-change section
            if line[0] == "#":
                t = int(line[1:])
            elif line[0] in "01xz":
                changes.append((t, line[1:], line[0]))
            elif line[0] in "bB":
                val, symbol = line[1:].split()
                changes.append((t, symbol, val))
            # ignore 'r' real changes
    return sym_of, changes


def build_series(sym_of, changes):
    """symbol->sorted list of (time, value_str)."""
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

    # Time window: reset + showcase (0 .. 175 ns). Timescale is 1 ps.
    PS_PER_NS = 1000
    t0, t1 = 0, 175 * PS_PER_NS
    # Sample grid every 0.5 ns for clean edges.
    step = 500
    ts = list(range(t0, t1 + step, step))

    fig, axes = plt.subplots(len(WANT), 1, figsize=(13, 8.6), sharex=True)
    fig.suptitle("apb_regfile - APB4 write / read / out-of-range(PSLVERR)\n"
                 "captured from Icarus Verilog (tb_apb_dump.vcd) - REAL simulation",
                 fontsize=12, fontweight="bold")

    # Clock-cycle gridlines (posedges at 5ns + k*10ns).
    posedges = [ (5 + 10*k) * PS_PER_NS for k in range(0, 18) ]
    posedges = [p for p in posedges if t0 <= p <= t1]

    for ax, name in zip(axes, WANT):
        sym = sym_of[name]
        seq = series[sym]
        ax.set_ylabel(name, rotation=0, ha="right", va="center",
                      fontsize=10, labelpad=28, fontfamily="monospace")
        ax.set_yticks([])
        for spine in ("top", "right", "left"):
            ax.spines[spine].set_visible(False)
        for p in posedges:
            ax.axvline(p / PS_PER_NS, color="0.90", lw=0.7, zorder=0)

        if name in BUS:
            # Draw value bars; label hex when the value changes.
            prev = None
            seg_start = t0
            def draw_seg(a, b, valstr):
                if a >= b:
                    return
                an, bn = a / PS_PER_NS, b / PS_PER_NS
                iv = to_int(valstr) if valstr is not None else None
                stable = (iv is not None)
                y0, y1 = 0.18, 0.82
                if stable and iv != 0:
                    ax.add_patch(Polygon(
                        [(an, 0.5), (an + 0.4, y1), (bn - 0.4, y1),
                         (bn, 0.5), (bn - 0.4, y0), (an + 0.4, y0)],
                        closed=True, facecolor="#cfe3ff",
                        edgecolor="#1f4e8c", lw=1.1, zorder=2))
                    label = "0x%0*X" % (max(2, (len(valstr)+3)//4), iv)
                    ax.text((an + bn)/2, 0.5, label, ha="center", va="center",
                            fontsize=8, fontfamily="monospace", zorder=3)
                else:
                    ax.hlines(0.5, an, bn, color="0.55", lw=1.2, zorder=2)
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
            color = "#1f4e8c" if name == "PCLK" else "#0b6b3a"
            ax.step(xs, ys, where="post", color=color, lw=1.4)
            ax.fill_between(xs, ys, step="post", color=color, alpha=0.08)
            ax.set_ylim(-0.25, 1.35)

    axes[-1].set_xlabel("time (ns)   -   clock period 10 ns, posedge at 5 + 10k ns",
                        fontsize=10)
    axes[-1].set_xlim(t0 / PS_PER_NS, t1 / PS_PER_NS)

    # Annotate the four transfers.
    ann = axes[0]
    for x, txt in [(55, "WRITE reg1"), (85, "READ reg1"),
                   (115, "WRITE OOB"), (145, "READ OOB")]:
        ann.text(x, 1.55, txt, ha="center", fontsize=8.5, color="#333",
                 fontfamily="monospace")

    fig.tight_layout(rect=[0, 0, 1, 0.95])
    fig.savefig(OUT, dpi=130)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
