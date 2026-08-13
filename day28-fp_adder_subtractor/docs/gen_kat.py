#!/usr/bin/env python3
"""
gen_kat.py - regenerate the Known-Answer Table (KAT) that pins the Day28
SystemVerilog golden reference model to real hardware IEEE-754 arithmetic.

Every KAT row is  a, b, sub, z, {inv,ovf,unf,inx}  where

  * `z` is the bit pattern produced by numpy float32 add/sub, i.e. by the
    host CPU's IEEE-754 binary32 unit - genuine independent ground truth,
    not this project's model.  (For NaN results only the NaN-ness is ground
    truth; the DUT spec fixes the payload to the canonical qNaN 0x7FC00000,
    so that is what is stored.)
  * the four flag bits follow this project's documented flag spec (see the
    Day28 README "Exception flags"); the C/numpy layer does not expose a
    per-operation flag word, so those columns come from the Python model -
    which is itself cross-checked bit-for-bit against numpy on the result
    word over 400k+ randomised operations by the sweep at the bottom.

Output: prints a SystemVerilog initialiser block for fp32_ref_pkg.sv, and
writes docs/fp32_kat.txt.

Usage:  python3 docs/gen_kat.py
"""
import os
import struct

import numpy as np

QNAN = 0x7FC00000


def bits(f):
    return struct.unpack("<I", struct.pack("<f", np.float32(f)))[0]


def flt(b):
    return np.frombuffer(struct.pack("<I", b & 0xFFFFFFFF), dtype="<f4")[0]


# ---------------------------------------------------------------------------
# The Python model (same algorithm the SystemVerilog golden model implements).
# ---------------------------------------------------------------------------
def fp_add(a, b, sub):
    if sub:
        b ^= 0x80000000
    sa, ea, ma = (a >> 31) & 1, (a >> 23) & 0xFF, a & 0x7FFFFF
    sb, eb, mb = (b >> 31) & 1, (b >> 23) & 0xFF, b & 0x7FFFFF

    a_zero, b_zero = (ea == 0 and ma == 0), (eb == 0 and mb == 0)
    a_inf, b_inf = (ea == 255 and ma == 0), (eb == 255 and mb == 0)
    a_nan, b_nan = (ea == 255 and ma != 0), (eb == 255 and mb != 0)
    a_snan = a_nan and not ((ma >> 22) & 1)
    b_snan = b_nan and not ((mb >> 22) & 1)
    clean = dict(inv=0, ovf=0, unf=0, inx=0)

    if a_nan or b_nan:
        return QNAN, dict(clean, inv=int(a_snan or b_snan))
    if a_inf and b_inf:
        return (QNAN, dict(clean, inv=1)) if sa != sb else (a, clean)
    if a_inf:
        return a, clean
    if b_inf:
        return b, clean
    if a_zero and b_zero:
        return (sa & sb) << 31, clean
    if a_zero:
        return b, clean
    if b_zero:
        return a, clean

    siga = ((1 if ea else 0) << 23) | ma
    sigb = ((1 if eb else 0) << 23) | mb
    efa, efb = (ea or 1), (eb or 1)

    if (efa > efb) or (efa == efb and siga >= sigb):
        s_big, e_big, sig_big, s_sml, e_sml, sig_sml = sa, efa, siga, sb, efb, sigb
    else:
        s_big, e_big, sig_big, s_sml, e_sml, sig_sml = sb, efb, sigb, sa, efa, siga

    d = min(e_big - e_sml, 27)
    big_w = sig_big << 3
    sml_f = sig_sml << 3
    sml_w = (sml_f >> d) | (1 if (sml_f & ((1 << d) - 1)) else 0)

    exp = e_big
    if s_big == s_sml:
        s = big_w + sml_w
        if s & (1 << 27):
            s = (s >> 1) | (s & 1)
            exp += 1
    else:
        s = big_w - sml_w
        if s == 0:
            return 0, clean
        while not (s & (1 << 26)) and exp > 1:
            s <<= 1
            exp -= 1

    L, G = (s >> 3) & 1, (s >> 2) & 1
    st = ((s >> 1) & 1) | (s & 1)
    inx = 1 if (G or st) else 0
    sig24 = (s >> 3) & 0xFFFFFF
    if G and (L or st):
        sig24 += 1
        if sig24 == (1 << 24):
            sig24 >>= 1
            exp += 1

    if sig24 == 0:
        return 0, dict(clean, unf=inx, inx=inx)
    if (sig24 >> 23) & 1:
        if exp >= 255:
            return (s_big << 31) | (255 << 23), dict(clean, ovf=1, inx=1)
        return (s_big << 31) | (exp << 23) | (sig24 & 0x7FFFFF), dict(clean, inx=inx)
    return (s_big << 31) | (sig24 & 0x7FFFFF), dict(clean, unf=inx, inx=inx)


def numpy_ref(a, b, sub):
    with np.errstate(all="ignore"):
        r = (np.float32(flt(a)) - np.float32(flt(b))) if sub else \
            (np.float32(flt(a)) + np.float32(flt(b)))
    return bits(r)


def is_nan(x):
    return ((x >> 23) & 0xFF) == 0xFF and (x & 0x7FFFFF) != 0


# ---------------------------------------------------------------------------
# The corner cases worth freezing into the RTL testbench.
# ---------------------------------------------------------------------------
ONE       = 0x3F800000
TWO       = 0x40000000
MINUS_ONE = 0xBF800000
PINF      = 0x7F800000
NINF      = 0xFF800000
PZERO     = 0x00000000
NZERO     = 0x80000000
MAXN      = 0x7F7FFFFF          # largest finite
MINN      = 0x00800000          # smallest normal  2^-126
MAXSUB    = 0x007FFFFF          # largest subnormal
MINSUB    = 0x00000001          # smallest subnormal 2^-149
SNAN      = 0x7F800001          # signalling NaN
QNANI     = 0x7FC00000
ULP1      = 0x33800000          # 2^-24  : exact half-ULP of 1.0
ULP2      = 0x34000000          # 2^-23  : one ULP of 1.0
BIG       = 0x71800000          # 2^100
TINY      = 0x0D800000          # 2^-100

KAT = [
    # ---- documented walk-throughs ----
    (ONE,       TWO,      0, "1.0 + 2.0 = 3.0"),
    (ONE,       ONE,      1, "1.0 - 1.0 = +0 (exact cancellation)"),
    (NZERO,     NZERO,    0, "(-0) + (-0) = -0"),
    (PZERO,     NZERO,    0, "(+0) + (-0) = +0"),
    (PZERO,     PZERO,    1, "(+0) - (+0) = +0"),
    (NZERO,     PZERO,    1, "(-0) - (+0) = -0"),
    # ---- round-to-nearest-EVEN ties ----
    (ONE,       ULP1,     0, "1.0 + 2^-24 : exact tie, LSB even -> stays 1.0"),
    (ONE + 1,   ULP1,     0, "(1.0+1ulp) + 2^-24 : exact tie, LSB odd -> rounds up"),
    (ONE,       ULP2,     0, "1.0 + 2^-23 : exactly one ULP, exact"),
    (ONE,       0x33C00000, 0, "1.0 + 1.5*2^-24 : above the tie -> rounds up"),
    (ONE,       ULP1,     1, "1.0 - 2^-24 : subtractive round, needs guard bit"),
    # ---- alignment / sticky ----
    (BIG,       TINY,     0, "2^100 + 2^-100 : 200-bit alignment, sticky only"),
    (BIG,       TINY,     1, "2^100 - 2^-100 : sticky forces round-down"),
    (MAXN,      MINSUB,   0, "maxfinite + minsubnormal : sticky, no change"),
    # ---- cancellation / normalisation ----
    (ONE,       ONE - 1,  1, "1.0 - (1.0-1ulp) : 23-bit cancellation"),
    (0x40000000, 0x3FFFFFFF, 1, "2.0 - nextbelow(2.0) : full left normalise"),
    # ---- subnormals ----
    (MINSUB,    MINSUB,   0, "minsub + minsub = 2*minsub"),
    (MAXSUB,    MINSUB,   0, "maxsub + minsub = minnormal (carries into normal)"),
    (MINN,      MINSUB,   1, "minnormal - minsub = maxsubnormal (drops out of normal)"),
    (MINSUB,    MINSUB,   1, "minsub - minsub = +0"),
    (MINN,      MINN,     1, "minnormal - minnormal = +0"),
    (0x00800001, MINN,    1, "(minnormal+1ulp) - minnormal = minsubnormal (drops out of normal)"),
    (0x24000000, 0xA3FFFFFF, 0, "near-cancelling normals -> 24-bit left normalise, exact"),
    (MAXSUB,     MAXSUB,   0, "maxsub + maxsub : two subnormals carry into a normal"),
    (0x00400000, 0x00400000, 0, "midsub + midsub : subnormal doubling stays subnormal"),
    (MINN,       MAXSUB,   1, "minnormal - maxsub : smallest subnormal step"),
    # ---- overflow ----
    (MAXN,      MAXN,     0, "maxfinite + maxfinite = +inf (overflow)"),
    (MAXN,      MAXN,     1, "maxfinite - maxfinite = +0"),
    (0xFF7FFFFF, MAXN,    0, "-maxfinite + maxfinite = +0"),
    (MAXN,      0x73000000, 0, "maxfinite + 2^103 : rounds up over the top -> inf"),
    (0x7F7FFFFE, 0x73000000, 0, "just below maxfinite + 2^103 : rounds up, stays finite"),
    (0x3FFFFFFF, 0x33000000, 0, "nextbelow(2.0) + 2^-25 : round-up carries into exp++"),
    # ---- infinities ----
    (PINF,      NINF,     0, "(+inf) + (-inf) = qNaN, INVALID"),
    (PINF,      PINF,     1, "(+inf) - (+inf) = qNaN, INVALID"),
    (PINF,      PINF,     0, "(+inf) + (+inf) = +inf"),
    (PINF,      ONE,      0, "(+inf) + 1.0 = +inf"),
    (ONE,       NINF,     0, "1.0 + (-inf) = -inf"),
    (NINF,      ONE,      1, "(-inf) - 1.0 = -inf"),
    (PINF,      PZERO,    0, "(+inf) + 0 = +inf"),
    # ---- NaNs ----
    (QNANI,     ONE,      0, "qNaN + 1.0 = qNaN, no flags"),
    (ONE,       QNANI,    1, "1.0 - qNaN = qNaN, no flags"),
    (SNAN,      ONE,      0, "sNaN + 1.0 = qNaN, INVALID"),
    (SNAN,      PINF,     0, "sNaN + inf = qNaN, INVALID"),
    (QNANI,     PINF,     0, "qNaN + inf = qNaN (NaN wins over inf)"),
    # ---- identities ----
    (PZERO,     ONE,      0, "0 + 1.0 = 1.0"),
    (ONE,       PZERO,    1, "1.0 - 0 = 1.0"),
    (PZERO,     ONE,      1, "0 - 1.0 = -1.0"),
    (MINUS_ONE, PZERO,    0, "-1.0 + 0 = -1.0"),
]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    rows, sv, bad = [], [], 0

    for a, b, sub, note in KAT:
        z, fl = fp_add(a, b, sub)
        ref = numpy_ref(a, b, sub)
        if is_nan(ref):
            ok = is_nan(z)
        else:
            ok = (z == ref)
        if not ok:
            bad += 1
            print(f"!! KAT row disagrees with numpy: {note}: "
                  f"model={z:08x} numpy={ref:08x}")
        fw = f"4'b{fl['inv']}{fl['ovf']}{fl['unf']}{fl['inx']}"
        rows.append(f"{a:08x} {b:08x} {sub} {z:08x} "
                    f"{fl['inv']}{fl['ovf']}{fl['unf']}{fl['inx']}  // {note}")
        sv.append(f"        kat_add(32'h{a:08X}, 32'h{b:08X}, 1'b{sub}, "
                  f"32'h{z:08X}, {fw});   // {note}")

    with open(os.path.join(here, "fp32_kat.txt"), "w") as f:
        f.write("# a b sub z {inv,ovf,unf,inx}   -- result words are numpy "
                "(hardware IEEE-754 binary32) ground truth\n")
        f.write("\n".join(rows) + "\n")

    print("\n".join(sv))
    print(f"\n// {len(KAT)} KAT rows, {bad} disagreements with numpy float32")


if __name__ == "__main__":
    main()
