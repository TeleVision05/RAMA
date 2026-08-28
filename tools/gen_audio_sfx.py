#!/usr/bin/env python3
"""
RAMA — procedural sound-effect generator.

Synthesises every game SFX from scratch with numpy + the stdlib `wave` module.
No samples, no external audio libraries, no downloads: everything here is
original synthesis and therefore license-clean.

Output: assets/audio/*.wav  — 44100 Hz, 16-bit PCM, MONO.

Synthesis toolkit implemented below:
  * zero-phase FFT spectral shaping (Butterworth-magnitude LP/HP/BP, tilt)
  * 2-pole resonator / formant banks (exact IIR response applied in freq domain)
  * Chamberlin state-variable filter for time-varying sweeps
  * Karplus-Strong plucked string
  * modal (damped-sine) resonators for wood / metal / bell bodies
  * Rosenberg-glottal-pulse voice source with jitter, roughness AM and
    period-doubling for creature growls
  * Schroeder reverb (parallel feedback combs -> series allpasses), computed
    block-wise so it stays fast in pure numpy
  * granular layering with circular (wrap-around) placement for perfect loops

Loop strategy: looping beds (fire_crackle, water_lap) are synthesised entirely
with CIRCULAR operations — circular FFT filtering, LFOs whose frequencies are
integer multiples of 1/T, and grains placed with wrap-around indexing. The
result is mathematically seamless; the buffer is then rotated so the splice
point lands on a near-zero upward zero-crossing, so the file also starts and
ends at ~0.
"""

from __future__ import annotations

import math
import os
import re
import struct
import wave
import zlib

import numpy as np

# ----------------------------------------------------------------------------
# globals
# ----------------------------------------------------------------------------

SR = 44100
OUT_DIR = "/Users/tarunvadapalli/Documents/Git/UltraOpen/assets/audio"
TARGET_PEAK_DBFS = -3.0
TARGET_PEAK = 10.0 ** (TARGET_PEAK_DBFS / 20.0)

RNG = np.random.default_rng(20260828)


def seed(name: str) -> None:
    """Deterministic per-sound RNG so re-runs are byte-identical."""
    global RNG
    RNG = np.random.default_rng(zlib.crc32(name.encode()) ^ 0x5241_4D41)


def ns(dur: float) -> int:
    return max(1, int(round(dur * SR)))


def tarr(n: int) -> np.ndarray:
    return np.arange(n, dtype=np.float64) / SR


def white(n: int) -> np.ndarray:
    return RNG.standard_normal(n)


def uni(a: float, b: float) -> float:
    return float(RNG.uniform(a, b))


# ----------------------------------------------------------------------------
# spectral shaping (zero-phase FFT filtering)
# ----------------------------------------------------------------------------

def fft_shape(x: np.ndarray, mag_fn, circular: bool = False) -> np.ndarray:
    """Apply a frequency response. circular=True keeps the loop seamless."""
    n = len(x)
    if circular:
        xp = x
        N = n
    else:
        N = 1 << int(math.ceil(math.log2(max(8, n * 2))))
        xp = np.zeros(N)
        xp[:n] = x
    X = np.fft.rfft(xp)
    f = np.fft.rfftfreq(N, 1.0 / SR)
    y = np.fft.irfft(X * mag_fn(f), N)
    return y[:n]


def lp_mag(fc, order=4):
    def g(f):
        r = np.maximum(f, 1e-6) / fc
        return 1.0 / np.sqrt(1.0 + r ** (2 * order))
    return g


def hp_mag(fc, order=4):
    def g(f):
        r = (np.maximum(f, 1e-6) / fc) ** order
        return r / np.sqrt(1.0 + r * r)
    return g


def bp_mag(f_lo, f_hi, order=4):
    lo, hi = hp_mag(f_lo, order), lp_mag(f_hi, order)
    return lambda f: lo(f) * hi(f)


def tilt_mag(db_per_oct, f_ref=1000.0):
    def g(f):
        oct_ = np.log2(np.maximum(f, 20.0) / f_ref)
        return 10.0 ** (db_per_oct * oct_ / 20.0)
    return g


def reson_mag(f0, bw, gain=1.0):
    """Exact response of a 2-pole resonator, peak-normalised."""
    r = math.exp(-math.pi * bw / SR)
    cw = math.cos(2.0 * math.pi * f0 / SR)

    def g(f):
        zi = np.exp(-2j * np.pi * f / SR)
        H = 1.0 / (1.0 - 2.0 * r * cw * zi + (r * r) * zi * zi)
        m = np.max(np.abs(H))
        return gain * H / (m if m > 0 else 1.0)
    return g


def mag_mul(*fns):
    def g(f):
        out = np.ones(f.shape, dtype=complex)
        for fn in fns:
            out = out * fn(f)
        return out
    return g


def mag_sum(pairs):
    def g(f):
        out = np.zeros(f.shape, dtype=complex)
        for w, fn in pairs:
            out = out + w * fn(f)
        return out
    return g


def formant_bank(spec, tilt_db=-6.0, floor=0.05):
    """spec = [(freq, bandwidth, gain), ...]

    `floor` is a higher-pole correction. A bank of N isolated 2-pole resonators
    has a -12 dB/oct skirt above the top formant, so summing four of them makes
    the bank act as a brick-wall low-pass above F4 — measured 2026-08-28, the
    F_RAKSH bank at f0=64 Hz put the 4 kHz third-octave 50.6 dB below the peak
    even with a -3 dB/oct tilt, and the rendered growls held 0.04% of their
    energy above 1.5 kHz against 38% for their beast_snarl siblings. A real
    vocal tract has an infinite formant series whose tail leaves a broadband
    floor instead of a null, so add one: it is what carries the turbulence and
    the consonant edge that make a voice read as a voice rather than a hum.
    """
    pairs = [(g, reson_mag(f, b)) for f, b, g in spec]
    if floor > 0.0:
        pairs.append((floor, lambda f: np.ones(f.shape, dtype=complex)))
    return mag_mul(mag_sum(pairs), tilt_mag(tilt_db))


# ----------------------------------------------------------------------------
# time-varying state-variable filter (Chamberlin)
# ----------------------------------------------------------------------------

def svf(x, fc, q=1.4, mode="bp"):
    n = len(x)
    fcv = np.clip(np.broadcast_to(np.asarray(fc, dtype=np.float64), (n,)), 20.0, 8600.0)
    qv = np.broadcast_to(np.asarray(q, dtype=np.float64), (n,))
    fs = (2.0 * np.sin(np.pi * fcv / SR)).tolist()
    dp = np.clip(1.0 / np.maximum(qv, 0.5), 0.02, 1.4).tolist()
    xs = np.asarray(x, dtype=np.float64).tolist()
    out = [0.0] * n
    low = 0.0
    band = 0.0
    if mode == "lp":
        for i in range(n):
            low += fs[i] * band
            band += fs[i] * (xs[i] - low - dp[i] * band)
            out[i] = low
    elif mode == "hp":
        for i in range(n):
            low += fs[i] * band
            h = xs[i] - low - dp[i] * band
            band += fs[i] * h
            out[i] = h
    else:  # band-pass
        for i in range(n):
            low += fs[i] * band
            band += fs[i] * (xs[i] - low - dp[i] * band)
            out[i] = band
    return np.asarray(out, dtype=np.float64)


# ----------------------------------------------------------------------------
# envelopes / primitives
# ----------------------------------------------------------------------------

def env_ad(n, atk, dec, curve=3.0, hold=0.0):
    t = tarr(n)
    atk = max(atk, 1e-5)
    a = np.sin(np.clip(t / atk, 0.0, 1.0) * (np.pi / 2.0)) ** 2
    d = np.exp(-np.maximum(t - atk - hold, 0.0) / max(dec, 1e-5) * curve)
    return a * d


def env_bump(n, skew=0.75, power=1.6):
    u = np.linspace(0.0, 1.0, n)
    return np.sin(np.pi * (u ** skew)) ** power


def nband(n, f_lo, f_hi, order=2):
    """Band-limited noise normalised to unit RMS.

    Raw white() loses most of its level once it is band-limited (a 180-1400 Hz
    slice of a 22 kHz spectrum keeps only ~23% of the amplitude), so mixing it
    against a modal thump by raw gain silently buries it. Normalising first
    makes the mix gains mean what they say.
    """
    y = fft_shape(white(n), bp_mag(f_lo, f_hi, order))
    sd = float(np.std(y))
    return y / sd if sd > 1e-12 else y


def nlow(n, fc, order=3):
    y = fft_shape(white(n), lp_mag(fc, order))
    sd = float(np.std(y))
    return y / sd if sd > 1e-12 else y


def smooth_noise(n, hz):
    y = fft_shape(white(n), lp_mag(hz, 2))
    s = float(np.std(y))
    return y / s if s > 1e-12 else y


def sweep(n, f0, f1, shape="exp", knee=None):
    """Return (signal, freq_curve) for a swept sine."""
    u = np.linspace(0.0, 1.0, n)
    if knee is not None:
        f = np.where(u < knee[0],
                     f0 * (knee[1] / f0) ** np.clip(u / knee[0], 0, 1),
                     knee[1] * (f1 / knee[1]) ** np.clip((u - knee[0]) / (1 - knee[0]), 0, 1))
    elif shape == "exp":
        f = f0 * (max(f1, 1e-6) / max(f0, 1e-6)) ** u
    else:
        f = f0 + (f1 - f0) * u
    ph = 2.0 * np.pi * np.cumsum(f) / SR
    return np.sin(ph + uni(0, 6.283)), f


def modal(n, partials, jitter_hz=0.0):
    """partials = [(freq, amp, decay_seconds), ...] -> summed damped sines."""
    t = tarr(n)
    y = np.zeros(n)
    for f, a, d in partials:
        ff = f * (1.0 + uni(-jitter_hz, jitter_hz) / max(f, 1.0))
        y += a * np.sin(2.0 * np.pi * ff * t + uni(0, 6.283)) * np.exp(-t / max(d, 1e-4))
    return y


def click(n, bright=6000.0, dur=0.0018):
    """Very fast broadband transient."""
    m = min(n, ns(dur))
    x = np.zeros(n)
    x[:m] = white(m) * np.linspace(1.0, 0.0, m) ** 2
    return fft_shape(x, mag_mul(hp_mag(700, 2), lp_mag(bright, 3)))


def karplus(freq, dur, damp=0.995, lp=0.5, exc_lo=200.0, exc_hi=9000.0, tail=None):
    n = ns(dur)
    L = max(2, int(round(SR / freq)))
    exc = fft_shape(white(L + 1), bp_mag(exc_lo, exc_hi, 2))
    e = float(np.max(np.abs(exc)))
    if e > 0:
        exc = exc / e
    y = np.zeros(n)
    m = min(L + 1, n)
    y[:m] = exc[:m]
    ys = y.tolist()
    a = lp
    b = 1.0 - lp
    for i in range(L + 1, n):
        ys[i] = damp * (a * ys[i - L] + b * ys[i - L - 1])
    return np.asarray(ys)


def tame(x, k=2.0):
    """Soft-knee outliers above k x the 99.9th percentile.

    Granular beds occasionally stack two grains into one spike that is 6-7 dB
    above everything else; peak-normalising then leaves the whole bed quiet.
    Combat transients are never run through this.
    """
    thr = float(np.percentile(np.abs(x), 99.9)) * k
    if thr <= 0:
        return x
    a = np.abs(x)
    over = a > thr
    if not np.any(over):
        return x
    out = x.copy()
    out[over] = np.sign(x[over]) * thr * (1.0 + np.tanh((a[over] - thr) / thr))
    return out


def grain(dst, pos, g, wrap=False):
    n = len(dst)
    m = len(g)
    if wrap:
        p = pos % n
        if p + m <= n:
            dst[p:p + m] += g
        else:
            k = n - p
            dst[p:] += g[:k]
            rest = g[k:]
            while len(rest) >= n:
                dst += rest[:n]
                rest = rest[n:]
            dst[:len(rest)] += rest
    else:
        if pos >= n:
            return
        m = min(m, n - pos)
        dst[pos:pos + m] += g[:m]


# ----------------------------------------------------------------------------
# reverb (block-wise recursive combs / allpasses -> fast in numpy)
# ----------------------------------------------------------------------------

def _comb(x, D, g):
    y = x.copy()
    n = len(y)
    i = D
    while i < n:
        blk = min(D, n - i)
        y[i:i + blk] += g * y[i - D:i - D + blk]
        i += D
    return y


def _allpass(x, D, g):
    n = len(x)
    y = -g * x
    y[D:] += x[:n - D]
    i = D
    while i < n:
        blk = min(D, n - i)
        y[i:i + blk] += g * y[i - D:i - D + blk]
        i += D
    return y


def reverb(x, rt60=1.4, wet=0.32, size=1.0, damp_fc=5500.0, predelay=0.012):
    n = len(x)
    pd = ns(predelay)
    src = np.concatenate([np.zeros(pd), x])[:n] if pd < n else x
    combs = [1557, 1617, 1491, 1422, 1277, 1356, 1188, 1116]
    wetsig = np.zeros(n)
    for D0 in combs:
        D = max(8, int(D0 * size))
        if D >= n:
            continue
        g = 10.0 ** (-3.0 * D / (SR * max(rt60, 0.05)))
        g = min(g, 0.96)
        wetsig += _comb(src, D, g)
    wetsig /= len(combs)
    for D0, g in ((225, 0.5), (556, 0.5), (441, 0.5), (341, 0.5)):
        D = max(4, int(D0 * size))
        if D < n:
            wetsig = _allpass(wetsig, D, g)
    wetsig = fft_shape(wetsig, lp_mag(damp_fc, 2))
    return x * (1.0 - wet * 0.35) + wetsig * wet


# ----------------------------------------------------------------------------
# voice source (creatures + player)
# ----------------------------------------------------------------------------

def voice(n, f0_curve, formants, jitter=0.015, rough=0.0, rough_hz=45.0,
          noise_mix=0.08, sub=0.0, chaos=0.0, tilt_db=-3.0, hp=150.0,
          floor=0.05, rasp=0.0, rasp_band=(1400.0, 7000.0)):
    t = tarr(n)
    f0c = np.broadcast_to(np.asarray(f0_curve, dtype=np.float64), (n,))
    jit = smooth_noise(n, 26.0) * jitter + smooth_noise(n, 6.0) * jitter * 0.7
    f0 = np.maximum(f0c * (1.0 + jit), 25.0)
    ph = np.cumsum(f0) / SR
    frac = np.mod(ph, 1.0)

    t1, t2 = 0.46, 0.20
    op = 0.5 * (1.0 - np.cos(np.pi * np.clip(frac / t1, 0, 1)))
    cl = np.cos(np.pi * np.clip((frac - t1) / t2, 0, 1) / 2.0)
    p = np.where(frac < t1, op, np.where(frac < t1 + t2, cl, 0.0))

    src = np.diff(p, prepend=p[0]) * (SR / np.maximum(f0, 25.0)) * 0.35

    if sub > 0.0:  # period doubling -> guttural
        src *= 1.0 + sub * 0.5 * np.cos(np.pi * ph)
    if rough > 0.0:  # snarl AM
        src *= 1.0 + rough * (0.6 * np.sin(2.0 * np.pi * rough_hz * t + uni(0, 6.28))
                              + 0.4 * np.sin(2.0 * np.pi * rough_hz * 1.53 * t))
    if chaos > 0.0:
        src *= 1.0 + chaos * smooth_noise(n, 90.0)

    src += noise_mix * white(n) * (0.35 + 0.65 * p)
    # The formant bank alone leaves the glottal fundamental dominant, which on
    # small speakers reads as featureless rumble; the high-pass puts the energy
    # back where the formants (and therefore the character) live.
    out = fft_shape(src, mag_mul(formant_bank(formants, tilt_db, floor),
                                 hp_mag(hp, 2)))

    # Glottal turbulence. Adding it to `src` does not work: the formant bank is
    # downstream and nulls everything above the top formant, which is exactly
    # how the growls ended up with 0.04% of their energy above 1.5 kHz. It has
    # to be injected AFTER the bank, and gated by the pulse so it reads as
    # breath forced through a constriction rather than as a layer of hiss.
    if rasp > 0.0:
        out = out + rasp * nband(n, rasp_band[0], rasp_band[1], 2) * (0.28 + 0.72 * p)
    return out


F_RAMA = [(560, 90, 1.0), (1080, 130, 0.78), (2450, 190, 0.42), (3300, 260, 0.18)]
F_RAKSH = [(330, 95, 1.0), (760, 140, 0.88), (1750, 220, 0.46), (2900, 320, 0.18)]
F_RAKSH_OPEN = [(620, 110, 1.0), (1150, 160, 0.80), (2300, 240, 0.40), (3400, 340, 0.15)]
F_BEAST = [(480, 130, 1.0), (1250, 220, 0.90), (2600, 340, 0.55), (4200, 500, 0.22)]


# ============================================================================
# FOOTSTEPS
# ============================================================================

def footstep_grass(v):
    dur = 0.155
    n = ns(dur)
    y = np.zeros(n)
    for k, (off, amp, dec) in enumerate([(0.0, 1.0, 0.030), (uni(0.022, 0.034), 0.55, 0.042)]):
        m = n - ns(off)
        e = env_ad(m, 0.0012, dec, curve=2.6)
        b = fft_shape(white(m) * e, mag_mul(hp_mag(1400 * (1 + 0.06 * v), 2),
                                            lp_mag(9500, 2)))
        grain(y, ns(off), b * amp)
    # brushy blade grains
    for _ in range(RNG.integers(9, 15)):
        gl = ns(uni(0.004, 0.016))
        g = white(gl) * np.hanning(gl)
        g = fft_shape(g, bp_mag(uni(2500, 4200), uni(7000, 11000), 2))
        grain(y, ns(uni(0.0, 0.075)), g * uni(0.12, 0.4))
    # faint soil body under the swish
    y += fft_shape(white(n) * env_ad(n, 0.002, 0.035, 3.5), lp_mag(240, 3)) * 0.35
    return y * (0.9 + 0.05 * v)


def footstep_dirt(v):
    dur = 0.185
    n = ns(dur)
    y = np.zeros(n)
    # every parameter is drawn per variant, otherwise the four files are near
    # copies of each other and the walk cycle sounds like a machine
    thump_f = uni(76.0, 122.0)
    d1 = uni(0.024, 0.040)
    y += modal(n, [(thump_f, 1.0, d1), (thump_f * uni(1.9, 2.4), 0.55, d1 * 0.6),
                   (thump_f * uni(3.1, 3.9), 0.30, d1 * 0.4)]) * 0.22
    # packed-earth mid body: this is what makes it read as "dirt" not "sub drop"
    y += nband(n, uni(150, 230), uni(1300, 2100)) * \
        env_ad(n, uni(0.0008, 0.002), uni(0.024, 0.038), 3.0) * 1.15
    y += nlow(n, uni(340, 500)) * env_ad(n, 0.001, uni(0.022, 0.034), 3.0) * 0.30
    y += nband(n, 900, 3400) * env_ad(n, 0.0008, 0.014, 3.0) * 0.45
    # heel/toe second contact at a variant-specific offset
    off = uni(0.020, 0.042)
    m = n - ns(off)
    grain(y, ns(off), nband(m, 200, 1600) *
          env_ad(m, 0.001, uni(0.014, 0.026), 3.0) * uni(0.35, 0.60))
    for _ in range(RNG.integers(12, 22)):  # fine grit
        gl = ns(uni(0.0012, 0.005))
        g = white(gl) * np.hanning(gl)
        g = fft_shape(g, bp_mag(uni(2200, 3800), uni(6500, 9500), 2))
        grain(y, ns(uni(0.002, 0.10)), g * uni(0.04, 0.16))
    return y


def footstep_stone(v):
    dur = 0.185
    n = ns(dur)
    y = np.zeros(n)
    slap = fft_shape(white(n) * env_ad(n, uni(0.0005, 0.0009), uni(0.008, 0.014), 4.0),
                     mag_mul(hp_mag(uni(900, 1500), 2), lp_mag(12000, 2)))
    y += slap * 1.25
    body = modal(n, [(uni(300, 420), 0.42, uni(0.016, 0.026)),
                     (uni(720, 980), 0.40, uni(0.011, 0.018)),
                     (uni(1400, 1900), 0.30, uni(0.008, 0.013)),
                     (uni(2500, 3400), 0.18, uni(0.005, 0.009)),
                     (uni(4200, 5400), 0.09, 0.004)])
    y += body * 0.85
    y += modal(n, [(uni(70.0, 96.0), 0.5, uni(0.016, 0.028))]) * 0.30
    # short room reflections
    for d, g in [(uni(0.009, 0.014), 0.34), (uni(0.017, 0.023), 0.22),
                 (uni(0.028, 0.036), 0.13), (uni(0.042, 0.053), 0.08)]:
        k = ns(d)
        if k < n:
            y[k:] += fft_shape(slap[:n - k], lp_mag(4200, 2)) * g
    return reverb(y, rt60=0.32, wet=0.20, size=0.5, damp_fc=5000)


def footstep_water(v):
    dur = 0.42
    n = ns(dur)
    y = np.zeros(n)
    # main splash: noise through a downward-swept band-pass
    m = ns(0.19)
    fc = np.geomspace(uni(3400.0, 4400.0), uni(320.0, 430.0), m)
    sp = svf(white(m) * env_ad(m, 0.0015, 0.055, 2.4), fc, q=2.2, mode="bp")
    sp += nband(m, 500, 5000) * env_ad(m, 0.001, 0.030, 3.0) * 0.55
    sp += nband(m, 3000, 11000) * env_ad(m, 0.001, 0.020, 3.2) * 0.30
    grain(y, 0, sp * 1.0)
    # every splash keeps a "plosh" of displaced water so the four variants read
    # as the same material
    y += nlow(n, uni(260, 340)) * env_ad(n, 0.002, uni(0.040, 0.055), 3.0) * 0.85
    y += nband(n, 150, 900) * env_ad(n, 0.0015, uni(0.030, 0.045), 3.0) * 0.55
    # droplet tail — droplets ring upward in pitch
    for _ in range(RNG.integers(4, 8)):
        dl = ns(uni(0.020, 0.055))
        f0 = uni(900, 2400)
        s, _f = sweep(dl, f0, f0 * uni(1.25, 1.9))
        d = s * env_ad(dl, 0.0008, uni(0.012, 0.028), 3.0)
        grain(y, ns(uni(0.10, 0.33)), d * uni(0.18, 0.42))
    return y


def land_soft():
    n = ns(0.34)
    y = modal(n, [(62, 1.0, 0.055), (128, 0.55, 0.030), (205, 0.36, 0.018),
                  (330, 0.22, 0.012)]) * 0.30
    y += nband(n, 180, 1500) * env_ad(n, 0.0015, 0.040, 3.0) * 1.15
    y += nlow(n, 600) * env_ad(n, 0.001, 0.030, 3.0) * 0.30
    y += nband(n, 1800, 7000) * env_ad(n, 0.001, 0.070, 2.4) * 0.45
    for _ in range(8):
        gl = ns(uni(0.002, 0.008))
        g = white(gl) * np.hanning(gl)
        grain(y, ns(uni(0.005, 0.13)), fft_shape(g, bp_mag(2500, 9000, 2)) * uni(0.04, 0.15))
    return y


def land_hard():
    n = ns(0.55)
    y = modal(n, [(48, 1.2, 0.090), (96, 0.75, 0.045), (163, 0.55, 0.026),
                  (244, 0.34, 0.016)]) * 0.24
    y += click(n, 9000, 0.003) * 1.1
    y += nband(n, 200, 2000) * env_ad(n, 0.001, 0.050, 3.0) * 1.70
    y += nlow(n, 900) * env_ad(n, 0.001, 0.055, 3.0) * 0.32
    y += nband(n, 2200, 9000) * env_ad(n, 0.0008, 0.100, 2.2) * 0.60
    y += modal(n, [(310, 0.45, 0.035), (620, 0.30, 0.020), (940, 0.16, 0.012)]) * 0.8
    return reverb(y, rt60=0.5, wet=0.16, size=0.7)


def jump():
    n = ns(0.30)
    m = ns(0.22)
    u = np.linspace(0, 1, m)
    fc = 700.0 * (3200.0 / 700.0) ** np.clip(u / 0.42, 0, 1)
    fc = np.where(u < 0.42, fc, 3200.0 * (900.0 / 3200.0) ** np.clip((u - 0.42) / 0.58, 0, 1))
    cloth = svf(white(m) * env_bump(m, 0.6, 1.5), fc, q=1.6, mode="bp")
    y = np.zeros(n)
    grain(y, 0, cloth * 1.0)
    y += fft_shape(white(n) * env_ad(n, 0.004, 0.070, 2.4), bp_mag(3000, 10000, 2)) * 0.30
    # small body effort
    eff = voice(n, np.linspace(150, 120, n), F_RAMA, jitter=0.02, noise_mix=0.45,
                hp=200.0)
    y += eff * env_ad(n, 0.008, 0.075, 3.0) * 0.22
    y += modal(n, [(70, 0.35, 0.035)])
    return y


# ============================================================================
# BOW
# ============================================================================

def bow_draw():
    dur = 0.78
    n = ns(dur)
    y = np.zeros(n)
    u = np.linspace(0, 1, n)
    # stick-slip wood creak: irregular grain train, rising in rate and pitch
    tpos = 0.008
    while tpos < 0.72:
        gl = ns(uni(0.006, 0.020))
        f = uni(240, 420) * (1.0 + 1.5 * (tpos / 0.75))
        g = modal(gl, [(f, 1.0, uni(0.004, 0.012)),
                       (f * 2.03, 0.4, 0.005),
                       (f * 3.4, 0.18, 0.003)])
        g += fft_shape(white(gl) * env_ad(gl, 0.0006, 0.004, 3.0), bp_mag(1200, 6000, 2)) * 0.45
        amp = 0.25 + 0.75 * (tpos / 0.75) ** 1.3
        grain(y, ns(tpos), g * amp * uni(0.5, 1.0))
        tpos += uni(0.012, 0.040) * (1.0 - 0.55 * (tpos / 0.75))
    # string tension: rising filtered noise + a thin rising partial
    ten = svf(white(n) * (0.15 + 0.85 * u ** 1.6),
              np.geomspace(700, 3400, n), q=3.2, mode="bp")
    y += ten * 0.30
    s, _ = sweep(n, 380, 900)
    y += s * (u ** 2.2) * 0.10
    # low leather/limb groan
    y += fft_shape(white(n) * (0.2 + 0.8 * u), lp_mag(260, 3)) * 0.25 * u
    y *= np.minimum(1.0, np.linspace(0, 12, n)) * np.concatenate(
        [np.ones(n - ns(0.05)), np.cos(np.linspace(0, np.pi / 2, ns(0.05))) ** 2])
    return y


def bow_full():
    n = ns(0.075)
    y = click(n, 9000, 0.0012) * 0.7
    y += modal(n, [(2950, 0.9, 0.006), (4400, 0.5, 0.004), (1650, 0.4, 0.009),
                   (7200, 0.2, 0.002)])
    y += fft_shape(white(n) * env_ad(n, 0.0004, 0.006, 4.0), bp_mag(2000, 11000, 2)) * 0.4
    return y


def bow_release():
    n = ns(0.55)
    y = np.zeros(n)
    # THWACK: fast-decaying plucked string
    for f, a, dmp in [(186.0, 1.0, 0.9955), (247.0, 0.45, 0.9948)]:
        k = karplus(f, 0.34, damp=dmp, lp=0.42, exc_lo=300, exc_hi=9000)
        grain(y, 0, k * a * np.exp(-tarr(len(k)) / 0.075))
    y += click(n, 11000, 0.0022) * 0.85
    # limb thump
    y += modal(n, [(92, 0.7, 0.030), (168, 0.3, 0.018), (430, 0.2, 0.010)])
    # air whoosh of the loosed arrow
    m = ns(0.26)
    fc = np.geomspace(2600, 700, m)
    y[:m] += svf(white(m) * env_bump(m, 0.45, 1.4), fc, q=1.8, mode="bp") * 0.35
    y += fft_shape(white(n) * env_ad(n, 0.0008, 0.020, 3.0), bp_mag(1500, 9000, 2)) * 0.30
    return reverb(y, rt60=0.45, wet=0.12, size=0.6)


def arrow_flight():
    dur = 0.84
    n = ns(dur)
    u = np.linspace(0, 1, n)
    # airy whistle, doppler-ish falling pitch
    fc = 2400.0 * (820.0 / 2400.0) ** (u ** 0.85)
    # one band-pass pass leaves too much broadband leakage for the sweep to be
    # audible; cascading two makes the falling band the dominant feature
    air = svf(svf(white(n), fc, q=5.0, mode="bp"), fc, q=5.0, mode="bp")
    air /= max(float(np.max(np.abs(air))), 1e-9)
    amp = np.sin(np.pi * np.clip(u * 1.02, 0, 1) ** 0.8) ** 1.2
    y = air * amp * 0.85
    # thin tonal whistle with vibrato riding the same contour
    vib = 1.0 + 0.012 * np.sin(2 * np.pi * 6.5 * tarr(n))
    ph = 2 * np.pi * np.cumsum(fc * vib) / SR
    y += np.sin(ph) * amp * 0.22
    y += np.sin(2 * ph) * amp * 0.06
    # fletching flutter
    y *= 1.0 + 0.18 * np.sin(2 * np.pi * 74.0 * tarr(n)) * amp
    y += nband(n, 1800, 6500) * amp * 0.10
    # a falling global low-pass so the air, the whistle and the flutter all
    # doppler down together instead of leaving a static hiss behind
    y = svf(y, np.minimum(fc * 3.0, 8400.0), q=0.8, mode="lp")
    return y


def arrow_hit_flesh():
    n = ns(0.32)
    y = modal(n, [(74, 1.0, 0.045), (132, 0.70, 0.026), (196, 0.42, 0.015)]) * 0.17
    y += nband(n, 190, 1600) * env_ad(n, 0.0008, 0.026, 3.0) * 1.35
    y += nlow(n, 500) * env_ad(n, 0.0008, 0.030, 3.0) * 0.28
    # wet slap
    m = ns(0.10)
    slap = svf(white(m) * env_ad(m, 0.0008, 0.022, 3.0),
               np.geomspace(1800, 380, m), q=2.4, mode="bp")
    slap /= max(float(np.max(np.abs(slap))), 1e-9)
    y[:m] += slap * 0.85
    # squelch tail
    m2 = ns(0.14)
    y[ns(0.03):ns(0.03) + m2] += svf(white(m2) * env_ad(m2, 0.006, 0.045, 2.6),
                                     np.geomspace(700, 300, m2), q=3.0, mode="bp") * 0.35
    y += click(n, 5000, 0.0012) * 0.40
    return y


def arrow_hit_wood():
    n = ns(0.40)
    y = click(n, 11000, 0.0020) * 1.10
    y += modal(n, [(310, 0.55, 0.070), (527, 0.75, 0.052), (868, 0.70, 0.036),
                   (1390, 0.62, 0.024), (2180, 0.48, 0.016), (3260, 0.32, 0.010),
                   (4700, 0.18, 0.007), (6300, 0.09, 0.005)])
    y += nband(n, 700, 7000) * env_ad(n, 0.0006, 0.016, 3.2) * 1.70
    y += nband(n, 2000, 11000) * env_ad(n, 0.0004, 0.007, 4.0) * 0.80
    y += nband(n, 200, 1200) * env_ad(n, 0.0008, 0.022, 3.0) * 0.55
    y += modal(n, [(96, 0.22, 0.026)]) * 0.5
    return y


def arrow_hit_stone():
    n = ns(0.55)
    y = click(n, 14000, 0.0016) * 0.55
    y += nband(n, 1500, 14000) * env_ad(n, 0.0004, 0.020, 3.4) * 1.30
    y += nband(n, 5000, 16000) * env_ad(n, 0.0003, 0.009, 3.6) * 0.55
    y += nband(n, 400, 2200) * env_ad(n, 0.0006, 0.030, 3.0) * 0.85
    y += modal(n, [(1450, 0.55, 0.035), (2900, 0.40, 0.022), (620, 0.38, 0.040),
                   (4300, 0.22, 0.014), (960, 0.30, 0.030)])
    # ricochet ping: descending glissando
    m = ns(0.34)
    s, _ = sweep(m, 3400, 1500)
    ping = s * env_ad(m, 0.0008, 0.22, 2.2)
    s2, _ = sweep(m, 5100, 2350)
    ping += s2 * env_ad(m, 0.0008, 0.14, 2.6) * 0.45
    grain(y, ns(0.010), ping * 0.80)
    grain(y, ns(0.075), ping * 0.30)
    grain(y, ns(0.150), ping * 0.12)
    return reverb(y, rt60=0.55, wet=0.20, size=0.75, damp_fc=7000)


def arrow_pickup():
    n = ns(0.30)
    y = np.zeros(n)
    for k in range(RNG.integers(4, 7)):
        gl = ns(0.09)
        f = uni(700, 1500)
        g = modal(gl, [(f, 1.0, uni(0.010, 0.024)), (f * 1.94, 0.42, 0.010),
                       (f * 3.1, 0.18, 0.006)])
        g += click(gl, 8000, 0.001) * 0.35
        grain(y, ns(uni(0.0, 0.16)), g * uni(0.35, 1.0))
    y += fft_shape(white(n) * env_ad(n, 0.002, 0.040, 3.0), bp_mag(2500, 9000, 2)) * 0.12
    return y


# ============================================================================
# MELEE
# ============================================================================

def sword_swing(v):
    cfg = [(0.32, 2100, 380, 1.6), (0.25, 2700, 460, 2.0), (0.19, 3400, 620, 2.4)][v - 1]
    dur, f_hi, f_lo, q = cfg
    n = ns(dur + 0.06)
    m = ns(dur)
    u = np.linspace(0, 1, m)
    fc = f_hi * (f_lo / f_hi) ** (u ** 0.8)
    amp = np.sin(np.pi * np.clip(u * 1.05, 0, 1) ** 0.65) ** 1.5
    body = svf(white(m) * amp, fc, q=q, mode="bp")
    body /= max(float(np.max(np.abs(body))), 1e-9)
    y = np.zeros(n)
    grain(y, 0, body)
    # a second, brighter blade layer an octave up
    hi = svf(white(m) * amp, np.minimum(fc * 2.3, 8500), q=q * 1.4, mode="bp")
    hi /= max(float(np.max(np.abs(hi))), 1e-9)
    grain(y, ns(0.004), hi * 0.35)
    # low air displacement
    y += fft_shape(white(n) * env_bump(n, 0.7, 1.4), lp_mag(320, 3)) * 0.30
    # faint edge tone
    s, _ = sweep(m, f_hi * 0.9, f_lo * 1.2)
    grain(y, 0, s * amp * 0.06)
    return y


def sword_hit_flesh():
    n = ns(0.45)
    y = modal(n, [(68, 1.0, 0.055), (124, 0.60, 0.030), (188, 0.34, 0.018)]) * 0.30
    y += nband(n, 190, 1700) * env_ad(n, 0.0008, 0.032, 3.0) * 1.25
    y += nlow(n, 560) * env_ad(n, 0.0008, 0.035, 3.0) * 0.30
    m = ns(0.13)
    sl = svf(white(m) * env_ad(m, 0.0008, 0.028, 3.0),
             np.geomspace(2200, 400, m), q=2.2, mode="bp")
    sl /= max(float(np.max(np.abs(sl))), 1e-9)
    y[:m] += sl * 0.75
    # metallic edge
    y += modal(n, [(2380, 0.42, 0.070), (3510, 0.32, 0.048), (4870, 0.20, 0.030),
                   (6420, 0.11, 0.018)]) * 1.0
    y += click(n, 12000, 0.0014) * 0.60
    return reverb(y, rt60=0.4, wet=0.12, size=0.6)


def sword_hit_block():
    n = ns(1.55)
    parts = []
    base = 1180.0
    for r, a, d in [(0.52, 0.26, 0.55), (1.00, 1.00, 0.95), (1.51, 0.78, 0.80),
                    (2.13, 0.66, 0.60), (2.74, 0.58, 0.46), (3.41, 0.48, 0.38),
                    (4.29, 0.38, 0.30), (5.11, 0.30, 0.24), (6.37, 0.22, 0.18),
                    (7.82, 0.15, 0.13), (9.44, 0.09, 0.09)]:
        f = base * r
        parts.append((f, a, d))
        parts.append((f * 1.006, a * 0.55, d * 0.85))  # beating shimmer
    y = modal(n, parts) * 0.55
    y += click(n, 15000, 0.0018) * 0.9
    y += fft_shape(white(n) * env_ad(n, 0.0005, 0.020, 3.5),
                   mag_mul(hp_mag(2500, 2), lp_mag(16000, 2))) * 1.15
    y += modal(n, [(150, 0.22, 0.040), (300, 0.12, 0.024)])
    return reverb(y, rt60=0.9, wet=0.20, size=0.85, damp_fc=9000)


def sword_unsheathe():
    dur = 0.95
    n = ns(dur)
    y = np.zeros(n)
    m = ns(0.42)
    u = np.linspace(0, 1, m)
    # scrape: grainy noise with a rising resonant band
    fc = 900.0 * (5200.0 / 900.0) ** (u ** 1.25)
    fc = np.minimum(fc, 8400)
    grit = white(m) * (0.55 + 0.45 * smooth_noise(m, 220.0))
    scr = svf(grit * (0.25 + 0.75 * u ** 1.2), fc, q=4.0, mode="bp")
    scr /= max(float(np.max(np.abs(scr))), 1e-9)
    grain(y, 0, scr * 0.75)
    y[:m] += fft_shape(white(m) * (0.2 + 0.8 * u), bp_mag(3000, 11000, 2)) * 0.22
    # bright ring-out at the end
    r = ns(0.60)
    ring = modal(r, [(2640, 1.0, 0.30), (2652, 0.6, 0.26), (3960, 0.55, 0.20),
                     (5290, 0.30, 0.14), (7100, 0.16, 0.09), (1320, 0.25, 0.22)])
    ring *= env_ad(r, 0.0025, 0.42, 2.4)
    grain(y, ns(0.36), ring * 0.85)
    y += click(n, 12000, 0.0012) * 0.0
    return reverb(y, rt60=0.7, wet=0.18, size=0.7, damp_fc=9000)


# ============================================================================
# DAMAGE / LIFE
# ============================================================================

def player_hurt(v):
    dur = [0.30, 0.26, 0.35][v - 1]
    n = ns(dur + 0.10)
    m = ns(dur)
    f0 = [128.0, 142.0, 118.0][v - 1]
    u = np.linspace(0, 1, m)
    curve = f0 * (1.0 + 0.16 * np.sin(np.pi * u ** 0.6)) * (1.0 - 0.22 * u ** 2)
    fm = [F_RAMA,
          [(620, 95, 1.0), (1160, 140, 0.6), (2500, 200, 0.25)],
          [(480, 85, 1.0), (980, 125, 0.55), (2350, 190, 0.22)]][v - 1]
    src = voice(m, curve, fm, jitter=0.020, noise_mix=0.10, sub=0.10,
                tilt_db=-3.0, hp=165.0,
                floor=0.07, rasp=0.26, rasp_band=(1600.0, 7000.0))
    src *= env_ad(m, 0.008, dur * 0.55, 2.6)
    y = np.zeros(n)
    grain(y, 0, src / max(float(np.max(np.abs(src))), 1e-9))
    # breath transient
    y += nband(n, 900, 5000) * env_ad(n, 0.003, 0.045, 3.0) * 0.16
    return reverb(y, rt60=0.35, wet=0.12, size=0.6)


def player_death():
    dur = 2.6
    n = ns(dur)
    m = ns(1.35)
    u = np.linspace(0, 1, m)
    curve = 168.0 * (58.0 / 168.0) ** (u ** 0.75)
    src = voice(m, curve, F_RAMA, jitter=0.025, noise_mix=0.14, sub=0.28,
                rough=0.10, rough_hz=22.0, tilt_db=-3.0, hp=130.0,
                floor=0.09, rasp=0.34, rasp_band=(1200.0, 6000.0))
    src *= env_ad(m, 0.020, 0.95, 2.0)
    y = np.zeros(n)
    grain(y, 0, src / max(float(np.max(np.abs(src))), 1e-9) * 0.9)
    # low falling tone underneath
    s, _ = sweep(m, 190, 72)
    grain(y, 0, s * env_ad(m, 0.05, 0.9, 2.2) * 0.16)
    y += nband(n, 300, 2200) * env_ad(n, 0.02, 0.35, 2.5) * 0.07
    # a dark tail: a bright reverb here makes the falling tone read as rising
    return reverb(y, rt60=2.2, wet=0.38, size=1.25, damp_fc=1600, predelay=0.03)


def heal():
    dur = 1.7
    n = ns(dur)
    y = np.zeros(n)
    root = 392.0  # G
    steps = [1.0, 1.125, 1.3348, 1.5, 1.7818, 2.0]
    for i, r in enumerate(steps):
        f = root * r
        start = 0.055 * i
        m = n - ns(start)
        parts = [(f, 1.0, 0.55 - 0.05 * i), (f * 2.0, 0.42, 0.34), (f * 2.76, 0.20, 0.22),
                 (f * 4.07, 0.10, 0.14), (f * 5.43, 0.05, 0.09)]
        b = modal(m, parts) * env_ad(m, 0.030, 0.60, 2.2)
        grain(y, ns(start), b * (0.85 - 0.08 * i))
    # shimmer dust
    for _ in range(28):
        gl = ns(uni(0.03, 0.10))
        f = uni(2400, 8000)
        g = np.sin(2 * np.pi * f * tarr(gl)) * env_ad(gl, 0.006, 0.045, 2.5)
        grain(y, ns(uni(0.0, 1.25)), g * uni(0.02, 0.07))
    y += fft_shape(white(n) * env_bump(n, 0.5, 2.0), bp_mag(5000, 13000, 2)) * 0.05
    return reverb(y, rt60=1.5, wet=0.30, size=1.0, damp_fc=9000)


def enemy_alert(v):
    dur = [1.05, 0.88][v - 1]
    n = ns(dur + 0.25)
    m = ns(dur)
    u = np.linspace(0, 1, m)
    f0 = [58.0, 66.0][v - 1]
    curve = f0 * (1.0 + 1.25 * u ** 1.5) * (1.0 - 0.10 * np.clip((u - 0.85) / 0.15, 0, 1))
    src = voice(m, curve, F_RAKSH, jitter=0.035, rough=0.45 + 0.1 * v,
                rough_hz=[31.0, 38.0][v - 1], noise_mix=0.22, sub=0.55, chaos=0.20,
                tilt_db=-3.0, hp=140.0,
                floor=0.08, rasp=0.34, rasp_band=(1300.0, 6500.0))
    src *= (0.25 + 0.75 * u ** 1.3) * env_ad(m, 0.06, dur * 0.85, 1.6)
    y = np.zeros(n)
    grain(y, 0, src / max(float(np.max(np.abs(src))), 1e-9))
    y += nband(n, 700, 4200) * np.concatenate([(0.1 + 0.9 * u), np.zeros(n - m)]) * 0.10
    return reverb(y, rt60=0.8, wet=0.18, size=0.9, damp_fc=3800)


def enemy_growl(v):
    dur = [0.72, 0.55, 0.95][v - 1]
    n = ns(dur + 0.2)
    m = ns(dur)
    u = np.linspace(0, 1, m)
    f0 = [64.0, 78.0, 55.0][v - 1]
    shapes = [1.0 + 0.25 * np.sin(np.pi * u), 1.0 - 0.20 * u, 1.0 + 0.10 * np.sin(2 * np.pi * u)]
    curve = f0 * shapes[v - 1]
    src = voice(m, curve, F_RAKSH, jitter=0.030, rough=0.40, rough_hz=[26, 34, 21][v - 1],
                noise_mix=0.16, sub=0.60, chaos=0.25, tilt_db=-3.0, hp=145.0,
                floor=0.10, rasp=0.44, rasp_band=(1100.0, 6500.0))
    src *= env_ad(m, 0.055, dur * 0.75, 1.8)
    y = np.zeros(n)
    grain(y, 0, src / max(float(np.max(np.abs(src))), 1e-9))
    return reverb(y, rt60=0.6, wet=0.15, size=0.85, damp_fc=3600)


def enemy_attack(v):
    dur = [0.42, 0.36][v - 1]
    n = ns(dur + 0.25)
    m = ns(dur)
    u = np.linspace(0, 1, m)
    f0 = [92.0, 108.0][v - 1]
    curve = f0 * (1.0 + 0.55 * np.sin(np.pi * u ** 0.5)) * (1.0 - 0.30 * u ** 2)
    src = voice(m, curve, F_RAKSH_OPEN, jitter=0.030, rough=0.30,
                rough_hz=[44, 52][v - 1], noise_mix=0.20, sub=0.35, chaos=0.15,
                tilt_db=-2.5, hp=185.0,
                floor=0.08, rasp=0.34, rasp_band=(1400.0, 7000.0))
    src *= env_ad(m, 0.006, dur * 0.60, 2.4)
    y = np.zeros(n)
    grain(y, 0, src / max(float(np.max(np.abs(src))), 1e-9))
    y += nband(n, 800, 5500) * env_ad(n, 0.003, 0.05, 3.0) * 0.12
    return reverb(y, rt60=0.55, wet=0.16, size=0.8, damp_fc=4500)


def enemy_hurt(v):
    dur = [0.26, 0.22, 0.30][v - 1]
    n = ns(dur + 0.15)
    m = ns(dur)
    u = np.linspace(0, 1, m)
    f0 = [86.0, 100.0, 74.0][v - 1]
    curve = f0 * (1.0 + 0.30 * np.exp(-4 * u)) * (1.0 - 0.28 * u)
    src = voice(m, curve, F_RAKSH_OPEN, jitter=0.040, rough=0.35, rough_hz=48.0,
                noise_mix=0.26, sub=0.40, chaos=0.30, tilt_db=-2.5, hp=185.0,
                floor=0.08, rasp=0.36, rasp_band=(1400.0, 7500.0))
    src *= env_ad(m, 0.004, dur * 0.5, 2.8)
    y = np.zeros(n)
    grain(y, 0, src / max(float(np.max(np.abs(src))), 1e-9))
    y += nband(n, 1000, 6000) * env_ad(n, 0.002, 0.035, 3.2) * 0.14
    return reverb(y, rt60=0.4, wet=0.12, size=0.7)


def enemy_death(v):
    dur = [1.5, 1.25][v - 1]
    n = ns(dur + 0.9)
    m = ns(dur)
    u = np.linspace(0, 1, m)
    f0 = [80.0, 92.0][v - 1]
    curve = f0 * (0.42 / 1.0) ** (u ** 0.9) * (1.0 + 0.06 * np.sin(2 * np.pi * 9 * u))
    curve = f0 * (1.0 - 0.62 * u ** 0.8)
    src = voice(m, curve, F_RAKSH, jitter=0.055, rough=0.55, rough_hz=18.0,
                noise_mix=0.30, sub=0.70, chaos=0.45, tilt_db=-3.0, hp=125.0,
                floor=0.06, rasp=0.20, rasp_band=(1300.0, 6500.0))
    # gurgle: irregular amplitude chopping
    gur = 1.0 + 0.55 * smooth_noise(m, 14.0) * u
    src *= np.clip(gur, 0.0, 2.0) * env_ad(m, 0.03, dur * 0.8, 1.7)
    y = np.zeros(n)
    grain(y, 0, src / max(float(np.max(np.abs(src))), 1e-9) * 0.95)
    # body-fall thump at the end
    fall_at = ns(dur * 0.86)
    fl = n - fall_at
    thump = modal(fl, [(52, 1.0, 0.075), (104, 0.55, 0.040), (176, 0.32, 0.022)]) * 0.34
    thump += nband(fl, 180, 1600) * env_ad(fl, 0.0035, 0.055, 2.6) * 0.85
    thump += nlow(fl, 700) * env_ad(fl, 0.0015, 0.055, 3.0) * 0.28
    for _ in range(10):
        gl = ns(uni(0.003, 0.012))
        g = white(gl) * np.hanning(gl)
        grain(thump, ns(uni(0.01, 0.30)), fft_shape(g, bp_mag(1500, 7000, 2)) * uni(0.03, 0.12))
    grain(y, fall_at, thump * 0.75)
    return reverb(y, rt60=1.0, wet=0.20, size=1.0, damp_fc=3800)


def beast_snarl(v):
    dur = [0.85, 0.62][v - 1]
    n = ns(dur + 0.25)
    m = ns(dur)
    u = np.linspace(0, 1, m)
    f0 = [188.0, 232.0][v - 1]
    curve = f0 * (1.0 + 0.35 * np.sin(np.pi * u ** 0.7)) * (1.0 - 0.15 * u)
    src = voice(m, curve, F_BEAST, jitter=0.060, rough=0.65,
                rough_hz=[72, 88][v - 1], noise_mix=0.26, sub=0.25, chaos=0.55,
                tilt_db=-3.5, hp=220.0,
                floor=0.02, rasp=0.0)
    src *= env_ad(m, 0.012, dur * 0.7, 2.0)
    y = np.zeros(n)
    grain(y, 0, src / max(float(np.max(np.abs(src))), 1e-9))
    # breathy rasp on top
    y += nband(n, 900, 4500) * np.concatenate([env_bump(m, 0.6, 1.2), np.zeros(n - m)]) * 0.09
    return reverb(y, rt60=0.5, wet=0.14, size=0.8, damp_fc=6000)


# ============================================================================
# WORLD / UI
# ============================================================================

def fire_crackle():
    """10 s seamless loop — everything built with circular operations."""
    dur = 10.0
    n = ns(dur)
    t = tarr(n)
    T = n / SR

    # --- low roar: circularly-filtered noise, modulated by loop-periodic LFOs
    roar = fft_shape(white(n), mag_mul(bp_mag(45, 420, 2), tilt_mag(-3.0)), circular=True)
    roar /= max(float(np.std(roar)), 1e-9)
    lfo = np.zeros(n)
    for k, a in [(1, 0.30), (2, 0.18), (3, 0.12), (5, 0.09), (7, 0.06), (11, 0.04)]:
        lfo += a * np.sin(2 * np.pi * (k / T) * t + uni(0, 6.283))
    roar *= 0.55 + 0.45 * np.clip(1.0 + lfo, 0.1, 2.0)

    # --- mid hiss / flame body
    hiss = fft_shape(white(n), bp_mag(500, 4200, 2), circular=True)
    hiss /= max(float(np.std(hiss)), 1e-9)
    lfo2 = np.zeros(n)
    for k, a in [(2, 0.35), (3, 0.25), (5, 0.18), (8, 0.12), (13, 0.08)]:
        lfo2 += a * np.sin(2 * np.pi * (k / T) * t + uni(0, 6.283))
    hiss *= 0.45 + 0.55 * np.clip(1.0 + lfo2, 0.05, 2.0)

    y = roar * 0.34 + hiss * 0.34

    # --- dense random pops, placed circularly
    n_pops = 300
    for _ in range(n_pops):
        gl = ns(uni(0.006, 0.035))
        f = uni(700, 4200)
        g = modal(gl, [(f, 1.0, uni(0.0015, 0.006)),
                       (f * uni(1.7, 2.4), 0.45, 0.0025),
                       (f * uni(3.0, 4.5), 0.20, 0.0015)])
        g += fft_shape(white(gl) * env_ad(gl, 0.0003, 0.0025, 4.0),
                       bp_mag(1500, 11000, 2)) * 0.6
        g *= env_ad(gl, 0.0004, uni(0.004, 0.014), 3.0)
        grain(y, int(uni(0, n)), g * uni(0.12, 0.85), wrap=True)

    # --- micro ticks (embers)
    for _ in range(1600):
        gl = ns(uni(0.0008, 0.004))
        g = white(gl) * np.hanning(gl)
        g = fft_shape(g, bp_mag(uni(2500, 5000), uni(9000, 14000), 2))
        grain(y, int(uni(0, n)), g * uni(0.02, 0.16), wrap=True)

    # --- occasional bigger crackle bursts
    for _ in range(14):
        bl = ns(uni(0.10, 0.30))
        b = np.zeros(bl)
        for _ in range(int(uni(6, 16))):
            gl = ns(uni(0.004, 0.018))
            f = uni(500, 2600)
            g = modal(gl, [(f, 1.0, uni(0.002, 0.007)), (f * 2.1, 0.4, 0.002)])
            g *= env_ad(gl, 0.0004, uni(0.005, 0.014), 3.0)
            grain(b, int(uni(0, bl)), g * uni(0.3, 1.0))
        b *= env_bump(bl, 0.8, 0.9)
        grain(y, int(uni(0, n)), b * uni(0.35, 0.9), wrap=True)

    # gentle circular low shelf so it sits under music
    y = fft_shape(y, mag_mul(hp_mag(75, 2), lp_mag(15000, 2)), circular=True)
    return tame(y, 2.0)


def water_lap():
    """6 s seamless loop of gentle shore lapping."""
    dur = 6.0
    n = ns(dur)
    t = tarr(n)
    T = n / SR

    bed = fft_shape(white(n), bp_mag(60, 900, 2), circular=True)
    bed /= max(float(np.std(bed)), 1e-9)
    lfo = np.zeros(n)
    for k, a in [(1, 0.35), (2, 0.22), (3, 0.14), (5, 0.09)]:
        lfo += a * np.sin(2 * np.pi * (k / T) * t + uni(0, 6.283))
    bed *= 0.5 + 0.5 * np.clip(1.0 + lfo, 0.05, 2.0)

    hiss = fft_shape(white(n), bp_mag(2000, 9000, 2), circular=True)
    hiss /= max(float(np.std(hiss)), 1e-9)
    y = bed * 0.32 + hiss * 0.05

    # lapping swells, circularly placed
    for _ in range(11):
        ll = ns(uni(0.55, 1.30))
        u = np.linspace(0, 1, ll)
        fc = np.geomspace(uni(1600, 2600), uni(320, 520), ll)
        lap = svf(white(ll) * (np.sin(np.pi * u ** 0.65) ** 1.6), fc, q=1.5, mode="bp")
        lap /= max(float(np.max(np.abs(lap))), 1e-9)
        # fizz on the crest
        lap += fft_shape(white(ll) * (np.sin(np.pi * u ** 1.5) ** 2.2),
                         bp_mag(2500, 10000, 2)) * 0.30
        lap += fft_shape(white(ll) * (np.sin(np.pi * u ** 0.5) ** 1.4),
                         lp_mag(300, 3)) * 0.45
        lap *= np.hanning(ll) ** 0.35  # guarantee the grain is zero at its ends
        grain(y, int(uni(0, n)), lap * uni(0.35, 0.95), wrap=True)

    # a few little droplets / plips
    for _ in range(18):
        gl = ns(uni(0.02, 0.06))
        f0 = uni(700, 2100)
        s, _f = sweep(gl, f0, f0 * uni(1.3, 1.9))
        g = s * env_ad(gl, 0.0008, uni(0.012, 0.030), 3.0)
        grain(y, int(uni(0, n)), g * uni(0.03, 0.12), wrap=True)

    y = fft_shape(y, mag_mul(hp_mag(40, 2), lp_mag(14000, 2)), circular=True)
    return y


def bird(v):
    if v == 1:  # two-note whistle
        n = ns(0.62)
        y = np.zeros(n)
        for i, (start, d, fa, fb, amp) in enumerate(
                [(0.02, 0.15, 2350, 2500, 1.0), (0.24, 0.20, 3050, 2900, 0.85)]):
            m = ns(d)
            u = np.linspace(0, 1, m)
            f = fa * (fb / fa) ** np.sqrt(u)
            f = f * (1.0 + 0.010 * np.sin(2 * np.pi * 16 * u))
            ph = 2 * np.pi * np.cumsum(f) / SR
            e = np.sin(np.pi * np.clip(u, 0, 1) ** 0.55) ** 2.0
            g = (np.sin(ph) + 0.22 * np.sin(2 * ph) + 0.06 * np.sin(3 * ph)) * e
            grain(y, ns(start), g * amp)
        y += fft_shape(white(n) * env_ad(n, 0.01, 0.25, 2.0), bp_mag(3000, 9000, 2)) * 0.02
        return y
    if v == 2:  # trill
        n = ns(0.70)
        y = np.zeros(n)
        pos = 0.02
        i = 0
        while pos < 0.60:
            m = ns(0.030)
            u = np.linspace(0, 1, m)
            f0 = 2900 + 260 * math.sin(i * 0.9) + uni(-70, 70)
            f = f0 * (1.0 + 0.13 * u)
            ph = 2 * np.pi * np.cumsum(f) / SR
            e = np.sin(np.pi * u) ** 1.3
            g = (np.sin(ph) + 0.3 * np.sin(2 * ph)) * e
            grain(y, ns(pos), g * (0.55 + 0.45 * math.sin(i * 0.5)))
            pos += 0.038
            i += 1
        y *= env_bump(n, 0.85, 0.5) * 0.6 + 0.4
        return y
    if v == 3:  # descending call
        n = ns(0.55)
        y = np.zeros(n)
        for start, amp in [(0.01, 1.0), (0.30, 0.6)]:
            m = ns(0.22)
            u = np.linspace(0, 1, m)
            f = 3600 * (1250 / 3600) ** (u ** 0.7)
            f *= 1.0 + 0.008 * np.sin(2 * np.pi * 22 * u)
            ph = 2 * np.pi * np.cumsum(f) / SR
            e = np.sin(np.pi * np.clip(u * 1.05, 0, 1) ** 0.45) ** 2.0
            g = (np.sin(ph) + 0.28 * np.sin(2 * ph) + 0.08 * np.sin(3 * ph)) * e
            grain(y, ns(start), g * amp)
        return y
    # v == 4 : harsh caw
    n = ns(0.56)
    y = np.zeros(n)
    for start, d, f0, amp in [(0.01, 0.25, 690, 1.0), (0.27, 0.24, 640, 0.92)]:
        m = ns(d)
        u = np.linspace(0, 1, m)
        curve = f0 * (1.0 + 0.28 * np.sin(np.pi * u ** 0.6)) * (1.0 - 0.20 * u)
        g = voice(m, curve, [(1150, 200, 1.0), (2300, 320, 0.75), (3800, 460, 0.4),
                             (620, 150, 0.5)],
                  jitter=0.045, rough=0.55, rough_hz=95.0, noise_mix=0.30,
                  chaos=0.4, tilt_db=-3.0, hp=420.0)
        g *= env_ad(m, 0.005, d * 0.85, 1.7)
        g /= max(float(np.max(np.abs(g))), 1e-9)
        grain(y, ns(start), g * amp)
    return y


def insect_chirp(v):
    if v == 1:  # cricket: pulse group
        n = ns(0.30)
        y = np.zeros(n)
        for k in range(4):
            m = ns(0.016)
            u = np.linspace(0, 1, m)
            f = 4550 + 60 * k
            ph = 2 * np.pi * f * tarr(m)
            e = np.sin(np.pi * u) ** 1.4
            g = (np.sin(ph) + 0.35 * np.sin(2 * ph) + 0.12 * np.sin(3 * ph)) * e
            g *= 1.0 + 0.5 * np.sin(2 * np.pi * 620 * tarr(m))
            grain(y, ns(0.02 + 0.055 * k), g * (1.0 - 0.12 * k))
        return y
    # cicada-ish buzz burst
    n = ns(0.42)
    m = ns(0.34)
    u = np.linspace(0, 1, m)
    car = np.sin(2 * np.pi * 5200 * tarr(m))
    am = 0.5 + 0.5 * np.sin(2 * np.pi * 145 * tarr(m))
    g = car * am * (np.sin(np.pi * np.clip(u * 1.05, 0, 1) ** 0.6) ** 1.2)
    g += fft_shape(white(m), bp_mag(4200, 9000, 2)) * am * 0.25 * np.sin(np.pi * u) ** 1.2
    y = np.zeros(n)
    grain(y, ns(0.01), g)
    return y


def bell_temple():
    """Struck bronze temple bell — inharmonic partials, ~6 s decay."""
    dur = 6.4
    n = ns(dur)
    f = 268.0

    def stack(spec):
        parts = []
        for r, a, d in spec:
            fr = f * r
            beat = uni(0.25, 1.1) * (1.0 + r * 0.12)
            parts.append((fr, a, d))
            parts.append((fr + beat, a * 0.62, d * 0.92))
            parts.append((fr - beat * 0.7, a * 0.38, d * 0.85))
        y = modal(n, parts)
        return y / max(float(np.max(np.abs(y))), 1e-9)

    # hum, prime, tierce, quint, nominal — the long singing body
    body = stack([(0.500, 0.62, 6.0), (1.000, 1.00, 4.8), (1.183, 0.78, 3.6),
                  (1.506, 0.62, 2.8), (2.000, 0.86, 2.3), (2.514, 0.44, 1.6),
                  (2.662, 0.36, 1.4), (3.011, 0.32, 1.2)])
    # bright inharmonic cluster: short-lived, and the reason a bell sounds like
    # bronze instead of like an organ
    clang = stack([(4.166, 0.95, 0.60), (5.433, 0.90, 0.46), (6.796, 0.85, 0.36),
                   (8.210, 0.75, 0.28), (10.09, 0.65, 0.21), (12.44, 0.55, 0.16),
                   (15.10, 0.45, 0.12), (18.32, 0.34, 0.09), (22.11, 0.22, 0.07)])

    # metal contact transient
    strike = nband(n, 2000, 15000) * env_ad(n, 0.0004, 0.016, 4.0) * 1.0
    strike += modal(n, [(3900, 0.9, 0.075), (6100, 0.7, 0.048),
                        (9200, 0.45, 0.026), (13100, 0.22, 0.014)])
    strike /= max(float(np.max(np.abs(strike))), 1e-9)

    y = body * 1.0 + clang * 0.92 + strike * 0.80

    # slow amplitude warble in the first moments (the bell "wobble")
    t = tarr(n)
    y *= 1.0 + 0.10 * np.sin(2 * np.pi * 3.1 * t) * np.exp(-t / 0.9)
    y *= env_ad(n, 0.0012, 5.8, 1.0)
    return reverb(y, rt60=2.4, wet=0.26, size=1.3, damp_fc=8000, predelay=0.02)


def pickup_item():
    n = ns(0.45)
    y = np.zeros(n)
    for i, (r, start, amp) in enumerate([(1.0, 0.0, 1.0), (1.5, 0.055, 0.8)]):
        f = 1046.5 * r
        m = n - ns(start)
        parts = [(f, 1.0, 0.16), (f * 2.0, 0.4, 0.10), (f * 2.77, 0.18, 0.07),
                 (f * 4.1, 0.08, 0.045)]
        g = modal(m, parts) * env_ad(m, 0.003, 0.20, 2.4)
        grain(y, ns(start), g * amp)
    y += click(n, 9000, 0.0010) * 0.10
    return reverb(y, rt60=0.7, wet=0.20, size=0.8, damp_fc=9000)


def ui_click():
    n = ns(0.075)
    y = modal(n, [(1180, 1.0, 0.010), (2360, 0.30, 0.006), (620, 0.35, 0.014)])
    y += fft_shape(white(n) * env_ad(n, 0.0006, 0.005, 4.0), bp_mag(900, 6000, 2)) * 0.35
    y *= env_ad(n, 0.0010, 0.028, 2.6)
    return y


def ui_hover():
    n = ns(0.060)
    y = modal(n, [(1760, 1.0, 0.008), (3520, 0.20, 0.004)])
    y += fft_shape(white(n) * env_ad(n, 0.0008, 0.004, 4.0), bp_mag(2000, 8000, 2)) * 0.20
    y *= env_ad(n, 0.0016, 0.022, 2.8)
    return y * 0.55


def ui_open():
    n = ns(0.32)
    m = ns(0.22)
    u = np.linspace(0, 1, m)
    sw = svf(white(m) * (np.sin(np.pi * u ** 1.3) ** 1.3),
             np.geomspace(700, 4200, m), q=2.4, mode="bp")
    sw /= max(float(np.max(np.abs(sw))), 1e-9)
    y = np.zeros(n)
    grain(y, 0, sw * 0.45)
    # two notes rising, the second late enough that the gesture actually goes up
    for fq, start, amp in [(523.25, 0.005, 0.75), (784.0, 0.085, 1.0)]:
        k = n - ns(start)
        tone = modal(k, [(fq, 1.0, 0.11), (fq * 2, 0.42, 0.07), (fq * 3, 0.18, 0.05)])
        grain(y, ns(start), tone * env_ad(k, 0.006, 0.14, 2.4) * amp)
    return reverb(y, rt60=0.4, wet=0.16, size=0.7, damp_fc=9000)


def ui_close():
    n = ns(0.30)
    m = ns(0.20)
    u = np.linspace(0, 1, m)
    sw = svf(white(m) * (np.sin(np.pi * u ** 1.3) ** 1.3),
             np.geomspace(4200, 700, m), q=2.4, mode="bp")
    sw /= max(float(np.max(np.abs(sw))), 1e-9)
    y = np.zeros(n)
    grain(y, 0, sw * 0.45)
    # mirror of ui_open: two notes falling
    for fq, start, amp in [(587.33, 0.005, 0.75), (392.0, 0.080, 1.0)]:
        k = n - ns(start)
        tone = modal(k, [(fq, 1.0, 0.11), (fq * 2, 0.38, 0.07), (fq * 3, 0.15, 0.05)])
        grain(y, ns(start), tone * env_ad(k, 0.006, 0.13, 2.6) * amp)
    return reverb(y, rt60=0.35, wet=0.14, size=0.65, damp_fc=4000)


def quest_accept():
    n = ns(1.25)
    y = np.zeros(n)
    for f, start, amp, dec in [(293.66, 0.0, 1.0, 0.55), (440.0, 0.17, 0.95, 0.70)]:
        m = n - ns(start)
        # The partial series used to stop being audible at the 3rd harmonic
        # (0.06 amp on the 5th, decaying 4x faster than the fundamental), which
        # left 95% of the sound below 880 Hz — a dull thump where the other
        # reward cue, objective_complete, sits an octave and a half higher.
        # Real struck bronze keeps a bright, slightly inharmonic upper series.
        parts = [(f, 1.0, dec), (f * 2, 0.5, dec * 0.7), (f * 3, 0.34, dec * 0.60),
                 (f * 4.02, 0.30, dec * 0.58), (f * 5.05, 0.30, dec * 0.55),
                 (f * 6.9, 0.22, dec * 0.45), (f * 9.2, 0.15, dec * 0.35),
                 (f * 1.002, 0.4, dec * 0.9)]
        g = modal(m, parts) * env_ad(m, 0.012, dec * 1.1, 2.0)
        grain(y, ns(start), g * amp)
    # Soft brass shimmer. This was raw white() through bp_mag, so the written
    # 0.035 was really ~0.019 after the band-limiting loss and it never spoke.
    y += nband(n, 3000, 9000) * env_ad(n, 0.03, 0.35, 2.4) * 0.075
    return reverb(y, rt60=1.3, wet=0.28, size=1.0, damp_fc=7000)


def objective_complete():
    n = ns(1.0)
    y = np.zeros(n)
    for i, (f, start) in enumerate([(659.25, 0.0), (880.0, 0.075), (1174.66, 0.15)]):
        m = n - ns(start)
        parts = [(f, 1.0, 0.28), (f * 2.0, 0.42, 0.18), (f * 2.76, 0.18, 0.12),
                 (f * 4.07, 0.09, 0.08), (f * 1.003, 0.35, 0.26)]
        g = modal(m, parts) * env_ad(m, 0.004, 0.34, 2.2)
        grain(y, ns(start), g * (1.0 - 0.12 * i))
    return reverb(y, rt60=1.0, wet=0.24, size=0.9, damp_fc=9000)


def shrine_activate():
    dur = 3.4
    n = ns(dur)
    t = tarr(n)
    y = np.zeros(n)
    # tanpura-ish drone: Sa - Pa - Sa, plucked strings, swelling
    for f, start, amp in [(146.83, 0.02, 1.0), (220.0, 0.30, 0.85),
                          (293.66, 0.58, 0.75), (146.83, 0.90, 0.6)]:
        k = karplus(f, min(2.6, dur - start), damp=0.9992, lp=0.52,
                    exc_lo=120, exc_hi=5000)
        k *= env_ad(len(k), 0.004, 2.2, 1.6)
        grain(y, ns(start), k * amp * 0.55)
    # swelling harmonic drone
    swell = np.sin(np.pi * np.clip(t / dur, 0, 1) ** 0.7) ** 1.3
    for h, a in [(1, 1.0), (2, 0.5), (3, 0.32), (4, 0.18), (5, 0.11), (6, 0.07), (8, 0.04)]:
        f = 146.83 * h
        det = 1.0 + 0.0016 * math.sin(h * 1.7)
        y += np.sin(2 * np.pi * f * det * t + uni(0, 6.28)) * a * swell * 0.14
    # struck bell over the top
    bl = n - ns(0.25)
    bparts = []
    for r, a, d in [(0.5, 0.45, 2.4), (1.0, 1.0, 2.0), (1.183, 0.6, 1.5),
                    (1.506, 0.5, 1.2), (2.0, 0.7, 1.0), (2.514, 0.3, 0.7),
                    (3.011, 0.22, 0.5), (4.166, 0.14, 0.34)]:
        f = 587.33 * r
        bparts.append((f, a, d))
        bparts.append((f + uni(0.3, 0.9), a * 0.55, d * 0.9))
    bell = modal(bl, bparts) * env_ad(bl, 0.0015, 2.2, 1.3)
    bell /= max(float(np.max(np.abs(bell))), 1e-9)
    grain(y, ns(0.25), bell * 0.55)
    # airy shimmer rising
    y += fft_shape(white(n) * swell, bp_mag(4000, 11000, 2)) * 0.05
    return reverb(y, rt60=2.6, wet=0.34, size=1.35, damp_fc=6000, predelay=0.025)


def torch_light():
    dur = 1.7
    n = ns(dur)
    y = np.zeros(n)
    # ignition whoosh
    m = ns(0.34)
    u = np.linspace(0, 1, m)
    fc = np.where(u < 0.35,
                  300.0 * (2600.0 / 300.0) ** np.clip(u / 0.35, 0, 1),
                  2600.0 * (500.0 / 2600.0) ** np.clip((u - 0.35) / 0.65, 0, 1))
    wh = svf(white(m) * (np.sin(np.pi * u ** 0.55) ** 1.3), fc, q=1.7, mode="bp")
    wh /= max(float(np.max(np.abs(wh))), 1e-9)
    grain(y, 0, wh * 0.95)
    y[:m] += fft_shape(white(m) * (np.sin(np.pi * u ** 0.5) ** 1.5), lp_mag(260, 3)) * 0.45
    # settle into crackle
    tail_env = np.concatenate([np.zeros(ns(0.14)),
                               np.linspace(0, 1, ns(0.16)),
                               np.ones(n - ns(0.30))])
    tail_env = tail_env[:n] * np.exp(-np.maximum(tarr(n) - 0.6, 0) / 1.1)
    roar = fft_shape(white(n), bp_mag(60, 900, 2))
    roar /= max(float(np.std(roar)), 1e-9)
    y += roar * tail_env * 0.28
    hiss = fft_shape(white(n), bp_mag(900, 6000, 2))
    hiss /= max(float(np.std(hiss)), 1e-9)
    y += hiss * tail_env * 0.12
    for _ in range(70):
        pos = uni(0.18, dur - 0.06)
        gl = ns(uni(0.004, 0.020))
        f = uni(800, 3800)
        g = modal(gl, [(f, 1.0, uni(0.002, 0.006)), (f * 2.1, 0.4, 0.002)])
        g += fft_shape(white(gl) * env_ad(gl, 0.0003, 0.002, 4.0), bp_mag(2000, 10000, 2)) * 0.5
        g *= env_ad(gl, 0.0004, uni(0.004, 0.012), 3.0)
        amp = uni(0.10, 0.45) * math.exp(-max(pos - 0.5, 0) / 1.0)
        grain(y, ns(pos), g * amp)
    return tame(y, 1.9)


# ============================================================================
# output
# ============================================================================

def fade(x, fin, fout):
    n = len(x)
    a = min(max(1, int(fin * SR)), n // 2)
    b = min(max(1, int(fout * SR)), n // 2)
    w = np.ones(n)
    w[:a] = np.sin(np.linspace(0.0, np.pi / 2.0, a)) ** 2
    w[n - b:] = np.cos(np.linspace(0.0, np.pi / 2.0, b)) ** 2
    return x * w


def seam_align(x):
    """Rotate a circular buffer so the splice lands on a near-zero crossing."""
    ax = np.abs(x)
    s = np.signbit(x)
    cross = np.where((~s[1:]) & s[:-1])[0] + 1
    if len(cross) == 0:
        return x
    score = ax[cross] + ax[cross - 1]
    k = int(cross[int(np.argmin(score))])
    return np.roll(x, -k)


def write_wav(name, x, loop=False):
    path = os.path.join(OUT_DIR, name)
    x = np.nan_to_num(np.asarray(x, dtype=np.float64))
    x = x - float(np.mean(x))
    if loop:
        x = seam_align(x)
    else:
        d = len(x) / SR
        x = fade(x, min(0.0015, d * 0.05), min(0.010, d * 0.15))
    p = float(np.max(np.abs(x)))
    if p < 1e-12:
        raise RuntimeError("silent buffer: " + name)
    x = x * (TARGET_PEAK / p)
    i16 = np.clip(np.round(x * 32767.0), -32767, 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(i16.tobytes())
    if loop:
        add_smpl_loop(path, len(i16))
    return path


def add_smpl_loop(path, nframes):
    """Append a RIFF `smpl` chunk marking the whole file as a forward loop.

    Without this the seamless-loop work is dead weight. `edit/loop_mode=0` in a
    Godot .import is "Detect From WAV", not "Disabled" — with no loop metadata
    in the file there is nothing to detect, so the importer produced
    AudioStreamWAV.loop_mode == 0 (LOOP_DISABLED) and the bed played once and
    stopped. Verified against Godot 4.7.2 on 2026-08-28 by loading the imported
    resource and reading loop_mode back (0 before this chunk, 1 after).

    Godot's WAV importer (resource_importer_wav.cpp) skips 10 uint32 of the
    chunk and then reads loop type / start / end, so the layout below is the
    one it expects: 9 header fields, then the first loop's identifier, type,
    start, end, fraction, play-count.
    """
    body = struct.pack(
        "<9I",
        0,                              # manufacturer
        0,                              # product
        int(round(1e9 / SR)),           # sample period, ns
        60,                             # MIDI unity note
        0,                              # MIDI pitch fraction
        0,                              # SMPTE format
        0,                              # SMPTE offset
        1,                              # number of sample loops
        0,                              # sampler-specific data bytes
    ) + struct.pack(
        "<6I",
        0,                              # loop identifier
        0,                              # type 0 = forward  (Godot: loop_mode = type + 1)
        0,                              # start frame
        max(nframes - 1, 0),            # end frame (inclusive)
        0,                              # fraction
        0,                              # play count, 0 = infinite
    )
    chunk = b"smpl" + struct.pack("<I", len(body)) + body
    with open(path, "r+b") as f:
        data = f.read()
        assert data[:4] == b"RIFF" and data[8:12] == b"WAVE", path
        f.seek(0, os.SEEK_END)
        f.write(chunk)
        f.seek(4)
        f.write(struct.pack("<I", len(data) + len(chunk) - 8))
    sync_import_loop(path)
    return path


def sync_import_loop(path):
    """Force the Godot .import sidecar to Forward looping, if one exists.

    The smpl chunk is enough for a clean import, but a sidecar checked in from
    an earlier render pins the old answer and wins. Measured against Godot
    4.7.2 on 2026-08-28 by editing the sidecar and reading the imported stream
    back:

      edit/loop_mode  AudioStreamWAV.loop_mode  loop_end
      0 Detect From WAV   1 FORWARD             440999   <- reads our smpl chunk
      1 Disabled          0 DISABLED                 0
      2 Forward           1 FORWARD             440999
      3 Ping-Pong         2 PINGPONG            440999

    So the sidecar value is NOT the AudioStreamWAV enum: it is offset by one,
    and 0 means "detect", not "off". A stale sidecar holding 1 was why the
    seamless beds still imported with looping disabled.
    """
    imp = path + ".import"
    if not os.path.exists(imp):
        return
    with open(imp, "r", encoding="utf-8") as f:
        text = f.read()
    if "edit/loop_mode=" not in text:
        return
    new = re.sub(r"^edit/loop_mode=.*$", "edit/loop_mode=2", text, flags=re.M)
    if new != text:
        with open(imp, "w", encoding="utf-8") as f:
            f.write(new)


JOBS = []


def job(name, fn, loop=False):
    JOBS.append((name, fn, loop))


for i in range(1, 5):
    job(f"footstep_grass_{i}", (lambda k: (lambda: footstep_grass(k)))(i))
    job(f"footstep_dirt_{i}", (lambda k: (lambda: footstep_dirt(k)))(i))
    job(f"footstep_stone_{i}", (lambda k: (lambda: footstep_stone(k)))(i))
    job(f"footstep_water_{i}", (lambda k: (lambda: footstep_water(k)))(i))
job("land_soft", land_soft)
job("land_hard", land_hard)
job("jump", jump)

job("bow_draw", bow_draw)
job("bow_full", bow_full)
job("bow_release", bow_release)
job("arrow_flight", arrow_flight)
job("arrow_hit_flesh", arrow_hit_flesh)
job("arrow_hit_wood", arrow_hit_wood)
job("arrow_hit_stone", arrow_hit_stone)
job("arrow_pickup", arrow_pickup)

for i in range(1, 4):
    job(f"sword_swing_{i}", (lambda k: (lambda: sword_swing(k)))(i))
job("sword_hit_flesh", sword_hit_flesh)
job("sword_hit_block", sword_hit_block)
job("sword_unsheathe", sword_unsheathe)

for i in range(1, 4):
    job(f"player_hurt_{i}", (lambda k: (lambda: player_hurt(k)))(i))
job("player_death", player_death)
job("heal", heal)
for i in range(1, 3):
    job(f"enemy_alert_{i}", (lambda k: (lambda: enemy_alert(k)))(i))
for i in range(1, 4):
    job(f"enemy_growl_{i}", (lambda k: (lambda: enemy_growl(k)))(i))
for i in range(1, 3):
    job(f"enemy_attack_{i}", (lambda k: (lambda: enemy_attack(k)))(i))
for i in range(1, 4):
    job(f"enemy_hurt_{i}", (lambda k: (lambda: enemy_hurt(k)))(i))
for i in range(1, 3):
    job(f"enemy_death_{i}", (lambda k: (lambda: enemy_death(k)))(i))
for i in range(1, 3):
    job(f"beast_snarl_{i}", (lambda k: (lambda: beast_snarl(k)))(i))

job("fire_crackle", fire_crackle, loop=True)
for i in range(1, 5):
    job(f"bird_{i}", (lambda k: (lambda: bird(k)))(i))
for i in range(1, 3):
    job(f"insect_chirp_{i}", (lambda k: (lambda: insect_chirp(k)))(i))
job("water_lap", water_lap, loop=True)
job("bell_temple", bell_temple)
job("pickup_item", pickup_item)
job("ui_click", ui_click)
job("ui_hover", ui_hover)
job("ui_open", ui_open)
job("ui_close", ui_close)
job("quest_accept", quest_accept)
job("objective_complete", objective_complete)
job("shrine_activate", shrine_activate)
job("torch_light", torch_light)


# ============================================================================
# verification
# ============================================================================

def read_wav(path):
    with wave.open(path, "rb") as w:
        assert w.getnchannels() == 1, "not mono"
        assert w.getsampwidth() == 2, "not 16-bit"
        assert w.getframerate() == SR, "wrong rate"
        raw = w.readframes(w.getnframes())
    return np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0


def loop_metric(x):
    """Seam discontinuity vs. the file's own sample-to-sample step distribution.

    A single-sample comparison is not enough: the splice can also be smooth in
    x[0]-x[-1] while the surrounding milliseconds jump. So this looks at the
    largest step in a small window straddling the wrap point.
    """
    d_all = np.abs(np.diff(x))
    p999 = float(np.percentile(d_all, 99.9))
    w = ns(0.002)
    wrapped = np.concatenate([x[-w:], x[:w]])
    seam = float(np.max(np.abs(np.diff(wrapped))[w - 3:w + 2]))
    head = float(np.sqrt(np.mean(x[:ns(0.05)] ** 2)))
    tail = float(np.sqrt(np.mean(x[-ns(0.05):] ** 2)))
    return seam, p999, (seam / p999 if p999 > 0 else 0.0), head, tail


def hf_share(x, fc=1500.0):
    """Share of energy above `fc`, measured on the most favourable window.

    Whole-file energy is the wrong lens for a percussive hit: arrow_hit_wood is
    38% above 1.5 kHz in its first 10 ms and 0.08% over the whole 400 ms,
    because a long low modal ring integrates away a short bright transient.
    Taking the best of {10 ms, 50 ms, whole} credits a real attack while still
    catching a sound that is dull at every timescale — which is what the voice
    family was before 2026-08-28 (0.03-0.4% in every window, against 20-38% for
    their beast_snarl and enemy_death siblings from this same generator).
    """
    def share(seg):
        if len(seg) < 64:
            return 0.0
        X = np.abs(np.fft.rfft(seg * np.hanning(len(seg)))) ** 2
        f = np.fft.rfftfreq(len(seg), 1.0 / SR)
        tot = float(X.sum())
        return 100.0 * float(X[f >= fc].sum()) / tot if tot > 0 else 0.0
    return max(share(x[:ns(0.010)]), share(x[:ns(0.050)]), share(x))


def bands(x):
    """Energy fraction per octave-ish band — catches sounds that are all
    sub-bass rumble or all hiss, which a peak/RMS check cannot see."""
    X = np.abs(np.fft.rfft(x * np.hanning(len(x)))) ** 2
    f = np.fft.rfftfreq(len(x), 1.0 / SR)
    tot = float(X.sum())
    if tot <= 0:
        return [0.0] * 6
    edges = [0, 150, 500, 1500, 4000, 9000, 22051]
    return [100.0 * float(X[(f >= a) & (f < b)].sum()) / tot
            for a, b in zip(edges[:-1], edges[1:])]


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    rows = []
    failures = []
    for name, fn, loop in JOBS:
        seed(name)
        y = fn()
        path = write_wav(name + ".wav", y, loop=loop)
        rows.append((name + ".wav", path, loop))

    print()
    hdr = (f"{'file':<26}{'dur s':>7}{'kB':>7}{'peak dB':>9}{'RMS':>8}"
           f"{'RMS dB':>8}{'crest':>7}{'pk/p999':>9}{'hf%':>7}"
           f"{'<150':>6}{'.15-.5k':>8}{'.5-1.5k':>8}{'1.5-4k':>8}{'4-9k':>7}{'>9k':>6}"
           f"{'loop':>7}")
    print(hdr)
    print("-" * len(hdr))
    keep = {}
    for fname, path, loop in rows:
        x = read_wav(path)
        keep[fname] = x
        n = len(x)
        dur = n / SR
        peak = float(np.max(np.abs(x)))
        peak_db = 20.0 * math.log10(peak) if peak > 0 else -999.0
        rms = float(np.sqrt(np.mean(x * x)))
        rms_db = 20.0 * math.log10(rms) if rms > 0 else -999.0
        crest = peak_db - rms_db
        p999 = float(np.percentile(np.abs(x), 99.9))
        spike = peak / p999 if p999 > 0 else 99.0
        pk_i = int(np.argmax(np.abs(x)))
        onset_i = int(np.argmax(np.abs(x) >= 0.1 * peak))
        at_attack = (pk_i - onset_i) <= ns(0.025)
        spike_limit = 4.0 if at_attack else 2.6
        dc = float(np.mean(x))
        b = bands(x)
        size = os.path.getsize(path)

        loopcol = "-"
        if loop:
            seam, sp999, ratio, head, tail = loop_metric(x)
            loopcol = f"{ratio:.2f}x"
            if ratio > 1.5:
                failures.append(f"{fname}: loop seam step is {ratio:.2f}x the p99.9 "
                                f"step -> audible click")
            if abs(x[0]) > 0.05 or abs(x[-1]) > 0.05:
                failures.append(f"{fname}: loop endpoints not near zero "
                                f"({x[0]:+.4f} / {x[-1]:+.4f})")
            if head > 0 and tail > 0 and not (0.5 < head / tail < 2.0):
                failures.append(f"{fname}: loop head/tail level mismatch "
                                f"({head:.4f} vs {tail:.4f})")

        if rms <= 0.001:
            failures.append(f"{fname}: silent / near-silent (RMS {rms:.6f})")
        if peak >= 0.9995:
            failures.append(f"{fname}: clipping (peak {peak:.5f})")
        if not (-3.2 <= peak_db <= -2.8):
            failures.append(f"{fname}: peak {peak_db:.2f} dBFS off target -3.0")
        if abs(dc) > 0.01:
            failures.append(f"{fname}: DC offset {dc:+.5f}")
        if int(np.sum(np.abs(x) >= 0.999)) > 0:
            failures.append(f"{fname}: samples at full scale")
        if spike > spike_limit:
            where = "at the attack" if at_attack else f"{pk_i/SR*1000:.0f} ms in"
            failures.append(f"{fname}: peak is {spike:.2f}x the 99.9th pct ({where}) "
                            f"— limit {spike_limit} — it is eating the headroom")
        if crest > 26.5:
            failures.append(f"{fname}: crest factor {crest:.1f} dB — all transient "
                            f"and no body, it will sit far too quiet in the mix")
        if b[0] > 70.0:
            failures.append(f"{fname}: {b[0]:.0f}% of energy below 150 Hz — reads "
                            f"as rumble, not as a sound")
        if sum(b[1:5]) < 15.0:
            failures.append(f"{fname}: only {sum(b[1:5]):.0f}% in 150 Hz-9 kHz — "
                            f"no audible body")
        hfs = hf_share(x)
        if hfs < 3.0:
            failures.append(f"{fname}: only {hfs:.2f}% of energy above 1.5 kHz in its "
                            f"brightest window — no formants / no attack edge, it will "
                            f"read as a muffled hum")

        print(f"{fname:<26}{dur:>7.2f}{size/1024.0:>7.0f}{peak_db:>9.2f}"
              f"{rms:>8.4f}{rms_db:>8.2f}{crest:>7.1f}{spike:>9.2f}"
              f"{hfs:>7.1f}"
              f"{b[0]:>6.1f}{b[1]:>8.1f}{b[2]:>8.1f}{b[3]:>8.1f}{b[4]:>7.1f}{b[5]:>6.1f}"
              f"{loopcol:>7}")

    # variants must not be near-copies of each other, or the walk cycle and the
    # combat barks turn into an obvious loop; they must also not drift apart in
    # level, or one footstep in four jumps out of the walk cycle
    print()
    fams = {}
    for fname in keep:
        stem = fname[:-4]
        head, _, tailnum = stem.rpartition("_")
        if tailnum.isdigit():
            fams.setdefault(head, []).append(fname)
    print(f"{'family':<22}{'n':>3}{'max |corr| between variants':>32}")
    for base in sorted(fams):
        members = sorted(fams[base])
        worst = 0.0
        for i in range(len(members)):
            for j in range(i + 1, len(members)):
                a, bb = keep[members[i]], keep[members[j]]
                m = min(len(a), len(bb))
                c = abs(float(np.corrcoef(a[:m], bb[:m])[0, 1]))
                worst = max(worst, c)
        levels = [20.0 * math.log10(max(float(np.sqrt(np.mean(keep[mm] ** 2))), 1e-9))
                  for mm in members]
        spread = max(levels) - min(levels)
        # bird_* is specified as four different species and insect_chirp_* as two;
        # they are picked as distinct calls, not as interchangeable takes of one
        # event, so they only have to stay in the same ballpark.
        distinct = base in ("bird", "insect_chirp")
        limit = 12.0 if distinct else 4.0
        if spread > limit:
            failures.append(f"{base}_*: {spread:.1f} dB RMS spread across variants "
                            f"(limit {limit:.0f}) — one of them will jump out")
        flag = f"  spread {spread:.1f} dB" + ("  OK" if worst < 0.5 else "  TOO SIMILAR")
        if worst >= 0.5:
            failures.append(f"{base}_*: variants correlate at {worst:.2f} — they "
                            f"will sound repetitive")
        print(f"{base:<22}{len(members):>3}{worst:>32.3f}{flag}")

    print()
    print(f"{len(rows)} files written to {OUT_DIR}")
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print("  ! " + f)
        raise SystemExit(1)
    print("ALL CHECKS PASSED: mono / 16-bit / 44100 Hz; RMS > 0.001; no clipping;")
    print("peak = -3 dBFS; |DC| < 0.01; no headroom-eating spikes; spectral balance")
    print("sane; variants decorrelated; loops seamless at the splice.")


if __name__ == "__main__":
    main()
