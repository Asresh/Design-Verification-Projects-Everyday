#!/usr/bin/env python3
"""
make_waveform.py - render docs/arb_rr_waveform.png from a REAL simulator run.

This parses the VCD produced by Icarus Verilog (`tb_arb_rr_dump.vcd`, from
`make icarus_dump`) and draws the directed "showcase" window of the round-robin
arbiter: after reset release, all four requesters hold `req` high and the grant
rotates 0 -> 1 -> 2 -> 3 -> 0; a cycle with `en` low STALLS (no grant, the
priority pointer holds); then sparse request vectors show the circular skip; and
an idle cycle (no req) leaves the grant deasserted.

The waveform is therefore captured from a genuine simulation, not hand-modeled.

Usage:
    make icarus_dump          # produces tb_arb_rr_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_arb_rr_dump.vcd]
"""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
VCD  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "tb_arb_rr_dump.vcd")
OUT  = os.path.join(HERE, "arb_rr_waveform.png")

WANT = ["clk", "rst_n", "en", "req", "grant", "grant_valid", "grant_idx"]
BITS = {"clk", "rst_n", "en", "grant_valid"}          # single-bit level signals
BINBUS = {"req", "grant"}                             # show as binary bit vector
INTBUS = {"grant_idx"}                                # show as decimal


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
                    in_top = (depth == 1)          # tb_arb_rr_dump = depth 1
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

    PS = 1000                                   # ps per ns (Icarus dumps in ps)
    t0, t1 = 30 * PS, 140 * PS                  # reset release .. showcase end
    step = 500
    ts = list(range(t0, t1 + step, step))

    fig, axes = plt.subplots(len(WANT), 1, figsize=(13, 8.4), sharex=True)
    fig.suptitle("arb_rr - 4-requester round-robin arbiter: rotate 0,1,2,3, stall (en=0), "
                 "sparse skip, idle\n"
                 "captured from Icarus Verilog (tb_arb_rr_dump.vcd) - REAL simulation",
                 fontsize=12, fontweight="bold")

    posedges = [(5 + 10 * k) * PS for k in range(0, 20)]
    posedges = [p for p in posedges if t0 <= p <= t1]

    def draw_bus(ax, seq, as_bin, nbits=4):
        seg_start, prev = t0, value_at(seq, t0)

        def seg(a, b, valstr):
            if a >= b:
                return
            an, bn = a / PS, b / PS
            iv = to_int(valstr)
            if iv is not None and iv != 0:
                if as_bin:
                    label = format(iv, "0%db" % nbits)
                else:
                    label = "%d" % iv
                ax.fill_between([an, bn], 0.16, 0.84, color="#cfe3ff",
                                edgecolor="#1f4e8c", lw=1.0, zorder=2)
                ax.text((an + bn) / 2, 0.5, label, ha="center", va="center",
                        fontsize=8, fontfamily="monospace", zorder=3)
            else:
                ax.hlines(0.5, an, bn, color="0.55", lw=1.1, zorder=2)

        for (tt, v) in seq:
            if tt <= t0:
                prev = v
                continue
            if tt > t1:
                break
            seg(seg_start, tt, prev)
            seg_start, prev = tt, v
        seg(seg_start, t1, prev)
        ax.set_ylim(0, 1)

    for ax, name in zip(axes, WANT):
        seq = series[sym_of[name]]
        ax.set_ylabel(name, rotation=0, ha="right", va="center",
                      fontsize=9.5, labelpad=32, fontfamily="monospace")
        ax.set_yticks([])
        for spine in ("top", "right", "left"):
            ax.spines[spine].set_visible(False)
        for p in posedges:
            ax.axvline(p / PS, color="0.90", lw=0.7, zorder=0)

        if name in BINBUS:
            draw_bus(ax, seq, as_bin=True, nbits=4)
        elif name in INTBUS:
            draw_bus(ax, seq, as_bin=False)
        else:
            xs, ys, last = [], [], value_at(seq, t0) or "0"
            for t in ts:
                v = value_at(seq, t) or last
                last = v
                xs.append(t / PS)
                ys.append(1 if v == "1" else 0)
            color = "#1f4e8c" if name == "clk" else "#0b6b3a"
            ax.step(xs, ys, where="post", color=color, lw=1.4)
            ax.fill_between(xs, ys, step="post", color=color, alpha=0.08)
            ax.set_ylim(-0.25, 1.35)

    axes[-1].set_xlabel("time (ns)   -   clock period 10 ns, posedge at 5 + 10k ns",
                        fontsize=10)
    axes[-1].set_xlim(t0 / PS, t1 / PS)

    # Annotate the winner (or event) each grant cycle in the showcase window.
    ann = axes[0]
    labels = [(45, "gnt 0"), (55, "gnt 1"), (65, "gnt 2"),
              (75, "STALL\n(en=0)"), (85, "gnt 3"), (95, "gnt 0\n(wrap)"),
              (105, "gnt 1"), (115, "gnt 3\n(skip)"), (125, "IDLE\n(no req)"),
              (135, "gnt 0")]
    for x, txt in labels:
        ann.text(x, 1.62, txt, ha="center", va="bottom", fontsize=7.3,
                 color="#333", fontfamily="monospace")

    fig.tight_layout(rect=[0, 0, 1, 0.94])
    fig.savefig(OUT, dpi=130)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
