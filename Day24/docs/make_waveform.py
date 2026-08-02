#!/usr/bin/env python3
"""
make_waveform.py - render docs/secded_ecc_waveform.png from a REAL sim run.

Parses the VCD produced by Icarus Verilog (`tb_secded_ecc_dump.vcd`, from
`make icarus_dump`) and draws the DIRECTED SHOWCASE of the SECDED (72,64)
extended-Hamming ECC block: a 64-bit word is ENCODEd to its 72-bit codeword,
then DECODEd three ways - clean (no error), with a single injected bit flip,
and with a double injected bit flip - so the captured trace shows the whole
detect/correct contract:

    in_op = 0 (ENCODE) : out_valid pulses LAT=2 cycles later with the codeword.
    in_op = 1 (DECODE) :
        clean   -> out_syndrome = 00, out_sbe = 0, out_dbe = 0
        1 flip  -> out_syndrome != 0, out_sbe = 1  (single-bit CORRECTED)
        2 flips -> out_syndrome != 0, out_dbe = 1  (double-bit DETECTED, uncorrectable)

The syndrome bus is gated by out_valid; out_sbe / out_dbe are the correct-vs-
detect verdict lines.

The trace is captured from a genuine Icarus simulation - it is NOT hand-modeled.

Usage:
    make icarus_dump          # produces tb_secded_ecc_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_secded_ecc_dump.vcd]
"""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
VCD  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "tb_secded_ecc_dump.vcd")
OUT  = os.path.join(HERE, "secded_ecc_waveform.png")

# Display order (top -> bottom).
WANT = ["clk", "in_valid", "in_op", "out_valid", "out_op",
        "out_syndrome", "out_sbe", "out_dbe"]
LEVEL  = {"clk", "in_valid", "in_op", "out_valid", "out_op", "out_sbe", "out_dbe"}
HEXBUS = {"out_syndrome"}                              # hex-formatted bus (gated)

PS = 1000                                              # ps per ns


def parse_vcd(path):
    sym_of, changes, width = {}, [], {}
    depth, in_top, defining, t = 0, False, True, 0
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if defining:
                if line.startswith("$scope"):
                    depth += 1
                    in_top = (depth == 1)          # tb_secded_ecc_dump = depth 1
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


def as_hex(binstr, nybbles):
    try:
        return "%0*X" % (nybbles, int(binstr, 2))
    except (ValueError, TypeError):
        return None


def showcase_window(series, sym_of):
    """From just before the first in_valid pulse to a few cycles past the fourth
    showcase result, so ENCODE + the three DECODEs (clean/1-bit/2-bit) are all on
    screen."""
    iv = series[sym_of["in_valid"]]
    t_start = next((t for (t, v) in iv if v == "1"), None)
    if t_start is None:
        sys.exit("no in_valid pulse found in VCD")
    return t_start - 20 * PS, t_start + 200 * PS


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

    fig, axes = plt.subplots(len(WANT), 1, figsize=(13, 7.4), sharex=True)
    fig.suptitle(
        "secded_ecc - SECDED (72,64) extended-Hamming ECC ENCODE + DECODE showcase\n"
        "REAL Icarus Verilog capture (tb_secded_ecc_dump.vcd), clk 10 ns, LAT=2 - "
        "encode, then decode clean / 1-bit (sbe, CORRECTED) / 2-bit (dbe, DETECTED)",
        fontsize=10.5, fontweight="bold")

    ovseq = series[sym_of["out_valid"]]

    def draw_hex_bus(ax, seq, tint, nybbles, gate_seq):
        pts = sorted(set([T0] + [tt for (tt, _) in seq if T0 < tt < T1] +
                         [tt for (tt, _) in gate_seq if T0 < tt < T1] + [T1]))
        for i in range(len(pts) - 1):
            a_, b_ = pts[i], pts[i + 1]
            if value_at(gate_seq, (a_ + b_) // 2) != "1":
                continue
            txt = as_hex(value_at(seq, a_), nybbles)
            an, bn = a_ / PS, b_ / PS
            if txt is not None:
                ax.fill_between([an, bn], 0.16, 0.84, color=tint,
                                edgecolor="#1f4e8c", lw=1.0, zorder=2)
                ax.text((an + bn) / 2, 0.5, txt, ha="center", va="center",
                        fontsize=8.0, fontfamily="monospace", zorder=3)
        ax.set_ylim(0, 1)

    posedges = [(5 + 10 * k) * PS for k in range(0, 400)]
    posedges = [p for p in posedges if T0 <= p <= T1]

    for ax, name in zip(axes, WANT):
        seq = series[sym_of[name]]
        ax.set_ylabel(name, rotation=0, ha="right", va="center",
                      fontsize=8.6, labelpad=30, fontfamily="monospace")
        ax.set_yticks([])
        for spine in ("top", "right", "left"):
            ax.spines[spine].set_visible(False)
        for p in posedges:
            ax.axvline(p / PS, color="0.93", lw=0.6, zorder=0)

        if name in HEXBUS:
            draw_hex_bus(ax, seq, "#e7dcf3", 2, ovseq)     # violet-tint syndrome
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
                color = "#5b2d91"      # violet: request strobe
            elif name == "in_op":
                color = "#8a5a00"      # amber: ENCODE(0)/DECODE(1)
            elif name == "out_valid":
                color = "#1f7a4d"      # green: result strobe
            elif name == "out_op":
                color = "#8a5a00"
            elif name == "out_sbe":
                color = "#1f7a4d"      # green: single-bit corrected
            else:                      # out_dbe
                color = "#b02418"      # red: double-bit detected
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
