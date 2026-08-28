#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""RAMA - surface-detail textures for TRUE 3D leaf geometry.

The first-pass leaf atlases (leaf_banyan / leaf_mango / leaf_palm) each hold four
cells, and every cell is a whole CLUSTER of painted leaves. That is the right texture
for a flat card and exactly the wrong one for a real leaf: mapping a cluster onto one
lamina paints twelve leaves on a single leaf.

These are the replacements. Each image is one leaf's own parameter space:

    x in [0.000 .. 0.750]   the blade.  x = 0.375 is the midrib, the two edges are the
                            leaf margins.  So UV.x = 0.375 + u * 0.375 for u in [-1, 1].
    x in [0.885 .. 0.985]   a stem strip, for the twig of a sprig and the rachis of a
                            frond - so a whole sprig is ONE surface with ONE material.
    y                       runs from the TIP at the top to the PETIOLE at the bottom.

ALPHA IS 1 EVERYWHERE. The silhouette is the mesh's job now: the geometry is already
a tapered, cambered, drooping lamina, and an alpha cut on top of it would only nibble
the real outline away. What the texture supplies is what geometry at 10 triangles
cannot: venation, mottling, margin darkening, and a normal map with the lateral veins
in it.

Outputs (assets/textures):
    leaf_lamina_broad   banyan / sal / bush - broad, pinnate, glossy
    leaf_lamina_dark    mango - narrower, denser venation, much darker
    leaf_lamina_pinna   palm leaflets - parallel striations, no lateral veins
each with a matching _normal. The `leaf_` prefix matters: tools/fix_imports.py keys
lossless compression off it.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_tex_nature as N  # noqa: E402

S = 512
BLADE_X0, BLADE_X1 = 0.000, 0.750
STEM_X0, STEM_X1 = 0.885, 0.985


def _blade(shape, rng, pr):
    """Colour + height for the blade region, in leaf parameter space.

    u in [-1, 1] across the width, t in [0, 1] from petiole to tip.
    """
    h, w = shape
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float64)
    u = (xs + 0.5) / w * 2.0 - 1.0
    t = 1.0 - (ys + 0.5) / h
    au = np.abs(u)

    lam = np.clip(1.0 - au * au, 0.0, 1.0)
    # midrib: a real ridge, wide at the petiole and fading out before the tip
    mw = pr["mid_w"] * (1.0 - 0.55 * t) + 0.018
    mid = np.exp(-((u / mw) ** 2))
    # lateral veins sweep from the midrib toward the margin AND toward the tip
    nv = pr["nv"]
    ph = t * nv - au * pr["vein_sweep"] * nv + pr.get("vphase", 0.31)
    vein = np.exp(-(((ph - np.round(ph)) / pr["vein_w"]) ** 2)) * np.clip(au * 3.2, 0, 1)
    vein *= np.clip(1.0 - t * 0.35, 0, 1)

    # lengthwise striation: the only venation a palm leaflet has, and the thing that
    # makes one read as a leaflet rather than a green strip
    stripe = np.zeros_like(u)
    if pr.get("stripe_n", 0) > 0:
        sp = np.sin(u * np.pi * pr["stripe_n"] + 0.7 * N.local_fbm(shape, 3, rng, 3))
        stripe = (np.abs(sp) ** 0.55) * np.clip(1.0 - au * 0.4, 0, 1)

    hh = pr["cup"] * np.sqrt(lam) + pr["mid_amp"] * mid * (1.0 - 0.5 * t) + pr["vein_amp"] * vein
    hh += pr.get("stripe_amp", 0.0) * stripe
    # the margin rolls slightly under, which is what catches a rim light
    hh -= 0.30 * N.smoothstep(0.80, 1.0, au)

    mott = N.local_fbm(shape, 3, rng, 4) * 0.5 + 0.5
    fine = N.local_fbm(shape, 14, rng, 3)
    cA = np.array(pr["col_a"])
    cB = np.array(pr["col_b"])
    tone = np.clip(mott * 1.30 - 0.15 + 0.22 * fine, 0, 1)[..., None]
    col = cA[None, None, :] * (1 - tone) + cB[None, None, :] * tone
    # darker toward the margin, darker at the shaded petiole end, lighter at the tip
    md = pr["margin_dark"]
    col = col * (1.0 - md + md * np.clip(lam + 0.25, 0, 1))[..., None]
    col = col * (1.0 - pr["base_dark"] * (1.0 - N.smoothstep(0.0, 0.45, t)))[..., None]
    col = col * (1.0 + pr["tip_light"] * N.smoothstep(0.35, 1.0, t))[..., None]
    vm = np.clip(vein * 0.8 + mid, 0, 1)[..., None] * pr["vein_mix"]
    col = col * (1 - vm) + np.array(pr["vein_col"])[None, None, :] * vm
    if pr.get("stripe_amp", 0.0) > 0.0:
        col = col * (0.86 + 0.22 * stripe)[..., None]
    if pr.get("dry", 0.0) > 0.0:
        dm = N.smoothstep(pr["dry"], min(0.999, pr["dry"] + 0.34), t + 0.14 * mott - 0.07)[..., None]
        col = col * (1 - dm * 0.85) + np.array(pr["dry_col"])[None, None, :] * dm * 0.85
    col = col * (1.0 + 0.09 * fine)[..., None]
    return np.clip(col, 0, 1), hh


def _stem(shape, rng, col_a, col_b):
    """A short length of twig, seen unrolled. Lengthwise fibre, no bark plates:
    at 15 mm across nothing coarser than a fibre survives one pixel."""
    h, w = shape
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float64)
    ux = (xs + 0.5) / w
    fib = N.local_fbm(shape, 2, rng, 4) * 0.5 + 0.5
    streak = N.local_fbm((h, max(2, w // 3)), 2, rng, 3)
    streak = np.repeat(streak, w // max(1, w // 3) + 1, axis=1)[:, :w]
    v = np.clip(fib * 0.7 + streak * 0.45 + 0.15, 0, 1)
    cA = np.array(col_a)
    cB = np.array(col_b)
    col = cA[None, None, :] * (1 - v[..., None]) + cB[None, None, :] * v[..., None]
    # a round twig is dark at both silhouette edges; the geometry is a 3-sided prism,
    # so this is the only thing making it read as round at all
    shade = 0.52 + 0.48 * np.sin(np.clip(ux, 0, 1) * np.pi) ** 0.7
    col = col * shade[..., None]
    hh = v * 0.5 + 0.5 * np.sin(np.clip(ux, 0, 1) * np.pi)
    return np.clip(col, 0, 1), hh


def build(name, rng, pr, stem_a, stem_b, strength=7.0):
    rgb = np.zeros((S, S, 3))
    hgt = np.zeros((S, S))
    bx0, bx1 = int(BLADE_X0 * S), int(BLADE_X1 * S)
    sx0, sx1 = int(STEM_X0 * S), int(STEM_X1 * S)
    c, h = _blade((S, bx1 - bx0), rng, pr)
    rgb[:, bx0:bx1] = c
    hgt[:, bx0:bx1] = h
    c, h = _stem((S, sx1 - sx0), rng, stem_a, stem_b)
    rgb[:, sx0:sx1] = c
    hgt[:, sx0:sx1] = h
    # fill the guard band either side of the stem with its own edge colour, so a low
    # mip blends stem into stem instead of dragging blade green across it
    rgb[:, bx1:sx0] = rgb[:, sx0 : sx0 + 1]
    hgt[:, bx1:sx0] = hgt[:, sx0 : sx0 + 1]
    rgb[:, sx1:] = rgb[:, sx1 - 1 : sx1]
    hgt[:, sx1:] = hgt[:, sx1 - 1 : sx1]

    alpha = np.ones((S, S))
    N.save_rgba(rgb, alpha, name + ".png", kind="foliage", sharpen=0.0)
    nrm = N.height_to_normal(N.gblur(hgt, 0.6), strength=strength, tileable=False)
    N.save_normal_u8(nrm, name + "_normal.png", tileable=False)
    print("  wrote %s(.png/_normal.png)" % name)


BROAD = dict(
    nv=9, stripe_n=0.0, stripe_amp=0.0, vein_sweep=0.42, vein_w=0.16, vein_amp=0.30, vein_mix=0.40,
    mid_w=0.070, mid_amp=1.00, cup=0.34, margin_dark=0.34, base_dark=0.18, tip_light=0.10,
    col_a=(0.095, 0.245, 0.090), col_b=(0.255, 0.500, 0.180),
    vein_col=(0.430, 0.570, 0.250), dry=0.0, dry_col=(0.62, 0.52, 0.16),
)
DARK = dict(
    nv=15, stripe_n=0.0, stripe_amp=0.0, vein_sweep=0.50, vein_w=0.13, vein_amp=0.26, vein_mix=0.32,
    mid_w=0.055, mid_amp=0.88, cup=0.28, margin_dark=0.30, base_dark=0.22, tip_light=0.14,
    col_a=(0.082, 0.245, 0.096), col_b=(0.215, 0.450, 0.160),
    vein_col=(0.295, 0.415, 0.175), dry=0.0, dry_col=(0.44, 0.26, 0.12),
)
PINNA = dict(
    nv=1, vein_sweep=0.0, vein_w=0.30, vein_amp=0.04, vein_mix=0.26,
    mid_w=0.150, mid_amp=0.70, cup=0.44, margin_dark=0.26, base_dark=0.10, tip_light=0.06,
    stripe_n=11.0, stripe_amp=0.30,
    col_a=(0.080, 0.190, 0.066), col_b=(0.168, 0.320, 0.112),
    vein_col=(0.235, 0.360, 0.145), dry=0.90, dry_col=(0.520, 0.430, 0.205),
)


def main():
    rng = np.random.default_rng(0x5241_4D41)
    print("leaf3d surface textures ->", N.OUT)
    build("leaf_lamina_broad", rng, BROAD, (0.300, 0.245, 0.140), (0.470, 0.395, 0.230))
    build("leaf_lamina_dark", rng, DARK, (0.255, 0.205, 0.120), (0.410, 0.335, 0.195))
    # a palm rachis is a pale straw-green spine, not a brown twig
    build("leaf_lamina_pinna", rng, PINNA, (0.330, 0.320, 0.155), (0.560, 0.520, 0.265), strength=4.0)


if __name__ == "__main__":
    main()
