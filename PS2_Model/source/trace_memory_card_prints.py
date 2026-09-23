"""Trace the "MagicGate" print of the memory card (a custom logotype with no public
vector and no matching font) from the frontal reference photo into polygon
outlines in card mm. ("8MB" / "MEMORY CARD" are plain Helvetica on the card, so
the build sets them in Helvetica: traces of them came out wobblier than the font.)

    python3 PS2_Model/source/trace_memory_card_prints.py      # needs opencv-python, numpy

Writes PS2_Model/source/memory_card_prints_traced.json, read by build_memory_card.py.

Method: the photo (PS2_Model/references/memory_card/memcard_top_forenti.jpg,
Forenti, CC BY-SA 3.0) is deskewed with the card's min-area rectangle, the card
bbox gives pixels per mm (width = 42 mm). Each print region is upscaled 8x
(bicubic), blurred, thresholded halfway between the body and ink luminance,
cleaned of specks, and its contours (outer + holes, even-odd) are simplified.
Coordinates: X right (0 = card centre), Z down the card from the connector
end (0 = end face), i.e. the model's top-view axes.
"""
import json
from pathlib import Path

import cv2
import numpy as np

REPO = Path(__file__).resolve().parents[2]
PHOTO = REPO / 'PS2_Model/references/memory_card/memcard_top_forenti.jpg'
OUT = REPO / 'PS2_Model/source/memory_card_prints_traced.json'
CARD_W = 42.0
UP = 8                     # upscale factor
EPS_MM = 0.02              # polygon simplification tolerance
SMOOTH_MM = 0.035          # gaussian smoothing of the contour along its length
# regions in card mm: (x0, x1, z0, z1)
REGIONS = {
    'print_magicgate': (-10.0, 10.0, 24.1, 26.4),
}


def smooth(pts, sigma):
    """Circular gaussian smoothing of a dense closed contour (removes JPEG /
    surface-grain wobble; corners round by about sigma)."""
    r = int(3 * sigma)
    if len(pts) < 2 * r + 1 or sigma <= 0:
        return pts
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma) ** 2)
    k /= k.sum()
    ext = np.concatenate([pts[-r:], pts, pts[:r]])
    return np.column_stack([np.convolve(ext[:, i], k, mode='valid') for i in (0, 1)])


def main():
    img = cv2.imread(str(PHOTO))
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY).astype(np.float32)
    # card = large dark blob on a light background
    mask = (gray < 80).astype(np.uint8)  # (the soft shadow below the card is ~110)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((15, 15), np.uint8))
    n, lab, stats, _ = cv2.connectedComponentsWithStats(mask)
    card = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    pts = np.column_stack(np.nonzero(lab == card)[::-1]).astype(np.float32)
    (cx, cy), (w, h), ang = cv2.minAreaRect(pts)
    while ang > 45:
        ang -= 90
        w, h = h, w
    while ang < -45:
        ang += 90
        w, h = h, w
    rot = cv2.getRotationMatrix2D((cx, cy), ang, 1.0)
    gray = cv2.warpAffine(gray, rot, (img.shape[1], img.shape[0]), flags=cv2.INTER_CUBIC,
                          borderMode=cv2.BORDER_REPLICATE)
    x0, y0 = cx - w / 2, cy - h / 2
    ppm = w / CARD_W
    print(f'deskew {ang:.2f} deg, card {w:.1f} x {h:.1f} px, {ppm:.2f} px/mm, '
          f'length {h / ppm:.2f} mm')

    out = {'source': str(PHOTO.relative_to(REPO)), 'px_per_mm': round(ppm, 3),
           'deskew_deg': round(ang, 3), 'eps_mm': EPS_MM, 'prints': {}}
    for name, (mx0, mx1, mz0, mz1) in REGIONS.items():
        px0, px1 = int(x0 + (mx0 + CARD_W / 2) * ppm), int(x0 + (mx1 + CARD_W / 2) * ppm)
        py0, py1 = int(y0 + mz0 * ppm), int(y0 + mz1 * ppm)
        crop = gray[py0:py1, px0:px1]
        big = cv2.resize(crop, None, fx=UP, fy=UP, interpolation=cv2.INTER_CUBIC)
        big = cv2.GaussianBlur(big, (0, 0), 0.7 * UP)
        bg, ink = np.percentile(big, 40), np.percentile(big, 99.5)
        bw = (big > (bg + ink) / 2).astype(np.uint8)
        k, lab, stats, _ = cv2.connectedComponentsWithStats(bw)
        keep = np.zeros_like(bw)
        biggest = stats[1:, cv2.CC_STAT_AREA].max()
        for i in range(1, k):
            if stats[i, cv2.CC_STAT_AREA] > 0.03 * biggest:
                keep[lab == i] = 1
        contours, _ = cv2.findContours(keep, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE)
        polys = []
        for c in contours:
            if cv2.contourArea(c) < 0.004 * biggest:
                continue
            c = smooth(c[:, 0, :].astype(np.float64), SMOOTH_MM * ppm * UP)
            c = cv2.approxPolyDP(c.astype(np.float32)[:, None, :], EPS_MM * ppm * UP,
                                 True)[:, 0, :].astype(np.float64)
            if len(c) < 3:
                continue
            X = (c[:, 0] / UP + 0.5 / UP + px0 - x0) / ppm - CARD_W / 2
            Z = (c[:, 1] / UP + 0.5 / UP + py0 - y0) / ppm
            polys.append([[round(a, 4), round(b, 4)] for a, b in zip(X, Z)])
        allp = np.array([p for poly in polys for p in poly])
        print(f'{name}: {len(polys)} contours, {len(allp)} points, bbox X '
              f'{allp[:, 0].min():.2f}..{allp[:, 0].max():.2f} Z {allp[:, 1].min():.2f}..'
              f'{allp[:, 1].max():.2f}')
        out['prints'][name] = polys
    OUT.write_text(json.dumps(out, separators=(',', ':')) + '\n')
    print('wrote', OUT)


main()
