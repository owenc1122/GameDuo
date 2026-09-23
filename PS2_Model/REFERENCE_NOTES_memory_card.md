# PS2 8 MB 记忆卡（SCPH-10020，黑色）参考数据

契约文件：`tools/ps2_blender/contract_parts/PS2-MemoryCard.json`

## 坐标约定
- 平放，贴标签的一面朝上（+Y），接口端朝 -Z。
- 根点 = 接口端面的中心（X 为宽度中心，Y 为厚度中心，Z = 0 在端面上）。卡身向 +Z 延伸到 56.5，卡身厚 7.3 mm，顶面（标签面）在 Y = +3.55；SONY 压印凸起 0.2 mm 到 Y = +3.75，整体包围盒 7.5 mm。
- 接口端的判断：△ 标记和两个倒角都在这一端；防滑波纹在另一端（SONY 那一端）的两侧，插进主机后露在外面用手捏。见 memcard_top_forenti.jpg 和 PS2_Model/references/memcard_8mb_evanamos.jpg。

## 等级说明
- **官方**：Sony 文档原文。
- **交叉验证**：两个及以上互相独立的来源数值一致。
- **照片校准**：从照片量取，比例尺用宽度 42 mm，即 memcard_top_forenti.jpg 上 22.71 px/mm。标“推定”的是估计值。

## 尺寸与外形
| 项目 | 数值(mm) | 来源 URL | 等级 |
|---|---|---|---|
| 宽 X | 42.0 | https://www.printables.com/model/403806-playstation-12-memory-card-holder-parameterizable （SCAD：`mcRawWidth = 42`）；https://www.printables.com/model/1307502-picomemcard-ps1-memory-card-rp2040zero-shell （外壳 SCAD 宽 42） | 交叉验证 |
| 厚 Y | 7.5（另一个来源为 7.3） | 同上（`mcRawHeight = 7.5` / 外壳 7.3） | 交叉验证 |
| 长 Z | 56.5 | 三张照片的长宽比分别为 1.345 / 1.346 / 1.346（Forenti、Ilion、Qurren），再乘 42 | 照片校准（memcard_top_forenti.jpg） |
| 包围盒 [X,Y,Z] | [42.0, 7.5, 56.5] | 综合以上 | 交叉验证 + 照片校准 |
| 接口端两角倒角 | 2 × 2（45°） | PicoMemCard SCAD 的 hull 外形 + 照片 | 照片校准（memcard_top_forenti.jpg） |
| 尾端圆角 | R ≈ 2.5 | 照片 | 照片校准（推定） |
| 插入方向 | 印有 △ 的一面朝上（主机横放时），插进 MEMORY CARD 插槽 | Sony 说明书 https://www.playstation.com/content/dam/global_pdc/en/corporate/support/manuals/ps2-docs/JA_SCPH-10020_WEB.pdf | 官方 |

## 接口端与防呆
| 项目 | 数值(mm) | 来源 | 等级 |
|---|---|---|---|
| 端面窗口 | 宽 28，高约 4，居中，深约 6 | PicoMemCard SCAD 的 contact cutout（28 宽，距底面 1.6 起） | 照片校准（推定） |
| 触点 | 8 针，间距 2.4，被 2 条隔筋（宽 1.6）分成 3 格；隔筋中心约 X = +7.4 / -3.0，左右不对称，起防呆作用 | 同上 | 照片校准（推定，方向需要实物确认） |

## 正面印字与造型（中心 [X, Z]，都在 Y = +3.55 这一面上）
| 项目 | 数值(mm) | 来源 | 等级 |
|---|---|---|---|
| △ 标记（指向 -Z，与机身同色） | 中心 (0, 3.0)，11 × 2.7 | memcard_top_forenti.jpg | 照片校准（memcard_top_forenti.jpg） |
| 两个小孔 | (±17.5, 3.8)，Ø1.8 | 同上 | 照片校准（memcard_top_forenti.jpg） |
| PS 标志（蓝） | (-13.9, 8.0)，7.2 × 5.5 | 同上 | 照片校准（memcard_top_forenti.jpg） |
| “PlayStation 2”（蓝） | (6.5, 8.5)，22.6 × 3.8 | 同上 | 照片校准（memcard_top_forenti.jpg） |
| “8MB”（灰；“8”字高约 6.3） | (0.3, 15.3)，10.7 × 6.3 | 同上 | 照片校准（memcard_top_forenti.jpg） |
| “MEMORY CARD”（灰） | (0, 20.8)，22 × 2.0 | 同上 | 照片校准（memcard_top_forenti.jpg） |
| “MagicGate”（灰，小型大写） | (-0.2, 25.2)，16.5 × 1.4 | 同上 | 照片校准（memcard_top_forenti.jpg） |
| 标签凹区 | 中心 (0, 37.3)，38.5 × 20，深约 0.3 | forenti + solomon203 两张照片 | 照片校准（memcard_scph10020_solomon203.jpg） |
| 横向刻线 | Z = 47.2，X 从 -19 到 19 | 同上 | 照片校准（memcard_top_forenti.jpg） |
| “SONY”凸字（与机身同色） | (-0.3, 51.7)，15 × 2.7 | 同上 | 照片校准（memcard_top_forenti.jpg） |
| 两侧防滑波纹 | Z 29–46，4 个波峰，起伏约 0.5 | 同上 + evanamos | 照片校准（推定起伏量） |

## 颜色（近似 sRGB）
| 项目 | 值 | 来源 |
|---|---|---|
| 机身 / 标签凹区 | #232225（照片实测 #312F32，影棚光偏亮） | PS2_Model/references/memcard_8mb_evanamos.jpg |
| 蓝色印字（PS 标志、PlayStation 2） | #1170C4（实测 #116EBE / #006EC6） | 同上 |
| 灰色印字（8MB 等） | #6E6E74（实测 #626269） | 同上 |
| 触点 | #C9A24A（镀金，推定） | 推定 |

## 下载的图片（`PS2_Model/references/memory_card/`）
| 文件 | 原图 | 作者 / 许可 |
|---|---|---|
| memcard_top_forenti.jpg | https://commons.wikimedia.org/wiki/File:PS2_Memory_Card.jpg | Forenti / CC BY-SA 3.0 |
| memcard_top_ilion.jpg | https://commons.wikimedia.org/wiki/File:Sony_PS2_Speicherkarte.jpg | Ilion / CC BY-SA 3.0 |

另外也用到了仓库里已有的 `PS2_Model/references/memcard_8mb_evanamos.jpg`（Evan-Amos，公有领域，https://commons.wikimedia.org/wiki/File:PS2-8MB-Mem-Card.jpg ）和 `memcard_scph10020_solomon203.jpg`（Solomon203，CC BY-SA 4.0，https://commons.wikimedia.org/wiki/File:SCPH-10020_Memory_Card.jpg ）。社区 CAD 文件只下载到临时目录读取数值，没有放进仓库。

## 精度边界
宽 42 和厚 7.5 来自两个互相独立的社区 CAD，彼此一致，误差约 ±0.3（厚度另一个值是 7.3）。长 56.5 来自三张照片的长宽比，三者只差 1%，但一张有透视的照片（solomon203）给出的比例更低，所以长度按 ±1 mm 看待。印字位置大约 ±0.5 mm。接口窗口的尺寸、隔筋位置和防呆方向只有一个爱好者复刻外壳作依据，属于推定；如果要和主机插槽精确配合，需要实物测量或参考插槽开口的数据。Sony 说明书里没有外形尺寸。
