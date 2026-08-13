#!/usr/bin/env python3
"""
make_waveform.py - render docs/seq_gap_detector_waveform.png from a REAL sim run.

Parses the VCD produced by Icarus Verilog (`tb_seq_gap_detector_dump.vcd`, from
`make icarus_dump`) and draws the DIRECTED SHOWCASE of the MARKET-DATA SEQUENCE
GAP DETECTOR & DUPLICATE SUPPRESSOR: eight back-to-back messages (zero-bubble)
streamed one per cycle against the programmed session (init_seq=100), with the
decision emerging LAT=3 cycles later. The eight messages walk through every
action and both duplicate flavours:

    1 seq 100 -> PASS   exp 101
    2 seq 101 -> PASS   exp 102
    3 seq 101 -> DUP    exp 102  (B-line duplicate copy)
    4 seq 102 -> PASS   exp 103
    5 seq 105 -> GAP=2  exp 106  (103,104 missing -> forward 105, resync)
    6 seq 106 -> PASS   exp 107
    7 seq 104 -> DUP    exp 107  (stale late retransmit, 104 < 107)
    8 seq 107 -> PASS   exp 108

The story the window tells: a numbered message stream arrives at line rate (one
per clock, in_valid held high, zero bubbles); each message flows through the
fixed-latency compare/dedup/gap datapath and exactly LAT cycles later out_valid
pulses with the action code and out_fwd, while out_gap reports the count of
missing sequence numbers on a gap and out_expected tracks the running
next-expected sequence that only advances on a forwarded message.

The trace is captured from a genuine Icarus simulation - it is NOT hand-modeled.

Usage:
    make icarus_dump          # produces tb_seq_gap_detector_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_seq_gap_detector_dump.vcd]
"""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
VCD  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "tb_seq_gap_detector_dump.vcd")
OUT  = os.path.join(HERE, "seq_gap_detector_waveform.png")

# Display order (top -> bottom).
WANT = ["clk", "in_valid", "in_seq", "out_valid", "out_fwd",
        "out_action", "out_gap", "out_expected"]
LEVEL   = {"clk", "in_valid", "out_valid", "out_fwd"}        # 1-bit step signals
ACTBUS  = {"out_action"}                                     # PASS/DUP/GAP text
DECBUS  = {"in_seq", "out_gap", "out_expected"}              # unsigned decimals

PS = 1000                                         # ps per ns (Icarus dumps in ps)


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
                    in_top = (depth == 1)          # tb_seq_gap_detector_dump = depth 1
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


def as_udec(binstr):
    try:
        return str(int(binstr, 2))
    except (ValueError, TypeError):
        return None


def action_txt(binstr):
    try:
        v = int(binstr, 2)
        return {0: "PASS", 1: "DUP", 2: "GAP"}.get(v, "?")
    except (ValueError, TypeError):
        return None


def showcase_window(series, sym_of):
    """From the first in_valid pulse to a few cycles after the 8th message's
    decision, so the whole zero-bubble showcase + its results are on screen."""
    iv = series[sym_of["in_valid"]]
    t_start = next((t for (t, v) in iv if v == "1"), None)
    if t_start is None:
        sys.exit("no in_valid pulse found in VCD")
    # 8 messages + LAT(3) + a little margin, clk = 10 ns
    return t_start - 25 * PS, t_start + 145 * PS


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
        "seq_gap_detector - MARKET-DATA sequence gap detector & duplicate suppressor showcase\n"
        "REAL Icarus Verilog capture (tb_seq_gap_detector_dump.vcd), clk 10 ns - 8 zero-bubble "
        "messages, LAT=3: PASS / duplicate / gap(=2) / stale, init_seq=100",
        fontsize=10.5, fontweight="bold")

    ovseq = series[sym_of["out_valid"]]

    def draw_text_bus(ax, seq, tint, fmt, gate=False):
        # gate=True -> only draw where out_valid is high (output buses are only
        # meaningful when a decision is present; idle values are don't-care).
        pts = sorted(set([T0] + [tt for (tt, _) in seq if T0 < tt < T1] +
                         ([tt for (tt, _) in ovseq if T0 < tt < T1] if gate else []) +
                         [T1]))
        for i in range(len(pts) - 1):
            a_, b_ = pts[i], pts[i + 1]
            if gate and value_at(ovseq, (a_ + b_) // 2) != "1":
                continue
            raw = value_at(seq, a_)
            txt = fmt(raw)
            an, bn = a_ / PS, b_ / PS
            if txt is not None:
                ax.fill_between([an, bn], 0.16, 0.84, color=tint,
                                edgecolor="#1f4e8c", lw=1.0, zorder=2)
                ax.text((an + bn) / 2, 0.5, txt, ha="center",
                        va="center", fontsize=7.2, fontfamily="monospace", zorder=3)
        ax.set_ylim(0, 1)

    posedges = [(5 + 10 * k) * PS for k in range(0, 400)]
    posedges = [p for p in posedges if T0 <= p <= T1]

    for ax, name in zip(axes, WANT):
        seq = series[sym_of[name]]
        w   = width.get(name, 1)
        ax.set_ylabel(name, rotation=0, ha="right", va="center",
                      fontsize=8.6, labelpad=30, fontfamily="monospace")
        ax.set_yticks([])
        for spine in ("top", "right", "left"):
            ax.spines[spine].set_visible(False)
        for p in posedges:
            ax.axvline(p / PS, color="0.93", lw=0.6, zorder=0)

        if name in ACTBUS:
            draw_text_bus(ax, seq, "#f2d9c0", action_txt, gate=True)
        elif name in DECBUS:
            is_out = name.startswith("out_")
            tint = "#cfeddc" if is_out else "#cfe3ff"
            draw_text_bus(ax, seq, tint, as_udec, gate=is_out)
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
                color = "#5b2d91"      # violet: message-present strobe
            elif name == "out_valid":
                color = "#1f7a4d"      # green: decision strobe
            else:                      # out_fwd
                color = "#c02d2d"      # red-ish: forward flag
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
