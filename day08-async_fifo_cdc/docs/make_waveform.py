#!/usr/bin/env python3
"""
make_waveform.py - render docs/async_fifo_waveform.png from a REAL simulator run.

This parses the VCD produced by Icarus Verilog (`tb_async_fifo_dump.vcd`, from
`make icarus_dump`) and draws the directed "showcase" window of the dual-clock
asynchronous FIFO:

  * FILL   : the write domain streams A0,B1,C2,D3 into a depth-4 FIFO; wr_full
             asserts once four words are resident (writes E4,F5 are refused).
  * CROSS  : rd_empty deasserts a couple of read clocks later - the write Gray
             pointer has propagated through the 2-flop synchronizer into the
             read domain.
  * HOLD   : both domains idle; the FIFO holds its four words across the CDC.
  * DRAIN  : the read domain streams reads; words fall through in FIFO order
             (A0,B1,C2,D3), wr_full clears as space frees, then rd_empty asserts.

The waveform is captured from a genuine Icarus simulation, not hand-modeled.
The two clocks use non-commensurate half-periods (5.0 ns / 6.5 ns) so their
posedges never coincide.

Usage:
    make icarus_dump          # produces tb_async_fifo_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_async_fifo_dump.vcd]
"""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
VCD  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "tb_async_fifo_dump.vcd")
OUT  = os.path.join(HERE, "async_fifo_waveform.png")

# Display order (top -> bottom): write domain, then read domain.
WANT = ["wr_clk", "wr_en", "wr_data", "wr_full",
        "rd_clk", "rd_en", "rd_data", "rd_empty"]
LEVEL = {"wr_clk", "rd_clk", "wr_en", "wr_full", "rd_en", "rd_empty"}
HEXBUS = {"wr_data", "rd_data"}

PS = 1000                              # ps per ns (Icarus dumps in ps)
T0, T1 = 30 * PS, 200 * PS             # reset release .. drained empty


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
                    in_top = (depth == 1)          # tb_async_fifo_dump = depth 1
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

    fig, axes = plt.subplots(len(WANT), 1, figsize=(13, 8.8), sharex=True)
    fig.suptitle(
        "async_fifo - dual-clock (CDC) FIFO: fill to full, Gray-pointer cross, "
        "hold, drain to empty\n"
        "captured from Icarus Verilog (tb_async_fifo_dump.vcd) - REAL simulation "
        "(wr_clk 10 ns, rd_clk 13 ns)",
        fontsize=12, fontweight="bold")

    def draw_bus(ax, seq, gate_seq, gate_is_low_active):
        """Draw a hex bus; grey out cycles where the gate makes it a don't-care.
        gate_is_low_active=False: valid when gate==1 (wr_data valid when wr_en).
        gate_is_low_active=True : valid when gate==0 (rd_data valid when !rd_empty)."""
        # Build change points within the window.
        pts = sorted(set([T0] + [tt for (tt, _) in seq if T0 < tt < T1] +
                         [tt for (tt, _) in gate_seq if T0 < tt < T1] + [T1]))
        for i in range(len(pts) - 1):
            a, b = pts[i], pts[i + 1]
            val = value_at(seq, a)
            g = value_at(gate_seq, a)
            valid = (g == "0") if gate_is_low_active else (g == "1")
            an, bn = a / PS, b / PS
            iv = to_int(val)
            if valid and iv is not None:
                ax.fill_between([an, bn], 0.16, 0.84, color="#cfe3ff",
                                edgecolor="#1f4e8c", lw=1.0, zorder=2)
                ax.text((an + bn) / 2, 0.5, "%02X" % iv, ha="center", va="center",
                        fontsize=8, fontfamily="monospace", zorder=3)
            else:
                ax.hlines(0.5, an, bn, color="0.75", lw=1.1, zorder=2,
                          linestyles="dotted")
        ax.set_ylim(0, 1)

    # Light gridlines at each write-clock posedge.
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

        if name == "wr_data":
            draw_bus(ax, seq, series[sym_of["wr_en"]], gate_is_low_active=False)
        elif name == "rd_data":
            draw_bus(ax, seq, series[sym_of["rd_empty"]], gate_is_low_active=True)
        else:
            xs, ys, last = [], [], value_at(seq, T0) or "0"
            for t in ts:
                v = value_at(seq, t) or last
                last = v
                xs.append(t / PS)
                ys.append(1 if v == "1" else 0)
            if name in ("wr_clk", "rd_clk"):
                color = "#1f4e8c"
            elif name in ("wr_full", "rd_empty"):
                color = "#b23b3b"
            else:
                color = "#0b6b3a"
            ax.step(xs, ys, where="post", color=color, lw=1.4)
            ax.fill_between(xs, ys, step="post", color=color, alpha=0.08)
            ax.set_ylim(-0.25, 1.35)

    axes[-1].set_xlabel("time (ns)", fontsize=10)
    axes[-1].set_xlim(T0 / PS, T1 / PS)

    # Phase annotations derived FROM THE CAPTURED VCD (not hardcoded), so the
    # callouts always match whatever trace is rendered.
    def first_time(name, target, tmin=T0):
        for (tt, v) in series[sym_of[name]]:
            if tt >= tmin and v == target:
                return tt
        return None

    t_full  = first_time("wr_full", "1")                       # FIFO fills
    t_cross = first_time("rd_empty", "0")                      # write ptr crossed
    t_drain = first_time("rd_en", "1", tmin=(t_cross or T0))   # reader starts
    t_empty = first_time("rd_empty", "1",
                         tmin=((t_drain or t_cross or T0) + 1000))  # drained

    ann = axes[0]
    def put(t, txt):
        if t is not None and T0 <= t <= T1:
            ann.text(t / PS, 1.55, txt, ha="center", va="bottom",
                     fontsize=7.4, color="#333", fontfamily="monospace")

    if t_full:
        put((T0 + t_full) // 2, "FILL")
        put(t_full, "wr_full\n@%dns" % int(t_full / PS))
    if t_cross and t_drain and t_drain > t_cross:
        put((t_cross + t_drain) // 2, "HOLD\n(CDC)")
    if t_drain and t_empty and t_empty > t_drain:
        put((t_drain + t_empty) // 2, "DRAIN")
    if t_empty:
        put(t_empty, "rd_empty\n@%dns" % int(t_empty / PS))

    fig.tight_layout(rect=[0, 0, 1, 0.93])
    fig.savefig(OUT, dpi=130)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
