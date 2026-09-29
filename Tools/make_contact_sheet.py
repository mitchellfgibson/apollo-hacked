#!/usr/bin/env python3
"""Compose a single contact-sheet preview of the NOOP brand pack."""
import os
from PIL import Image, ImageDraw, ImageFont
from make_icon import hx, NAVY_TOP, NAVY_BOT, GLOW
import numpy as np

SRC = os.path.expanduser('~/Downloads/noop-brand')
HNE = '/System/Library/Fonts/HelveticaNeue.ttc'
TEXT = hx('#F4F6F8'); SUB = hx('#AEB9C7'); MUT = hx('#7E8A9B')
HAIR = hx('#21304A')

def font(px, bold=True):
    idx = 1 if bold else 10  # HelveticaNeue: 1=Bold, 10=Medium (upright)
    try: return ImageFont.truetype(HNE, px, index=idx)
    except Exception:
        return ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf', px)

W, H = 1600, 2180
grad = np.empty((H, W, 3), float)
ys = np.linspace(0, 1, H)[:, None]
for c in range(3):
    grad[:, :, c] = NAVY_TOP[c] + (NAVY_BOT[c] - NAVY_TOP[c]) * ys
sheet = Image.fromarray(grad.astype(np.uint8)).convert('RGBA')
D = ImageDraw.Draw(sheet)

def label(x, y, s, px=26, color=SUB, bold=False):
    D.text((x, y), s, font=font(px, bold), fill=color + (255,))

def heading(x, y, s):
    label(x, y, s, 30, MUT, bold=True)

PAD = 80
# title
label(PAD, 54, 'NOOP', 64, TEXT, bold=True)
label(PAD + 200, 78, 'Brand Pack', 34, SUB)
label(PAD, 132, 'Titanium & Gold  ·  gold on navy  ·  v3.6', 24, MUT)
D.line([(PAD, 186), (W - PAD, 186)], fill=HAIR + (255,), width=2)

y = 220
# banner
heading(PAD, y, 'SUBREDDIT BANNER  ·  1920 × 384'); y += 44
ban = Image.open(f'{SRC}/subreddit-banner-1920x384.png').convert('RGBA')
bw = W - 2 * PAD; bh = int(bw * ban.height / ban.width)
sheet.alpha_composite(ban.resize((bw, bh), Image.LANCZOS), (PAD, y))
D.rectangle([PAD, y, PAD + bw, y + bh], outline=HAIR + (255,), width=2)
y += bh + 56

# row: app icon, avatar (circle), favicons
heading(PAD, y, 'APP ICON  ·  SUBREDDIT AVATAR  ·  FAVICONS'); y += 44
icon = Image.open(f'{SRC}/icon-1024.png').convert('RGBA').resize((300, 300), Image.LANCZOS)
sheet.alpha_composite(icon, (PAD, y))
label(PAD, y + 312, 'App icon  ·  1024', 22, MUT)
# avatar in circle crop (preview Reddit)
av = Image.open(f'{SRC}/subreddit-icon-256.png').convert('RGBA').resize((300, 300), Image.LANCZOS)
mask = Image.new('L', (300, 300), 0); ImageDraw.Draw(mask).ellipse([0, 0, 300, 300], fill=255)
ax = PAD + 360
sheet.paste(av, (ax, y), mask)
D.ellipse([ax, y, ax + 300, y + 300], outline=HAIR + (255,), width=2)
label(ax, y + 312, 'Avatar  ·  256  (circle)', 22, MUT)
# favicons
fx = ax + 360
for i, s in enumerate((48, 32, 16)):
    fv = Image.open(f'{SRC}/favicon-{s}.png').convert('RGBA')
    yy = y + i * 70
    sheet.alpha_composite(fv.resize((s, s), Image.LANCZOS), (fx, yy))
    label(fx + 70, yy + s // 2 - 12, f'{s}px', 22, MUT)
# transparent mark on light chip
mk = Image.open(f'{SRC}/mark-transparent-1024.png').convert('RGBA').resize((220, 220), Image.LANCZOS)
chip = fx + 260
D.rounded_rectangle([chip, y + 40, chip + 220, y + 260], 18, fill=hx('#F4F6F8') + (255,))
sheet.alpha_composite(mk, (chip, y + 40))
label(chip, y + 272, 'Mark on light', 22, MUT)
y += 360

# wordmark lockup
heading(PAD, y, 'WORDMARK LOCKUP'); y += 44
lk = Image.open(f'{SRC}/wordmark-lockup-navy.png').convert('RGBA')
lw = W - 2 * PAD; lh = int(lw * lk.height / lk.width)
sheet.alpha_composite(lk.resize((lw, lh), Image.LANCZOS), (PAD, y))
D.rectangle([PAD, y, PAD + lw, y + lh], outline=HAIR + (255,), width=2)
y += lh + 56

# OG + palette side by side
heading(PAD, y, 'SOCIAL / OG  ·  1200 × 630'); y += 44
og = Image.open(f'{SRC}/og-social-1200x630.png').convert('RGBA')
ow = 760; oh = int(ow * og.height / og.width)
sheet.alpha_composite(og.resize((ow, oh), Image.LANCZOS), (PAD, y))
D.rectangle([PAD, y, PAD + ow, y + oh], outline=HAIR + (255,), width=2)

# palette swatches (right column)
px0 = PAD + ow + 50
heading(px0, y - 44, 'PALETTE')
swatches = [
    ('#E8B84B', 'Gold'), ('#FCEBA8', 'Gold light'), ('#C8902F', 'Gold deep'),
    ('#0A1322', 'Navy top'), ('#05080F', 'Navy base'), ('#17263E', 'Glow'),
    ('#F4F6F8', 'Text'), ('#AEB9C7', 'Text 2'), ('#21304A', 'Hairline'),
]
sw = 70; gap = 16; cols = 3
for i, (hexv, name) in enumerate(swatches):
    r, c = divmod(i, cols)
    sx = px0 + c * (sw + 130)
    sy = y + r * (sw + 34)
    D.rounded_rectangle([sx, sy, sx + sw, sy + sw], 12, fill=hx(hexv) + (255,), outline=HAIR + (255,), width=1)
    label(sx + sw + 12, sy + 8, name, 20, TEXT)
    label(sx + sw + 12, sy + 36, hexv.upper(), 18, MUT)
# type sample
ty = y + 3 * (sw + 34) + 14
label(px0, ty, 'Helvetica Neue', 30, TEXT, bold=True)
label(px0, ty + 42, 'Offline. On-device. Yours.', 24, SUB)
label(px0, ty + 78, 'AaBbCc 0123 — recovery · strain', 20, MUT)
y += oh + 50

D.line([(PAD, y), (W - PAD, y)], fill=HAIR + (255,), width=2)
label(PAD, y + 18, 'All assets → ~/Downloads/noop-brand/', 22, MUT)
label(PAD, y + 50, 'Mark: open gold recovery ring + solid gold core on deep navy.', 22, SUB)

out = f'{SRC}/contact-sheet.png'
sheet.convert('RGB').save(out)
print('wrote', out, sheet.size)
