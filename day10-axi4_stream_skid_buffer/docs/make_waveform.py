#!/usr/bin/env python3
"""
make_waveform.py - render docs/axis_skid_waveform.png from a REAL simulator run.

Parses the VCD produced by Icarus Verilog (`tb_axis_skid_dump.vcd`, from
`make icarus_dump`) and draws the DIRECTED showcase window of the AXI4-Stream
skid buffer: a 6-byte packet (A0 A1 A2 A3 A4 A5, with A2 a null byte tkeep=0)
driven back-to-back on the slave side while the master (sink) side stalls
mid-packet.

The story the window tells:
    * beats stream through (s_tvalid&&s_tready -> one cycle later m_tvalid),
    * the sink de-asserts m_tready -> the registered output slot HOLDS,
    * the next accepted beat is parked in the SKID register (skid_valid=1),
    * s_tready therefore drops, pushing back-pressure UPSTREAM,
    * the sink re-asserts m_tready -> output + skid drain, s_tready recovers,
    * tlast marks the end of the packet.

The trace is captured from a genuine Icarus simulation - it is NOT hand-modeled.

Usage:
    make icarus_dump          # produces tb_axis_skid_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_axis_skid_dump.vcd]
"""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
VCD  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "tb_axis_skid_dump.vcd")
OUT  = os.path.join(HERE, "axis_skid_waveform.png")

# Display order (top -> bottom).
WANT = ["clk",
        "s_tvalid", "s_tready", "s_tdata", "s_tkeep", "s_tlast",
        "skid_valid_dbg",
        "m_tvalid", "m_tready", "m_tdata", "m_tkeep", "m_tlast"]
PRETTY = {"skid_valid_dbg": "skid_valid"}
LEVEL  = {"clk", "s_tvalid", "s_tready", "s_tkeep", "s_tlast",
          "skid_valid_dbg", "m_tvalid", "m_tready", "m_tkeep", "m_tlast"}
HEXBUS = {"s_tdata", "m_tdata"}
GATE   = {"s_tdata": "s_tvalid", "m_tdata": "m_tvalid"}

PS = 1000                              # ps per ns (Icarus dumps in ps)
T0, T1 = 20 * PS, 180 * PS             # directed showcase window (~16 cycles)


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
                    in_top = (depth == 1)          # tb_axis_skid_dump = depth 1
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


def to_int(binstr):
    try:
        return int(binstr, 2)
    except (ValueError, TypeError):
        return None


def main():
    if not os.path.exists(VCD):
        sys.exit("VCD not found: %s  (run `make icarus_dump` first)" % VCD)
    sym_of, changes = parse_vcd(VCD)
    missing = [w for w in WANT if w not in sym_of]
    if missing:
        sys.exit("signals not found in VCD: %s" % missing)
    series = build_series(sym_of, changes)

    step = 250
    ts = list(range(T0, T1 + step, step))

    fig, axes = plt.subplots(len(WANT), 1, figsize=(13, 10.4), sharex=True)
    fig.suptitle(
        "axis_skid - AXI4-Stream skid buffer: 6-byte packet (A0..A5, A2 = null "
        "byte tkeep=0) streamed back-to-back while the sink stalls mid-packet\n"
        "captured from Icarus Verilog (tb_axis_skid_dump.vcd) - REAL simulation "
        "(clk 10 ns) - watch skid_valid fill and s_tready drop when m_tready "
        "de-asserts (back-pressure propagating upstream)",
        fontsize=11.0, fontweight="bold")

    def draw_bus(ax, seq, gate_seq):
        """Hex bus; grey dotted in cycles where the gating valid is low."""
        pts = sorted(set([T0] + [tt for (tt, _) in seq if T0 < tt < T1] +
                         [tt for (tt, _) in gate_seq if T0 < tt < T1] + [T1]))
        for i in range(len(pts) - 1):
            a_, b_ = pts[i], pts[i + 1]
            val = value_at(seq, a_)
            g   = value_at(gate_seq, a_)
            an, bn = a_ / PS, b_ / PS
            iv = to_int(val)
            if g == "1" and iv is not None:
                ax.fill_between([an, bn], 0.16, 0.84, color="#cfe3ff",
                                edgecolor="#1f4e8c", lw=1.0, zorder=2)
                ax.text((an + bn) / 2, 0.5, "%02X" % iv, ha="center",
                        va="center", fontsize=8, fontfamily="monospace", zorder=3)
            else:
                ax.hlines(0.5, an, bn, color="0.75", lw=1.1, zorder=2,
                          linestyles="dotted")
        ax.set_ylim(0, 1)

    # Light gridlines at each clock posedge.
    posedges = [(5 + 10 * k) * PS for k in range(0, 30)]
    posedges = [p for p in posedges if T0 <= p <= T1]

    for ax, name in zip(axes, WANT):
        seq = series[sym_of[name]]
        ax.set_ylabel(PRETTY.get(name, name), rotation=0, ha="right",
                      va="center", fontsize=9.5, labelpad=34,
                      fontfamily="monospace")
        ax.set_yticks([])
        for spine in ("top", "right", "left"):
            ax.spines[spine].set_visible(False)
        for p in posedges:
            ax.axvline(p / PS, color="0.92", lw=0.7, zorder=0)

        if name in HEXBUS:
            draw_bus(ax, seq, series[sym_of[GATE[name]]])
        else:
            xs, ys, last = [], [], value_at(seq, T0) or "0"
            for t in ts:
                v = value_at(seq, t) or last
                last = v
                xs.append(t / PS)
                ys.append(1 if v == "1" else 0)
            if name == "clk":
                color = "#1f4e8c"
            elif name in ("s_tvalid", "s_tready", "m_tvalid", "m_tready"):
                color = "#0b6b3a"
            elif name == "skid_valid_dbg":
                color = "#d98a00"           # amber: the internal skid state
            else:                           # tkeep / tlast framing
                color = "#b23b3b"
            ax.step(xs, ys, where="post", color=color, lw=1.4)
            ax.fill_between(xs, ys, step="post", color=color, alpha=0.08)
            ax.set_ylim(-0.25, 1.35)

    axes[-1].set_xlabel("time (ns)", fontsize=10)
    axes[-1].set_xlim(T0 / PS, T1 / PS)

    fig.tight_layout(rect=[0, 0, 1, 0.93])
    fig.savefig(OUT, dpi=130)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
