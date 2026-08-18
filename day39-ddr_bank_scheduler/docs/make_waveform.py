# Author: Asresh Kuricheti
"""Render selected signals from the real Icarus VCD as a readable PNG."""
import sys
import matplotlib.pyplot as plt

path=sys.argv[1]
want=["clk","rst_n","req_valid","req_ready","req_write","req_addr","cmd_valid","cmd_ready","cmd","cmd_bank","cmd_row","req_done"]
bus={"req_addr","cmd","cmd_bank","cmd_row"}
codes,names,events={},{},{}
with open(path,encoding="utf-8") as f:
    for line in f:
        p=line.split()
        if len(p)>=5 and p[0]=="$var":
            code,name=p[3],p[4]
            if name in want:codes[code]=name;names[name]=code;events[code]=[]
        elif line.startswith("#"):t=int(line[1:])
        elif line and line[0] in "01xz" and line[1:].strip() in codes:events[line[1:].strip()].append((t,1 if line[0]=="1" else 0))
        elif line.startswith("b"):
            value,code=line.split()
            if code in codes:events[code].append((t,int(value[1:].replace("x","0").replace("z","0"),2)))
fig,axes=plt.subplots(len(want),1,figsize=(14,10),sharex=True)
for ax,name in zip(axes,want):
    ev=[(t/1000.0,v) for t,v in events.get(names.get(name,""),[]) if t<=650000]
    if ev:ax.step([x for x,_ in ev],[y for _,y in ev],where="post",linewidth=1.4)
    if name not in bus:ax.set_ylim(-.2,1.2);ax.set_yticks([0,1])
    ax.set_ylabel(name,rotation=0,ha="right",va="center",fontsize=8);ax.grid(alpha=.25)
axes[-1].set_xlabel("Simulation time (ns)");fig.suptitle("DDR bank scheduler: captured requests, command backpressure, timing waits, and completion")
fig.tight_layout();fig.savefig("docs/ddr_bank_scheduler_waveform.png",dpi=170);print("wrote docs/ddr_bank_scheduler_waveform.png")
