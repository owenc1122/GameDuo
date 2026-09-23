# 共享矢量标识

所有 PS2 模型的商标与按键印刷优先使用这里的矢量，不再用系统字体近似。Blender 里用 `bpy.ops.import_curve.svg(filepath=...)` 导入，转网格后按参考照片缩放定位。

| 文件 | 内容 | 来源 |
|---|---|---|
| `PlayStation2_logo_commons.svg` | PS2 标志（蓝色渐变“PS2”）+ “PlayStation®2” 字标（官方字体轮廓） | Wikimedia Commons `File:PlayStation 2 logo.svg`，Public domain（文字标志），商标属 Sony |
| `PlayStation_logo_commons.svg` | 彩色 PlayStation “PS” 标志 | Wikimedia Commons `File:PlayStation logo.svg`，Public domain，商标属 Sony |
| `PS.svg`、`SONY.svg` | 单色 PS 标志、SONY 字标 | `PSP2000_IceSilver/references/official_print_vectors/`，取自 Sony PSP-2000 官方快速参考手册 |
| `SELECT.svg`、`START.svg` | 按键字样（手册嵌入 Helvetica 字形） | 同上 |
| `L.svg`、`R.svg` | 肩键字母 | 同上 |
| `TRIANGLE/CIRCLE/CROSS/SQUARE.svg` | 面键符号 | 同上 |
| `DPAD_*.svg` | 方向键箭头 | 同上 |

“PlayStation 2” 字标需要单独使用时，从 `PlayStation2_logo_commons.svg` 中只取下方字标的路径。“DUALSHOCK 2”、“MEMORY CARD”、“MagicGate” 等没有公开矢量的字样，按参考照片描摹或用最接近的字体，并在报告里注明。
