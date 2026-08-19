#!/usr/bin/env python3
"""Author: Asresh Kuricheti. Render the real Icarus-captured PTW waveform."""
import sys
from pathlib import Path
import matplotlib.pyplot as plt

vcd = Path(sys.argv[1] if len(sys.argv) > 1 else "tb_page_table_walker_dump.vcd")
codes, changes, scope, now = {}, {}, [], 0
for raw in vcd.read_text().splitlines():
    line = raw.strip()
    if line.startswith("$scope"):
        scope.append(line.split()[2])
    elif line.startswith("$upscope"):
        scope.pop()
    elif line.startswith("$var"):
        parts = line.split()
        if parts[3] not in codes:
            codes[parts[3]] = ".".join(scope + [parts[4]])
        changes.setdefault(parts[3], [])
    elif line.startswith("#"):
        now = int(line[1:])
    elif line and line[0] in "01xz" and line[1:] in changes:
        changes[line[1:]].append((now, line[0]))
    elif line.startswith("b"):
        bits, code = line[1:].split()
        if code in changes:
            changes[code].append((now, bits))

def signal_code(name):
    exact = f"tb_page_table_walker_dump.{name}"
    for code, full_name in codes.items():
        if full_name == exact:
            return code
    raise KeyError(name)

def value(name, tick):
    result = "0"
    for change_tick, change_value in changes[signal_code(name)]:
        if change_tick > tick:
            break
        result = change_value
    return result

def number(name, tick):
    raw = value(name, tick)
    return 0 if any(ch in raw.lower() for ch in "xz") else int(raw, 2)

rising_edges = [tick for tick, val in changes[signal_code("clk")] if val == "1"]
rising_edges = rising_edges[2:74]
cycles = list(range(len(rising_edges)))
digital = ["rst_n", "req_valid", "req_ready", "mem_req_valid", "mem_req_ready", "mem_rsp_valid", "rsp_valid", "rsp_fault"]
fig, axes = plt.subplots(
    len(digital) + 1, 1, figsize=(20, 11), sharex=True, constrained_layout=True,
    gridspec_kw={"height_ratios": [1] * len(digital) + [3.0]},
)
for axis, name in zip(axes, digital):
    samples = [number(name, tick) for tick in rising_edges]
    axis.step(cycles, samples, where="post", linewidth=2)
    axis.set_ylim(-0.15, 1.15)
    axis.set_yticks([0, 1])
    axis.set_ylabel(name, rotation=0, ha="right", va="center", fontsize=9)
    axis.grid(axis="x", alpha=0.25)

bus_axis = axes[-1]
bus_axis.set_ylim(-0.5, 0.5)
bus_axis.set_yticks([])
bus_axis.set_ylabel("walk event\naddress / PTE / result", rotation=0, ha="right", va="center", fontsize=9)
bus_axis.grid(axis="x", alpha=0.25)
for i, tick in enumerate(rising_edges):
    label = ""
    if number("req_valid", tick) and number("req_ready", tick):
        kinds = ["RD", "WR", "EX"]
        access = number("req_access", tick)
        label = f"{kinds[access]} VA\n{number('req_vaddr',tick):08x}"
    if number("mem_req_valid", tick) and number("mem_req_ready", tick):
        label = f"PTE REQ\n{number('mem_req_addr',tick):09x}"
    if number("mem_rsp_valid", tick):
        label = f"PTE RSP\n{number('mem_rsp_pte',tick):08x}"
    if number("rsp_valid", tick):
        if number("rsp_fault", tick):
            label = f"FAULT {number('rsp_fault_code',tick)}\nL{number('rsp_leaf_level',tick)}"
        else:
            label = f"PA {number('rsp_paddr',tick):09x}\nL{number('rsp_leaf_level',tick)} leaf"
    if label:
        bus_axis.text(i, 0, label, ha="center", va="center", fontsize=6.5, family="monospace")

axes[-1].set_xlabel("Captured rising-edge cycle")
fig.suptitle("Day 40 — Two-level page-table walk: memory stalls, 4 KiB/4 MiB leaves, and fault classification", fontsize=14)
output = Path(__file__).with_name("page_table_walker_waveform.png")
fig.savefig(output, dpi=170)
print(output)
