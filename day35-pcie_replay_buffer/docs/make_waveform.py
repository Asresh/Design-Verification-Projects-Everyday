#!/usr/bin/env python3
"""Author: Asresh Kuricheti. Render a real Icarus-captured replay-buffer waveform."""
import sys
from pathlib import Path
import matplotlib.pyplot as plt

vcd = Path(sys.argv[1] if len(sys.argv) > 1 else "tb_pcie_replay_dump.vcd")
codes, changes, scope, now = {}, {}, [], 0
for raw in vcd.read_text().splitlines():
    line = raw.strip()
    if line.startswith("$scope"): scope.append(line.split()[2])
    elif line.startswith("$upscope"): scope.pop()
    elif line.startswith("$var"):
        p = line.split(); name = p[4]
        if p[3] not in codes: codes[p[3]] = ".".join(scope + [name])
        changes.setdefault(p[3], [])
    elif line.startswith("#"): now = int(line[1:])
    elif line and line[0] in "01xz" and line[1:] in changes: changes[line[1:]].append((now, line[0]))
    elif line.startswith("b"):
        bits, code = line[1:].split()
        if code in changes: changes[code].append((now, bits))

def get_code(name):
    for code, full in codes.items():
        if full == "tb_pcie_replay_dump." + name: return code
    raise KeyError(name)
def value(name, time):
    out = "0"
    for when, val in changes[get_code(name)]:
        if when > time: break
        out = val
    return out
def number(name, time):
    raw = value(name, time)
    return 0 if any(c in raw.lower() for c in "xz") else int(raw, 2)

rises = [t for t, v in changes[get_code("clk")] if v == "1"][2:30]
x = list(range(len(rises)))
signals = ["rst_n", "tx_valid", "tx_ready", "link_valid", "link_ready", "ack_valid", "nak_valid", "replay_active", "full"]
fig, axes = plt.subplots(len(signals)+1, 1, figsize=(18, 11), sharex=True, constrained_layout=True,
                         gridspec_kw={"height_ratios":[1]*len(signals)+[2.4]})
for ax, name in zip(axes, signals):
    ax.step(x, [number(name,t) for t in rises], where="post", linewidth=2)
    ax.set_ylim(-.15,1.15); ax.set_yticks([0,1]); ax.grid(axis="x", alpha=.25)
    ax.set_ylabel(name, rotation=0, ha="right", va="center", fontsize=8)
ax = axes[-1]; ax.set_ylim(-.5,.5); ax.set_yticks([]); ax.grid(axis="x",alpha=.25)
ax.set_ylabel("sequence /\npayload / depth", rotation=0, ha="right", va="center", fontsize=8)
for i,t in enumerate(rises):
    text = f"occ={number('occupancy',t)}"
    if number("tx_valid",t) and number("tx_ready",t): text += f"\nENQ {number('tx_data',t):08x}"
    if number("link_valid",t): text += f"\nL{number('link_seq',t):02x}:{number('link_data',t):08x}"
    if number("ack_valid",t): text += f"\nACK {number('ack_seq',t):02x}"
    if number("nak_valid",t): text += f"\nNAK {number('nak_seq',t):02x}"
    ax.text(i,0,text,ha="center",va="center",fontsize=6.2,family="monospace")
axes[-1].set_xlabel("Captured rising-edge cycle")
fig.suptitle("Day 35 — PCIe-Style Replay Buffer: enqueue, backpressure, NAK replay, cumulative ACK", fontsize=14)
out = Path(__file__).with_name("pcie_replay_buffer_waveform.png")
fig.savefig(out, dpi=170); print(out)
