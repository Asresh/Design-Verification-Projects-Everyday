#!/usr/bin/env python3
"""
make_waveform.py - render docs/codec_8b10b_waveform.png from a REAL sim run.

Parses the VCD produced by Icarus Verilog (`tb_codec_8b10b_dump.vcd`, from
`make icarus_dump`) and draws the SHOWCASE window: fourteen symbols pushed back
to back, one per cycle, with the codeword appearing 1 cycle later and the
decoded symbol 2 cycles later.  Reading left to right:

    D.0.0    unbalanced both halves - drives running disparity to RD+
    K.28.5   the comma; enc_comma asserts, out_k comes back set
    D.21.2   balanced in both halves - RD does not move
    D.10.5   balanced in both halves
    D.20.7   a D.x.7 symbol, where the alternate-encoding rule decides which
             of the two 3b/4b patterns goes out
    D.31.7   unbalanced both halves
    K.28.5 with bit 9 flipped on the wire  -> the receiver catches it
    D.0.0    recovery: the link carries on from the very next symbol
    K.27.7   a non-K.28 control symbol
    K.21.2   a control symbol that does not exist -> enc_kerr, and the all-zero
             word that goes out instead is reported as a code error at the far
             end.  It also carries a disparity the transmitter never sent, so
             the receiver's RD ends up out of step - visible as the disparity
             error on the NEXT symbol, after which the link self-corrects
    D.7.0    D.07 - balanced but still alternating
    D.7.3    D.x.3 - the other balanced-but-alternating entry
    K.28.1   another comma
    D.0.0

Buses are annotated with what they mean - symbol names for in_data/out_data and
the 6b|4b sub-block split for the codewords - because "K.28.5" and
"001111|1010" are what the reader needs; the raw values are in the README.

This trace is captured from a genuine Icarus Verilog simulation of the RTL - it
is NOT hand-modeled.

Usage:
    make icarus_dump          # produces tb_codec_8b10b_dump.vcd
    python3 docs/make_waveform.py [path/to/tb_codec_8b10b_dump.vcd]
"""
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
VCD = (sys.argv[1] if len(sys.argv) > 1
       else os.path.join(HERE, "..", "tb_codec_8b10b_dump.vcd"))
OUT = os.path.join(HERE, "codec_8b10b_waveform.png")

# Display order (top -> bottom).
WANT = ["clk", "rst_n",
        "in_valid", "in_data", "in_k", "err_mask",
        "enc_valid", "enc_code", "wire_code", "enc_rd", "enc_kerr", "enc_comma",
        "out_valid", "out_data", "out_k", "out_code_err", "out_disp_err",
        "out_rd", "out_comma",
        "mark"]
SYMBUS = {"in_data", "out_data"}          # rendered as D.x.y / K.x.y
CODEBUS = {"enc_code", "wire_code"}       # rendered as abcdei|fghj
MASKBUS = {"err_mask"}                    # rendered as the flipped bit index
LEVEL = {"clk", "rst_n", "in_valid", "in_k", "enc_valid", "enc_rd", "enc_kerr",
         "enc_comma", "out_valid", "out_k", "out_code_err", "out_disp_err",
         "out_rd", "out_comma", "mark"}
PS = 1000                                 # ps per ns

# The K flag lives on a separate wire, so the symbol row needs it to know
# whether 0xBC means D.28.5 or K.28.5.
KPARTNER = {"in_data": "in_k", "out_data": "out_k"}


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
                    in_top = (depth == 1)   # tb_codec_8b10b_dump = depth 1
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


def as_symbol(binstr, is_k):
    """A byte, in the D.x.y / K.x.y notation the standard uses."""
    v = to_int(binstr)
    if v is None:
        return None
    return "%s.%d.%d" % ("K" if is_k else "D", v & 0x1F, (v >> 5) & 0x7)


def as_code(binstr):
    """A codeword, split into its 5b/6b and 3b/4b sub-blocks."""
    v = to_int(binstr)
    if v is None:
        return None
    b = format(v, "010b")
    return "%s|%s" % (b[:6], b[6:])


def as_mask(binstr):
    """A wire-error mask, as the bit position it flips."""
    v = to_int(binstr)
    if v is None:
        return None
    if v == 0:
        return "clean"
    bits = [i for i in range(10) if v & (1 << i)]
    return "flip b%s" % ",".join(str(b) for b in bits)


def window(series, sym_of):
    """The `mark`-delimited showcase section, padded so the pipeline fill at
    the start and the last drained symbol at the end are both on screen."""
    mk = series[sym_of["mark"]]
    t0 = next((t for (t, v) in mk if v == "1"), None)
    t1 = next((t for (t, v) in mk if v == "0" and t0 is not None and t > t0),
              None)
    if t0 is None or t1 is None:
        sys.exit("mark window not found in VCD")
    return t0 - 20 * PS, t1 + 30 * PS


def main():
    if not os.path.exists(VCD):
        sys.exit("VCD not found: %s  (run `make icarus_dump` first)" % VCD)
    sym_of, width, changes = parse_vcd(VCD)
    missing = [w for w in WANT if w not in sym_of]
    if missing:
        sys.exit("signals not found in VCD: %s" % missing)
    series = build_series(sym_of, changes)
    T0, T1 = window(series, sym_of)

    step = 200
    ts = list(range(T0, T1 + step, step))

    fig, axes = plt.subplots(len(WANT), 1, figsize=(16, 11.2), sharex=True)
    fig.suptitle(
        "8b/10b encoder / decoder - SHOWCASE WINDOW\n"
        "REAL Icarus Verilog capture (tb_codec_8b10b_dump.vcd) - one symbol per "
        "cycle, zero bubble, codeword at LAT=1 and decoded symbol at LAT=2:\n"
        "commas and running disparity, a single-bit wire error caught as a code "
        "error, and an unencodable control request whose all-zero word knocks\n"
        "the receiver's RD out of step - which surfaces as a disparity error on "
        "the very next symbol, then self-corrects",
        fontsize=10.4, fontweight="bold")

    grid = [g * PS for g in range(0, 100000, 10) if T0 <= g * PS <= T1]

    color = {"clk": "#333333", "rst_n": "#8a6d3b",
             "in_valid": "#1f7a4d", "in_k": "#1f7a4d",
             "enc_valid": "#1f4e8c", "enc_rd": "#5b2d91",
             "enc_kerr": "#a3282d", "enc_comma": "#b5761f",
             "out_valid": "#1f4e8c", "out_k": "#1f7a4d",
             "out_code_err": "#a3282d", "out_disp_err": "#a3282d",
             "out_rd": "#5b2d91", "out_comma": "#b5761f",
             "mark": "#5b2d91"}
    tint = {"in_data": "#dff0e6", "out_data": "#dff0e6",
            "enc_code": "#dfe8f5", "wire_code": "#f3e4e4",
            "err_mask": "#f5efdc"}

    def draw_bus(ax, name, seq, tint_c):
        kseq = series[sym_of[KPARTNER[name]]] if name in KPARTNER else None
        pts = sorted(set([T0] + [tt for (tt, _) in seq if T0 < tt < T1] + [T1]))
        if kseq is not None:
            pts = sorted(set(pts + [tt for (tt, _) in kseq if T0 < tt < T1]))
        for i in range(len(pts) - 1):
            a_, b_ = pts[i], pts[i + 1]
            raw = value_at(seq, a_)
            if name in SYMBUS:
                is_k = as_level(value_at(kseq, a_) or "0")
                txt = as_symbol(raw, is_k)
            elif name in CODEBUS:
                txt = as_code(raw)
            elif name in MASKBUS:
                txt = as_mask(raw)
            else:
                txt = raw
            an, bn = a_ / PS, b_ / PS
            if txt is not None and (bn - an) > 1.0:
                ax.fill_between([an, bn], 0.16, 0.84, color=tint_c,
                                edgecolor="#1f4e8c", lw=1.0, zorder=2)
                ax.text((an + bn) / 2, 0.5, txt, ha="center", va="center",
                        fontsize=7.0, fontfamily="monospace", zorder=3)
        ax.set_ylim(0, 1)

    for ax, name in zip(axes, WANT):
        seq = series[sym_of[name]]
        ax.set_ylabel(name, rotation=0, ha="right", va="center",
                      fontsize=8.4, labelpad=36, fontfamily="monospace")
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
            ax.step(xs, ys, where="post", color=color[name], lw=1.4)
            ax.fill_between(xs, ys, step="post", color=color[name], alpha=0.08)
            ax.set_ylim(-0.25, 1.35)
        else:
            draw_bus(ax, name, seq, tint[name])

    axes[-1].set_xlabel("time (ns)   -   one 10 ns cycle per symbol", fontsize=10)
    axes[-1].set_xlim(T0 / PS, T1 / PS)

    fig.tight_layout(rect=[0, 0, 1, 0.885])
    fig.savefig(OUT, dpi=125)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
