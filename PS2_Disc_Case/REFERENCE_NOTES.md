# PS2 DVD 游戏光盘与美版 (NTSC-U/C) PS2 DVD 盒：参考数据

本文件只记录数据，不含模型。数值与 `tools/ps2_blender/contract_parts/PS2-DVD.json`、`PS2-Case.json` 一致，单位 mm。

等级说明：
- **官方**：标准或厂商文件（ECMA-267、Amaray 产品手册）。
- **交叉验证**：两个以上互相独立的来源一致。
- **照片校准**：用一个官方尺寸作比例尺在照片上量出，括号内写照片名。JSON 中另有 `estimated_keys`，列出的是工程估计：照片看不清，只能按结构推断的值。

坐标约定：
- 光盘：标签面朝 +Y，根节点在圆心。标签面上的二维坐标 [u, v] 从 +Y 方向看，u 对应 +X，v（标签的“上”）对应 −Z。
- 盒子：竖放，正面朝 +Z，书脊在 −X，根节点在包围盒底面中心。范围：X ∈ [−67.5, 67.5]，Y ∈ [0, 190]，Z ∈ [−7, 7]。

## 1. 光盘 (PS2-DVD)

| 项目 | 数值 (mm) | 来源 URL | 等级 |
|---|---|---|---|
| 外径 | 120.00 ±0.30 | [ECMA-267 §10.1](https://ecma-international.org/wp-content/uploads/ECMA-267_3rd_edition_april_2001.pdf) | 官方 |
| 厚度（含标签） | 1.20（+0.30 / −0.06），由两片 0.6 基片粘合 | ECMA-267 §10.1 | 官方 |
| 中心孔 | 15.00（+0.15 / −0），孔缘圆角 ≤ 0.1 | ECMA-267 §10.1 | 官方 |
| 第一过渡区外径 | 16.0 | ECMA-267 §10.2 | 官方 |
| 夹持区 | 内径 22.0，外径 33.0 | ECMA-267 §10.3–10.4 | 官方 |
| 第三过渡区（可设堆叠环） | 33–44，上表面允许高出 0.25 | ECMA-267 §10.5 | 官方 |
| 堆叠环直径 | 37.0（高约 0.2） | ps2dvd_data_side.jpg 径向剖面在 36.5–37 mm 处有微弱凸起 | 照片校准（弱，列入 estimated_keys） |
| 信息区起点 / 数据区起点 | 44.0 / 48.0 | ECMA-267 §10.6 | 官方 |
| 数据区最大外径 / 信息区终点 | 116.0 / ≥117.0 | ECMA-267 §10.6 表 1 | 官方 |
| 外缘圆角 | ≤ 0.2 | ECMA-267 §10.7 | 官方 |
| 透明中心区外径（数据面无镀层） | 41.0 | ps2dvd_data_side.jpg（以 15.0 mm 孔边作比例校验；椭圆拟合） | 照片校准 |
| 镜面环（有镀层，刻母盘号） | 41.0–44.0 | ps2dvd_data_side.jpg | 照片校准 |
| 标签印刷内径 | 24.0 | ps2dvd_data_side.jpg 中透过透明区看到白色印刷边，直径 23.9；ps2_hdd_utility_disc_label_ntscuc.jpg 为约 23.5；[edocpublish](https://www.edocpublish.com/resources-2/specifications/cd-or-dvd-specifications-for-printing/) 满版印刷规格为 23 | 交叉验证 |
| 标签印刷外径 | 117.0 | edocpublish 满版印刷规格为 117；HDD 盘照片外缘留白约 1.5 mm | 交叉验证 |
| 中心全息 PS2 标志环 | 直径 27–36，共 6 个 | ps2dvd_data_side.jpg | 照片校准 |
| 数据面 PS 水印 | 6 个，中心半径约 44.7，每个约 14，位于 1/3/5/7/9/11 点钟方向 | ps2dvd_data_side.jpg 与 [Commons 说明](https://commons.wikimedia.org/wiki/File:PS2dvd.jpg) | 照片校准 |

### 标签面元素位置（NTSC-U/C 官方版式，只记位置）
测量对象为 ps2_hdd_utility_disc_label_ntscuc.jpg（SCUS 97395，Sony NTSC U/C 标签）。比例尺取盘径 120 mm：横向 10.07 px/mm，纵向 9.38 px/mm，拍摄有倾斜。

| 元素 | 中心 [u, v] | 尺寸 | 等级 |
|---|---|---|---|
| PS 标志方框（白框、白色 PS 标志） | [−38.8, 0.3] | 15.5 × 15.6 | 照片校准 |
| “NTSC U/C” 小框 | [−39.0, −11.9] | 15.7 × 2.4 | 照片校准 |
| 产品编号（SLUS-xxxxx） | [−39.1, −17.8] | 14.7 × 6.2 | 照片校准 |
| 右侧发行商标志 | [35.4, 2.2] | 12.1 × 16.7 | 照片校准 |
| “PlayStation 2” 字标 | [0.3, −41.9] | 27.1 × 5.5 | 照片校准 |
| 授权声明文字块（本盘在上方） | [0, 23.7] | 88.3 × 14.4 | 照片校准 |
| 授权声明改为沿外缘环排时 | 半径 55，弧段 200°–340°，字高 1.4 | 无照片佐证 | estimated_keys |

### 光盘颜色

| 项目 | sRGB | 来源 | 等级 |
|---|---|---|---|
| 数据面（PS2 **DVD**） | `#B9B9BE` 银色金属。暖光下实测中位数为 `#A37E4E` | ps2dvd_data_side.jpg、ps2_dvd_label_piacarrot.jpg | 照片校准 |
| 数据面（PS2 **CD-ROM**，备用值） | `#2E2470` 深蓝紫 | [Commons: CD-ROM for PlayStation2.jpg](https://commons.wikimedia.org/wiki/File:CD-ROM_for_PlayStation2.jpg)，只取色，未存入仓库 | 照片校准 |
| 标签默认色 | `#FFFFFF`（运行时由贴图替换） | 任务约定 | 官方 |
| 标签黑色油墨 | `#1C1B1E` | HDD 盘照片 | 照片校准 |

**纠正：** 蓝色或黑色数据面是 PS2 早期 **CD-ROM** 游戏的特征。维基百科 [PlayStation 2](https://en.wikipedia.org/wiki/PlayStation_2) 条目写道 “earlier titles being published on blue-tinted CD-ROM format”。PS2 **DVD-ROM** 游戏盘的数据面是银色，两张 Commons DVD 照片都能印证。JSON 的 `data_side` 使用银色，蓝色值单独放在 `data_side_ps2_cd_blue_alt`。

## 2. 美版 PS2 DVD 盒 (PS2-Case)

| 项目 | 数值 (mm) | 来源 URL | 等级 |
|---|---|---|---|
| 外形 高 × 宽 | 190 × 135 | [维基百科 Keep case](https://en.wikipedia.org/wiki/Keep_case)（引用 Amaray 手册）；[coverstitch.io](https://coverstitch.io/dimensions.html) 称 PS2 与 DVD 盒外形相同 | 交叉验证 |
| 厚度（书脊） | 14 | [Amaray 手册（2010 存档）](https://web.archive.org/web/20100821133442/http://www.amaray.com/downloads/AmarayBrochure.pdf)：DVD single 封面纸书脊 14 mm；coverstitch 同为 14 | 官方 |
| 厂商 | Amaray（书脊内侧压印 “US PAT No 5788068”） | ps2_case_inside.jpg | 照片校准 |
| 壁厚 | 1.3 | 结构估计 | estimated_keys |
| 转轴 | 书脊两侧为 PP 活页铰链；模型简化为盖子单轴，经过 [−66.85, *, 6.35]，方向 [0, −1, 0] | ps2_case_inside.jpg 与结构推断 | estimated_keys |
| 开盖角度 | 0 – π（可平摊 180°） | ps2_case_inside.jpg（盒子平摊） | 照片校准 |
| 光盘卡座中心 | X = −5.0（±3，偏向书脊），Y = 71.0（±2），Z = −2.6 | ps2_case_inside.jpg（按盒高 190，5.83 px/mm）；ps2_disc_in_case_crtgamer.jpg 量得 Y ≈ 70.8；Z 为估计值 | 照片校准 |
| 卡座直径 / 底座直径 | 15.0 / 36 | 与 ECMA 15 mm 中心孔配合；底座直径取自 crtgamer 照片 | 交叉验证 / 照片校准 |
| 护盘弧墙 | 内径约 121，外径约 124，高约 4，分 4 段 | ps2_case_inside.jpg | 照片校准（部分估计） |
| 记忆卡座 | 中心 [−5.0, 159.5]，外框 56.6 × 46.3，可容 56.5 × 42 的卡 | ps2_case_inside.jpg；卡尺寸见 PS2-MemoryCard.json | 照片校准 / 交叉验证 |
| 说明书卡扣 | 2 个，位于盖子内侧的开口边（+X），中心 Y = 14.5 与 175.5，X 范围 38.5–63.0，宽 11 | ps2_case_inside.jpg（6.03 px/mm） | 照片校准 |
| 说明书最大尺寸 | 120 × 180，厚 ≤ 3 | Amaray 手册 | 官方 |
| 封面纸 | 273 × 183 = 129.5 + 14 + 129.5 | Amaray 手册；coverstitch 为 274 × 184（取整值） | 官方 |
| 封面纸正面区域 | X −67.5 至 62.0，Y 3.5 至 186.5 | 由 190 与 183 之差推算 | 照片校准（X 为估计） |
| 透明外套膜厚 / 封面纸厚 | 0.15 / 0.15 | 估计 | estimated_keys |

### 封面顶部横幅（美版）
测量对象为 5 张北美版 PS2 封面扫描：Dark Cloud、Kingdom Hearts、Ratchet & Clank、Sly Cooper、Katamari Damacy。图片来自英文维基百科，属 non-free，只在临时目录测量，**未存入仓库**，例如 [RaCbox.jpg](https://en.wikipedia.org/wiki/File:RaCbox.jpg)。比例尺为正面 129.5 × 183。

| 项目 | 数值 | 等级 |
|---|---|---|
| 横幅颜色 | **黑色** `#050505`（不是白色） | 照片校准 |
| 横幅高度 | 17.1 ±0.8（从封面纸顶边算） | 照片校准 |
| “PlayStation 2” 白色字标 | 距封面纸左上角 x 4.5–67.9、y 4.0–15.7；在盒坐标中中心为 [−31.3, 176.6]，尺寸 63.4 × 11.7 | 照片校准 |
| 彩色 PS 标志 | x 111.4–125.4、y 2.4–13.7；盒坐标中心为 [50.9, 178.4]，尺寸 14.0 × 11.3 | 照片校准 |
| “NTSC U/C” 小框（部分封面有） | 横幅下方右侧，x 111.7–128.8、y 17.8–20.2 | 照片校准 |

### 书脊横幅（美版）
测量对象为 us_ps2_spines_gamestop.jpg，比例尺取盒高 190，得 4.0 px/mm。

| 项目 | 数值 | 等级 |
|---|---|---|
| 黑色书脊带 | 从盒顶向下到 53.9 处（在封面纸上为 50.4），盒坐标 Y 136.1–186.5 | 照片校准 |
| 白底彩色 PS 标志方块 | 中心 Y 179.5，约 10 × 12.5 | 照片校准 |
| “PlayStation 2” 竖排字（从上往下读） | Y 138.4–171.3，长 32.9 | 照片校准 |
| Greatest Hits 版本 | 书脊带为红色，默认不建模 | 照片校准 |

### 盒子颜色

| 项目 | sRGB | 等级 |
|---|---|---|
| 盒体黑色 PP（哑光细纹理） | `#232326`（原始测值 `#28282A`，已按照片中说明书白纸校正） | 照片校准 |
| 透明套膜 | `#FFFFFF`，alpha 0.06 | estimated_keys |
| PS 标志 红 / 黄 / 绿 / 蓝 | `#CA2B1D` / `#BF912D` / `#2E8B64` / `#2D5889` | 照片校准（封面扫描分辨率低） |

## 3. 仓库内参考照片（`PS2_Disc_Case/references/`）

| 文件 | 原始出处 | 作者 / 许可 | 用途 |
|---|---|---|---|
| ps2dvd_data_side.jpg | [Commons: PS2dvd.jpg](https://commons.wikimedia.org/wiki/File:PS2dvd.jpg) | DiscoverYellow，CC BY-SA 3.0 / GFDL。本地副本为 1600 px 重采样，原图 1024 px，内容一致 | 数据面各环直径、颜色 |
| ps2_dvd_label_piacarrot.jpg | [Commons: DVD-ROM for PlayStation2.jpg](https://commons.wikimedia.org/wiki/File:DVD-ROM_for_PlayStation2.jpg) | Pia Carrot，GFDL / CC BY-SA 3.0 / 2.5 / 2.1-jp。文件名虽写 label，实际拍的是数据面 | 银色数据面颜色 |
| ps2_case_inside.jpg | [Commons: PlayStation 2 Game Case - Inside.jpg](https://commons.wikimedia.org/wiki/File:PlayStation_2_Game_Case_-_Inside.jpg) | Aya19790，CC BY-SA 4.0，1600 px 缩小版 | 卡座、记忆卡座、卡扣、盒色 |
| ps2_disc_in_case_crtgamer.jpg | [Commons: Disc Crack From Case.jpg](https://commons.wikimedia.org/wiki/File:Disc_Crack_From_Case.jpg) | CRTGAMER，公有领域 | 卡座底座直径、卡座 Y 位置 |
| us_ps2_spines_gamestop.jpg | [Commons: Used PS2 games at GameStop, Stonestown.JPG](https://commons.wikimedia.org/wiki/File:Used_PS2_games_at_GameStop,_Stonestown.JPG) | BrokenSphere，CC BY-SA 3.0 | 美版书脊横幅 |
| ps2_hdd_utility_disc_label_ntscuc.jpg | [Commons: Sony PlayStation 2 HDD Utility Disc 20071206.jpg](https://commons.wikimedia.org/wiki/File:Sony_PlayStation_2_HDD_Utility_Disc_20071206.jpg) | Taurolyon，作者声明公有领域（盘面商标属 Sony） | NTSC-U/C 标签版式、印刷内径 |

开放 CAD 检索：用 Printables GraphQL 搜索 “ps2 case”、“dvd case”、“amaray”、“ps2 disc”，没有找到 PS2 或 Amaray 盒的 1:1 复刻模型。1185864 “DVD Case” 与 263270 “Hinged DVD case” 都是 CC BY，但不是原厂外形，未采用。Thingiverse 的 API 需要令牌，这次没有检索。

## 精度边界

光盘几何以 ECMA-267 为准，属于标准名义值；实物公差为外径 ±0.3、厚度 +0.30/−0.06。镜面环、堆叠环、印刷内径和全息环是在单张倾斜照片上量的，以中心孔 15.0 mm 自检，误差约 ±0.5 mm；堆叠环 37 mm 的信号很弱。盒子只有外形 190 × 135 × 14 和封面纸、说明书尺寸有厂商或多源依据。卡座、记忆卡座、卡扣和书脊横幅来自透视照片，误差约 ±2–3 mm；卡座 X 向偏移 −5 mm 的不确定度为 ±3 mm。壁厚、铰链轴位置、光盘在盒内的 Z 高度、护盘弧墙和膜厚都是结构估计，已列入 `estimated_keys`。封面横幅来自低分辨率维基扫描，误差约 ±0.8 mm；不同游戏、不同年份的封面（如 Greatest Hits）有差异。所有颜色都是照片近似值，没有色度计数据。
