#!/usr/bin/env python3
"""
Day32 - mutation test for the MESI coherence checker.

A green regression proves nothing on its own: it might mean the design is
right, or it might mean the checker cannot tell the difference.  This script
introduces one realistic single-line coherence bug at a time into
mesi_cache.sv, re-runs the self-checking testbench, and requires every one of
them to FAIL.  A mutant that survives is a hole in the verification, not a
harmless variation.

Run from the Day32 directory:   python3 docs/mutation_test.py
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
DUT = HERE / "mesi_cache.sv"
SRCS = ["mesi_ref_pkg.sv", "MUTANT.sv", "tb_mesi_cache_dump.sv"]

# (name, what a real engineer would have typed by mistake, from, to)
MUTANTS = [
    (
        "read miss always installs S (MESI degraded to MSI)",
        "the E state is never entered, so every store to a privately-read line "
        "pays for a BusUpgr it does not need",
        "state_q[acc_idx] <= fill_shared ? ST_S : ST_E;",
        "state_q[acc_idx] <= ST_S;",
    ),
    (
        "read miss always installs E (shared line claimed exclusively)",
        "a line another cache is already holding gets claimed exclusively - "
        "two caches now believe they may write it without telling anyone",
        "state_q[acc_idx] <= fill_shared ? ST_S : ST_E;",
        "state_q[acc_idx] <= ST_E;",
    ),
    (
        "remote read invalidates instead of downgrading",
        "BusRd throws the line away rather than dropping to S - correct, but "
        "needlessly destroys the sharing the protocol exists to allow",
        "BUSRD  : snoop_ns = ST_S;",
        "BUSRD  : snoop_ns = ST_I;",
    ),
    (
        "remote store downgrades instead of invalidating",
        "BusRdX leaves a stale readable copy behind while another core writes "
        "the line - the textbook coherence violation",
        "BUSRDX : snoop_ns = ST_I;",
        "BUSRDX : snoop_ns = ST_S;",
    ),
    (
        "dirty owner never flushes",
        "an M line is silently dropped to S without pushing its data out, so "
        "the requester and DRAM both get the stale value",
        "snp_dirty <= snoop_match && (state_q[snp_idx] == ST_M) &&",
        "snp_dirty <= 1'b0 && (state_q[snp_idx] == ST_M) &&",
    ),
    (
        "writeback uses the new tag instead of the resident one",
        "the dirty victim's data is written back to the address that is "
        "replacing it - loads keep working while DRAM quietly rots",
        "pend_addr  <= {tag_q[acc_idx], acc_idx};",
        "pend_addr  <= req_addr;",
    ),
    (
        "store on a shared line treated as a hit",
        "a store to S completes locally without a BusUpgr, so the other "
        "sharers keep serving the old value",
        "end else if (acc_writeable) begin",
        "end else if (1'b1) begin",
    ),
    (
        "queued BusUpgr is not downgraded after being invalidated",
        "a cache that lost its copy while waiting for the bus still issues an "
        "upgrade, claiming ownership of a line it no longer holds",
        "if (upgr_killed)\n            pend_cmd <= BUSRDX;",
        "if (1'b0)\n            pend_cmd <= BUSRDX;",
    ),
    (
        "tag compare ignores the tag (index-only hit)",
        "any address mapping to a resident set reports a hit, returning "
        "another address's data entirely",
        "wire       acc_hit   = (acc_state != ST_I) && (tag_q[acc_idx] == acc_tag);",
        "wire       acc_hit   = (acc_state != ST_I);",
    ),
]


def run(workdir: Path) -> str:
    """Build and run the testbench in workdir; return combined output."""
    build = subprocess.run(
        ["iverilog", "-g2012", "-o", "simv_mut"] + SRCS,
        cwd=workdir, capture_output=True, text=True,
    )
    if build.returncode != 0:
        return "BUILD FAILED\n" + build.stdout + build.stderr
    sim = subprocess.run(
        ["vvp", "simv_mut"], cwd=workdir,
        capture_output=True, text=True, timeout=900,
    )
    return sim.stdout + sim.stderr


def main() -> int:
    golden = DUT.read_text()

    with tempfile.TemporaryDirectory() as td:
        work = Path(td)
        for name in ("mesi_ref_pkg.sv", "tb_mesi_cache_dump.sv"):
            (work / name).write_text((HERE / name).read_text())

        # ---- baseline: the unmutated design must PASS ----
        (work / "MUTANT.sv").write_text(golden)
        out = run(work)
        if "RESULT: *** PASS ***" not in out:
            print("baseline FAILED - fix the design before mutation testing")
            print(out[-3000:])
            return 1
        print("baseline (unmutated)                                        PASS\n")

        print(f"{'mutant':<58} {'verdict':<8} caught by")
        print("-" * 100)

        survivors = []
        for name, _why, frm, to in MUTANTS:
            if frm not in golden:
                print(f"{name:<58} {'SKIP':<8} anchor text not found")
                survivors.append(name)
                continue
            (work / "MUTANT.sv").write_text(golden.replace(frm, to, 1))
            out = run(work)

            if "RESULT: *** FAIL ***" in out or "BUILD FAILED" in out:
                # report the first thing that noticed
                first = ""
                for line in out.splitlines():
                    if "[ERROR]" in line:
                        first = line.split("]", 2)[-1].strip()
                        break
                if not first and "COVERAGE HOLE" in out:
                    for i, line in enumerate(out.splitlines()):
                        if "COVERAGE HOLE" in line:
                            first = "coverage hole: " + out.splitlines()[i - 1].strip()
                            break
                if not first:
                    first = "build error" if "BUILD FAILED" in out else "(unattributed)"
                print(f"{name:<58} {'caught':<8} {first[:70]}")
            else:
                print(f"{name:<58} {'SURVIVED':<8} <-- verification hole")
                survivors.append(name)

        print("-" * 100)
        if survivors:
            print(f"\n{len(survivors)} mutant(s) survived:")
            for s in survivors:
                print("  -", s)
            return 1
        print(f"\nall {len(MUTANTS)} mutants caught")
        return 0


if __name__ == "__main__":
    sys.exit(main())
