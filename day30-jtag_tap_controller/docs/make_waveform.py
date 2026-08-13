#!/usr/bin/env python3
"""
make_waveform.py - render docs/jtag_tap_waveform.png from a REAL sim run.

Parses the VCD produced by Icarus Verilog (`tb_jtag_tap_dump.vcd`, from
`make icarus_dump`) and draws the SHOWCASE window the testbench delimits with
its `mark` signal: a complete IR scan that loads SAMPLE/PRELOAD, immediately
followed by an eight-bit boundary-scan DR scan that is PARKED IN PAUSE-DR
halfway through.

Reading left to right, this one window contains most of what the standard has
to say about a TAP:

    Run-Test/Idle -> Select-DR -> Select-IR -> Capture-IR
        Capture-IR loads 0b0001, and TDO shows that mandatory 1 - the bit a
        board tester uses to tell a live TAP from a chain stuck at zero
    Shift-IR x4
        the opcode 0b0001 goes in on TDI, LSB first; the captured pattern
        comes out on TDO.  The fourth cycle carries TMS=1, so the last bit is
        shifted in on the way out - that is how n bits fit into n clocks
    Exit1-IR -> Update-IR
        ir_latched changes here, and it changes on the FALLING edge, half a
        cycle after the state is entered
    Run-Test/Idle -> Select-DR -> Capture-DR
        the boundary register grabs pin_in (0xA5) at this rising edge
    Shift-DR x4 -> Exit1-DR -> Pause-DR -> Exit2-DR -> Shift-DR x4
        the scan is parked mid-chain and resumed.  Nothing is lost: the
        Shift->Exit1 transition still shifts a bit, Exit2->Shift does not,
        and the captured 0xA5 comes out across the park
    Exit1-DR -> Update-DR
        pin_out takes the preloaded 0x5A, again on the falling edge

Note tdo_en: TDO is driven in exactly the two Shift states and is left alone
everywhere else, which is what lets several devices share one scan chain.

This trace is captured from a genuine Icarus Verilog simulation of the RTL -
it is NOT hand-modeled.

Usage:
    make icarus_dump          # produces tb_jtag_tap_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_jtag_tap_dump.vcd]
"""
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
VCD = (sys.argv[1] if len(sys.argv) > 1
       else os.path.join(HERE, "..", "tb_jtag_tap_dump.vcd"))
OUT = os.path.join(HERE, "jtag_tap_waveform.png")

# Display order (top -> bottom).
WANT = ["tck", "trst_n",
        "tms", "tdi", "tdo", "tdo_en",
        "state", "ir_shift", "ir_latched",
        "pin_in", "pin_out", "pin_oe", "user_out",
        "mark"]

LEVEL = {"tck", "trst_n", "tms", "tdi", "tdo", "tdo_en", "pin_oe", "mark"}
STATEBUS = {"state"}                  # rendered as the state's name
INSTRBUS = {"ir_latched"}             # rendered as the instruction's name
BITBUS = {"ir_shift"}                 # rendered as raw bits
HEXBUS = {"pin_in", "pin_out", "user_out"}
PS = 1000                             # ps per ns

# The conventional four-bit TAP state encoding, from the standard's diagram.
STATE_NAME = {
    0x0: "Exit2-DR",   0x1: "Exit1-DR",   0x2: "Shift-DR",   0x3: "Pause-DR",
    0x4: "Select-IR",  0x5: "Update-DR",  0x6: "Capture-DR", 0x7: "Select-DR",
    0x8: "Exit2-IR",   0x9: "Exit1-IR",   0xA: "Shift-IR",   0xB: "Pause-IR",
    0xC: "Run/Idle",   0xD: "Update-IR",  0xE: "Capture-IR", 0xF: "TLR",
}

INSTR_NAME = {
    0b0000: "EXTEST", 0b0001: "SAMPLE", 0b0010: "IDCODE",
    0b1000: "USER",   0b1100: "CLAMP",  0b1111: "BYPASS",
}

# The states in which something is latched or captured, tinted so the eye
# lands on them.
HOT_STATES = {0x6: "#dff0e6",   # Capture-DR
              0xE: "#dff0e6",   # Capture-IR
              0x5: "#f5e0c8",   # Update-DR
              0xD: "#f5e0c8",   # Update-IR
              0x2: "#dfe8f5",   # Shift-DR
              0xA: "#dfe8f5",   # Shift-IR
              0x3: "#f3e4e4",   # Pause-DR
              0xB: "#f3e4e4",   # Pause-IR
              0xF: "#e8e2f2"}   # Test-Logic-Reset


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
                    in_top = (depth == 1)   # tb_jtag_tap_dump = depth 1
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
    return t0 - 30 * PS, t1 + 20 * PS


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

    fig, axes = plt.subplots(len(WANT), 1, figsize=(19, 8.6), sharex=True)
    fig.suptitle(
        "IEEE 1149.1 JTAG TAP controller - SHOWCASE WINDOW\n"
        "REAL Icarus Verilog capture (tb_jtag_tap_dump.vcd): an IR scan loading "
        "SAMPLE/PRELOAD, then an 8-bit boundary scan PARKED IN PAUSE-DR halfway "
        "through.\n"
        "Capture-IR presents the mandatory 0b0001 on TDO; the boundary captures "
        "pin_in=0xA5 at Capture-DR; the park costs no bits; ir_latched and "
        "pin_out both change on the FALLING edge, half a cycle after their "
        "Update state is entered.\n"
        "tdo_en is asserted in exactly the two Shift states - which is what lets "
        "several devices share one scan chain.",
        fontsize=10.2, fontweight="bold", y=0.995)

    # One gridline per TCK cycle (20 ns), so the reader can count clocks.
    grid = [g * PS for g in range(0, 1000000, 20) if T0 <= g * PS <= T1]

    color = {"tck": "#333333", "trst_n": "#8a6d3b",
             "tms": "#a3282d", "tdi": "#1f7a4d", "tdo": "#1f4e8c",
             "tdo_en": "#5b2d91", "pin_oe": "#b5761f", "mark": "#5b2d91"}
    tint = {"ir_shift": "#dfe8f5", "ir_latched": "#f5e0c8",
            "pin_in": "#dff0e6", "pin_out": "#f5efdc", "user_out": "#eeeeee"}

    def label_for(name, raw):
        v = to_int(raw)
        if v is None:
            return None
        if name in STATEBUS:
            return STATE_NAME.get(v, "0x%X" % v)
        if name in INSTRBUS:
            return INSTR_NAME.get(v, "0b" + format(v, "04b") + "*")  # * = unimplemented
        if name in BITBUS:
            return "0b" + format(v, "04b")
        return "0x%02X" % v

    def draw_bus(ax, name, seq, default_tint):
        pts = sorted(set([T0] + [tt for (tt, _) in seq if T0 < tt < T1] + [T1]))
        for i in range(len(pts) - 1):
            a_, b_ = pts[i], pts[i + 1]
            raw = value_at(seq, a_)
            txt = label_for(name, raw)
            an, bn = a_ / PS, b_ / PS
            if txt is None or (bn - an) <= 0.5:
                continue
            c = default_tint
            if name in STATEBUS:
                c = HOT_STATES.get(to_int(raw), "#f2f2f2")
            ax.fill_between([an, bn], 0.14, 0.86, color=c,
                            edgecolor="#1f4e8c", lw=0.9, zorder=2)
            ax.text((an + bn) / 2, 0.5, txt, ha="center", va="center",
                    fontsize=6.6 if name in STATEBUS else 7.0,
                    rotation=90 if (name in STATEBUS and (bn - an) < 26) else 0,
                    fontfamily="monospace", zorder=3)
        ax.set_ylim(0, 1)

    for ax, name in zip(axes, WANT):
        seq = series[sym_of[name]]
        ax.set_ylabel(name, rotation=0, ha="right", va="center",
                      fontsize=8.6, labelpad=40, fontfamily="monospace")
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
        "time (ns)   -   one gridline per 20 ns TCK cycle.  TMS/TDI are sampled "
        "on the rising edge; TDO, ir_latched and pin_out change on the falling "
        "edge.", fontsize=9.5)
    axes[-1].set_xlim(T0 / PS, T1 / PS)

    fig.tight_layout(rect=[0, 0, 1, 0.935])
    fig.savefig(OUT, dpi=125)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
