# Handheld retail cases — shared contract (NDS / 3DS / PSP UMD, US retail)

Three runtime assets, built like the PS2 case (`PS2_Disc_Case/source/build_case.py`, read its README):
procedural Blender Python, exported to USDZ, loaded by SceneKit, opened in Cover Flow; the
cartridge / UMD is taken out of the case and handed to the existing insertion animation.

| Asset | Root node | Source folder | Runtime file |
|---|---|---|---|
| Nintendo DS case (NTSC-U) | `NDS_CASE` | `Handheld_Cases/NDS/` | `DuoDS/Resources/NDS-Case.usdz` |
| Nintendo 3DS case (NTSC-U) | `CTR_CASE` | `Handheld_Cases/3DS/` | `DuoDS/Resources/3DS-Case.usdz` |
| PSP UMD case (NTSC-U) | `UMD_CASE` | `Handheld_Cases/UMD/` | `DuoDS/Resources/PSP-UMD-Case.usdz` |

(The three runtime files are currently copies of `PS2-Case.usdz` as stand-ins; they are already in the
Xcode target — overwrite them in place, never touch `project.pbxproj`.)

## Frame (identical to PS2-Case)

Metres, Y up, `metersPerUnit = 1`. Case closed, standing, front cover facing +Z, spine on −X.
Root = bottom centre of the closed case's bounding box: X ∈ [−W/2, W/2], Y ∈ [0, H], Z ∈ [−T/2, T/2].

## Nodes (names are API — the app finds them by name)

| Node | Role |
|---|---|
| `<ROOT>` | root empty (USD defaultPrim) |
| `CASE_TRAY` | static back half (everything that does not move) |
| `CASE_SPINE_HINGE` | empty on the back hinge line (outer spine/back corner), rotated π about X so local +Y = world −Y; never animated |
| `CASE_SPINE` | child of `CASE_SPINE_HINGE`, identity rest transform; opens by local `rot_y` 0 → π/2 |
| `CASE_LID` | child of `CASE_SPINE`, positioned on the front hinge line (local (0, 0, −T)), zero rest rotation; opens by local `rot_y` 0 → π/2 |
| `CASE_MEDIUM_ANCHOR` | empty under `CASE_TRAY`: origin = centre of the cartridge / UMD body resting in its holder with the case closed; local +Z = the medium's label face normal (pointing toward the lid, out of the tray); local +Y = the medium's "up" (label reads upright; for DS/3DS cards the contact edge is at −Y; for the UMD the shutter/window side conventions are documented in the asset README) |
| `COVER_ART` | front insert panel (under `CASE_LID`) |
| `COVER_ART_SPINE` | spine insert strip (under `CASE_SPINE`) |
| `COVER_ART_BACK` | back insert panel (under `CASE_TRAY`) |
| `TRADEMARK_PRINTS*` | optional: any molded/printed logo on the PLASTIC (not on the paper insert) goes in groups whose names start with `TRADEMARK_PRINTS`, so the app can hide them |

Fully open (π/2, π/2): tray | spine | lid flat side by side, inner faces up (+Z), like PS2.
Both hinge angles may be interpolated simultaneously; the four corner poses must be collision-free.

## Insert (cover sheet) UV

`COVER_ART`, `COVER_ART_SPINE`, `COVER_ART_BACK` share ONE image = the real printed insert sheet laid
flat as seen from outside: `back | spine | front`, left to right. u = 0 is the back panel's free edge,
u = 1 the front panel's free edge; v = 0 bottom, v = 1 top (SceneKit shows image top at the top — same
as PS2, no contentsTransform needed). Each asset's `contract.json` states the real insert size in mm:
`{"insert_mm": {"back": B, "spine": S, "front": F, "height": Hh}, "u_splits": [B/(B+S+F), (B+S)/(B+S+F)]}`.
The app renders the sheet from these numbers, so they must be exact and match the UVs.
No banners/logos on the plastic unless molded in reality; the platform banner (e.g. "NINTENDO DS",
"PSP") is part of the paper insert and is drawn by the app into the texture.

## Contents

The holder must fit the app's real medium model (measure it, don't guess):
- DS / 3DS cards: `DuoDS/Resources/Detailed-Cartridges.usdz`, nodes `ndsStandard` / `threeDS` (millimetre units,
  ≈ 33 × 35 × 3.8 mm).
- UMD: `DuoDS/Resources/PSP-UMD.usdz` + `PSP-UMD-Shell.usdz` (metres; ≈ 64 × 65 × 4.2 mm).
Self-check (exit code 1 on failure, like build_case.py): hinge corner poses collision-free, and a
medium proxy (or the real medium mesh) at `CASE_MEDIUM_ANCHOR` collision-free with the case closed.

## Deliverables per asset

`Handheld_Cases/<X>/source/build_<x>_case.py`, `contract.json`, `README.md` (Chinese, like
`PS2_Disc_Case/README.md`, including the node table, anchor axes and insert UV), `REFERENCE_NOTES.md`
(every dimension/colour with its source), `renders/case_closed.png`, `renders/case_open.png`, the
`.blend`, `exports/<name>.usdz` and the copy in `DuoDS/Resources/`. Reuse `tools/ps2_blender/common.py`
and helpers from `PS2_Disc_Case/source/build_dvd.py` by import; do NOT edit shared files
(`tools/ps2_blender/*`, `PS2_Disc_Case/*`, `DuoDS/*` other than your one usdz).
Blender: `/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python-exit-code 1 --python ...`
