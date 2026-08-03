#!/usr/bin/env python3
"""
make_waveform.py - render docs/i2c_master_waveform.png from a REAL sim run.

Parses the VCD produced by Icarus Verilog (`tb_i2c_master_dump.vcd`, from
`make icarus_dump`) and draws the DIRECTED SHOWCASE of the I2C master: the very
first transaction, a single-byte WRITE of 0x3C to slave address 0x42.

On the open-drain bus you can read the full I2C framing off the scl/sda pins:

    START (SDA falls while SCL high)
      -> address byte {0x42, W} = 0x84, MSB-first, 8 SCL pulses
      -> slave ACK  (SDA pulled low in the 9th pulse)
      -> data byte 0x3C, 8 SCL pulses
      -> slave ACK  (9th pulse)
    STOP  (SDA rises while SCL high)

busy is high for the whole transfer and done pulses for one cycle at the end
with ack_error = 0 (the address was ACKed).

The trace is captured from a genuine Icarus simulation - it is NOT hand-modeled.

Usage:
    make icarus_dump          # produces tb_i2c_master_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_i2c_master_dump.vcd]
"""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
VCD  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "tb_i2c_master_dump.vcd")
OUT  = os.path.join(HERE, "i2c_master_waveform.png")

# Display order (top -> bottom).
WANT  = ["scl", "sda", "start", "busy", "done", "ack_error", "dev_addr", "wr_data"]
LEVEL = {"scl", "sda", "start", "busy", "done", "ack_error"}
HBUS  = {"dev_addr", "wr_data"}          # unsigned-hex buses, gated by busy
GATE  = "busy"

PS = 1000                                # ps per ns


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
                    in_top = (depth == 1)     # tb_i2c_master_dump = depth 1
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
    # open-drain: released (z) reads as pulled-up high; x drawn low.
    if v in ("1", "z"):
        return 1
    return 0


def as_hex(binstr, w):
    try:
        return "0x%02X" % int(binstr, 2)
    except (ValueError, TypeError):
        return None


def window(series, sym_of):
    """From just before the first start pulse to a few hundred ns past the
    first done, so the whole first WRITE transaction is on screen."""
    st = series[sym_of["start"]]
    t0 = next((t for (t, v) in st if v == "1"), None)
    if t0 is None:
        sys.exit("no start pulse found in VCD")
    dn = series[sym_of["done"]]
    t1 = next((t for (t, v) in dn if v == "1" and t > t0), None)
    if t1 is None:
        sys.exit("no done pulse found in VCD")
    return t0 - 150 * PS, t1 + 250 * PS


def main():
    if not os.path.exists(VCD):
        sys.exit("VCD not found: %s  (run `make icarus_dump` first)" % VCD)
    sym_of, width, changes = parse_vcd(VCD)
    missing = [w for w in WANT if w not in sym_of]
    if missing:
        sys.exit("signals not found in VCD: %s" % missing)
    series = build_series(sym_of, changes)
    T0, T1 = window(series, sym_of)

    step = 250
    ts = list(range(T0, T1 + step, step))

    fig, axes = plt.subplots(len(WANT), 1, figsize=(13, 6.8), sharex=True)
    fig.suptitle(
        "i2c_master - single-byte WRITE 0x3C to slave 0x42 (open-drain bus)\n"
        "REAL Icarus Verilog capture (tb_i2c_master_dump.vcd), core clk 10 ns, "
        "SCL period 160 ns - START / addr 0x84 / ACK / data 0x3C / ACK / STOP",
        fontsize=10.5, fontweight="bold")

    def draw_hex_bus(ax, seq, tint, w, gate_seq):
        pts = sorted(set([T0] + [tt for (tt, _) in seq if T0 < tt < T1] +
                         [tt for (tt, _) in gate_seq if T0 < tt < T1] + [T1]))
        for i in range(len(pts) - 1):
            a_, b_ = pts[i], pts[i + 1]
            if value_at(gate_seq, (a_ + b_) // 2) != "1":
                continue
            txt = as_hex(value_at(seq, a_), w)
            an, bn = a_ / PS, b_ / PS
            if txt is not None:
                ax.fill_between([an, bn], 0.16, 0.84, color=tint,
                                edgecolor="#1f4e8c", lw=1.0, zorder=2)
                ax.text((an + bn) / 2, 0.5, txt, ha="center", va="center",
                        fontsize=8.0, fontfamily="monospace", zorder=3)
        ax.set_ylim(0, 1)

    # light guide-lines at every SCL rising edge would be dense; use a coarse
    # 160 ns grid (one I2C bit) instead.
    grid = [g * PS for g in range(0, 100000, 160) if T0 <= g * PS <= T1]

    color = {"scl": "#1f4e8c", "sda": "#b5651d", "start": "#5b2d91",
             "busy": "#1f7a4d", "done": "#1f7a4d", "ack_error": "#a11d33"}
    tint  = {"dev_addr": "#dfe8f5", "wr_data": "#dff0e6"}

    for ax, name in zip(axes, WANT):
        seq = series[sym_of[name]]
        ax.set_ylabel(name, rotation=0, ha="right", va="center",
                      fontsize=8.6, labelpad=32, fontfamily="monospace")
        ax.set_yticks([])
        for spine in ("top", "right", "left"):
            ax.spines[spine].set_visible(False)
        for g in grid:
            ax.axvline(g / PS, color="0.93", lw=0.6, zorder=0)

        if name in HBUS:
            draw_hex_bus(ax, seq, tint[name], width[name],
                         series[sym_of[GATE]])
        else:
            xs, ys, last = [], [], as_level(value_at(seq, T0) or "z")
            for t in ts:
                v = value_at(seq, t)
                lv = as_level(v) if v is not None else last
                last = lv
                xs.append(t / PS)
                ys.append(lv)
            ax.step(xs, ys, where="post", color=color[name], lw=1.5)
            ax.fill_between(xs, ys, step="post", color=color[name], alpha=0.08)
            ax.set_ylim(-0.25, 1.35)

    axes[-1].set_xlabel("time (ns)", fontsize=10)
    axes[-1].set_xlim(T0 / PS, T1 / PS)

    fig.tight_layout(rect=[0, 0, 1, 0.92])
    fig.savefig(OUT, dpi=130)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
