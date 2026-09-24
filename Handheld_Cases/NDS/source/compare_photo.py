"""Side-by-side check against the reference photo (plain python3 + Pillow, not Blender).

    python3 Handheld_Cases/NDS/source/compare_photo.py

Reads references/nds_case_na_inside_empty.jpg and renders/case_open_photo_view.png
(written by build_nds_case.py) and writes renders/compare_photo.png: the two full views
stacked, then the same detail crops (GBA bracket, DS holder, manual clip) side by side.
Detail boxes are given in the photo's 1920 x 956 pixel frame and mapped into the render
by per-part offsets fitted by eye (the camera match is approximate).
"""
from pathlib import Path

from PIL import Image, ImageDraw

ASSET = Path(__file__).resolve().parents[1]
photo = Image.open(ASSET / 'references/nds_case_na_inside_empty.jpg').convert('RGB').resize((1920, 956))
render = Image.open(ASSET / 'renders/case_open_photo_view.png').convert('RGB').resize((1920, 956))

DETAILS = [('GBA bracket', (1150, 120, 1600, 380)), ('DS card holder', (1180, 400, 1600, 730)),
           ('manual clip (lid)', (200, 170, 470, 300))]
W = 1920
rows = [photo, render]
for name, box in DETAILS:
    a, b = photo.crop(box), render.crop(box)
    s = min(940 / a.width, 420 / a.height)
    a = a.resize((int(a.width * s), int(a.height * s)))
    b = b.resize(a.size)
    row = Image.new('RGB', (W, a.height + 30), (30, 30, 30))
    row.paste(a, (10, 30))
    row.paste(b, (W - 10 - b.width, 30))
    ImageDraw.Draw(row).text((12, 8), f'{name}: photo (left) | render (right)', fill=(230, 230, 230))
    rows.append(row)
out = Image.new('RGB', (W, sum(r.height for r in rows) + 10 * len(rows)), (30, 30, 30))
y = 0
for i, r in enumerate(rows):
    out.paste(r, (0, y))
    if i < 2:
        ImageDraw.Draw(out).text((12, y + 8), ['reference photo (Multicherry, CC BY-SA 4.0)',
                                              'render, same framing'][i], fill=(255, 80, 80))
    y += r.height + 10
out.save(ASSET / 'renders/compare_photo.png')
print(ASSET / 'renders/compare_photo.png')
