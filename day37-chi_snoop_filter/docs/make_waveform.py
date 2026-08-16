# Author: Asresh Kuricheti
"""Render selected signals from the real Icarus VCD into a waveform PNG."""
import sys
from pathlib import Path
import matplotlib.pyplot as plt

vcd=Path(sys.argv[1] if len(sys.argv)>1 else "tb_chi_snoop_filter_dump.vcd")
codes,names={},{}; changes={}
with vcd.open() as f:
    scope=[]; t=0
    for raw in f:
        s=raw.strip()
        if s.startswith("$scope"): scope.append(s.split()[2])
        elif s.startswith("$upscope") and scope: scope.pop()
        elif s.startswith("$var"):
            p=s.split(); code=p[3]; name=p[4]; full=".".join(scope+[name]);codes[code]=full;names.setdefault(name,code);changes.setdefault(code,[])
        elif s.startswith("#"): t=int(s[1:])
        elif s and s[0] in "01xz" and s[1:] in changes: changes[s[1:]].append((t,s[0]))
        elif s.startswith("b"):
            p=s.split()
            if len(p)==2 and p[1] in changes: changes[p[1]].append((t,p[0][1:]))

signals=["clk","rst_n","req_valid","req_ready","req_op","req_node","req_addr","rsp_valid","rsp_ready","dir_hit","snoop_valid","snoop_mask","snoop_invalidate","new_sharers"]
def value_at(code,t):
    v="x"
    for ts,x in changes.get(code,[]):
        if ts>t: break
        v=x
    return v
max_t=min(max((a for c in changes.values() for a,_ in c),default=1),250)
fig,axes=plt.subplots(len(signals),1,figsize=(14,10),sharex=True,gridspec_kw={"hspace":0.05})
for ax,name in zip(axes,signals):
    code=names.get(name); pts=changes.get(code,[]); times=sorted({0,max_t,*[t for t,_ in pts if t<=max_t]})
    vals=[value_at(code,t) for t in times]
    if name in {"clk","rst_n","req_valid","req_ready","rsp_valid","rsp_ready","dir_hit","snoop_valid","snoop_invalidate"}:
        y=[1 if v=="1" else 0 for v in vals];ax.step(times,y,where="post",lw=1.4);ax.set_ylim(-.2,1.2);ax.set_yticks([])
    else:
        ax.set_ylim(0,1);ax.set_yticks([])
        for j in range(len(times)-1):
            ax.hlines(.5,times[j],times[j+1],lw=2); v=vals[j]
            if times[j+1]-times[j]>15: ax.text((times[j]+times[j+1])/2,.58,(hex(int(v,2)) if v not in ('x','z') else v),ha="center",fontsize=7)
    ax.set_ylabel(name,rotation=0,ha="right",va="center",fontsize=8);ax.grid(axis="x",alpha=.2)
axes[-1].set_xlabel("simulation time (ns)");fig.suptitle("Day 37: CHI-style snoop-filter regression (real Icarus VCD)");fig.tight_layout(rect=[0,0,1,.98]);fig.savefig(Path(__file__).with_name("chi_snoop_filter_waveform.png"),dpi=180,bbox_inches="tight")
