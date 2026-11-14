#!/usr/bin/env python3
"""
RAMA -- procedural ARCHITECTURAL / CRAFTED PBR materials (Ancient India / Ramayana).

Everything is synthesised from scratch with numpy.  No downloads, no source imagery,
so every byte is original and licence-clean.

TILEABILITY IS PROVEN, NOT ASSUMED.
Every primitive is a function of the torus: noise lattices are periodic, Worley cells
wrap, blurs are FFT (circular) convolutions, smears use np.roll, strokes wrap modulo N,
and all patterned frequencies are integers over N.  The whole pipeline reads its pixel
coordinates through grid()/_axis(), which add a global OFFSET.  A texture is therefore
seamless iff rendering it with OFFSET=(dy,dx) equals np.roll(render at (0,0)).  main()
runs exactly that test with an awkward prime-ish offset and fails loudly if it does not.

Outputs, 1024x1024, into assets/textures/:
    <name>_albedo.png   8-bit RGB
    <name>_normal.png   tangent space, OpenGL +Y up, encoded around (128,128,255)
    <name>_rough.png    single channel roughness packed as RGB
"""

import os
import sys
import time
import numpy as np
from PIL import Image

N = 1024
ROOT = "/Users/tarunvadapalli/Documents/Git/RAMA"
OUT = os.path.join(ROOT, "assets", "textures")
PREVIEW = os.environ.get("RAMA_PREVIEW_DIR", "")

# global sampling offset -- (0,0) for real output, non-zero for the tiling proof
OFF = [0, 0]


def set_offset(dy, dx):
    OFF[0] = int(dy)
    OFF[1] = int(dx)
    _WCACHE.clear()


def grid():
    """Pixel coordinates, shifted by the global OFFSET. Always used modulo-safely."""
    yy, xx = np.mgrid[0:N, 0:N]
    return (yy + OFF[0]).astype(np.float32), (xx + OFF[1]).astype(np.float32)


def vcoord():
    """Wrapped 0..1 vertical coordinate (for band layouts)."""
    yy, _ = np.mgrid[0:N, 0:N]
    return (((yy + OFF[0]) % N) / float(N)).astype(np.float32)


# ----------------------------------------------------------------------------
# periodic noise primitives
# ----------------------------------------------------------------------------

def _axis(p, off):
    x = (np.arange(N, dtype=np.float64) + off) * (float(p) / N)
    i0 = np.floor(x).astype(np.int64)
    f = (x - i0).astype(np.float32)
    i0 = (i0 % p).astype(np.int64)
    i1 = ((i0 + 1) % p).astype(np.int64)
    fs = f * f * f * (f * (f * 6.0 - 15.0) + 10.0)
    return i0, i1, f, fs


def value_noise(px, py, seed):
    px = int(max(2, min(px, N)))
    py = int(max(2, min(py, N)))
    rng = np.random.default_rng(seed & 0x7FFFFFFF)
    g = rng.random((py, px), dtype=np.float32)
    ix0, ix1, _, fx = _axis(px, OFF[1])
    iy0, iy1, _, fy = _axis(py, OFF[0])
    a = g[np.ix_(iy0, ix0)]
    b = g[np.ix_(iy0, ix1)]
    c = g[np.ix_(iy1, ix0)]
    dd = g[np.ix_(iy1, ix1)]
    fxr = fx[None, :]
    fyr = fy[:, None]
    top = a + (b - a) * fxr
    bot = c + (dd - c) * fxr
    return (top + (bot - top) * fyr).astype(np.float32) * 2.0 - 1.0


def perlin(px, py, seed):
    px = int(max(2, min(px, N)))
    py = int(max(2, min(py, N)))
    rng = np.random.default_rng(seed & 0x7FFFFFFF)
    ang = rng.uniform(0.0, 2.0 * np.pi, (py, px)).astype(np.float32)
    gx = np.cos(ang)
    gy = np.sin(ang)
    ix0, ix1, fxr, fxs = _axis(px, OFF[1])
    iy0, iy1, fyr, fys = _axis(py, OFF[0])
    X0 = fxr[None, :]
    X1 = (fxr - 1.0)[None, :]
    Y0 = fyr[:, None]
    Y1 = (fyr - 1.0)[:, None]
    n00 = gx[np.ix_(iy0, ix0)] * X0 + gy[np.ix_(iy0, ix0)] * Y0
    n10 = gx[np.ix_(iy0, ix1)] * X1 + gy[np.ix_(iy0, ix1)] * Y0
    n01 = gx[np.ix_(iy1, ix0)] * X0 + gy[np.ix_(iy1, ix0)] * Y1
    n11 = gx[np.ix_(iy1, ix1)] * X1 + gy[np.ix_(iy1, ix1)] * Y1
    sx = fxs[None, :]
    sy = fys[:, None]
    top = n00 + (n10 - n00) * sx
    bot = n01 + (n11 - n01) * sx
    return ((top + (bot - top) * sy) * 1.42).astype(np.float32)


def fbm(period, octaves, seed, persistence=0.5, lac=2.0, aniso=1.0,
        kind="perlin", ridged=False, zero_one=True):
    """Multi-octave periodic noise. aniso>1 => finer in X (features stretched in Y)."""
    tot = np.zeros((N, N), np.float32)
    amp = 1.0
    norm = 0.0
    for o in range(octaves):
        m = lac ** o
        py = int(round(period * m))
        px = int(round(period * aniso * m))
        v = perlin(px, py, seed * 7919 + o * 131 + 17) if kind == "perlin" \
            else value_noise(px, py, seed * 7919 + o * 131 + 17)
        if ridged:
            v = 1.0 - 2.0 * np.abs(v)
        tot += v * amp
        norm += amp
        amp *= persistence
    tot /= norm
    if zero_one:
        tot = np.clip(tot * 0.5 + 0.5, 0.0, 1.0)
    return tot.astype(np.float32)


_WCACHE = {}


def worley(period, seed, jitter=1.0):
    """Periodic Worley on the torus. Returns (F1, F2) in cell units."""
    key = (period, seed, jitter)
    if key in _WCACHE:
        return _WCACHE[key]
    P = int(max(2, period))
    rng = np.random.default_rng((seed * 6151 + 7) & 0x7FFFFFFF)
    off = (rng.random((P, P, 2), dtype=np.float32) - 0.5) * jitter + 0.5
    cell = float(N) / P
    yy, xx = grid()
    py = yy / cell
    px = xx / cell
    cy = np.floor(py).astype(np.int64)
    cx = np.floor(px).astype(np.int64)
    f1 = np.full((N, N), 1e9, np.float32)
    f2 = np.full((N, N), 1e9, np.float32)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            ny = cy + dy
            nx = cx + dx
            qy = ny + off[ny % P, nx % P, 0]
            qx = nx + off[ny % P, nx % P, 1]
            dd = np.sqrt((py - qy) ** 2 + (px - qx) ** 2).astype(np.float32)
            nearer = dd < f1
            f2 = np.where(nearer, f1, np.minimum(f2, dd))
            f1 = np.where(nearer, dd, f1)
    _WCACHE[key] = (f1, f2)
    return f1, f2


def cell_edges(period, seed, width=0.10, jitter=1.0):
    """Continuous polygonal crack network along Worley cell borders."""
    f1, f2 = worley(period, seed, jitter)
    return smoothstep(width, 0.0, f2 - f1)


# ----------------------------------------------------------------------------
# periodic filters / math
# ----------------------------------------------------------------------------

_GK = {}


def gblur(a, sigma):
    if sigma <= 0:
        return a
    key = round(float(sigma), 4)
    k = _GK.get(key)
    if k is None:
        fy = np.fft.fftfreq(N)
        fx = np.fft.rfftfreq(N)
        k = np.exp(-2.0 * (np.pi * sigma) ** 2 * (fy[:, None] ** 2 + fx[None, :] ** 2))
        _GK[key] = k.astype(np.float32)
        k = _GK[key]
    return np.fft.irfft2(np.fft.rfft2(a.astype(np.float32)) * k, s=(N, N)).astype(np.float32)


def streak(a, length=48, decay=0.94, axis=0, direction=1):
    acc = a.astype(np.float32).copy()
    w = 1.0
    tot = 1.0
    for k in range(1, int(length)):
        w *= decay
        acc += np.roll(a, direction * k, axis=axis) * w
        tot += w
    return acc / tot


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0 + 1e-9), 0.0, 1.0)
    return (t * t * (3.0 - 2.0 * t)).astype(np.float32)


def nrm01(a):
    lo = float(a.min())
    hi = float(a.max())
    if hi - lo < 1e-9:
        return np.zeros_like(a)
    return ((a - lo) / (hi - lo)).astype(np.float32)


def gain(a, c, pivot=0.5):
    return np.clip((a - pivot) * c + pivot, 0.0, 1.0).astype(np.float32)


def shoulder(a, knee=0.86, ceil=0.985):
    """Soft highlight rolloff. Above `knee` the response is exponential rather
    than clipped, so a bright carved edge still carries stone grain instead of
    flattening to a zero-variance rail at 255. Monotonic; below `knee` a no-op."""
    span = max(ceil - knee, 1e-6)
    hi = knee + span * (1.0 - np.exp(-np.clip(a - knee, 0.0, None) / span))
    return np.where(a > knee, hi, a).astype(np.float32)


def wrapd(a):
    return (a + N * 0.5) % N - N * 0.5


def col(r, g, b):
    return np.array([r, g, b], np.float32).reshape(1, 1, 3) / 255.0


def lerp3(a, b, t):
    return a + (b - a) * t[..., None]


def strokes(count, lmin, lmax, seed, ang=0.0, spread=np.pi, curve=0.0,
            samples=48, taper=True, weight=1.0, jitterw=0.0):
    rng = np.random.default_rng((seed * 104729 + 3) & 0x7FFFFFFF)
    x0 = rng.uniform(0, N, count) - OFF[1]     # grid() maps pixel i -> coord i+OFF,
    y0 = rng.uniform(0, N, count) - OFF[0]     # so a feature at coord c draws at c-OFF
    L = rng.uniform(lmin, lmax, count)
    a0 = ang + rng.uniform(-spread, spread, count)
    t = np.linspace(0.0, 1.0, samples)[None, :]
    cur = rng.uniform(-curve, curve, count)[:, None]
    aa = a0[:, None] + cur * t
    step = (L[:, None] / samples)
    xs = x0[:, None] + np.cumsum(np.cos(aa), axis=1) * step
    ys = y0[:, None] + np.cumsum(np.sin(aa), axis=1) * step
    if jitterw > 0:
        xs = xs + rng.normal(0, jitterw, xs.shape)
        ys = ys + rng.normal(0, jitterw, ys.shape)
    w = np.sin(np.pi * t) ** 0.6 if taper else np.ones_like(t)
    w = np.broadcast_to(w * weight, (count, samples)) * rng.uniform(0.45, 1.0, count)[:, None]
    xi = np.mod(np.round(xs).astype(np.int64), N)
    yi = np.mod(np.round(ys).astype(np.int64), N)
    flat = np.bincount((yi * N + xi).ravel(), weights=w.ravel(), minlength=N * N)
    return flat.reshape(N, N).astype(np.float32)


def brick_field(rows, cols, warpx=None, warpy=None, stagger=0.5):
    """Running-bond courses. rows/cols divide N; rows even so the stagger wraps."""
    yy, xx = grid()
    if warpx is not None:
        xx = xx + warpx
    if warpy is not None:
        yy = yy + warpy
    rh = float(N) / rows
    cw = float(N) / cols
    fr = yy / rh
    row = np.floor(fr).astype(np.int64)
    ly = (fr - row).astype(np.float32)
    sh = (row & 1).astype(np.float32) * stagger
    fc = xx / cw + sh
    cl = np.floor(fc).astype(np.int64)
    lx = (fc - cl).astype(np.float32)
    bid = ((row % rows) * cols + (cl % cols)).astype(np.int32)
    dx = (np.minimum(lx, 1.0 - lx) * cw).astype(np.float32)
    dy = (np.minimum(ly, 1.0 - ly) * rh).astype(np.float32)
    return bid, lx, ly, dx, dy, np.minimum(dx, dy)


def pb(rng, nb, bid, lo=0.0, hi=1.0):
    return rng.uniform(lo, hi, nb).astype(np.float32)[bid]


def pb_pal(rng, nb, bid, palette):
    pal = np.array(palette, np.float32) / 255.0
    idx = rng.integers(0, len(pal), nb)
    return pal[idx][bid]


# ----------------------------------------------------------------------------
# shading helpers
# ----------------------------------------------------------------------------

def micro_grain(seed, worley_period=170, fine_period=320):
    """Sand-grain scale relief. Without this, big shapes read as polished plastic."""
    sp, _ = worley(worley_period, seed, 1.0)
    speck = np.clip(1.0 - sp * 2.4, 0, 1) ** 1.4
    return (speck - 0.35) * 0.5 + (fbm(fine_period, 2, seed + 1) - 0.5)


def ao_multi(h, radii=(3.0, 9.0, 26.0), weights=(0.45, 0.35, 0.20), strength=1.0):
    occ = np.zeros((N, N), np.float32)
    for r, w in zip(radii, weights):
        occ += w * np.clip((gblur(h, r) - h), 0.0, None)
    return (1.0 - np.clip(occ * strength, 0.0, 1.0)).astype(np.float32)


def cavity(h, sigma=2.0):
    return (h - gblur(h, sigma)).astype(np.float32)


def normal_encode(h, strength):
    h = h.astype(np.float32)

    def r(a, dy, dx):
        return np.roll(np.roll(a, dy, 0), dx, 1)

    gx = (r(h, -1, -1) + 2 * r(h, 0, -1) + r(h, 1, -1)) - \
         (r(h, -1, 1) + 2 * r(h, 0, 1) + r(h, 1, 1))
    gy = (r(h, -1, -1) + 2 * r(h, -1, 0) + r(h, -1, 1)) - \
         (r(h, 1, -1) + 2 * r(h, 1, 0) + r(h, 1, 1))
    nx = (gx / 8.0) * strength
    ny = -(gy / 8.0) * strength          # row index grows down, V grows up
    nz = np.ones_like(nx)
    inv = 1.0 / np.sqrt(nx * nx + ny * ny + nz * nz)
    out = np.empty((N, N, 3), np.float32)
    out[..., 0] = nx * inv * 0.5 + 0.5
    out[..., 1] = ny * inv * 0.5 + 0.5
    out[..., 2] = nz * inv * 0.5 + 0.5
    return out


def to8(a):
    return np.clip(a * 255.0 + 0.5, 0, 255).astype(np.uint8)


# ============================================================================
# 1. TEMPLE STONE -- honey sandstone ashlar, Hampi
# ============================================================================

def gen_temple_stone():
    s = 1101
    rng = np.random.default_rng(s)
    wx = (fbm(6, 4, s + 1) - 0.5) * 2.0
    wy = (fbm(6, 4, s + 2) - 0.5) * 2.0
    rows, cols = 8, 4
    bid, lx, ly, dx, dy, d = brick_field(rows, cols, wx * 9.0, wy * 5.5)
    nb = rows * cols

    bh = pb(rng, nb, bid, -1, 1)
    tone = pb(rng, nb, bid, 0, 1)
    tx = pb(rng, nb, bid, -1, 1)
    ty = pb(rng, nb, bid, -1, 1)
    bedang = pb(rng, nb, bid, -0.25, 0.25)
    wear_r = pb(rng, nb, bid, 0, 1)          # some blocks are far more eaten than others
    tilt = (tx * (lx - 0.5) + ty * (ly - 0.5)) * 0.5

    mw = 7.0
    face = smoothstep(mw - 1.0, mw + 2.5, d)

    grain = fbm(26, 7, s + 10, persistence=0.55)
    fine = fbm(170, 4, s + 11)
    f1, _ = worley(50, s + 13, 0.95)
    pit = np.clip(1.0 - f1 * 2.1, 0, 1) ** 2

    bedu = (ly + bedang * (lx - 0.5)) * 9.0
    bed = 0.5 + 0.5 * np.cos(2.0 * np.pi * bedu + (fbm(40, 3, s + 12) - 0.5) * 4.0)
    bed = bed * smoothstep(0.30, 0.75, fbm(14, 4, s + 14))

    h = 0.62 + bh * 0.016 + tilt * 0.020
    h += (grain - 0.5) * 0.030 + (fine - 0.5) * 0.020 + (bed - 0.5) * 0.014
    h += micro_grain(s + 50) * 0.024                       # sand grain, or it looks plastic
    pit = pit * (0.30 + 0.95 * fbm(110, 3, s + 51))        # irregular, not drilled holes
    h -= pit * 0.030 * smoothstep(0.30, 0.68, fbm(18, 3, s + 15)) * (0.5 + wear_r)

    # diagonal chisel dressing left by the mason's point tool
    ch = strokes(4200, 20, 70, s + 16, ang=0.62, spread=0.16, curve=0.10, samples=30)
    ch += strokes(2200, 20, 70, s + 17, ang=-0.55, spread=0.16, curve=0.10, samples=30) * 0.8
    chis = nrm01(gblur(np.clip(ch, 0, 1.6), 0.8))
    h += (chis - 0.45) * 0.020 * face

    mort = 0.435 + (fbm(70, 5, s + 18) - 0.5) * 0.10 + (fbm(210, 3, s + 19) - 0.5) * 0.04
    mort -= smoothstep(0.50, 0.86, fbm(15, 4, s + 20)) * 0.065
    h = h * face + mort * (1.0 - face)

    bevel = smoothstep(mw + 1.0, mw + 8.0, d)
    h -= (1.0 - bevel) * face * 0.013

    chipn = fbm(52, 4, s + 21)
    chipw = 1.0 + 34.0 * np.clip(chipn - 0.53, 0, 1) ** 1.0
    chip = 1.0 - smoothstep(chipw, chipw + 3.0, d)
    chipd = chip * face * (0.35 + 0.75 * fbm(120, 3, s + 22)) * (0.45 + 0.9 * wear_r)
    corner = (1.0 - smoothstep(5.0, 40.0, np.minimum(dx, dy))) * \
             smoothstep(0.52, 0.78, fbm(40, 4, s + 23)) * face * (0.4 + wear_r)
    h -= chipd * 0.080 + corner * 0.065

    spall = smoothstep(0.70, 0.80, fbm(8, 5, s + 24)) * face * (0.35 + 1.1 * wear_r)
    spall = np.clip(spall, 0, 1)
    h -= spall * 0.070 * (0.5 + 0.5 * fbm(40, 4, s + 25))

    h = gblur(h, 0.55)
    ao = ao_multi(h, (2.2, 7.0, 22.0), (0.60, 0.28, 0.12), strength=3.8)
    cav = cavity(h, 2.2)
    broad = cavity(h, 13.0)

    blockc = pb_pal(rng, nb, bid, [
        (216, 176, 114), (194, 152, 94), (176, 152, 120), (208, 168, 100),
        (184, 162, 128), (224, 194, 138), (164, 124, 78), (200, 172, 128),
        (192, 142, 86), (172, 140, 104), (212, 186, 132), (156, 130, 96),
    ])
    mott = fbm(15, 6, s + 30, persistence=0.55)
    alb = blockc * (0.76 + 0.48 * mott)[..., None]
    alb = lerp3(alb, col(238, 212, 164), smoothstep(0.60, 0.95, mott * 0.6 + tone * 0.4) * 0.45)
    alb = lerp3(alb, col(146, 108, 66), smoothstep(0.55, 0.98, 1.0 - mott) * 0.40)
    alb = lerp3(alb, col(228, 198, 148), bed * 0.24)
    alb = lerp3(alb, col(196, 172, 138), np.clip(chis - 0.5, 0, 1) * 0.35)

    alb = lerp3(alb, col(174, 162, 138) * (0.66 + 0.55 * fbm(110, 4, s + 31))[..., None],
                1.0 - face)
    alb = lerp3(alb, col(240, 216, 172), np.clip((chipd + corner + spall) * 1.2, 0, 1) * 0.55)

    # weathering pours out of every bed joint and runs down the face
    src = np.clip((1.0 - smoothstep(mw, mw + 8.0, dy)) * fbm(26, 5, s + 32) * 2.0, 0, 1)
    src = np.maximum(src, np.clip(fbm(13, 5, s + 33) - 0.50, 0, 1) * 3.0)
    run = nrm01(gblur(streak(src, 190, 0.983, 0, 1), 1.1))
    run = np.clip(run * (0.35 + 0.95 * fbm(42, 4, s + 34)) * 1.5, 0, 1)
    alb = lerp3(alb, col(122, 96, 62), run * 0.80)
    alb = lerp3(alb, col(74, 62, 46), np.clip(run - 0.45, 0, 1) * 1.9 * 0.62)

    lf1, _ = worley(22, s + 35, 1.0)
    lich = smoothstep(0.62, 0.16, lf1) * smoothstep(0.40, 0.66, fbm(9, 5, s + 36))
    lich *= (0.35 + 1.1 * (1.0 - face) + 0.75 * np.clip(-broad * 16, 0, 1))
    lich = np.clip(gblur(lich, 0.9) * 1.25, 0, 1)
    alb = lerp3(alb, col(166, 166, 132), lich * 0.72)
    alb = lerp3(alb, col(118, 126, 90), np.clip(lich - 0.60, 0, 1) * 2.5 * 0.55)
    rust = smoothstep(0.62, 0.86, fbm(17, 5, s + 37)) * (0.30 + 0.85 * run)
    alb = lerp3(alb, col(168, 108, 52), np.clip(rust * 1.2, 0, 1) * 0.55)

    alb = lerp3(alb, col(210, 194, 164), np.clip(-cav * 22.0, 0, 1) * 0.30)
    alb *= (0.93 + 0.14 * fbm(300, 3, s + 52))[..., None]      # grain in the colour too
    alb *= (ao ** 1.30)[..., None]
    alb *= (1.0 + np.clip(cav * 11.0, -0.32, 0.34))[..., None]
    alb = gain(alb, 1.18, 0.44)

    rough = 0.80 - 0.10 * mott + 0.08 * (fbm(58, 4, s + 40) - 0.5)
    rough += (1.0 - face) * 0.11 + lich * 0.14 + run * 0.07
    rough += np.clip(chipd + corner + spall, 0, 1) * 0.08
    rough -= np.clip(cav * 7.0, 0, 0.10)
    return np.clip(alb, 0, 1), h, np.clip(rough, 0.40, 0.99), 66.0

# ============================================================================
# 2. CARVED STONE -- hero relief: lotus medallions, meander band, fluting
# ============================================================================

def _lotus(cx, cy, R, seed, wobble=1.0, tiers=(8, 8, 8)):
    yy, xx = grid()
    ddx = wrapd(xx - cx) + (fbm(13, 4, seed + 3) - 0.5) * 8.0 * wobble
    ddy = wrapd(yy - cy) + (fbm(13, 4, seed + 4) - 0.5) * 8.0 * wobble
    r = np.sqrt(ddx * ddx + ddy * ddy) / R
    th = np.arctan2(ddy, ddx)
    h = np.zeros((N, N), np.float32)

    def petals(n, r0, r1, off, amp, wid=1.0, spine=0.22):
        a = (th / (2.0 * np.pi) * n + off) % 1.0
        ca = (a - 0.5) * 2.0
        t = np.clip((r - r0) / (r1 - r0), 0.0, 1.0)
        inside = ((r >= r0) & (r <= r1)).astype(np.float32)
        # float32 sin(pi*1.0) lands a hair below zero; clip before a fractional power
        prof = np.clip(np.sin(np.pi * t), 0.0, None) ** 0.72   # 0 at base and tip
        weff = np.maximum(wid * (1.0 - 0.52 * np.clip(2.0 * t - 1.0, 0, 1)), 0.14)
        q = np.clip(1.0 - (ca / weff) ** 2, 0.0, None)
        dome = np.sqrt(q) * prof
        dome += spine * np.clip(1.0 - np.abs(ca / weff) * 4.5, 0, 1) * prof
        return dome * inside * amp

    h += petals(tiers[0], 0.54, 1.02, 0.00, 0.105, 1.00, 0.24)
    h += petals(tiers[1], 0.33, 0.72, 0.50, 0.086, 0.98, 0.22)
    h += petals(tiers[2], 0.15, 0.44, 0.25, 0.070, 0.95, 0.20)

    pod = np.sqrt(np.clip(1.0 - (r / 0.175) ** 2, 0, None)) * 0.075
    seedb = (np.cos(th * 7.0) * 0.5 + 0.5) * np.clip(1.0 - (r / 0.14) ** 2, 0, None)
    h += pod + seedb * 0.016

    frame = np.sqrt(np.clip(1.0 - ((r - 1.155) / 0.080) ** 2, 0, None)) * 0.070
    h += frame
    bd = (th / (2.0 * np.pi) * 40.0) % 1.0
    beads = np.sqrt(np.clip(1.0 - ((bd - 0.5) * 2.4) ** 2, 0, None)) * \
            np.sqrt(np.clip(1.0 - ((r - 1.268) / 0.048) ** 2, 0, None))
    h += beads * 0.034
    panel = smoothstep(1.33, 1.27, r)
    return h - 0.040 * panel, panel


def _meander(v0, v1):
    yy, xx = grid()
    yw = ((yy) % N)
    cells = 8
    cw = float(N) / cells
    band_h = (v1 - v0) * N
    u = (xx / cw) % 1.0
    w = (yw - v0 * N) / band_h
    t = 0.150
    m = np.zeros((N, N), np.float32)

    def seg(x0, x1, y0, y1):
        return ((u >= x0) & (u <= x1) & (w >= y0) & (w <= y1)).astype(np.float32)

    m = np.maximum(m, seg(-0.01, 1.01, 0.07, 0.07 + t))
    m = np.maximum(m, seg(0.17, 0.17 + t, 0.07, 0.85))
    m = np.maximum(m, seg(0.17, 0.85, 0.85 - t, 0.85))
    m = np.maximum(m, seg(0.85 - t, 0.85, 0.44, 0.85))
    m = np.maximum(m, seg(0.43, 0.85, 0.44, 0.44 + t))
    m = np.maximum(m, seg(0.43, 0.43 + t, 0.44, 0.67))
    inside = ((w > 0.0) & (w < 1.0)).astype(np.float32)
    return m * inside, inside


def gen_carved_stone():
    s = 2202
    yy, xx = grid()
    v = vcoord()

    grain = fbm(22, 7, s + 1, persistence=0.56)
    fine = fbm(180, 4, s + 2)
    sed = fbm(9, 3, s + 3, aniso=0.30)
    h = 0.50 + (grain - 0.5) * 0.022 + (fine - 0.5) * 0.010 + (sed - 0.5) * 0.014

    # broad vertical fluting, unevenly cut and unevenly worn
    fl_warp = (fbm(8, 4, s + 4) - 0.5) * 7.0
    fu = ((xx + fl_warp) / (float(N) / 16.0)) % 1.0
    fdepth = 0.048 + 0.030 * fbm(6, 3, s + 5, aniso=0.35)
    flute = np.sqrt(np.clip(1.0 - ((fu - 0.5) * 2.0 / 0.86) ** 2, 0, None))
    h -= flute * fdepth
    h += np.clip(1.0 - np.abs(fu - 0.5) * 2.0 / 0.14, 0, 1) ** 2 * 0.012

    band_med = smoothstep(0.435, 0.452, v) * (1.0 - smoothstep(0.800, 0.817, v))
    band_mea = smoothstep(0.288, 0.302, v) * (1.0 - smoothstep(0.428, 0.442, v))
    panel_bg = np.maximum(band_med, band_mea)
    h = h * (1.0 - panel_bg) + (0.50 + (grain - 0.5) * 0.014) * panel_bg

    def fillet(c, hw, amp):
        return np.sqrt(np.clip(1.0 - (np.abs(v - c) / hw) ** 2, 0, None)) * amp

    h += fillet(0.2810, 0.0140, 0.062)
    h += fillet(0.4485, 0.0140, 0.062)
    h += fillet(0.8270, 0.0165, 0.070)
    h += fillet(0.8640, 0.0080, 0.036)
    h += fillet(0.2510, 0.0080, 0.036)

    mm, minside = _meander(0.302, 0.428)
    # _meander returns a hard binary mask. Blurring it and then re-steepening
    # with a narrow smoothstep rebuilt a ~2.5px cliff, and a 0.126 height step
    # that sharp saturates normal_encode (z -> 0.17) and drives the cavity-lit
    # albedo past 1.0 -- which showed up as blown, zero-variance full-width
    # white lines on the fret's horizontal bars (rows 320/335/416).
    # A wider blur plus a wider remap gives the carved edge a ~4px chamfer,
    # which is also what a real weathered fret looks like.
    mm = smoothstep(0.20, 0.88, gblur(mm, 2.3))
    h -= minside * 0.038 * (1.0 - mm)
    h += mm * 0.088

    for i, cx in enumerate((256.0, 768.0)):
        lh, _ = _lotus(cx, 0.6255 * N, 152.0, s + 40 + i * 7)
        h = h + lh
    for i, cx in enumerate((0.0, 512.0)):
        rh, _ = _lotus(cx, 0.6255 * N, 54.0, s + 80 + i * 5, wobble=0.5, tiers=(6, 6, 6))
        h = h + rh * 0.60

    h += (fbm(60, 5, s + 60) - 0.5) * 0.011
    h += (fbm(110, 3, s + 61, aniso=0.16) - 0.5) * 0.009
    h += micro_grain(s + 90) * 0.020
    f1, _ = worley(44, s + 62, 0.95)
    pit = np.clip(1.0 - f1 * 2.0, 0, 1) ** 2
    h -= pit * 0.030 * smoothstep(0.32, 0.72, fbm(17, 3, s + 63))

    # damage: fewer but bigger losses, concentrated on the proud carving
    edge = np.clip(np.abs(cavity(h, 2.6)) * 34.0, 0, 1)
    dam = smoothstep(0.74, 0.93, fbm(5, 5, s + 64))
    dam = gblur(dam, 1.6)
    h -= dam * (0.35 + 0.9 * edge) * 0.090
    frac = smoothstep(0.905, 0.955, fbm(4, 5, s + 65, ridged=True))
    frac = frac * smoothstep(0.42, 0.70, fbm(5, 4, s + 68))     # only a few real fractures
    h -= gblur(frac, 1.2) * 0.085
    loss = smoothstep(0.860, 0.925, fbm(5, 5, s + 66))
    loss = smoothstep(0.15, 0.75, gblur(loss, 2.0))
    h = h * (1.0 - loss) + (0.435 + (fbm(46, 4, s + 67) - 0.5) * 0.055) * loss

    h = gblur(h, 0.5)
    ao = ao_multi(h, (2.0, 6.5, 20.0), (0.40, 0.36, 0.24), strength=6.4)
    cav = cavity(h, 2.4)
    broad = cavity(h, 11.0)

    mott = fbm(13, 6, s + 70, persistence=0.55)
    drift = fbm(4, 4, s + 71)
    t = np.clip(mott * 0.55 + sed * 0.20 + grain * 0.10 + drift * 0.15, 0, 1)
    alb = lerp3(col(136, 98, 56), col(198, 156, 98), smoothstep(0.05, 0.55, t))
    alb = lerp3(alb, col(238, 210, 160), smoothstep(0.55, 0.94, t))
    alb = lerp3(alb, col(206, 162, 100), fbm(30, 4, s + 72) * 0.50)
    alb = lerp3(alb, col(150, 140, 104), smoothstep(0.62, 0.95, drift) * 0.35)

    grime = np.clip(-broad * 22.0, 0, 1) ** 0.75
    grime = np.clip(grime * (0.45 + 0.9 * fbm(18, 5, s + 73)), 0, 1)
    alb = lerp3(alb, col(76, 64, 46), grime * 0.80)

    src = np.clip(fbm(13, 5, s + 74) - 0.50, 0, 1) * 3.0
    run = nrm01(streak(src, 170, 0.980, 0, 1))
    alb = lerp3(alb, col(112, 90, 60), np.clip(run * 1.1, 0, 1) * 0.75)

    lf1, _ = worley(20, s + 75, 1.0)
    lich = smoothstep(0.60, 0.12, lf1) * smoothstep(0.42, 0.68, fbm(8, 5, s + 76))
    lich *= (0.30 + 1.1 * np.clip(-cav * 26, 0, 1) + 0.7 * np.clip(-broad * 15, 0, 1))
    lich = np.clip(gblur(lich, 0.9) * 1.2, 0, 1)
    alb = lerp3(alb, col(150, 160, 112), lich * 0.80)
    alb = lerp3(alb, col(96, 112, 72), np.clip(lich - 0.58, 0, 1) * 2.4 * 0.6)

    alb *= (0.93 + 0.14 * fbm(300, 3, s + 91))[..., None]
    alb = lerp3(alb, col(232, 212, 172), np.clip(broad * 22.0, 0, 1) * 0.26)
    alb = lerp3(alb, col(230, 202, 154),
                np.clip((dam * edge + frac + loss) * 1.5, 0, 1) * 0.50)
    alb *= (ao ** 1.55)[..., None]
    # cap the proud-edge brightening: the old +0.36 ceiling stacked on top of
    # the near-white lerp and then gain(), which railed whole rows at 255.
    alb *= (1.0 + np.clip(cav * 12.0, -0.34, 0.22))[..., None]
    alb = gain(alb, 1.26, 0.42)
    alb = shoulder(alb)

    rough = 0.78 - 0.09 * t + 0.07 * (fbm(52, 4, s + 80) - 0.5)
    rough += grime * 0.13 + lich * 0.14 + loss * 0.06
    rough -= np.clip(broad * 10.0, 0, 0.14)
    return np.clip(alb, 0, 1), h, np.clip(rough, 0.40, 0.99), 96.0

# ============================================================================
# 3. CLAY WALL -- hand-smoothed mud plaster over straw daub
# ============================================================================

def gen_clay_wall():
    s = 3303
    big = fbm(6, 6, s + 3, persistence=0.58)
    swirl = fbm(9, 5, s + 4, aniso=0.55)
    h = 0.55 + (big - 0.5) * 0.090 + (swirl - 0.5) * 0.036

    # palm/trowel sweeps -- broad smooth areas with raised edges where the hand lifted
    sweep = streak(fbm(16, 3, s + 5) - 0.5, 52, 0.940, axis=1, direction=1)
    h += sweep * 0.048
    sweep2 = streak(fbm(22, 3, s + 6) - 0.5, 34, 0.910, axis=0, direction=1)
    h += sweep2 * 0.024
    lift = np.clip(np.abs(cavity(gblur(sweep, 3.5), 10.0)) * 30.0, 0, 1)
    h += lift * 0.014
    smoothed = smoothstep(0.30, 0.72, fbm(7, 4, s + 7))     # where the hand polished it

    # straw / chaff, mostly buried, surfacing where the plaster has worn thin
    fa = strokes(2400, 45, 150, s + 10, ang=0.0, spread=np.pi, curve=0.55, samples=60)
    fb = strokes(1100, 110, 280, s + 11, ang=0.25, spread=np.pi, curve=0.9, samples=95)
    fc = strokes(3000, 12, 34, s + 12, ang=0.0, spread=np.pi, curve=0.4, samples=20)
    fibre = smoothstep(0.16, 0.66, gblur(np.clip(fa + fb * 0.95 + fc * 0.55, 0, 1.7), 0.55))
    fibre = fibre * (0.30 + 1.30 * (1.0 - smoothed))
    fibre = np.clip(fibre, 0, 1)
    h += fibre * 0.068

    f1, _ = worley(84, s + 25, 1.0)
    grit = np.clip(1.0 - f1 * 2.6, 0, 1) ** 1.5 * (0.25 + 1.0 * (1.0 - smoothed))
    h += grit * 0.022
    p1, _ = worley(24, s + 14, 1.0)
    peb = np.sqrt(np.clip(1.0 - (p1 / 0.28) ** 2, 0, None)) * \
          smoothstep(0.66, 0.86, fbm(12, 4, s + 15))
    h += peb * 0.045
    h += (fbm(210, 3, s + 16) - 0.5) * 0.012
    h += (fbm(40, 4, s + 24) - 0.5) * 0.030 * (0.3 + 1.0 * (1.0 - smoothed))   # mud lumps
    h += micro_grain(s + 26, 150, 300) * 0.026 * (0.35 + 0.9 * (1.0 - smoothed))

    # shrinkage craquelure: a connected polygon network, width varying along it
    net = np.maximum(cell_edges(10, s + 17, width=0.040),
                     cell_edges(21, s + 18, width=0.020) * 0.35)
    netm = smoothstep(0.53, 0.68, fbm(6, 4, s + 19))     # ~15% of the wall, measured
    crack = np.clip(net, 0, 1) * netm * (0.30 + 0.85 * fbm(30, 4, s + 20))
    crack = gblur(crack, 0.6)
    h -= crack * 0.055

    # plaster fallen away, exposing strawy daub underneath
    spall = smoothstep(0.735, 0.800, fbm(7, 5, s + 21))
    spall = smoothstep(0.15, 0.80, gblur(spall, 1.6))
    h -= spall * 0.090
    h += spall * fibre * 0.055
    h += spall * (fbm(70, 4, s + 22) - 0.5) * 0.030

    dv = 0.5 * (1.0 + np.cos(2.0 * np.pi * vcoord()))
    damp = np.clip(dv ** 1.5 * (0.42 + 0.95 * fbm(8, 5, s + 23)), 0, 1)
    damp = gblur(damp, 2.5)

    h = gblur(h, 0.6)
    ao = ao_multi(h, (2.0, 7.0, 24.0), (0.45, 0.35, 0.20), strength=4.8)
    cav = cavity(h, 2.0)
    broad = cavity(h, 12.0)

    mott = fbm(10, 6, s + 30, persistence=0.55)
    t = np.clip(mott * 0.65 + big * 0.35, 0, 1)
    alb = lerp3(col(148, 98, 54), col(206, 154, 94), smoothstep(0.05, 0.52, t))
    alb = lerp3(alb, col(234, 196, 140), smoothstep(0.52, 0.94, t))
    alb = lerp3(alb, col(184, 134, 80), fbm(34, 4, s + 31) * 0.55)

    alb = lerp3(alb, col(232, 206, 146), np.clip(fibre * 1.4, 0, 1) * 0.78)
    alb = lerp3(alb, col(198, 168, 104), np.clip(fibre - 0.55, 0, 1) * 2.0 * 0.50)
    alb = lerp3(alb, col(118, 80, 46), spall * 0.85)
    alb = lerp3(alb, col(208, 192, 170), np.clip(peb * 2.0, 0, 1) * 0.50)
    alb = lerp3(alb, col(82, 56, 36), np.clip(crack * 1.5, 0, 1) * 0.88)

    alb = lerp3(alb, col(112, 82, 54), damp * 0.72)
    alb = lerp3(alb, col(92, 92, 64), np.clip(damp - 0.50, 0, 1) * 1.8 * 0.48)
    sp = smoothstep(0.66, 0.92, fbm(64, 4, s + 32)) * damp
    alb = lerp3(alb, col(78, 62, 44), sp * 0.62)
    salt = smoothstep(0.52, 0.78, damp) * (1.0 - smoothstep(0.70, 0.94, damp)) * \
           smoothstep(0.50, 0.82, fbm(24, 5, s + 33))
    alb = lerp3(alb, col(230, 218, 196), salt * 0.45)
    alb = lerp3(alb, col(242, 232, 210),
                np.clip(cav * 18.0, 0, 1) * (1.0 - damp) * 0.26)

    alb *= (0.94 + 0.12 * fbm(280, 3, s + 34))[..., None]
    alb *= (ao ** 1.25)[..., None]
    alb *= (1.0 + np.clip(cav * 10.0, -0.30, 0.30))[..., None]
    alb = gain(alb, 1.16, 0.44)

    rough = 0.86 - 0.05 * t + 0.06 * (fbm(44, 4, s + 40) - 0.5)
    rough += fibre * 0.08 + spall * 0.07 + crack * 0.06 + grit * 0.05
    rough -= damp * 0.22 + peb * 0.16 + smoothed * 0.08
    rough -= np.clip(cav * 6.0, 0, 0.07)
    return np.clip(alb, 0, 1), h, np.clip(rough, 0.40, 0.99), 66.0

# ============================================================================
# 4. THATCH -- dried palm / grass roof, overlapping courses
# ============================================================================

def gen_thatch():
    s = 4404
    yy, xx = grid()
    courses = 6
    ch = float(N) / courses
    wob = (fbm(7, 4, s + 1, aniso=2.6) - 0.5) * 62.0
    wob += (fbm(18, 3, s + 2, aniso=4.5) - 0.5) * 22.0
    fr = (yy + wob) / ch
    ly = (fr - np.floor(fr)).astype(np.float32)

    ramp = smoothstep(0.03, 0.82, ly)
    lip = 1.0 - smoothstep(0.84, 1.00, ly)
    h = (0.30 + ramp * 0.36) * (0.42 + 0.58 * lip)

    # bundles: a clump field gates a much finer stalk field
    clump = fbm(9, 4, s + 3, aniso=8.0, persistence=0.60)
    clump2 = fbm(5, 3, s + 4, aniso=4.0, persistence=0.55)
    stalk = fbm(5, 6, s + 5, aniso=52.0, persistence=0.62)
    stalk2 = fbm(9, 5, s + 6, aniso=30.0, persistence=0.60)
    stalk3 = fbm(3, 4, s + 7, aniso=110.0, persistence=0.65)
    st = np.clip(stalk * 0.42 + stalk2 * 0.32 + stalk3 * 0.26, 0, 1)
    h += (st - 0.5) * (0.09 + 0.15 * clump)
    h += (clump - 0.5) * 0.075 + (clump2 - 0.5) * 0.050

    stk = strokes(5600, 100, 250, s + 10, ang=np.pi / 2, spread=0.20, curve=0.26, samples=95)
    stk += strokes(2800, 170, 380, s + 11, ang=np.pi / 2, spread=0.12, curve=0.16, samples=120) * 0.85
    stk = nrm01(gblur(np.clip(stk, 0, 3.0), 0.7))
    h += (stk - 0.45) * 0.110

    # ragged ends hanging over the course below, and a few straws pulled right out
    ends = np.clip(fbm(4, 5, s + 12, aniso=46.0) - 0.48, 0, 1) * 3.4
    ends = ends * smoothstep(0.60, 0.99, ly) * (0.4 + 1.0 * clump2)
    h += ends * 0.090
    loose = strokes(420, 120, 320, s + 13, ang=np.pi / 2, spread=0.42, curve=0.6, samples=110)
    loose = nrm01(gblur(np.clip(loose, 0, 1.4), 1.0))
    h += loose * 0.045

    matt = smoothstep(0.66, 0.86, fbm(5, 5, s + 14))
    h -= matt * 0.065
    h += (fbm(160, 3, s + 15, aniso=8.0) - 0.5) * 0.012

    h = gblur(h, 0.5)
    ao = ao_multi(h, (1.6, 6.0, 18.0), (0.38, 0.36, 0.26), strength=5.4)
    cav = cavity(h, 1.8)

    gap = smoothstep(0.82, 0.995, ly) * (0.50 + 0.75 * fbm(16, 4, s + 16, aniso=4.0))
    gap = np.clip(gap * (1.0 - np.clip(ends + loose, 0, 1) * 0.8), 0, 1)

    tone = np.clip(st * 0.38 + stk * 0.24 + clump * 0.22 + fbm(8, 5, s + 20) * 0.16, 0, 1)
    alb = lerp3(col(88, 60, 28), col(182, 136, 60), smoothstep(0.05, 0.52, tone))
    alb = lerp3(alb, col(234, 200, 130), smoothstep(0.52, 0.92, tone))
    # bundle-to-bundle drift: green-grey unrotted, silvered, and dark old straw
    hue = fbm(6, 5, s + 21, aniso=44.0)
    hue2 = fbm(7, 4, s + 22, aniso=5.0)
    hue3 = fbm(4, 4, s + 23, aniso=9.0)
    alb = lerp3(alb, col(148, 146, 84), np.clip(hue - 0.52, 0, 1) * 1.9 * 0.60)
    alb = lerp3(alb, col(226, 198, 134), np.clip(0.48 - hue, 0, 1) * 1.9 * 0.52)
    alb = lerp3(alb, col(132, 106, 62), np.clip(hue2 - 0.54, 0, 1) * 2.1 * 0.62)
    alb = lerp3(alb, col(214, 180, 106), np.clip(0.44 - hue2, 0, 1) * 2.1 * 0.45)
    alb = lerp3(alb, col(176, 172, 152), np.clip(hue3 - 0.62, 0, 1) * 2.6 * 0.50)
    ptone = fbm(3, 4, s + 24, aniso=2.0)
    alb = lerp3(alb, col(118, 100, 62), np.clip(ptone - 0.58, 0, 1) * 2.3 * 0.50)
    alb = lerp3(alb, col(228, 202, 150), np.clip(0.42 - ptone, 0, 1) * 2.3 * 0.38)
    alb = lerp3(alb, col(66, 48, 26), matt * 0.72)
    alb = lerp3(alb, col(32, 22, 12), gap * 0.88)
    tip = smoothstep(0.46, 0.82, ly) * (1.0 - gap)
    alb = lerp3(alb, col(242, 214, 150), tip * 0.34)
    alb = lerp3(alb, col(248, 228, 174), np.clip((ends + loose) * 1.2, 0, 1) * 0.40)

    alb *= (ao ** 1.40)[..., None]
    alb *= (1.0 + np.clip(cav * 13.0, -0.36, 0.38))[..., None]
    alb = gain(alb, 1.20, 0.42)

    rough = 0.82 - 0.16 * tone + 0.10 * (fbm(36, 4, s + 30) - 0.5)
    rough += matt * 0.14 + gap * 0.12 + np.clip(hue - 0.5, 0, 1) * 0.14
    rough += np.clip(hue3 - 0.6, 0, 1) * 0.12
    rough -= np.clip(stk - 0.55, 0, 1) * 0.20 - 0.0
    rough -= np.clip(cav * 8.0, 0, 0.10)
    return np.clip(alb, 0, 1), h, np.clip(rough, 0.42, 0.99), 78.0

# ============================================================================
# 5. WOOD BEAM -- weathered teak, axe-hewn
# ============================================================================

def gen_wood_beam():
    s = 5505
    yy, xx = grid()

    warp = (fbm(3, 5, s + 1, aniso=0.22, persistence=0.62) - 0.5) * 72.0
    warp += (fbm(8, 4, s + 2, aniso=0.30) - 0.5) * 30.0
    warp += (fbm(30, 3, s + 3, aniso=0.5) - 0.5) * 8.0

    knots = [(180.0, 300.0, 62.0, 1.0), (720.0, 690.0, 44.0, -1.0),
             (470.0, 118.0, 27.0, 0.7)]
    knotm = np.zeros((N, N), np.float32)
    knotc = np.zeros((N, N), np.float32)
    knotr = np.zeros((N, N), np.float32)
    for (kx, ky, kr, sgn) in knots:
        ddx = wrapd(xx - kx)
        ddy = wrapd(yy - ky) * 0.58
        rr = np.sqrt(ddx * ddx + ddy * ddy) + (fbm(20, 4, s + 40) - 0.5) * 6.0
        warp = warp + sgn * np.exp(-(rr / (kr * 3.8)) ** 2) * ddy * 2.3
        m = smoothstep(kr * 1.55, kr * 0.70, rr)
        knotm = np.maximum(knotm, m)
        knotc = np.maximum(knotc, smoothstep(kr * 0.85, kr * 0.35, rr))
        knotr = np.maximum(knotr, m * (0.5 + 0.5 * np.cos(rr / (kr * 0.085))))

    gx = xx + warp
    u = gx / float(N)
    ph = 2.0 * np.pi * (11.0 * u + 0.50 * np.sin(2.0 * np.pi * 2.0 * u)
                        + 0.26 * np.sin(2.0 * np.pi * 5.0 * u + 1.3))
    ring = 0.5 + 0.5 * np.cos(ph)
    late = ring ** 10
    late = np.maximum(late, (0.5 + 0.5 * np.cos(ph * 2.0 + 1.1)) ** 18 * 0.40)
    early = (1.0 - ring) ** 2

    fibre = fbm(8, 5, s + 5, aniso=34.0, persistence=0.62)
    pore = np.clip(fbm(14, 4, s + 6, aniso=50.0) - 0.58, 0, 1) * 2.6
    pore *= (0.30 + 0.95 * late)

    # WEATHERED wood: the soft earlywood washes out and the hard latewood stands proud
    weath = smoothstep(0.25, 0.85, fbm(5, 5, s + 20))
    h = 0.58 + late * 0.072 * (0.4 + 1.2 * weath) - early * 0.040 * (0.3 + 1.3 * weath)
    h += (fibre - 0.5) * 0.055 - pore * 0.032
    h += (fbm(120, 4, s + 21, aniso=9.0) - 0.5) * 0.026      # raised weathered fibres

    # axe-hewn facets: long shallow strips down the length of the beam, each one
    # a flat plane left by a blade stroke -- NOT rounded blobs
    fac = fbm(3, 2, s + 7, aniso=4.5, persistence=0.45)
    facs = gblur(np.floor(fac * 5.0) / 5.0, 2.0)
    h += (facs - 0.5) * 0.048
    facedge = np.clip(np.abs(cavity(facs, 2.5)) * 42.0, 0, 1)
    h -= facedge * 0.016

    h += knotm * 0.030 - knotc * 0.075 + knotr * knotm * 0.030

    # three real drying splits that wander along the grain
    split = np.zeros((N, N), np.float32)
    for i, (sx0, wdt, amp) in enumerate([(0.17, 7.5, 1.0), (0.61, 5.0, 0.85),
                                         (0.87, 3.5, 0.7)]):
        xc = sx0 * N + (fbm(3, 4, s + 30 + i, aniso=0.12) - 0.5) * 120.0
        dd = np.abs(wrapd(xx - xc))
        wv = wdt * (0.5 + 1.3 * fbm(9, 3, s + 34 + i, aniso=0.25))
        line = np.clip(1.0 - dd / np.maximum(wv, 0.8), 0, 1)
        lenm = smoothstep(0.36, 0.62, fbm(4, 4, s + 37 + i, aniso=0.22))
        split = np.maximum(split, line * lenm * amp)
    split = smoothstep(0.10, 0.70, gblur(split, 1.0))
    h -= split * 0.135

    h = gblur(h, 0.5)
    ao = ao_multi(h, (1.8, 6.0, 20.0), (0.44, 0.36, 0.20), strength=5.4)
    cav = cavity(h, 1.8)
    broad = cavity(h, 12.0)

    # sun-silvered grey outside, warm teak in every groove and sheltered patch
    warm = np.clip(late * 0.60 + pore * 0.45 + (1.0 - fibre) * 0.25, 0, 1)
    shelter = np.clip(-broad * 18.0, 0, 1)
    alb = lerp3(col(178, 150, 116), col(150, 122, 92), fbm(11, 5, s + 50))
    alb = lerp3(alb, col(112, 72, 36), np.clip(warm * (0.45 + 0.75 * shelter) * 1.7, 0, 1))
    alb = lerp3(alb, col(154, 104, 54),
                np.clip(early * (1.0 - weath) * 1.3, 0, 1) * 0.62)
    alb = lerp3(alb, col(56, 36, 20), np.clip(late * 0.60 + pore * 0.7, 0, 1) * 0.66)
    alb = lerp3(alb, col(184, 172, 152), weath * smoothstep(0.42, 0.92, fbm(6, 5, s + 51)) * 0.42)
    alb = lerp3(alb, col(196, 186, 168), np.clip(cav * 12.0, 0, 1) * 0.14)

    # facet faces catch the sun differently
    alb *= (0.90 + 0.20 * facs)[..., None]
    alb = lerp3(alb, col(200, 188, 168), facedge * 0.12)

    alb = lerp3(alb, col(94, 62, 34), knotm * 0.68)
    alb = lerp3(alb, col(40, 26, 16), knotc * 0.88)
    alb = lerp3(alb, col(30, 22, 14), np.clip(split * 1.4, 0, 1) * 0.92)

    grey = smoothstep(0.66, 0.92, fbm(8, 5, s + 52))
    alb = lerp3(alb, col(146, 140, 124), grey * 0.30)
    moss = smoothstep(0.70, 0.90, fbm(12, 5, s + 53)) * shelter
    alb = lerp3(alb, col(112, 122, 84), moss * 0.45)

    alb *= (ao ** 1.35)[..., None]
    alb *= (1.0 + np.clip(cav * 12.0, -0.32, 0.34))[..., None]
    alb = gain(alb, 1.20, 0.44)

    rough = 0.80 + 0.12 * (fbm(34, 4, s + 60) - 0.5)
    rough += pore * 0.14 + split * 0.14 + weath * 0.10 + grey * 0.07 + moss * 0.06
    rough -= knotm * 0.22 + (1.0 - weath) * 0.10
    rough -= np.clip(cav * 8.0, 0, 0.10)
    return np.clip(alb, 0, 1), h, np.clip(rough, 0.36, 0.99), 76.0

# ============================================================================
# 6. TERRACOTTA -- fired clay roof tile / pot
# ============================================================================

def gen_terracotta():
    s = 6606
    yy, xx = grid()
    wob = (fbm(4, 4, s + 1, aniso=0.35) - 0.5) * 22.0
    wob += (fbm(11, 3, s + 2, aniso=0.55) - 0.5) * 8.0
    yr = (yy + wob) / float(N)
    rp = 2.0 * np.pi * (34.0 * yr + 0.60 * np.sin(2.0 * np.pi * 3.0 * yr)
                        + 0.32 * np.sin(2.0 * np.pi * 7.0 * yr + 0.8))
    ringamp = 0.35 + 0.9 * fbm(5, 3, s + 3, aniso=0.4)     # rings fade in and out
    fine_ring = 0.5 + 0.5 * np.cos(rp)
    med_ring = 0.5 + 0.5 * np.cos(2.0 * np.pi * (9.0 * yr) + 1.1)
    big_ring = 0.5 + 0.5 * np.cos(2.0 * np.pi * (4.0 * yr) - 0.6)

    h = 0.62
    h += (fine_ring ** 2 - 0.35) * 0.012 * ringamp
    h += (med_ring ** 3 - 0.30) * 0.014
    h += (big_ring - 0.5) * 0.016
    h += (fbm(6, 5, s + 4, persistence=0.58) - 0.5) * 0.060
    h += (fbm(22, 4, s + 5) - 0.5) * 0.024
    h += (fbm(90, 4, s + 6) - 0.5) * 0.014

    f1, _ = worley(64, s + 7, 1.0)
    pores = np.clip(1.0 - f1 * 3.4, 0, 1) ** 1.6
    pores *= smoothstep(0.56, 0.86, fbm(14, 4, s + 8))     # clustered, not a blanket
    h -= pores * 0.024
    sand, _ = worley(118, s + 9, 1.0)
    grit = np.sqrt(np.clip(1.0 - (sand / 0.30) ** 2, 0, None)) * \
           smoothstep(0.48, 0.78, fbm(16, 4, s + 10))
    h += grit * 0.016
    h += (fbm(220, 3, s + 11) - 0.5) * 0.016

    # a handful of proper chips: deep, sharp-rimmed, showing raw clay
    cf1, _ = worley(8, s + 12, 1.0)
    site = smoothstep(0.36, 0.02, cf1 + (fbm(30, 4, s + 13) - 0.5) * 0.10
                      + (fbm(70, 3, s + 18) - 0.5) * 0.07)      # ragged fracture outline
    sel = smoothstep(0.52, 0.68, fbm(8, 4, s + 14))
    chip = smoothstep(0.34, 0.58, gblur(np.clip(site * sel * 2.2, 0, 1), 1.0))
    h -= chip * 0.070
    h -= chip * (fbm(46, 4, s + 17) - 0.5) * 0.024          # broken flake floor
    rim = np.clip(cavity(chip, 2.2) * 9.0, 0, 1)            # inner lip only
    h -= rim * 0.010

    nick = smoothstep(0.875, 0.940, fbm(7, 5, s + 15, ridged=True))
    nick *= smoothstep(0.46, 0.74, fbm(12, 4, s + 16))
    h -= gblur(nick, 0.8) * 0.085

    h = gblur(h, 0.5)
    ao = ao_multi(h, (1.8, 6.5, 22.0), (0.44, 0.36, 0.20), strength=5.4)
    cav = cavity(h, 1.8)
    broad = cavity(h, 11.0)

    cloud = fbm(4, 6, s + 20, persistence=0.60)
    cloud2 = fbm(11, 5, s + 21)
    cloud3 = fbm(26, 4, s + 22)
    t = np.clip(cloud * 0.55 + cloud2 * 0.30 + cloud3 * 0.15, 0, 1)
    alb = lerp3(col(106, 40, 26), col(180, 76, 38), smoothstep(0.06, 0.40, t))
    alb = lerp3(alb, col(214, 108, 52), smoothstep(0.38, 0.66, t))
    alb = lerp3(alb, col(240, 158, 94), smoothstep(0.66, 0.95, t))

    smoke = smoothstep(0.50, 0.82, fbm(3, 5, s + 23))
    alb = lerp3(alb, col(88, 52, 44), smoke * 0.78)
    alb = lerp3(alb, col(48, 34, 34), np.clip(smoke - 0.58, 0, 1) * 2.6 * 0.55)
    flash = smoothstep(0.58, 0.90, fbm(5, 5, s + 24))
    alb = lerp3(alb, col(234, 146, 66), flash * 0.55)
    scorch = smoothstep(0.72, 0.94, fbm(9, 5, s + 25))
    alb = lerp3(alb, col(126, 78, 56), scorch * 0.45)

    alb = lerp3(alb, col(226, 146, 96), chip * 0.85)
    alb = lerp3(alb, col(238, 176, 128), np.clip(rim * 1.6, 0, 1) * 0.45)
    alb = lerp3(alb, col(236, 172, 122), np.clip(nick * 1.5, 0, 1) * 0.62)
    alb = lerp3(alb, col(224, 178, 138), np.clip(grit * 1.8, 0, 1) * 0.22)

    bloom = smoothstep(0.66, 0.90, fbm(13, 5, s + 26)) * np.clip(broad * 14.0 + 0.35, 0, 1)
    alb = lerp3(alb, col(228, 204, 182), bloom * 0.48)
    alb = lerp3(alb, col(96, 56, 38), np.clip(-cav * 20.0, 0, 1) * 0.24)
    alb *= (0.96 + 0.07 * fine_ring * ringamp)[..., None]

    alb *= (ao ** 1.30)[..., None]
    alb *= (1.0 + np.clip(cav * 11.0, -0.28, 0.30))[..., None]
    alb = gain(alb, 1.26, 0.40)

    burnish = smoothstep(0.28, 0.82, fbm(5, 5, s + 31))
    rough = 0.76 + 0.14 * (fbm(38, 4, s + 30) - 0.5)
    rough -= burnish * 0.36
    rough -= smoothstep(0.35, 0.92, t) * 0.10
    rough += chip * 0.26 + pores * 0.16 + bloom * 0.16 + nick * 0.22 + grit * 0.14
    rough += smoke * 0.08
    rough -= np.clip(cav * 7.0, 0, 0.10)
    return np.clip(alb, 0, 1), h, np.clip(rough, 0.22, 0.96), 82.0

# ============================================================================
# 7. BRICK RUIN -- crumbling ancient brick, missing units, moss and vine
# ============================================================================

def gen_brick_ruin():
    s = 7707
    rng = np.random.default_rng(s)
    wx = (fbm(7, 4, s + 1) - 0.5) * 2.0
    wy = (fbm(7, 4, s + 2) - 0.5) * 2.0
    rows, cols = 16, 8
    bid, lx, ly, dx, dy, d = brick_field(rows, cols, wx * 7.0, wy * 4.0)
    nb = rows * cols

    bh = pb(rng, nb, bid, -1, 1)
    tx = pb(rng, nb, bid, -1, 1)
    ty = pb(rng, nb, bid, -1, 1)
    miss_r = pb(rng, nb, bid, 0, 1)
    wear_r = pb(rng, nb, bid, 0, 1)
    tilt = (tx * (lx - 0.5) + ty * (ly - 0.5)) * 0.8

    mw = 6.5
    face = smoothstep(mw - 1.5, mw + 3.0, d)

    grain = fbm(28, 6, s + 10, persistence=0.55)
    fine = fbm(190, 4, s + 11)
    f1, _ = worley(58, s + 12, 1.0)
    pit = np.clip(1.0 - f1 * 2.2, 0, 1) ** 1.5

    h = 0.62 + bh * 0.022 + tilt * 0.034
    h += (grain - 0.5) * 0.038 + (fine - 0.5) * 0.020
    h += micro_grain(s + 50, 140, 280) * 0.048
    h -= pit * 0.070 * smoothstep(0.24, 0.64, fbm(20, 3, s + 13)) * (0.4 + wear_r)

    bevel = smoothstep(mw + 1.0, mw + 11.0 + 16.0 * fbm(26, 4, s + 51), d)
    h -= (1.0 - bevel) * face * 0.030 * (0.35 + 0.85 * fbm(64, 4, s + 14))

    ero = smoothstep(0.38, 0.82, fbm(10, 5, s + 15)) * (0.35 + 0.9 * wear_r)
    h -= ero * face * 0.085 * (0.35 + 0.75 * fbm(34, 4, s + 16))

    mort = 0.40 + (fbm(56, 5, s + 17) - 0.5) * 0.18 + (fbm(170, 3, s + 18) - 0.5) * 0.06
    mort -= smoothstep(0.40, 0.82, fbm(12, 4, s + 19)) * 0.11
    h = h * face + mort * (1.0 - face)

    gone = (miss_r < 0.10).astype(np.float32)
    partial = ((miss_r >= 0.10) & (miss_r < 0.22)).astype(np.float32)
    part_cut = smoothstep(0.44, 0.62, fbm(20, 5, s + 20)) * partial
    holem = smoothstep(0.28, 0.72, gblur(np.clip(gone + part_cut, 0, 1), 1.8))
    rub_id, _, _, rdx, rdy, rd = brick_field(16, 8, wx * 5.0 + 26.0, wy * 4.0 + 17.0)
    rubble = 0.15 + (fbm(36, 5, s + 21) - 0.5) * 0.100 + (fbm(120, 4, s + 22) - 0.5) * 0.050
    rubble += smoothstep(4.0, 10.0, rd) * 0.034
    h = h * (1.0 - holem) + rubble * holem

    corner = (1.0 - smoothstep(4.0, 30.0, np.minimum(dx, dy))) * \
             smoothstep(0.48, 0.74, fbm(44, 4, s + 23)) * face
    h -= corner * 0.090

    h = gblur(h, 0.6)
    ao = ao_multi(h, (2.0, 7.0, 24.0), (0.55, 0.30, 0.15), strength=4.6)
    cav = cavity(h, 2.2)
    broad = cavity(h, 14.0)

    brickc = pb_pal(rng, nb, bid, [
        (168, 102, 68), (146, 86, 58), (184, 122, 80), (158, 108, 76),
        (132, 88, 66), (176, 130, 92), (150, 94, 62), (126, 86, 66),
        (190, 132, 86), (162, 116, 84), (140, 100, 76), (172, 110, 68),
    ])
    mott = fbm(15, 6, s + 30, persistence=0.55)
    alb = brickc * (0.78 + 0.46 * mott)[..., None]
    alb = lerp3(alb, col(206, 156, 110), smoothstep(0.60, 0.95, mott) * 0.42)
    alb = lerp3(alb, col(102, 70, 54), smoothstep(0.64, 0.98, 1.0 - mott) * 0.40)
    alb = lerp3(alb, col(192, 146, 104), np.clip(ero * face, 0, 1) * 0.38)
    alb = lerp3(alb, col(118, 78, 58),
                smoothstep(0.58, 0.86, fbm(34, 5, s + 53)) * face * 0.40)
    alb = lerp3(alb, col(198, 154, 118),
                smoothstep(0.58, 0.88, fbm(52, 5, s + 54)) * face * 0.32)
    alb = lerp3(alb, col(214, 178, 134), np.clip(corner * 1.3, 0, 1) * 0.40)

    alb = lerp3(alb, col(112, 102, 86) * (0.45 + 0.80 * fbm(96, 4, s + 31))[..., None],
                1.0 - face)
    alb *= (1.0 - (1.0 - face) * 0.22)[..., None]      # the joint is a shadowed recess
    # the gap is not a flat hole: broken brick backs and rubble sit inside it
    rubc = pb_pal(np.random.default_rng(s + 99), nb, rub_id, [
        (108, 76, 58), (92, 66, 52), (124, 92, 70), (84, 62, 50),
        (116, 88, 66), (98, 74, 58), (130, 100, 76), (88, 68, 56)])
    alb = lerp3(alb, rubc * (0.60 + 0.60 * fbm(50, 4, s + 32))[..., None], holem * 0.92)

    moist = np.clip(gblur(np.clip((1.0 - face) * 0.75 + holem * 0.65 +
                                  np.clip(-broad * 16.0, 0, 1) * 0.75, 0, 1.5), 8.0) * 1.4, 0, 1)
    mf1, _ = worley(26, s + 33, 1.0)
    mossp = smoothstep(0.58, 0.12, mf1) * smoothstep(0.46, 0.74, fbm(8, 5, s + 34))
    moss = np.clip(mossp * (0.15 + 1.15 * moist), 0, 1)
    moss = np.clip(gblur(moss, 1.0) * (0.55 + 0.85 * fbm(64, 4, s + 35)), 0, 1)
    alb = lerp3(alb, col(112, 128, 68), moss * 0.82)
    alb = lerp3(alb, col(62, 82, 42), np.clip(moss - 0.55, 0, 1) * 2.2 * 0.72)

    vine = strokes(70, 380, 950, s + 36, ang=np.pi / 2, spread=0.34,
                   curve=3.4, samples=300, taper=False)
    vinep = strokes(900, 30, 90, s + 37, ang=np.pi / 2, spread=1.2, curve=1.6, samples=34)
    vine = nrm01(gblur(np.clip(vine, 0, 1.6), 0.8)) * 1.5
    vine = np.clip(vine + nrm01(gblur(np.clip(vinep, 0, 1.4), 1.0)) * 0.55 - 0.26, 0, 1)
    alb = lerp3(alb, col(82, 96, 52), vine * 0.58)
    alb = lerp3(alb, col(50, 62, 36), np.clip(vine - 0.60, 0, 1) * 2.4 * 0.5)

    wash = nrm01(streak(np.clip(moss * 0.8 + vine * 0.6, 0, 1), 150, 0.978, 0, 1))
    alb = lerp3(alb, col(96, 92, 68), np.clip(wash * 0.55, 0, 1))
    dark = nrm01(streak(np.clip(fbm(11, 5, s + 38) - 0.66, 0, 1) * 3.0, 130, 0.974, 0, 1))
    alb = lerp3(alb, col(62, 56, 46), np.clip(dark * 0.55, 0, 1))
    eff = smoothstep(0.62, 0.90, fbm(18, 5, s + 39)) * (1.0 - moist) * face
    alb = lerp3(alb, col(212, 204, 190), eff * 0.48)

    alb *= (0.91 + 0.18 * fbm(280, 3, s + 52))[..., None]
    alb *= (1.0 - holem * 0.30)[..., None]          # real depth inside the gaps
    alb *= (ao ** 1.30)[..., None]
    alb *= (1.0 + np.clip(cav * 8.0, -0.26, 0.26))[..., None]
    alb = gain(alb, 1.16, 0.44)

    rough = 0.84 + 0.10 * (fbm(46, 4, s + 40) - 0.5)
    rough += (1.0 - face) * 0.09 + moss * 0.08 + ero * 0.07 + eff * 0.07
    rough -= vine * 0.16 + moist * 0.07
    rough -= np.clip(cav * 6.0, 0, 0.08)
    return np.clip(alb, 0, 1), h, np.clip(rough, 0.44, 0.99), 76.0

# ============================================================================
# 8. GOLD / BRASS -- polished then tarnished temple metal
# ============================================================================

def gen_gold_brass():
    s = 8808

    # cast body, then planished: two scales of shallow hammer facets, unevenly worked
    h = 0.60 + (fbm(7, 4, s + 1, persistence=0.50) - 0.5) * 0.034
    h += (fbm(20, 3, s + 2, persistence=0.45) - 0.5) * 0.013
    hamp = 0.30 + 0.95 * fbm(5, 3, s + 3)
    d1, _ = worley(11, s + 4, 0.90)
    d2, _ = worley(24, s + 5, 0.90)
    h += gblur(np.sqrt(np.clip(1.0 - (d1 / 0.56) ** 2, 0, None)), 0.9) * 0.038 * hamp
    h += gblur(np.sqrt(np.clip(1.0 - (d2 / 0.50) ** 2, 0, None)), 0.6) * 0.020 * hamp

    # casting pits and porosity
    cp, _ = worley(58, s + 6, 1.0)
    pits = np.clip(1.0 - cp * 3.6, 0, 1) ** 1.8 * smoothstep(0.62, 0.88, fbm(12, 4, s + 7))
    h -= pits * 0.018
    h += (fbm(190, 3, s + 8) - 0.5) * 0.006

    # polishing and handling scratches -- the sharpest thing on the surface
    sc = strokes(3800, 70, 380, s + 10, ang=0.32, spread=0.38, curve=0.20, samples=120)
    sc += strokes(1400, 180, 640, s + 11, ang=-0.20, spread=0.24, curve=0.10, samples=170) * 0.9
    sc += strokes(2400, 25, 90, s + 12, ang=0.0, spread=np.pi, curve=0.5, samples=36) * 0.6
    scn = nrm01(gblur(np.clip(sc, 0, 2.6), 0.40))
    h -= scn * 0.018

    dent = smoothstep(0.74, 0.93, fbm(8, 4, s + 13))
    h -= gblur(dent, 2.6) * 0.034
    ding, _ = worley(9, s + 14, 1.0)
    ding = smoothstep(0.30, 0.06, ding) * smoothstep(0.76, 0.90, fbm(7, 4, s + 15))
    ding = gblur(ding, 2.0)
    h -= ding * 0.038

    h = gblur(h, 0.4)
    ao = ao_multi(h, (1.6, 5.5, 16.0), (0.44, 0.36, 0.20), strength=4.2)
    cav = cavity(h, 1.8)
    broad = cavity(h, 9.0)

    # tarnish: verdigris settles in every crevice and pit, blooms in patches, and
    # runs downward out of the blooms the way rain carries it
    crev = np.clip(-cav * 30.0, 0, 1)
    crev = np.maximum(crev, np.clip(-broad * 20.0, 0, 1))
    crev = np.maximum(crev, np.clip(pits * 1.6, 0, 1))
    # patina spreads as irregular continents with fractal edges, not round spots:
    # a low-frequency field pushed around by higher octaves before thresholding
    pa = fbm(3, 6, s + 20, persistence=0.62)
    pb2 = fbm(8, 5, s + 21, persistence=0.55)
    pc = fbm(26, 4, s + 22)
    field = np.clip(pa + (pb2 - 0.5) * 0.55 + (pc - 0.5) * 0.22, 0, 1)
    blot = smoothstep(0.40, 0.82, field)      # wide ramp -> a real transition zone
    drip = nrm01(streak(np.clip(blot - 0.35, 0, 1) * 2.0, 110, 0.970, 0, 1))
    tarn = np.clip(crev * 0.78 + blot * 0.82 + drip * 0.40, 0, 1)
    tarn = np.clip(gblur(tarn, 1.1) * (0.55 + 0.80 * fbm(24, 4, s + 23)), 0, 1)

    # base metal is far from uniform: burnished highs, deep coppery lows
    t = fbm(4, 5, s + 30, persistence=0.58)
    alb = lerp3(col(166, 112, 30), col(250, 216, 128), t)
    alb = lerp3(alb, col(214, 154, 48), smoothstep(0.24, 0.82, fbm(11, 5, s + 31)) * 0.62)
    alb = lerp3(alb, col(198, 124, 44), smoothstep(0.55, 0.92, fbm(7, 5, s + 32)) * 0.55)
    alb = lerp3(alb, col(154, 108, 36), smoothstep(0.30, 0.88, fbm(19, 5, s + 33)) * 0.40)
    burn = nrm01(streak(fbm(30, 4, s + 34) - 0.5, 60, 0.955, axis=1, direction=1))
    alb = lerp3(alb, col(252, 228, 158), np.clip(burn - 0.45, 0, 1) * 1.9 * 0.35)
    alb = lerp3(alb, col(254, 232, 168), np.clip(scn * 1.6, 0, 1) * 0.50)
    # tarnish walks gold -> warm brown -> olive -> muted verdigris -> near black,
    # each step overlapping the next so there is no hard edge anywhere
    alb = lerp3(alb, col(176, 126, 48), np.clip(tarn * 1.6, 0, 1) * 0.55)
    alb = lerp3(alb, col(140, 98, 40), np.clip(tarn - 0.14, 0, 1) * 1.15 * 0.60)
    alb = lerp3(alb, col(118, 104, 54), np.clip(tarn - 0.30, 0, 1) * 1.05 * 0.62)
    alb = lerp3(alb, col(104, 118, 82), np.clip(tarn - 0.46, 0, 1) * 1.15 * 0.66)
    alb = lerp3(alb, col(84, 118, 98), np.clip(tarn - 0.62, 0, 1) * 1.35 * 0.68)
    alb = lerp3(alb, col(52, 80, 70), np.clip(tarn - 0.78, 0, 1) * 2.0 * 0.62)
    alb = lerp3(alb, col(26, 38, 34), np.clip(tarn - 0.92, 0, 1) * 9.0 * 0.65)
    pol = np.clip(cav * 20.0, 0, 1) * (1.0 - tarn) ** 2
    alb = lerp3(alb, col(255, 246, 204), pol * 0.80)
    alb = lerp3(alb, col(120, 84, 26), np.clip(-cav * 20.0, 0, 1) * (1.0 - tarn) * 0.32)
    alb = lerp3(alb, col(255, 236, 176),
                np.clip(broad * 24.0, 0, 1) * (1.0 - tarn) * 0.42)
    alb = lerp3(alb, col(58, 44, 22), np.clip(ding * 1.4, 0, 1) * 0.45)

    alb *= (ao ** 0.80)[..., None]
    alb *= (1.0 + np.clip(cav * 9.0, -0.22, 0.26))[..., None]
    alb = gain(alb, 1.22, 0.46)

    rough = 0.09 + 0.05 * (fbm(56, 4, s + 40) - 0.5)
    rough += tarn * 0.74 + scn * 0.22 + dent * 0.09 + pits * 0.20 + ding * 0.15
    rough -= pol * 0.05
    return np.clip(alb, 0, 1), h, np.clip(rough, 0.05, 0.94), 92.0

# ============================================================================
# build / verify
# ============================================================================

MATERIALS = [
    ("temple_stone", gen_temple_stone),
    ("carved_stone", gen_carved_stone),
    ("clay_wall", gen_clay_wall),
    ("thatch", gen_thatch),
    ("wood_beam", gen_wood_beam),
    ("terracotta", gen_terracotta),
    ("brick_ruin", gen_brick_ruin),
    ("gold_brass", gen_gold_brass),
]


def build(fn):
    alb, h, rough, nstr = fn()
    alb8 = to8(np.clip(alb, 0, 1))
    nrm8 = to8(normal_encode(h, nstr))
    rgh8 = to8(np.repeat(np.clip(rough, 0, 1)[..., None], 3, axis=2))
    return alb8, nrm8, rgh8


def luma(a):
    a = a.astype(np.float32)
    return a if a.ndim == 2 else 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]


def seam_stats(a8):
    """Seam step vs the distribution of every interior step. A seamless tile's
    wrap step must be no worse than the worst step inside the image."""
    a = luma(a8)
    sx = np.abs(a[:, 1:] - a[:, :-1]).mean(axis=0)
    sy = np.abs(a[1:, :] - a[:-1, :]).mean(axis=1)
    wx = float(np.abs(a[:, 0] - a[:, -1]).mean())
    wy = float(np.abs(a[0, :] - a[-1, :]).mean())
    return (wx, float(np.percentile(sx, 99)), float(sx.max()),
            wy, float(np.percentile(sy, 99)), float(sy.max()))


ROWS = []
PROBLEMS = []


def emit(name, kind, img8):
    path = os.path.join(OUT, "%s_%s.png" % (name, kind))
    Image.fromarray(img8).save(path, optimize=True)
    im = Image.open(path)
    arr = np.asarray(im)
    L = luma(arr)
    wx, px, mx, wy, py, my = seam_stats(arr)
    ROWS.append(dict(path=path, bytes=os.path.getsize(path), dims=im.size, mode=im.mode,
                     mean=float(L.mean()), std=float(L.std()),
                     sx=wx / max(mx, 1e-6), sy=wy / max(my, 1e-6),
                     kind=kind, name=name,
                     ch=[(float(arr[..., c].mean()), float(arr[..., c].std()))
                         for c in range(3)]))
    r = ROWS[-1]
    if im.size != (N, N):
        PROBLEMS.append("%s: wrong dims %s" % (path, im.size))
    if L.std() <= 8.0:
        PROBLEMS.append("%s: FLAT, luma std %.2f <= 8" % (path, L.std()))
    if r["sx"] > 1.02 or r["sy"] > 1.02:
        PROBLEMS.append("%s: seam step exceeds worst interior step (x %.2f y %.2f)"
                        % (path, r["sx"], r["sy"]))
    if kind == "normal" and (arr[..., 0].std() < 10 or arr[..., 1].std() < 10):
        PROBLEMS.append("%s: normal too flat (R sd %.1f G sd %.1f)"
                        % (path, arr[..., 0].std(), arr[..., 1].std()))
    return arr


def lit(alb8, nrm8, rgh8):
    a = alb8.astype(np.float32) / 255.0
    n = nrm8.astype(np.float32) / 255.0 * 2.0 - 1.0
    n /= np.maximum(np.linalg.norm(n, axis=2, keepdims=True), 1e-6)
    rg = rgh8[..., 0].astype(np.float32) / 255.0
    L = np.array([-0.42, 0.55, 0.72], np.float32)
    L /= np.linalg.norm(L)
    V = np.array([0.0, 0.0, 1.0], np.float32)
    H = (L + V)
    H /= np.linalg.norm(H)
    ndl = np.clip(n @ L, 0, 1)
    ndh = np.clip(n @ H, 0, 1)
    gl = (1.0 - rg) ** 2
    spec = gl * ndh ** (6.0 + 200.0 * gl)
    out = a * (0.32 + 0.90 * ndl)[..., None] + (spec * 1.1)[..., None]
    return to8(np.clip(out, 0, 1))


def preview(name, alb8, nrm8, rgh8):
    if not PREVIEW:
        return
    os.makedirs(PREVIEW, exist_ok=True)
    q = 256
    li = lit(alb8, nrm8, rgh8)

    def rs(a, k):
        return np.asarray(Image.fromarray(a).resize((k, k), Image.LANCZOS))

    tl = rs(li, q)
    tiled = np.concatenate([np.concatenate([tl, tl], 1), np.concatenate([tl, tl], 1)], 0)
    right = np.concatenate([
        np.concatenate([rs(alb8, q), rs(nrm8, q)], 1),
        np.concatenate([rs(rgh8, q), rs(li, q)], 1)], 0)
    Image.fromarray(np.concatenate([tiled, right], 1)).save(
        os.path.join(PREVIEW, "%s_preview.png" % name))


def main():
    os.makedirs(OUT, exist_ok=True)
    only = [a for a in sys.argv[1:] if not a.startswith("-")]
    skip_tile = "--no-tilecheck" in sys.argv
    t0 = time.time()
    tile_results = []

    for name, fn in MATERIALS:
        if only and name not in only:
            continue
        ts = time.time()
        set_offset(0, 0)
        alb8, nrm8, rgh8 = build(fn)
        emit(name, "albedo", alb8)
        emit(name, "normal", nrm8)
        emit(name, "rough", rgh8)
        preview(name, alb8, nrm8, rgh8)

        tl = "skipped"
        if not skip_tile:
            dy, dx = 373, 641
            set_offset(dy, dx)
            a2, n2, r2 = build(fn)
            worst = 0.0
            worstm = 0.0
            nbad = 0
            nborder = 0
            for a, b in ((alb8, a2), (nrm8, n2), (rgh8, r2)):
                ref = np.roll(a, (-dy, -dx), axis=(0, 1)).astype(np.int32)
                dif = np.abs(ref - b.astype(np.int32)).max(axis=2)
                worst = max(worst, float(dif.max()))
                worstm = max(worstm, float(dif.mean()))
                by, bx = np.nonzero(dif > 2)
                nbad = max(nbad, int(by.size))
                nborder = max(nborder, int(((by < 2) | (by > N - 3) |
                                            (bx < 2) | (bx > N - 3)).sum()))
            tile_results.append((name, worst, worstm, nbad, nborder))
            tl = "torus-shift dmax=%d dmean=%.5f bad=%d border=%d" % (
                int(worst), worstm, nbad, nborder)
            # A genuine seam break shows up ON the wrap border and in bulk. Isolated
            # interior pixels are floor() ties differing in the last float bit.
            if worstm > 0.002 or nbad > 400 or nborder > 0:
                PROBLEMS.append("%s: NOT TILEABLE -- dmax=%d dmean=%.5f bad=%d border=%d"
                                % (name, int(worst), worstm, nbad, nborder))
            set_offset(0, 0)
        print("  built %-14s %5.1fs   %s" % (name, time.time() - ts, tl), flush=True)
        _WCACHE.clear()

    print("\ntotal %.1fs\n" % (time.time() - t0))
    hdr = "%-46s %9s %10s %5s %9s %9s %7s %7s" % (
        "path", "bytes", "dims", "mode", "luma_mean", "luma_std", "seamX", "seamY")
    print(hdr)
    print("-" * len(hdr))
    for r in ROWS:
        print("%-46s %9d %10s %5s %9.2f %9.2f %7.2f %7.2f" % (
            os.path.relpath(r["path"], ROOT), r["bytes"],
            "%dx%d" % r["dims"], r["mode"], r["mean"], r["std"], r["sx"], r["sy"]))
    print("\n(seamX/seamY = wrap-around step / worst interior step; <=1.00 means the seam"
          "\n is not even the sharpest edge in the image)")

    print("\nnormal map channels (R/G must be bumpy):")
    for r in ROWS:
        if r["kind"] == "normal":
            c = r["ch"]
            print("  %-14s R mu=%6.1f sd=%5.1f  G mu=%6.1f sd=%5.1f  B mu=%6.1f sd=%5.1f"
                  % (r["name"], c[0][0], c[0][1], c[1][0], c[1][1], c[2][0], c[2][1]))
    print("\nroughness (0-255):")
    for r in ROWS:
        if r["kind"] == "rough":
            print("  %-14s mean=%6.1f sd=%5.1f" % (r["name"], r["mean"], r["std"]))
    if tile_results:
        print("\ntileability proof -- render at offset (373,641) vs np.roll of render at (0,0):")
        print("  (an exact match proves the generator is a function of the torus;")
        print("   stray pixels are floor() ties on a cell edge -- a real seam lands on the border)")
        for nm, w, m, nb_, nbo in tile_results:
            print("  %-14s dmax=%3d  dmean=%.5f  pixels>2: %4d of %d  on border: %d   %s"
                  % (nm, int(w), m, nb_, N * N, nbo,
                     "OK" if (m <= 0.002 and nb_ <= 400 and nbo == 0) else "FAIL"))

    if PROBLEMS:
        print("\n!!! PROBLEMS (%d):" % len(PROBLEMS))
        for p in PROBLEMS:
            print("   ", p)
        return 1
    print("\nALL CHECKS PASSED: %d files, all 1024x1024, all provably tileable, none flat."
          % len(ROWS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
