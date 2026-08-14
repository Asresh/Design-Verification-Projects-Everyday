#!/usr/bin/env python3
"""Author: Asresh Kuricheti. Render a real Icarus-captured TLB waveform."""
import sys
from pathlib import Path
import matplotlib.pyplot as plt

vcd=Path(sys.argv[1] if len(sys.argv)>1 else "tb_i_tlb_dump.vcd")
codes,changes,scope,now={}, {}, [], 0
for raw in vcd.read_text().splitlines():
    line=raw.strip()
    if line.startswith("$scope"): scope.append(line.split()[2])
    elif line.startswith("$upscope"): scope.pop()
    elif line.startswith("$var"):
        p=line.split();name=p[4]
        if p[3] not in codes: codes[p[3]]=".".join(scope+[name])
        changes.setdefault(p[3],[])
    elif line.startswith("#"): now=int(line[1:])
    elif line and line[0] in "01xz" and line[1:] in changes: changes[line[1:]].append((now,line[0]))
    elif line.startswith("b"):
        bits,code=line[1:].split()
        if code in changes: changes[code].append((now,bits))

def code(name):
    for c,n in codes.items():
        if n=="tb_i_tlb_dump."+name:return c
    raise KeyError(name)
def val(name,t):
    out="0"
    for ct,cv in changes[code(name)]:
        if ct>t:break
        out=cv
    return out
def num(name,t):
    v=val(name,t)
    return 0 if any(x in v.lower() for x in "xz") else int(v,2)

rises=[t for t,v in changes[code("clk")] if v=="1"][2:34]
x=list(range(len(rises)))
signals=["rst_n","fill_valid","query_valid","query_hit","query_exec_fault","inv_valid"]
fig,axes=plt.subplots(len(signals)+1,1,figsize=(18,9),sharex=True,constrained_layout=True,
                     gridspec_kw={"height_ratios":[1]*len(signals)+[2.5]})
for ax,name in zip(axes,signals):
    ys=[num(name,t) for t in rises];ax.step(x,ys,where="post",linewidth=2)
    ax.set_ylim(-.15,1.15);ax.set_yticks([0,1]);ax.set_ylabel(name,rotation=0,ha="right",va="center",fontsize=9);ax.grid(axis="x",alpha=.25)
ax=axes[-1];ax.set_ylim(-.5,.5);ax.set_yticks([]);ax.set_ylabel("operation\naddress/result",rotation=0,ha="right",va="center",fontsize=9);ax.grid(axis="x",alpha=.25)
for i,t in enumerate(rises):
    if num("fill_valid",t): text=f"FILL a{num('fill_asid',t):02x}\nVA {num('fill_vaddr',t):08x}\nPA {num('fill_paddr',t):08x}"
    elif num("query_valid",t): text=f"QUERY a{num('query_asid',t):02x}\nVA {num('query_vaddr',t):08x}\n"+(f"PA {num('query_paddr',t):08x}" if num('query_hit',t) else "MISS")
    elif num("inv_valid",t): text="INV ALL" if num("inv_all",t) else f"INV a{num('inv_asid',t):02x}\nVA {num('inv_vaddr',t):08x}"
    else:text="—"
    ax.text(i,0,text,ha="center",va="center",fontsize=6.3,family="monospace")
axes[-1].set_xlabel("Captured rising-edge cycle")
fig.suptitle("Day 34 — Instruction TLB: fill, ASID isolation, superpage translation, permission fault, and invalidation",fontsize=14)
out=Path(__file__).with_name("i_tlb_waveform.png");fig.savefig(out,dpi=170);print(out)
