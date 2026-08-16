#!/usr/bin/env python3
"""Author: Asresh Kuricheti. Render the real Icarus-captured AXI reorder waveform."""
import sys
from pathlib import Path
import matplotlib.pyplot as plt

vcd = Path(sys.argv[1] if len(sys.argv) > 1 else "tb_axi_read_reorder_dump.vcd")
codes, changes, scope, now = {}, {}, [], 0
for raw in vcd.read_text().splitlines():
    line = raw.strip()
    if line.startswith("$scope"): scope.append(line.split()[2])
    elif line.startswith("$upscope"): scope.pop()
    elif line.startswith("$var"):
        p=line.split(); name=p[4]
        if p[3] not in codes: codes[p[3]]=".".join(scope+[name])
        changes.setdefault(p[3],[])
    elif line.startswith("#"): now=int(line[1:])
    elif line and line[0] in "01xz" and line[1:] in changes: changes[line[1:]].append((now,line[0]))
    elif line.startswith("b"):
        bits,code=line[1:].split()
        if code in changes: changes[code].append((now,bits))

def code(name):
    target="tb_axi_read_reorder_dump."+name
    for key,full in codes.items():
        if full==target: return key
    raise KeyError(name)
def val(name,t):
    out="0"
    for when,value in changes[code(name)]:
        if when>t: break
        out=value
    return out
def num(name,t):
    raw=val(name,t)
    return 0 if any(c in raw.lower() for c in "xz") else int(raw,2)

rises=[t for t,v in changes[code("clk")] if v=="1"][:40]
x=list(range(len(rises)))
signals=["rst_n","ar_valid","ar_ready","mem_req_valid","mem_req_ready","mem_rsp_valid","r_valid","r_ready"]
fig,axes=plt.subplots(len(signals)+1,1,figsize=(20,11),sharex=True,constrained_layout=True,
  gridspec_kw={"height_ratios":[1]*len(signals)+[2.8]})
for ax,name in zip(axes,signals):
    ax.step(x,[num(name,t) for t in rises],where="post",linewidth=2)
    ax.set_ylim(-.15,1.15); ax.set_yticks([0,1]); ax.grid(axis="x",alpha=.25)
    ax.set_ylabel(name,rotation=0,ha="right",va="center",fontsize=8)
ax=axes[-1]; ax.set_ylim(-.5,.5); ax.set_yticks([]); ax.grid(axis="x",alpha=.25)
ax.set_ylabel("ID / tag / data\noccupancy",rotation=0,ha="right",va="center",fontsize=8)
for i,t in enumerate(rises):
    label=f"occ={num('occupancy',t)}"
    if num("ar_valid",t) and num("ar_ready",t): label+=f"\nAR id{num('ar_id',t)} @{num('ar_addr',t):04x}"
    if num("mem_rsp_valid",t): label+=f"\nMEM tag{num('mem_rsp_tag',t)}"
    if num("r_valid",t): label+=f"\nR id{num('r_id',t)} {num('r_data',t):08x}"+(" ERR" if num("r_error",t) else "")
    ax.text(i,0,label,ha="center",va="center",fontsize=5.8,family="monospace")
axes[-1].set_xlabel("Captured rising-edge cycle")
fig.suptitle("Day 36 — AXI Multi-ID Read Reorder: out-of-order memory completion, per-ID retirement",fontsize=14)
out=Path(__file__).with_name("axi_read_reorder_waveform.png")
fig.savefig(out,dpi=170); print(out)
