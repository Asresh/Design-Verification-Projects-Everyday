#!/usr/bin/env python3
"""Cycle-accurate hand model of sync_fifo, rendered as a timing diagram.

No HDL simulator was available in the build environment, so this Python model
reproduces the RTL's clocked behavior exactly (same acceptance rules, same
count/flag equations) and draws the resulting waveform. It is a MODELED
diagram, not a screenshot from a real simulator run -- the README says so.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

DEPTH = 8

# ---- Stimulus program: (rst_n, wr_en, wr_data, rd_en) applied at each posedge.
# Covers: reset, fill to full, overflow attempt, drain to empty, underflow
# attempt, and a simultaneous read+write.
prog = [
    (0, 0, 0x00, 0),  # c0  reset
    (0, 0, 0x00, 0),  # c1  reset
    (1, 1, 0xA0, 0),  # c2  write A0
    (1, 1, 0xA1, 0),  # c3  write A1
    (1, 1, 0xA2, 0),  # c4  write A2
    (1, 1, 0xA3, 0),  # c5  write A3 (fast-fill excerpt)
    (1, 1, 0xA4, 0),  # c6  write A4
    (1, 1, 0xA5, 0),  # c7  write A5
    (1, 1, 0xA6, 0),  # c8  write A6
    (1, 1, 0xA7, 0),  # c9  write A7 -> becomes FULL
    (1, 1, 0xFF, 0),  # c10 OVERFLOW attempt (dropped)
    (1, 0, 0x00, 1),  # c11 read A0
    (1, 1, 0x5C, 1),  # c12 simultaneous R+W (read A1, write 5C)
    (1, 0, 0x00, 1),  # c13 read A2
]

# ---- Model state
wr_ptr = rd_ptr = count = 0
mem = [0] * DEPTH

# Sampled-before-edge (combinational) values, and post-edge state.
rows = []  # dicts of per-cycle signal values as displayed
for (rst_n, wr_en, wr_data, rd_en) in prog:
    full  = 1 if count == DEPTH else 0
    empty = 1 if count == 0 else 0
    do_wr = wr_en and not full and rst_n
    do_rd = rd_en and not empty and rst_n
    rd_data = mem[rd_ptr]  # combinational read of current head

    rows.append(dict(rst_n=rst_n, wr_en=wr_en, wr_data=wr_data, rd_en=rd_en,
                     rd_data=rd_data, full=full, empty=empty, count=count))

    # clocked update
    if not rst_n:
        wr_ptr = rd_ptr = count = 0
    else:
        if do_wr:
            mem[wr_ptr] = wr_data
            wr_ptr = 0 if wr_ptr == DEPTH - 1 else wr_ptr + 1
        if do_rd:
            rd_ptr = 0 if rd_ptr == DEPTH - 1 else rd_ptr + 1
        if do_wr and not do_rd:
            count += 1
        elif do_rd and not do_wr:
            count -= 1

N = len(rows)

# ---------------------------------------------------------------- plotting
binary_sigs = ["rst_n", "wr_en", "rd_en", "full", "empty"]
bus_sigs    = ["wr_data", "rd_data", "count"]
order = ["clk"] + binary_sigs + bus_sigs

fig, ax = plt.subplots(figsize=(15, 8))
row_h = 1.0
gap   = 0.35
ytop  = len(order) * (row_h + gap)

def ylane(i):
    return ytop - i * (row_h + gap)

hi, lo = 0.72, 0.05  # within-lane high/low offsets

# --- clock ---
y0 = ylane(0)
xs, ys = [], []
for c in range(N):
    xs += [c, c + 0.5, c + 0.5, c + 1.0]
    ys += [y0 + lo, y0 + lo, y0 + hi, y0 + hi]
    # build proper square wave
# simpler: draw square wave manually
ax.text(-0.15, y0 + (hi + lo) / 2, "clk", ha="right", va="center", fontsize=11, fontweight="bold")
for c in range(N):
    ax.plot([c, c, c + 0.5, c + 0.5, c + 1.0],
            [y0 + lo, y0 + hi, y0 + hi, y0 + lo, y0 + lo],
            color="#1f77b4", lw=1.4)

# --- binary signals ---
for si, sig in enumerate(binary_sigs, start=1):
    y = ylane(si)
    ax.text(-0.15, y + (hi + lo) / 2, sig, ha="right", va="center",
            fontsize=11, fontweight="bold")
    prev = rows[0][sig]
    for c in range(N):
        v = rows[c][sig]
        yv = y + hi if v else y + lo
        ax.plot([c, c + 1], [yv, yv], color="#d62728" if v else "#2ca02c", lw=1.8)
        if c > 0 and rows[c][sig] != rows[c - 1][sig]:
            ax.plot([c, c], [y + lo, y + hi], color="#555", lw=1.0)

# --- bus signals (hex boxes) ---
palette = {"wr_data": "#e8f0fe", "rd_data": "#fef3e8", "count": "#eef7ec"}
for bi, sig in enumerate(bus_sigs):
    y = ylane(1 + len(binary_sigs) + bi)
    ax.text(-0.15, y + (hi + lo) / 2, sig, ha="right", va="center",
            fontsize=11, fontweight="bold")
    for c in range(N):
        val = rows[c][sig]
        if sig == "count":
            label = f"{val}"
        else:
            label = f"{val:02X}"
        rect = Rectangle((c + 0.03, y + lo), 0.94, hi - lo,
                         facecolor=palette[sig], edgecolor="#666", lw=0.8)
        ax.add_patch(rect)
        ax.text(c + 0.5, y + (hi + lo) / 2, label, ha="center", va="center",
                fontsize=9, family="monospace")

# --- annotations for key events ---
events = {
    1.5: "reset\nreleased",
    9.5: "FULL",
    10.5: "overflow\ndropped",
    11.5: "read A0",
    12.5: "R+W\nsame cycle",
}
for x, txt in events.items():
    ax.annotate(txt, xy=(x, ytop + 0.15), ha="center", va="bottom",
                fontsize=8.5, color="#333",
                arrowprops=None)

# cycle grid + numbers
for c in range(N + 1):
    ax.plot([c, c], [0, ytop + 0.05], color="#eee", lw=0.6, zorder=0)
for c in range(N):
    ax.text(c + 0.5, -0.35, f"{c}", ha="center", va="top", fontsize=8, color="#888")
ax.text(N / 2, -0.75, "clock cycle", ha="center", va="top", fontsize=9, color="#888")

ax.set_xlim(-1.4, N + 0.2)
ax.set_ylim(-1.0, ytop + 1.0)
ax.axis("off")
ax.set_title("sync_fifo (WIDTH=8, DEPTH=8) — modeled timing diagram\n"
             "reset → fill-to-full → overflow drop → read → simultaneous R+W",
             fontsize=13, fontweight="bold")

plt.tight_layout()
out = __file__.rsplit("/", 1)[0] + "/sync_fifo_waveform.png"
plt.savefig(out, dpi=130, bbox_inches="tight")
print("wrote", out)
