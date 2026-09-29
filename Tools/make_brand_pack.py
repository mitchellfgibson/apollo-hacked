#!/usr/bin/env python3
"""NOOP brand pack — Titanium & Gold v3.6 "gold on navy".

Builds the full asset set (app icons, subreddit avatar + banner, wordmark
lockups, social/OG image, favicons, transparent mark) + a contact sheet, all
from the shipping app-icon mark. Output: ~/Downloads/noop-brand/.
"""
import os, math
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from make_icon import render as render_icon, hx, NAVY_TOP, NAVY_BOT, GLOW, GOLD_LIGHT, GOLD, GOLD_DEEP, grade

OUT = os.path.expanduser('~/Downloads/noop-brand')
os.makedirs(OUT, exist_ok=True)
TEXT = hx('#F4F6F8')   # off-white (StrandPalette.textPrimary)
SUB  = hx('#AEB9C7')   # secondary text
HNE  = '/System/Library/Fonts/HelveticaNeue.ttc'

def font(px, bold=True):
    # HelveticaNeue.ttc faces: 0=Regular 1=Bold 10=Medium (upright — avoid italics).
    idx = 1 if bold else 10
    try: return ImageFont.truetype(HNE, px, index=idx)
    except Exception:
        return ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf', px)

def navy_bg(W, H):
    grad = np.empty((H, W, 3), float)
    ys = np.linspace(0, 1, H)[:, None]
    for c in range(3):
        grad[:, :, c] = NAVY_TOP[c] + (NAVY_BOT[c] - NAVY_TOP[c]) * ys
    yy, xx = np.mgrid[0:H, 0:W]
    d = np.sqrt((xx - W * 0.5) ** 2 + (yy - H * 0.30) ** 2)
    glow = np.clip(1 - d / (max(W, H) * 0.85), 0, 1) ** 2.0
    for c in range(3):
        grad[:, :, c] = np.clip(grad[:, :, c] + glow * GLOW[c] * 0.5, 0, 255)
    return Image.fromarray(grad.astype(np.uint8), 'RGB').convert('RGBA')

def draw_mark(D, cx, cy, r, ring_w_frac=0.27):
    """Draw the gold open ring + core, centred at (cx,cy) with outer radius r."""
    ring_w = r * 2 * ring_w_frac
    center_r = r - ring_w / 2
    core_r = r * 0.23
    seg = ring_w / 2
    n = 1300
    for i in range(n + 1):
        t = i / n
        a = math.radians(241.0 + (-302.0) * t)
        x, y = cx + center_r * math.cos(a), cy + center_r * math.sin(a)
        D.ellipse([x - seg, y - seg, x + seg, y + seg], fill=tuple(int(v) for v in grade(t)) + (255,))
    D.ellipse([cx - core_r, cy - core_r, cx + core_r, cy + core_r], fill=GOLD + (255,))

def mark_transparent(S):
    SS = 4; W = S * SS
    img = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    draw_mark(ImageDraw.Draw(img), W / 2, W / 2, 0.42 * W)
    return img.resize((S, S), Image.LANCZOS)

def text_w(d, s, f):
    b = d.textbbox((0, 0), s, font=f); return b[2] - b[0], b[3] - b[1]

def wordmark(D, x, y, px, color=TEXT, track=0.06):
    """Draw 'NOOP' with letter-spacing; returns total width."""
    f = font(px, bold=True)
    cx = x
    sp = int(px * track)
    for ch in 'NOOP':
        D.text((cx, y), ch, font=f, fill=color + (255,))
        w, _ = text_w(D, ch, f)
        cx += w + sp
    return cx - x - sp

# ---- 1. app icons (from the shipping mark) ----
ic = render_icon(1024, 1.0)
ic.save(f'{OUT}/icon-1024.png')
ic.resize((512, 512), Image.LANCZOS).save(f'{OUT}/icon-512.png')
ic.resize((256, 256), Image.LANCZOS).save(f'{OUT}/icon-256.png')

# ---- 2. subreddit avatar (256, circle-safe: ring sits inside the circle) ----
render_icon(256, 0.84).save(f'{OUT}/subreddit-icon-256.png')

# ---- 3. transparent mark (overlays / dark or light) ----
mark_transparent(1024).save(f'{OUT}/mark-transparent-1024.png')

# ---- 4. favicons ----
for s in (16, 32, 48):
    render_icon(s, 0.84).save(f'{OUT}/favicon-{s}.png')

# ---- 5. wordmark lockup (mark + NOOP), transparent + on-navy ----
def lockup(on_navy):
    W, H, SS = 1600, 480, 2
    base = navy_bg(W * SS, H * SS) if on_navy else Image.new('RGBA', (W * SS, H * SS), (0, 0, 0, 0))
    D = ImageDraw.Draw(base)
    mr = H * SS * 0.40
    mcx = W * SS * 0.30
    draw_mark(D, mcx, H * SS / 2, mr)
    px = int(H * SS * 0.46)
    f = font(px, bold=True)
    _, th = text_w(D, 'NOOP', f)
    wordmark(D, mcx + mr + H * SS * 0.14, H * SS / 2 - px * 0.62, px)
    return base.resize((W, H), Image.LANCZOS)
lockup(False).save(f'{OUT}/wordmark-lockup-transparent.png')
lockup(True).save(f'{OUT}/wordmark-lockup-navy.png')

# ---- 6. subreddit banner (1920x384) ----
def banner():
    W, H, SS = 1920, 384, 2
    img = navy_bg(W * SS, H * SS)
    D = ImageDraw.Draw(img)
    # faint oversized ring watermark, right side
    wm = Image.new('RGBA', (W * SS, H * SS), (0, 0, 0, 0))
    draw_mark(ImageDraw.Draw(wm), W * SS * 0.86, H * SS * 0.5, H * SS * 0.66)
    img = Image.alpha_composite(img, wm.point(lambda p: int(p * 0.10) if p else 0))
    D = ImageDraw.Draw(img)
    # mark + wordmark, left
    mr = H * SS * 0.34
    mx = W * SS * 0.085 + mr
    draw_mark(D, mx, H * SS * 0.40, mr)
    px = int(H * SS * 0.34)
    wordmark(D, mx + mr + W * SS * 0.02, H * SS * 0.40 - px * 0.62, px)
    # tagline
    tf = font(int(H * SS * 0.105), bold=False)
    D.text((mx - mr, H * SS * 0.74), 'Offline.  On-device.  Yours.', font=tf, fill=SUB + (255,))
    return img.resize((W, H), Image.LANCZOS)
banner().save(f'{OUT}/subreddit-banner-1920x384.png')

# ---- 7. social / OG image (1200x630) ----
def og():
    W, H, SS = 1200, 630, 2
    img = navy_bg(W * SS, H * SS)
    D = ImageDraw.Draw(img)
    mr = H * SS * 0.21
    draw_mark(D, W * SS / 2, H * SS * 0.34, mr)
    px = int(H * SS * 0.165)
    f = font(px, bold=True)
    tw, _ = 0, 0
    # measure NOOP width for centring
    sp = int(px * 0.06); total = 0
    for ch in 'NOOP':
        w, _ = text_w(D, ch, f); total += w + sp
    total -= sp
    wordmark(D, W * SS / 2 - total / 2, H * SS * 0.55, px)
    tf = font(int(H * SS * 0.052), bold=False)
    tag = 'A free, offline companion for your WHOOP strap.'
    tw, _ = text_w(D, tag, tf)
    D.text((W * SS / 2 - tw / 2, H * SS * 0.74), tag, font=tf, fill=SUB + (255,))
    return img.resize((W, H), Image.LANCZOS)
og().save(f'{OUT}/og-social-1200x630.png')

print('brand pack written to', OUT)
print('\n'.join('  ' + f for f in sorted(os.listdir(OUT)) if f.endswith('.png')))
