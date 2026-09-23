# DualShock 2（SCPH-10010，黑色）参考数据

契约文件：`tools/ps2_blender/contract_parts/PS2-DualShock2.json`

## 坐标约定
- 手柄平放在桌面，面键朝上，握把朝向玩家。X = 宽（向右为 +），Y = 高（向上为 +，桌面 Y=0），Z = 朝向玩家（+Z 为握把端，-Z 为肩键/线缆端）。
- 根点 = 机身包围盒底面中心（只算机身，不含线缆和插头）。机身 X ∈ [-78.5, 78.5]，Z ∈ [-47.5, 47.5]。
- 各部件 `center_mm` 指未按下时部件顶面的中心。

## 等级说明
- **官方**：Sony 文档原文。
- **交叉验证**：两个及以上互相独立的二手来源（Wikipedia、dimensions.com、社区 CAD）数值一致。
- **照片校准**：用 dimensions.com 正交线稿（按 157 mm 缩放，6.45 px/mm）和 Commons 俯视照片测得，下表写明所用照片。标“推定”的行是工程估计，照片里量不出来。

## 整体
| 项目 | 数值(mm) | 来源 URL | 等级 |
|---|---|---|---|
| 机身 宽×长(Z)×高(Y) | 157 × 95 × 55 | https://en.wikipedia.org/wiki/DualShock （DS2 信息框：157×95×55 mm）；https://www.dimensions.com/element/dualshock-2-controller （157 / 95 / 54.9 mm） | 交叉验证 |
| 含摇杆的总高 | ≈ 62 | dimensions.com 线稿前视/侧视（摇杆顶部高出 55 mm 那条尺寸线约 7 mm） | 照片校准（dimensions.com 线稿） |
| 面板平面（按键周围的外壳顶面）Y | ≈ 52 | 同上 | 照片校准（dimensions.com 线稿） |
| 重量 | 172 g（ja.wiki）/ 210 g（en.wiki、dimensions.com） | https://ja.wikipedia.org/wiki/DUALSHOCK ；https://en.wikipedia.org/wiki/DualShock | 交叉验证（两个来源不一致，已取 172） |
| 线缆长度 | 2400 | en.wiki DS2 信息框写 2.4 m；https://en.wikipedia.org/wiki/PlayStation_2_accessories 写“比初代 DualShock（2 m）略长” | 交叉验证 |
| 线缆出口 | 中心 (0, 38.5, -33.0)，护线套 Ø9.5，线径 Ø4.0 | dimensions.com 前视图 | 照片校准（dimensions.com 线稿） |

## 按键布局（中心点，mm）
| 项目 | 数值(mm) | 来源 URL | 等级 |
|---|---|---|---|
| 十字键（一体十字） | 中心 (-46.5, 54.0, -12.5)；外廓 26×26，臂宽 8.5；凹槽 38×37.5 | dimensions.com 线稿 + ds2_top_boarder8925.jpg + ds2_top_piacarrot.jpg | 照片校准（ds2_top_boarder8925.jpg） |
| 面键组中心 | (46.5, -, -12.5)；与十字键中心相距 93 | 同上（线稿 92，照片经透视修正后约 94） | 照片校准（ds2_top_boarder8925.jpg） |
| △ | (46.5, 55.0, -24.7)，Ø10.5 | 同上 | 照片校准（ds2_top_piacarrot.jpg） |
| ○ | (59.3, 55.0, -12.5)，Ø10.5 | 同上 | 照片校准（ds2_top_piacarrot.jpg） |
| × | (46.5, 55.0, -0.3)，Ø10.5 | 同上 | 照片校准（ds2_top_piacarrot.jpg） |
| □ | (33.7, 55.0, -12.5)，Ø10.5 | 同上 | 照片校准（ds2_top_piacarrot.jpg） |
| 面键间距 | □↔○ 25.6，△↔× 24.4（相邻两键约 17.7） | 线稿两个方向都是 24.4；两张照片横向都大 5–10% | 照片校准（两张俯视照） |
| L1 / R1 | 中心 (∓46.5, 41.5, -44.5)，21 × 9（高）× 6（深），前面 Z = -47.4 | dimensions.com 前视 + 侧视 | 照片校准（dimensions.com 线稿） |
| L2 / R2 | 中心 (∓46.5, 20.0, -42.5)，21 × 15.5 × 7，前面 Z ≈ -46 | 同上 | 照片校准（dimensions.com 线稿） |
| 左 / 右摇杆 | 帽顶中心 (∓23.0, 62.0, 10.5)；间距 46（线稿 47，照片 44.8 / 46.3）；帽 Ø22.5，帽厚 4.5；外圈 Ø33 | 线稿 + 两张俯视照 | 照片校准（ds2_top_piacarrot.jpg） |
| 摇杆转轴 | (∓23.0, 44.0, 10.5)（帽顶以下约 18） | 推定 | 照片校准（推定） |
| SELECT | (-14.0, 53.0, -12.5)，7.5 × 4.0，圆角矩形 | 线稿 + 照片 | 照片校准（ds2_top_boarder8925.jpg） |
| START | (14.0, 53.0, -12.5)，8.0 × 5.0，指向 +X 的三角形 | 同上 | 照片校准（ds2_top_boarder8925.jpg） |
| ANALOG 键 | (0, 52.5, 1.9)，7 × 3.5 | 两张照片（Z = +1.9 / +2.0） | 照片校准（ds2_top_piacarrot.jpg） |
| ANALOG LED（红） | (0, 52.2, 8.7)，5.5 × 1.8 | 两张照片（Z = +8.6 / +8.9） | 照片校准（ds2_top_piacarrot.jpg） |
| “SONY”印字 | (0, 52, -24.5)，26.5 × 4.2，灰 | 两张照片 | 照片校准（ds2_top_piacarrot.jpg） |
| PS 标志 / “PlayStation” | (0, 52, -16.5) 6×5 / (0, 52, -11.3) 15×2.5，灰 | 两张照片 | 照片校准（ds2_top_piacarrot.jpg） |
| SELECT / START / ANALOG 字样 | (∓13.7, 52, -6.6) / (0, 52, -2.7)，字高约 1.8 | 照片 | 照片校准（ds2_top_piacarrot.jpg） |
| “DUALSHOCK 2”印字（蓝） | 前侧（-Z）上方斜面，线缆出口左侧；中心约 (-18, 48, -33.5)，20 × 2.5 | Koei 识别说明：http://www.koei.co.jp/html/support/notice/dualshock2.htm ；PS2_Model/references/dualshock2_evanamos.jpg | 照片校准（dualshock2_evanamos.jpg） |

## 行程（给 iOS 动画用）
| 项目 | 数值 | 来源 | 等级 |
|---|---|---|---|
| 面键下压 | 2.0 mm | 推定（导电橡胶碗结构，iFixit 107082 有说明） | 照片校准（推定） |
| L1/R1 下压（+Z 方向） | 2.0 mm | 推定 | 照片校准（推定） |
| L2/R2 | 绕 X 轴转 8°（约合 3 mm），铰点 (∓46.5, 28, -40) | 推定；实物也可能是直推，Blender 里两种都能做 | 照片校准（推定） |
| 摇杆最大倾角 | 25° | 推定（同类 ALPS 摇杆模块的常见值） | 照片校准（推定） |
| L3/R3 按压 | 0.8 mm | 推定 | 照片校准（推定） |
| 十字键倾斜 | 5° | 推定 | 照片校准（推定） |
| SELECT/START、ANALOG | 1.0 / 0.8 mm | 推定 | 照片校准（推定） |

## 手柄插头
| 项目 | 数值(mm) | 来源 URL | 等级 |
|---|---|---|---|
| 插入端凸台（三窗口） | 40 × 7.5（外框），伸出约 9 | 社区 CAD 包围盒 40×7.5×14：https://www.printables.com/model/1293652-playstation-12-controller-plug （CC BY-NC，未放进仓库）；ds2_plug_front_iagoqnsi_hs2.jpg 量得宽高比约 5:1 | 照片校准（ds2_plug_front_iagoqnsi_hs2.jpg） |
| 插头主体 | 43 × 13 × 29（凸台宽 : 主体宽 = 555 : 598 px，见 dualshock2_plug_hs1.jpg） | 照片 + 推定 | 照片校准（dualshock2_plug_hs1.jpg，推定） |
| 插头总长（不含护线套） | ≈ 38；根点 = 插入端面中心，插入方向 -Z | 推定 | 照片校准（推定） |
| 磁环 | Ø14 × 25，距插头尾部约 60 | ds2_cable_plug_yolanc.jpg、dualshock2_plug_hs1.jpg | 照片校准（推定） |

## 颜色（近似 sRGB）
| 项目 | 值 | 来源 |
|---|---|---|
| 机身 | #1C1C1E（照片实测 #262628，握把 #141414） | dualshock2_evanamos.jpg |
| 按键帽 / 摇杆帽 | #2B2B2E / #2E2E31 | 同上 |
| △ 绿 / ○ 红 / × 蓝 / □ 粉 | #3DB39E / #E24A43 / #7F9FD9 / #E48CB8（细线与黑色混色，照片实测更淡：#60A3A5 / #AE605B / #8191AE / #D39DB5） | 同上 |
| 灰色印字 | #7E7E82（实测 #727274–#7B7B7D） | 同上 |
| DUALSHOCK 2 印字 | #3A6FC0 | 目测 |
| LED 亮 / 灭 | #FF2B1C / #4A0E0C | 推定 |

## 下载的图片（`PS2_Model/references/controller/`）
| 文件 | 原图 | 作者 / 许可 |
|---|---|---|
| ds2_top_boarder8925.jpg | https://commons.wikimedia.org/wiki/File:Sony_Dual_Shock_2.jpg | Boarder8925 / CC BY-SA 3.0 |
| ds2_top_piacarrot.jpg | https://commons.wikimedia.org/wiki/File:DualShock2.jpg | PiaCarrot / CC BY-SA 3.0 |
| ds2_plug_front_iagoqnsi_hs2.jpg | https://commons.wikimedia.org/wiki/File:DualShock_2_controller_plug_HS2.jpg | IagoQnsi / CC BY 4.0 |
| ds2_cable_plug_yolanc.jpg | https://commons.wikimedia.org/wiki/File:Game_controller_PlayStation_2.jpg | YolanC / CC BY-SA 2.5 |

尺寸线稿 https://cdn.prod.website-files.com/5b44edefca321a1e2d0c2aa6/5e5f3b92845bab20bdcf14a8_Dimensions-Guide-Digital-Video-Game-Controllers-DualShock-2-Dimensions.svg （dimensions.com，有版权）只用来测量，没有放进仓库。

## 其他查过的来源
- Sony 日文说明书 https://www.playstation.com/content/dam/global_pdc/en/corporate/support/manuals/ps2-docs/JA_SCPH-10010_WEB.pdf 和美版说明书（archive.org）都没有外形尺寸或重量。
- iFixit 拆解 40772、107082、50763：确认有 6 颗底部螺丝、导电橡胶碗压感结构和两个震动马达；没有尺寸。
- Printables / Thingiverse 上没有完整的 DualShock 2 外壳 CAD，只有支架和插头之类的零件。

## 精度边界
X/Z 布局：十字键、面键、摇杆的中心大约 ±1.5 mm，间距大约 ±1 mm。依据是 dimensions.com 线稿，加上两张近似俯视照片（已按面板高度做透视修正），三者相差不超过 2.5 mm。Y 方向（高度）只有 dimensions.com 前视和侧视两个来源，两者本身差约 3 mm，所以面板 Y、摇杆顶部 Y、L1/L2 高度大约 ±3 mm。“55 mm”是否含摇杆，各来源说法不一：线稿的尺寸线止于按键顶面，所以这里按“不含摇杆的机身高”处理，含摇杆约 62 mm。所有“推定”值（行程、转轴、铰点、插头主体、磁环）都是工程估计，可能差 30% 以上，拿到实物测量后应当替换。颜色是在影棚光下取样的近似值。
