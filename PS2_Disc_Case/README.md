# PS2 DVD 游戏光盘与美版光盘盒

PS2 DVD-ROM 游戏光盘（NTSC-U/C，120 mm 单面）和美版黑色 Amaray PS2 DVD 盒（带记忆卡座）的 App 运行时资产。全部由 Blender Python 脚本程序化建模，可从零重建；运行时 SceneKit 按固定节点名控制盒盖，并在盘面和封面上替换贴图。主机、手柄与记忆卡见 `../PS2_Model/README.md`，总体设计见 `docs/superpowers/specs/2026-09-22-ps2-models-design.md`，每个尺寸的来源与可信度见 [`REFERENCE_NOTES.md`](REFERENCE_NOTES.md)。

## 文件

- `exports/PS2-DVD.usdz`、`exports/PS2-Case.usdz`：运行时资产。已按 `PS2-DVD.usdz`、`PS2-Case.usdz` 复制到 `DuoDS/Resources/`，**尚未加入 Xcode target**，接入时需手动添加。
- `PS2_Disc_Case.blend`：由 `build_case.py` 保存，盒子加上一张放在卡座上的光盘（光盘只在 `.blend` 里，不进盒子的 USDZ）。每次重建都会覆盖；要改请改脚本或契约。
- `source/build_dvd.py`：光盘建模与导出，同时提供 `build_case.py` 复用的几何、文字、标志和渲染辅助函数。
- `source/build_case.py`：光盘盒建模与导出，含铰链自检（四个开合姿态下托盘、书脊、盒盖之间无相交）。
- `validation.json`：`tools/ps2_blender/validate_ps2.py` 写入的自动校验结果。
- `renders/`：`dvd_label / dvd_data`（标签面、数据面），`case_closed / case_open`，以及 UV 验证图 `case_open_cover_outside / case_closed_cover`（用中性测试图检查三块封面网格共用一张图时是否连续，不是游戏封面）。
- `references/`：参考照片，来源与许可见 REFERENCE_NOTES。
- 尺寸、颜色、运动范围写在 `tools/ps2_blender/contract.json` 与 `tools/ps2_blender/contract_parts/PS2-DVD.json`、`PS2-Case.json`（part 覆盖主文件）。

## 坐标与单位

米制，1 单位 = 1 m，`metersPerUnit = 1`，stage `upAxis = "Y"`。X 向右、Y 向上、Z 指向物件正面。不要额外施加缩放。SceneKit 忽略 upAxis，节点变换与 Blender 中的数值完全相同；根节点是 USD defaultPrim。

| 资产 | 根节点 | 根节点位置 | 摆放 |
|---|---|---|---|
| 光盘 | `PS2_DVD` | 盘心，Y = 0 为厚度中点（标签面 y = +0.6 mm，数据面 y = −0.6 mm） | 平放，标签面朝上（+Y），数据面朝下 |
| 光盘盒 | `PS2_CASE` | 包围盒底面中心；x −67.5…67.5，y 0…190，z −7…7 mm | 关闭、竖放，封面朝 +Z，书脊在 −X |

## SceneKit 接入约定

可动节点静止姿态为位置 0、旋转 0；表中的轴是该节点在父节点空间中的本地轴。USD 导入器会把带子节点的网格拆成 `NAME` 和几何子节点 `NAME_mesh`；这两个资产的可动节点和对位节点都是空节点，材质槽 `DISC_LABEL`、`COVER_ART*` 本身就带 geometry。

### 光盘 `PS2-DVD.usdz`

| 节点 | 作用 |
|---|---|
| `PS2_DVD` | 根节点（盘心）。放上主机托盘：以单位变换挂到主机的 `TRAY_DISC_ANCHOR` 下；放进盒子：以单位变换挂到 `CASE_DISC_ANCHOR` 下。 |
| `DISC_LABEL` | 印刷面材质槽，24–117 mm 的薄圆环，浮在标签面上 0.005 mm。默认材质 `DISC_LABEL_default`（白色）。 |
| `DISC_HUB` | 透明聚碳酸酯中心区（15 mm 孔到 41 mm） |
| `DISC_BODY` | 41–120 mm 不透明盘体：镜面环、银色数据面、标签外缘银边 |
| `TRADEMARK_PRINTS` | 默认美版标签印刷（9 点钟方向 PS 标志框、中心下方 “PlayStation 2” 字标）与数据面中心环内的 PS / PlayStation 2 模压全息 |

数据面按 PS2 DVD-ROM 实物做成银色；契约里的蓝色 `data_side_ps2_cd_blue_alt`（#2E2470）只属于早期 PS2 CD-ROM 游戏，作为备选值保留（见 REFERENCE_NOTES）。

### 光盘盒 `PS2-Case.usdz`

盒子按实物做成双活页铰链：托盘（后半）⟷ 书脊 ⟷ 盒盖（前半）。两条铰链线都沿 Y 方向，位于书脊外侧两个角：后铰链 (−67.5, y, −7) mm，前铰链 (−67.5, y, +7) mm。

| 节点 | 作用 | 轴 / 范围 |
|---|---|---|
| `CASE_TRAY` | 静态后半：托盘壳、卡座（6 爪）、护盘弧墙、记忆卡座、透明膜、封底 | 静态 |
| `CASE_DISC_ANCHOR` | 空节点，`CASE_TRAY` 子节点，位于 (−5, 71, −2.6) mm，已绕 X 转 +90°，使光盘 +Y（标签面）朝向盒盖 | 静止；`PS2_DVD` 以单位变换挂到这里即扣在卡座上 |
| `CASE_SPINE_HINGE` | 空节点，位于后铰链线，绕 X 转 π（本地 +Y = 世界 −Y）；只是框架，不要动它 | 静态 |
| `CASE_SPINE` | 书脊（后铰链） | 本地 Y 旋转，0（关闭）→ `π/2` |
| `CASE_LID` | 盒盖，`CASE_SPINE` 的子节点，位于前铰链线（父空间 (0, 0, −14) mm） | 本地 Y 旋转，0（关闭）→ `π/2` |
| `COVER_ART` | 封面材质槽（`CASE_LID` 下） | 见下文“封面贴图” |
| `COVER_ART_SPINE` | 书脊封面材质槽（`CASE_SPINE` 下） | 同上 |
| `COVER_ART_BACK` | 封底材质槽（`CASE_TRAY` 下） | 同上 |
| `TRADEMARK_PRINTS` | 顶层商标组（空；所有印刷都要跟随可动部件，所以分在下面两个组里） | — |
| `TRADEMARK_PRINTS_SPINE` | `CASE_SPINE` 下：书脊黑色横带、白框彩色 PS 标志、竖排 “PlayStation 2” 字标 | — |
| `TRADEMARK_PRINTS_LID` | `CASE_LID` 下：封面顶部黑色横幅、白色 “PlayStation 2” 字标、彩色 PS 标志 | — |

开盒：`CASE_SPINE` 与 `CASE_LID` 各转 `π/2`，两个角度可以同时插值。全开 (π/2, π/2) 时托盘 | 书脊 | 盒盖并排平放，内面朝上，外面都在 z = −7 mm，总宽 135 + 14 + 135 = 284 mm（x −216.5…67.5）。两个角度的四种组合 (0/π/2 × 0/π/2) 都已通过相交检查。

### 对位约定

| 空节点 | 对齐对象 | 含义 |
|---|---|---|
| `TRAY_DISC_ANCHOR`（主机 `DISC_TRAY` 子节点） | `PS2_DVD` 根节点 | 光盘在主机托盘里，标签面朝上、数据面朝下 |
| `CASE_DISC_ANCHOR`（盒子 `CASE_TRAY` 子节点） | `PS2_DVD` 根节点 | 光盘扣在盒内卡座上，标签面朝盒盖 |

两个锚点都已包含所需旋转，光盘挂上去时本地变换设为单位矩阵即可。

## 运行时贴图

两个材质槽都有 0–1 UV。SceneKit 导入 USDZ 时已把 USD 的 v 轴翻成图像坐标（实测：图像顶边对应 t = 0），直接把一张正向图片设给 `diffuse.contents` 就是正向显示，不需要 `contentsTransform`。

### 光盘标签 `DISC_LABEL`

平面 UV 覆盖整个 120 mm 正方形：u 对应 +X，图像“上”对应标签的“上”（−Z 方向）。准备一张正方形标签图（边长对应 120 mm），圆心即盘心；只有 24–117 mm 圆环内的部分可见，从盘底透过透明中心区还能看到内圈（镜像）。材质是 `DISC_LABEL_default`，替换 `diffuse.contents` 即可。

### 封面 `COVER_ART` / `COVER_ART_SPINE` / `COVER_ART_BACK`

三块网格共用一张 273 × 183 mm 的封面纸图（Amaray 单碟封面官方尺寸：封底 129.5 + 书脊 14 + 封面 129.5），从盒子外侧看平铺为 封底 | 书脊 | 封面，v = 0 为底边、1 为顶边（纸张 y 3.5…186.5 mm）。

| 区域 | 折线（纸张） | 网格实际覆盖的 u |
|---|---|---|
| 封底 `COVER_ART_BACK` | u 0 … 0.4744 | 0 … 0.4727 |
| 书脊 `COVER_ART_SPINE` | u 0.4744 … 0.5256 | 0.4759 … 0.5242 |
| 封面 `COVER_ART` | u 0.5256 … 1 | 0.5272 … 1.0 |

网格覆盖范围比折线略窄（盒壁圆角处的纸不可见），所以书脊文字和折线附近的图案要留约 0.5 mm 余量。三块网格默认都用材质 `COVER_ART_default`（#EDEDED）；在 SceneKit 中给三个节点的几何分别设置同一张图片，不要假定它们共享同一个 `SCNMaterial` 实例。封面上的透明膜（`SLEEVE_*`）在贴图外侧，不要替换它们的材质。

## 商标隐藏

商标默认显示。隐藏时把下列节点的 `isHidden` 设为 `true`：

| 资产 | 要隐藏的组 |
|---|---|
| 光盘 | `TRADEMARK_PRINTS`（标签印刷与中心全息） |
| 光盘盒 | `TRADEMARK_PRINTS`、`TRADEMARK_PRINTS_SPINE`、`TRADEMARK_PRINTS_LID`（三个一起隐藏） |

注意：盒内托盘底面的模压标记在 `TRAY_EMBOSS` 网格里（记忆卡座旁的 PS 标志和箭头、MEMORY CARD HOLDER、卡座按钮上的 PUSH、AMARAY），不在任何商标组下，隐藏上面三个组不会去掉这个 PS 标志；如需完全去掉，额外隐藏 `TRAY_EMBOSS`（会连同其余模压文字一起隐藏）。书脊内侧的专利号模压 `SPINE_EMBOSS` 不是商标。

## 尺寸与面数

`validation.json` 中的测量值（根节点空间顶点包围盒，容差 0.5 mm）：

| 资产 | 目标尺寸 (mm) | 实测 (mm) | 三角面 / 预算 |
|---|---|---|---|
| 光盘 | 120 × 1.2 × 120 | 120.0 × 1.455 × 120.0 | 3,774 / 4,000 |
| 光盘盒 | 135 × 190 × 14 | 135.0 × 190.0 × 14.0 | 5,104 / 11,000 |

光盘厚度实测多出的 0.255 mm 是标签面上的堆叠环（0.2 mm）以及浮在盘面上的标签层和印刷层，在容差内。盒子加光盘共 8,878 面，低于设计预算 15,000。

## 精度边界

REFERENCE_NOTES 中每个数值都标有等级：**官方**（ECMA-267 标准、Amaray 产品手册）、**交叉验证**（两个以上独立来源一致）、**照片校准**（以官方尺寸为比例尺，从照片测得，注明照片）；照片看不清、只能按结构推断的工程估计列在契约 JSON 的 `estimated_keys` 里。

- **光盘**：外径、中心孔、厚度、夹持区、信息区与数据区都是 ECMA-267 名义值（官方）。印刷区内径 24 mm、外径 117 mm 交叉验证。镜面环、堆叠环、全息环为单张倾斜照片测量（约 ±0.5 mm），堆叠环直径和高度为估计。
- **光盘盒**：外形 190 × 135 × 14、封面纸 273 × 183、说明书最大尺寸有厂商或多源依据。卡座、记忆卡座、卡扣和书脊横幅来自透视照片（约 ±2–3 mm，卡座 X 向偏移 −5 mm 不确定度 ±3 mm）。壁厚、铰链轴位置、光盘在盒内的 Z 高度、护盘弧墙和膜厚为结构估计。美版封面顶部横幅为**黑底白字**（5 份北美封面扫描，横幅高 17.1 ± 0.8 mm），与设计稿最初写的“白色横条”不同；不同游戏、年份（如 Greatest Hits）有差异。
- **印刷字形**：PS 标志与 “PlayStation 2” 字标来自共享矢量 `tools/ps2_blender/vectors/`（Wikimedia Commons 与 Sony 官方手册矢量，见该目录 `README.md`）。没有公开矢量的小字（MEMORY CARD HOLDER、PUSH、AMARAY、专利号）用 Blender 内置字体，字形为近似。
- 所有颜色都是照片近似值，没有色度计数据。不在范围内：真实游戏封面与盘面图案、实物测量。

## 重建方法

从仓库根目录运行：

```sh
tools/ps2_blender/run_all.sh
```

它依次重建全部五个 PS2 资产（记忆卡 → DualShock 2 → 主机 → DVD → 光盘盒，Blender 一次只开一个），再运行校验器自测、`validate_ps2.py` 和 `verify_scenekit.swift`，任一步失败则退出码非 0；日志在 `build/ps2_logs/`。

单独构建（DVD 要先于盒子；两个脚本每次都会重新输出 `renders/` 里的检查图）：

```sh
B="/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python-exit-code 1"
$B --python PS2_Disc_Case/source/build_dvd.py
$B --python PS2_Disc_Case/source/build_case.py
$B --python tools/ps2_blender/validate_ps2.py -- --only PS2-DVD --only PS2-Case
xcrun swift tools/ps2_blender/verify_scenekit.swift --only PS2-DVD --only PS2-Case
```

`build_case.py` 通过 `importlib` 载入 `build_dvd.py` 的辅助函数，并在 `.blend` 中放一张光盘，但不读取 DVD 的导出文件。需要 Blender 5.2。重建后如需更新 App 资源，把 `exports/*.usdz` 再复制到 `DuoDS/Resources/`。
