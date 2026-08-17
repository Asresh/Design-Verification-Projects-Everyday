# Author: Asresh Kuricheti
"""Render selected signals from a real Icarus VCD into a readable PNG."""
import sys
import matplotlib.pyplot as plt

path = sys.argv[1]
want = ["rst_n","desc_valid","desc_ready","rd_valid","rd_ready","rd_data_valid","wr_valid","wr_ready","wr_last","done","error"]
codes,names,events={}, {}, {}
with open(path,encoding="utf-8") as f:
    for line in f:
        p=line.split()
        if len(p)>=5 and p[0]=="$var":
            code,name=p[3],p[4]
            if name in want: codes[code]=name;names[name]=code;events[code]=[]
        elif line.startswith("#"): t=int(line[1:])
        elif line and line[0] in "01xz" and line[1:].strip() in codes:
            events[line[1:].strip()].append((t,1 if line[0]=="1" else 0))
fig,axes=plt.subplots(len(want),1,figsize=(13,8),sharex=True)
for ax,name in zip(axes,want):
    ev=events.get(names.get(name,""),[]);ev=[(t/1000.0,v) for t,v in ev if t<=1_600_000]
    if ev: ax.step([x for x,_ in ev],[y for _,y in ev],where="post",linewidth=1.4)
    ax.set_ylim(-.2,1.2);ax.set_yticks([0,1]);ax.set_ylabel(name,rotation=0,ha="right",va="center",fontsize=8);ax.grid(alpha=.25)
axes[-1].set_xlabel("Simulation time (ns)");fig.suptitle("Scatter-Gather DMA: captured descriptor, read, write, backpressure, and completion activity")
fig.tight_layout();fig.savefig("docs/dma_engine_waveform.png",dpi=170);print("wrote docs/dma_engine_waveform.png")
