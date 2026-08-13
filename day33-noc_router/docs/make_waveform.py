#!/usr/bin/env python3
"""Render the first contention/backpressure window from an Icarus VCD."""
import sys
from pathlib import Path
import matplotlib.pyplot as plt

vcd = Path(sys.argv[1] if len(sys.argv) > 1 else "tb_noc_router_dump.vcd")
codes, changes, scope, now = {}, {}, [], 0
for raw in vcd.read_text().splitlines():
    line = raw.strip()
    if line.startswith("$scope"):
        scope.append(line.split()[2])
    elif line.startswith("$upscope"):
        scope.pop()
    elif line.startswith("$var"):
        p = line.split()
        name = p[4] + ((" " + p[5]) if len(p) > 6 and p[5] != "$end" else "")
        codes[p[3]] = ".".join(scope + [name])
        changes.setdefault(p[3], [])
    elif line.startswith("#"):
        now = int(line[1:])
    elif line and line[0] in "01xz" and line[1:] in changes:
        changes[line[1:]].append((now, line[0]))
    elif line.startswith("b"):
        bits, code = line[1:].split()
        if code in changes:
            changes[code].append((now, bits))

def code_for(suffix):
    matches = [c for c,n in codes.items() if n.startswith("tb_noc_router_dump.") and
               (n.endswith(suffix) or n.endswith(suffix + " [2:0]") or n.endswith(suffix + " [5:0]") or
                n.endswith(suffix + " [95:0]"))]
    if not matches:
        raise KeyError(f"VCD signal not found: {suffix}")
    return matches[0]

def value_at(code, t):
    val = "0"
    for ct, cv in changes[code]:
        if ct > t: break
        val = cv
    return val

def as_int(v):
    return 0 if any(x in v.lower() for x in "xz") else int(v, 2)

clk = code_for("clk")
rises = [t for t,v in changes[clk] if v == "1"][3:19]
names = ["rst_n","in_valid","in_ready","out_valid","out_ready","in_last","out_last"]
fig, axes = plt.subplots(len(names)+2, 1, figsize=(18, 10), sharex=True,
                         constrained_layout=True,
                         gridspec_kw={"height_ratios":[1]*len(names)+[1.5,1.5]})
x = list(range(len(rises)))
for ax,name in zip(axes,names):
    vals = [as_int(value_at(code_for(name),t)) for t in rises]
    ax.step(x, vals, where="post", linewidth=1.8)
    ax.set_ylabel(name, rotation=0, ha="right", va="center", fontsize=9)
    ax.grid(True, axis="x", alpha=.25)
    ax.set_yticks(sorted(set(vals)))

for ax, side in ((axes[-2],"in"),(axes[-1],"out")):
    ax.set_ylim(-.5,.5); ax.set_yticks([]); ax.grid(True, axis="x", alpha=.25)
    ax.set_ylabel(side+" transfers", rotation=0, ha="right", va="center", fontsize=9)
    for i,t in enumerate(rises):
        valid=as_int(value_at(code_for(side+"_valid"),t))
        ready=as_int(value_at(code_for(side+"_ready"),t))
        dests=as_int(value_at(code_for(side+"_dest"),t))
        flits=as_int(value_at(code_for(side+"_flit"),t))
        tokens=[]
        for p in range(3):
            if ((valid >> p) & 1) and ((ready >> p) & 1):
                d=(dests >> (2*p)) & 3
                f=(flits >> (32*p)) & 0xffffffff
                tokens.append(f"p{p}→{d}\n{f:08x}")
        ax.text(i,0,"\n".join(tokens) if tokens else "—",ha="center",va="center",
                fontsize=6.5,family="monospace")

axes[-1].set_xlabel("Captured rising-edge cycle")
fig.suptitle("Day 33 — 3×3 NoC Router: contention, round-robin service, and backpressure", fontsize=14)
out = Path(__file__).with_name("noc_router_waveform.png")
fig.savefig(out, dpi=170)
print(out)
