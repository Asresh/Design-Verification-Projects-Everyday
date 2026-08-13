#!/usr/bin/env python3
"""
make_waveform.py - render docs/uart_waveform.png from a REAL simulator run.

This parses the VCD produced by Icarus Verilog (`tb_uart_dump.vcd`, from
`make icarus_dump`) and draws the "showcase" byte: 0xA5 transmitted at
cfg_clks_per_bit=16 (160 ns per bit). It shows the serial line framing - one
start bit (0), eight data bits LSB-first, one stop bit (1) - plus the parallel
handshake (tx_start / tx_busy) and the deserialized result (rx_valid / rx_data).

The waveform is therefore captured from a genuine simulation, not hand-modeled.

Usage:
    make icarus_dump          # produces tb_uart_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_uart_dump.vcd]
"""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon

HERE = os.path.dirname(os.path.abspath(__file__))
VCD  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "tb_uart_dump.vcd")
OUT  = os.path.join(HERE, "uart_waveform.png")

WANT = ["tx_start", "tx_data", "tx_serial", "tx_busy",
        "rx_valid", "rx_data", "framing_err"]
BUS  = {"tx_data", "rx_data"}

PS_PER_NS  = 1000
BIT_NS     = 160            # cfg_clks_per_bit(16) * clock period(10 ns)
BIT_LABELS = ["START", "D0", "D1", "D2", "D3", "D4", "D5", "D6", "D7", "STOP"]


def parse_vcd(path):
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
                    in_top = (depth == 1)          # tb_uart_dump is scope depth 1
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


def first_falling(seq, after_ps):
    """First 1->0 transition time at/after after_ps."""
    prev = None
    for (tt, v) in seq:
        if prev == "1" and v == "0" and tt >= after_ps:
            return tt
        prev = v
    return None


def main():
    if not os.path.exists(VCD):
        sys.exit("VCD not found: %s  (run `make icarus_dump` first)" % VCD)
    sym_of, changes = parse_vcd(VCD)
    missing = [w for w in WANT if w not in sym_of]
    if missing:
        sys.exit("signals not found in VCD: %s" % missing)
    series = build_series(sym_of, changes)

    # Locate the showcase start bit (first falling edge of tx_serial after 60 ns).
    tstart = first_falling(series[sym_of["tx_serial"]], 60 * PS_PER_NS)
    if tstart is None:
        sys.exit("could not find a start bit in the VCD")

    bit_ps = BIT_NS * PS_PER_NS
    boundaries = [tstart + bit_ps * k for k in range(0, 11)]
    t0 = tstart - 60 * PS_PER_NS
    t1 = boundaries[-1] + 60 * PS_PER_NS
    step = 500
    ts = list(range(t0, t1 + step, step))

    fig, axes = plt.subplots(len(WANT), 1, figsize=(13, 7.4), sharex=True)
    fig.suptitle("uart - transmit byte 0xA5 @ cfg_clks_per_bit=16 (8-N-1 frame)\n"
                 "captured from Icarus Verilog (tb_uart_dump.vcd) - REAL simulation",
                 fontsize=12, fontweight="bold")

    for ax, name in zip(axes, WANT):
        sym = sym_of[name]
        seq = series[sym]
        ax.set_ylabel(name, rotation=0, ha="right", va="center",
                      fontsize=10, labelpad=30, fontfamily="monospace")
        ax.set_yticks([])
        for spine in ("top", "right", "left"):
            ax.spines[spine].set_visible(False)
        # Bit-boundary gridlines.
        for b in boundaries:
            ax.axvline(b / PS_PER_NS, color="0.80", lw=0.8, zorder=0)

        if name in BUS:
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
                        [(an, 0.5), (an + 3, y1), (bn - 3, y1),
                         (bn, 0.5), (bn - 3, y0), (an + 3, y0)],
                        closed=True, facecolor="#cfe3ff",
                        edgecolor="#1f4e8c", lw=1.1, zorder=2))
                    label = "0x%02X" % iv
                    ax.text((an + bn)/2, 0.5, label, ha="center", va="center",
                            fontsize=9, fontfamily="monospace", zorder=3)
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
            color = "#8a1f7a" if name == "tx_serial" else "#0b6b3a"
            ax.step(xs, ys, where="post", color=color, lw=1.6 if name == "tx_serial" else 1.3)
            ax.fill_between(xs, ys, step="post", color=color, alpha=0.08)
            ax.set_ylim(-0.25, 1.35)

    # Annotate the bit fields above the tx_serial row.
    ser_ax = axes[WANT.index("tx_serial")]
    for k, lab in enumerate(BIT_LABELS):
        c = (boundaries[k] + bit_ps/2) / PS_PER_NS
        ser_ax.text(c, 1.55, lab, ha="center", fontsize=8.5,
                    color="#333", fontfamily="monospace")

    axes[-1].set_xlabel("time (ns)   -   1 bit = %d ns (cfg=16 x 10 ns clock)" % BIT_NS,
                        fontsize=10)
    axes[-1].set_xlim(t0 / PS_PER_NS, t1 / PS_PER_NS)

    fig.tight_layout(rect=[0, 0, 1, 0.95])
    fig.savefig(OUT, dpi=130)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
