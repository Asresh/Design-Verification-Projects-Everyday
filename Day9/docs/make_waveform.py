#!/usr/bin/env python3
"""
make_waveform.py - render docs/alu_waveform.png from a REAL simulator run.

Parses the VCD produced by Icarus Verilog (`tb_alu_dump.vcd`, from
`make icarus_dump`) and draws the DIRECTED showcase window of the registered
ALU, one operation per clock:

    ADD (carry-out) -> SUB (borrow) -> ADD (signed overflow) -> AND (zero) ->
    OR (neg) -> XOR (neg) -> SLL -> SRL -> SLT

Each request (opcode/a/b) is captured while in_valid is high; the DUT's
registered response (result + zero/carry/overflow/negative flags) appears one
clock later while out_valid is high. The trace is captured from a genuine
Icarus simulation - it is NOT hand-modeled.

Usage:
    make icarus_dump          # produces tb_alu_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_alu_dump.vcd]
"""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
VCD  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "tb_alu_dump.vcd")
OUT  = os.path.join(HERE, "alu_waveform.png")

# Display order (top -> bottom).
WANT = ["clk", "in_valid", "opcode", "a", "b",
        "out_valid", "result", "zero", "carry", "overflow", "negative"]
LEVEL  = {"clk", "in_valid", "out_valid", "zero", "carry", "overflow", "negative"}
HEXBUS = {"a", "b", "result"}
OPBUS  = {"opcode"}

OPNAME = {0: "ADD", 1: "SUB", 2: "AND", 3: "OR", 4: "XOR",
          5: "SLL", 6: "SRL", 7: "SLT"}

PS = 1000                              # ps per ns (Icarus dumps in ps)
T0, T1 = 30 * PS, 170 * PS             # reset release .. end of directed window


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
                    in_top = (depth == 1)          # tb_alu_dump = depth 1
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

    fig, axes = plt.subplots(len(WANT), 1, figsize=(13, 9.6), sharex=True)
    fig.suptitle(
        "alu - registered ALU: one op per clock (request while in_valid, "
        "registered response one clock later while out_valid)\n"
        "captured from Icarus Verilog (tb_alu_dump.vcd) - REAL simulation "
        "(clk 10 ns) - directed showcase: ADD/SUB/overflow/zero/logic/shift/SLT",
        fontsize=11.5, fontweight="bold")

    def draw_bus(ax, seq, gate_seq, opcode_bus=False):
        """Hex (or opcode-mnemonic) bus; grey out cycles where gate==0."""
        pts = sorted(set([T0] + [tt for (tt, _) in seq if T0 < tt < T1] +
                         [tt for (tt, _) in gate_seq if T0 < tt < T1] + [T1]))
        for i in range(len(pts) - 1):
            a_, b_ = pts[i], pts[i + 1]
            val = value_at(seq, a_)
            g = value_at(gate_seq, a_)
            valid = (g == "1")
            an, bn = a_ / PS, b_ / PS
            iv = to_int(val)
            if valid and iv is not None:
                label = OPNAME.get(iv, "%X" % iv) if opcode_bus else ("%02X" % iv)
                ax.fill_between([an, bn], 0.16, 0.84, color="#cfe3ff",
                                edgecolor="#1f4e8c", lw=1.0, zorder=2)
                ax.text((an + bn) / 2, 0.5, label, ha="center", va="center",
                        fontsize=8, fontfamily="monospace", zorder=3)
            else:
                ax.hlines(0.5, an, bn, color="0.75", lw=1.1, zorder=2,
                          linestyles="dotted")
        ax.set_ylim(0, 1)

    # Light gridlines at each clock posedge.
    posedges = [(5 + 10 * k) * PS for k in range(0, 30)]
    posedges = [p for p in posedges if T0 <= p <= T1]

    for ax, name in zip(axes, WANT):
        seq = series[sym_of[name]]
        ax.set_ylabel(name, rotation=0, ha="right", va="center",
                      fontsize=9.5, labelpad=30, fontfamily="monospace")
        ax.set_yticks([])
        for spine in ("top", "right", "left"):
            ax.spines[spine].set_visible(False)
        for p in posedges:
            ax.axvline(p / PS, color="0.92", lw=0.7, zorder=0)

        if name in OPBUS:
            draw_bus(ax, seq, series[sym_of["in_valid"]], opcode_bus=True)
        elif name in ("a", "b"):
            draw_bus(ax, seq, series[sym_of["in_valid"]])
        elif name == "result":
            draw_bus(ax, seq, series[sym_of["out_valid"]])
        else:
            xs, ys, last = [], [], value_at(seq, T0) or "0"
            for t in ts:
                v = value_at(seq, t) or last
                last = v
                xs.append(t / PS)
                ys.append(1 if v == "1" else 0)
            if name == "clk":
                color = "#1f4e8c"
            elif name in ("in_valid", "out_valid"):
                color = "#0b6b3a"
            else:                       # flags
                color = "#b23b3b"
            ax.step(xs, ys, where="post", color=color, lw=1.4)
            ax.fill_between(xs, ys, step="post", color=color, alpha=0.08)
            ax.set_ylim(-0.25, 1.35)

    axes[-1].set_xlabel("time (ns)", fontsize=10)
    axes[-1].set_xlim(T0 / PS, T1 / PS)

    # Annotate the operation flowing through each response cycle, derived from
    # the captured trace (not hardcoded) so callouts always match the render.
    ann = axes[0]
    ov_seq = series[sym_of["out_valid"]]
    op_seq = series[sym_of["opcode"]]
    iv_seq = series[sym_of["in_valid"]]
    for p in posedges:
        if value_at(iv_seq, p) == "1":
            iv = to_int(value_at(op_seq, p))
            if iv is not None and iv in OPNAME:
                ann.text(p / PS + 0.3, 1.55, OPNAME[iv], ha="center",
                         va="bottom", fontsize=7.0, color="#333",
                         fontfamily="monospace", rotation=0)

    fig.tight_layout(rect=[0, 0, 1, 0.93])
    fig.savefig(OUT, dpi=130)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
