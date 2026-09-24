# PSP UMD 美版零售盒（NTSC-U）

App 运行时资产 `PSP-UMD-Case.usdz`：美版 PSP UMD 游戏透明盒（竖版 104 × 177 × 14.5 mm，透明 PP 盒体 + 外层透明膜 + 纸质封面）。全部由 Blender Python 脚本程序化建模，可从零重建；运行时 SceneKit 按固定节点名开合盒盖、替换封面贴图，并把 App 现有的 UMD 模型放进/取出盒内卡座。共享约定见 [`../CONTRACT.md`](../CONTRACT.md)，调研见 [`../RESEARCH.md`](../RESEARCH.md)，每个尺寸与颜色的来源见 [`REFERENCE_NOTES.md`](REFERENCE_NOTES.md)。做法与 `PS2_Disc_Case/`（PS2 Amaray 盒）一致。

## 文件

- `exports/PSP-UMD-Case.usdz`：运行时资产，已覆盖复制到 `DuoDS/Resources/PSP-UMD-Case.usdz`（该文件已在 Xcode target 里，原先是 PS2 盒的占位副本）。
- `PSP_UMD_Case.blend`：由脚本保存；盒子 + 挂在 `CASE_MEDIUM_ANCHOR` 下的真实 UMD（`UMD_PREVIEW`，只在 `.blend` 里，不进 USDZ）。每次重建都会覆盖。
- `source/build_umd_case.py`：建模、导出、自检、渲染，并写出 `contract.json`。
- `contract.json`：尺寸、封面纸尺寸 `insert_mm` 与 `u_splits`、铰链、锚点与 UMD→锚点变换（由脚本生成，数值与 UV 同源）。
- `renders/`：`case_closed`（关闭，默认灰封面）、`case_open`（全开斜视，UMD 在卡座里）、`case_open_top`（全开俯视）、`cradle_detail` / `cradle_empty`（卡座特写，有/无 UMD，用来对照参考照片），UV 验证图 `case_open_cover_outside`（全开从外侧看：封底 | 书脊 | 封面）和 `case_closed_cover`（关闭，测试图）。
- `references/`：内部结构参考照片（来源见 REFERENCE_NOTES）。

## 坐标与单位

米制，1 单位 = 1 m，`metersPerUnit = 1`，stage `upAxis = "Y"`，根节点 `UMD_CASE` 是 USD defaultPrim。与 PS2-Case 相同的框架：盒子关闭、竖放，封面朝 +Z，书脊在 −X。根节点 = 关闭时包围盒底面中心：x −52…52，y 0…177，z −7.25…7.25 mm。分型面 z = 0（托盘壁止于 −0.05，盒盖壁始于 +0.05）。

## 节点（名字就是 API）

盒子是双活页铰链：托盘（后半）⟷ 书脊 ⟷ 盒盖（前半）。两条铰链线沿 Y，位于书脊外侧两个角：后铰链 (−52, y, −7.25) mm，前铰链 (−52, y, +7.25) mm。

| 节点 | 作用 | 轴 / 范围 |
|---|---|---|
| `UMD_CASE` | 根空节点 | — |
| `CASE_TRAY` | 静态后半（空节点）：`TRAY_SHELL`（透明盒体，含弹片 U 形槽）、`UMD_CRADLE_RIM`（UMD 形凸缘，左右指槽，上下开口）、`UMD_CRADLE_TABS`（上下两个卡扣，唇边盖住 UMD 边缘 1 mm）、`UMD_CRADLE_FLOOR`（两条支撑筋、弹片上的中心定位柱、弹片弧形筋）、`TRAY_SNAP_NUBS`（开口边内侧的扣位）、`SLEEVE_BACK`、`COVER_ART_BACK`、`INSERT_REVERSE_BACK` | 静态 |
| `CASE_MEDIUM_ANCHOR` | 空节点，`CASE_TRAY` 子节点，见下文“UMD 对位” | 静态 |
| `CASE_SPINE_HINGE` | 空节点，位于后铰链线 (−52, 88.5, −7.25) mm，绕 X 转 π（本地 +Y = 世界 −Y）；只是框架，不要动它 | 静态 |
| `CASE_SPINE` | 书脊：`SPINE_PANEL`、`SLEEVE_SPINE`、`COVER_ART_SPINE`、`INSERT_REVERSE_SPINE`；静止变换为单位矩阵 | 本地 `rot_y` 0（关）→ π/2 |
| `CASE_LID` | 盒盖，`CASE_SPINE` 子节点，位于前铰链线（父空间 (0, 0, −14.5) mm），静止旋转 0：`LID_SHELL`、`LID_MANUAL_CLIP`（开口边中部的说明书卡片）、`LID_SNAP_TABS`（两个扣舌，勾在托盘扣位下）、`SLEEVE_FRONT`、`COVER_ART`、`INSERT_REVERSE_FRONT` | 本地 `rot_y` 0（关）→ π/2 |
| `COVER_ART` / `COVER_ART_SPINE` / `COVER_ART_BACK` | 封面纸三块材质槽（分别在 `CASE_LID` / `CASE_SPINE` / `CASE_TRAY` 下） | 见“封面贴图” |
| `TRADEMARK_PRINTS` | 根节点下的静态组：托盘卡座内的模压 “UMD” 字样 `TRAY_UMD_EMBOSS`（UMD 是 Sony 商标；纯文字，用 Blender 内置字体） | 隐藏：`isHidden = true` |

开盒：`CASE_SPINE` 与 `CASE_LID` 各转 π/2，两个角度可同时插值；只改 `eulerAngles.y`，不要改 `position`。全开 (π/2, π/2) 时 托盘 | 书脊 | 盒盖 并排平放、内面朝上（+Z），外面都在 z = −7.25 mm，总宽 104 + 14.5 + 104 = 222.5 mm（x −170.5…52）。四种角度组合 (0/π/2 × 0/π/2) 都通过相交自检。塑料上没有印刷横幅；“PSP” 黑色横幅属于纸质封面，由 App 画进贴图。

## UMD 对位（`CASE_MEDIUM_ANCHOR`）

- 位置：`CASE_TRAY` 空间 (0, 93.0, −2.7) mm，旋转为单位矩阵（轴 = 盒子轴）。
- 原点：UMD 盘心（盘轴上、厚度中点）。UMD 形状的包围盒中心比盘心低 0.5 mm（UMD 外形 x ±32，y −33…+32，z ±2.1 mm），所以盒内 UMD 外形实际占 x −32…32、y 60…125、z −4.8…−0.6 mm（自检实测）。
- 轴：本地 +Z = UMD 标签面法线（朝盒盖，开盒后朝上可见）；本地 +Y = UMD 的“上”：圆弧端朝上、带两个圆角的平端朝下（标签正读，“PSP” 字样与手柄图标在下方）；本地 +X 指向盒子开口边，UMD 读取窗（数据面的矩形窗口）在 +X 一侧、朝下贴着托盘。
- UMD 模型自身坐标（`PSP-UMD.usdz`、`PSP-UMD-Shell.usdz`，米制，测量所得）：原点 = 盘心，标签面在 −Z（z = −2.1 mm），数据/读取面在 +Z（钢制夹持毂在 +Z 侧中心 Ø18 mm 开口里），圆弧端 +Y，读取窗在 −X。
- **固定变换**：把 UMD 根节点作为 `CASE_MEDIUM_ANCHOR` 的子节点，本地变换 = 绕 Y 旋转 π，平移 0，缩放 1：

  ```swift
  umdRoot.position = SCNVector3Zero
  umdRoot.eulerAngles = SCNVector3(0, Float.pi, 0)
  umdRoot.scale = SCNVector3(1, 1, 1)   // 两者都是米；盒子的缩放由 UMD_CASE 继承
  anchor.addChildNode(umdRoot)
  ```

  这与 `umdScene(for:)` 中 `eulerAngles.y = .pi` 的朝向完全相同（那里另外乘了 ×700 的展示缩放，放进盒子时不要带这个缩放）。`PSP-UMD.usdz` 与 `PSP-UMD-Shell.usdz` 两个根节点都用这同一个变换。
- 卡座：凸缘内缘 = 实测 UMD 外形（凸包）外扩 0.4 mm，壁宽 2.4 mm，顶面 z = −1.4 mm（UMD 标签面比它高 0.8 mm）；左右中部各有一个 3 mm 深的弧形指槽；上下各一个卡扣，唇边底面在 UMD 标签面上方 0.15 mm；两条支撑筋 x = ±15 mm，顶面比 UMD 数据面低 0.05 mm；中心定位柱 Ø10 mm，高出 UMD 数据面 0.35 mm，伸进 UMD 的 Ø18 mm 毂孔（离钢毂仍有 0.18 mm）。自检用真实 UMD 网格（21 个网格：外壳、透明罩、盘片、钢毂等）确认关盒时与盒子无相交。

## 封面贴图

三块网格共用一张封面纸图，纸张尺寸 **213 × 172 mm**：封底 99.5 | 书脊 14.0 | 封面 99.5，从盒子外侧看平铺为 封底 | 书脊 | 封面（左→右）。u = 0 为封底自由边，u = 1 为封面自由边；v = 0 底边、v = 1 顶边（纸张在盒上 y = 2.5…174.5 mm）。SceneKit 中直接把正向图片设给 `diffuse.contents`，不需要 `contentsTransform`（与 PS2 相同）。

```json
"insert_mm": {"back": 99.5, "spine": 14.0, "front": 99.5, "height": 172.0},
"u_splits": [0.467136, 0.532864]
```

| 区域 | 折线（纸张 u） | 网格实际覆盖的 u |
|---|---|---|
| 封底 `COVER_ART_BACK` | 0 … 0.46714 | 0 … 0.46502 |
| 书脊 `COVER_ART_SPINE` | 0.46714 … 0.53286 | 0.46784 … 0.53216 |
| 封面 `COVER_ART` | 0.53286 … 1 | 0.53498 … 1 |

网格比折线略窄（折角处约 0.45 mm 的纸看不到），书脊文字留 ≥0.5 mm 余量。`COVER_ART*` 只有朝外的一个面（默认材质 `COVER_ART_default`，#EDEDED）；App 会把它们几何上的所有材质换成贴图（`applyPS2CoverInsert` 的做法可直接复用，只换节点根名）。纸的背面是单独的网格 `INSERT_REVERSE_*`（材质 `INSERT_paper_reverse`，白纸色），这样开盒后透过透明盒体看到的是白色纸背而不是镜像的封面——不要替换它们的材质。外层透明膜 `SLEEVE_*` 在贴图外侧，也不要替换。`case_open_cover_outside.png` 证明对角线与 60 mm 圆在 封底 | 书脊 | 封面 之间连续。

## 材质与透明

| 材质 | 用途 | 值 |
|---|---|---|
| `CASE_plastic_clear` | 盒体、卡座、卡片、扣位 | #C8DBE1，roughness 0.06，opacity 0.28 |
| `CASE_emboss_frosted` | 模压 UMD 字样 | #E6EEF0，roughness 0.4，opacity 0.6 |
| `CASE_sleeve` | 外层透明膜 | #FAFAFA，roughness 0.03，opacity 0.05（与 PS2 膜一致） |
| `COVER_ART_default` | 封面纸（运行时替换） | #EDEDED |
| `INSERT_paper_reverse` | 纸背 | #F2F1EB |

透明度通过 `common.export_usdz` 的 `_fix_opacity` 写入 UsdPreviewSurface `opacity`；已用 macOS SceneKit 实测载入：塑料材质 `transparent.contents = 0.28`、膜 0.05、封面不透明，节点名、层级、铰链与锚点位置与本文一致。轻微蓝灰色调 + 多层叠加让壁厚和边缘可见；盒子的“样子”主要来自膜后面的纸质封面。注意：膜是高光材质（和 PS2 相同），灯光正对时会在封面上出现一片镜面反光。

## 尺寸与面数

- 外形 104.0 × 177.0 × 14.5 mm（包围盒实测一致）；塑料壁厚 1.2 mm；膜 0.15 mm。
- 三角面：**7,179**（预算 40,000）。

## 精度边界

- 外形 104 × 177 × 14.5 为多个零售/替换盒规格的折中（104–110 × 176–180 × 14–15）。
- 封面纸 213 × 172 mm：总宽取自替换盒卖家标注的 sleeve 8 3/8″（212.7 mm），宽高比取自 23 张 libretro 美版 PSP 封面扫描的中位数 0.579；没有官方模板数据，中等可信度（±1–2 mm）。
- 卡座形状、位置、支撑筋、定位柱、指槽、卡扣、说明书卡片、扣位来自一张替换盒正面照片（Mediaxpo，与原厂同款模具外观）的比例测量（约 ±2–3 mm）；卡座内缘直接用 App 的 UMD 模型实测，不是估计。扣位/扣舌的具体形状是结构推断。
- 颜色为照片近似值。

## 重建

从仓库根目录运行（约 2 分钟，含 7 张 Cycles 渲染）：

```sh
/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python-exit-code 1 \
  --python Handheld_Cases/UMD/source/build_umd_case.py
cp Handheld_Cases/UMD/exports/PSP-UMD-Case.usdz DuoDS/Resources/PSP-UMD-Case.usdz
```

脚本通过 `importlib` 复用 `tools/ps2_blender/common.py`、`PS2_Disc_Case/source/build_dvd.py`、`build_case.py` 的辅助函数（不修改它们），用 pxr 直接读取 `PSP-UMD-Shell.usdz` 的外形来生成卡座，导出后再导入两个 UMD 文件做碰撞检查和渲染。自检输出（任一失败退出码 1）：

```
self-check spine=0.0000 lid=0.0000: collisions none
self-check spine=1.5708 lid=0.0000: collisions none
self-check spine=0.0000 lid=1.5708: collisions none
self-check spine=1.5708 lid=1.5708: collisions none
self-check UMD (21 meshes) at CASE_MEDIUM_ANCHOR in closed case: collisions none
self-check UMD shell world bbox mm: -32.00..32.00 60.00..125.00 -4.80..-0.60
self-check OK
```
