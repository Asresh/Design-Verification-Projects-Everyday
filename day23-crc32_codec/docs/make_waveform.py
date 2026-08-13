#!/usr/bin/env python3
"""
make_waveform.py - render docs/crc32_stream_waveform.png from a REAL sim run.

Parses the VCD produced by Icarus Verilog (`tb_crc32_stream_dump.vcd`, from
`make icarus_dump`) and draws the DIRECTED SHOWCASE of the STREAMING CRC-32
(Ethernet FCS) GENERATOR: the canonical CRC-32 check vector "123456789" (bytes
0x31..0x39) streamed one byte per clock (zero-bubble, in_valid held high) in
GENERATE mode. in_sop marks the first byte (the running remainder is seeded to
0xFFFFFFFF), in_eop marks the last, and exactly LAT=2 cycles later out_valid
pulses with the Frame Check Sequence out_crc = 0xCBF43926 - the textbook CRC-32
of "123456789" - and out_ok = 1.

The window tells the FCS story end to end: a byte stream arrives at line rate,
each byte folds into the reflected LFSR remainder, and after the end-of-frame
byte the 32-bit FCS the transmitter would append emerges on out_crc.

The trace is captured from a genuine Icarus simulation - it is NOT hand-modeled.

Usage:
    make icarus_dump          # produces tb_crc32_stream_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_crc32_stream_dump.vcd]
"""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
VCD  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "tb_crc32_stream_dump.vcd")
OUT  = os.path.join(HERE, "crc32_stream_waveform.png")

# Display order (top -> bottom).
WANT = ["clk", "in_valid", "in_sop", "in_eop", "in_data",
        "out_valid", "out_crc", "out_ok"]
LEVEL   = {"clk", "in_valid", "in_sop", "in_eop", "out_valid", "out_ok"}
HEXBUS  = {"in_data", "out_crc"}                       # hex-formatted buses

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
                    in_top = (depth == 1)          # tb_crc32_stream_dump = depth 1
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
    """From just before the first in_sop pulse to a few cycles after the frame's
    FCS appears, so the whole zero-bubble showcase + its result are on screen."""
    sop = series[sym_of["in_sop"]]
    t_start = next((t for (t, v) in sop if v == "1"), None)
    if t_start is None:
        sys.exit("no in_sop pulse found in VCD")
    return t_start - 25 * PS, t_start + 155 * PS    # 9 bytes + LAT + margin


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

    fig, axes = plt.subplots(len(WANT), 1, figsize=(13, 8.0), sharex=True)
    fig.suptitle(
        "crc32_stream - STREAMING CRC-32 (Ethernet FCS) GENERATE showcase\n"
        "REAL Icarus Verilog capture (tb_crc32_stream_dump.vcd), clk 10 ns - "
        "\"123456789\" streamed zero-bubble, LAT=2: FCS out_crc = 0xCBF43926 (the textbook CRC-32)",
        fontsize=10.5, fontweight="bold")

    ivseq = series[sym_of["in_valid"]]
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
                        fontsize=7.4, fontfamily="monospace", zorder=3)
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
            is_out = name.startswith("out_")
            tint = "#cfeddc" if is_out else "#cfe3ff"
            nyb  = 8 if name == "out_crc" else 2
            draw_hex_bus(ax, seq, tint, nyb, ovseq if is_out else ivseq)
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
                color = "#5b2d91"      # violet: byte-present strobe
            elif name in ("in_sop", "in_eop"):
                color = "#8a5a00"      # amber: frame delimiters
            elif name == "out_valid":
                color = "#1f7a4d"      # green: result strobe
            else:                      # out_ok
                color = "#1f7a4d"
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
