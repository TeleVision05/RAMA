#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RAMA -- procedural AMBIENCE + MUSIC generator.

Everything here is synthesised from scratch with numpy + the stdlib `wave`
module.  No samples, no external audio libraries, no downloads.  All content is
therefore original and license-clean.

--------------------------------------------------------------------------
DESIGN NOTE -- how the seamless loop is guaranteed
--------------------------------------------------------------------------
Rather than generating a long non-periodic signal and crossfading the tail over
the head (which smears transients and still leaves a spectral seam), every
looping asset here is *constructed periodic* with period exactly N samples:

  * All filtering is done as circular convolution in the frequency domain
    (rFFT -> magnitude/complex response -> irFFT).  A circular filter of a
    periodic signal is periodic.  This includes the reverb: convolving with the
    room impulse response circularly wraps the reverb tail back onto the head,
    which is exactly what a real loop point needs.
  * All continuous oscillators / LFOs use frequencies snapped to the periodic
    grid k/T (see `pf`), so they complete a whole number of cycles per loop.
  * All discrete events (bird calls, drips, tabla strokes, plucked notes) are
    mixed in with `add_wrap`, which wraps whatever spills past the end of the
    buffer back onto the beginning.
  * Every subsequent stage (waveshaping, soft limiting, normalisation) is
    point-wise, so it preserves periodicity.

The result is a loop whose seam is mathematically identical to any other sample
boundary in the file.  `verify()` proves this: the sample-to-sample jump across
the wrap point is compared against the distribution of jumps inside the file.

Usage:
    python3 tools/gen_audio_amb.py            # build everything
    python3 tools/gen_audio_amb.py amb_river  # build a subset (substring match)
"""

import math
import os
import sys
import time
import wave

import numpy as np

# ---------------------------------------------------------------------------
# constants
# ---------------------------------------------------------------------------
SR = 44100
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "audio")
PEAK_DBFS = -3.0
PEAK_LIN = 10.0 ** (PEAK_DBFS / 20.0)


# ---------------------------------------------------------------------------
# tiny DSP toolkit
# ---------------------------------------------------------------------------
def db(x):
    return 20.0 * np.log10(max(float(x), 1e-12))


def rms(x):
    return float(np.sqrt(np.mean(np.square(x))))


def setrms(x, target):
    r = rms(x)
    return x * (target / r) if r > 1e-12 else x


def pf(freq, T):
    """Snap a frequency onto the periodic grid k/T so it loops seamlessly."""
    k = max(1, int(round(freq * T)))
    return k / T


def freqs(n):
    return np.fft.rfftfreq(n, 1.0 / SR)


# --- magnitude responses (zero phase, applied circularly) ------------------
def m_lp(f, fc, order=2):
    return 1.0 / np.sqrt(1.0 + (f / max(fc, 1e-9)) ** (2 * order))


def m_hp(f, fc, order=2):
    r = f / max(fc, 1e-9)
    return r ** order / np.sqrt(1.0 + r ** (2 * order))


def m_bp(f, lo, hi, order=2):
    return m_hp(f, lo, order) * m_lp(f, hi, order)


def m_res(f, f0, q):
    """Normalised 2-pole resonator magnitude (peak ~= 1.0 at f0)."""
    r = f / max(f0, 1e-9)
    h = 1.0 / np.sqrt((1.0 - r * r) ** 2 + (r / q) ** 2)
    return h / max(h.max(), 1e-12)


def m_tilt(f, lo_db, hi_db, pivot=800.0):
    """Gentle spectral tilt in dB from DC to Nyquist, pivoting at `pivot`."""
    x = np.log2(np.maximum(f, 1.0) / pivot)
    x = np.clip(x / 5.0, -1.0, 1.0)
    g = 0.5 * (lo_db + hi_db) + 0.5 * (hi_db - lo_db) * x
    return 10.0 ** (g / 20.0)


def apply_mag(x, mag):
    """Circular (wrap-around) filtering by a real magnitude response."""
    n = x.shape[0]
    X = np.fft.rfft(x, axis=0)
    X *= mag[:, None] if x.ndim == 2 else mag
    return np.fft.irfft(X, n=n, axis=0)


def circ_comb(x, delay_s, g, damp_hz=None):
    """Feedback comb 1/(1 - g z^-D) evaluated circularly.  D may be fractional."""
    n = x.shape[0]
    D = delay_s * SR
    k = np.arange(n // 2 + 1)
    z = np.exp(-2j * np.pi * k * D / n)
    if damp_hz:
        z = z * m_lp(freqs(n), damp_hz, 1)
    H = 1.0 / (1.0 - g * z)
    if n % 2 == 0:
        H[-1] = H[-1].real
    X = np.fft.rfft(x, axis=0)
    X *= H[:, None] if x.ndim == 2 else H
    return np.fft.irfft(X, n=n, axis=0)


def circ_conv(x, ir):
    """Circular convolution -- reverb tail wraps onto the head.  Loop-safe."""
    n = x.shape[0]
    pad = np.zeros((n, ir.shape[1]))
    m = min(ir.shape[0], n)
    pad[:m] = ir[:m]
    X = np.fft.rfft(x, axis=0)
    H = np.fft.rfft(pad, axis=0)
    return np.fft.irfft(X * H, n=n, axis=0)


def _fast_len(n):
    while True:
        m = n
        for p in (2, 3, 5, 7):
            while m % p == 0:
                m //= p
        if m == 1:
            return n
        n += 1


def lin_conv(x, ir):
    """True (non-circular) convolution -- for one-shot stings."""
    n, m = x.shape[0], ir.shape[0]
    N = _fast_len(n + m - 1)
    X = np.fft.rfft(x, n=N, axis=0)
    H = np.fft.rfft(ir, n=N, axis=0)
    return np.fft.irfft(X * H, n=N, axis=0)[:n]


def rand_env(n, hz, rng, lo=0.0, hi=1.0, shape=1.0, ch=1):
    """Smooth, strictly periodic random envelope in [lo, hi]."""
    x = rng.standard_normal((n, ch)) if ch > 1 else rng.standard_normal(n)
    x = apply_mag(x, m_lp(freqs(n), hz, 3))
    x = x - x.min(axis=0)
    mx = x.max(axis=0)
    x = x / np.where(mx > 1e-12, mx, 1.0)
    x = np.power(x, shape)
    return lo + (hi - lo) * x


def noise(n, rng, ch=1):
    return rng.standard_normal((n, ch)) if ch > 1 else rng.standard_normal(n)


def bed(n, rng, lo, hi, order=2, mod_hz=0.15, mod_depth=0.5, mod_shape=1.0):
    """Wide stereo band-limited noise bed with slow independent L/R breathing."""
    x = apply_mag(noise(n, rng, 2), m_bp(freqs(n), lo, hi, order))
    if mod_depth > 0:
        x = x * rand_env(n, mod_hz, rng, 1.0 - mod_depth, 1.0, mod_shape, ch=2)
    return setrms(x, 1.0)


def pan(x, p):
    """Equal power pan of a mono signal.  p in [-1, 1]."""
    a = (p + 1.0) * 0.25 * math.pi
    return np.stack([x * math.cos(a), x * math.sin(a)], axis=1)


def add_wrap(buf, start, seg):
    """Mix `seg` into `buf` at sample `start`, wrapping past the end."""
    n = buf.shape[0]
    if seg.ndim == 1 and buf.ndim == 2:
        seg = np.stack([seg, seg], axis=1)
    m = seg.shape[0]
    if m > n:  # fold long tails back on themselves
        fold = np.zeros_like(buf)
        for o in range(0, m, n):
            c = seg[o:o + n]
            fold[:c.shape[0]] += c
        seg, m = fold, n
    s = int(start) % n
    e = s + m
    if e <= n:
        buf[s:e] += seg
    else:
        k = n - s
        buf[s:] += seg[:k]
        buf[:e - n] += seg[k:]


def adsr(n, a, d, s, r, curve=2.0):
    """Sample-count ADSR with smooth (power) segments."""
    a, d, r = max(int(a * SR), 1), max(int(d * SR), 1), max(int(r * SR), 1)
    sus = max(n - a - d - r, 0)
    e = np.concatenate([
        np.linspace(0.0, 1.0, a, endpoint=False) ** (1.0 / curve),
        s + (1.0 - s) * (np.linspace(1.0, 0.0, d, endpoint=False) ** curve),
        np.full(sus, s),
        s * (np.linspace(1.0, 0.0, r) ** curve),
    ])
    return e[:n] if e.shape[0] >= n else np.pad(e, (0, n - e.shape[0]))


def compress(x, th=0.25, knee=0.10):
    """Soft-knee peak control with an explicit knee width.

    Used on percussion buses: a tabla transient otherwise eats ~16 dB of
    headroom, which both starves the sustained material and makes a downbeat
    sitting on sample 0 tower over the bar that leads into it.
    Point-wise, so the loop stays exactly periodic.
    """
    a = np.abs(x)
    y = x.copy()
    m = a > th
    y[m] = np.sign(x[m]) * (th + knee * np.tanh((a[m] - th) / knee))
    return y


def soft_limit(x, th=0.72):
    """Point-wise soft knee -- tames transients without touching periodicity."""
    a = np.abs(x)
    over = a > th
    y = x.copy()
    y[over] = np.sign(x[over]) * (th + (1.0 - th) * np.tanh((a[over] - th) / (1.0 - th)))
    return y


def finalize(x, headroom=0.62, limit=True):
    """DC removal -> gentle limiting -> peak normalise to PEAK_DBFS."""
    x = np.asarray(x, dtype=np.float64)
    if x.ndim == 1:
        x = x[:, None]
    x = x - x.mean(axis=0, keepdims=True)
    p = np.percentile(np.abs(x), 99.7)
    if p > 1e-9:
        x = x * (headroom / p)
    if limit:
        x = soft_limit(x)
    pk = np.max(np.abs(x))
    if pk > 1e-9:
        x = x * (PEAK_LIN / pk)
    return x


def write_wav(path, x):
    if x.ndim == 1:
        x = x[:, None]
    i16 = np.round(np.clip(x, -1.0, 1.0) * 32767.0).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(x.shape[1])
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(i16.tobytes())


# ---------------------------------------------------------------------------
# instruments
# ---------------------------------------------------------------------------
def karplus(f, dur, seed, decay=None, bright=0.55, pick=0.28, amp=1.0,
            body=0.0, release=0.22):
    """Karplus-Strong plucked string with fractional-delay tuning.

    Loop filter is h = [0.5(1-a), 0.5, 0.5a] -> lowpass + (0.5 + a) sample
    delay, so total loop delay is L + 0.5 + a == SR / f.
    """
    n = max(int(dur * SR), 64)
    d = SR / float(f)
    L = int(max(2, math.floor(d - 0.5)))
    a = min(max(d - 0.5 - L, 0.0), 0.999)
    if decay is None:
        decay = max(0.45, dur * 0.62)
    g = 10.0 ** (-3.0 * L / (decay * SR))
    g = min(g, 0.99995)

    rg = np.random.default_rng(seed)
    exc = rg.standard_normal(L)
    # brightness: blend raw noise with a smoothed copy
    sm = np.convolve(np.r_[exc[-3:], exc, exc[:3]], np.ones(5) / 5.0, "same")[3:-3]
    exc = bright * exc + (1.0 - bright) * sm
    # pick position comb -> notches, gives the string its character
    k = max(1, int(pick * L))
    exc = exc - np.roll(exc, k)
    exc *= np.hanning(L) ** 0.25
    exc /= max(np.max(np.abs(exc)), 1e-9)

    h0, h1, h2 = 0.5 * (1.0 - a), 0.5, 0.5 * a
    nb = int(math.ceil(n / L)) + 1
    out = np.empty(nb * L)
    buf = exc.copy()
    tail = np.zeros(2)  # the two samples preceding buf[0]
    for b in range(nb):
        out[b * L:(b + 1) * L] = buf
        s1 = np.empty(L); s1[0] = tail[1]; s1[1:] = buf[:-1]
        s2 = np.empty(L); s2[0] = tail[0]; s2[1] = tail[1]; s2[2:] = buf[:-2]
        tail = buf[-2:].copy()
        buf = g * (h0 * buf + h1 * s1 + h2 * s2)
    y = out[:n]

    if body > 0.0:  # wooden resonance of the gourd / soundboard
        f_ = freqs(n)
        r = apply_mag(y, 0.6 * m_res(f_, 210.0, 5.0) + 0.4 * m_res(f_, 430.0, 7.0))
        y = y + body * r

    env = np.ones(n)
    rl = min(int(release * SR), n)
    env[n - rl:] = np.linspace(1.0, 0.0, rl) ** 2.0
    return y * env * amp


def jivari(x, amount=0.5, seed=0):
    """Tanpura bridge buzz: a grazing nonlinearity + a band of upper partials
    that swells in just after the attack."""
    n = x.shape[0]
    p = x / max(np.max(np.abs(x)), 1e-9)
    z = 0.55 * np.tanh(5.5 * p) + 0.30 * np.sin(2.6 * np.pi * p) + 0.15 * (p * np.abs(p))
    f_ = freqs(n)
    z = apply_mag(z, m_bp(f_, 1200.0, 5200.0, 2) * (0.6 + 0.8 * m_res(f_, 2600.0, 2.2)))
    t = np.arange(n) / SR
    sw = (1.0 - np.exp(-t / 0.16)) * np.exp(-t / 1.9)
    z = z * sw
    z = setrms(z, max(rms(x), 1e-9))
    return x + amount * z


def bansuri(f, dur, seed, glide_from=None, glide_t=0.22, amp=1.0, breath=0.34,
            vib=5.0, vibd=0.013, bright=1.0, attack=0.10):
    """Bamboo flute: sine stack + breath noise, vibrato, slight overblow."""
    n = max(int(dur * SR), 256)
    t = np.arange(n) / SR
    rg = np.random.default_rng(seed)

    fc = np.full(n, float(f))
    if glide_from:
        gn = min(int(glide_t * SR), n)
        w = np.linspace(0.0, 1.0, gn) ** 0.55
        fc[:gn] = glide_from * (1.0 - w) + f * w
    vdep = np.clip(t / 0.55, 0.0, 1.0) * vibd
    fc = fc * (1.0 + vdep * np.sin(2 * np.pi * vib * t + rg.uniform(0, 6.28)))
    fc = fc * (1.0 + 0.004 * rand_env(n, 3.0, rg, -1.0, 1.0))  # air instability

    ph = 2 * np.pi * np.cumsum(fc) / SR
    env = adsr(n, attack, 0.28, 0.80, min(0.30, dur * 0.35), curve=1.7)
    env *= 1.0 + 0.09 * np.sin(2 * np.pi * 0.7 * t)  # slow breath swell

    harm = np.array([1.0, 0.34, 0.13, 0.062, 0.028, 0.013]) * bright
    y = np.zeros(n)
    for i, h in enumerate(harm):
        # overblow: upper partials track loudness
        y += h * np.sin((i + 1) * ph) * (env ** (1.0 + 0.42 * i))

    br = apply_mag(rg.standard_normal(n),
                   m_bp(freqs(n), max(f * 1.4, 900.0), 8000.0, 2)
                   * (0.7 + 0.9 * m_res(freqs(n), f * 3.0, 2.0)))
    br = setrms(br, 1.0) * env ** 1.3
    y = setrms(y, 1.0) + breath * br * 0.45
    return y * env * amp


def sitar(f, dur, seed, glide_from=None, glide_t=0.0, amp=1.0, **kw):
    """Plucked string; optional meend by resampling the pitch contour."""
    y = karplus(f, dur, seed, amp=amp, body=0.35, **kw)
    if glide_from and glide_t > 0.0:
        # cheap meend: pitch-shift the head by reading it with a moving rate
        n = y.shape[0]
        gn = min(int(glide_t * SR), n - 2)
        w = np.linspace(0.0, 1.0, gn) ** 0.6
        rate = (glide_from * (1.0 - w) + f * w) / f
        idx = np.cumsum(rate)
        idx = np.clip(idx, 0, n - 2)
        i0 = idx.astype(np.int64)
        fr = idx - i0
        y = np.concatenate([y[i0] * (1 - fr) + y[i0 + 1] * fr, y[gn:]])[:n]
    return y


def membrane(f0, dur, seed, modes, bend=(1.0, 1.0, 0.03), decay=0.5,
             click=0.15, click_bp=(1500.0, 7000.0), amp=1.0, lp=None):
    """Tabla-ish drum head: inharmonic modes + pitch-dropping envelope."""
    n = max(int(dur * SR), 256)
    t = np.arange(n) / SR
    rg = np.random.default_rng(seed)
    b0, b1, tau = bend
    fmul = b1 + (b0 - b1) * np.exp(-t / tau)
    y = np.zeros(n)
    for ratio, a, dm in modes:
        ph = 2 * np.pi * np.cumsum(f0 * ratio * fmul) / SR
        y += a * np.sin(ph + rg.uniform(0, 6.28)) * np.exp(-t / (decay * dm))
    y *= 1.0 - np.exp(-t / 0.0016)  # short attack rounding
    if click > 0.0:
        c = rg.standard_normal(n) * np.exp(-t / 0.008)
        c = apply_mag(c, m_bp(freqs(n), click_bp[0], click_bp[1], 2))
        y = setrms(y, 1.0) + click * setrms(c, 1.0) * 0.6
    if lp:
        y = apply_mag(y, m_lp(freqs(n), lp, 2))
    return setrms(y, 1.0) * amp * 0.35


def tabla(stroke, seed, amp=1.0, tune=1.0, lp=None):
    s = stroke
    if s in ("na", "ta"):
        return membrane(372.0 * tune, 0.85, seed,
                        [(1.0, 1.0, 1.0), (1.51, 0.5, 0.55), (2.0, 0.30, 0.4),
                         (2.66, 0.18, 0.28), (3.42, 0.10, 0.2)],
                        bend=(1.07, 1.0, 0.018), decay=0.42,
                        click=0.22 if s == "ta" else 0.14, amp=amp, lp=lp)
    if s == "tin":
        return membrane(505.0 * tune, 0.95, seed,
                        [(1.0, 1.0, 1.0), (1.48, 0.42, 0.6), (2.05, 0.24, 0.4),
                         (2.9, 0.12, 0.25)],
                        bend=(1.05, 1.0, 0.015), decay=0.55, click=0.16,
                        amp=amp, lp=lp)
    if s == "te":
        return membrane(430.0 * tune, 0.16, seed,
                        [(1.0, 1.0, 1.0), (1.6, 0.5, 0.7)],
                        bend=(1.2, 1.0, 0.01), decay=0.05, click=0.35,
                        amp=amp, lp=lp)
    if s == "ge":
        return membrane(96.0 * tune, 0.75, seed,
                        [(1.0, 1.0, 1.0), (1.44, 0.30, 0.5), (2.12, 0.13, 0.3)],
                        bend=(1.95, 0.76, 0.115), decay=0.40, click=0.05,
                        click_bp=(400.0, 2500.0), amp=amp, lp=lp)
    if s == "ke":
        return membrane(112.0 * tune, 0.20, seed,
                        [(1.0, 1.0, 1.0), (1.5, 0.35, 0.6)],
                        bend=(1.3, 1.0, 0.012), decay=0.055, click=0.10,
                        click_bp=(300.0, 2200.0), amp=amp, lp=lp)
    if s == "dha":
        a = tabla("na", seed, amp, tune, lp)
        b = tabla("ge", seed + 1, amp * 1.05, tune, lp)
        n = max(a.shape[0], b.shape[0])
        o = np.zeros(n); o[:a.shape[0]] += a; o[:b.shape[0]] += b
        return o
    if s == "dhin":
        a = tabla("tin", seed, amp, tune, lp)
        b = tabla("ge", seed + 1, amp * 0.9, tune, lp)
        n = max(a.shape[0], b.shape[0])
        o = np.zeros(n); o[:a.shape[0]] += a; o[:b.shape[0]] += b
        return o
    raise ValueError(stroke)


BELL_MODES = [(0.50, 0.55, 1.35), (1.00, 1.00, 1.00), (1.183, 0.62, 0.78),
              (1.506, 0.48, 0.60), (2.000, 0.40, 0.46), (2.514, 0.26, 0.34),
              (2.662, 0.20, 0.30), (3.011, 0.16, 0.24), (4.166, 0.10, 0.15),
              (5.433, 0.06, 0.10)]


def bell(f0, dur, seed, decay=3.2, amp=1.0, lp=None, strike=0.18):
    n = max(int(dur * SR), 256)
    t = np.arange(n) / SR
    rg = np.random.default_rng(seed)
    y = np.zeros(n)
    for ratio, a, dm in BELL_MODES:
        det = 1.0 + rg.uniform(-0.0016, 0.0016)          # warble pairs
        beat = 1.0 + 0.35 * np.sin(2 * np.pi * rg.uniform(0.25, 1.4) * t)
        y += a * np.sin(2 * np.pi * f0 * ratio * det * t + rg.uniform(0, 6.28)) \
             * np.exp(-t / (decay * dm)) * (0.72 + 0.28 * beat)
    y *= 1.0 - np.exp(-t / 0.0022)
    if strike > 0.0:
        c = rg.standard_normal(n) * np.exp(-t / 0.012)
        c = apply_mag(c, m_bp(freqs(n), 2000.0, 11000.0, 2))
        y = setrms(y, 1.0) + strike * setrms(c, 1.0) * 0.5
    if lp:
        y = apply_mag(y, m_lp(freqs(n), lp, 2))
    return setrms(y, 1.0) * amp


# ---------------------------------------------------------------------------
# reverb impulse responses
# ---------------------------------------------------------------------------
def make_ir(dur, rt60, seed, damp=4200.0, predelay=0.018, hp=90.0,
            width=1.0, er=6):
    n = int(dur * SR)
    rg = np.random.default_rng(seed)
    t = np.arange(n) / SR
    x = rg.standard_normal((n, 2))
    x[:, 1] = width * x[:, 1] + (1.0 - width) * x[:, 0]
    x *= (10.0 ** (-3.0 * t / rt60))[:, None]
    x *= (1.0 - np.exp(-t / 0.006))[:, None]          # diffusion build-up
    f_ = freqs(n)
    dark = apply_mag(x, m_bp(f_, hp, damp * 0.35, 2))
    w = np.clip(t / (dur * 0.7), 0.0, 1.0)[:, None]    # tail gets darker
    x = apply_mag(x, m_bp(f_, hp, damp, 2)) * (1.0 - w) + dark * w

    ir = np.zeros((n, 2))
    pd = int(predelay * SR)
    ir[pd:] = x[:n - pd]
    for i in range(er):                                # early reflections
        d = int((predelay + rg.uniform(0.008, 0.075)) * SR)
        g = rg.uniform(0.18, 0.5) * (0.75 ** i)
        c = rg.integers(0, 2)
        if d < n:
            ir[d, c] += g
            ir[min(d + rg.integers(3, 40), n - 1), 1 - c] += g * 0.7
    ir[0] += 0.05
    return ir / max(np.sqrt(np.sum(ir ** 2) / 2.0), 1e-9) * 0.9


def verb(x, ir, wet, loop=True):
    w = circ_conv(x, ir) if loop else lin_conv(x, ir)
    w = setrms(w, max(rms(x), 1e-12))
    return (1.0 - wet) * x + wet * w


# ---------------------------------------------------------------------------
# scales -- just intonation ratios above Sa
# ---------------------------------------------------------------------------
YAMAN = [1.0, 9 / 8, 5 / 4, 45 / 32, 3 / 2, 5 / 3, 15 / 8]        # Ma tivra
BHAIRAV = [1.0, 16 / 15, 5 / 4, 4 / 3, 3 / 2, 8 / 5, 15 / 8]      # re, dha komal
BHAIRAVI = [1.0, 16 / 15, 6 / 5, 4 / 3, 3 / 2, 8 / 5, 9 / 5]      # re ga dha ni komal
MALKAUNS = [1.0, 6 / 5, 4 / 3, 8 / 5, 9 / 5]                      # no Re, no Pa


def deg(scale, i, sa):
    o, k = divmod(int(i), len(scale))
    return sa * scale[k] * (2.0 ** o)


def tanpura(n, sa, seed, cycle=None, period=1.25, amp=1.0, buzz=0.55, spread=0.62,
            offset=0.5):
    """Four-string tanpura: Pa Sa Sa Sa(low), plucked round-robin.

    `offset` shifts the pluck grid off the loop boundary.  A pluck attack landing
    exactly on sample 0 makes the head of the loop far hotter than the tail even
    though the waveform is continuous; half a period of offset removes it.
    """
    T = n / SR
    if cycle is None:
        cycle = [sa * 0.75, sa, sa, sa * 0.5]
    out = np.zeros((n, 2))
    nplucks = int(round(T / period))
    period = T / nplucks                      # snap so the cycle closes the loop
    rg = np.random.default_rng(seed)
    for i in range(nplucks):
        f = cycle[i % len(cycle)]
        dur = period * 3.4
        s = karplus(f, dur, seed + i * 7, decay=period * 2.1, bright=0.42,
                    pick=0.16, body=0.45, release=period * 0.9)
        s = jivari(s, buzz, seed + i)
        s = setrms(s, 1.0) * (0.85 + 0.15 * rg.random())
        p = spread * (-0.6 if i % len(cycle) == 0 else (0.5 if i % 2 else -0.25))
        add_wrap(out, int((i + offset) * period * SR + rg.uniform(-0.012, 0.012) * SR),
                 pan(s, p))
    return setrms(out, 1.0) * amp


def sympathetic(x, sa, scale, seed, mix=0.20):
    """Sympathetic strings: a bank of tuned resonant combs (loop-safe)."""
    n = x.shape[0]
    acc = np.zeros_like(x)
    for i, r in enumerate(scale):
        for o in (0, 1):
            f = sa * r * (2 ** o)
            acc += circ_comb(x, 1.0 / f, 0.90, damp_hz=3400.0) / (1.0 + 0.35 * i)
    acc = apply_mag(acc, m_bp(freqs(n), 180.0, 6000.0, 2))
    acc = setrms(acc, max(rms(x), 1e-12))
    return x + mix * acc


# ===========================================================================
# AMBIENCES
# ===========================================================================
def gen_forest_day(dur=30.0):
    n = int(dur * SR)
    T = n / SR
    rg = np.random.default_rng(1001)
    f_ = freqs(n)
    mix = np.zeros((n, 2))

    # ---- cicada shimmer: resonant high noise + fast AM, many voices -------
    cic = np.zeros((n, 2))
    t = np.arange(n) / SR
    for v in range(9):
        f0 = rg.uniform(3800.0, 8200.0)
        src = noise(n, rg)
        src = apply_mag(src, m_res(f_, f0, rg.uniform(6.0, 14.0))
                        + 0.45 * m_res(f_, f0 * 1.63, 9.0)
                        + 0.25 * m_res(f_, f0 * 2.31, 11.0))
        am = pf(rg.uniform(38.0, 78.0), T)
        depth = rg.uniform(0.45, 0.85)
        buzz = (1.0 - depth) + depth * (0.5 + 0.5 * np.sin(2 * np.pi * am * t
                                                           + rg.uniform(0, 6.3))) ** 1.6
        swell = rand_env(n, rg.uniform(0.06, 0.22), rg, 0.12, 1.0, 1.7)
        cic += pan(setrms(src * buzz * swell, 1.0), rg.uniform(-0.95, 0.95)) \
               * rg.uniform(0.55, 1.0)
    cic = apply_mag(cic, m_bp(f_, 2600.0, 13000.0, 2))
    mix += setrms(cic, 0.115)

    # ---- leaf rustle swells ----------------------------------------------
    leaf = bed(n, rg, 700.0, 6500.0, 2, mod_hz=0.20, mod_depth=0.85, mod_shape=1.9)
    gust = rand_env(n, 0.09, rg, 0.15, 1.0, 2.6, ch=2)
    leaf = leaf * (0.35 + 0.9 * gust)
    for _ in range(14):  # individual branch shivers
        d = rg.uniform(0.5, 2.2)
        m = int(d * SR)
        s = apply_mag(rg.standard_normal(m), m_bp(freqs(m), 1400.0, 9000.0, 2))
        s *= np.sin(np.linspace(0, np.pi, m)) ** 2.2
        s *= 1.0 + 0.6 * np.sin(2 * np.pi * rg.uniform(7, 18) * np.arange(m) / SR)
        add_wrap(leaf, rg.uniform(0, n), pan(setrms(s, 1.0) * 0.55,
                                             rg.uniform(-0.9, 0.9)))
    mix += setrms(leaf, 0.085)

    # ---- distant birds ----------------------------------------------------
    birds = np.zeros((n, 2))
    for _ in range(46):
        birds_seg = _bird(rg)
        d = rg.uniform(0.25, 1.0)                        # distance 0..1
        seg = apply_mag(birds_seg, m_lp(freqs(birds_seg.shape[0]),
                                        9000.0 - 6200.0 * d, 2))
        add_wrap(birds, rg.uniform(0, n),
                 pan(setrms(seg, 1.0) * (1.0 - 0.72 * d), rg.uniform(-1.0, 1.0)))
    birds = verb(birds, make_ir(2.2, 1.7, 77, damp=5200.0, width=1.0), 0.42)
    mix += setrms(birds, 0.055)

    # ---- low forest hum ---------------------------------------------------
    hum = bed(n, rg, 38.0, 230.0, 2, mod_hz=0.05, mod_depth=0.4)
    hum = apply_mag(hum, 1.0 + 1.1 * m_res(f_, 92.0, 3.0) + 0.7 * m_res(f_, 148.0, 4.0))
    mix += setrms(hum, 0.075)

    # ---- distant canopy air ----------------------------------------------
    mix += setrms(bed(n, rg, 300.0, 2400.0, 2, mod_hz=0.07, mod_depth=0.55), 0.038)

    mix = verb(mix, make_ir(1.8, 1.2, 5, damp=6000.0, width=1.0), 0.16)
    mix = apply_mag(mix, m_tilt(f_, -1.5, 2.5, 900.0) * m_hp(f_, 26.0, 2))
    return finalize(mix)


def _bird(rg):
    """One short bird call, mono."""
    style = int(rg.integers(0, 5))
    if style == 0:      # descending whistle
        d = rg.uniform(0.14, 0.26)
        m = int(d * SR); t = np.arange(m) / SR
        f = rg.uniform(2400, 3400) * np.exp(-t / (d * 0.9)) ** 0.35
        env = np.sin(np.linspace(0, np.pi, m)) ** 1.3
    elif style == 1:    # rising tweet
        d = rg.uniform(0.06, 0.12)
        m = int(d * SR); t = np.arange(m) / SR
        f = np.linspace(rg.uniform(1500, 2100), rg.uniform(3000, 4200), m)
        env = np.sin(np.linspace(0, np.pi, m)) ** 1.1
    elif style == 2:    # two-note pee-oo
        d = rg.uniform(0.30, 0.5)
        m = int(d * SR); t = np.arange(m) / SR
        h = m // 2
        f = np.concatenate([np.full(h, rg.uniform(2600, 3200)),
                            np.full(m - h, rg.uniform(1900, 2300))])
        env = np.concatenate([np.sin(np.linspace(0, np.pi, h)) ** 1.4,
                              np.sin(np.linspace(0, np.pi, m - h)) ** 1.4])
    elif style == 3:    # trill
        d = rg.uniform(0.35, 0.75)
        m = int(d * SR); t = np.arange(m) / SR
        r = rg.uniform(18, 34)
        f = rg.uniform(2800, 4000) * (1.0 + 0.11 * np.sin(2 * np.pi * r * t))
        env = (0.5 + 0.5 * np.sin(2 * np.pi * r * t)) ** 2.2
        env *= np.sin(np.linspace(0, np.pi, m)) ** 0.8
    else:               # koel-like rising triple
        d = rg.uniform(0.55, 0.9)
        m = int(d * SR); t = np.arange(m) / SR
        base = rg.uniform(1300, 1700)
        f = base * (1.0 + 0.55 * np.clip(t / d, 0, 1))
        step = (0.5 + 0.5 * np.sign(np.sin(2 * np.pi * 3.2 * t)))
        env = step * np.sin(np.linspace(0, np.pi, m)) ** 0.9
        f = f * (1.0 + 0.06 * step)
    ph = 2 * np.pi * np.cumsum(f) / SR
    y = np.sin(ph) + 0.28 * np.sin(2 * ph) + 0.09 * np.sin(3 * ph)
    nz = apply_mag(rg.standard_normal(m), m_bp(freqs(m), 2000.0, 9000.0, 2))
    y = y * env + 0.10 * setrms(nz, 1.0) * env
    return y


def gen_forest_night(dur=30.0):
    n = int(dur * SR)
    T = n / SR
    rg = np.random.default_rng(2002)
    f_ = freqs(n)
    t = np.arange(n) / SR
    mix = np.zeros((n, 2))

    # ---- dense pulsing crickets, high and narrow -------------------------
    cri = np.zeros((n, 2))
    for v in range(14):
        f0 = rg.uniform(4600.0, 9200.0)
        src = apply_mag(noise(n, rg),
                        m_res(f_, f0, rg.uniform(16.0, 34.0))
                        + 0.35 * m_res(f_, f0 * 1.5, 20.0))
        rate = pf(rg.uniform(6.5, 15.0), T)
        ph = 2 * np.pi * rate * t + rg.uniform(0, 6.3)
        # sharp chirp pulses (short duty cycle)
        pulse = np.clip(np.sin(ph), 0.0, 1.0) ** rg.uniform(4.0, 11.0)
        # each chirp is itself a fast 3-4 stroke trill
        pulse = pulse * (0.55 + 0.45 * (0.5 + 0.5 * np.sin(
            2 * np.pi * pf(rg.uniform(40, 62), T) * t)))
        slow = rand_env(n, rg.uniform(0.05, 0.15), rg, 0.35, 1.0, 1.4)
        cri += pan(setrms(src * pulse * slow, 1.0), rg.uniform(-1.0, 1.0)) \
               * rg.uniform(0.5, 1.0)
    cri = apply_mag(cri, m_bp(f_, 3500.0, 14000.0, 2))
    mix += setrms(cri, 0.100)

    # ---- owl hoots --------------------------------------------------------
    owls = np.zeros((n, 2))
    ts = 1.6
    while ts < T - 0.5:
        f0 = rg.uniform(300.0, 430.0)
        seg = np.zeros(int(1.9 * SR))
        off = 0
        for k, ln in enumerate((0.30, 0.55)):
            m = int(ln * SR); tt = np.arange(m) / SR
            fc = f0 * (1.0 + 0.035 * np.sin(np.pi * tt / ln)) * (1.0 if k == 0 else 0.97)
            ph = 2 * np.pi * np.cumsum(fc) / SR
            e = np.sin(np.linspace(0, np.pi, m)) ** 1.6
            v = (np.sin(ph) + 0.22 * np.sin(2 * ph) + 0.06 * np.sin(3 * ph)) * e
            v += 0.05 * setrms(apply_mag(rg.standard_normal(m),
                                         m_bp(freqs(m), 400.0, 2200.0, 2)), 1.0) * e
            seg[off:off + m] += v
            off += m + int(0.18 * SR)
        seg = apply_mag(seg, m_lp(freqs(seg.shape[0]), 1500.0, 2))
        add_wrap(owls, ts * SR, pan(setrms(seg, 1.0), rg.uniform(-0.75, 0.75)))
        ts += rg.uniform(4.5, 7.5)
    owls = verb(owls, make_ir(3.0, 2.4, 41, damp=2600.0), 0.5)
    mix += setrms(owls, 0.075)

    # ---- frogs near water -------------------------------------------------
    frogs = np.zeros((n, 2))
    for _ in range(34):
        d = rg.uniform(0.22, 0.8)
        m = int(d * SR); tt = np.arange(m) / SR
        f0 = rg.uniform(190.0, 470.0)
        rate = rg.uniform(22.0, 48.0) * (1.0 + rg.uniform(-0.3, 0.5) * tt / d)
        croak = np.sin(2 * np.pi * np.cumsum(np.full(m, f0)) / SR)
        croak += 0.45 * np.sin(2 * np.pi * np.cumsum(np.full(m, f0 * 2)) / SR)
        gate = (0.5 + 0.5 * np.sin(2 * np.pi * np.cumsum(rate) / SR)) ** 3.0
        croak = croak * gate
        croak = apply_mag(croak, m_res(freqs(m), rg.uniform(700, 1400), 3.0) * 0.8
                          + m_lp(freqs(m), 2600.0, 2) * 0.6)
        croak *= np.sin(np.linspace(0, np.pi, m)) ** 0.7
        add_wrap(frogs, rg.uniform(0, n),
                 pan(setrms(croak, 1.0), rg.uniform(-0.9, 0.9)) * rg.uniform(0.4, 1.0))
    frogs = verb(frogs, make_ir(2.2, 1.6, 43, damp=3000.0), 0.3)
    mix += setrms(frogs, 0.062)

    # water near the frogs (quiet, slow)
    wat = bed(n, rg, 260.0, 1900.0, 2, mod_hz=0.13, mod_depth=0.6)
    mix += setrms(wat, 0.030)

    # ---- sparse night insects (much thinner than day) ---------------------
    ins = bed(n, rg, 2500.0, 6000.0, 2, mod_hz=0.10, mod_depth=0.8, mod_shape=2.4)
    mix += setrms(ins, 0.018)

    # ---- deep quiet air bed ----------------------------------------------
    air = bed(n, rg, 26.0, 180.0, 2, mod_hz=0.04, mod_depth=0.35)
    air = apply_mag(air, 1.0 + 0.9 * m_res(f_, 58.0, 3.0))
    mix += setrms(air, 0.085)

    mix = verb(mix, make_ir(2.6, 2.0, 9, damp=3800.0), 0.18)
    mix = apply_mag(mix, m_tilt(f_, 2.0, -1.0, 700.0) * m_hp(f_, 22.0, 2))
    return finalize(mix)


def gen_river(dur=30.0):
    n = int(dur * SR)
    rg = np.random.default_rng(3003)
    f_ = freqs(n)
    mix = np.zeros((n, 2))

    bands = [(45, 170, 0.055, 0.06, 0.35), (150, 420, 0.115, 0.11, 0.5),
             (380, 1100, 0.135, 0.19, 0.6), (950, 2900, 0.125, 0.27, 0.65),
             (2600, 6800, 0.085, 0.36, 0.7), (6200, 14000, 0.045, 0.5, 0.75)]
    for lo, hi, g, mh, md in bands:
        b = bed(n, rg, lo, hi, 2, mod_hz=mh, mod_depth=md, mod_shape=1.3)
        # a second, faster ripple layer keeps it from sounding static
        b = b * rand_env(n, mh * 4.5, rg, 0.72, 1.0, 1.1, ch=2)
        mix += setrms(b, g)

    # ---- gurgles / bubbles ------------------------------------------------
    gur = np.zeros((n, 2))
    for _ in range(150):
        kind = rg.random()
        if kind < 0.55:                      # bubble: sine with rising pitch
            d = rg.uniform(0.025, 0.09)
            m = int(d * SR); tt = np.arange(m) / SR
            f0 = rg.uniform(320, 1100)
            f = f0 * (1.0 + rg.uniform(0.5, 1.6) * (tt / d) ** 1.5)
            y = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-tt / (d * 0.42))
            y += 0.2 * np.sin(4 * np.pi * np.cumsum(f) / SR) * np.exp(-tt / (d * 0.2))
        else:                                # gurgle: resonance sweep on noise
            d = rg.uniform(0.10, 0.30)
            m = int(d * SR); tt = np.arange(m) / SR
            nz = rg.standard_normal(m)
            fa, fb = rg.uniform(300, 700), rg.uniform(700, 1900)
            if rg.random() < 0.5:
                fa, fb = fb, fa
            y = (apply_mag(nz, m_res(freqs(m), fa, 7.0)) * np.linspace(1, 0, m)
                 + apply_mag(nz, m_res(freqs(m), fb, 7.0)) * np.linspace(0, 1, m))
            y *= np.sin(np.linspace(0, np.pi, m)) ** 1.2
            y *= 1.0 + 0.5 * np.sin(2 * np.pi * rg.uniform(14, 40) * tt)
        add_wrap(gur, rg.uniform(0, n),
                 pan(setrms(y, 1.0), rg.uniform(-1.0, 1.0)) * rg.uniform(0.25, 1.0))
    mix += setrms(gur, 0.070)

    # ---- water hitting rock: brief hiss bursts ----------------------------
    spl = np.zeros((n, 2))
    for _ in range(40):
        d = rg.uniform(0.15, 0.6)
        m = int(d * SR)
        y = apply_mag(rg.standard_normal(m), m_bp(freqs(m), rg.uniform(900, 2200),
                                                  rg.uniform(6000, 12000), 2))
        y *= np.sin(np.linspace(0, np.pi, m)) ** 2.4
        add_wrap(spl, rg.uniform(0, n), pan(setrms(y, 1.0), rg.uniform(-1.0, 1.0)))
    mix += setrms(spl, 0.038)

    mix = verb(mix, make_ir(1.6, 1.1, 13, damp=6500.0), 0.13)
    mix = apply_mag(mix, m_tilt(f_, 0.5, 1.5, 800.0) * m_hp(f_, 30.0, 2))
    return finalize(mix)


def gen_village(dur=30.0):
    n = int(dur * SR)
    T = n / SR
    rg = np.random.default_rng(4004)
    f_ = freqs(n)
    t = np.arange(n) / SR
    mix = np.zeros((n, 2))

    # ---- distant murmur of voices (formants, no words) -------------------
    VOWELS = [(700, 1220, 2600), (400, 1900, 2570), (300, 2300, 3000),
              (600, 1050, 2400), (450, 800, 2830), (640, 1200, 2400)]
    mur = np.zeros((n, 2))
    for v in range(9):
        f0 = pf(rg.uniform(96.0, 215.0), T)
        # band-limited buzz (glottal source) with jitter + shimmer
        K = int(min(34, 8000 / f0))
        vib = 1.0 + 0.012 * np.sin(2 * np.pi * pf(rg.uniform(4, 7), T) * t
                                   + rg.uniform(0, 6.3))
        ph = 2 * np.pi * np.cumsum(f0 * vib) / SR
        src = np.zeros(n)
        for k in range(1, K + 1):
            src += np.sin(k * ph + rg.uniform(0, 6.3)) / (k ** 1.15)
        src += 0.35 * setrms(apply_mag(rg.standard_normal(n),
                                       m_bp(f_, 1200.0, 6000.0, 2)), rms(src))
        # slowly morph between two vowel colours
        a, b = VOWELS[rg.integers(0, len(VOWELS))], VOWELS[rg.integers(0, len(VOWELS))]
        ma = sum(g * m_res(f_, fc, 8.0) for fc, g in zip(a, (1.0, 0.55, 0.25)))
        mb = sum(g * m_res(f_, fc, 8.0) for fc, g in zip(b, (1.0, 0.55, 0.25)))
        w = rand_env(n, 0.35, rg, 0.0, 1.0)
        voc = apply_mag(src, ma) * (1.0 - w) + apply_mag(src, mb) * w
        # syllabic gating -- this is what makes it read as speech
        syl = rand_env(n, rg.uniform(3.0, 6.0), rg, 0.0, 1.0, 2.6)
        syl = np.clip(syl * 2.1 - 0.35, 0.0, 1.0)
        talk = rand_env(n, rg.uniform(0.07, 0.2), rg, 0.0, 1.0, 2.2)  # pauses
        voc = voc * syl * talk
        mur += pan(setrms(voc, 1.0), rg.uniform(-0.9, 0.9)) * rg.uniform(0.5, 1.0)
    mur = apply_mag(mur, m_bp(f_, 200.0, 3200.0, 2))
    mur = verb(mur, make_ir(2.6, 1.9, 61, damp=2800.0), 0.55)
    mix += setrms(mur, 0.085)

    # ---- livestock --------------------------------------------------------
    stock = np.zeros((n, 2))
    ts = rg.uniform(0.5, 4.0)
    while ts < T:
        if rg.random() < 0.55:               # goat bleat
            d = rg.uniform(0.45, 0.95)
            m = int(d * SR); tt = np.arange(m) / SR
            f0 = rg.uniform(320.0, 470.0) * (1.0 - 0.12 * tt / d)
            trem = 1.0 + 0.16 * np.sin(2 * np.pi * rg.uniform(9, 15) * tt)
            ph = 2 * np.pi * np.cumsum(f0 * trem) / SR
            y = sum(a * np.sin(k * ph) for k, a in
                    ((1, 1.0), (2, 0.6), (3, 0.35), (4, 0.2), (5, 0.1)))
            y *= (0.55 + 0.45 * np.sin(2 * np.pi * rg.uniform(11, 16) * tt)) ** 1.4
            y = apply_mag(y, m_res(freqs(m), 900.0, 3.0) * 0.9
                          + m_res(freqs(m), 2100.0, 4.0) * 0.4 + 0.35)
            y *= np.sin(np.linspace(0, np.pi, m)) ** 0.9
        else:                                # cow low
            d = rg.uniform(1.1, 1.9)
            m = int(d * SR); tt = np.arange(m) / SR
            u = tt / d
            f0 = rg.uniform(105.0, 145.0) * (1.0 + 0.22 * np.sin(np.pi * u) ** 1.4)
            ph = 2 * np.pi * np.cumsum(f0) / SR
            y = sum(a * np.sin(k * ph) for k, a in
                    ((1, 1.0), (2, 0.7), (3, 0.45), (4, 0.3), (5, 0.18), (6, 0.1)))
            y = apply_mag(y, m_res(freqs(m), 480.0, 3.5) * 0.8
                          + m_res(freqs(m), 1150.0, 4.0) * 0.35 + 0.4)
            y *= np.sin(np.pi * u) ** 1.2
        add_wrap(stock, ts * SR,
                 pan(setrms(y, 1.0), rg.uniform(-0.85, 0.85)) * rg.uniform(0.5, 1.0))
        ts += rg.uniform(5.0, 11.0)
    stock = verb(stock, make_ir(2.8, 2.1, 63, damp=2400.0), 0.45)
    mix += setrms(stock, 0.055)

    # ---- distant hand drum, 8 beats @ 96 BPM = 5 s, 6 cycles in 30 s -----
    drum = np.zeros((n, 2))
    beat = 60.0 / 96.0
    pat = [("dha", 0.0, 1.0), ("te", 0.5, 0.3), ("tin", 1.0, 0.7),
           ("te", 1.75, 0.25), ("na", 2.0, 0.8), ("ge", 2.5, 0.55),
           ("tin", 3.0, 0.65), ("te", 3.5, 0.3), ("dha", 4.0, 0.9),
           ("te", 4.5, 0.28), ("na", 5.0, 0.6), ("ke", 5.5, 0.35),
           ("tin", 6.0, 0.7), ("te", 6.5, 0.3), ("na", 7.0, 0.55),
           ("te", 7.5, 0.35)]
    cycles = int(round(T / (8 * beat)))
    for c in range(cycles):
        for i, (s, b, a) in enumerate(pat):
            y = tabla(s, 900 + c * 37 + i, amp=a * rg.uniform(0.82, 1.0),
                      tune=1.0, lp=2600.0)
            add_wrap(drum, (c * 8 + b) * beat * SR + rg.uniform(-0.01, 0.01) * SR,
                     pan(y, 0.35 + rg.uniform(-0.1, 0.1)))
    drum = verb(drum, make_ir(3.0, 2.3, 65, damp=2000.0), 0.62)
    mix += setrms(drum, 0.048)

    # ---- creaking rope / well pulley -------------------------------------
    creak = np.zeros((n, 2))
    for _ in range(5):
        d = rg.uniform(0.7, 1.6)
        m = int(d * SR)
        imp = np.zeros(m)
        pos, k = 0.0, 0
        rate = rg.uniform(16.0, 34.0)
        while pos < m - 2:
            imp[int(pos)] += rg.uniform(0.4, 1.0) * (1.0 - 0.6 * pos / m)
            rate *= rg.uniform(0.985, 1.02)
            pos += SR / max(rate, 4.0) * rg.uniform(0.7, 1.3)
            k += 1
        fr = rg.uniform(320, 900)
        y = apply_mag(imp, m_res(freqs(m), fr, 12.0) + 0.5 * m_res(freqs(m), fr * 2.4, 9.0)
                      + 0.25 * m_res(freqs(m), fr * 4.1, 7.0))
        y *= np.sin(np.linspace(0, np.pi, m)) ** 0.8
        add_wrap(creak, rg.uniform(0, n),
                 pan(setrms(y, 1.0), rg.uniform(-0.8, 0.8)) * rg.uniform(0.5, 1.0))
    mix += setrms(creak, 0.026)

    # ---- wind through thatch ---------------------------------------------
    th = bed(n, rg, 500.0, 4200.0, 2, mod_hz=0.10, mod_depth=0.75, mod_shape=2.0)
    th = apply_mag(th, 1.0 + 0.7 * m_res(f_, 1600.0, 4.0) + 0.4 * m_res(f_, 3100.0, 6.0))
    mix += setrms(th, 0.042)

    # ---- warm low bed -----------------------------------------------------
    mix += setrms(bed(n, rg, 45.0, 260.0, 2, mod_hz=0.06, mod_depth=0.4), 0.058)
    # ---- daytime insects (village is inhabited countryside) --------------
    mix += setrms(bed(n, rg, 3000.0, 8000.0, 2, mod_hz=0.09, mod_depth=0.8), 0.020)

    mix = verb(mix, make_ir(2.2, 1.6, 67, damp=3600.0), 0.15)
    mix = apply_mag(mix, m_tilt(f_, 1.5, 0.0, 700.0) * m_hp(f_, 28.0, 2))
    return finalize(mix)


def gen_wind(dur=30.0):
    n = int(dur * SR)
    rg = np.random.default_rng(5005)
    f_ = freqs(n)
    mix = np.zeros((n, 2))

    # global gust envelope (smoothed random, strongly shaped)
    gust = rand_env(n, 0.075, rg, 0.06, 1.0, 2.3, ch=2)
    gust = gust * rand_env(n, 0.22, rg, 0.45, 1.0, 1.4, ch=2)

    # band-pass whose centre sweeps: crossfade a stack of static bands with
    # periodic random weights (keeps the loop exact).
    centres = [140.0, 300.0, 620.0, 1250.0, 2500.0, 5000.0, 9500.0]
    src = noise(n, rg, 2)
    acc = np.zeros((n, 2))
    wsum = np.zeros((n, 2))
    for i, fc in enumerate(centres):
        b = apply_mag(src, m_bp(f_, fc * 0.55, fc * 1.9, 2))
        w = rand_env(n, 0.10 + 0.03 * i, rg, 0.05, 1.0, 2.0, ch=2)
        # louder gusts push energy upward in frequency
        w = w * (gust ** (0.35 + 0.30 * i))
        acc += setrms(b, 1.0) * w
        wsum += w
    acc = acc / np.maximum(wsum, 1e-6)
    mix += setrms(acc * (0.25 + 0.85 * gust), 0.13)

    # whistling through gaps -- narrow resonances that appear on gusts
    wh = np.zeros((n, 2))
    for fc, q in ((760.0, 22.0), (1150.0, 26.0), (1830.0, 30.0), (2740.0, 24.0)):
        b = apply_mag(noise(n, rg, 2), m_res(f_, fc, q))
        e = rand_env(n, 0.12, rg, 0.0, 1.0, 3.2, ch=2) * gust ** 2.0
        wh += setrms(b, 1.0) * e
    mix += setrms(wh, 0.045)

    # low body / rumble that swells with the gusts
    low = bed(n, rg, 30.0, 210.0, 2, mod_hz=0.06, mod_depth=0.45)
    mix += setrms(low * (0.4 + 0.9 * gust), 0.085)

    # buffeting -- brief broadband slaps at the peak of gusts
    buf = np.zeros((n, 2))
    for _ in range(22):
        d = rg.uniform(0.25, 1.1)
        m = int(d * SR)
        y = apply_mag(rg.standard_normal(m), m_bp(freqs(m), 120.0, 2600.0, 2))
        y *= np.sin(np.linspace(0, np.pi, m)) ** 2.6
        add_wrap(buf, rg.uniform(0, n), pan(setrms(y, 1.0), rg.uniform(-1.0, 1.0)))
    mix += setrms(buf, 0.035)

    mix = apply_mag(mix, m_hp(f_, 24.0, 2) * m_tilt(f_, 1.0, 0.5, 900.0))
    return finalize(mix)


def gen_temple(dur=30.0):
    n = int(dur * SR)
    T = n / SR
    rg = np.random.default_rng(6006)
    f_ = freqs(n)
    t = np.arange(n) / SR
    mix = np.zeros((n, 2))

    # ---- low stone drone with slow beating -------------------------------
    dr = np.zeros((n, 2))
    base = 58.0
    for k, a in ((1.0, 1.0), (1.5, 0.30), (2.0, 0.42), (3.0, 0.18),
                 (4.0, 0.10), (5.0, 0.05)):
        for det, p in ((0.0, -0.5), (0.4, 0.5)):
            f0 = pf(base * k + det, T)
            s = np.sin(2 * np.pi * f0 * t + rg.uniform(0, 6.3))
            env = 0.75 + 0.25 * np.sin(2 * np.pi * pf(0.07, T) * t + k)
            dr += pan(s * env * a, p * 0.7)
    dr = apply_mag(dr, m_lp(f_, 900.0, 2))
    mix += setrms(dr, 0.115)

    # ---- cold air in a stone hall ----------------------------------------
    air = bed(n, rg, 45.0, 900.0, 2, mod_hz=0.045, mod_depth=0.45)
    air = apply_mag(air, 1.0 + 0.8 * m_res(f_, 118.0, 4.0) + 0.5 * m_res(f_, 236.0, 6.0))
    mix += setrms(air, 0.055)

    # ---- faint drips ------------------------------------------------------
    dripb = np.zeros((n, 2))
    ts = rg.uniform(0.3, 2.0)
    while ts < T:
        d = rg.uniform(0.05, 0.12)
        m = int(d * SR); tt = np.arange(m) / SR
        f0 = rg.uniform(900, 2400)
        f = f0 * (1.0 + 1.1 * (tt / d) ** 1.4)         # bubble pitch rise
        y = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-tt / (d * 0.36))
        y += 0.25 * np.sin(4 * np.pi * np.cumsum(f) / SR) * np.exp(-tt / (d * 0.14))
        c = apply_mag(rg.standard_normal(m), m_bp(freqs(m), 2500.0, 10000.0, 2))
        y = setrms(y, 1.0) + 0.12 * setrms(c, 1.0) * np.exp(-tt / 0.004)
        add_wrap(dripb, ts * SR,
                 pan(setrms(y, 1.0), rg.uniform(-0.9, 0.9)) * rg.uniform(0.35, 1.0))
        ts += rg.uniform(1.8, 5.0)
    mix += setrms(dripb, 0.030)

    # ---- distant temple bell every 10 s (3 strikes / 30 s loop) ----------
    bells = np.zeros((n, 2))
    spacing = T / 3.0
    for i in range(3):
        y = bell(rg.uniform(207.0, 216.0), 9.0, 700 + i * 11, decay=3.4,
                 lp=3000.0, strike=0.10)
        y *= 1.0 if i else 1.12
        add_wrap(bells, (1.6 + i * spacing) * SR,
                 pan(setrms(y, 1.0), (-0.3, 0.25, -0.1)[i]))
    mix += setrms(bells, 0.075)

    # ---- distant chant-like resonance (very faint, sacred) ---------------
    ch = np.zeros((n, 2))
    for f0, a in ((pf(116.0, T), 1.0), (pf(174.0, T), 0.5), (pf(232.0, T), 0.3)):
        e = rand_env(n, 0.06, rg, 0.0, 1.0, 2.4)
        ch += pan(np.sin(2 * np.pi * f0 * t + rg.uniform(0, 6.3)) * e * a,
                  rg.uniform(-0.4, 0.4))
    mix += setrms(ch, 0.022)

    ir = make_ir(5.0, 4.4, 71, damp=2300.0, predelay=0.045, hp=70.0, er=10)
    mix = verb(mix, ir, 0.62)
    mix = apply_mag(mix, m_tilt(f_, 2.5, -3.0, 600.0) * m_hp(f_, 26.0, 2))
    return finalize(mix)


# ===========================================================================
# MUSIC
# ===========================================================================
def _render_melody(n, notes, sa, scale, seed, sitar_gain=1.0, flute_gain=1.0):
    """notes: (t_sec, degree, dur_sec, 'sitar'|'flute', glide_from_degree|None,
               vel)"""
    sit = np.zeros((n, 2))
    flu = np.zeros((n, 2))
    rg = np.random.default_rng(seed)
    for i, nt in enumerate(notes):
        t0, d, dur, inst = nt[0], nt[1], nt[2], nt[3]
        gl = nt[4] if len(nt) > 4 else None
        vel = nt[5] if len(nt) > 5 else 1.0
        f = deg(scale, d, sa)
        gf = deg(scale, gl, sa) if gl is not None else None
        if inst == "sitar":
            y = sitar(f, dur, seed + i * 13, glide_from=gf,
                      glide_t=0.16 if gf else 0.0, amp=vel,
                      decay=dur * 0.72, bright=0.6, pick=0.24,
                      release=min(0.5, dur * 0.4))
            add_wrap(sit, t0 * SR, pan(y, rg.uniform(-0.32, 0.32)))
        else:
            y = bansuri(f, dur, seed + i * 17, glide_from=gf,
                        glide_t=0.24, amp=vel, breath=0.36,
                        vib=rg.uniform(4.4, 5.6), vibd=0.014)
            add_wrap(flu, t0 * SR, pan(y, rg.uniform(-0.22, 0.22)))
    out = np.zeros((n, 2))
    if np.any(sit):
        sit = sympathetic(sit, sa, scale, seed + 3, mix=0.22)
        out += setrms(sit, 1.0) * sitar_gain
    if np.any(flu):
        out += setrms(flu, 1.0) * flute_gain
    return out


def gen_music_explore(dur=75.0):
    n = int(dur * SR)
    rg = np.random.default_rng(7007)
    f_ = freqs(n)
    sa = 146.0
    S = YAMAN

    mix = np.zeros((n, 2))
    dro = tanpura(n, sa, 111, period=1.25, buzz=0.6, spread=0.7)
    mix += setrms(dro, 0.085)

    # low sustained shruti box under everything (Sa + Pa)
    t = np.arange(n) / SR
    T = n / SR
    shr = np.zeros((n, 2))
    for f0, a, p in ((sa * 0.5, 1.0, -0.4), (sa * 0.75, 0.6, 0.4),
                     (sa, 0.45, 0.0), (sa * 1.5, 0.25, 0.2)):
        for det in (-0.12, 0.12):
            ff = pf(f0 + det, T)
            e = 0.8 + 0.2 * np.sin(2 * np.pi * pf(0.055, T) * t + f0)
            shr += pan(np.sin(2 * np.pi * ff * t + rg.uniform(0, 6.3)) * e * a, p)
    shr = apply_mag(shr, m_lp(f_, 1400.0, 2))
    mix += setrms(shr, 0.045)

    # alap -- slow, wandering, unmetred
    NOTES = [
        (0.8, 0, 3.6, "flute", None, 0.85),
        (4.7, 1, 1.4, "flute", 0, 0.8),
        (6.3, 2, 3.1, "flute", None, 0.9),
        (9.7, 1, 1.2, "flute", None, 0.7),
        (11.1, 0, 3.8, "flute", 1, 0.85),
        (15.3, -1, 2.3, "sitar", None, 0.8),
        (17.8, 0, 2.7, "sitar", -1, 0.9),
        (20.8, 2, 1.5, "sitar", None, 0.75),
        (22.5, 3, 3.0, "sitar", 2, 0.95),
        (25.9, 4, 4.2, "flute", None, 1.0),
        (30.4, 3, 1.3, "flute", None, 0.7),
        (31.9, 2, 1.6, "flute", None, 0.75),
        (33.7, 4, 3.3, "flute", 2, 0.9),
        (37.3, 5, 1.7, "sitar", None, 0.8),
        (39.2, 6, 1.6, "sitar", None, 0.85),
        (41.0, 7, 3.9, "sitar", 6, 1.0),
        (45.2, 6, 1.4, "flute", None, 0.75),
        (46.8, 5, 1.5, "flute", None, 0.8),
        (48.5, 4, 3.5, "flute", 5, 0.9),
        (52.4, 3, 1.6, "flute", None, 0.7),
        (54.2, 2, 1.7, "sitar", None, 0.8),
        (56.1, 4, 2.3, "sitar", None, 0.85),
        (58.7, 2, 1.5, "sitar", None, 0.7),
        (60.4, 1, 1.6, "sitar", None, 0.7),
        (62.2, 0, 4.4, "flute", 1, 0.9),
        (67.0, 2, 1.9, "flute", None, 0.7),
        (69.1, 1, 1.5, "flute", None, 0.65),
        (70.8, -1, 2.1, "flute", None, 0.6),
        (73.1, 0, 3.4, "flute", -1, 0.8),
    ]
    mel = _render_melody(n, NOTES, sa, S, 501, sitar_gain=0.85, flute_gain=1.0)
    mel = verb(mel, make_ir(5.5, 4.6, 81, damp=3400.0, predelay=0.04, er=9), 0.52)
    mix += setrms(mel, 0.14)

    mix = verb(mix, make_ir(3.4, 2.8, 83, damp=4200.0), 0.20)
    mix = apply_mag(mix, m_hp(f_, 32.0, 2) * m_tilt(f_, 1.0, 0.5, 800.0))
    return finalize(mix, headroom=0.66)


def gen_music_village(dur=60.0):
    n = int(dur * SR)
    rg = np.random.default_rng(8008)
    f_ = freqs(n)
    T = n / SR
    sa = 164.0
    S = BHAIRAV
    bpm = 72.0
    beat = 60.0 / bpm                      # 0.8333 s -> 72 beats in 60 s
    cycles = int(round(T / (8 * beat)))    # 9 cycles of 8

    mix = np.zeros((n, 2))
    mix += setrms(tanpura(n, sa, 222, period=1.25, buzz=0.5, spread=0.6), 0.080)

    t = np.arange(n) / SR
    shr = np.zeros((n, 2))
    for f0, a, p in ((sa * 0.5, 1.0, -0.35), (sa * 0.75, 0.55, 0.35), (sa, 0.35, 0.0)):
        for det in (-0.1, 0.1):
            shr += pan(np.sin(2 * np.pi * pf(f0 + det, T) * t + rg.uniform(0, 6.3)) * a,
                       p)
    mix += setrms(apply_mag(shr, m_lp(f_, 1200.0, 2)), 0.040)

    # ---- tabla: gentle 8-beat pulse --------------------------------------
    PAT = [("dha", 0.0, 0.82), ("te", 0.75, 0.22), ("dhin", 1.0, 0.72),
           ("na", 2.0, 0.62), ("te", 2.5, 0.24), ("dha", 3.0, 0.85),
           ("ge", 3.5, 0.40), ("dha", 4.0, 0.95), ("te", 4.75, 0.22),
           ("tin", 5.0, 0.68), ("na", 6.0, 0.58), ("ke", 6.5, 0.30),
           ("ta", 7.0, 0.66), ("te", 7.5, 0.26)]
    FILL = [("te", 6.25, 0.3), ("te", 6.75, 0.34), ("na", 7.25, 0.4),
            ("tin", 7.5, 0.45), ("te", 7.75, 0.32)]
    # The final cycle resolves onto sam, so the beats leading into the loop point
    # must be the busiest -- otherwise the bar empties out right before the seam.
    ENDFILL = [("te", 6.25, 0.30), ("na", 6.5, 0.50), ("te", 6.75, 0.34),
               ("tin", 7.0, 0.55), ("te", 7.25, 0.30), ("na", 7.5, 0.68),
               ("dha", 7.75, 0.86)]
    drum = np.zeros((n, 2))
    for c in range(cycles):
        if c == cycles - 1:
            pat = [p for p in PAT if p[1] < 6.0] + ENDFILL
        else:
            pat = PAT + (FILL if c % 4 == 3 else [])
        for i, (s, b, a) in enumerate(pat):
            y = tabla(s, 1200 + c * 53 + i, amp=a * rg.uniform(0.88, 1.0), tune=1.02)
            add_wrap(drum, (c * 8 + b) * beat * SR + rg.uniform(-0.006, 0.006) * SR,
                     pan(y, 0.18 if s in ("na", "tin", "ta", "te") else -0.18))
    drum = verb(drum, make_ir(1.8, 1.3, 85, damp=4000.0), 0.24)
    drum = compress(setrms(drum, 0.105), th=0.22, knee=0.09)
    mix += setrms(drum, 0.105)

    # ---- melody: 4 phrases sequenced over 9 cycles -----------------------
    A = [(0, 0, 1), (1, 1, 1), (2, 2, 2), (4, 1, 1), (5, 0, 1.5), (6.5, -1, 1.5)]
    B = [(0, 2, 1), (1, 3, 1), (2, 4, 2), (4, 3, 1), (5, 2, 1), (6, 1, 2)]
    C = [(0, 4, 1), (1, 5, 1), (2, 4, 1), (3, 3, 1), (4, 2, 2), (6, 0, 2)]
    D = [(0, 7, 1.5), (1.5, 6, 0.5), (2, 5, 1), (3, 4, 1), (4, 3, 1),
         (5, 2, 1), (6, 1, 1), (7, 0, 1)]
    # closing phrase: settles onto Sa and holds it across the loop point, so the
    # melody is continuous through the seam instead of stopping dead at it
    E = [(0, 2, 1), (1, 1, 1), (2, 0, 2), (4, -1, 1), (5, 0, 1), (6, 0, 2.6)]
    SEQ = [A, A, B, A, C, D, B, A, E]
    notes = []
    for c, ph in enumerate(SEQ):
        inst = "flute" if c in (2, 5, 6) else "sitar"
        for j, (b, d, ln) in enumerate(ph):
            # a melodic entry lands just *after* sam, not on top of it -- this is
            # idiomatic, and it stops a pluck transient stacking onto the drum
            # stroke at sample 0 (which is the loop boundary)
            t0 = (c * 8 + b) * beat + (0.055 if b == 0 else 0.0)
            dur = ln * beat * (1.35 if inst == "flute" else 1.7)
            gl = ph[j - 1][1] if (inst == "flute" and j > 0 and rg.random() < 0.35) else None
            vel = 0.95 if b == 0 else rg.uniform(0.68, 0.88)
            notes.append((t0, d, dur, inst, gl, vel))
    mel = _render_melody(n, notes, sa, S, 601, sitar_gain=1.0, flute_gain=0.9)
    mel = verb(mel, make_ir(3.2, 2.4, 87, damp=4200.0), 0.34)
    mix += setrms(mel, 0.135)

    mix = verb(mix, make_ir(2.4, 1.8, 89, damp=5000.0), 0.16)
    mix = apply_mag(mix, m_hp(f_, 34.0, 2) * m_tilt(f_, 1.5, 1.0, 800.0))
    return finalize(mix, headroom=0.66)


def gen_music_combat(dur=60.0):
    n = int(dur * SR)
    rg = np.random.default_rng(9009)
    f_ = freqs(n)
    T = n / SR
    sa = 98.0                              # low drone tonic
    mel_sa = sa * 2.0
    S = BHAIRAVI
    bpm = 133.0                            # 133 beats in 60 s = 19 cycles of 7
    beat = 60.0 / bpm
    cycles = 19

    mix = np.zeros((n, 2))
    t = np.arange(n) / SR

    # ---- aggressive low drone --------------------------------------------
    dro = np.zeros((n, 2))
    for f0, a, p in ((sa * 0.5, 1.0, 0.0), (sa, 0.75, -0.3), (sa * 1.5, 0.5, 0.3),
                     (sa * 2, 0.28, 0.15), (sa * 3, 0.14, -0.15)):
        for det in (-0.22, 0.22):
            ph = 2 * np.pi * pf(f0 + det, T) * t + rg.uniform(0, 6.3)
            dro += pan((np.sin(ph) + 0.3 * np.sin(2 * ph) + 0.12 * np.sin(3 * ph)) * a, p)
    dro = np.tanh(1.7 * setrms(dro, 0.35))                 # grit
    dro = apply_mag(dro, m_bp(f_, 34.0, 2600.0, 2))
    # pulse the drone on the 7-beat cycle
    cyc = 7 * beat
    dro *= (0.72 + 0.28 * (0.5 + 0.5 * np.cos(2 * np.pi * t / cyc)) ** 2)[:, None]
    mix += setrms(dro, 0.115)

    # ---- tense tremolo bowed layer ---------------------------------------
    tre = np.zeros((n, 2))
    for f0, a, p in ((mel_sa, 1.0, -0.55), (mel_sa * 1.5, 0.7, 0.55),
                     (mel_sa * 16 / 15, 0.32, 0.25)):
        src = apply_mag(noise(n, rg), m_res(f_, f0, 60.0) + 0.5 * m_res(f_, f0 * 2, 55.0)
                        + 0.25 * m_res(f_, f0 * 3, 45.0))
        trem = (0.5 + 0.5 * np.sin(2 * np.pi * pf(12.0, T) * t + rg.uniform(0, 6.3))) ** 1.5
        env = rand_env(n, 0.14, rg, 0.15, 1.0, 2.0)
        tre += pan(setrms(src, 1.0) * (0.35 + 0.65 * trem) * env * a, p)
    mix += setrms(tre, 0.058)

    # ---- driving tabla, 7-beat (3+2+2) -----------------------------------
    PAT = [("ge", 0.0, 1.0), ("na", 0.5, 0.45), ("te", 0.75, 0.30),
           ("dha", 1.0, 0.72), ("te", 1.5, 0.30), ("na", 1.75, 0.38),
           ("tin", 2.0, 0.60), ("te", 2.5, 0.28),
           ("ge", 3.0, 0.95), ("na", 3.5, 0.50), ("te", 3.75, 0.30),
           ("dha", 4.0, 0.68), ("te", 4.5, 0.30),
           ("ge", 5.0, 0.85), ("na", 5.5, 0.48), ("te", 5.75, 0.32),
           ("tin", 6.0, 0.70), ("te", 6.25, 0.26), ("na", 6.5, 0.44),
           ("te", 6.75, 0.34)]
    TIHAI = [("dha", 6.0, 1.0), ("te", 6.25, 0.5), ("na", 6.5, 0.8),
             ("te", 6.75, 0.5)]
    drum = np.zeros((n, 2))
    for c in range(cycles):
        pat = [p for p in PAT if not (c % 4 == 3 and p[1] >= 6.0)]
        pat = pat + (TIHAI if c % 4 == 3 else [])
        if c == cycles - 1:   # pickup that rings through the loop point
            pat = [p for p in pat if p[1] < 6.5] + [("na", 6.5, 0.6),
                                                    ("te", 6.625, 0.3),
                                                    ("dha", 6.75, 0.88)]
        for i, (s, b, a) in enumerate(pat):
            y = tabla(s, 1500 + c * 61 + i, amp=a * rg.uniform(0.9, 1.05), tune=1.06)
            add_wrap(drum, (c * 7 + b) * beat * SR + rg.uniform(-0.005, 0.005) * SR,
                     pan(y, 0.22 if s in ("na", "tin", "ta", "te") else -0.22))
    drum = verb(drum, make_ir(1.4, 1.0, 91, damp=5200.0), 0.20)
    drum = compress(setrms(drum, 0.135), th=0.30, knee=0.14)
    mix += setrms(drum, 0.135)

    # ---- urgent melodic riff ---------------------------------------------
    R1 = [(0, 0, 1), (1, 1, .5), (1.5, 2, .5), (2, 0, 1), (3, 3, 1),
          (4, 2, .5), (4.5, 1, .5), (5, 0, 1), (6, -2, 1)]
    R2 = [(0, 4, 1), (1, 3, .5), (1.5, 2, .5), (2, 4, 1), (3, 5, 1),
          (4, 4, .5), (4.5, 3, .5), (5, 2, 1), (6, 0, 1)]
    R3 = [(0, 0, .5), (.5, 2, .5), (1, 3, .5), (1.5, 4, .5), (2, 3, 1),
          (3, 2, .5), (3.5, 1, .5), (4, 0, 1), (5, 6, 1), (6, 4, 1)]
    R4 = [(0, 7, 1), (1, 6, .5), (1.5, 5, .5), (2, 4, 1), (3, 2, 1),
          (4, 3, .5), (4.5, 2, .5), (5, 1, 1), (6, 0, 1)]
    SEQ = [R1, R1, R2, R3, R1, R2, R4, R3, R1, R2, R1, R3,
           R4, R2, R1, R3, R2, R4, R1]
    notes = []
    for c, ph in enumerate(SEQ):
        for b, d, ln in ph:
            t0 = (c * 7 + b) * beat
            dur = ln * beat * 2.2
            vel = 1.0 if b == 0 else rg.uniform(0.6, 0.85)
            notes.append((t0, d, dur, "sitar", None, vel))
        if c % 6 == 5:                     # answering flute cry
            notes.append(((c * 7 + 5) * beat, 7, beat * 3.2, "flute", 5, 0.9))
    mel = _render_melody(n, notes, mel_sa, S, 701, sitar_gain=1.0, flute_gain=0.7)
    mel = verb(mel, make_ir(2.0, 1.5, 93, damp=5000.0), 0.26)
    mix += setrms(mel, 0.125)

    mix = verb(mix, make_ir(1.8, 1.3, 95, damp=5500.0), 0.12)
    mix = apply_mag(mix, m_hp(f_, 34.0, 2) * m_tilt(f_, 2.0, 1.5, 700.0))
    return finalize(mix, headroom=0.68)


def gen_music_night(dur=60.0):
    n = int(dur * SR)
    rg = np.random.default_rng(10010)
    f_ = freqs(n)
    T = n / SR
    sa = 110.0
    S = MALKAUNS

    mix = np.zeros((n, 2))
    # Malkauns has no Pa -- the tanpura is tuned to Ma (4/3) instead.
    dro = tanpura(n, sa, 333, cycle=[sa * 4 / 3 * 0.5, sa, sa, sa * 0.5],
                  period=1.5, buzz=0.45, spread=0.55)
    mix += setrms(dro, 0.085)

    t = np.arange(n) / SR
    shr = np.zeros((n, 2))
    for f0, a, p in ((sa * 0.5, 1.0, -0.3), (sa * 2 / 3, 0.5, 0.3), (sa, 0.30, 0.0)):
        for det in (-0.08, 0.08):
            shr += pan(np.sin(2 * np.pi * pf(f0 + det, T) * t + rg.uniform(0, 6.3)) * a, p)
    mix += setrms(apply_mag(shr, m_lp(f_, 900.0, 2)), 0.055)

    NOTES = [
        (1.0, 0, 5.0, "flute", None, 0.75),
        (7.4, 1, 3.6, "flute", 0, 0.7),
        (11.8, 0, 4.2, "sitar", None, 0.8),
        (17.2, -1, 4.6, "flute", None, 0.65),
        (23.2, 1, 3.2, "sitar", None, 0.75),
        (27.4, 2, 5.2, "flute", 1, 0.85),
        (33.6, 1, 3.0, "sitar", None, 0.7),
        (37.8, 3, 4.2, "flute", None, 0.8),
        (43.2, 2, 3.2, "sitar", None, 0.72),
        (47.4, 1, 3.6, "flute", 2, 0.7),
        (52.0, 0, 5.6, "flute", None, 0.8),
        (58.2, -1, 3.8, "sitar", None, 0.6),
    ]
    mel = _render_melody(n, NOTES, sa, S, 801, sitar_gain=0.9, flute_gain=1.0)
    mel = verb(mel, make_ir(6.0, 5.0, 97, damp=2800.0, predelay=0.05, er=10), 0.58)
    mix += setrms(mel, 0.115)

    # cold night air under the music
    mix += setrms(bed(n, rg, 40.0, 700.0, 2, mod_hz=0.05, mod_depth=0.5), 0.032)

    mix = verb(mix, make_ir(4.5, 3.8, 99, damp=3000.0), 0.24)
    mix = apply_mag(mix, m_hp(f_, 30.0, 2) * m_tilt(f_, 2.0, -1.5, 600.0))
    return finalize(mix, headroom=0.64)


def gen_sting_discovery(dur=5.0):
    n = int(dur * SR)
    rg = np.random.default_rng(11011)
    f_ = freqs(n)
    sa = 196.0
    S = YAMAN
    mix = np.zeros((n, 2))

    # rising accelerating flourish
    seq = [0, 1, 2, 3, 4, 5, 6, 7, 9, 11]
    t0 = 0.02
    gap = 0.115
    for i, d in enumerate(seq):
        f = deg(S, d, sa)
        y = sitar(f, min(2.6, dur - t0), 1300 + i * 9, amp=0.55 + 0.05 * i,
                  decay=0.9 + 0.06 * i, bright=0.72, pick=0.2, release=0.25)
        add_wrap(mix, t0 * SR, pan(y, -0.5 + i * 0.11))
        t0 += gap
        gap *= 0.86

    # bell at the top
    b = bell(deg(S, 14, sa), dur - 1.1, 1400, decay=1.35, strike=0.22)
    add_wrap(mix, 1.05 * SR, pan(setrms(b, 0.9), 0.0))

    # shimmer: high sine grains raining down
    sh = np.zeros((n, 2))
    for i in range(90):
        st = rg.uniform(0.9, 3.4)
        d = rg.uniform(0.10, 0.45)
        m = int(d * SR); tt = np.arange(m) / SR
        f = deg(S, int(rg.integers(14, 25)), sa) * rg.uniform(0.997, 1.003)
        y = np.sin(2 * np.pi * f * tt) * np.exp(-tt / (d * 0.34))
        y *= 1.0 - np.exp(-tt / 0.004)
        add_wrap(sh, st * SR, pan(y, rg.uniform(-1.0, 1.0)) * rg.uniform(0.2, 1.0))
    mix += setrms(sh, rms(mix) * 0.5)

    # warm low bloom
    t = np.arange(n) / SR
    low = np.zeros((n, 2))
    for f0, a, p in ((sa * 0.25, 1.0, 0.0), (sa * 0.375, 0.6, -0.3), (sa * 0.5, 0.4, 0.3)):
        e = (1.0 - np.exp(-t / 0.30)) * np.exp(-t / 2.4)
        low += pan(np.sin(2 * np.pi * f0 * t) * e * a, p)
    mix += setrms(low, rms(mix) * 0.55)

    mix = verb(mix, make_ir(3.0, 2.6, 101, damp=5000.0), 0.42, loop=False)
    mix = apply_mag(mix, m_hp(f_, 40.0, 2) * m_tilt(f_, 0.0, 2.0, 900.0))
    mix = finalize(mix, headroom=0.7)
    fade = min(int(0.45 * SR), n)
    mix[n - fade:] *= (np.linspace(1.0, 0.0, fade) ** 2.0)[:, None]
    mix[:64] *= np.linspace(0.0, 1.0, 64)[:, None]
    return mix


def gen_sting_quest(dur=4.0):
    n = int(dur * SR)
    rg = np.random.default_rng(12012)
    f_ = freqs(n)
    sa = 174.0
    S = BHAIRAV
    mix = np.zeros((n, 2))

    # warm resolving phrase: Pa -> Ga -> Re -> Sa, doubled flute + sitar
    PH = [(0.02, 4, 1.1, 0.9), (0.50, 2, 1.0, 0.85), (0.96, 1, 0.9, 0.8),
          (1.40, 0, 2.4, 1.0)]
    for i, (t0, d, ln, v) in enumerate(PH):
        f = deg(S, d, sa)
        y = sitar(f, min(ln + 1.4, dur - t0), 1600 + i * 5, amp=v * 0.9,
                  decay=(ln + 1.0) * 0.75, bright=0.6, pick=0.22, release=0.35)
        add_wrap(mix, t0 * SR, pan(y, -0.22 + 0.14 * i))
        fl = bansuri(f, min(ln + 0.9, dur - t0), 1700 + i * 5,
                     glide_from=deg(S, PH[i - 1][1], sa) if i else None,
                     glide_t=0.16, amp=v * 0.75, breath=0.3, vib=4.8, attack=0.07)
        add_wrap(mix, (t0 + 0.02) * SR, pan(fl, 0.18 - 0.12 * i))

    # gentle bell on the resolution
    b = bell(deg(S, 7, sa), dur - 1.5, 1800, decay=1.0, strike=0.10, lp=7000.0)
    add_wrap(mix, 1.42 * SR, pan(setrms(b, 0.55), 0.0))

    # sustained warm Sa+Pa pad
    t = np.arange(n) / SR
    pad = np.zeros((n, 2))
    for f0, a, p in ((sa * 0.5, 1.0, -0.35), (sa * 0.75, 0.55, 0.35),
                     (sa, 0.35, 0.0), (sa * 1.5, 0.2, 0.2)):
        for det in (-0.1, 0.1):
            e = (1.0 - np.exp(-t / 0.35)) * np.exp(-t / 2.6)
            pad += pan(np.sin(2 * np.pi * (f0 + det) * t + rg.uniform(0, 6.3)) * e * a, p)
    mix += setrms(pad, rms(mix) * 0.62)

    mix = verb(mix, make_ir(2.6, 2.2, 103, damp=4200.0), 0.36, loop=False)
    mix = apply_mag(mix, m_hp(f_, 40.0, 2) * m_tilt(f_, 1.5, 0.5, 800.0))
    mix = finalize(mix, headroom=0.7)
    fade = min(int(0.5 * SR), n)
    mix[n - fade:] *= (np.linspace(1.0, 0.0, fade) ** 2.0)[:, None]
    mix[:64] *= np.linspace(0.0, 1.0, 64)[:, None]
    return mix


# ===========================================================================
# verification
# ===========================================================================
def verify(path, looping):
    with wave.open(path, "rb") as w:
        ch, sw, sr, nf = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(nf)
    x = np.frombuffer(raw, dtype="<i2").astype(np.float64).reshape(nf, ch) / 32768.0

    peak = float(np.max(np.abs(x)))
    r = rms(x)
    dc = float(np.max(np.abs(x.mean(axis=0))))
    corr = 1.0
    if ch == 2:
        a, b = x[:, 0] - x[:, 0].mean(), x[:, 1] - x[:, 1].mean()
        corr = float(np.dot(a, b) / max(np.linalg.norm(a) * np.linalg.norm(b), 1e-12))

    d = np.abs(np.diff(x, axis=0))
    p999 = float(np.percentile(d, 99.9))
    dmax = float(d.max())
    seam_jump = float(np.max(np.abs(x[0] - x[-1])))
    head = rms(x[:1000])
    tail = rms(x[-1000:])
    bal = db(tail + 1e-12) - db(head + 1e-12)

    checks = []
    checks.append(("sr", sr == SR, f"{sr}"))
    checks.append(("16bit", sw == 2, f"{sw*8}bit"))
    checks.append(("stereo", ch == 2, f"{ch}ch"))
    checks.append(("peak~-3dB", abs(db(peak) - PEAK_DBFS) < 0.6, f"{db(peak):.2f}"))
    checks.append(("noclip", peak < 0.999, f"{peak:.4f}"))
    checks.append(("nodc", dc < 0.002, f"{dc:.5f}"))
    checks.append(("level", db(r) > -34.0, f"{db(r):.1f}"))
    if looping:
        # the wrap-point jump must sit inside the normal jump distribution
        checks.append(("seam", seam_jump <= max(3.0 * p999, 0.5 * dmax, 2e-3),
                       f"{seam_jump:.5f} vs p99.9 {p999:.5f}"))
        checks.append(("headtail", abs(bal) < 9.0, f"{bal:+.2f}dB"))
    else:
        checks.append(("endsilent", rms(x[-2000:]) < 0.004, f"{db(rms(x[-2000:])):.1f}"))
        checks.append(("startzero", abs(x[0]).max() < 0.02, f"{abs(x[0]).max():.4f}"))

    ok = all(c[1] for c in checks)
    return {
        "ok": ok, "checks": checks, "ch": ch, "sr": sr, "frames": nf,
        "dur": nf / sr, "peak": db(peak), "rms": db(r), "dc": dc,
        "corr": corr, "seam": seam_jump, "p999": p999, "bal": bal,
        "bytes": os.path.getsize(path),
    }


# ===========================================================================
# main
# ===========================================================================
JOBS = [
    ("amb_forest_day.wav", gen_forest_day, 30.0, True),
    ("amb_forest_night.wav", gen_forest_night, 30.0, True),
    ("amb_river.wav", gen_river, 30.0, True),
    ("amb_village.wav", gen_village, 30.0, True),
    ("amb_wind.wav", gen_wind, 30.0, True),
    ("amb_temple.wav", gen_temple, 30.0, True),
    ("music_explore.wav", gen_music_explore, 75.0, True),
    ("music_village.wav", gen_music_village, 60.0, True),
    ("music_combat.wav", gen_music_combat, 60.0, True),
    ("music_night.wav", gen_music_night, 60.0, True),
    ("sting_discovery.wav", gen_sting_discovery, 5.0, False),
    ("sting_quest.wav", gen_sting_quest, 4.0, False),
]


def main(argv):
    os.makedirs(OUT, exist_ok=True)
    sel = [a for a in argv[1:] if not a.startswith("-")]
    jobs = [j for j in JOBS if not sel or any(s in j[0] for s in sel)]

    rows = []
    failed = []
    for name, fn, dur, looping in jobs:
        p = os.path.join(OUT, name)
        t0 = time.time()
        x = fn(dur)
        write_wav(p, x)
        gen = time.time() - t0
        v = verify(p, looping)
        v["name"] = name
        v["gen"] = gen
        v["loop"] = looping
        rows.append(v)
        if not v["ok"]:
            failed.append(v)
        flag = "OK " if v["ok"] else "FAIL"
        print(f"[{flag}] {name:22s} {v['dur']:6.2f}s  peak {v['peak']:+6.2f}  "
              f"rms {v['rms']:+6.2f}  ({gen:5.1f}s)", flush=True)
        if not v["ok"]:
            for cn, cok, cv in v["checks"]:
                if not cok:
                    print(f"        !! {cn}: {cv}")

    print()
    print("=" * 118)
    print(f"{'FILE':24s} {'BYTES':>10s} {'CH':>3s} {'SR':>6s} {'DUR':>7s} "
          f"{'PEAK':>7s} {'RMS':>7s} {'DC':>8s} {'L/R':>6s} {'SEAM':>9s} "
          f"{'p99.9':>9s} {'H/T':>8s}  ST")
    print("-" * 118)
    for v in rows:
        print(f"{v['name']:24s} {v['bytes']:10d} {v['ch']:3d} {v['sr']:6d} "
              f"{v['dur']:6.2f}s {v['peak']:+7.2f} {v['rms']:+7.2f} "
              f"{v['dc']:8.5f} {v['corr']:+6.3f} {v['seam']:9.6f} "
              f"{v['p999']:9.6f} {v['bal']:+7.2f}  "
              f"{'PASS' if v['ok'] else 'FAIL'}")
    print("=" * 118)
    print("PEAK/RMS/H-T in dBFS or dB. SEAM = |x[0]-x[N-1]| at the loop wrap;")
    print("p99.9 = 99.9th percentile of |x[n]-x[n-1]| inside the file.")
    print("A seam at or below the internal jump distribution == click-free loop.")
    print(f"\n{len(rows) - len(failed)}/{len(rows)} passed.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
