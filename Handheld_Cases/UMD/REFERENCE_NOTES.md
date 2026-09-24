# PSP UMD case (NTSC-U) — reference notes

Every dimension / colour used by `source/build_umd_case.py`, with its source and confidence.
Grades: **measured-model** (read from the app's own asset files), **multi-source** (≥2 independent
listings agree), **photo-scaled** (scaled from a photo using a known dimension, ±2–3 mm),
**estimate** (structural / engineering guess). Researched 2026-09-23.

## Sources

| # | Source | Used for |
|---|---|---|
| S1 | `Handheld_Cases/RESEARCH.md` §3 (Wikipedia UMD 177 × 104 × 14; Walvis 105 × 176 × 15; CheckOutStore 104 × 178 × 15; ZedLabz ≈ 110 × 180 × 14) | outer size |
| S2 | CheckOutStore / Mediaxpo "Replacement Game Cases compatible with Clear Playstation PSP UMD" — "104mm x 178mm x 15mm", polypropylene, clear outer sleeve, interior clips. https://www.checkoutstore.com/products/replacement-game-cases-compatible-with-clear-playstation-psp-umd | size, material, colour; product photos (open case, inside) |
| S3 | ZedLabz PSP replacement case: "18cm x 11cm x 1.4cm approx.", clips for manual and UMD. https://www.zedlabz.com/products/zedlabz-compatible-replacement-retail-game-disc-storage-case-for-sony-psp-2-pack-clear | size, layout (photo) |
| S4 | LDBmart "50 PSP UMD game case w/ sleeve, super clear" — case 6 15/16″ × 4″ × 1/2″ spine, **sleeve 8 3/8″ × 6 9/16″**, literature clip on the left panel. https://store.ldbmart.com/50umdgacawsl.html | insert wrap width, clip side |
| S5 | libretro-thumbnails `Sony_-_PlayStation_Portable/Named_Boxarts` — 23 random (USA) front scans: width/height median **0.5793** (cluster 0.5759–0.5805; 3 outliers 0.588–0.616 are cropped scans) | insert front aspect |
| S6 | `DuoDS/Resources/PSP-UMD-Shell.usdz`, `PSP-UMD.usdz` (read with pxr / Blender import) | UMD outline, thickness, hub opening, orientation |
| S7 | `DuoDS/App/GameLibrary.swift` `umdScene(for:)` — ×700, `eulerAngles.y = .pi`, "The authored label face is -Z; +Z is the optical/read face" | UMD axis convention |
| S8 | Photo `references/psp_case_open_mediaxpo.jpg` (= S2 product image 1, 1751 × 1819) and crop `references/psp_case_cradle_crop.png` | inside layout |

Searched without success: The Cover Project PSP template (site returns 403), uncovered.name
template list (login), DeviantArt PSP templates (pixel sizes only, no physical size), iFixit
"Repairing a PSP UMD Case" (it is about the UMD shell, not the keep case).

## Case

| Item | Value | Grade / source |
|---|---|---|
| Outer size W × H × T | 104 × 177 × 14.5 mm, portrait | multi-source S1–S4 (range 104–110 × 176–180 × 12.7–15) |
| Material / colour | clear PP; modelled #C8DBE1 at opacity 0.28 (slight blue-grey so edges read) | S2 "Clear", "Polypropylene"; colour = photo approximation |
| Outer film | clear, over front, spine and back, open at the free edges; #FAFAFA, opacity 0.05, 0.15 mm | S2/S3 "clear outer sleeve"; values as the PS2 case |
| Wall thickness | 1.2 mm; plastic 0.45 mm inside the film | estimate (thin-wall PP keep case) |
| Hinge | double living hinge on the outer spine corners, book style, spine on the left from the front | RESEARCH §3; photo S8 (two hinge lines) |
| Free-edge corner radius | 3.0 mm outer, 1.7 mm inner | photo S8 / estimate |
| Closure snaps | 2 per edge at y = 17 and 160 mm (lid tab hooks under a tray nub) | photo-scaled S8 (small features 16 mm from top/bottom on both free edges); tab/nub shape = estimate |
| Manual clip | lid (left half when open), middle of the free edge; tongue 17.1 × 14 × 0.8 mm, 1.4 mm under the lid floor, raised grip pad 10 × 6 mm | position: photo S8 + S4 ("literature clip on the left panel"); size photo-scaled ±3 mm |
| Plastic prints | only molded "UMD" text in the cradle (15 × 5 mm, 16 mm above the boss); no banner | photo S8 (reads "UMD" + an unreadable small line, omitted) |

## UMD cradle (tray, right half when open)

| Item | Value | Grade / source |
|---|---|---|
| UMD outline | convex hull of `PSP-UMD-Shell.usdz`: top semicircle r 32, straight sides x ±32 down to y ≈ −22, r≈3 corners, shallow bottom arc to y −33; thickness 4.2 (z ±2.1) | measured-model S6 |
| UMD orientation in the case | upright (round end up), label up (toward the lid) | photo S8: rim arc at the top, flatter end with corners at the bottom; "UMD" floor text upright |
| Cradle centre (anchor) | x 0, y 93.0 mm (rim outer 49 mm from the top, 120 mm from the top; photo 48.7 / 120.4) | photo-scaled S8 (vertical scale 6.92 px/mm from the 177 mm height; x from the tray centre, perspective-limited ±3 mm) |
| Rim | inner = UMD outline + 0.4 mm play, 2.4 mm wide, top at z −1.4 (4.2 mm above the floor), 0.4 mm bevel; overall ≈ 70.6 mm tall (photo 71.7) | photo-scaled S8; play = estimate |
| Finger scoops | left and right mid-height, lens-shaped, 3 mm deep, ≈ 19 mm long | photo S8 (curved recesses at mid-height on both sides) |
| Snap tabs | top and bottom centre in 8 mm rim slots; post 5.6 × 1.2 mm, lip hangs 1.0 mm over the UMD edge 0.15 mm above its label face | photo S8 (small hooks in rim gaps top and bottom); sizes estimate |
| Support rails | x ±15 mm, 1.4 mm wide, 0.75 mm high, run the height of the cradle | photo-scaled S8 (two vertical ribs) |
| Locating boss | Ø10 mm, 0.35 mm into the UMD's Ø18 hub opening, 0.18 mm clear of the steel hub | photo-scaled S8 (Ø ≈ 10); hub opening measured-model S6 (read-side cover inner radius 9.0, hub top at UMD z +1.57) |
| Spring tongue | U-slot 0.8 mm wide around the boss, r 7, legs 16 mm down; three curved ribs below the boss | photo S8 |
| UMD rest height | read face 0.8 mm above the tray floor (z −4.8), label face at z −0.6; anchor z −2.7 | estimate, verified collision-free |

## Insert (paper cover)

| Item | Value | Grade / source |
|---|---|---|
| Full wrap | 213.0 mm | S4 sleeve 8 3/8″ = 212.7 mm (listing for a 1/2″-spine case); within 0.3 mm |
| Spine | 14.0 mm | case 14.5 minus 2 × film/plastic offsets; estimate (±0.5) |
| Front = back | 99.5 mm | (213 − 14) / 2 |
| Height | 172.0 mm | 99.5 / 0.5793 = 171.8 (S5 median aspect); case height 177 minus 2.5 mm per side, as other keep cases (PS2 3.5, DS 3). S4's second number 6 9/16″ = 166.7 mm conflicts and is not used (it would give a 96.6 mm front at the scanned aspect, leaving 5 mm at the free edge) |
| u_splits | [99.5/213, 113.5/213] = [0.467136, 0.532864] | derived |
| Placement | insert y 2.5…174.5 mm; fold on the outer spine corners; free edges at x = 47.5 mm | derived |
| Banner | black top bar with "PSP" logo is printed on the insert, drawn by the app (RESEARCH §3) | not modelled on the plastic |
| Default colour | `COVER_ART_default` #EDEDED; paper reverse #F2F1EB | as PS2 / estimate |
