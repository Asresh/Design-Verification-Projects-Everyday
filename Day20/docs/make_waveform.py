#!/usr/bin/env python3
"""
make_waveform.py - render docs/risk_gate_waveform.png from a REAL sim run.

Parses the VCD produced by Icarus Verilog (`tb_risk_gate_dump.vcd`, from
`make icarus_dump`) and draws the DIRECTED SHOWCASE of the pre-trade RISK-CHECK
GATE: eight back-to-back orders (zero-bubble) streamed one per cycle, each
validated against the programmed limits (max_qty=1000, price band [100,200],
max_notional=100000, pos_limit=500), with the verdict emerging LAT=3 cycles
later. The eight orders walk through every verdict in strict priority and
exercise the running net position:

    1 BUY  150 x100  -> ACCEPT   (reason 0)   pos +100
    2 BUY  150 x300  -> ACCEPT   (reason 0)   pos +400
    3 BUY  150 x300  -> POS_LIMIT(reason 5)   pos +400  (would be +700 > 500)
    4 BUY  150 x2000 -> QTY_MAX  (reason 2)   pos +400
    5 SELL  50 x100  -> PRICE_BAND(reason 3)  pos +400  (50 < 100)
    6 BUY  200 x800  -> NOTIONAL (reason 4)   pos +400  (160000 > 100000)
    7 BUY  100 x0    -> QTY_ZERO (reason 1)   pos +400
    8 SELL 150 x300  -> ACCEPT   (reason 0)   pos +100  (sell reduces position)

The story the window tells: an order stream arrives at line rate (one per clock,
in_valid held high, zero bubbles); each order flows through the fixed-latency
check datapath and exactly LAT cycles later out_valid pulses with out_accept and
a compact reason code, while out_pos tracks the running net position that only
advances on an accepted order.

The trace is captured from a genuine Icarus simulation - it is NOT hand-modeled.

Usage:
    make icarus_dump          # produces tb_risk_gate_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_risk_gate_dump.vcd]
"""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
VCD  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "tb_risk_gate_dump.vcd")
OUT  = os.path.join(HERE, "risk_gate_waveform.png")

# Display order (top -> bottom).
WANT = ["clk", "in_valid", "in_side", "in_price", "in_qty",
        "out_valid", "out_accept", "out_reason", "out_pos"]
LEVEL   = {"clk", "in_valid", "out_valid", "out_accept"}     # 1-bit step signals
SIDEBUS = {"in_side"}                                        # 0=BUY / 1=SELL text
DECBUS  = {"in_price", "in_qty", "out_reason"}               # unsigned decimals
SDECBUS = {"out_pos"}                                        # SIGNED decimal

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
                    in_top = (depth == 1)          # tb_risk_gate_dump = depth 1
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


def as_sdec(binstr, w):
    try:
        v = int(binstr, 2)
        if len(binstr) < w:                       # VCD zero-extends; pad implied
            pass
        # two's complement using the declared width
        if v >= (1 << (w - 1)):
            v -= (1 << w)
        return str(v)
    except (ValueError, TypeError):
        return None


def side_txt(binstr):
    try:
        return "SELL" if int(binstr, 2) else "BUY"
    except (ValueError, TypeError):
        return None


def showcase_window(series, sym_of):
    """From the first in_valid pulse to a few cycles after the 8th order's
    verdict, so the whole zero-bubble showcase + its results are on screen."""
    iv = series[sym_of["in_valid"]]
    t_start = next((t for (t, v) in iv if v == "1"), None)
    if t_start is None:
        sys.exit("no in_valid pulse found in VCD")
    # 8 orders + LAT(3) + a little margin, clk = 10 ns
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

    fig, axes = plt.subplots(len(WANT), 1, figsize=(13, 8.4), sharex=True)
    fig.suptitle(
        "risk_gate - pre-trade RISK-CHECK GATE (fat-finger order validation) showcase\n"
        "REAL Icarus Verilog capture (tb_risk_gate_dump.vcd), clk 10 ns - 8 zero-bubble "
        "orders, LAT=3: accept / pos-limit / qty-max / price-band / notional / qty-zero",
        fontsize=10.5, fontweight="bold")

    def draw_text_bus(ax, seq, tint, fmt):
        pts = sorted(set([T0] + [tt for (tt, _) in seq if T0 < tt < T1] + [T1]))
        for i in range(len(pts) - 1):
            a_, b_ = pts[i], pts[i + 1]
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

        if name in SIDEBUS:
            draw_text_bus(ax, seq, "#eee0c0", side_txt)
        elif name in DECBUS:
            tint = "#cfeddc" if name.startswith("out_") else "#cfe3ff"
            draw_text_bus(ax, seq, tint, as_udec)
        elif name in SDECBUS:
            draw_text_bus(ax, seq, "#e6d6f2", lambda b, w=w: as_sdec(b, w))
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
                color = "#5b2d91"      # violet: order-present strobe
            elif name == "out_valid":
                color = "#1f7a4d"      # green: verdict strobe
            else:                      # out_accept
                color = "#c02d2d"      # red-ish: accept flag
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
