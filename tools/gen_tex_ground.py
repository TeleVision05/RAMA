#!/usr/bin/env python3
"""
RAMA - procedural TERRAIN GROUND material generator.

Synthesizes seamlessly-tileable PBR ground materials (albedo / normal / roughness)
for the triplanar terrain shader.  Everything is generated from scratch with numpy
(no downloads, no source images) so the output is original and license-clean.

Art direction: ancient India.  Sun-baked earth, saffron/ochre, laterite red soil,
deep monsoon-forest greens, weathered Hampi sandstone, river silt.

Tileability strategy
--------------------
Every primitive is defined on a torus:
  * value / gradient (perlin) noise use a *wrapped integer lattice*
  * worley uses minimal-image (toroidal) distance to jittered grid points
  * blurs are done with FFT (circular convolution -> inherently periodic)
  * domain warp / LIC sample with wrapped bilinear lookups
  * banded strata use integer wave numbers (kx, ky) so the phase closes on the tile
  * splatted leaves / twigs / pebbles write through modulo indices
Nothing in the pipeline can introduce a seam.

Outputs -> assets/textures/
    grass, dirt, rock, sand, mud_river, forest_floor   (1024, _albedo/_normal/_rough)
    detail_noise.png                                   (512, RGB octave split)
"""

import math
import os
import sys
import time

import numpy as np
from PIL import Image

# --------------------------------------------------------------------------------------
# config
# --------------------------------------------------------------------------------------

ROOT = "/Users/tarunvadapalli/Documents/Git/UltraOpen"
OUT = os.path.join(ROOT, "assets", "textures")
PREVIEW_DIR = os.environ.get("RAMA_PREVIEW_DIR", os.path.join(ROOT, "build", "texpreview"))
N = 1024

WRITTEN = []  # (path, name, kind)


# --------------------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------------------

def rng(seed):
    return np.random.default_rng(int(seed) & 0x7FFFFFFF)


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a + 1e-9), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def norm01(x, lo=0.4, hi=99.6):
    a, b = np.percentile(x, [lo, hi])
    return np.clip((x - a) / (b - a + 1e-9), 0.0, 1.0).astype(np.float32)


def lerp(a, b, t):
    return a + (b - a) * t


def mix3(c0, c1, t):
    """c0/c1: (3,) tuple or (H,W,3) array. t: (H,W)."""
    c0 = np.asarray(c0, np.float32)
    c1 = np.asarray(c1, np.float32)
    if c0.ndim == 1:
        c0 = c0.reshape(1, 1, 3)
    if c1.ndim == 1:
        c1 = c1.reshape(1, 1, 3)
    t = np.asarray(t, np.float32)
    if t.ndim == 0:
        return c0 + (c1 - c0) * t
    return c0 + (c1 - c0) * t[..., None]


def tint(col, c, t):
    return mix3(col, c, t)


# --------------------------------------------------------------------------------------
# periodic noise primitives
# --------------------------------------------------------------------------------------

def _fade(t):
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


def _axis(n, freq):
    t = (np.arange(n, dtype=np.float32) + 0.5) * (float(freq) / n)
    i0 = np.floor(t).astype(np.int64) % freq
    i1 = (i0 + 1) % freq
    fr = (t - np.floor(t)).astype(np.float32)
    return i0, i1, fr


def value_noise(n, freq, seed):
    """Periodic value noise in [0,1]. Any integer freq tiles the n-px image."""
    freq = int(max(1, min(freq, n)))
    g = rng(seed).random((freq, freq), dtype=np.float32)
    i0, i1, fr = _axis(n, freq)
    u = _fade(fr)
    a = g[:, i0] * (1.0 - u)[None, :] + g[:, i1] * u[None, :]      # (freq, n)
    return (a[i0, :] * (1.0 - u)[:, None] + a[i1, :] * u[:, None]).astype(np.float32)


def perlin(n, freq, seed):
    """Periodic gradient noise, roughly [-0.7, 0.7]."""
    freq = int(max(1, min(freq, n)))
    ang = rng(seed).random((freq, freq), dtype=np.float32) * (2.0 * np.pi)
    gx = np.cos(ang).astype(np.float32)
    gy = np.sin(ang).astype(np.float32)
    i0, i1, fr = _axis(n, freq)
    u = _fade(fr)
    X0 = fr[None, :]
    X1 = (fr - 1.0)[None, :]
    Y0 = fr[:, None]
    Y1 = (fr - 1.0)[:, None]

    def dot(iy, ix, dx, dy):
        return gx[np.ix_(iy, ix)] * dx + gy[np.ix_(iy, ix)] * dy

    n00 = dot(i0, i0, X0, Y0)
    n10 = dot(i0, i1, X1, Y0)
    n01 = dot(i1, i0, X0, Y1)
    n11 = dot(i1, i1, X1, Y1)
    ux = u[None, :]
    uy = u[:, None]
    nx0 = n00 + ux * (n10 - n00)
    nx1 = n01 + ux * (n11 - n01)
    return (nx0 + uy * (nx1 - nx0)).astype(np.float32)


def fbm(n, base, octaves=6, gain=0.5, lac=2.0, seed=0, kind="perlin", ridged=False):
    """Multi-octave periodic fractal noise, ~[-1,1]."""
    total = np.zeros((n, n), np.float32)
    amp = 1.0
    norm = 0.0
    f = float(base)
    for o in range(octaves):
        fi = int(round(f))
        if fi < 1:
            fi = 1
        if fi > n // 2:
            break
        if kind == "perlin":
            v = perlin(n, fi, seed + o * 1301 + 7) * 1.55
        else:
            v = value_noise(n, fi, seed + o * 1301 + 7) * 2.0 - 1.0
        if ridged:
            v = 1.0 - np.abs(v)
            v = v * 2.0 - 1.0
        total += amp * v
        norm += amp
        amp *= gain
        f *= lac
    return (total / max(norm, 1e-6)).astype(np.float32)


def billow(n, base, octaves=5, seed=0, gain=0.5):
    total = np.zeros((n, n), np.float32)
    amp = 1.0
    norm = 0.0
    f = float(base)
    for o in range(octaves):
        fi = int(max(1, round(f)))
        if fi > n // 2:
            break
        total += amp * np.abs(perlin(n, fi, seed + o * 977 + 3) * 1.55)
        norm += amp
        amp *= gain
        f *= 2.0
    return (total / max(norm, 1e-6)).astype(np.float32)


# --------------------------------------------------------------------------------------
# wrapped sampling, warp, LIC, blur, worley
# --------------------------------------------------------------------------------------

def grid(n):
    y, x = np.mgrid[0:n, 0:n]
    return x.astype(np.float32), y.astype(np.float32)


def sample_wrap(img, x, y):
    h, w = img.shape
    x0 = np.floor(x).astype(np.int64)
    y0 = np.floor(y).astype(np.int64)
    fx = (x - x0).astype(np.float32)
    fy = (y - y0).astype(np.float32)
    x0 %= w
    y0 %= h
    x1 = (x0 + 1) % w
    y1 = (y0 + 1) % h
    return (img[y0, x0] * (1 - fx) * (1 - fy) + img[y0, x1] * fx * (1 - fy) +
            img[y1, x0] * (1 - fx) * fy + img[y1, x1] * fx * fy).astype(np.float32)


def warp(field, dx, dy):
    n = field.shape[0]
    X, Y = grid(n)
    return sample_wrap(field, X + dx, Y + dy)


def lic(field, ang, length=20.0, steps=10, taper=1.0):
    """Straight-line integral convolution along a direction field.  Turns isotropic
    noise into directional fibres (grass blades, silt streaks, wheel ruts)."""
    n = field.shape[0]
    X, Y = grid(n)
    cx = np.cos(ang).astype(np.float32)
    sy = np.sin(ang).astype(np.float32)
    acc = field.copy()
    wsum = np.ones_like(field)
    for s in range(1, steps + 1):
        d = length * s / steps
        w = float((1.0 - s / (steps + 1.0)) ** taper)
        acc += w * (sample_wrap(field, X + cx * d, Y + sy * d) +
                    sample_wrap(field, X - cx * d, Y - sy * d))
        wsum += 2.0 * w
    return (acc / wsum).astype(np.float32)


def blur(img, sigma):
    """Periodic gaussian blur via FFT (circular convolution -> stays tileable)."""
    if sigma <= 0:
        return img
    n = img.shape[0]
    ky = np.fft.fftfreq(n).astype(np.float32)[:, None]
    kx = np.fft.rfftfreq(n).astype(np.float32)[None, :]
    g = np.exp(-2.0 * (np.pi ** 2) * (sigma ** 2) * (kx * kx + ky * ky))
    return np.fft.irfft2(np.fft.rfft2(img) * g, s=(n, n)).astype(np.float32)


def sharpen(img, sigma=2.0, amount=0.6):
    return np.clip(img + amount * (img - blur(img, sigma)), 0.0, 1.0)


def dcrack_edge(c, sigma=2.5, gain=1.7):
    """The pale curled-up lip just outside a crack line."""
    return np.clip(blur(c, sigma) * gain - c * 1.15, 0.0, 1.0)


def cavity_ao(h, sigma=7.0, k=2.6, floor=0.30):
    d = blur(h, sigma) - h
    return np.clip(1.0 - k * np.clip(d, 0.0, None), floor, 1.0).astype(np.float32)


def worley(n, cells, seed, jitter=0.95, wx=None, wy=None, aniso=1.0):
    """Periodic worley.  Returns f1, f2 (in cell units), winning cell id,
    and the delta vector to the winning feature point (for facet tilts).

    wx/wy optionally warp the sampling position, which turns the perfectly
    circular F1 discs into irregular organic blobs (pebbles, stones, lichen)."""
    cells = int(max(2, cells))
    r = rng(seed)
    cs = n / float(cells)
    base = np.stack(np.meshgrid(np.arange(cells), np.arange(cells), indexing="ij"), -1).astype(np.float32)
    pts = (base + 0.5 + jitter * (r.random((cells, cells, 2), dtype=np.float32) - 0.5)) * cs
    py_all = pts[..., 0]
    px_all = pts[..., 1]

    X, Y = grid(n)
    if wx is not None:
        X = X + wx
    if wy is not None:
        Y = Y + wy
    cxi = (np.floor(X / cs).astype(np.int64)) % cells
    cyi = (np.floor(Y / cs).astype(np.int64)) % cells

    f1 = np.full((n, n), 1e9, np.float32)
    f2 = np.full((n, n), 1e9, np.float32)
    cid = np.zeros((n, n), np.int64)
    dvx = np.zeros((n, n), np.float32)
    dvy = np.zeros((n, n), np.float32)
    half = n * 0.5

    for dy in (-1, 0, 1):
        nyi = (cyi + dy) % cells
        for dx in (-1, 0, 1):
            nxi = (cxi + dx) % cells
            px = px_all[nyi, nxi]
            py = py_all[nyi, nxi]
            ddx = px - X
            ddy = py - Y
            ddx = (ddx + half) % n - half
            ddy = (ddy + half) % n - half
            d = np.sqrt(ddx * ddx + (ddy * aniso) * (ddy * aniso))
            closer = d < f1
            f2 = np.where(closer, f1, np.minimum(f2, d))
            np.copyto(cid, (nyi * cells + nxi), where=closer)
            np.copyto(dvx, ddx, where=closer)
            np.copyto(dvy, ddy, where=closer)
            f1 = np.where(closer, d, f1)
    return {"f1": (f1 / cs).astype(np.float32), "f2": (f2 / cs).astype(np.float32),
            "id": cid, "dx": dvx / cs, "dy": dvy / cs, "cells": cells, "cs": cs}


def cell_random(w, seed, dims=1):
    """Per-cell random value(s) looked up through the worley id map."""
    c = w["cells"]
    tab = rng(seed).random((c * c, dims), dtype=np.float32)
    if dims == 1:
        return tab[:, 0][w["id"]]
    return [tab[:, i][w["id"]] for i in range(dims)]


def pebble_field(n, cells, seed, density=0.30, rlo=0.14, rhi=0.34, warp_amt=0.42, edge=0.22):
    """Scattered irregular stones.  The worley domain is noise-warped so the
    stones are lumpy blobs instead of perfect discs.  Returns mask, dome, tone, w."""
    cs = n / float(cells)
    wf = int(max(3, min(cells * 2, n // 8)))
    wx = fbm(n, wf, 4, seed=seed + 51) * cs * warp_amt
    wy = fbm(n, wf, 4, seed=seed + 52) * cs * warp_amt
    w = worley(n, cells, seed, jitter=1.0, wx=wx, wy=wy)
    sel, rad, tone = cell_random(w, seed + 53, 3)
    on = (sel < density).astype(np.float32)
    prad = rlo + (rhi - rlo) * rad
    pin = np.clip(1.0 - w["f1"] / np.maximum(prad, 1e-3), 0.0, 1.0)
    mask = on * smoothstep(0.0, edge, pin)
    dome = np.sqrt(np.clip(pin, 0.0, 1.0)) * mask
    return mask, dome, tone, w


# --------------------------------------------------------------------------------------
# splatting (leaves, twigs, flecks) - painter's algorithm with wrapped indices
# --------------------------------------------------------------------------------------

class Canvas:
    def __init__(self, n, base_col, base_h, base_rough):
        self.n = n
        self.col = np.repeat(np.asarray(base_col, np.float32).reshape(1, 1, 3), n, 0).repeat(n, 1) \
            if np.asarray(base_col).ndim == 1 else base_col.astype(np.float32).copy()
        self.h = (np.full((n, n), base_h, np.float32) if np.isscalar(base_h) else base_h.astype(np.float32).copy())
        self.r = (np.full((n, n), base_rough, np.float32) if np.isscalar(base_rough) else base_rough.astype(np.float32).copy())
        self.mask = np.zeros((n, n), np.float32)


def splat_leaf(cv, cy, cx, L, W, ang, color, base_z, curl, r, mottle=None,
               veins=True, rough=0.66, tip_dark=0.30, stem=True, asym=0.0,
               shape=(0.62, 0.22)):
    """Rasterize one lanceolate leaf at (cy,cx) with wrap-around."""
    n = cv.n
    R = int(math.ceil(max(L, W) * 0.62)) + 3
    if R * 2 + 1 >= n:
        return
    yy, xx = np.mgrid[-R:R + 1, -R:R + 1]
    yy = yy.astype(np.float32)
    xx = xx.astype(np.float32)
    ca = math.cos(ang)
    sa = math.sin(ang)
    u = (xx * ca + yy * sa) / (L * 0.5)          # -1 .. 1 along the leaf
    v = (-xx * sa + yy * ca) / (W * 0.5)         # across
    s = np.clip((u + 1.0) * 0.5, 0.0, 1.0)

    # Lanceolate half-width: widest just below the middle, drawn to a point at
    # the tip and narrowing to the petiole at the base.  A broad flat profile
    # here is what makes procedural litter read as almond petals, not leaves.
    prof = (np.clip(4.0 * s * (1.0 - s), 0.0, 1.0) ** shape[0]) * (np.clip(1.0 - s, 0.0, 1.0) ** shape[1])
    pmax = float(prof.max())
    if pmax <= 1e-5:
        return
    prof = prof / pmax
    bend = curl * 0.42 * (4.0 * s * (1.0 - s))   # gentle midrib curve
    vc = v - bend
    if asym:
        prof = prof * np.where(vc >= 0.0, 1.0 + asym, 1.0 - asym)
    inside = (np.abs(u) < 1.0) & (np.abs(vc) < prof)
    if not inside.any():
        return

    t = np.clip(np.abs(vc) / np.maximum(prof, 1e-3), 0.0, 1.0)
    dome = np.sqrt(np.clip(1.0 - t * t, 0.0, 1.0))
    rib = np.exp(-((t * 7.0) ** 2))

    hloc = (base_z
            + 0.052 * (t ** 2.2) * (0.35 + abs(curl))     # dry edges curl upward
            + 0.020 * dome
            + 0.016 * rib
            + 0.010 * np.sin(s * 11.0))

    gy = ((int(cy) + yy.astype(np.int64)) % n)
    gx = ((int(cx) + xx.astype(np.int64)) % n)
    iy = gy[inside]
    ix = gx[inside]

    col = np.asarray(color, np.float32).reshape(1, 3) * np.ones((iy.size, 1), np.float32)

    ins_t = t[inside]
    ins_s = s[inside]
    ins_dome = dome[inside]
    ins_rib = rib[inside]

    # shading: rim darkening, midrib highlight, tip discolouration
    shade = (0.80 + 0.30 * ins_dome) * (1.0 - tip_dark * smoothstep(0.55, 1.0, ins_s))
    shade *= (1.0 - 0.34 * smoothstep(0.68, 1.0, ins_t))     # dried, darkened margin
    if veins:
        sgn = 1.0 if r.random() > 0.5 else -1.0
        nv = 11.0 + 16.0 * (L / 120.0)
        vein = 0.5 + 0.5 * np.cos(ins_s * nv * math.pi + ins_t * 9.0 * sgn)
        shade *= (0.955 + 0.085 * vein)
        shade *= (1.0 + 0.22 * ins_rib)                      # pale midrib
    col *= shade[:, None]

    if mottle is not None:
        m = mottle[iy, ix]
        col *= (0.80 + 0.40 * m)[:, None]
        # dark decay blotches
        blot = smoothstep(0.74, 0.94, m)
        col *= (1.0 - 0.35 * blot)[:, None]

    cv.col[iy, ix] = np.clip(col, 0.0, 1.4)
    cv.h[iy, ix] = hloc[inside]
    cv.r[iy, ix] = rough * (0.92 + 0.16 * ins_t)
    cv.mask[iy, ix] = 1.0

    if stem and L > 26:
        # petiole: short line off the base
        sl = L * 0.16
        for k in range(int(sl)):
            d = k + L * 0.5
            py = int(cy + math.sin(ang + math.pi) * d) % n
            px = int(cx + math.cos(ang + math.pi) * d) % n
            cv.col[py, px] = np.asarray(color, np.float32) * 0.55
            cv.h[py, px] = base_z + 0.012


def splat_twig(cv, cy, cx, L, W, ang, color, base_z, r):
    n = cv.n
    R = int(math.ceil(L * 0.6)) + 3
    if R * 2 + 1 >= n:
        return
    yy, xx = np.mgrid[-R:R + 1, -R:R + 1]
    yy = yy.astype(np.float32)
    xx = xx.astype(np.float32)
    ca = math.cos(ang)
    sa = math.sin(ang)
    u = (xx * ca + yy * sa)
    v = (-xx * sa + yy * ca)
    bendc = (r.random() - 0.5) * 0.0035
    v = v - bendc * u * u
    halfw = W * 0.5 * (1.0 - 0.55 * np.clip(np.abs(u) / (L * 0.5), 0, 1))
    inside = (np.abs(u) < L * 0.5) & (np.abs(v) < halfw)
    if not inside.any():
        return
    t = np.clip(np.abs(v) / np.maximum(halfw, 1e-3), 0, 1)
    dome = np.sqrt(np.clip(1 - t * t, 0, 1))
    gy = ((int(cy) + yy.astype(np.int64)) % n)[inside]
    gx = ((int(cx) + xx.astype(np.int64)) % n)[inside]
    c = np.asarray(color, np.float32).reshape(1, 3) * (0.62 + 0.55 * dome[inside])[:, None]
    cv.col[gy, gx] = np.clip(c, 0, 1)
    cv.h[gy, gx] = base_z + 0.030 * dome[inside]
    cv.r[gy, gx] = 0.80
    cv.mask[gy, gx] = 1.0


# --------------------------------------------------------------------------------------
# encode / write
# --------------------------------------------------------------------------------------

def to_u8(x):
    return np.clip(x * 255.0 + 0.5, 0, 255).astype(np.uint8)


def normal_map(h, strength):
    hm1 = np.roll(h, 1, 0)
    hp1 = np.roll(h, -1, 0)
    gx = ((np.roll(hm1, -1, 1) + 2.0 * np.roll(h, -1, 1) + np.roll(hp1, -1, 1)) -
          (np.roll(hm1, 1, 1) + 2.0 * np.roll(h, 1, 1) + np.roll(hp1, 1, 1))) / 8.0
    gy = ((np.roll(hp1, -1, 1) + 2.0 * hp1 + np.roll(hp1, 1, 1)) -
          (np.roll(hm1, -1, 1) + 2.0 * hm1 + np.roll(hm1, 1, 1))) / 8.0
    nx = -gx * strength
    ny = gy * strength           # OpenGL / +Y up
    nz = np.ones_like(h)
    inv = 1.0 / np.sqrt(nx * nx + ny * ny + nz * nz)
    out = np.stack([nx * inv, ny * inv, nz * inv], -1)
    return to_u8(out * 0.5 + 0.5)


def save_rgb(arr_u8, path):
    Image.fromarray(arr_u8, "RGB").save(path, optimize=True)


def write_material(name, albedo, height, rough, normal_strength):
    os.makedirs(OUT, exist_ok=True)
    a = to_u8(np.clip(albedo, 0.0, 1.0))
    save_rgb(a, os.path.join(OUT, f"{name}_albedo.png"))
    nrm = normal_map(height.astype(np.float32), normal_strength)
    save_rgb(nrm, os.path.join(OUT, f"{name}_normal.png"))
    rr = to_u8(np.clip(rough, 0.0, 1.0))
    save_rgb(np.stack([rr, rr, rr], -1), os.path.join(OUT, f"{name}_rough.png"))
    for k in ("albedo", "normal", "rough"):
        WRITTEN.append(os.path.join(OUT, f"{name}_{k}.png"))
    return a, nrm, rr


# ======================================================================================
#  MATERIALS
# ======================================================================================

def make_grass(n=N, seed=1101):
    X, Y = grid(n)

    # --- direction field.  Real turf grows in tufts that each fan a different way,
    #     so the angle comes from a per-tuft random value (worley cell id) blended
    #     with a smooth field; a purely smooth field just looks like combed fur.
    wt = worley(n, 30, seed + 51, jitter=1.0)
    tuft_ang = cell_random(wt, seed + 52, 1) * (2.0 * np.pi)
    tuft_ang = blur(np.cos(tuft_ang), 3.0), blur(np.sin(tuft_ang), 3.0)
    ang = np.arctan2(tuft_ang[1], tuft_ang[0])
    ang = ang + fbm(n, 8, 4, seed=seed + 1) * 1.15 + fbm(n, 22, 3, seed=seed + 2) * 0.55

    # --- blade fibres via LIC of fine noise along the direction field
    fine = 0.62 * value_noise(n, n // 2, seed + 3) + 0.38 * value_noise(n, n // 3, seed + 4)
    blades = norm01(lic(fine, ang, length=17.0, steps=9))
    blades = smoothstep(0.18, 0.84, blades)
    fine2 = 0.7 * value_noise(n, n // 2, seed + 7) + 0.3 * value_noise(n, int(n / 2.6), seed + 8)
    blades2 = norm01(lic(fine2, ang + 0.55, length=9.0, steps=6))
    blades2 = smoothstep(0.20, 0.82, blades2)
    fine3 = value_noise(n, n // 2, seed + 9)
    blades3 = norm01(lic(fine3, ang - 0.75, length=26.0, steps=11))
    blade = np.clip(0.48 * blades + 0.32 * blades2 + 0.20 * smoothstep(0.2, 0.85, blades3), 0, 1)
    blade = sharpen(blade, 1.3, 0.70)

    # --- clump / tuft structure (kept mid-frequency: big blobs repeat visibly
    #     once the tile is laid end to end every few metres)
    clump = norm01(fbm(n, 9, 5, gain=0.55, seed=seed + 11))
    tuft = norm01(billow(n, 26, 4, seed=seed + 12))
    tuftm = smoothstep(0.15, 0.95, 1.0 - wt["f1"])
    micro = value_noise(n, n // 2, seed + 13)

    # --- bare soil showing between tufts: fragmented, never one big blob
    dpat = norm01(fbm(n, 7, 5, gain=0.58, seed=seed + 21))
    dfrag = norm01(fbm(n, 20, 4, gain=0.55, seed=seed + 23))
    dirt_m = smoothstep(0.52, 0.84, dpat * 0.60 + 0.40 * dfrag) * (1.0 - 0.45 * clump)
    dirt_m = smoothstep(0.04, 0.52, np.clip(dirt_m * 1.7, 0, 1))
    dirt_m *= (0.55 + 0.45 * smoothstep(0.3, 0.9, norm01(fbm(n, 45, 3, seed=seed + 24))))

    h = (0.44 * blade + 0.20 * clump + 0.16 * tuft + 0.11 * tuftm + 0.09 * micro)
    h = lerp(h, 0.20 + 0.16 * norm01(fbm(n, 40, 4, seed=seed + 22)), dirt_m * 0.9)

    # --- colour: many greens, hue driven per-tuft as well as per-region
    hue = norm01(fbm(n, 7, 4, seed=seed + 31))
    hue2 = norm01(fbm(n, 15, 3, seed=seed + 32))
    thue = cell_random(wt, seed + 33, 1)
    thue = blur(thue, 2.0)
    C_deep = (0.070, 0.200, 0.140)     # deep blue-green shade
    C_mid = (0.215, 0.395, 0.150)      # monsoon green
    C_yel = (0.505, 0.565, 0.185)      # yellow-green sunlit
    C_str = (0.640, 0.570, 0.280)      # dry straw
    C_gap = (0.038, 0.072, 0.045)      # shadow at the base of the sward

    # each tuft leans to its own hue: patches of yellow-green next to patches of
    # deep blue-green is what separates real turf from flat green noise
    hmix = np.clip(0.30 * hue + 0.48 * thue + 0.22 * hue2, 0, 1)
    hmix = smoothstep(0.02, 0.98, hmix)
    col = mix3(C_deep, C_mid, smoothstep(0.14, 0.60, hmix))
    col = mix3(col, C_yel, smoothstep(0.42, 0.94, 0.50 * hmix + 0.28 * clump + 0.22 * thue))
    col = mix3(col, C_str, smoothstep(0.62, 1.0, 0.60 * thue + 0.40 * tuft) * 0.72)
    # blue-green depth in the shaded hollows
    col = mix3(col, (0.060, 0.170, 0.150), smoothstep(0.55, 1.0, (1.0 - clump) * 0.6 + 0.4 * (1.0 - thue)) * 0.34)

    shade = 0.40 + 0.92 * blade
    col = col * shade[..., None]
    col = mix3(col, C_gap, ((1.0 - blade) ** 1.8) * 0.68)
    # sunlit blade tips
    col = mix3(col, (0.640, 0.700, 0.330), smoothstep(0.86, 1.0, blade) * 0.35)
    col *= (0.90 + 0.20 * micro)[..., None]

    # laterite soil peeking through
    soil_n = norm01(fbm(n, 26, 4, seed=seed + 41))
    soil_g = norm01(fbm(n, 90, 3, seed=seed + 42))
    soil = mix3((0.245, 0.135, 0.085), (0.430, 0.258, 0.160), soil_n)
    soil = mix3(soil, (0.530, 0.375, 0.250), smoothstep(0.60, 1.0, soil_n) * 0.7)
    soil *= (0.86 + 0.28 * soil_g)[..., None]
    col = mix3(col, soil, dirt_m * 0.90)

    rough = (0.735 + 0.185 * (1.0 - blade) + 0.075 * dirt_m
             + 0.055 * (micro - 0.5) - 0.06 * smoothstep(0.5, 1.0, blade))
    rough = np.clip(rough, 0.60, 0.99)

    # --- dry leaf flecks + tiny straw litter (splatted, wraps correctly)
    cv = Canvas(n, col, h, rough)
    r = rng(seed + 900)
    mottle = norm01(fbm(n, 30, 4, seed=seed + 901))
    fleck_cols = [(0.455, 0.352, 0.170), (0.395, 0.298, 0.145), (0.520, 0.442, 0.255),
                  (0.330, 0.212, 0.115), (0.420, 0.290, 0.140)]
    for _ in range(230):
        L = float(r.uniform(9, 26))
        cvL = fleck_cols[int(r.integers(0, len(fleck_cols)))]
        splat_leaf(cv, r.integers(0, n), r.integers(0, n), L, L * r.uniform(0.30, 0.48),
                   float(r.uniform(0, math.pi * 2)), cvL,
                   float(np.clip(h[int(r.integers(0, n)), int(r.integers(0, n))] + 0.10, 0, 1)),
                   float(r.uniform(-1, 1)), r, mottle=mottle, rough=0.70, stem=False)
    for _ in range(90):
        splat_twig(cv, r.integers(0, n), r.integers(0, n), float(r.uniform(14, 40)),
                   float(r.uniform(1.6, 3.0)), float(r.uniform(0, math.pi * 2)),
                   (0.38, 0.29, 0.16), 0.52, r)

    col, h, rough = cv.col, cv.h, cv.r
    ao = cavity_ao(h, 5.0, 2.2, 0.42)
    col = col * (0.55 + 0.45 * ao)[..., None]
    return np.clip(col, 0, 1), h, rough, 26.0


def make_dirt(n=N, seed=2202):
    base = norm01(fbm(n, 9, 7, gain=0.52, seed=seed + 1))
    grit = norm01(fbm(n, 90, 4, gain=0.55, seed=seed + 2))
    micro = value_noise(n, n // 2, seed + 3)

    # --- compacted traffic lanes running roughly along +X, wandering
    # TILING RULE (same rule as the rock bedding below): a large-scale mask must
    # not be a low-order function of X or Y alone.  This was
    #     rut = 0.5 + 0.5*cos(2*pi*(2*Yn) + rw)
    # a frequency-2, purely-Y cosine whose ~1 rad of warp was nowhere near enough
    # to break the band.  It dominated the material -- the roughness row-mean swept
    # 203..237 while the column-mean spread was only 10, i.e. 89% of the map's
    # variance sat in a single (fx=0, fy=2) sinusoid -- so at a 4-12 m tiling rate
    # it read as hard horizontal stripes repeating every few metres.  Rebuilt as
    # isotropic noise stretched along the lane direction by LIC: still directional,
    # still periodic (lic/sample_wrap are toroidal), but it varies along X as well
    # as Y and so has no banding frequency at all.
    lane_dir = fbm(n, 3, 2, seed=seed + 21) * 0.30
    lane_src = norm01(fbm(n, 7, 4, gain=0.55, seed=seed + 4))
    lane = norm01(lic(lane_src, lane_dir, length=130.0, steps=18))
    rut = smoothstep(0.20, 0.90, lane)
    rut_d = smoothstep(0.45, 0.95, rut)
    rut_lip = smoothstep(0.28, 0.46, rut) * (1.0 - smoothstep(0.46, 0.64, rut))

    # --- directional streaking (drag / tyre marks) along the rut axis
    sang = fbm(n, 5, 3, seed=seed + 6) * 0.26
    streak = norm01(lic(value_noise(n, n // 3, seed + 7), sang, length=95.0, steps=16))
    streak2 = norm01(lic(value_noise(n, n // 2, seed + 8), sang + 0.06, length=30.0, steps=11))
    streak = np.clip(0.55 * streak + 0.45 * streak2, 0, 1)
    streak = smoothstep(0.12, 0.88, streak)
    # streaks concentrate in the rut, faint elsewhere
    streak_amt = 0.35 + 0.65 * rut_d

    # --- embedded pebbles: lumpy, sparse, mostly buried, close to soil colour
    pebble, pdome, ptone, pw = pebble_field(n, 30, seed + 9, density=0.34,
                                            rlo=0.11, rhi=0.26, warp_amt=0.30, edge=0.26)
    peb2, pdome2, ptone2, pw2 = pebble_field(n, 68, seed + 11, density=0.34,
                                             rlo=0.10, rhi=0.23, warp_amt=0.35, edge=0.30)
    grit_p, gdome, gtone, _ = pebble_field(n, 150, seed + 12, density=0.30,
                                           rlo=0.14, rhi=0.32, warp_amt=0.6, edge=0.4)
    # soil aggregates: the soft clods that make packed earth read as earth
    clod, clod_h, ctone, _ = pebble_field(n, 62, seed + 19, density=0.62,
                                          rlo=0.26, rhi=0.52, warp_amt=0.75, edge=0.75)
    clod2, clod2_h, ctone2, _ = pebble_field(n, 120, seed + 20, density=0.55,
                                             rlo=0.22, rhi=0.48, warp_amt=0.8, edge=0.8)

    # --- dry cracking (worley ridge graph), warped so cracks are not straight
    cwx = fbm(n, 14, 4, seed=seed + 16) * 8.0
    cwy = fbm(n, 14, 4, seed=seed + 17) * 8.0
    cw = worley(n, 24, seed + 13, jitter=1.0, wx=cwx, wy=cwy)
    cwidth = 0.016 + 0.030 * norm01(fbm(n, 12, 3, seed=seed + 14))
    crack = 1.0 - smoothstep(0.0, 1.0, (cw["f2"] - cw["f1"]) / cwidth)
    cw2 = worley(n, 11, seed + 15, jitter=1.0, wx=cwx * 1.6, wy=cwy * 1.6)
    crack2 = 1.0 - smoothstep(0.0, 1.0, (cw2["f2"] - cw2["f1"]) / 0.030)
    # cracking only opens where the soil has actually dried out and been left
    # alone: under traffic the path stays compacted and smooth
    dryness = smoothstep(0.38, 0.80, 0.55 * base + 0.45 * norm01(fbm(n, 6, 4, seed=seed + 18)))
    dryness *= (1.0 - rut_d * 0.75)
    crack = np.clip(np.maximum(crack * 0.80, crack2), 0, 1) * dryness
    crack *= (1.0 - pebble * 0.9)

    h = (0.42 + 0.20 * base + 0.11 * grit + 0.05 * micro
         + 0.075 * clod_h + 0.045 * clod2_h
         + 0.20 * pdome + 0.11 * pdome2 + 0.06 * gdome
         - 0.17 * rut_d + 0.05 * rut_lip + 0.07 * (streak - 0.5) * streak_amt
         - 0.20 * crack)
    h = np.clip(h, 0, 1)

    # --- laterite colour ramp
    C_dark = (0.205, 0.098, 0.058)
    C_mid = (0.430, 0.220, 0.126)
    C_lit = (0.625, 0.398, 0.248)
    C_dust = (0.735, 0.585, 0.435)
    t = np.clip(0.40 * base + 0.31 * grit + 0.11 * micro + 0.08 * streak
                + 0.10 * ctone * clod, 0, 1)
    col = mix3(C_dark, C_mid, smoothstep(0.12, 0.58, t))
    col = mix3(col, C_lit, smoothstep(0.48, 0.93, t))
    col = mix3(col, C_dust, smoothstep(0.52, 1.0, 0.55 * streak * streak_amt + 0.45 * grit) * 0.55)
    # sun-bleached dust on the high ground, damp dark soil in the rut
    col = mix3(col, (0.760, 0.640, 0.500), smoothstep(0.62, 1.0, h) * 0.30)
    col = mix3(col, (0.235, 0.118, 0.072), rut_d * 0.60)
    col *= (0.90 + 0.20 * streak)[..., None]

    # pebbles: grey-ochre river stone, only slightly lighter than the soil so they
    # read as embedded rather than as scattered dots
    pcol = mix3((0.340, 0.278, 0.220), (0.545, 0.462, 0.360), ptone)
    pcol = mix3(pcol, (0.455, 0.300, 0.198), (1.0 - ptone) * 0.70)
    col = mix3(col, pcol * (0.66 + 0.48 * pdome)[..., None], pebble * 0.90)
    p2col = mix3((0.330, 0.278, 0.222), (0.560, 0.470, 0.360), ptone2)
    col = mix3(col, p2col * (0.72 + 0.40 * pdome2)[..., None], peb2 * 0.80)
    col = mix3(col, mix3((0.300, 0.250, 0.200), (0.520, 0.440, 0.340), gtone), grit_p * 0.45)
    # clods pick up dust on top and shadow on the underside
    col = mix3(col, (0.640, 0.470, 0.330), np.clip(clod_h - 0.35, 0, 1) * 0.42)
    col = mix3(col, (0.220, 0.112, 0.068), np.clip(clod - clod_h * 1.25, 0, 1) * 0.55)
    col = mix3(col, (0.585, 0.418, 0.288), np.clip(clod2_h - 0.40, 0, 1) * 0.28)

    # crack interiors: dark shadow
    col = mix3(col, (0.115, 0.058, 0.036), crack * 0.74)

    ao = cavity_ao(h, 6.0, 2.6, 0.32)
    col = col * (0.46 + 0.54 * ao)[..., None]

    rough = (0.870 + 0.08 * (1 - base) - 0.22 * pebble - 0.14 * peb2 - 0.08 * grit_p
             + 0.07 * crack - 0.10 * rut_d + 0.06 * (micro - 0.5) + 0.05 * dryness)
    rough = np.clip(rough, 0.48, 0.99)
    return np.clip(col, 0, 1), h, rough, 32.0


def make_rock(n=N, seed=3303):
    X, Y = grid(n)
    Xn = X / n
    Yn = Y / n

    # --- sedimentary strata.
    #     Tileability rule: the band pattern may only be built from harmonics
    #     sin(m * 2pi * (kx*Xn + ky*Yn)) with INTEGER m, kx, ky, plus a periodic
    #     warp.  A quantised band *index* (floor of a ramp) does NOT close across
    #     the tile unless the per-tile band increment divides the table length,
    #     which is what produced a hard seam on the first pass.  Summing a few
    #     harmonics gives irregular layer thicknesses that are periodic by
    #     construction.  kx=1, ky=3 -> |k|=3.16, so harmonic m yields ~3.16*m
    #     layers across the tile: m in 2..8 reads as Hampi bedding at 6 m tiling.
    KX, KY = 1.0, 3.0
    ph = 2.0 * np.pi * (KX * Xn + KY * Yn)
    wl = fbm(n, 4, 5, gain=0.55, seed=seed + 1) * 1.30 + fbm(n, 11, 4, seed=seed + 2) * 0.42
    prr = rng(seed + 3).random(12, dtype=np.float32) * (2.0 * np.pi)

    def harm(m, wamp, k):
        return np.sin(m * ph + wl * wamp + prr[k])

    bandsig = (0.60 * harm(2, 1.0, 0) + 0.45 * harm(3, 1.15, 1) +
               0.30 * harm(5, 1.35, 2) + 0.18 * harm(8, 1.6, 3)) / 1.53
    # soft quantisation -> flat layers with quick transitions between them
    bh = smoothstep(-0.45, 0.45, bandsig)
    bc = smoothstep(-0.55, 0.55, 0.62 * harm(2, 1.05, 4) + 0.38 * harm(3, 1.25, 5))
    brough = smoothstep(-0.7, 0.7, harm(5, 1.4, 6))
    bthick = 0.5 + 0.5 * harm(3, 1.1, 7)
    # crisp bedding partings between the beds
    bedplane = 1.0 - smoothstep(0.0, 0.22 + 0.20 * bthick,
                                np.abs(np.sin(2.0 * ph + wl * 1.0 + prr[8])))
    bedplane = np.maximum(bedplane * 0.85,
                          (1.0 - smoothstep(0.0, 0.13,
                                            np.abs(np.sin(3.0 * ph + wl * 1.2 + prr[9])))) * 0.55)
    # fine laminations inside each bed
    lam = 0.5 + 0.5 * np.cos(16.0 * ph + wl * 2.2 + prr[10])

    # --- chipped facets: the stone is broken into slabs, each sitting at its own
    #     height and tilt.  This is what stops the strata reading as wood grain.
    fwx = fbm(n, 10, 4, seed=seed + 20) * 34.0
    fwy = fbm(n, 10, 4, seed=seed + 21) * 34.0
    w = worley(n, 7, seed + 4, jitter=1.0, wx=fwx, wy=fwy)
    fh, ftx, fty, fc = cell_random(w, seed + 5, 4)
    facet = 0.38 * (fh - 0.5) + 0.26 * ((ftx - 0.5) * w["dx"] + (fty - 0.5) * w["dy"])
    fedge = 1.0 - smoothstep(0.0, 0.13, w["f2"] - w["f1"])
    fchip = smoothstep(0.05, 0.30, w["f2"] - w["f1"])       # slab interior

    w3 = worley(n, 19, seed + 6, jitter=1.0, wx=fwx * 0.55, wy=fwy * 0.55)
    fh3, ftx3, fty3, fc3 = cell_random(w3, seed + 7, 4)
    facet3 = 0.16 * (fh3 - 0.5) + 0.13 * ((ftx3 - 0.5) * w3["dx"] + (fty3 - 0.5) * w3["dy"])
    fedge3 = 1.0 - smoothstep(0.0, 0.085, w3["f2"] - w3["f1"])

    w4 = worley(n, 44, seed + 40, jitter=1.0, wx=fwx * 0.3, wy=fwy * 0.3)
    fh4 = cell_random(w4, seed + 41, 1)
    facet4 = 0.07 * (fh4 - 0.5)
    fedge4 = 1.0 - smoothstep(0.0, 0.06, w4["f2"] - w4["f1"])

    # --- crack network.  A full worley ridge graph at every cell boundary reads
    #     as dried mud, not stone: real fractures are sparse.  So the graph is
    #     gated by a low-frequency mask and kept thin.
    cwx = fbm(n, 9, 4, seed=seed + 22) * 22.0
    cwy = fbm(n, 9, 4, seed=seed + 23) * 22.0
    cw = worley(n, 6, seed + 8, jitter=1.0, wx=cwx, wy=cwy)
    cwid = 0.012 + 0.026 * norm01(fbm(n, 9, 3, seed=seed + 9))
    crack = 1.0 - smoothstep(0.0, 1.0, (cw["f2"] - cw["f1"]) / cwid)
    crack *= smoothstep(0.30, 0.68, norm01(fbm(n, 5, 4, seed=seed + 11)))
    cw2 = worley(n, 16, seed + 10, jitter=1.0, wx=cwx * 1.4, wy=cwy * 1.4)
    craze_where = smoothstep(0.62, 0.90, norm01(fbm(n, 8, 4, seed=seed + 25)))
    crack2 = (1.0 - smoothstep(0.0, 1.0, (cw2["f2"] - cw2["f1"]) / 0.018)) * 0.75 * craze_where
    crack = np.clip(np.maximum(crack, crack2), 0, 1)
    # a few partings open along the bedding
    crack = np.clip(crack + bedplane * 0.30 * smoothstep(0.62, 1.0, norm01(fbm(n, 10, 3, seed=seed + 24))), 0, 1)

    # --- mineral grain: quartz / feldspar / biotite crystals.  This is the
    #     single most important cue that the surface is granite and not leather.
    gwx = fbm(n, 60, 3, seed=seed + 50) * 3.0
    gwy = fbm(n, 60, 3, seed=seed + 51) * 3.0
    mw = worley(n, 165, seed + 52, jitter=1.0, wx=gwx, wy=gwy)
    mtone, mkind = cell_random(mw, seed + 53, 2)
    medge = 1.0 - smoothstep(0.0, 0.13, mw["f2"] - mw["f1"])
    mw2 = worley(n, 74, seed + 54, jitter=1.0, wx=gwx * 2, wy=gwy * 2)
    mtone2, mkind2 = cell_random(mw2, seed + 55, 2)

    # --- surface roughness of the stone itself
    grit = norm01(fbm(n, 120, 4, gain=0.55, seed=seed + 12))
    pit = smoothstep(0.82, 1.0, norm01(billow(n, 48, 3, seed=seed + 13)))
    erode = norm01(fbm(n, 18, 6, gain=0.5, seed=seed + 14))

    h = (0.46 + 0.11 * (bh - 0.5) - 0.09 * bedplane + 0.030 * (lam - 0.5)
         + facet - 0.055 * fedge + facet3 - 0.030 * fedge3 + facet4 - 0.018 * fedge4
         + 0.10 * (erode - 0.5) + 0.050 * grit - 0.11 * pit - 0.16 * crack
         + 0.030 * (mtone - 0.5) - 0.022 * medge + 0.018 * (mtone2 - 0.5))
    h = np.clip(norm01(h, 0.2, 99.8) * 0.9 + 0.05, 0, 1)

    # --- weathered grey-ochre sandstone palette
    C_shadow = (0.175, 0.160, 0.140)
    C_grey = (0.402, 0.380, 0.336)
    C_stone = (0.600, 0.540, 0.428)
    C_ochre = (0.700, 0.578, 0.378)
    C_pale = (0.800, 0.748, 0.618)

    # each broken slab carries its own tone, so the bedding never dominates
    tone = np.clip(0.18 * bc + 0.28 * erode + 0.14 * grit + 0.26 * fc + 0.14 * fc3, 0, 1)
    col = mix3(C_shadow, C_grey, smoothstep(0.04, 0.42, tone))
    col = mix3(col, C_stone, smoothstep(0.28, 0.70, tone))
    # warm / cool alternating beds, held right back so the rock is not timber
    col = mix3(col, C_ochre, smoothstep(0.40, 0.90, 0.30 * bc + 0.42 * erode + 0.28 * fc) * 0.92)
    col = mix3(col, C_pale, smoothstep(0.78, 1.0, tone) * 0.85)

    # --- mineral crystals scattered through the matrix
    C_quartz = (0.735, 0.712, 0.660)
    C_feld = (0.700, 0.588, 0.470)
    C_biot = (0.185, 0.170, 0.150)
    C_horn = (0.330, 0.330, 0.290)
    xtal = mix3(C_feld, C_quartz, smoothstep(0.30, 0.72, mkind))
    xtal = mix3(xtal, C_biot, smoothstep(0.86, 1.0, mkind))
    xtal = mix3(xtal, C_horn, smoothstep(0.0, 0.16, mkind) * 0.8)
    xtal = xtal * (0.82 + 0.36 * mtone)[..., None]
    col = mix3(col, xtal, 0.34 + 0.16 * smoothstep(0.4, 1.0, fchip))
    xtal2 = mix3(C_feld, C_quartz, smoothstep(0.35, 0.80, mkind2))
    xtal2 = mix3(xtal2, C_biot, smoothstep(0.88, 1.0, mkind2))
    col = mix3(col, xtal2 * (0.84 + 0.32 * mtone2)[..., None], 0.17)
    col = mix3(col, (0.240, 0.222, 0.196), medge * 0.22)

    # freshly chipped faces are paler than the weathered rind
    col = mix3(col, C_pale, smoothstep(0.55, 1.0, fchip * (0.4 + 0.6 * fh)) * 0.26)
    col = mix3(col, (0.290, 0.262, 0.222), fedge3 * 0.26 + fedge * 0.20)
    col *= (0.95 + 0.10 * (lam - 0.5))[..., None]
    # iron staining running down the face
    stain = norm01(lic(value_noise(n, n // 4, seed + 15), np.full((n, n), 1.35, np.float32),
                       length=60.0, steps=13))
    col = mix3(col, (0.520, 0.352, 0.180), smoothstep(0.72, 1.0, stain) * 0.28)
    col = mix3(col, (0.360, 0.300, 0.225), smoothstep(0.84, 1.0, 1.0 - stain) * 0.14)
    col *= (0.90 + 0.20 * grit)[..., None]
    col = mix3(col, (0.170, 0.155, 0.135), bedplane * 0.24)

    # --- lichen: muted green-gold crusts, blotchy at their own scale, hugging
    #     the sheltered lows and the crack margins
    lwx = fbm(n, 16, 4, seed=seed + 30) * 14.0
    lwy = fbm(n, 16, 4, seed=seed + 31) * 14.0
    lw = worley(n, 14, seed + 32, jitter=1.0, wx=lwx, wy=lwy)
    lsel, lrad = cell_random(lw, seed + 33, 2)
    lblob = ((lsel < 0.44).astype(np.float32) *
             smoothstep(0.0, 0.30, np.clip(1.0 - lw["f1"] / (0.34 + 0.46 * lrad), 0, 1)))
    lw2 = worley(n, 38, seed + 34, jitter=1.0, wx=lwx * 0.5, wy=lwy * 0.5)
    lsel2, lrad2 = cell_random(lw2, seed + 35, 2)
    lblob2 = ((lsel2 < 0.24).astype(np.float32) *
              smoothstep(0.0, 0.40, np.clip(1.0 - lw2["f1"] / (0.28 + 0.40 * lrad2), 0, 1)))
    lm2 = norm01(billow(n, 42, 4, seed=seed + 17))
    lmid = norm01(fbm(n, 55, 4, gain=0.55, seed=seed + 18))
    lfine = norm01(fbm(n, 190, 3, seed=seed + 36))
    # crusts have a defined edge, not a soft fade
    lich = np.maximum(lblob, lblob2 * 0.85) * smoothstep(0.10, 0.55, lm2)
    # subtract noise before thresholding so the crust has a ragged margin
    lich = smoothstep(0.18, 0.62, np.clip(lich - 0.42 * (1.0 - lmid), 0, 1))
    lich = lich * (0.62 + 0.38 * lmid)
    lich *= (smoothstep(0.72, 0.24, h) * 0.75 + 0.60)
    lich = np.clip(lich * 1.25, 0, 1) * (1.0 - 0.80 * crack)
    # two species: muted green-gold, and the rust-orange crust common on
    # exposed Deccan granite
    species = cell_random(lw, seed + 37, 1)
    lgreen = mix3((0.180, 0.198, 0.108), (0.352, 0.360, 0.185), lmid)
    lgreen = mix3(lgreen, (0.455, 0.428, 0.262), smoothstep(0.55, 1.0, lm2) * 0.60)
    lrust = mix3((0.315, 0.212, 0.115), (0.480, 0.340, 0.172), lmid)
    lcol = mix3(lgreen, lrust, smoothstep(0.74, 0.90, species))
    lcol = mix3(lcol, (0.300, 0.318, 0.240), smoothstep(0.66, 1.0, 1.0 - lmid) * 0.50)
    lcol *= (0.90 + 0.20 * lfine)[..., None]
    # the crust is thin: keep the stone's own tonal variation underneath it
    lcol = mix3(lcol, col * 0.90 + lcol * 0.35, 0.30)
    col = mix3(col, lcol, lich * 0.66)
    h = h + 0.018 * lich * (0.4 + 0.6 * lfine)

    # cracks: dark but not black, with the pale weathered lip beside them
    col = mix3(col, (0.740, 0.700, 0.610), dcrack_edge(crack, 2.0, 1.5) * 0.22)
    col = mix3(col, (0.088, 0.078, 0.066), crack * 0.82)
    ao = cavity_ao(h, 7.0, 2.8, 0.28)
    col = col * (0.44 + 0.56 * ao)[..., None]

    rough = (0.620 + 0.22 * grit + 0.12 * (brough - 0.5) + 0.20 * lich
             + 0.10 * crack + 0.08 * pit - 0.14 * smoothstep(0.55, 1.0, h))
    rough = np.clip(rough, 0.38, 0.99)
    return np.clip(col, 0, 1), h, rough, 36.0


def make_sand(n=N, seed=4404):
    X, Y = grid(n)
    Xn = X / n
    Yn = Y / n

    # --- ripple dunes.  Integer wave numbers + a strong warp keep them tileable
    #     but stop them reading as corduroy; the amplitude is modulated so the
    #     ripples fade in and out the way wind-worked sand actually does.
    wrp = fbm(n, 5, 5, gain=0.55, seed=seed + 1) * 1.15 + fbm(n, 12, 4, seed=seed + 2) * 0.42
    ph = 2.0 * np.pi * (3.0 * Xn + 17.0 * Yn) + wrp * 4.2
    rip = (0.5 + 0.5 * np.sin(ph)) ** 1.8               # sharp crests, broad troughs
    ph2 = 2.0 * np.pi * (13.0 * Xn + 6.0 * Yn) + fbm(n, 7, 4, seed=seed + 3) * 3.4
    rip2 = (0.5 + 0.5 * np.sin(ph2)) ** 2.2
    ph3 = 2.0 * np.pi * (7.0 * Xn + 29.0 * Yn) + fbm(n, 9, 4, seed=seed + 14) * 3.0
    rip3 = (0.5 + 0.5 * np.sin(ph3)) ** 2.4
    amp1 = smoothstep(0.20, 0.80, norm01(fbm(n, 6, 4, seed=seed + 15)))
    amp2 = smoothstep(0.25, 0.85, norm01(fbm(n, 8, 4, seed=seed + 16)))
    ripple = np.clip(0.70 * rip * (0.35 + 0.65 * amp1)
                     + 0.34 * rip2 * (0.30 + 0.70 * amp2)
                     + 0.22 * rip3 * (0.30 + 0.70 * (1.0 - amp1)), 0, 1)

    dune = norm01(fbm(n, 7, 5, gain=0.55, seed=seed + 4))
    grain = 0.55 * value_noise(n, n, seed + 5) + 0.45 * value_noise(n, n // 2, seed + 6)
    grain2 = norm01(fbm(n, 150, 3, gain=0.5, seed=seed + 7))

    # --- scattered pebbles and shell grit
    peb, pdome, tone, _ = pebble_field(n, 40, seed + 8, density=0.13,
                                       rlo=0.10, rhi=0.26, warp_amt=0.55, edge=0.35)
    peb2, pdome2, tone2, _ = pebble_field(n, 96, seed + 17, density=0.10,
                                          rlo=0.10, rhi=0.22, warp_amt=0.6, edge=0.4)

    # --- dark mineral specks (magnetite / garnet sand)
    sp = value_noise(n, int(n * 0.42), seed + 10)
    specks = smoothstep(0.935, 0.985, sp)
    sp2 = value_noise(n, int(n * 0.30), seed + 11)
    specks2 = smoothstep(0.930, 0.985, sp2)

    h = (0.40 + 0.21 * ripple + 0.13 * dune + 0.10 * grain + 0.07 * grain2
         + 0.15 * pdome + 0.07 * pdome2)
    h = np.clip(h, 0, 1)

    C_shadow = (0.470, 0.400, 0.300)
    C_mid = (0.680, 0.598, 0.452)
    C_pale = (0.822, 0.760, 0.612)
    C_hot = (0.880, 0.812, 0.640)

    t = np.clip(0.46 * ripple + 0.24 * dune + 0.17 * grain + 0.13 * grain2, 0, 1)
    col = mix3(C_shadow, C_mid, smoothstep(0.08, 0.50, t))
    col = mix3(col, C_pale, smoothstep(0.38, 0.86, t))
    col = mix3(col, C_hot, smoothstep(0.78, 1.0, t) * 0.85)
    # damp patches: mid-frequency and gentle, so the tile does not repeat as a blob
    damp = smoothstep(0.58, 0.92, norm01(fbm(n, 9, 5, gain=0.55, seed=seed + 12)))
    damp *= (0.45 + 0.55 * smoothstep(0.4, 0.9, norm01(fbm(n, 22, 3, seed=seed + 13))))
    col = mix3(col, (0.455, 0.390, 0.295), damp * 0.42)
    col *= (0.93 + 0.14 * grain)[..., None]

    col = mix3(col, (0.235, 0.205, 0.185), specks * 0.62)
    col = mix3(col, (0.330, 0.210, 0.185), specks2 * 0.55)
    pcol = mix3((0.505, 0.455, 0.390), (0.748, 0.700, 0.598), tone)
    col = mix3(col, pcol * (0.74 + 0.38 * pdome)[..., None], peb)
    col = mix3(col, mix3((0.470, 0.420, 0.355), (0.700, 0.650, 0.545), tone2),
               peb2 * 0.75)

    ao = cavity_ao(h, 5.0, 2.2, 0.42)
    col = col * (0.58 + 0.42 * ao)[..., None]

    rough = (0.815 + 0.10 * (1 - ripple) + 0.07 * grain2 - 0.26 * damp
             - 0.18 * peb - 0.10 * peb2 + 0.05 * (grain - 0.5))
    rough = np.clip(rough, 0.42, 0.99)
    return np.clip(col, 0, 1), h, rough, 26.0


def make_mud_river(n=N, seed=5505):
    X, Y = grid(n)

    # --- flow direction of the current, mostly one way but meandering
    ang = 0.55 + fbm(n, 3, 3, seed=seed + 1) * 0.55
    silt = norm01(lic(value_noise(n, n // 3, seed + 2), ang, length=75.0, steps=15))
    silt2 = norm01(lic(value_noise(n, n // 2, seed + 3), ang + 0.15, length=25.0, steps=9))

    # --- organic mottling from a heavily domain-warped fbm, at three scales so
    #     the silt does not turn into soft camouflage blobs
    wx = fbm(n, 6, 4, seed=seed + 4) * 40.0
    wy = fbm(n, 6, 4, seed=seed + 5) * 40.0
    mot = warp(norm01(fbm(n, 10, 6, gain=0.55, seed=seed + 6)), wx, wy)
    mot2 = warp(norm01(billow(n, 22, 4, seed=seed + 7)), wx * 0.5, wy * 0.5)
    mot3 = warp(norm01(billow(n, 60, 4, seed=seed + 30)), wx * 0.25, wy * 0.25)
    mot = np.clip(0.72 * mot + 0.28 * mot3, 0, 1)
    fine = norm01(fbm(n, 110, 4, gain=0.55, seed=seed + 8))
    grit = norm01(fbm(n, 260, 3, gain=0.5, seed=seed + 31))

    # --- embedded stones, lumpy and partly buried in the silt
    stone, stone_h, tone, _ = pebble_field(n, 15, seed + 9, density=0.30,
                                           rlo=0.22, rhi=0.46, warp_amt=0.50, edge=0.26)
    st2, st2_h, tone2, _ = pebble_field(n, 38, seed + 11, density=0.26,
                                        rlo=0.16, rhi=0.36, warp_amt=0.55, edge=0.30)
    st3, st3_h, tone3, _ = pebble_field(n, 90, seed + 32, density=0.18,
                                        rlo=0.12, rhi=0.26, warp_amt=0.6, edge=0.36)
    # silt drifts over the upstream side of the bigger stones
    bury = smoothstep(0.30, 0.80, norm01(fbm(n, 26, 4, seed=seed + 20)))
    stone = stone * (0.55 + 0.45 * bury)
    stone_h = stone_h * (0.55 + 0.45 * bury)

    # --- desiccation polygons on the bars that have dried out
    dwx = fbm(n, 16, 4, seed=seed + 21) * 7.0
    dwy = fbm(n, 16, 4, seed=seed + 22) * 7.0
    dc = worley(n, 26, seed + 23, jitter=1.0, wx=dwx, wy=dwy)
    dcrack = 1.0 - smoothstep(0.0, 1.0, (dc["f2"] - dc["f1"]) / 0.045)

    h = (0.36 + 0.20 * mot + 0.12 * mot2 + 0.08 * fine + 0.035 * grit
         + 0.06 * silt + 0.04 * silt2 + 0.32 * stone_h + 0.17 * st2_h + 0.08 * st3_h)
    h = np.clip(h, 0, 1)
    dry_zone = smoothstep(0.60, 0.90, h) * smoothstep(0.35, 0.8, norm01(fbm(n, 7, 4, seed=seed + 24)))
    dcrack = dcrack * dry_zone
    h = np.clip(h - 0.10 * dcrack, 0, 1)

    # --- dark wet silt with a river blue-green cast in the pools
    C_black = (0.098, 0.090, 0.072)
    C_mud = (0.205, 0.176, 0.120)
    C_silt = (0.395, 0.340, 0.230)
    C_dry = (0.468, 0.406, 0.288)
    C_algae = (0.115, 0.198, 0.158)

    t = np.clip(0.46 * mot + 0.20 * mot2 + 0.10 * silt + 0.24 * fine, 0, 1)
    t = smoothstep(0.04, 0.96, t)                      # gently stretch the range
    col = mix3(C_black, C_mud, smoothstep(0.04, 0.42, t))
    col = mix3(col, C_silt, smoothstep(0.34, 0.80, t))
    col = mix3(col, C_dry, smoothstep(0.60, 1.0, 0.45 * t + 0.55 * h) * 0.62)
    col = mix3(col, C_algae, smoothstep(0.55, 0.95, mot2 * 0.6 + 0.4 * (1 - h)) * 0.60)
    # river blue-green sheen in the deepest silt
    col = mix3(col, (0.085, 0.135, 0.140), smoothstep(0.70, 1.0, 1.0 - t) * 0.45)
    # fine detail stays subtle: at full strength it turns the silt into static
    col *= (0.93 + 0.14 * silt2)[..., None]
    col *= (0.955 + 0.09 * grit)[..., None]

    # stones read clearly: paler, cooler and rounder than the silt around them
    scol = mix3((0.265, 0.256, 0.230), (0.640, 0.602, 0.512), tone)
    scol = mix3(scol, (0.310, 0.335, 0.282), (1.0 - tone) * 0.45)
    col = mix3(col, scol * (0.50 + 0.72 * stone_h)[..., None], stone * 0.96)
    col = mix3(col, mix3((0.205, 0.195, 0.170), (0.520, 0.485, 0.402), tone2) *
               (0.56 + 0.62 * st2_h)[..., None], st2 * 0.90)
    col = mix3(col, mix3((0.185, 0.176, 0.155), (0.420, 0.392, 0.325), tone3) *
               (0.66 + 0.48 * st3_h)[..., None], st3 * 0.70)

    # dried mud polygons
    col = mix3(col, (0.560, 0.492, 0.360), dcrack_edge(dcrack) * 0.35)
    col = mix3(col, (0.060, 0.050, 0.038), dcrack * 0.75)

    ao = cavity_ao(h, 6.0, 2.4, 0.34)
    col = col * (0.52 + 0.48 * ao)[..., None]

    # --- wetness: standing water in the lows -> very glossy; crests dry out
    wet = smoothstep(0.58, 0.18, h) * smoothstep(0.20, 0.70, norm01(fbm(n, 8, 5, seed=seed + 13)) + 0.30)
    wet = np.clip(wet * (1.0 - dry_zone * 0.85), 0, 1)
    col = col * (1.0 - 0.34 * wet)[..., None]
    rough = (0.500 - 0.40 * wet + 0.18 * (1 - mot) + 0.12 * fine
             + 0.22 * smoothstep(0.55, 1.0, h) + 0.16 * dry_zone - 0.12 * stone)
    rough = np.clip(rough, 0.05, 0.88)
    return np.clip(col, 0, 1), h, rough, 32.0


def make_forest_floor(n=N, seed=6606):
    r = rng(seed)

    # ---------------- humus / soil substrate ----------------
    hum = norm01(fbm(n, 9, 6, gain=0.55, seed=seed + 1))
    hum2 = norm01(billow(n, 30, 4, seed=seed + 2))
    fine = norm01(fbm(n, 130, 4, gain=0.55, seed=seed + 3))
    dark = mix3((0.055, 0.042, 0.030), (0.150, 0.110, 0.070), hum)
    dark = mix3(dark, (0.230, 0.172, 0.108), smoothstep(0.55, 1.0, 0.6 * hum + 0.4 * hum2) * 0.8)
    dark *= (0.85 + 0.30 * fine)[..., None]
    base_h = 0.16 + 0.10 * hum + 0.05 * hum2 + 0.04 * fine

    cv = Canvas(n, dark, base_h, np.clip(0.90 + 0.07 * (fine - 0.5), 0.6, 1.0))

    mottle = norm01(fbm(n, 22, 5, gain=0.55, seed=seed + 4))

    # ---------------- moss on the substrate ----------------
    # laid down BEFORE the litter so it shows through the gaps rather than
    # sitting on top of the leaves like paint
    mwx = fbm(n, 14, 4, seed=seed + 24) * 22.0
    mwy = fbm(n, 14, 4, seed=seed + 25) * 22.0
    mw = worley(n, 12, seed + 26, jitter=1.0, wx=mwx, wy=mwy)
    msel, mrad = cell_random(mw, seed + 27, 2)
    mblob = ((msel < 0.34).astype(np.float32) *
             smoothstep(0.0, 0.45, np.clip(1.0 - mw["f1"] / (0.32 + 0.45 * mrad), 0, 1)))
    mm2 = norm01(billow(n, 30, 4, seed=seed + 22))
    mfuzz = norm01(fbm(n, 210, 3, gain=0.5, seed=seed + 23))
    mfuzz2 = norm01(fbm(n, 70, 3, seed=seed + 28))
    moss = np.clip(mblob * (0.35 + 0.85 * mfuzz2) * smoothstep(0.15, 0.65, mm2), 0, 1)
    moss = smoothstep(0.12, 0.55, moss)
    mcol = mix3((0.075, 0.175, 0.062), (0.235, 0.368, 0.108), mfuzz)
    mcol = mix3(mcol, (0.380, 0.452, 0.150), smoothstep(0.60, 1.0, mm2) * 0.65)
    mcol = mix3(mcol, (0.140, 0.250, 0.130), smoothstep(0.65, 1.0, 1.0 - mfuzz) * 0.5)
    cv.col = mix3(cv.col, mcol, moss * 0.94)
    cv.h = cv.h + 0.075 * moss * (0.4 + 0.6 * mfuzz)
    cv.r = lerp(cv.r, 0.95 + 0.04 * (mfuzz - 0.5), moss * 0.9)

    # ---------------- leaf litter ----------------
    # Muted deciduous palette: browns carry the texture, ochre and red are
    # accents.  A saturated red/cream mix reads as confetti, not litter.
    palette = [
        ((0.520, 0.352, 0.135), 0.15),   # ochre
        ((0.415, 0.268, 0.128), 0.20),   # warm brown
        ((0.352, 0.140, 0.092), 0.09),   # deep red
        ((0.470, 0.228, 0.108), 0.10),   # rust
        ((0.565, 0.468, 0.300), 0.09),   # pale tan / bleached
        ((0.360, 0.348, 0.165), 0.08),   # fading olive
        ((0.205, 0.132, 0.082), 0.16),   # dark chocolate, older litter
        ((0.280, 0.205, 0.112), 0.13),   # damp brown
    ]
    pcols = [p[0] for p in palette]
    pw = np.array([p[1] for p in palette], np.float64)
    pw /= pw.sum()

    # leaves collect in drifts instead of spreading evenly
    drift = norm01(fbm(n, 5, 4, gain=0.55, seed=seed + 40))

    def place(bias):
        """Rejection-sample a position so litter piles up in the drifts."""
        for _ in range(6):
            cy = int(r.integers(0, n))
            cx = int(r.integers(0, n))
            if r.random() < (0.30 + 0.70 * drift[cy, cx]) ** bias:
                return cy, cx
        return cy, cx

    # Deep layers are drawn dark (they sit in shadow under everything above);
    # the top layers keep a wide size spread so the litter never reads as confetti.
    LAYERS = [
        # (count, len_lo, len_hi, z_lo, z_hi, dark_mul)
        (620, 55, 125, 0.16, 0.34, 0.40),
        (560, 48, 115, 0.30, 0.48, 0.60),
        (480, 42, 108, 0.44, 0.62, 0.82),
        (330, 38, 135, 0.58, 0.74, 1.00),
        (170, 70, 185, 0.70, 0.84, 1.08),     # a few big whole leaves on top
        (260, 20, 62, 0.76, 0.92, 1.02),      # small broken litter
    ]
    for li, (count, llo, lhi, zlo, zhi, dmul) in enumerate(LAYERS):
        for _ in range(count):
            L = float(r.uniform(llo, lhi))
            W = L * float(r.uniform(0.20, 0.40))
            ci = int(r.choice(len(pcols), p=pw))
            c = np.asarray(pcols[ci], np.float32) * (0.78 + 0.46 * r.random()) * dmul
            cy, cx = place(1.4)
            splat_leaf(cv, cy, cx, L, W,
                       float(r.uniform(0, math.pi * 2)), np.clip(c, 0, 1),
                       float(r.uniform(zlo, zhi)), float(r.uniform(-1.0, 1.0)), r,
                       mottle=mottle, rough=float(r.uniform(0.52, 0.80)),
                       tip_dark=float(r.uniform(0.15, 0.45)),
                       asym=float(r.uniform(-0.18, 0.18)),
                       shape=(float(r.uniform(0.42, 0.95)), float(r.uniform(0.10, 0.38))))
        # twigs go in mid-stack so they end up half-buried, not lying on top
        if li == 2:
            twig_cols = [(0.330, 0.252, 0.155), (0.255, 0.188, 0.115),
                         (0.420, 0.330, 0.208), (0.198, 0.148, 0.098)]
            for _ in range(80):
                cy, cx = place(0.8)
                splat_twig(cv, cy, cx, float(r.uniform(45, 200)),
                           float(r.uniform(2.5, 7.0)), float(r.uniform(0, math.pi * 2)),
                           twig_cols[int(r.integers(0, len(twig_cols)))],
                           float(r.uniform(0.52, 0.66)), r)

    col = cv.col
    h = cv.h
    rough = cv.r

    # ---------------- moss creeping over the lowest litter ----------------
    creep = np.clip(moss * smoothstep(0.66, 0.22, h), 0, 1)
    col = mix3(col, mcol, creep * 0.62)
    h = h + 0.022 * creep * mfuzz
    rough = lerp(rough, 0.95 + 0.04 * (mfuzz - 0.5), creep * 0.75)
    moss = np.clip(np.maximum(moss * (1.0 - cv.mask * 0.6), creep), 0, 1)

    # ---------------- integration pass ----------------
    # damp shadow settling into the gaps between leaves
    ao = cavity_ao(h, 3.5, 3.6, 0.16)
    ao2 = cavity_ao(h, 16.0, 1.8, 0.34)
    col = col * (0.26 + 0.74 * ao)[..., None] * (0.50 + 0.50 * ao2)[..., None]
    # metre-scale damp/dry variation, mid-frequency so the tile does not repeat
    dampness = smoothstep(0.35, 0.85, norm01(fbm(n, 7, 5, gain=0.55, seed=seed + 31)))
    col = col * (1.0 - 0.32 * dampness)[..., None]
    col = mix3(col, (0.070, 0.052, 0.038), dampness * 0.26)
    # a few shafts of dry bleached litter to lift the mid-tones
    lift = smoothstep(0.68, 1.0, norm01(fbm(n, 11, 4, seed=seed + 32)))
    col = mix3(col, (0.680, 0.552, 0.330), lift * 0.16 * (1.0 - moss))
    rough = np.clip(rough - 0.16 * dampness + 0.05 * (fine - 0.5), 0.32, 0.99)

    # dust of fine debris on top to break up the leaf edges a little
    col *= (0.93 + 0.14 * fine)[..., None]

    h = np.clip(norm01(h, 0.2, 99.8), 0, 1)
    return np.clip(col, 0, 1), h, rough, 30.0


def make_detail_noise(n=512, seed=7707):
    R = norm01(fbm(n, 96, 4, gain=0.55, seed=seed + 1))
    G = norm01(fbm(n, 24, 5, gain=0.55, seed=seed + 2))
    B = norm01(fbm(n, 5, 4, gain=0.55, seed=seed + 3))
    # centre each octave band around 0.5 so it can be used as a signed multiplier
    def ctr(x):
        return np.clip(0.5 + (x - float(np.mean(x))) * 1.02, 0, 1)
    rgb = np.stack([ctr(R), ctr(G), ctr(B)], -1)
    p = os.path.join(OUT, "detail_noise.png")
    save_rgb(to_u8(rgb), p)
    WRITTEN.append(p)
    return rgb


# ======================================================================================
#  verification
# ======================================================================================

def luma(a):
    a = a.astype(np.float32)
    return 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]


def seam_ratio(a):
    """<edge discontinuity> / <interior discontinuity>.  ~1.0 == perfectly tileable."""
    a = a.astype(np.float32)
    ecol = np.abs(a[:, 0] - a[:, -1]).mean()
    erow = np.abs(a[0, :] - a[-1, :]).mean()
    icol = np.abs(a[:, 1:] - a[:, :-1]).mean()
    irow = np.abs(a[1:, :] - a[:-1, :]).mean()
    return (ecol / max(icol, 1e-6), erow / max(irow, 1e-6), ecol, erow)


def verify_all():
    rows = []
    problems = []
    for p in WRITTEN:
        if not os.path.isfile(p):
            problems.append(f"MISSING {p}")
            continue
        im = Image.open(p)
        arr = np.asarray(im)
        lm = luma(arr)
        sc, sr, ec, er = seam_ratio(arr)
        row = {
            "path": p,
            "bytes": os.path.getsize(p),
            "dims": f"{im.size[0]}x{im.size[1]}",
            "mode": im.mode,
            "mean": float(lm.mean()),
            "std": float(lm.std()),
            "seam_x": sc, "seam_y": sr, "edge_mad": max(ec, er),
        }
        base = os.path.basename(p)
        if "_normal" in base:
            row["nrg_std"] = float(np.std(arr[..., 0].astype(np.float32))), float(np.std(arr[..., 1].astype(np.float32)))
            if min(row["nrg_std"]) < 12.0:
                problems.append(f"FLAT NORMAL {base} rg_std={row['nrg_std']}")
        else:
            if row["std"] <= 8.0:
                problems.append(f"UNIFORM {base} luma_std={row['std']:.2f}")
        if max(sc, sr) > 1.6:
            problems.append(f"SEAM {base} ratio=({sc:.2f},{sr:.2f})")
        rows.append(row)
    return rows, problems


def print_table(rows):
    hdr = f"{'file':<34} {'dims':>9} {'mode':>5} {'KB':>7} {'luma_mean':>10} {'luma_std':>9} {'seamX':>6} {'seamY':>6}"
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        print(f"{os.path.basename(r['path']):<34} {r['dims']:>9} {r['mode']:>5} "
              f"{r['bytes']/1024:>7.1f} {r['mean']:>10.2f} {r['std']:>9.2f} "
              f"{r['seam_x']:>6.2f} {r['seam_y']:>6.2f}")


def write_previews(mats):
    """Contact sheet + 2x2 tiled sheet so the result can be eyeballed."""
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    TH = 256
    names = [m[0] for m in mats]
    sheet = Image.new("RGB", (TH * 3 + 24, TH * len(names) + 8 * len(names)), (18, 18, 20))
    tiled = Image.new("RGB", (TH * len(names) + 8 * len(names), TH), (18, 18, 20))
    for i, nm in enumerate(names):
        for j, k in enumerate(("albedo", "normal", "rough")):
            im = Image.open(os.path.join(OUT, f"{nm}_{k}.png")).resize((TH, TH), Image.LANCZOS)
            sheet.paste(im, (j * (TH + 8), i * (TH + 8)))
        a = Image.open(os.path.join(OUT, f"{nm}_albedo.png")).resize((TH // 2, TH // 2), Image.LANCZOS)
        blk = Image.new("RGB", (TH, TH))
        for oy in (0, TH // 2):
            for ox in (0, TH // 2):
                blk.paste(a, (ox, oy))
        tiled.paste(blk, (i * (TH + 8), 0))
    p1 = os.path.join(PREVIEW_DIR, "contact_sheet.png")
    p2 = os.path.join(PREVIEW_DIR, "tiling_2x2.png")
    sheet.save(p1)
    tiled.save(p2)
    return p1, p2


# ======================================================================================

def main():
    os.makedirs(OUT, exist_ok=True)
    t0 = time.time()
    mats = [
        ("grass", make_grass),
        ("dirt", make_dirt),
        ("rock", make_rock),
        ("sand", make_sand),
        ("mud_river", make_mud_river),
        ("forest_floor", make_forest_floor),
    ]
    only = sys.argv[1:] if len(sys.argv) > 1 else None
    for name, fn in mats:
        if only and name not in only:
            continue
        t = time.time()
        col, h, rough, nstr = fn()
        write_material(name, col, h, rough, nstr)
        print(f"  [{name:<12}] {time.time()-t:6.1f}s", flush=True)
    if not only:
        make_detail_noise()
        print("  [detail_noise ]", flush=True)

    rows, problems = verify_all()
    print()
    print_table(rows)
    print()
    if not only:
        p1, p2 = write_previews([m for m in mats])
        print(f"preview contact sheet : {p1}")
        print(f"preview 2x2 tiling    : {p2}")
    print()
    if problems:
        print("PROBLEMS:")
        for p in problems:
            print("  !!", p)
    else:
        print("ALL CHECKS PASSED (non-uniform, non-flat normals, seamless)")
    print(f"total {time.time()-t0:.1f}s")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
