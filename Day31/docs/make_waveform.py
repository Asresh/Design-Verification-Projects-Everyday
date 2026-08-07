#!/usr/bin/env python3
"""
make_waveform.py - render docs/cache_ctrl_waveform.png from a REAL sim run.

Parses the VCD produced by Icarus Verilog (`tb_cache_ctrl_dump.vcd`, from
`make icarus_dump`) and draws the SHOWCASE window the testbench delimits with
its `mark` signal.

That window is the whole argument for a write-back write-allocate cache, in
three accesses:

    1. WRITE HIT to a resident line
         cpu_req_we is high, the lookup hits, the response comes back with
         cpu_rsp_hit=1 - and the memory port never moves.  The store is now
         sitting in the cache and DRAM does not know about it.  That silence
         is the feature.

    2. READ MISS to a different tag in the SAME set
         Direct-mapped, so this address wants the line the dirty data is in.
         The controller therefore:
           EVICT  - four memory WRITES, one per word, carrying the line back
                    to its OLD address (note mem_req_we high; the DEADBEEF
                    written in step 1 leaves in the SECOND beat, at 0x004,
                    because that is the word it was written to - the whole
                    line goes, not just the dirty word)
           FILL   - four memory READS at the NEW address, one outstanding at
                    a time, each one landing in the data array
           ALLOC  - the line is re-tagged and the access that missed is
                    finally performed
           RESP   - cpu_rsp_hit=0

    3. READ HIT in the line just filled
         Two cycles, no memory traffic.

Read the `state` row left to right and the FSM is right there:
IDLE -> LOOKUP -> RESP for a hit, and IDLE -> LOOKUP -> EVICT x4 -> FILL x8 ->
ALLOC -> RESP for a dirty miss.

This trace is captured from a genuine Icarus Verilog simulation of the RTL -
it is NOT hand-modeled.  The backing memory in the showcase window is
configured always-ready with zero read latency so the picture is about the
cache rather than about a slow memory; the rest of the run hammers it with
random stalls and latency instead.

Usage:
    make icarus_dump          # produces tb_cache_ctrl_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_cache_ctrl_dump.vcd]
"""
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
VCD = (sys.argv[1] if len(sys.argv) > 1
       else os.path.join(HERE, "..", "tb_cache_ctrl_dump.vcd"))
OUT = os.path.join(HERE, "cache_ctrl_waveform.png")

# Display order (top -> bottom).
WANT = ["clk",
        "cpu_req_valid", "cpu_req_ready", "cpu_req_we", "cpu_req_addr",
        "cpu_rsp_valid", "cpu_rsp_hit", "cpu_rsp_rdata",
        "state",
        "mem_req_valid", "mem_req_ready", "mem_req_we",
        "mem_req_addr", "mem_req_wdata",
        "mem_rsp_valid", "mem_rsp_rdata",
        "mark"]

LEVEL = {"clk", "cpu_req_valid", "cpu_req_ready", "cpu_req_we",
         "cpu_rsp_valid", "cpu_rsp_hit",
         "mem_req_valid", "mem_req_ready", "mem_req_we", "mem_rsp_valid",
         "mark"}
STATEBUS = {"state"}
ADDRBUS = {"cpu_req_addr", "mem_req_addr"}
DATABUS = {"cpu_rsp_rdata", "mem_req_wdata", "mem_rsp_rdata"}
PS = 1000                              # ps per ns
CYCLE = 10                             # ns

STATE_NAME = {
    0: "IDLE",  1: "LOOKUP", 2: "EVICT", 3: "FILL",
    4: "ALLOC", 5: "RESP",   6: "FSCAN", 7: "FWB",
}

# The states worth letting the eye land on.
HOT_STATES = {
    0: "#f2f2f2",     # IDLE
    1: "#dfe8f5",     # LOOKUP - where hit/miss is decided
    2: "#f5d9d9",     # EVICT  - dirty data leaving
    3: "#dff0e6",     # FILL   - new data arriving
    4: "#f5e0c8",     # ALLOC  - the line is re-tagged
    5: "#e8e2f2",     # RESP
    6: "#efe6d5",     # FSCAN
    7: "#f3e4e4",     # FWB
}


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
                    in_top = (depth == 1)   # tb_cache_ctrl_dump = depth 1
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
    return 1 if v == "1" else 0


def to_int(binstr):
    if binstr is None:
        return None
    try:
        return int(binstr, 2)
    except (ValueError, TypeError):
        return None


def window(series, sym_of):
    """The `mark`-delimited showcase section, padded a little either side."""
    mk = series[sym_of["mark"]]
    t0 = next((t for (t, v) in mk if v == "1"), None)
    t1 = next((t for (t, v) in mk if v == "0" and t0 is not None and t > t0),
              None)
    if t0 is None or t1 is None:
        sys.exit("mark window not found in VCD")
    return t0 - 15 * PS, t1 + 10 * PS


def main():
    if not os.path.exists(VCD):
        sys.exit("VCD not found: %s  (run `make icarus_dump` first)" % VCD)
    sym_of, width, changes = parse_vcd(VCD)
    missing = [w for w in WANT if w not in sym_of]
    if missing:
        sys.exit("signals not found in VCD: %s" % missing)
    series = build_series(sym_of, changes)
    T0, T1 = window(series, sym_of)

    step = 500
    ts = list(range(T0, T1 + step, step))

    fig, axes = plt.subplots(len(WANT), 1, figsize=(21, 9.6), sharex=True)
    fig.suptitle(
        "Direct-mapped WRITE-BACK / WRITE-ALLOCATE cache controller - SHOWCASE "
        "WINDOW\n"
        "REAL Icarus Verilog capture (tb_cache_ctrl_dump.vcd): a write hit, "
        "then a conflicting read that must EVICT the dirty line before it can "
        "FILL the new one, then a hit in the line just filled.\n"
        "The write hit moves NO memory traffic at all - that is what "
        "write-back means.  The miss that follows pays for it: four memory "
        "WRITES carrying the WHOLE dirty line back to its OLD address "
        "(0xDEADBEEF leaves in the second beat, at 0x004, the word it was "
        "written to),\n"
        "then four memory READS at the NEW address, one outstanding at a time. "
        " Read the `state` row to see the FSM: IDLE-LOOKUP-RESP for a hit, "
        "IDLE-LOOKUP-EVICT-FILL-ALLOC-RESP for a dirty miss.",
        fontsize=10.0, fontweight="bold", y=0.997)

    grid = [g * PS for g in range(0, 1000000, CYCLE) if T0 <= g * PS <= T1]

    color = {"clk": "#333333",
             "cpu_req_valid": "#1f4e8c", "cpu_req_ready": "#1f7a4d",
             "cpu_req_we": "#a3282d",
             "cpu_rsp_valid": "#1f4e8c", "cpu_rsp_hit": "#1f7a4d",
             "mem_req_valid": "#8a3ea3", "mem_req_ready": "#1f7a4d",
             "mem_req_we": "#a3282d", "mem_rsp_valid": "#8a3ea3",
             "mark": "#5b2d91"}
    tint = {"cpu_req_addr": "#dfe8f5", "cpu_rsp_rdata": "#e8e2f2",
            "mem_req_addr": "#f5d9d9", "mem_req_wdata": "#f5d9d9",
            "mem_rsp_rdata": "#dff0e6"}

    def label_for(name, raw):
        v = to_int(raw)
        if v is None:
            return None
        if name in STATEBUS:
            return STATE_NAME.get(v, "0x%X" % v)
        if name in ADDRBUS:
            return "0x%03X" % v
        return "%08X" % v

    def draw_bus(ax, name, seq, default_tint):
        pts = sorted(set([T0] + [tt for (tt, _) in seq if T0 < tt < T1] + [T1]))
        for i in range(len(pts) - 1):
            a_, b_ = pts[i], pts[i + 1]
            raw = value_at(seq, a_)
            txt = label_for(name, raw)
            an, bn = a_ / PS, b_ / PS
            if txt is None or (bn - an) <= 0.5:
                continue
            c = HOT_STATES.get(to_int(raw), "#f2f2f2") if name in STATEBUS \
                else default_tint
            ax.fill_between([an, bn], 0.14, 0.86, color=c,
                            edgecolor="#1f4e8c", lw=0.9, zorder=2)
            ax.text((an + bn) / 2, 0.5, txt, ha="center", va="center",
                    fontsize=6.4 if name in STATEBUS else 6.6,
                    rotation=90 if (bn - an) < 16 else 0,
                    fontfamily="monospace", zorder=3)
        ax.set_ylim(0, 1)

    for ax, name in zip(axes, WANT):
        seq = series[sym_of[name]]
        ax.set_ylabel(name, rotation=0, ha="right", va="center",
                      fontsize=8.4, labelpad=42, fontfamily="monospace")
        ax.set_yticks([])
        for spine in ("top", "right", "left"):
            ax.spines[spine].set_visible(False)
        for g in grid:
            ax.axvline(g / PS, color="0.93", lw=0.6, zorder=0)

        if name in LEVEL:
            xs, ys, last = [], [], as_level(value_at(seq, T0) or "0")
            for t in ts:
                v = value_at(seq, t)
                lv = as_level(v) if v is not None else last
                last = lv
                xs.append(t / PS)
                ys.append(lv)
            ax.step(xs, ys, where="post", color=color[name], lw=1.3)
            ax.fill_between(xs, ys, step="post", color=color[name], alpha=0.08)
            ax.set_ylim(-0.25, 1.35)
        else:
            draw_bus(ax, name, seq, tint.get(name, "#f2f2f2"))

    axes[-1].set_xlabel(
        "time (ns)   -   one gridline per 10 ns clock cycle.  Everything is "
        "sampled on the rising edge; the response channel is registered, so a "
        "response appears one cycle after the RESP state is entered.",
        fontsize=9.5)
    axes[-1].set_xlim(T0 / PS, T1 / PS)

    fig.tight_layout(rect=[0, 0, 1, 0.925])
    fig.savefig(OUT, dpi=125)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
