# Research notes (2026-09-23) — US retail DS / 3DS / PSP UMD cases and cover sources

"Measured" = scaled from Wikimedia Commons photos or GameTDB scans (±2–3 mm).
Surprises: US DS cases are opaque dark grey/black (clear ones are EU and thicker); DS and 3DS cases
are LANDSCAPE (wider than tall); the DS/3DS "NINTENDO DS/3DS" banner is a VERTICAL white strip printed
on the paper insert (DS: front panel, left, next to the spine; 3DS: front panel, far right). Only PSP
has a top horizontal banner.

## 1. US DS case (NTR, ~2005–2014)
- Size W×H×T: Wikipedia Keep case 135 × 122 × 15 mm (NA/JP; EU is 135×122×20 clear). Walvis 136×124×19
  (EU thick), insert height 118. Amaray 135×125, insert height 118. Mediaxpo VGBR14DS: 14 mm thick.
  Model: 135 × 122 × 14.5 mm.
- Colour: opaque dark grey/near-black PP ("The standard US case is black" — Nintendo World Report).
  Exceptions: DSi-only white, some Mario red (2010+).
- Clear outer film over the whole exterior (front, spine, back), open at top and bottom edges; the
  paper insert slides in there.
- Insert (back + spine + front): The Cover Project template front/back 5.117″ × 4.567″ = 130.0 × 116.0 mm.
  From GameTDB full scans (1616×680): full wrap ≈ 276 × 116 mm, spine ≈ 15.7 mm.
  Front-left white banner strip ("NINTENDO DS", vertical) ≈ 18 mm wide. Spine: white DS logo on top, title below.
- Hinge/opening: book style, spine on the left seen from the front; front cover opens to the left. Flat
  spine panel with a living hinge on each side (normal keep case). Two clips on the inside of the
  opening edge.
- Inside (Commons photo, coordinates from hinge edge / top edge):
  - Left half (inside of front cover): 2 manual clips near the free edge, ≈18 mm from top and bottom;
    molded "Nintendo" oval in the centre.
  - Right half (tray inside back cover): GBA slot recess ≈58 × 34 mm outer, x 28–86 mm from hinge,
    y 8–42 mm from top. DS card holder outer ≈47 × 47 mm, pocket ≈33 × 35 mm, centre ≈56 mm from hinge,
    78 mm from top; a push-release tab with a triangle to its right. Molded vertical "NINTENDO DS" near
    the right edge.
  - Molded on plastic: only inner "Nintendo"/"NINTENDO DS" logos and PP "5" recycling mark on the spine.
  - Nov 2010+ "eco" case (first: Mario vs. Donkey Kong: Mini-Land Mayhem): no GBA slot, cut-out
    recycling logo behind the manual.
- Paper: white banner strip, ESRB rating, barcode, "NTR-P-A2DE-USA" code.
  Source photo: https://commons.wikimedia.org/wiki/File:Nintendo_DS_game_case_(NA_type)_(inside_empty).jpg

## 2. US 3DS case (CTR)
- Size: Wikipedia 135 × 122 × 12 mm; Walvis 136×124×12.5 (insert height 118); CheckOutStore
  136×123×12.5; ZedLabz 13.7×12.5×1.2–1.3 cm "NA thin spine". Model: 135 × 122 × 12 mm.
- Colour: white opaque PP (some Mario red). NA New-3DS-only games also white. EU is black and 14 mm.
- Insert: same template proportions as DS, full wrap ≈ 276 × 116 mm, spine ≈ 12 mm. Vertical white
  banner strip on the front panel's FAR RIGHT, ≈13–15 mm wide. Spine: white, 3DS logo, game icon, title,
  Nintendo logo at the bottom. 4 banner variants (white/black, with/without Nintendo Network corner):
  https://commons.wikimedia.org/wiki/File:Nintendo_3DS_case_banners.png
- Inside: like DS; 2 manual clips on the left; ONE card holder on the right, roughly centre-right; no
  GBA slot. Molded Nintendo and 3DS logos inside (medium confidence).

## 3. US PSP UMD case
- Size: Wikipedia UMD 177 × 104 × 14 mm; Walvis 105×176×15; CheckOutStore 104×178×15; ZedLabz ≈110×180×14.
  Model: 104 × 177 × 14.5 mm (PORTRAIT).
- Colour: clear PP ("Clear" per Wikipedia Keep case; sellers "OEM colour match"). Clear outer film over the insert.
- Insert (estimate): libretro front 512:884 = 0.579 matches the case. Front ≈ 100 × 172 mm,
  full wrap ≈ 214 × 172 mm (no authoritative source).
- Banner: black horizontal top bar on the paper insert, "PSP" logo left, PlayStation logo right
  (GTA:LCS US cover).
- Inside (low confidence, ZedLabz photos): UMD-shaped cradle on the right half, roughly centred, a centre
  locating post and two tabs top and bottom; 1 manual clip on the left, middle of the edge.

## 4. Media (verified)
- DS card 33 × 35 × 3.8 mm, 3.5 g. 3DS card 33–35 (incl. key tab) × 35 × 3.8 mm.
- UMD shell 64 × 65 × 4.2 mm, disc Ø60 mm (ECMA-365).

## 5. GameTDB (DS / 3DS covers)
- Template: `https://art.gametdb.com/{ds|3ds}/{type}/{REGION}/{ID}.{jpg|png}`; ID = 4-char game code,
  case-sensitive upper (lowercase 404). DS: header 0x0C (A2DE). 3DS: from product code "CTR-P-AMKE"
  (NCCH 0x150) → AMKE.
- Regions: US, EN, JA, FR, DE, ES, IT, NL, PT, RU, KO… Fallback US → EN → others.
- Verified sizes (HTTP 200): cover 160×144 jpg; coverM 400×352; coverHQ 768×680 (not always: IPKE 1768×1595);
  coverS 128×115 png (3DS 404); coverfull 340×144; coverfullM 856×352; coverfullHQ 1616×680 jpg (back+spine+front);
  box (3D render) 240×216 png.
- coverfullHQ 200 for AREE, ECDE, AJRE (3DS) and IPKE, ADAE, AMCE (DS). A2DP (EN) 200. A2DJ/AMKJ (JA)
  coverHQ 404 but cover/coverM 200. AMKP (EN) coverfullHQ 404.
- coverfullHQ horizontal splits (±3 px): DS back 0–764, spine 764–856, front 856–1616;
  3DS back 0–777, spine 777–847, front 847–1616.
- Cache-Control max-age 30 days, ETag. Fetch on demand and cache; do not bundle.

## 6. PSP covers
- GameTDB has no PSP. xlenore/psp-covers does not exist.
- libretro-thumbnails: front only (1775 images), keyed by Redump name:
  `https://thumbnails.libretro.com/Sony%20-%20PlayStation%20Portable/Named_Boxarts/<url-encoded name>.png`
  (raw.githubusercontent mirror works too). Verified "Grand Theft Auto - Liberty City Stories (USA)
  (En,Fr,De,Es,It) (v1.05).png" 200, 512×884.
  Serial → name: libretro-database `metadat/redump/Sony - PlayStation Portable.dat` has `serial "ULUS-10041"`.
  Replace `&*/:\`<>?\|` in names with `_` (libretro convention; untested).
- Keyless front+back by serial: none found. ScreenScraper (box-2D, box-2D-back, box-texture; PSP system 61)
  needs a dev account (403 without); TheGamesDB needs an API key (418).
