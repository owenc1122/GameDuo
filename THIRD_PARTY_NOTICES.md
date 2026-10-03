# Third-Party Notices

Game Duo is distributed under GPL-3.0-or-later. It includes the following open-source components.
Full license texts are in `DuoDS/Resources/Licenses/` and are shown in the app under Settings > About > Open Source Licenses.
The machine-readable list is `DuoDS/Resources/Licenses/OpenSourceLicenses.json`.

| Component | Use | License | Upstream | Revision |
|---|---|---|---|---|
| melonDS DS | DS core | GPL-3.0-or-later | https://github.com/JesseTG/melonds-ds | bc4e4b67d2d4 |
| melonDS | DS core (via melonDS DS) | GPL-3.0-or-later | https://github.com/melonDS-emu/melonDS | 7117178c2dd5 |
| DeSmuME | DS core (HD rendering mode) | GPL-2.0-or-later | https://github.com/libretro/desmume | TODO |
| Azahar | 3DS core | GPL-2.0-or-later | https://github.com/azahar-emu/azahar | c2237de04d8c |
| PPSSPP | PSP core + runtime assets | GPL-2.0-or-later | https://github.com/hrydgard/ppsspp | TODO |
| ParaLLEl N64 | N64 core | GPL-2.0-or-later (mixed GPL/LGPL components) | https://github.com/libretro/parallel-n64 | 6e4c44c51885 |
| Play! | PS2 core (WebAssembly) | BSD-2-Clause | https://github.com/jpd002/Play- | 83700b2c31e5 |
| libretro API | core interface | MIT | https://github.com/libretro/libretro-common | - |
| libarchive | archive headers (system library) | BSD-2-Clause | https://github.com/libarchive/libarchive | abaa707d92fc |
| Fast-SRGAN | upscaling model | MIT | https://github.com/HasnainRaz/Fast-SRGAN | - |
| Roboto Condensed | font (PPSSPP assets) | Apache-2.0 | https://github.com/googlefonts/roboto-classic | - |
| Inconsolata | font (PPSSPP assets) | OFL-1.1 | https://github.com/googlefonts/Inconsolata | - |

Corresponding source for the modified cores = upstream revision above + patches under `vendor/patches/` (see `vendor/MANIFEST.tsv`).
