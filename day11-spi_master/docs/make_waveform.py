#!/usr/bin/env python3
"""
make_waveform.py - render docs/spi_master_waveform.png from a REAL simulator run.

Parses the VCD produced by Icarus Verilog (`tb_spi_master_dump.vcd`, from
`make icarus_dump`) and draws the DIRECTED showcase transfer of the SPI master:
a single SPI mode-0 (CPOL=0, CPHA=0) byte exchange - master sends 0xA5 while the
independent slave sends 0x3C back - with a small clock divider so the exchange
is compact and readable.

The story the window tells:
    * CS_N asserts (goes low) and SCLK begins stepping at the mode-0 idle-low
      polarity,
    * MOSI presents the master's byte MSB-first (pre-driven at CS for CPHA=0),
    * MISO presents the slave's byte MSB-first in lock-step,
    * busy is high for the whole transfer,
    * done pulses for one clock as CS_N returns high, and rx_data latches the
      byte shifted in from MISO (0x3C).

The trace is captured from a genuine Icarus simulation - it is NOT hand-modeled.

Usage:
    make icarus_dump          # produces tb_spi_master_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_spi_master_dump.vcd]
"""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
VCD  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "tb_spi_master_dump.vcd")
OUT  = os.path.join(HERE, "spi_master_waveform.png")

# Display order (top -> bottom).
WANT = ["clk", "cs_n", "sclk", "mosi", "miso",
        "tx_data", "rx_data", "busy", "done"]
LEVEL  = {"clk", "cs_n", "sclk", "mosi", "miso", "busy", "done"}
HEXBUS = {"tx_data", "rx_data"}

PS = 1000                              # ps per ns (Icarus dumps in ps)


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
                    in_top = (depth == 1)          # tb_spi_master_dump = depth 1
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


def first_transfer_window(series, sym_of):
    """Return (T0, T1) bracketing the first CS_N-low transfer + margins."""
    cs = series[sym_of["cs_n"]]
    dn = series[sym_of["done"]]
    t_fall = next((t for (t, v) in cs if v == "0"), None)
    if t_fall is None:
        sys.exit("no CS_N assertion found in VCD")
    t_done = next((t for (t, v) in dn if v == "1" and t > t_fall), None)
    if t_done is None:
        t_done = t_fall + 400 * PS
    margin = 40 * PS
    return t_fall - margin, t_done + margin


def main():
    if not os.path.exists(VCD):
        sys.exit("VCD not found: %s  (run `make icarus_dump` first)" % VCD)
    sym_of, changes = parse_vcd(VCD)
    missing = [w for w in WANT if w not in sym_of]
    if missing:
        sys.exit("signals not found in VCD: %s" % missing)
    series = build_series(sym_of, changes)
    T0, T1 = first_transfer_window(series, sym_of)

    step = 250
    ts = list(range(T0, T1 + step, step))

    fig, axes = plt.subplots(len(WANT), 1, figsize=(13, 9.2), sharex=True)
    fig.suptitle(
        "spi_master - SPI mode 0 (CPOL=0, CPHA=0): master sends 0xA5, slave "
        "returns 0x3C (full-duplex)\n"
        "REAL Icarus Verilog capture (tb_spi_master_dump.vcd), clk 10 ns, "
        "clk_div=2 - MSB-first shifting; done pulses, rx_data=3C latched",
        fontsize=10.5, fontweight="bold")

    def draw_bus(ax, seq):
        pts = sorted(set([T0] + [tt for (tt, _) in seq if T0 < tt < T1] + [T1]))
        for i in range(len(pts) - 1):
            a_, b_ = pts[i], pts[i + 1]
            iv = to_int(value_at(seq, a_))
            an, bn = a_ / PS, b_ / PS
            if iv is not None:
                ax.fill_between([an, bn], 0.16, 0.84, color="#cfe3ff",
                                edgecolor="#1f4e8c", lw=1.0, zorder=2)
                ax.text((an + bn) / 2, 0.5, "%02X" % iv, ha="center",
                        va="center", fontsize=8.5, fontfamily="monospace", zorder=3)
        ax.set_ylim(0, 1)

    # Light gridlines at each system-clock posedge in the window.
    posedges = [(5 + 10 * k) * PS for k in range(0, 200)]
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

        if name in HEXBUS:
            draw_bus(ax, seq)
        else:
            xs, ys, last = [], [], value_at(seq, T0) or "0"
            for t in ts:
                v = value_at(seq, t) or last
                last = v
                xs.append(t / PS)
                ys.append(1 if v == "1" else 0)
            if name == "clk":
                color = "#1f4e8c"
            elif name == "sclk":
                color = "#5b2d91"           # violet: the generated serial clock
            elif name == "cs_n":
                color = "#b23b3b"           # red: chip-select framing
            elif name in ("mosi", "miso"):
                color = "#0b6b3a"           # green: serial data lines
            else:                           # busy / done status
                color = "#d98a00"           # amber
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
