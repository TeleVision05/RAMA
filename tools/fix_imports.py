#!/usr/bin/env python3
"""Force correct Godot import settings on the generated assets.

Godot's defaults leave mipmaps OFF, which makes tiled terrain textures alias into
noise at any distance, and leave normal maps unflagged. Audio loop points are also
off by default, which makes every ambience bed click once per loop.
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEX = os.path.join(ROOT, "assets", "textures")
AUD = os.path.join(ROOT, "assets", "audio")

# Alpha-cutout atlases: keep them lossless so the leaf silhouettes stay crisp.
CUTOUT = ("leaf_", "grass_blades", "flowers")

def set_kv(text, key, value):
    pat = re.compile(rf"^{re.escape(key)}=.*$", re.M)
    if pat.search(text):
        return pat.sub(f"{key}={value}", text)
    return text.rstrip() + f"\n{key}={value}\n"

changed = 0
for name in sorted(os.listdir(TEX)):
    if not name.endswith(".png.import"):
        continue
    path = os.path.join(TEX, name)
    base = name[:-len(".png.import")]
    s = open(path).read()
    orig = s
    s = set_kv(s, "mipmaps/generate", "true")
    is_cutout = any(base.startswith(c) or base == c for c in CUTOUT)
    is_normal = base.endswith("_normal")
    is_data = base.endswith("_rough") or base == "detail_noise"
    if is_cutout:
        s = set_kv(s, "compress/mode", "0")          # lossless: alpha edges matter
        s = set_kv(s, "process/fix_alpha_border", "true")
    else:
        # VRAM compressed, but NOT high_quality: that forces BPTC (BC7), which Apple
        # GPUs do not support, and the texture then fails to load at runtime.
        s = set_kv(s, "compress/mode", "2")
        s = set_kv(s, "compress/high_quality", "false")
    s = set_kv(s, "compress/normal_map", "1" if is_normal else "0")
    if is_normal or is_data:
        s = set_kv(s, "detect_3d/compress_to", "0")
    if s != orig:
        open(path, "w").write(s)
        changed += 1

LOOPING = ("amb_", "music_", "fire_crackle", "water_lap")
aud = 0
for name in sorted(os.listdir(AUD)):
    if not name.endswith(".wav.import"):
        continue
    path = os.path.join(AUD, name)
    base = name[:-len(".wav.import")]
    s = open(path).read()
    orig = s
    loop = any(base.startswith(p) for p in LOOPING)
    s = set_kv(s, "edit/loop_mode", "1" if loop else "0")
    s = set_kv(s, "edit/normalize", "false")
    # Music and ambience are long; keep them compressed to save memory.
    s = set_kv(s, "force/max_rate", "false")
    if s != orig:
        open(path, "w").write(s)
        aud += 1

print(f"textures fixed: {changed}   audio fixed: {aud}")
