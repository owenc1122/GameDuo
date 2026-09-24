# 美版 Nintendo 3DS 游戏盒（3DS-Case）：参考数据

本文件只记录数据与来源，数值与 `contract.json` 一致，单位 mm。坐标：盒子关闭竖放，正面 +Z，书脊 −X，x −67.5…67.5，y 0…122（底→顶），z −6…6。

等级：
- **官方**：标准或厂商/任天堂数据。
- **交叉验证**：两个以上独立来源一致。
- **照片校准**：以已知外形尺寸为比例尺，从照片量得（写明照片），一般 ±2–3 mm。
- **估计**：照片看不清，按结构推断；在 `contract.json` 的 `estimated_keys` 中列出。

注意：能找到的“空盒内部”照片都是售后替换盒（Retro Game Fan、ZedLabz、Mediaxpo 的商品图），它们仿零售盒开模，布局一致但细节（模压标志、底面凹坑）可能不同。照片只作测量参考，未存入仓库。

## 照片来源

| 代号 | 内容 | URL |
|---|---|---|
| RGF-1 | 替换盒全开、正对内侧（卡扣、书脊、卡带座） | https://cdn.shopify.com/s/files/1/0711/4235/files/ACC-3DS-Replacment-Game-Case-1-Pack-View-1.webp（商品页 https://retrogamefan.com/products/replacement-game-cases-for-nintendo-3ds-2ds-5-pack-cartridge-storage-cases-brand-new-loose） |
| RGF-2 | 关闭，正面外侧（透过窗口看到卡扣） | 同上 `...-View-2.webp` |
| RGF-3 | 关闭，背面外侧（卡带座背面轮廓） | 同上 `...-View-3.webp` |
| RGF-4 | 平放，正面与开口边（指扣凹槽、锁扣槽） | 同上 `...-View-4.webp` |
| ZL-1 / ZL-2 | ZedLabz 白色替换盒，半开（托盘内 “NINTENDO 3DS” 竖排模压字、卡带座、盖内卡扣） | https://www.zedlabz.com/en-us/products/official-replacement-nintendo-3ds-retail-game-cartridge-case-2-pack-white |
| MX-1 | Mediaxpo 白色替换盒，书脊朝前半开（背面卡带座轮廓、正面卡扣窗口） | https://www.checkoutstore.com/products/replacement-game-cases-compatible-with-white-nintendo-3ds |
| DS-1 | 美版 DS 盒内部（装有卡带，CC BY-SA 4.0，Multicherry）：卡带正读、金手指朝下、弹片和三角在卡带右侧 | https://commons.wikimedia.org/wiki/File:Nintendo_DS_game_case_(NA_type)_(inside_filled).jpg |

## 1. 外形与材质

| 项目 | 数值 | 来源 | 等级 |
|---|---|---|---|
| 宽 × 高 × 厚 | 135 × 122 × 12 | 维基百科 [Keep case](https://en.wikipedia.org/wiki/Keep_case)（NA 3DS 135 × 122 × 12）；Walvis 136 × 124 × 12.5；CheckOutStore/Mediaxpo 136 × 123 × 12.5；ZedLabz 13.7 × 12.5 × 1.3 cm（均见 `../RESEARCH.md` §2） | 交叉验证（厂商值多 1 mm，取维基值） |
| 方向 | 横向（宽 > 高），书本式，书脊在左 | RESEARCH §2；RGF-1…4 | 交叉验证 |
| 颜色 | 白色不透明 PP，`#EEEEEA` | RESEARCH §2；RGF / ZL 照片取色（偏暖白） | 照片校准 |
| 透明外膜 | 覆盖正面、书脊、背面，纸质封面夹在膜与塑料之间 | RESEARCH §2 | 交叉验证 |
| 开口边角半径 | 2.0（书脊侧 0.3） | RGF-2、RGF-3 | 照片校准 |
| 壁厚 / 塑料外表面 | 1.2 / z ±5.55（膜在 ±5.85…6.0） | 结构估计，参照 PS2 Amaray 盒 | 估计 |
| 铰链 | 双活页铰链，铰链线在书脊外侧两角 (−67.5, z ∓6) | 与 PS2 盒相同的结构 | 估计 |

## 2. 封面纸（insert）

| 项目 | 数值 | 来源 | 等级 |
|---|---|---|---|
| GameTDB coverfullHQ | 1616 × 680 px，封底 0–777，书脊 777–847，封面 847–1616 px（±3 px） | RESEARCH §5（AREE、ECDE、AJRE 实测） | 交叉验证 |
| 全幅 | 276 × 116（The Cover Project 模板单面 130 × 116；全幅扫描比例 2.376） | RESEARCH §1–2 | 交叉验证 |
| 采用 `insert_mm` | 封底 132.7、书脊 12.0、封面 131.3、高 116.1 = 276 × (777, 70, 769) / 1616，高 276 × 680 / 1616 = 116.14 | 由上两行换算，取 0.1 mm | 换算 |
| `u_splits` | [132.7/276, 144.7/276] = [0.480797, 0.524275]；与 777/1616、847/1616 相差 0.03 px、0.23 px | 换算 | — |
| 书脊宽 = 盒厚 | 12.0 | RESEARCH §2（spine ≈ 12） | 交叉验证 |
| 平台竖条 | 封面最右，白（或黑）竖条约 13–15 mm，属纸质封面，由 App 绘制 | RESEARCH §2；[Nintendo 3DS case banners.png](https://commons.wikimedia.org/wiki/File:Nintendo_3DS_case_banners.png) | 交叉验证 |

## 3. 内部布局

| 项目 | 数值 | 来源 | 等级 |
|---|---|---|---|
| 卡带座位置 | 框外廓约 44 × 44（背面轮廓），中心距书脊外面 66.9 → x ≈ −0.6（取 −0.5），距顶 62 → y ≈ 60 | RGF-3（正对背面，8.13 px/mm）；RGF-1、MX-1、ZL-2 均显示居中偏右半托盘中央 | 照片校准 |
| 卡带座结构 | 凸起矩形框，+X 侧中间开口伸出带三角的弹片；+X 两角有卡爪，−X 侧有两个卡点；框内底面有两个方孔 | RGF-1、RGF-3；DS-1（DS 同类结构） | 照片校准（卡爪、方孔细节为估计） |
| 卡带座内腔 | 锚点坐标 x −17.0…18.0、y −18.0…18.0（卡带 34 × 35 + 0.5 余隙，含 +X 键位凸耳） | 由 App 卡带实测值推出 | 换算 |
| 框宽 / 框顶高度 | 3.0 / z −1.6（高出底面 2.75，卡带正面高出框约 1.2） | DS-1 中卡带略高于框 | 估计 |
| 说明书卡扣 | 2 个，在盖内靠开口边；窗口约 21 × 11，x 36.5–57.5（距开口边 10–31），中心距顶 30.4 / 88.6 → 采用对称 y 90 / 32 | RGF-2（正对正面）、RGF-1（内侧） | 照片校准 |
| 卡扣形状 | 窗口内一条从开口边一侧伸向书脊的舌片，末端加厚成钩，钩唇朝书脊 | RGF-1、ZL-1 | 估计 |
| 开口边 | 内侧一道加强筋，上下角各一个锁扣（盖上对应锁槽）；外侧上下角有小槽 | RGF-1、RGF-2、RGF-4 | 照片校准（尺寸估计） |
| 指扣凹槽 | 开口边中部，跨越分模线，长约 44（y 39–83），深 0.8 | RGF-4 | 照片校准（深度估计） |
| 书脊内侧 | 两个小凸块，中心距顶约 43 / 77.5 → y ≈ 79 / 45（采用 75–79、43–47）；两条短横筋，距顶约 21 / 100 | RGF-1 | 照片校准 |
| 模压文字 | 托盘上卡带座与开口边之间的竖排 “NINTENDO 3DS”，自下而上读；模型用纯文字 “Nintendo 3DS”（内置字体），中心 (44, 61)，长 40 | ZL-1、ZL-2；RESEARCH §2（中等可信度） | 照片校准（字体非原厂） |
| 未建模 | ZL 照片中托盘/盖内底面的浅圆角方格凹坑（RGF 照片中没有）；说明书 | — | — |

## 4. 3DS 卡带（App 模型实测）

在 Blender 5.2 中用 `bpy.ops.wm.usd_import` 导入 `DuoDS/Resources/Detailed-Cartridges.usdz`（stage metersPerUnit 1、upAxis Z，但数值为毫米），节点 `/root/threeDS`（文件中平移 (168, 0, 0)，无旋转/缩放），在其本地坐标中测量：

| 项目 | 数值 | 说明 |
|---|---|---|
| 包围盒 | x −16.5…17.5，y −17.5…17.5，z −3.915…0.043 | 全部子网格 |
| 主体 | 33 × 35 × 3.8（x ±16.5，y ±17.5，z −3.8…0） | `Back_cover_004` + `Front_cover_004` |
| 键位凸耳 | +X 侧 x 16.5…17.5，y 11.2…14.8；其上方右上角缺口 x > 12.2、y > 14.9 | 凸耳在卡带正读时的右侧 |
| 正面（标签面） | z = 0；标签凹槽 `Label_recess_bed`，顶部 “NINTENDO 3DS” 凸台 `Front_platform_004` 到 z +0.043（从 +Z 看正读，已渲染确认） | 标签面法线 = +Z |
| 背面 | z = −3.8；模压字 `Back_maker_mark`、`Molded_model_number` 到 −3.915 | — |
| 金手指 | 背面下部 y −17.35…−6.45（PCB 窗口） | 金手指在 −Y |
| 与 RESEARCH §4 对比 | 33–35（含凸耳）× 35 × 3.8 | 一致 |

结论：卡带自身轴已符合锚点约定（+Z 标签面、+Y 上、金手指 −Y），只是原点在正面；因此锚点原点取主体中心 (−0.5, 60, −2.285)，卡带挂上去的本地位置为 (0, 0, +1.9 mm)，缩放 0.001。

## 5. 颜色

| 项目 | sRGB | 来源 | 等级 |
|---|---|---|---|
| 盒体塑料 | `#EEEEEA`，粗糙度 0.55 | RGF、ZL 照片 | 照片校准 |
| 模压字 / 三角 | `#DCDCD6`（比塑料略暗，便于看出） | 模型取值 | 估计 |
| 封面纸默认 | `#EDEDED`（运行时由贴图替换） | 与 PS2 盒一致 | — |
| 透明膜 | `#FAFAFA`，alpha 0.04，粗糙度 0.03 | 与 PS2 盒一致 | 估计 |
