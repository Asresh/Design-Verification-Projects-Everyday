#!/usr/bin/env python3
"""
Day32 - render the committed waveform from a REAL Icarus Verilog VCD.

This is not a hand-drawn timing diagram: it parses the VCD that
tb_mesi_cache_dump.sv actually wrote during the self-checking run and plots
the captured values.  The window it selects is the five-access MESI showcase
at the top of the run - the whole protocol, in order:

    1. core0 reads a line nobody else has          ->  I -> E
    2. core0 stores to it, with NO bus transaction ->  E -> M   (silent)
    3. core1 reads it: the owner flushes           ->  M -> S / I -> S
    4. core1 stores: BusUpgr invalidates core0     ->  S -> I / S -> M
    5. core0 stores: BusRdX pulls it back          ->  M -> I / I -> M

Usage:  python3 docs/make_waveform.py tb_mesi_cache_dump.vcd
"""

import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

# ---------------------------------------------------------------------------
# minimal VCD reader
# ---------------------------------------------------------------------------


def parse_vcd(path, wanted):
    """Return {signal_name: [(time, value_string), ...]} for the wanted names."""
    code_of = {}
    series = {}
    timescale_ps = 1000  # default 1ns

    with open(path) as fh:
        # ---- header ----
        scope = []
        for line in fh:
            s = line.strip()
            if s.startswith("$timescale"):
                body = s.replace("$timescale", "").replace("$end", "").strip()
                if not body:
                    body = next(fh).strip()
                num = "".join(c for c in body if c.isdigit()) or "1"
                unit = "".join(c for c in body if c.isalpha())
                mult = {"s": 10**12, "ms": 10**9, "us": 10**6, "ns": 10**3, "ps": 1}
                timescale_ps = int(num) * mult.get(unit, 1000)
            elif s.startswith("$scope"):
                scope.append(s.split()[2])
            elif s.startswith("$upscope"):
                if scope:
                    scope.pop()
            elif s.startswith("$var"):
                parts = s.split()
                code, name = parts[3], parts[4]
                if len(scope) == 1 and name in wanted:
                    code_of[code] = name
                    series[name] = []
            elif s.startswith("$enddefinitions"):
                break

        # ---- value changes ----
        t = 0
        for line in fh:
            s = line.strip()
            if not s:
                continue
            if s[0] == "#":
                t = int(s[1:])
            elif s[0] in "01xzXZ":
                code = s[1:]
                if code in code_of:
                    series[code_of[code]].append((t, s[0]))
            elif s[0] in "bB":
                val, _, code = s[1:].partition(" ")
                if code in code_of:
                    series[code_of[code]].append((t, val))

    return series, timescale_ps


def value_at(changes, t):
    """Last value at or before t."""
    v = None
    for ct, cv in changes:
        if ct <= t:
            v = cv
        else:
            break
    return v


def as_int(v):
    if v is None:
        return None
    v = v.lower()
    if "x" in v or "z" in v:
        return None
    try:
        return int(v, 2)
    except ValueError:
        return None


# ---------------------------------------------------------------------------
# drawing helpers
# ---------------------------------------------------------------------------

BG      = "#ffffff"
FG      = "#1a1a2e"
GRID    = "#d8dce6"
HI      = "#0b6fb8"     # digital high
BUSFILL = "#e8eef7"
BUSEDGE = "#5b7fa6"
ACCENT  = "#c2410c"
GREEN   = "#0f7b52"
MUTED   = "#7a8598"

ST_NAME  = {0: "I", 1: "S", 2: "E", 3: "M"}
ST_COLOR = {"I": "#e7e9ee", "S": "#cfe3f7", "E": "#fde8c8", "M": "#f9cfcf"}
ST_EDGE  = {"I": "#9aa3b2", "S": "#4b8fd0", "E": "#d08a1e", "M": "#c0392b"}
CMD_NAME = {0: "BusRd", 1: "BusRdX", 2: "BusUpgr", 3: "BusWB"}


def draw_binary(ax, y, cycles, vals, h=0.62, color=HI):
    for i, c in enumerate(cycles):
        v = vals.get(c)
        if v is None:
            continue
        if v:
            ax.add_patch(Rectangle((i + 0.08, y), 0.84, h,
                                   facecolor=color, edgecolor="none",
                                   alpha=0.92, zorder=2))
        ax.plot([i, i + 1], [y, y], color=GRID, lw=0.7, zorder=1)


def draw_bus(ax, y, cycles, labels, h=0.62,
             fc=BUSFILL, ec=BUSEDGE, tc=FG, fs=7.0):
    for i, c in enumerate(cycles):
        lab = labels.get(c)
        if lab in (None, ""):
            ax.plot([i, i + 1], [y + h / 2, y + h / 2], color=GRID, lw=0.9, zorder=1)
            continue
        ax.add_patch(Rectangle((i + 0.06, y), 0.88, h,
                               facecolor=fc, edgecolor=ec, lw=0.8, zorder=2))
        ax.text(i + 0.5, y + h / 2, lab, ha="center", va="center",
                fontsize=fs, color=tc, family="monospace", zorder=3)


def draw_state(ax, y, cycles, states, h=0.62):
    for i, c in enumerate(cycles):
        st = states.get(c)
        if st is None:
            continue
        ax.add_patch(Rectangle((i + 0.03, y), 0.94, h,
                               facecolor=ST_COLOR[st], edgecolor=ST_EDGE[st],
                               lw=1.1, zorder=2))
        ax.text(i + 0.5, y + h / 2, st, ha="center", va="center",
                fontsize=9.5, fontweight="bold",
                color=ST_EDGE[st], family="monospace", zorder=3)


# ---------------------------------------------------------------------------


def main():
    vcd = Path(sys.argv[1] if len(sys.argv) > 1 else "tb_mesi_cache_dump.vcd")
    if not vcd.exists():
        sys.exit(f"{vcd} not found - run 'make icarus_dump' first")

    wanted = {
        "clk", "rst_n",
        "c0_req", "c0_we", "c0_addr", "c0_ack", "c0_hit",
        "c1_req", "c1_we", "c1_addr", "c1_ack", "c1_hit",
        "bus_valid", "bus_cmd", "bus_addr", "bus_master",
        "bus_fill", "bus_fill_shared", "bus_c2c",
        "mem_req", "mem_we",
        "c0_set0_state", "c1_set0_state",
    }
    sig, ts_ps = parse_vcd(vcd, wanted)
    missing = wanted - set(sig)
    if missing:
        sys.exit(f"VCD is missing signals: {sorted(missing)}")

    # ---- rebuild the cycle grid from the clock ----
    posedges = [t for t, v in sig["clk"] if v == "1"]
    if len(posedges) < 20:
        sys.exit("not enough clock edges in the VCD")
    period = posedges[1] - posedges[0]

    # sample just before each rising edge: that is what the DUT sees
    def sample_t(edge):
        return edge - period // 4

    # ---- find the showcase window: the first BusRd after reset ----
    start_i = 0
    for i, e in enumerate(posedges):
        if value_at(sig["rst_n"], sample_t(e)) == "1" and \
           value_at(sig["bus_valid"], sample_t(e)) == "1":
            start_i = max(0, i - 3)
            break

    NCYC = 42
    edges = posedges[start_i:start_i + NCYC]
    cycles = list(range(len(edges)))

    def collect(name, conv):
        return {i: conv(value_at(sig[name], sample_t(e))) for i, e in enumerate(edges)}

    bit = lambda v: (v == "1")
    num = lambda v: as_int(v)

    c0_req = collect("c0_req", bit)
    c0_we = collect("c0_we", bit)
    c0_ack = collect("c0_ack", bit)
    c0_hit = collect("c0_hit", bit)
    c0_addr = collect("c0_addr", num)
    c1_req = collect("c1_req", bit)
    c1_we = collect("c1_we", bit)
    c1_ack = collect("c1_ack", bit)
    c1_hit = collect("c1_hit", bit)
    c1_addr = collect("c1_addr", num)
    bvalid = collect("bus_valid", bit)
    bcmd = collect("bus_cmd", num)
    baddr = collect("bus_addr", num)
    bmaster = collect("bus_master", num)
    bfill = collect("bus_fill", bit)
    bshared = collect("bus_fill_shared", bit)
    bc2c = collect("bus_c2c", bit)
    memreq = collect("mem_req", bit)
    memwe = collect("mem_we", bit)
    s0 = collect("c0_set0_state", num)
    s1 = collect("c1_set0_state", num)

    # ---- derived label rows ----
    c0_op, c1_op = {}, {}
    for i in cycles:
        c0_op[i] = (("WR " if c0_we[i] else "RD ") + str(c0_addr[i])) if c0_req[i] else ""
        c1_op[i] = (("WR " if c1_we[i] else "RD ") + str(c1_addr[i])) if c1_req[i] else ""

    cmd_row, fill_row, mem_row = {}, {}, {}
    for i in cycles:
        cmd_row[i] = (f"{CMD_NAME.get(bcmd[i], '?')} @{baddr[i]} (c{bmaster[i]})"
                      if bvalid[i] else "")
        if bfill[i]:
            tags = []
            if bshared[i]:
                tags.append("shared")
            else:
                tags.append("EXCL")
            if bc2c[i]:
                tags.append("c2c")
            fill_row[i] = "fill " + "/".join(tags)
        else:
            fill_row[i] = ""
        mem_row[i] = ("MEM WR" if memwe[i] else "MEM RD") if memreq[i] else ""

    st0_row = {i: ST_NAME.get(s0[i]) for i in cycles}
    st1_row = {i: ST_NAME.get(s1[i]) for i in cycles}

    # -----------------------------------------------------------------
    # layout
    # -----------------------------------------------------------------
    rows = [
        ("clk",              "clk",    None),
        ("core0  cpu_req",   "bus",    c0_op),
        ("core0  cpu_ack",   "bin",    c0_ack),
        ("core0  cpu_hit",   "bin",    c0_hit),
        ("core0  set0 MESI", "state",  st0_row),
        ("core1  cpu_req",   "bus",    c1_op),
        ("core1  cpu_ack",   "bin",    c1_ack),
        ("core1  cpu_hit",   "bin",    c1_hit),
        ("core1  set0 MESI", "state",  st1_row),
        ("bus  address phase", "bus",  cmd_row),
        ("bus  completion",  "bus",    fill_row),
        ("memory port",      "bus",    mem_row),
    ]

    n = len(rows)
    fig_w = max(13.0, 0.50 * len(cycles) + 4.2)
    fig, ax = plt.subplots(figsize=(fig_w, 0.62 * n + 2.6))
    fig.patch.set_facecolor(BG)
    ax.set_facecolor(BG)

    for i in cycles:
        ax.axvline(i, color=GRID, lw=0.55, zorder=0)
    ax.axvline(len(cycles), color=GRID, lw=0.55, zorder=0)

    for r, (label, kind, data) in enumerate(rows):
        y = (n - 1 - r) * 1.0 + 0.2
        if kind == "clk":
            for i in cycles:
                ax.plot([i, i, i + 0.5, i + 0.5, i + 1],
                        [y, y + 0.62, y + 0.62, y, y], color=MUTED, lw=1.0, zorder=2)
        elif kind == "bin":
            draw_binary(ax, y, cycles, data)
        elif kind == "state":
            draw_state(ax, y, cycles, data)
        else:
            fc, ec = BUSFILL, BUSEDGE
            if "completion" in label:
                fc, ec = "#e3f2ea", GREEN
            if "memory" in label:
                fc, ec = "#f2eee3", "#9a7b2e"
            draw_bus(ax, y, cycles, data, fc=fc, ec=ec, fs=6.6)
        ax.text(-0.35, y + 0.31, label, ha="right", va="center",
                fontsize=8.6, color=FG, family="monospace")

    # ---- cycle numbers ----
    for i in cycles:
        ax.text(i + 0.5, -0.42, str(i), ha="center", va="center",
                fontsize=6.6, color=MUTED, family="monospace")
    ax.text(-0.35, -0.42, "cycle", ha="right", va="center",
            fontsize=7.4, color=MUTED, family="monospace")

    # ---- annotate the five protocol events ----
    marks = []
    prev0, prev1 = None, None
    notes = {
        ("I", "E"): ("core0: I->E\nnobody else had it", 0),
        ("E", "M"): ("core0: E->M SILENT\nzero bus cycles", 0),
        ("M", "S"): ("core0: M->S\nflushed to core1", 0),
        ("S", "I"): ("core0: S->I\nBusUpgr", 0),
        ("I", "M"): ("core0: I->M\nBusRdX", 0),
    }
    for i in cycles:
        a, b = st0_row.get(i - 1), st0_row.get(i)
        if a and b and a != b and (a, b) in notes:
            marks.append((i, notes[(a, b)][0]))
    for i in cycles:
        a, b = st1_row.get(i - 1), st1_row.get(i)
        if a and b and a != b:
            lbl = {("I", "S"): "core1: I->S",
                   ("S", "M"): "core1: S->M",
                   ("M", "I"): "core1: M->I",
                   ("S", "I"): "core1: S->I",
                   ("I", "E"): "core1: I->E",
                   ("I", "M"): "core1: I->M",
                   ("E", "M"): "core1: E->M"}.get((a, b))
            if lbl:
                marks.append((i, lbl))

    top = n * 1.0 + 0.15
    used = []
    for i, txt in marks:
        lvl = 0
        while any(abs(i - ui) < 6 and ul == lvl for ui, ul in used):
            lvl += 1
        used.append((i, lvl))
        yy = top + 0.30 + lvl * 0.62
        ax.annotate(txt, xy=(i, top - 0.10), xytext=(i, yy),
                    ha="center", va="bottom", fontsize=6.9, color=ACCENT,
                    family="monospace",
                    arrowprops=dict(arrowstyle="-", color=ACCENT, lw=0.7,
                                    shrinkA=0, shrinkB=2))

    ax.set_xlim(-4.2, len(cycles) + 0.4)
    ax.set_ylim(-0.95, top + 0.30 + (max([l for _, l in used], default=0) + 1) * 0.62 + 0.5)
    ax.axis("off")

    ax.set_title(
        "Day32 - MESI snooping cache coherence: captured from the Icarus Verilog VCD\n"
        "I -> E on a private read miss  |  E -> M with no bus transaction  |  "
        "M -> S flush  |  BusUpgr  |  BusRdX",
        fontsize=10.5, color=FG, pad=16, loc="left", x=-0.02)

    # ---- legend ----
    hs = []
    for st in ("I", "S", "E", "M"):
        hs.append(Rectangle((0, 0), 1, 1, facecolor=ST_COLOR[st],
                            edgecolor=ST_EDGE[st], lw=1.1,
                            label={"I": "I  invalid", "S": "S  shared",
                                   "E": "E  exclusive (clean, only copy)",
                                   "M": "M  modified (dirty, only copy)"}[st]))
    ax.legend(handles=hs, loc="lower left", bbox_to_anchor=(0.0, -0.13),
              ncol=4, frameon=False, fontsize=8.0, handlelength=1.5)

    out = Path(__file__).resolve().parent / "mesi_cache_waveform.png"
    fig.tight_layout()
    fig.savefig(out, dpi=155, facecolor=BG, bbox_inches="tight")
    print(f"wrote {out}")
    print(f"  window: cycles {start_i}..{start_i + len(cycles)} of the captured run "
          f"({len(posedges)} clock edges total, {period * ts_ps / 1000:.0f} ns period)")


if __name__ == "__main__":
    main()
