#!/usr/bin/env python3
"""
make_waveform.py - render docs/smem_bank_arb_waveform.png from a REAL sim run.

Parses the VCD produced by Icarus Verilog (`tb_smem_bank_arb_dump.vcd`, from
`make icarus_dump`) and draws the DIRECTED SHOWCASE of the GPU shared-memory
bank-conflict serializer: an 8-lane warp whose word addresses are

    lane 0 -> 0x00 (bank 0)      lane 4 -> 0x01 (bank 1)
    lane 1 -> 0x08 (bank 0)      lane 5 -> 0x02 (bank 2)
    lane 2 -> 0x10 (bank 0)      lane 6 -> 0x03 (bank 3)
    lane 3 -> 0x00 (bank 0)      lane 7 -> 0x04 (bank 4)

Bank 0 holds THREE distinct addresses {0x00, 0x08, 0x10} -> a 3-way bank
conflict, so the request serializes into 3 phases:

    phase 0  ph_served = 1111_1001 (0xF9)  ph_bank_use = 0001_1111 (0x1F)
             lanes 0 & 3 BROADCAST addr 0x00 in bank 0, and banks 1..4 serve
             lanes 4..7 IN PARALLEL - only lanes 1,2 remain
    phase 1  ph_served = 0000_0010 (0x02)  ph_bank_use = 0000_0001 (0x01)
             bank 0 serves addr 0x08 (lane 1)
    phase 2  ph_served = 0000_0100 (0x04)  ph_bank_use = 0000_0001 (0x01)  LAST
             bank 0 serves addr 0x10 (lane 2) -> request drained

The story the window tells: one warp request fans out into a contiguous 3-beat
phase stream (ph_index 0->1->2, ph_last on the final beat) whose served masks
show broadcast + parallel banks first, then the two conflicting accesses drain
one per cycle.

The trace is captured from a genuine Icarus simulation - it is NOT hand-modeled.

Usage:
    make icarus_dump          # produces tb_smem_bank_arb_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_smem_bank_arb_dump.vcd]
"""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
VCD  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "tb_smem_bank_arb_dump.vcd")
OUT  = os.path.join(HERE, "smem_bank_arb_waveform.png")

# Display order (top -> bottom).
WANT = ["clk", "req_valid", "req_ready", "busy",
        "ph_valid", "ph_served", "ph_bank_use", "ph_index", "ph_last"]
LEVEL  = {"clk", "req_valid", "req_ready", "busy", "ph_valid", "ph_last"}
DECBUS = {"ph_index"}                             # phase number, decimal
BINBUS = {"ph_served": 8, "ph_bank_use": 8}       # fixed-width binary mask

PS = 1000                                         # ps per ns (Icarus dumps in ps)


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
                    in_top = (depth == 1)          # tb_smem_bank_arb_dump = depth 1
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


def dec_of(binstr):
    try:
        return "%d" % int(binstr, 2)
    except (ValueError, TypeError):
        return None


def showcase_window(series, sym_of):
    """Return (T0, T1) bracketing the FIRST warp request: from the first
    req_valid pulse to the ph_last that ends its phase stream."""
    rv = series[sym_of["req_valid"]]
    pl = series[sym_of["ph_last"]]
    t_start = next((t for (t, v) in rv if v == "1"), None)
    if t_start is None:
        sys.exit("no req_valid pulse found in VCD")
    t_last = next((t for (t, v) in pl if t > t_start and v == "1"), None)
    if t_last is None:
        t_last = t_start + 60 * PS
    return t_start - 20 * PS, t_last + 30 * PS


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
        "smem_bank_arb - shared-memory bank-conflict serializer showcase\n"
        "REAL Icarus Verilog capture (tb_smem_bank_arb_dump.vcd), clk 10 ns - "
        "bank-0 3-way conflict + broadcast: ph_served 0xF9 -> 0x02 -> 0x04 over 3 phases",
        fontsize=10.5, fontweight="bold")

    def draw_bus(ax, seq, kind, width=0):
        pts = sorted(set([T0] + [tt for (tt, _) in seq if T0 < tt < T1] + [T1]))
        for i in range(len(pts) - 1):
            a_, b_ = pts[i], pts[i + 1]
            raw = value_at(seq, a_)
            if kind == "dec":
                txt = dec_of(raw)
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

        if name in DECBUS:
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
            elif name in ("req_valid", "req_ready"):
                color = "#5b2d91"      # violet: request handshake
            elif name == "ph_valid":
                color = "#1f7a4d"      # green: phase-beat strobe
            elif name == "ph_last":
                color = "#c0392b"      # red: final phase of the request
            else:                      # busy
                color = "#d98a00"      # amber: request in flight
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
