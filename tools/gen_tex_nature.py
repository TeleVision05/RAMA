#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RAMA - procedural VEGETATION / WATER / CHARACTER texture generator.

Everything here is synthesized from math (layered periodic Perlin/value/worley
noise, parametric leaf outlines, Gerstner wave sums, woven-thread models).
No external assets, no downloads -> 100% original and license-clean.

Art direction: Hampi sandstone / Western Ghats monsoon forest / Kerala
backwaters. Warm sun-baked earth, saffron & ochre, deep forest green,
terracotta, river blue-green, brass accents.

Outputs -> assets/textures/
"""
import os
import sys
import math
import time
import numpy as np
from PIL import Image

ROOT = "/Users/tarunvadapalli/Documents/Git/RAMA"
OUT = os.path.join(ROOT, "assets", "textures")
SHEETS = "/private/tmp/claude-501/-Users-tarunvadapalli-Documents-Git-UltraOpen/0cc70f8e-97e8-4264-a2ce-ba6d8721cbdc/scratchpad"
os.makedirs(OUT, exist_ok=True)
os.makedirs(SHEETS, exist_ok=True)

# path -> dict(tileable=bool, kind=str)
MANIFEST = {}


# ----------------------------------------------------------------------------
# math helpers
# ----------------------------------------------------------------------------
def _fade(t):
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0 + 1e-12), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def norm01(a):
    lo, hi = float(a.min()), float(a.max())
    if hi - lo < 1e-9:
        return np.zeros_like(a)
    return (a - lo) / (hi - lo)


def lerp(a, b, t):
    return a + (b - a) * t


def perlin(h, w, py, px, rng):
    """Tileable gradient (Perlin) noise. Lattice period (py, px) wraps exactly."""
    py = max(1, int(round(py)))
    px = max(1, int(round(px)))
    ang = rng.random((py, px)) * (2.0 * np.pi)
    ggx = np.cos(ang)
    ggy = np.sin(ang)
    ys = (np.arange(h) + 0.5) / h * py
    xs = (np.arange(w) + 0.5) / w * px
    y0 = np.floor(ys).astype(np.int64)
    x0 = np.floor(xs).astype(np.int64)
    ty = (ys - y0)[:, None]
    tx = (xs - x0)[None, :]
    i0 = y0 % py
    i1 = (y0 + 1) % py
    j0 = x0 % px
    j1 = (x0 + 1) % px

    def dot(iy, jx, dx, dy):
        return ggx[np.ix_(iy, jx)] * dx + ggy[np.ix_(iy, jx)] * dy

    n00 = dot(i0, j0, tx, ty)
    n01 = dot(i0, j1, tx - 1.0, ty)
    n10 = dot(i1, j0, tx, ty - 1.0)
    n11 = dot(i1, j1, tx - 1.0, ty - 1.0)
    u = _fade(tx)
    v = _fade(ty)
    return (((n00 * (1 - u) + n01 * u) * (1 - v) +
             (n10 * (1 - u) + n11 * u) * v) * 1.4142)


def fbm(h, w, py, px, rng, octaves=5, gain=0.5, lac=2, ridged=False):
    """Multi-octave tileable fractal noise. ridged -> 0..1 sharp ridges."""
    tot = np.zeros((h, w), np.float64)
    amp = 1.0
    nrm = 0.0
    for i in range(octaves):
        n = perlin(h, w, py * (lac ** i), px * (lac ** i), rng)
        if ridged:
            n = 1.0 - np.abs(n)
        tot += amp * n
        nrm += amp
        amp *= gain
    return tot / nrm


def worley(h, w, cy, cx, rng, jitter=1.0):
    """Tileable Worley/cellular noise -> (F1, F2) in pixel units."""
    cy = max(2, int(cy))
    cx = max(2, int(cx))
    jx = (rng.random((cy, cx)) - 0.5) * jitter + 0.5
    jy = (rng.random((cy, cx)) - 0.5) * jitter + 0.5
    u = ((np.arange(w) + 0.5) / w * cx)[None, :]
    v = ((np.arange(h) + 0.5) / h * cy)[:, None]
    ix = np.floor(u).astype(np.int64)
    iy = np.floor(v).astype(np.int64)
    sx = w / float(cx)
    sy = h / float(cy)
    f1 = np.full((h, w), 1e18)
    f2 = np.full((h, w), 1e18)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            ky = (iy + dy) % cy
            kx = (ix + dx) % cx
            ppx = (ix + dx) + jx[ky, kx]
            ppy = (iy + dy) + jy[ky, kx]
            dd = ((u - ppx) * sx) ** 2 + ((v - ppy) * sy) ** 2
            m = dd < f1
            f2 = np.where(m, f1, np.minimum(f2, dd))
            f1 = np.where(m, dd, f1)
    return np.sqrt(f1), np.sqrt(f2)


def gblur(img, sigma):
    """Wrapped (periodic) gaussian blur via FFT -> keeps tileability exact."""
    if sigma <= 0:
        return img
    h, w = img.shape
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.fftfreq(w)[None, :]
    k = np.exp(-2.0 * (np.pi ** 2) * (sigma ** 2) * (fx ** 2 + fy ** 2))
    return np.real(np.fft.ifft2(np.fft.fft2(img) * k))


def sample_wrap(img, X, Y):
    """Bilinear sample with wrap -> periodic domain warping."""
    h, w = img.shape
    x0 = np.floor(X).astype(np.int64)
    y0 = np.floor(Y).astype(np.int64)
    fx = X - x0
    fy = Y - y0
    x0 %= w
    y0 %= h
    x1 = (x0 + 1) % w
    y1 = (y0 + 1) % h
    return (img[y0, x0] * (1 - fx) * (1 - fy) + img[y0, x1] * fx * (1 - fy) +
            img[y1, x0] * (1 - fx) * fy + img[y1, x1] * fx * fy)


def warp(img, wx, wy, amount):
    """Periodic domain warp of `img` by noise fields wx/wy (pixels)."""
    h, w = img.shape
    Y, X = np.mgrid[0:h, 0:w].astype(np.float64)
    return sample_wrap(img, X + wx * amount, Y + wy * amount)


def flow_erode(H, iters=6, strength=0.35):
    """Cheap erosion-ish filter: material slumps toward lower neighbours."""
    H = H.copy()
    for _ in range(iters):
        mn = H.copy()
        for ax, sh in ((0, 1), (0, -1), (1, 1), (1, -1)):
            mn = np.minimum(mn, np.roll(H, sh, axis=ax))
        H = H * (1.0 - strength) + (0.5 * H + 0.5 * mn) * strength
    return H


def _upsample(g, h, w):
    gh, gw = g.shape
    ys = np.linspace(0, gh - 1, h)
    xs = np.linspace(0, gw - 1, w)
    y0 = np.clip(np.floor(ys).astype(np.int64), 0, gh - 2)
    x0 = np.clip(np.floor(xs).astype(np.int64), 0, gw - 2)
    fy = _fade((ys - y0))[:, None]
    fx = _fade((xs - x0))[None, :]
    a = g[np.ix_(y0, x0)]
    b = g[np.ix_(y0, x0 + 1)]
    c = g[np.ix_(y0 + 1, x0)]
    d = g[np.ix_(y0 + 1, x0 + 1)]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def local_fbm(shape, cells, rng, octaves=4, gain=0.5):
    """Non-tiling fbm for local stamps (leaves, petals)."""
    h, w = shape
    tot = np.zeros(shape)
    amp = 1.0
    nrm = 0.0
    for i in range(octaves):
        c = max(2, int(cells * (2 ** i)))
        g = rng.random((c, c)) * 2.0 - 1.0
        tot += amp * _upsample(g, h, w)
        nrm += amp
        amp *= gain
    return tot / nrm


# ----------------------------------------------------------------------------
# encode / write
# ----------------------------------------------------------------------------
def height_to_normal(H, strength=1.0, tileable=True, flat_mask=None):
    """Tangent-space OpenGL (+Y up) normal map from a height field."""
    if tileable:
        gx = (np.roll(H, -1, 1) - np.roll(H, 1, 1)) * 0.5
        gy = (np.roll(H, -1, 0) - np.roll(H, 1, 0)) * 0.5
    else:
        gy, gx = np.gradient(H)
    nx = -gx * strength
    ny = gy * strength          # image row increases downward -> +Y up
    nz = np.ones_like(H)
    l = np.sqrt(nx * nx + ny * ny + nz * nz)
    nx, ny, nz = nx / l, ny / l, nz / l
    if flat_mask is not None:
        nx = np.where(flat_mask, 0.0, nx)
        ny = np.where(flat_mask, 0.0, ny)
        nz = np.where(flat_mask, 1.0, nz)
    out = np.stack([nx, ny, nz], -1) * 0.5 + 0.5
    return np.clip(out * 255.0 + 0.5, 0, 255).astype(np.uint8)


def alpha_bleed(rgb, a, iters=28):
    """Dilate colour into transparent pixels so mips don't fringe."""
    rgb = rgb.copy()
    m = (a > 0.02).astype(np.float64)
    for _ in range(iters):
        wsum = np.zeros_like(m)
        csum = np.zeros_like(rgb)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                ww = np.roll(np.roll(m, dy, 0), dx, 1)
                cc = np.roll(np.roll(rgb, dy, 0), dx, 1)
                wgt = 1.0 if (dx == 0 or dy == 0) else 0.5
                wsum += ww * wgt
                csum += cc * ww[..., None] * wgt
        fill = (wsum > 0) & (m < 0.5)
        newc = np.where(fill[..., None], csum / np.maximum(wsum, 1e-6)[..., None], rgb)
        rgb = newc
        m = np.where(fill, 1.0, m)
        if m.min() > 0.5:
            break
    return rgb


def save_rgb(arr, path, kind="albedo", tileable=True):
    a = np.clip(arr, 0, 1)
    img = Image.fromarray((a * 255.0 + 0.5).astype(np.uint8), "RGB")
    p = os.path.join(OUT, path)
    img.save(p)
    MANIFEST[path] = dict(tileable=tileable, kind=kind)
    return p


def save_rgba(rgb, a, path, kind="atlas", tileable=False, sharpen=3.0):
    a = np.clip(a, 0, 1)
    if sharpen > 0:
        a = np.clip((a - 0.5) * sharpen + 0.5, 0, 1)
    rgb = alpha_bleed(np.clip(rgb, 0, 1), a)
    arr = np.concatenate([np.clip(rgb, 0, 1), a[..., None]], -1)
    img = Image.fromarray((arr * 255.0 + 0.5).astype(np.uint8), "RGBA")
    p = os.path.join(OUT, path)
    img.save(p)
    MANIFEST[path] = dict(tileable=tileable, kind=kind)
    return p


def save_normal_u8(u8, path, tileable=True):
    Image.fromarray(u8, "RGB").save(os.path.join(OUT, path))
    MANIFEST[path] = dict(tileable=tileable, kind="normal")


def save_gray(g, path, kind="rough", tileable=True):
    g = np.clip(g, 0, 1)
    u8 = (g * 255.0 + 0.5).astype(np.uint8)
    Image.fromarray(np.stack([u8] * 3, -1), "RGB").save(os.path.join(OUT, path))
    MANIFEST[path] = dict(tileable=tileable, kind=kind)


# ----------------------------------------------------------------------------
# LEAF ENGINE - parametric silhouettes (petiole + midrib + lamina outline)
# ----------------------------------------------------------------------------
def new_canvas(h, w, bg=(0.06, 0.13, 0.06)):
    return dict(rgb=np.tile(np.array(bg, np.float64), (h, w, 1)),
                a=np.zeros((h, w)), h=np.zeros((h, w)))


def _bbox(cv, pts, margin, clip):
    H, W = cv['a'].shape
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    x0 = int(math.floor(min(xs) - margin))
    x1 = int(math.ceil(max(xs) + margin))
    y0 = int(math.floor(min(ys) - margin))
    y1 = int(math.ceil(max(ys) + margin))
    cx0, cy0, cx1, cy1 = clip if clip else (0, 0, W, H)
    x0 = max(x0, cx0, 0); y0 = max(y0, cy0, 0)
    x1 = min(x1, cx1, W); y1 = min(y1, cy1, H)
    if x1 <= x0 + 1 or y1 <= y0 + 1:
        return None
    return x0, y0, x1, y1


def _composite(cv, box, cov, rgb, hh, z):
    x0, y0, x1, y1 = box
    sl = (slice(y0, y1), slice(x0, x1))
    c = np.clip(cov, 0, 1)
    cv['rgb'][sl] = cv['rgb'][sl] * (1 - c[..., None]) + rgb * c[..., None]
    cv['a'][sl] = cv['a'][sl] * (1 - c) + c
    cv['h'][sl] = cv['h'][sl] * (1 - c) + (hh + z) * c


def leaf_width_norm(a, b):
    ts = a / (a + b)
    return 1.0 / ((ts ** a) * ((1 - ts) ** b) + 1e-9)


def stamp_leaf(cv, bx, by, L, WD, ang, pr, rng, clip=None, z=0.0, shade=1.0):
    """Draw one leaf. bx,by = petiole attachment; ang in radians; L px long."""
    ca, sa = math.cos(ang), math.sin(ang)
    curve = pr.get('curve', 0.0)
    tipx = bx + ca * L - sa * curve * L
    tipy = by + sa * L + ca * curve * L
    box = _bbox(cv, [(bx, by), (tipx, tipy), ((bx + tipx) / 2, (by + tipy) / 2)],
                WD * 1.9 + 8, clip)
    if box is None:
        return
    x0, y0, x1, y1 = box
    Y, X = np.mgrid[y0:y1, x0:x1].astype(np.float64)
    X += 0.5; Y += 0.5
    rx = X - bx; ry = Y - by
    t = (rx * ca + ry * sa) / L
    s = (-rx * sa + ry * ca) - curve * L * (t * t)

    A = pr['a']; B = pr['b']
    K = leaf_width_norm(A, B)
    tc = np.clip(t, 0.0, 1.0)
    Wt = WD * K * (tc ** A) * ((1.0 - tc) ** B)
    # organic outline wobble (per-leaf random Fourier series)
    wob = pr.get('wob', 0.035)
    for k in (2, 3, 5, 8):
        Wt *= 1.0 + wob * rng.uniform(-1, 1) * np.sin(2 * np.pi * k * tc + rng.uniform(0, 6.28))
    # serrated / crenate margin
    serr = pr.get('serr', 0.0)
    if serr > 0:
        nser = pr.get('nser', 26)
        Wt *= 1.0 + serr * (np.abs(np.sin(np.pi * nser * tc)) ** 0.6 - 0.5)
    Wt = np.maximum(Wt, 0.0)

    absr = np.abs(s)
    d = np.where((t >= 0.0) & (t <= 1.0), Wt - absr, -1e3)
    # petiole
    pl = pr.get('petiole', 0.13)
    if pl > 0:
        wp = max(1.0, pr.get('pet_w', 0.017) * L)
        dp = wp * (1.0 + 0.55 * np.clip(-t / pl, 0, 1)) - absr
        d = np.maximum(d, np.where((t < 0) & (t >= -pl), dp, -1e3))
    cov = np.clip(d + 0.5, 0.0, 1.0)
    if cov.max() <= 0.002:
        return

    # ---- height field: midrib ridge + secondary veins + lamina cup
    u = np.clip(absr / np.maximum(Wt, 0.6), 0, 1)
    lam = np.clip(1.0 - u * u, 0, 1)
    hh = pr.get('cup', 0.30) * np.sqrt(lam)
    mid = np.exp(-(s / (pr.get('mid_w', 0.055) * WD + 0.9)) ** 2)
    hh = hh + pr.get('mid_amp', 0.85) * mid * (1.0 - 0.65 * tc)
    nv = pr.get('nv', 9)
    vph = tc * nv - u * 0.5 * nv + pr.get('vphase', 0.0)
    vein = np.exp(-((vph - np.round(vph)) / 0.17) ** 2) * np.clip(u * 3.0, 0, 1)
    hh = hh + pr.get('vein_amp', 0.24) * vein
    hh = hh * (1.0 - 0.35 * np.clip(-t / max(pl, 1e-6), 0, 1))

    # ---- albedo
    sh = (y1 - y0, x1 - x0)
    mott = local_fbm(sh, 2, rng, 4) * 0.5 + 0.5
    fine = local_fbm(sh, 12, rng, 3)
    cA = np.array(pr['col_a']); cB = np.array(pr['col_b'])
    tone = np.clip(mott * 1.25 - 0.12 + 0.25 * fine, 0, 1)[..., None]
    col = cA[None, None, :] * (1 - tone) + cB[None, None, :] * tone
    # margin darkening + slight lamina shading
    md = pr.get('margin_dark', 0.20)
    col = col * (1.0 - md + md * lam)[..., None]
    bd = pr.get('base_dark', 0.0)
    if bd > 0:
        col = col * (1.0 - bd * (1.0 - smoothstep(0.0, 0.60, tc)))[..., None]
    tl = pr.get('tip_light', 0.0)
    if tl > 0:
        col = col * (1.0 + tl * smoothstep(0.30, 1.0, tc))[..., None]
    # veins lighter than lamina
    vmask = np.clip(vein * 0.75 + mid * 1.0, 0, 1)[..., None]
    col = col * (1 - vmask * pr.get('vein_mix', 0.5)) + np.array(pr['vein_col'])[None, None, :] * (vmask * pr.get('vein_mix', 0.5))
    # dry / yellowed tip
    dry = pr.get('dry', 0.0)
    if dry > 0:
        dm = smoothstep(dry, min(0.999, dry + 0.30), tc + 0.16 * mott - 0.08)[..., None]
        col = col * (1 - dm * 0.92) + np.array(pr['dry_col'])[None, None, :] * dm * 0.92
    # blotches / age spots
    if pr.get('spots', 0.0) > 0:
        sp = smoothstep(0.55, 0.78, local_fbm(sh, 7, rng, 3) * 0.5 + 0.5)[..., None]
        col = col * (1 - sp * pr['spots']) + np.array(pr.get('spot_col', (0.36, 0.27, 0.10)))[None, None, :] * sp * pr['spots']
    # petiole colouring
    if pl > 0:
        pm = np.clip(-t / max(pl, 1e-6), 0, 1)[..., None]
        pcol = np.array(pr.get('pet_col', (0.34, 0.30, 0.15)))
        col = col * (1 - pm) + pcol[None, None, :] * pm
    col = col * (1.0 + 0.07 * fine)[..., None] * shade
    _composite(cv, box, cov, np.clip(col, 0, 1), hh, z)


def fit_len(bx, by, ang, L, clip, pad):
    """Shorten a leaf so its tip lands inside the atlas cell instead of being
    sliced flat by the cell border."""
    if clip is None:
        return L
    x0, y0, x1, y1 = clip
    if not (x0 <= bx <= x1 and y0 <= by <= y1):
        return L
    ca, sa = math.cos(ang), math.sin(ang)
    tmax = L
    for comp, o, lo, hi in ((ca, bx, x0, x1), (sa, by, y0, y1)):
        if abs(comp) < 1e-6:
            continue
        t = ((hi if comp > 0 else lo) - o) / comp
        tmax = min(tmax, t)
    return max(L * 0.30, min(L, tmax - pad))


def pick_side(bx, by, tang, spread, L, clip, pad, rng, prefer=None):
    """Keep the natural alternating fan, but flip a leaf to the other side of
    the twig when its preferred side would be cut short by the cell border."""
    cands = {}
    for side in (1, -1):
        ang = tang + side * spread + rng.uniform(-0.14, 0.14)
        cands[side] = (ang, fit_len(bx, by, ang, L, clip, pad))
    if prefer is None:
        best = max(cands.values(), key=lambda c: c[1])
        return best
    pc = cands[prefer]
    oc = cands[-prefer]
    if pc[1] >= 0.72 * L or oc[1] <= pc[1] * 1.20:
        return pc
    return oc


def bezier(p0, p1, p2, n=24):
    ts = np.linspace(0, 1, n)
    pts = []
    for t in ts:
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]
        pts.append((x, y))
    return pts


def stamp_stem(cv, pts, w0, w1, col, rng, clip=None, z=0.0, shade=1.0, rough=0.0):
    box = _bbox(cv, pts, max(w0, w1) + 3, clip)
    if box is None:
        return
    x0, y0, x1, y1 = box
    Y, X = np.mgrid[y0:y1, x0:x1].astype(np.float64)
    X += 0.5; Y += 0.5
    seg = np.array(pts)
    dl = np.sqrt(((seg[1:] - seg[:-1]) ** 2).sum(1))
    cum = np.concatenate([[0], np.cumsum(dl)])
    total = max(cum[-1], 1e-6)
    best = np.full(X.shape, -1e9)
    hbest = np.zeros(X.shape)
    for i in range(len(pts) - 1):
        ax, ay = pts[i]; bx2, by2 = pts[i + 1]
        vx, vy = bx2 - ax, by2 - ay
        ll = vx * vx + vy * vy + 1e-9
        tt = np.clip(((X - ax) * vx + (Y - ay) * vy) / ll, 0, 1)
        dx = X - (ax + tt * vx); dy = Y - (ay + tt * vy)
        dist = np.sqrt(dx * dx + dy * dy)
        f = (cum[i] + tt * dl[i]) / total
        wdt = w0 + (w1 - w0) * f
        val = wdt - dist
        m = val > best
        best = np.where(m, val, best)
        hbest = np.where(m, np.clip(1.0 - (dist / np.maximum(wdt, 0.5)) ** 2, 0, 1), hbest)
    cov = np.clip(best + 0.5, 0, 1)
    if cov.max() <= 0.002:
        return
    sh = (y1 - y0, x1 - x0)
    n = local_fbm(sh, 4, rng, 3)
    c = np.array(col)[None, None, :] * (1.0 + 0.16 * n)[..., None] * shade
    if rough > 0:
        c = c * (1.0 + rough * local_fbm(sh, 16, rng, 2))[..., None]
    _composite(cv, box, cov, np.clip(c, 0, 1), 0.55 * np.sqrt(hbest), z)


# ---- species parameter sets -------------------------------------------------
BANYAN = dict(a=0.60, b=0.98, nv=8, margin_dark=0.30, wob=0.030, curve=0.10, petiole=0.15,
              col_a=(0.085, 0.225, 0.085), col_b=(0.205, 0.420, 0.150),
              vein_col=(0.435, 0.575, 0.255), vein_mix=0.42, mid_w=0.055,
              mid_amp=0.90, cup=0.34, spots=0.0,
              dry_col=(0.62, 0.52, 0.16), pet_col=(0.40, 0.34, 0.16))
MANGO = dict(a=0.56, b=1.02, nv=13, margin_dark=0.28, wob=0.022, curve=0.12, petiole=0.11,
             col_a=(0.045, 0.150, 0.058), col_b=(0.125, 0.300, 0.105),
             vein_col=(0.300, 0.420, 0.180), vein_mix=0.34, mid_w=0.048,
             mid_amp=0.80, cup=0.26, spots=0.0,
             dry_col=(0.44, 0.26, 0.12), pet_col=(0.32, 0.26, 0.13))
PALMB = dict(a=0.26, b=0.52, nv=3, wob=0.018, curve=0.06, petiole=0.0,
             col_a=(0.135, 0.300, 0.100), col_b=(0.265, 0.470, 0.165),
             vein_col=(0.330, 0.500, 0.200), vein_mix=0.30, mid_w=0.16,
             mid_amp=1.05, cup=0.42, vein_amp=0.05,
             dry=0.72, dry_col=(0.585, 0.455, 0.205))


def gen_leaf_banyan(rng, S=1024):
    cv = new_canvas(S, S, (0.055, 0.115, 0.050))
    C = S // 2
    for gy in range(2):
        for gx in range(2):
            clip = (gx * C, gy * C, (gx + 1) * C, (gy + 1) * C)
            ox, oy = gx * C, gy * C
            tws = []
            for k in range(3):
                fx = 0.22 + 0.28 * k + rng.uniform(-0.04, 0.04)
                root = (ox + C * (0.5 + (fx - 0.5) * 0.55) + rng.uniform(-10, 10),
                        oy + C * 1.03)
                tip = (ox + C * fx, oy + C * rng.uniform(0.12, 0.28))
                mid = (ox + C * (0.5 + (fx - 0.5) * 0.80) + rng.uniform(-14, 14),
                       oy + C * rng.uniform(0.50, 0.66))
                tws.append(bezier(root, mid, tip, 20))
            for tw in tws:
                stamp_stem(cv, tw, C * 0.020, C * 0.006, (0.320, 0.262, 0.150),
                           rng, clip, z=0.0, shade=0.85)
            jobs = []
            for ti, tw in enumerate(tws):
                nl = int(rng.integers(7, 9))
                for i in range(nl):
                    jobs.append(((i + 0.5) / nl, tw, 1 if i % 2 == 0 else -1))
            jobs.sort(key=lambda j: j[0])
            for jn, (f, tw, side) in enumerate(jobs):
                depth = jn / max(1, len(jobs) - 1)
                idx = int(f * (len(tw) - 1))
                px, py = tw[idx]
                j = min(len(tw) - 1, idx + 1)
                k = max(0, idx - 1)
                tang = math.atan2(tw[j][1] - tw[k][1], tw[j][0] - tw[k][0])
                L = C * rng.uniform(0.23, 0.31) * (1.0 - 0.14 * f)
                WD = L * rng.uniform(0.44, 0.56)
                ang, L = pick_side(px, py, tang, rng.uniform(0.70, 1.40), L,
                                   clip, 4 + 0.40 * WD, rng, prefer=side)
                pr = dict(BANYAN)
                pr['curve'] = rng.uniform(-0.18, 0.18)
                pr['vphase'] = rng.random()
                r = rng.random()
                if r < 0.20:            # older yellowing leaf
                    pr['col_a'] = (0.245, 0.270, 0.078)
                    pr['col_b'] = (0.505, 0.455, 0.125)
                    pr['vein_col'] = (0.575, 0.510, 0.195)
                    pr['spots'] = 0.38
                elif r < 0.30:          # fresh light growth
                    pr['col_a'] = (0.170, 0.340, 0.115)
                    pr['col_b'] = (0.330, 0.545, 0.200)
                elif r < 0.38:
                    pr['spots'] = 0.22
                stamp_leaf(cv, px, py, L, WD, ang, pr, rng, clip,
                           z=0.12 * depth, shade=0.50 + 0.56 * depth)
    return cv


def gen_leaf_mango(rng, S=1024):
    cv = new_canvas(S, S, (0.035, 0.095, 0.040))
    C = S // 2
    for gy in range(2):
        for gx in range(2):
            clip = (gx * C, gy * C, (gx + 1) * C, (gy + 1) * C)
            ox, oy = gx * C, gy * C
            base = (ox + C * (0.46 + 0.10 * rng.random()), oy + C * 1.02)
            tip = (ox + C * (0.40 + 0.22 * rng.random()), oy + C * rng.uniform(0.30, 0.46))
            stem = bezier(base, (base[0] + rng.uniform(-24, 24), oy + C * 0.72), tip, 16)
            stamp_stem(cv, stem, C * 0.017, C * 0.009, (0.285, 0.230, 0.125),
                       rng, clip, z=0.0, shade=0.85)
            nl = int(rng.integers(13, 17))
            jobs = []
            for i in range(nl):
                f = (i + 0.45) / nl
                side = 1 if (i % 2 == 0) else -1
                if rng.random() < 0.2:
                    side = -side
                jobs.append((f, side))
            jobs.sort(key=lambda j: -abs(j[0] - 0.5))
            for jn, (f, side) in enumerate(jobs):
                depth = jn / max(1, len(jobs) - 1)
                idx = int(f * (len(stem) - 1))
                px, py = stem[idx]
                j = min(len(stem) - 1, idx + 1)
                k = max(0, idx - 1)
                tang = math.atan2(stem[j][1] - stem[k][1], stem[j][0] - stem[k][0])
                # upper leaves stand up, lower ones droop past horizontal
                spread = 0.42 + 1.45 * (1.0 - f) ** 0.8
                L = C * rng.uniform(0.40, 0.60) * (0.80 + 0.30 * f)
                WD = L * rng.uniform(0.165, 0.225)
                ang, L = pick_side(px, py, tang, spread, L, clip,
                                   5 + 0.5 * WD, rng, prefer=side)
                pr = dict(MANGO)
                pr['curve'] = side * rng.uniform(0.05, 0.26)   # droop away from stem
                pr['vphase'] = rng.random()
                r = rng.random()
                if r < 0.09:            # new copper-red flush
                    pr['col_a'] = (0.200, 0.105, 0.068)
                    pr['col_b'] = (0.365, 0.200, 0.110)
                    pr['vein_col'] = (0.430, 0.280, 0.145)
                elif r < 0.22:
                    pr['col_a'] = (0.130, 0.230, 0.068)
                    pr['col_b'] = (0.280, 0.375, 0.110)
                stamp_leaf(cv, px, py, L, WD, ang, pr, rng, clip,
                           z=0.12 * depth, shade=0.58 + 0.42 * depth)
    return cv


def gen_leaf_palm(rng, S=1024):
    cv = new_canvas(S, S, (0.075, 0.145, 0.055))
    C = S // 2
    for gy in range(2):
        for gx in range(2):
            clip = (gx * C, gy * C, (gx + 1) * C, (gy + 1) * C)
            ox, oy = gx * C, gy * C
            p0 = (ox + C * 0.05, oy + C * (0.88 + 0.07 * rng.random()))
            p2 = (ox + C * 0.90, oy + C * (0.14 + 0.10 * rng.random()))
            p1 = (ox + C * 0.44, oy + C * (0.34 + 0.16 * rng.random()))
            rach = bezier(p0, p1, p2, 40)
            nb = 30
            # back row (far side of rachis) then front row -> depth
            for pas, sgn in ((0, -1), (1, 1)):
                for i in range(nb):
                    f = (i + 0.5) / nb
                    idx = int(f * (len(rach) - 1))
                    px, py = rach[idx]
                    j = min(len(rach) - 1, idx + 1)
                    dx = rach[j][0] - rach[max(0, idx - 1)][0]
                    dy = rach[j][1] - rach[max(0, idx - 1)][1]
                    rang = math.atan2(dy, dx)
                    spread = 1.02 - 0.42 * f
                    ang = rang + sgn * (spread + rng.uniform(-0.11, 0.11))
                    L = C * (0.46 * (1.0 - 0.55 * f ** 1.6)) * rng.uniform(0.86, 1.10)
                    WD = L * rng.uniform(0.052, 0.080)
                    L = fit_len(px, py, ang, L, clip, 5 + 1.2 * WD)
                    pr = dict(PALMB)
                    pr['curve'] = sgn * rng.uniform(0.06, 0.22)
                    pr['dry'] = rng.uniform(0.60, 0.86)
                    if rng.random() < 0.10:
                        pr['col_a'] = (0.235, 0.330, 0.095)
                        pr['col_b'] = (0.400, 0.460, 0.140)
                    stamp_leaf(cv, px, py, L, WD, ang, pr, rng, clip,
                               z=0.06 * pas, shade=(0.60 if pas == 0 else 0.90) + 0.16 * f)
            stamp_stem(cv, rach, C * 0.026, C * 0.006, (0.415, 0.375, 0.165),
                       rng, clip, z=0.22, rough=0.10)
    return cv


def gen_grass(rng, S=512):
    cv = new_canvas(S, S, (0.10, 0.16, 0.055))
    GR = dict(a=0.05, b=0.72, nv=2, wob=0.020, petiole=0.0, mid_w=0.30,
              mid_amp=0.55, cup=0.30, vein_amp=0.05,
              col_a=(0.135, 0.250, 0.070), col_b=(0.330, 0.450, 0.120),
              vein_col=(0.330, 0.430, 0.150), vein_mix=0.25,
              dry=0.80, dry_col=(0.560, 0.480, 0.180))
    blades = []
    n = 54
    for i in range(n):
        x = (i + 0.5) / n * S + rng.uniform(-5, 5)
        L = S * rng.uniform(0.30, 0.90)
        blades.append((x, L, i))
    blades.sort(key=lambda b: b[1])          # short (back) first
    for k, (x, L, i) in enumerate(blades):
        f = k / max(1, len(blades) - 1)
        ang = -math.pi / 2 + rng.uniform(-0.30, 0.30)
        WD = S * rng.uniform(0.010, 0.020) * (0.75 + 0.5 * (L / S))
        pr = dict(GR)
        pr['curve'] = rng.uniform(-0.34, 0.34)
        pr['dry'] = rng.uniform(0.62, 0.95)
        if rng.random() < 0.18:
            pr['col_a'] = (0.250, 0.290, 0.075)
            pr['col_b'] = (0.470, 0.450, 0.130)
        stamp_leaf(cv, x, S + rng.uniform(2, 10), L, WD, ang, pr, rng,
                   z=0.10 * f, shade=0.62 + 0.38 * f)
    # dense opaque root mat along the bottom edge
    for i in range(70):
        x = rng.uniform(-4, S + 4)
        L = S * rng.uniform(0.06, 0.17)
        pr = dict(GR); pr['dry'] = 0.9
        pr['col_a'] = (0.085, 0.160, 0.050); pr['col_b'] = (0.200, 0.300, 0.085)
        stamp_leaf(cv, x, S + 6, L, S * rng.uniform(0.012, 0.024),
                   -math.pi / 2 + rng.uniform(-0.5, 0.5), pr, rng, z=0.0, shade=0.7)
    cv['a'][S - 3:, :] = 1.0
    cv['rgb'][S - 3:, :, :] = np.clip(cv['rgb'][S - 3:, :, :] * 0.75 + 0.02, 0, 1)
    return cv


# ----------------------------------------------------------------------------
# FLOWERS
# ----------------------------------------------------------------------------
def blossom_marigold(cv, cx, cy, R, rng, clip=None, z=0.0):
    deep = [(0.560, 0.185, 0.020), (0.870, 0.400, 0.030)]
    bright = [(0.800, 0.330, 0.020), (0.985, 0.640, 0.075)]
    rings = ((0.30, 8, 0.50, 0), (0.55, 11, 0.66, 0), (0.79, 14, 0.84, 1), (1.00, 17, 1.0, 1))
    for ri, (rf, cnt, br, pal) in enumerate(rings):
        ca, cb = (deep if pal == 0 else bright)
        for i in range(cnt):
            ang = 2 * np.pi * i / cnt + ri * 0.42 + rng.uniform(-0.08, 0.08)
            r0 = R * rf * 0.30
            pr = dict(a=1.05, b=0.62, nv=3, wob=0.085, petiole=0.0, mid_w=0.20,
                      mid_amp=0.55, cup=0.62, vein_amp=0.10, vein_mix=0.16,
                      col_a=ca, col_b=cb, vein_col=(0.99, 0.78, 0.30),
                      margin_dark=0.38, base_dark=0.52, tip_light=0.22,
                      serr=0.16, nser=2, curve=rng.uniform(-0.14, 0.14))
            L = R * rf * 0.86 * rng.uniform(0.86, 1.12)
            stamp_leaf(cv, cx + math.cos(ang) * r0, cy + math.sin(ang) * r0,
                       L, L * rng.uniform(0.40, 0.54), ang, pr, rng, clip,
                       z=z + 0.03 * ri, shade=br * rng.uniform(0.88, 1.08))
    stamp_stem(cv, [(cx, cy), (cx + 0.4, cy + 0.4)], R * 0.13, R * 0.11,
               (0.42, 0.135, 0.020), rng, clip, z=z + 0.2)


def blossom_hibiscus(cv, cx, cy, R, rng, clip=None, z=0.0):
    base = rng.uniform(0, 6.28)
    for i in range(5):
        ang = base + 2 * np.pi * i / 5 + rng.uniform(-0.06, 0.06)
        pr = dict(a=1.22, b=0.34, nv=9, wob=0.055, serr=0.13, nser=5, petiole=0.0,
                  mid_w=0.09, mid_amp=0.60, cup=0.44, vein_amp=0.22, vein_mix=0.34,
                  col_a=(0.330, 0.014, 0.038), col_b=(0.880, 0.145, 0.120),
                  vein_col=(0.470, 0.040, 0.055), margin_dark=0.40,
                  base_dark=0.62, tip_light=0.16, curve=rng.uniform(-0.12, 0.12))
        L = R * rng.uniform(0.92, 1.08)
        stamp_leaf(cv, cx, cy, L, L * rng.uniform(0.56, 0.70), ang, pr, rng, clip,
                   z=z + 0.02 * i, shade=(0.78 + 0.06 * i) * rng.uniform(0.94, 1.06))
    # throat + staminal column
    stamp_stem(cv, [(cx, cy), (cx + 1, cy + 1)], R * 0.20, R * 0.16,
               (0.640, 0.220, 0.090), rng, clip, z=z + 0.2)
    ta = base + rng.uniform(-0.6, 0.6)
    ex, ey = cx + math.cos(ta) * R * 0.72, cy + math.sin(ta) * R * 0.72
    stamp_stem(cv, [(cx, cy), (ex, ey)], R * 0.055, R * 0.030,
               (0.930, 0.560, 0.150), rng, clip, z=z + 0.3)
    for k in range(7):
        rr = rng.uniform(0.45, 0.80)
        px = cx + math.cos(ta) * R * rr + rng.uniform(-3, 3)
        py = cy + math.sin(ta) * R * rr + rng.uniform(-3, 3)
        stamp_stem(cv, [(px, py), (px + 0.6, py + 0.6)], R * 0.035, R * 0.030,
                   (0.990, 0.820, 0.220), rng, clip, z=z + 0.35)


def blossom_jasmine(cv, cx, cy, R, rng, clip=None, z=0.0):
    base = rng.uniform(0, 6.28)
    np_ = rng.integers(6, 8)
    for i in range(np_):
        ang = base + 2 * np.pi * i / np_ + rng.uniform(-0.05, 0.05)
        pr = dict(a=0.72, b=0.62, nv=3, wob=0.05, petiole=0.0, mid_w=0.14,
                  mid_amp=0.45, cup=0.45, vein_amp=0.08, vein_mix=0.18,
                  col_a=(0.820, 0.808, 0.735), col_b=(0.995, 0.990, 0.960),
                  vein_col=(0.905, 0.915, 0.845), margin_dark=0.30,
                  base_dark=0.34, tip_light=0.10, curve=rng.uniform(-0.10, 0.10))
        L = R * rng.uniform(0.90, 1.05)
        stamp_leaf(cv, cx, cy, L, L * rng.uniform(0.36, 0.48), ang, pr, rng, clip,
                   z=z + 0.02 * i, shade=0.86 + 0.04 * i)
    stamp_stem(cv, [(cx, cy), (cx + 0.5, cy + 0.5)], R * 0.16, R * 0.13,
               (0.960, 0.880, 0.480), rng, clip, z=z + 0.2)


def gen_flowers(rng, S=512):
    cv = new_canvas(S, S, (0.10, 0.11, 0.06))
    LEAF = dict(a=0.60, b=0.80, nv=7, wob=0.03, petiole=0.05, mid_w=0.06,
                mid_amp=0.7, cup=0.28, vein_mix=0.32,
                col_a=(0.070, 0.180, 0.070), col_b=(0.170, 0.330, 0.120),
                vein_col=(0.300, 0.430, 0.190), pet_col=(0.24, 0.30, 0.12))
    spots = [(0.20, 0.26, 'mar', 62), (0.74, 0.20, 'mar', 52), (0.46, 0.62, 'mar', 58),
             (0.20, 0.74, 'hib', 66), (0.78, 0.66, 'hib', 60),
             (0.50, 0.16, 'jas', 26), (0.62, 0.40, 'jas', 22), (0.14, 0.50, 'jas', 24),
             (0.86, 0.42, 'jas', 20), (0.36, 0.90, 'jas', 23), (0.66, 0.90, 'jas', 21)]
    # stems + foliage first (behind the blossoms)
    for fx, fy, kind, R in spots:
        cx, cy = fx * S, fy * S
        ex, ey = cx + rng.uniform(-30, 30), min(S + 20, cy + rng.uniform(70, 150))
        pts = bezier((cx, cy), ((cx + ex) / 2 + rng.uniform(-16, 16), (cy + ey) / 2), (ex, ey), 12)
        stamp_stem(cv, pts, 3.2, 2.0, (0.135, 0.230, 0.090), rng, z=-0.2, shade=0.9)
        for k in range(2):
            t = rng.uniform(0.35, 0.85)
            idx = int(t * (len(pts) - 1))
            L = rng.uniform(26, 46)
            ang = rng.uniform(-2.6, -0.5)
            stamp_leaf(cv, pts[idx][0], pts[idx][1], L, L * 0.34, ang,
                       dict(LEAF, curve=rng.uniform(-0.15, 0.15)), rng,
                       z=-0.1, shade=0.72 + 0.2 * rng.random())
    for fx, fy, kind, R in spots:
        cx, cy = fx * S, fy * S
        if kind == 'mar':
            blossom_marigold(cv, cx, cy, R, rng, z=0.4)
        elif kind == 'hib':
            blossom_hibiscus(cv, cx, cy, R, rng, z=0.5)
        else:
            for k in range(int(rng.integers(3, 5))):
                blossom_jasmine(cv, cx + rng.uniform(-R, R), cy + rng.uniform(-R, R),
                                R * rng.uniform(0.7, 1.0), rng, z=0.6 + 0.05 * k)
    return cv


def write_foliage(name, cv, with_normal=True, strength=9.0):
    a = np.clip(cv['a'], 0, 1)
    hard = np.clip((a - 0.5) * 3.0 + 0.5, 0, 1)
    save_rgba(cv['rgb'], a, name + ".png", kind="foliage", sharpen=3.0)
    if with_normal:
        H = gblur(cv['h'] * (hard > 0.35), 0.7)
        n = height_to_normal(H, strength=strength, tileable=False,
                             flat_mask=(hard < 0.35))
        save_normal_u8(n, name + "_normal.png", tileable=False)


# ----------------------------------------------------------------------------
# BARK
# ----------------------------------------------------------------------------
def gen_bark_banyan(rng, S=1024):
    wx = fbm(S, S, 5, 9, rng, 4) * 30.0
    wy = fbm(S, S, 5, 9, rng, 4) * 7.0
    r1 = norm01(warp(fbm(S, S, 2, 15, rng, octaves=5, gain=0.50, ridged=True), wx, wy, 1.0))
    r2 = norm01(warp(fbm(S, S, 3, 31, rng, octaves=4, gain=0.50, ridged=True), wx * 0.5, wy * 0.5, 1.0))
    ridge = smoothstep(0.18, 0.82, np.clip(r1 * 0.78 + r2 * 0.34, 0, 1))
    plates = smoothstep(0.50, 0.94, norm01(fbm(S, S, 20, 4, rng, 4, ridged=True)))
    coarse = norm01(fbm(S, S, 2, 3, rng, 3))
    H = ridge * (0.70 + 0.42 * coarse) - 0.34 * plates * ridge
    H = np.clip(H, 0, None) + 0.11 * fbm(S, S, 12, 46, rng, 4, ridged=True)
    H = flow_erode(norm01(H), iters=3, strength=0.30)

    Y, X = np.mgrid[0:S, 0:S].astype(np.float64)
    strand = np.zeros((S, S))
    for i in range(4):
        x0 = rng.uniform(0, S)
        k1 = int(rng.integers(1, 3))
        k2 = int(rng.integers(3, 6))
        A1 = rng.uniform(14, 44)
        A2 = rng.uniform(5, 15)
        p1 = rng.uniform(0, 6.28)
        p2 = rng.uniform(0, 6.28)
        xc = x0 + A1 * np.sin(2 * np.pi * k1 * Y / S + p1) + A2 * np.sin(2 * np.pi * k2 * Y / S + p2)
        dx = (X - xc + S * 0.5) % S - S * 0.5
        wdt = rng.uniform(11, 26) * (0.82 + 0.34 * np.sin(2 * np.pi * (k1 + 2) * Y / S + p2))
        strand = np.maximum(strand, np.clip(1.0 - (dx / wdt) ** 2, 0, 1) ** 0.55)
    strand = gblur(strand, 1.6)
    sgrain = 0.14 * fbm(S, S, 8, 34, rng, 3, ridged=True)
    H = np.clip(H * (1 - 0.55 * strand) + strand * (0.70 + sgrain), 0, 1.6)
    H = norm01(H)

    d = norm01(H)
    c_deep = np.array([0.050, 0.038, 0.030])
    c_mid = np.array([0.255, 0.205, 0.150])
    c_ridge = np.array([0.620, 0.578, 0.500])
    t1 = smoothstep(0.0, 0.50, d)[..., None]
    t2 = smoothstep(0.44, 1.0, d)[..., None]
    col = c_deep + (c_mid - c_deep) * t1
    col = col * (1 - t2) + c_ridge * t2
    dust = smoothstep(0.35, 0.85, norm01(fbm(S, S, 3, 4, rng, 4)))[..., None]
    col = col * (1 - 0.32 * dust) + np.array([0.505, 0.400, 0.255])[None, None, :] * 0.32 * dust
    lich = smoothstep(0.62, 0.88, norm01(fbm(S, S, 5, 5, rng, 5))) * smoothstep(0.50, 0.85, d)
    col = col * (1 - 0.58 * lich[..., None]) + np.array([0.545, 0.570, 0.430])[None, None, :] * 0.58 * lich[..., None]
    moss = smoothstep(0.55, 0.90, norm01(fbm(S, S, 6, 7, rng, 5))) * (1 - smoothstep(0.10, 0.42, d))
    col = col * (1 - 0.62 * moss[..., None]) + np.array([0.105, 0.175, 0.075])[None, None, :] * 0.62 * moss[..., None]
    col = col * (0.86 + 0.28 * norm01(fbm(S, S, 10, 40, rng, 4, ridged=True)))[..., None]
    rootc = np.array([0.352, 0.300, 0.236])
    rootv = (0.78 + 0.44 * norm01(fbm(S, S, 9, 36, rng, 4, ridged=True)))[..., None]
    sm = np.clip(strand * 1.15, 0, 1)[..., None]
    col = np.clip(col * (1 - 0.85 * sm) + rootc[None, None, :] * rootv * 0.85 * sm, 0, 1)

    rough = 1.0 - 0.45 * d - 0.12 * lich + 0.05 * moss + 0.07 * (norm01(H) - 0.5)
    rough = np.clip(rough, 0.45, 1.0)
    save_rgb(col, "bark_banyan.png")
    save_normal_u8(height_to_normal(H * 30.0, 1.0), "bark_banyan_normal.png")
    save_gray(rough, "bark_banyan_rough.png")


def gen_bark_palm(rng, S=1024):
    Y, X = np.mgrid[0:S, 0:S].astype(np.float64)
    NR = 11
    # ring spacing varies (periodic harmonics keep it exactly tileable in Y),
    # ring lines wave across X (integer harmonics keep X tileable)
    wave = np.zeros((S, S))
    for k, amp in ((1, 0.17), (2, 0.09), (3, 0.055), (5, 0.03)):
        wave += amp * np.sin(2 * np.pi * k * X / S + rng.uniform(0, 6.28))
    spacing = 0.26 * np.sin(2 * np.pi * 2 * Y / S + rng.uniform(0, 6.28)) + \
              0.14 * np.sin(2 * np.pi * 3 * Y / S + rng.uniform(0, 6.28))
    wob = fbm(S, S, 3, 5, rng, 4) * 0.20 + fbm(S, S, 7, 13, rng, 3) * 0.07
    ph = (Y / S) * NR + spacing + wave + wob * 1.5
    ring = np.floor(ph).astype(np.int64) % NR
    f = ph - np.floor(ph)
    rh = 0.72 + 0.55 * rng.random(NR)          # per-ring pad height
    rc = 0.78 + 0.44 * rng.random(NR)          # per-ring tone
    rw = 0.62 + 0.30 * rng.random(NR)          # per-ring pad width
    pad = smoothstep(0.03, 0.40, f) * (1.0 - smoothstep(rw[ring], np.minimum(rw[ring] + 0.24, 0.99), f))
    pad = pad * rh[ring]
    groove = (1.0 - smoothstep(0.0, 0.09, f)) + smoothstep(0.93, 1.0, f)
    fib = fbm(S, S, 5, 150, rng, 5, ridged=True)
    fib2 = fbm(S, S, 11, 70, rng, 4)
    husk = fbm(S, S, 24, 22, rng, 4, ridged=True)
    H = 0.66 * pad - 0.60 * np.clip(groove, 0, 1) + 0.26 * fib + 0.10 * fib2 + 0.07 * husk
    tear = smoothstep(0.50, 0.94, norm01(fbm(S, S, 9, 105, rng, 4, ridged=True)))
    H = H - 0.26 * tear * (1 - smoothstep(0.20, 0.55, np.abs(f - 0.5) * 2))
    H = norm01(gblur(H, 0.55))

    d = norm01(H)
    c_dark = np.array([0.150, 0.105, 0.062])
    c_tan = np.array([0.600, 0.478, 0.305])
    c_pale = np.array([0.795, 0.712, 0.545])
    t1 = smoothstep(0.05, 0.58, d)[..., None]
    t2 = smoothstep(0.60, 1.0, d)[..., None]
    col = c_dark + (c_tan - c_dark) * t1
    col = col * (1 - t2) + c_pale * t2
    col = col * rc[ring][..., None]                      # ring-to-ring tone
    grey = smoothstep(0.55, 0.90, norm01(fbm(S, S, 4, 4, rng, 4)))[..., None]
    col = col * (1 - 0.38 * grey) + np.array([0.560, 0.540, 0.495])[None, None, :] * 0.38 * grey
    warm = smoothstep(0.40, 0.85, norm01(fbm(S, S, 5, 3, rng, 4)))[..., None]
    col = col * (1 - 0.28 * warm) + np.array([0.685, 0.450, 0.205])[None, None, :] * 0.28 * warm
    col = col * (0.80 + 0.40 * norm01(fib))[..., None]
    col = np.clip(col * (0.92 + 0.18 * norm01(fib2))[..., None], 0, 1)

    rough = np.clip(0.99 - 0.42 * d + 0.16 * tear + 0.12 * (norm01(fib) - 0.5), 0.40, 1.0)
    save_rgb(col, "bark_palm.png")
    save_normal_u8(height_to_normal(H * 26.0, 1.0), "bark_palm_normal.png")
    save_gray(rough, "bark_palm_rough.png")


# ----------------------------------------------------------------------------
# WATER
# ----------------------------------------------------------------------------
def gen_water(rng, S=1024):
    Y, X = np.mgrid[0:S, 0:S].astype(np.float64)
    u = X / S
    v = Y / S
    H = np.zeros((S, S))
    # Gerstner-like: sharpened sine crests on integer wave vectors (exact tiling).
    # Two wind families (a dominant swell + a cross chop) keep it directional.
    waves = [(2, 1, 1.00, 3.4), (3, 1, 0.80, 3.0), (4, 2, 0.62, 2.8),
             (5, 1, 0.52, 2.6), (6, 3, 0.44, 2.4), (7, 2, 0.38, 2.3),
             (9, 4, 0.30, 2.1), (11, 3, 0.26, 2.0), (13, 5, 0.21, 1.8),
             (16, 7, 0.17, 1.7), (19, 6, 0.14, 1.6), (23, 9, 0.11, 1.5),
             (29, 11, 0.085, 1.4), (37, 14, 0.065, 1.3), (43, 17, 0.05, 1.2),
             (1, -2, 0.42, 2.6), (2, -3, 0.34, 2.4), (4, -5, 0.26, 2.2),
             (6, -8, 0.19, 2.0), (9, -12, 0.14, 1.8), (14, -18, 0.10, 1.6),
             (21, -27, 0.07, 1.4), (33, -41, 0.045, 1.2)]
    for nx, ny, amp, pw in waves:
        ph = rng.uniform(0, 2 * np.pi)
        sn = 0.5 + 0.5 * np.sin(2 * np.pi * (nx * u + ny * v) + ph)
        H += amp * (sn ** pw - 0.5)
    chop = fbm(S, S, 20, 80, rng, 4, ridged=True)
    H += 0.16 * (chop - chop.mean())
    H += 0.09 * fbm(S, S, 56, 112, rng, 3)
    H = norm01(H)
    save_normal_u8(height_to_normal(H * 105.0, 1.0), "water_normal.png")

    F = 512
    fw = fbm(F, F, 3, 7, rng, 4) * 42.0
    fh = fbm(F, F, 3, 7, rng, 4) * 14.0
    wisp = norm01(warp(fbm(F, F, 3, 9, rng, octaves=5, gain=0.55, ridged=True), fw, fh, 1.0))
    streak = norm01(fbm(F, F, 2, 20, rng, 5, ridged=True))
    band = norm01(fbm(F, F, 4, 4, rng, 3))
    foam = smoothstep(0.50, 0.98, wisp * 0.62 + streak * 0.50) * smoothstep(0.20, 0.78, band)
    lace = smoothstep(0.35, 0.90, norm01(fbm(F, F, 12, 26, rng, 4, ridged=True)))
    foam = np.clip(foam * (0.52 + 0.72 * lace), 0, 1)
    bub_f1, _ = worley(F, F, 40, 40, rng)
    bub = 1.0 - smoothstep(0.0, 2.6, bub_f1)
    foam = np.clip(foam + 0.28 * foam * bub, 0, 1)
    foam = np.clip(gblur(foam, 1.3) * 1.30, 0, 1) ** 0.95
    foam = np.clip(foam * (0.72 + 0.45 * norm01(fbm(F, F, 5, 5, rng, 3))), 0, 1)
    save_gray(foam, "water_foam.png", kind="mask")


# ----------------------------------------------------------------------------
# CHARACTER MATERIALS
# ----------------------------------------------------------------------------
def gen_skin(rng, S=512):
    f1, _ = worley(S, S, 118, 118, rng, jitter=1.0)
    pore = (1.0 - norm01(f1)) ** 2.2
    f1b, _ = worley(S, S, 205, 205, rng, jitter=1.0)
    pore2 = (1.0 - norm01(f1b)) ** 2.6
    micro = fbm(S, S, 70, 70, rng, 4)
    crease = fbm(S, S, 20, 46, rng, 4, ridged=True)
    fine = fbm(S, S, 34, 34, rng, 4)
    H = -0.80 * pore - 0.42 * pore2 + 0.26 * micro + 0.30 * (crease - crease.mean())
    H = norm01(gblur(H, 0.75))

    tone = norm01(fbm(S, S, 5, 5, rng, 4))
    blotch = norm01(fbm(S, S, 11, 11, rng, 5))
    base = np.array([0.505, 0.330, 0.212])
    warm = np.array([0.640, 0.442, 0.288])
    deep = np.array([0.392, 0.238, 0.150])
    col = base[None, None, :] + (warm - base)[None, None, :] * tone[..., None]
    col = col * (1 - 0.22 * (1 - blotch)[..., None]) + deep[None, None, :] * 0.22 * (1 - blotch)[..., None]
    red = smoothstep(0.60, 0.98, norm01(fbm(S, S, 9, 9, rng, 4)))[..., None]
    col = col + np.array([0.060, 0.006, 0.002])[None, None, :] * red
    # pore shadows carry most of the micro-contrast
    col = col * (1 - 0.52 * pore[..., None]) + np.array([0.285, 0.158, 0.104])[None, None, :] * 0.52 * pore[..., None]
    col = col * (1 - 0.26 * pore2[..., None])
    # freckles / sun-mottling: sparse pigment specks
    fr = smoothstep(0.72, 0.97, norm01(fbm(S, S, 26, 26, rng, 4)))[..., None]
    col = col * (1 - 0.45 * fr) + np.array([0.300, 0.168, 0.098])[None, None, :] * 0.45 * fr
    col = col * (0.84 + 0.32 * norm01(fine))[..., None]
    col = np.clip(col * (1 - 0.20 * norm01(crease))[..., None], 0, 1)

    rough = 0.48 + 0.24 * pore + 0.12 * pore2 - 0.12 * norm01(tone) + 0.10 * norm01(fine)
    rough = np.clip(rough, 0.28, 0.88)
    save_rgb(col, "skin_warm.png")
    save_normal_u8(height_to_normal(H * 12.0, 1.0), "skin_warm_normal.png")
    save_gray(rough, "skin_warm_rough.png")


def weave(S, P, rng):
    """Returns (height, warp_top_mask, thread_shade, gap_mask, ix, iy)."""
    nth = S // P
    Y, X = np.mgrid[0:S, 0:S].astype(np.float64)
    tw = 0.80 + 0.20 * rng.random(nth)
    tf = 0.80 + 0.20 * rng.random(nth)
    # slubs: a few thick, irregular threads (handloom)
    for arr in (tw, tf):
        for _ in range(max(2, nth // 26)):
            i = int(rng.integers(0, nth))
            arr[i] = min(1.45, arr[i] + rng.uniform(0.25, 0.55))
    ox = (rng.random(nth) - 0.5) * 0.30
    oy = (rng.random(nth) - 0.5) * 0.30
    sw = 0.82 + 0.36 * rng.random(nth)
    sf = 0.82 + 0.36 * rng.random(nth)
    fxi = X / P
    fyi = Y / P
    ix = np.floor(fxi).astype(np.int64) % nth
    iy = np.floor(fyi).astype(np.int64) % nth
    fx = fxi - np.floor(fxi) + ox[ix]
    fy = fyi - np.floor(fyi) + oy[iy]
    wwid = tw[ix]
    fwid = tf[iy]
    hw = np.sqrt(np.clip(1.0 - ((fx - 0.5) * 2.0 / wwid) ** 2, 0, 1))
    hf = np.sqrt(np.clip(1.0 - ((fy - 0.5) * 2.0 / fwid) ** 2, 0, 1))
    over = ((ix + iy) % 2) == 0
    H = np.where(over, 0.66 * hw + 0.22 * hf * (1 - hw), 0.66 * hf + 0.22 * hw * (1 - hf))
    gap = np.clip(np.maximum(hw, hf) * 2.4, 0, 1)
    shade = np.where(over, sw[ix], sf[iy] * 0.95)
    fuzz = fbm(S, S, S // 4, S // 4, rng, 3)
    H = H + 0.06 * fuzz
    H = gblur(H, 0.55)
    return H, over, shade, gap, fuzz


def gen_cloth(name, dye, dye2, rng, S=512, P=6, stripe=None, rough_base=0.90):
    H, over, shade, gap, fuzz = weave(S, P, rng)
    dyeu = norm01(fbm(S, S, 3, 3, rng, 4))          # uneven vat dye
    dyeu2 = norm01(fbm(S, S, 9, 9, rng, 4))
    c1 = np.array(dye); c2 = np.array(dye2)
    col = c1[None, None, :] + (c2 - c1)[None, None, :] * (0.35 * dyeu + 0.65 * dyeu2)[..., None]
    col = col * (0.80 + 0.34 * shade)[..., None]
    col = col * (0.55 + 0.55 * norm01(H))[..., None]
    col = col * (0.30 + 0.70 * gap)[..., None]      # dark interstices between threads
    col = col * (1.0 + 0.08 * fuzz)[..., None]
    if stripe is not None:
        Y = np.mgrid[0:S, 0:S][0]
        band = np.zeros((S, S))
        for (y0, y1, sc, amt) in stripe:
            m = ((Y >= y0) & (Y < y1)).astype(np.float64)
            m = gblur(m, 0.6)
            col = col * (1 - (m * amt)[..., None]) + np.array(sc)[None, None, :] * (m * amt)[..., None]
            band = np.maximum(band, m)
        H = H + 0.10 * band
    col = np.clip(col, 0, 1)
    rough = np.clip(rough_base - 0.26 * norm01(H) + 0.14 * (1 - gap)
                    + 0.10 * (norm01(fuzz) - 0.5) - 0.06 * norm01(dyeu2), 0.40, 1.0)
    save_rgb(col, name + ".png")
    save_normal_u8(height_to_normal(H * 15.0, 1.0), name + "_normal.png")
    save_gray(rough, name + "_rough.png")


def gen_demon_hide(rng, S=512):
    f1, f2 = worley(S, S, 10, 10, rng, jitter=0.95)
    f1b, f2b = worley(S, S, 25, 25, rng, jitter=0.95)
    crack = (1 - smoothstep(0.0, 5.5, f2 - f1)) * 0.95
    crack = np.maximum(crack, (1 - smoothstep(0.0, 2.4, f2b - f1b)) * 0.62)
    wxx = fbm(S, S, 5, 5, rng, 4) * 8.0
    wyy = fbm(S, S, 5, 5, rng, 4) * 8.0
    crack = np.clip(warp(crack, wxx, wyy, 1.0), 0, 1)
    plate = (1.0 - norm01(f1b)) ** 0.8
    grain = fbm(S, S, 32, 32, rng, 4, ridged=True)
    H = 0.55 * plate + 0.30 * (1 - norm01(f1)) + 0.22 * grain - 1.05 * crack
    H = norm01(gblur(H, 0.5))

    d = norm01(H)
    ash = np.array([0.425, 0.415, 0.400])
    pale = np.array([0.610, 0.592, 0.565])
    char = np.array([0.085, 0.082, 0.090])
    col = char[None, None, :] + (ash - char)[None, None, :] * smoothstep(0.04, 0.58, d)[..., None]
    col = col * (1 - smoothstep(0.62, 1.0, d)[..., None]) + pale[None, None, :] * smoothstep(0.62, 1.0, d)[..., None]
    cold = smoothstep(0.45, 0.90, norm01(fbm(S, S, 4, 4, rng, 4)))[..., None]
    col = col * (1 - 0.32 * cold) + np.array([0.300, 0.305, 0.345])[None, None, :] * 0.32 * cold
    dustc = smoothstep(0.50, 0.92, norm01(fbm(S, S, 7, 7, rng, 4)))[..., None]
    col = col * (1 - 0.22 * dustc) + np.array([0.520, 0.470, 0.410])[None, None, :] * 0.22 * dustc
    col = np.clip(col * (0.84 + 0.32 * norm01(grain))[..., None], 0, 1)

    # war-paint: broken vertical brush strokes, dried blood-black
    streak = norm01(fbm(S, S, 2, 7, rng, 5, ridged=True))
    streak = warp(streak, fbm(S, S, 6, 12, rng, 3) * 12.0, fbm(S, S, 6, 12, rng, 3) * 5.0, 1.0)
    brush = norm01(fbm(S, S, 9, 70, rng, 4))
    drips = norm01(fbm(S, S, 3, 40, rng, 4, ridged=True))
    paint = smoothstep(0.55, 0.80, streak) * smoothstep(0.18, 0.55, brush)
    paint = np.maximum(paint * 0.9, smoothstep(0.80, 0.96, drips) * smoothstep(0.50, 0.75, streak))
    paint = np.clip(paint * (1 - 0.35 * crack), 0, 1)
    pc = np.array([0.175, 0.032, 0.028])
    pc2 = np.array([0.045, 0.018, 0.020])
    pcol = pc[None, None, :] + (pc2 - pc)[None, None, :] * norm01(brush)[..., None]
    col = np.clip(col * (1 - 0.94 * paint[..., None]) + pcol * 0.94 * paint[..., None], 0, 1)

    rough = np.clip(0.95 - 0.16 * d + 0.06 * crack - 0.32 * paint + 0.06 * (norm01(grain) - 0.5), 0.38, 1.0)
    H = H - 0.04 * paint
    save_rgb(col, "demon_hide.png")
    save_normal_u8(height_to_normal(H * 30.0, 1.0), "demon_hide_normal.png")
    save_gray(rough, "demon_hide_rough.png")


# ----------------------------------------------------------------------------
# VERIFY + CONTACT SHEETS
# ----------------------------------------------------------------------------
def luma(a):
    return 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]


def seam_ratio(L):
    """Seam score = wrap-edge difference / 99th pct of INTERIOR neighbour diffs.

    Comparing against the *mean* interior diff is phase-blind: a texture with
    sharp periodic features (palm scar rings) has a huge p99 and a tiny mean,
    so a perfectly tileable wrap that happens to land on a scar looks like a
    seam. A real seam is an outlier against the interior distribution, so p99
    is the right yardstick. <=1.0 means the wrap is indistinguishable from a
    normal interior transition.
    """
    dy = np.abs(np.diff(L, axis=0)).mean(axis=1)
    dx = np.abs(np.diff(L, axis=1)).mean(axis=0)
    sy = np.abs(L[0, :] - L[-1, :]).mean()
    sx = np.abs(L[:, 0] - L[:, -1]).mean()
    ry = sy / max(np.percentile(dy, 99), 1e-6)
    rx = sx / max(np.percentile(dx, 99), 1e-6)
    return max(rx, ry)


def verify():
    rows = []
    ok_all = True
    for path in sorted(MANIFEST.keys()):
        full = os.path.join(OUT, path)
        meta = MANIFEST[path]
        if not os.path.exists(full):
            rows.append((path, "MISSING", "", "", "", "", "", "FAIL"))
            ok_all = False
            continue
        im = Image.open(full)
        arr = np.asarray(im).astype(np.float64)
        w, h = im.size
        L = luma(arr[..., :3])
        mean, std = L.mean(), L.std()
        flags = []
        if std <= 8.0:
            flags.append("FLAT")
        alpha_s = "-"
        if im.mode == "RGBA":
            A = arr[..., 3]
            alpha_s = "%d..%d avg%d" % (A.min(), A.max(), A.mean())
            if A.min() == A.max():
                flags.append("ALPHA-CONST")
            frac = float((A > 127).mean())
            if not (0.03 < frac < 0.97):
                flags.append("ALPHA-COVERAGE(%.2f)" % frac)
        seam = "-"
        if meta["tileable"]:
            r = seam_ratio(L)
            seam = "%.2f" % r
            if r > 1.25:
                flags.append("SEAM")
        if meta["kind"] == "normal":
            nz = arr[..., 2] / 255.0 * 2 - 1
            nx = arr[..., 0] / 255.0 * 2 - 1
            ny = arr[..., 1] / 255.0 * 2 - 1
            tilt = np.degrees(np.arccos(np.clip(nz, -1, 1)))
            sel = tilt if meta["tileable"] else tilt[(np.abs(nx) + np.abs(ny)) > 0.004]
            if sel.size == 0:
                sel = tilt
            flags.append("tilt~%.1fdeg" % sel.mean())
            if sel.mean() < 3.0:
                flags.append("TOO-FLAT")
        size_kb = os.path.getsize(full) / 1024.0
        bad = any(f in ("FLAT", "SEAM", "TOO-FLAT", "ALPHA-CONST") or f.startswith("ALPHA-COVERAGE")
                  for f in flags)
        ok_all = ok_all and not bad
        rows.append((path, "%dx%d" % (w, h), im.mode, "%.0f KB" % size_kb,
                     "%.1f" % mean, "%.1f" % std, alpha_s, seam,
                     ("FAIL " if bad else "OK ") + " ".join(f for f in flags if f.startswith("tilt")) if not bad
                     else "FAIL " + " ".join(flags)))
    hdr = ("FILE", "DIMS", "MODE", "SIZE", "LUMA_MEAN", "LUMA_STD", "ALPHA", "SEAM", "STATUS")
    wid = [max(len(str(r[i])) for r in ([hdr] + rows)) for i in range(len(hdr))]
    line = "  ".join(str(hdr[i]).ljust(wid[i]) for i in range(len(hdr)))
    print(line)
    print("-" * len(line))
    for r in rows:
        print("  ".join(str(r[i]).ljust(wid[i]) for i in range(len(hdr))))
    print("-" * len(line))
    print("FILES: %d   ALL CHECKS: %s" % (len(rows), "PASS" if ok_all else "FAIL"))
    return ok_all


def checker(w, h, sz=16):
    Y, X = np.mgrid[0:h, 0:w]
    c = (((X // sz) + (Y // sz)) % 2).astype(np.float64)
    return (0.55 + 0.25 * c)


def make_sheet(items, path, cell=340, cols=3):
    from PIL import ImageDraw
    rows = (len(items) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * cell, rows * (cell + 16)), (24, 24, 28))
    d = ImageDraw.Draw(sheet)
    for i, (label, im) in enumerate(items):
        im = im.convert("RGB").resize((cell - 8, cell - 8), Image.LANCZOS)
        cx = (i % cols) * cell + 4
        cy = (i // cols) * (cell + 16) + 14
        sheet.paste(im, (cx, cy))
        d.text((cx + 2, cy - 12), label, fill=(235, 220, 190))
    sheet.save(path)
    return path


def over_checker(path):
    im = Image.open(os.path.join(OUT, path)).convert("RGBA")
    a = np.asarray(im).astype(np.float64) / 255.0
    bg = checker(im.size[0], im.size[1], max(8, im.size[0] // 32))[..., None]
    out = a[..., :3] * a[..., 3:4] + bg * (1 - a[..., 3:4])
    return Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8))


def tiled(path, n=2):
    im = Image.open(os.path.join(OUT, path)).convert("RGB")
    s = im.resize((im.size[0] // 2, im.size[1] // 2), Image.LANCZOS)
    out = Image.new("RGB", (s.size[0] * n, s.size[1] * n))
    for i in range(n):
        for j in range(n):
            out.paste(s, (i * s.size[0], j * s.size[1]))
    return out


def sheets():
    fol = [(p, over_checker(p)) for p in
           ["leaf_banyan.png", "leaf_palm.png", "leaf_mango.png",
            "grass_blades.png", "flowers.png"]]
    fol += [(p, Image.open(os.path.join(OUT, p))) for p in
            ["leaf_banyan_normal.png", "leaf_palm_normal.png", "leaf_mango_normal.png"]]
    make_sheet(fol, os.path.join(SHEETS, "sheet_foliage.png"), 380, 4)
    alp = []
    for p in ["leaf_banyan.png", "leaf_palm.png", "leaf_mango.png", "grass_blades.png", "flowers.png"]:
        A = np.asarray(Image.open(os.path.join(OUT, p)).convert("RGBA"))[..., 3]
        alp.append((p + " ALPHA", Image.fromarray(A)))
    make_sheet(alp, os.path.join(SHEETS, "sheet_alpha.png"), 380, 3)
    til = []
    for p in ["bark_banyan.png", "bark_palm.png", "water_normal.png", "water_foam.png",
              "bark_banyan_normal.png", "bark_palm_normal.png",
              "bark_banyan_rough.png", "bark_palm_rough.png"]:
        til.append((p + " (2x2 tiled)", tiled(p)))
    make_sheet(til, os.path.join(SHEETS, "sheet_tiling.png"), 380, 4)
    ch = []
    for p in ["skin_warm.png", "cloth_saffron.png", "cloth_indigo.png", "cloth_white.png",
              "demon_hide.png", "skin_warm_normal.png", "cloth_saffron_normal.png",
              "demon_hide_normal.png", "cloth_white_normal.png", "demon_hide_rough.png"]:
        ch.append((p, tiled(p)))
    make_sheet(ch, os.path.join(SHEETS, "sheet_character.png"), 380, 5)
    print("contact sheets ->", SHEETS)


def spec_checks():
    print("\nSPEC CHECKS")
    print("-" * 72)
    ok = True
    print("1) alpha channels have a real range (not all-255):")
    for f in ["leaf_banyan.png", "leaf_palm.png", "leaf_mango.png",
              "grass_blades.png", "flowers.png"]:
        A = np.asarray(Image.open(os.path.join(OUT, f)).convert("RGBA"))[..., 3]
        opaque = float((A == 255).mean()) * 100
        clear = float((A == 0).mean()) * 100
        good = A.min() < A.max() and clear > 1.0 and opaque > 1.0
        ok = ok and good
        print("   %-18s min=%3d max=%3d  opaque=%.1f%%  clear=%.1f%%  edge px=%d  %s"
              % (f, A.min(), A.max(), opaque, clear,
                 int(((A > 8) & (A < 247)).sum()), "OK" if good else "FAIL"))
    print("2) grass_blades: bottom row opaque, top fades to alpha 0:")
    A = np.asarray(Image.open(os.path.join(OUT, "grass_blades.png")).convert("RGBA"))[..., 3]
    g = (A[-1].min() == 255) and (A[0].max() == 0)
    ok = ok and g
    print("   bottom row min alpha=%d (want 255)   top row max alpha=%d (want 0)   %s"
          % (A[-1].min(), A[0].max(), "OK" if g else "FAIL"))
    print("3) normal maps: OpenGL +Y, encoded around (128,128,255), nz>0 everywhere:")
    for f in sorted(k for k, v in MANIFEST.items() if v["kind"] == "normal"):
        n = np.asarray(Image.open(os.path.join(OUT, f))).astype(np.float64)
        v = n / 255.0 * 2 - 1
        ln = np.sqrt((v ** 2).sum(-1))
        good = n[..., 2].min() >= 128 and abs(ln.mean() - 1.0) < 0.02
        ok = ok and good
        print("   %-26s B min=%3d  |n| mean=%.3f  R/G mean=%.1f/%.1f  %s"
              % (f, int(n[..., 2].min()), ln.mean(), n[..., 0].mean(),
                 n[..., 1].mean(), "OK" if good else "FAIL"))
    print("4) tileable set: seam score = wrap diff / p99 interior diff (<=1.25 ok)")
    worst = 0.0
    for f in sorted(k for k, v in MANIFEST.items() if v["tileable"]):
        a = np.asarray(Image.open(os.path.join(OUT, f)).convert("RGB")).astype(np.float64)
        worst = max(worst, seam_ratio(luma(a)))
    print("   worst seam score across %d tiling maps = %.2f  %s"
          % (sum(1 for v in MANIFEST.values() if v["tileable"]), worst,
             "OK" if worst <= 1.25 else "FAIL"))
    ok = ok and worst <= 1.25
    print("-" * 72)
    print("SPEC CHECKS: %s" % ("PASS" if ok else "FAIL"))
    return ok


def main():
    t0 = time.time()
    rng = np.random.default_rng(0x5241_4D41)
    print("[1/6] foliage atlases ...")
    write_foliage("leaf_banyan", gen_leaf_banyan(rng), strength=17.0)
    write_foliage("leaf_palm", gen_leaf_palm(rng), strength=13.0)
    write_foliage("leaf_mango", gen_leaf_mango(rng), strength=19.0)
    cv = gen_grass(rng)
    save_rgba(cv['rgb'], cv['a'], "grass_blades.png", kind="foliage", sharpen=3.0)
    cv = gen_flowers(rng)
    save_rgba(cv['rgb'], cv['a'], "flowers.png", kind="foliage", sharpen=3.0)
    print("[2/6] bark ...")
    gen_bark_banyan(rng)
    gen_bark_palm(rng)
    print("[3/6] water ...")
    gen_water(rng)
    print("[4/6] skin ...")
    gen_skin(rng)
    print("[5/6] cloth ...")
    gen_cloth("cloth_saffron", (0.740, 0.318, 0.050), (0.945, 0.575, 0.135), rng, P=6)
    gen_cloth("cloth_indigo", (0.045, 0.072, 0.200), (0.170, 0.240, 0.455), rng, P=6)
    gen_cloth("cloth_white", (0.735, 0.700, 0.600), (0.945, 0.920, 0.855), rng, P=6,
              stripe=[(18, 21, (0.50, 0.21, 0.04), 0.88),
                      (24, 42, (0.795, 0.492, 0.092), 0.82),
                      (45, 48, (0.50, 0.21, 0.04), 0.88),
                      (52, 54, (0.640, 0.470, 0.145), 0.55)])
    print("[6/6] demon hide ...")
    gen_demon_hide(rng)
    print("generated in %.1fs\n" % (time.time() - t0))
    ok = verify()
    ok = spec_checks() and ok
    sheets()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
