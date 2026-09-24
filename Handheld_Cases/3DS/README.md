# 美版 Nintendo 3DS 游戏盒（CTR，NTSC-U）

App 运行时资产 `3DS-Case.usdz`：美版白色不透明 PP 3DS 游戏盒，横向（宽大于高），外侧有透明膜，书本式开合（从正面看书脊在左）。盖子（前半）内侧靠开口边有 2 个说明书卡扣，托盘（后半）中央有 1 个卡带座，没有 GBA 槽。模型全部由 Blender Python 脚本程序化生成，可从零重建。共享约定见 [`../CONTRACT.md`](../CONTRACT.md)，调研见 [`../RESEARCH.md`](../RESEARCH.md) 第 2 节，每个尺寸的来源与可信度见 [`REFERENCE_NOTES.md`](REFERENCE_NOTES.md)，全部数值在 [`contract.json`](contract.json)（mm）。做法与 `PS2_Disc_Case/source/build_case.py` 相同，并复用 `tools/ps2_blender/common.py` 和 `PS2_Disc_Case/source/build_dvd.py` 的辅助函数（只导入，不修改）。

## 文件

- `exports/3DS-Case.usdz`：运行时资产，脚本通过自检后会自动覆盖 `DuoDS/Resources/3DS-Case.usdz`（该文件已在 Xcode target 里，原来是 PS2 盒的临时副本）。
- `3DS_Case.blend`：脚本保存的场景：盒子，加上一张挂在 `CASE_MEDIUM_ANCHOR` 下的 App 真实 3DS 卡带（卡带只在 `.blend` 和渲染图里，不进 USDZ）。每次重建都会覆盖。
- `source/build_3ds_case.py`：建模、自检、导出、渲染。
- `contract.json`：尺寸、铰链、运动范围、封面纸尺寸与 `u_splits`、锚点、布局、颜色、`estimated_keys`。脚本从这里读取数值。
- `renders/`：
  - `case_closed.png`（正面 + 顶边 + 开口边）、`case_closed_spine.png`（正面 + 书脊）
  - `case_open.png`：全开，卡带座里放着真实 3DS 卡带；`case_open_holder_detail.png`：卡带座特写
  - UV 验证图（中性测试图，不是游戏封面）：`case_open_cover_outside.png`（全开后从外侧看，封底 | 书脊 | 封面平铺）、`case_closed_cover.png`（正面 + 书脊）、`case_closed_cover_back.png`（背面 + 开口边）。测试图的对角线和以书脊为圆心、半径 45 mm 的圆在三块网格之间连续；封面最右 14 mm 的白条和黑色箭头标出 App 要画 NINTENDO 3DS 竖条的位置和“上”方向。

## 坐标与单位

米制，`metersPerUnit = 1`，stage `upAxis = "Y"`，X 向右、Y 向上、Z 指向正面，与 `PS2-Case` 完全一致。根节点 `CTR_CASE` 是 USD defaultPrim，位于关闭盒子包围盒的底面中心：x −67.5…67.5，y 0…122，z −6…6 mm（135 × 122 × 12 mm）。盒子关闭、竖放，封面朝 +Z，书脊在 −X。

## 节点

两条铰链线都沿 Y，位于书脊外侧两个角：后铰链 (−67.5, y, −6) mm，前铰链 (−67.5, y, +6) mm。

| 节点 | 作用 | 轴 / 范围 |
|---|---|---|
| `CTR_CASE` | 根节点 | — |
| `CASE_TRAY` | 静态后半：`TRAY_SHELL`（托盘壳，开口边中部有指扣凹槽）、`TRAY_RAIL`（开口边内侧加强筋 + 上下两个锁扣）、`CARD_HOLDER`（卡带座框，+X 侧留口）、`CARD_HOLDER_HOOKS`（+X 两角卡爪、−X 两个卡点，压在卡带正面边缘上方）、`CARD_RELEASE_TONGUE`（+X 侧弹片）、`TRAY_EMBOSS`（弹片上的三角，非商标）、`TRAY_HINGE_WEB`、透明膜 `SLEEVE_BACK`、封底 `COVER_ART_BACK` | 静态 |
| `CASE_MEDIUM_ANCHOR` | `CASE_TRAY` 下的空节点，卡带对位点（见下文） | 静态 |
| `TRADEMARK_PRINTS` | 根节点下：托盘底面模压的纯文字 “Nintendo 3DS”（`TRAY_NINTENDO_3DS_EMBOSS`，Blender 内置字体，不是描摹的任天堂标志） | 可隐藏 |
| `CASE_SPINE_HINGE` | 空节点，位于后铰链线 (−67.5, 61, −6) mm，绕 X 转 π（本地 +Y = 世界 −Y）；只是框架，不要动 | 静态 |
| `CASE_SPINE` | 书脊：`SPINE_PANEL`、`SPINE_TABS`（内侧两个小凸块 + 两条短横筋）、`SLEEVE_SPINE`、`COVER_ART_SPINE` | 本地 `rot_y`：0（关）→ π/2 |
| `CASE_LID` | `CASE_SPINE` 的子节点，位于前铰链线（父空间 (0, 0, −12) mm），静止旋转为 0：`LID_SHELL`（含两个卡扣窗口和指扣凹槽）、`LID_RAIL`、`LID_CLIPS`（两个说明书卡扣）、`LID_HINGE_WEB`、`SLEEVE_FRONT`、`COVER_ART` | 本地 `rot_y`：0（关）→ π/2 |
| `COVER_ART` / `COVER_ART_SPINE` / `COVER_ART_BACK` | 封面 / 书脊 / 封底材质槽（分别在 `CASE_LID`、`CASE_SPINE`、`CASE_TRAY` 下） | 见“封面贴图” |

开盒：`CASE_SPINE` 与 `CASE_LID` 各转 π/2，两个角度可以同时插值。全开 (π/2, π/2) 时托盘 | 书脊 | 盒盖并排平放，内面朝上，外面都在 z = −6 mm，总宽 135 + 12 + 135 = 282 mm（x −214.5…67.5）。四种角点姿态 (0/π/2 × 0/π/2) 都通过了相交检查。可动节点只转不移：运动时只写 `eulerAngles.y`，不要改 `position`（`CASE_LID` 的位置就是铰链）。塑料上没有横幅；平台竖条（NINTENDO 3DS）属于纸质封面，由 App 画进贴图。

## 卡带对位 `CASE_MEDIUM_ANCHOR`

- 位置：`CASE_TRAY` 空间 (−0.5, 60.0, −2.285) mm，旋转为 0（本地轴与世界轴相同）。
- 原点 = 卡带主体（33 × 35 × 3.8 mm，不含 1 mm 键位凸耳）的中心；本地 **+Z** = 卡带正面（标签面）法线，指向盒盖；**+Y** = 卡带的“上”，标签正读，金手指在 **−Y**；+X = 键位凸耳一侧。
- 实测 App 卡带（`DuoDS/Resources/Detailed-Cartridges.usdz` 的 `/root/threeDS`，毫米单位，USD 中 upAxis Z，在 Blender 导入测得）：本地包围盒 x −16.5…17.5，y −17.5…17.5，z −3.915…0.043。主体 x ±16.5；键位凸耳在 +X 侧 x 16.5…17.5、y 11.2…14.8（其上方右上角有缺口）；正面（标签面）在 z = 0，顶部 “NINTENDO 3DS” 凸台高到 +0.043；背面 z = −3.8，背面模压字到 −3.915；金手指窗口在背面下部（−Y）。也就是说卡带节点自身的轴已经和锚点约定一致，只是原点在正面上，不在厚度中心。
- 放进盒子：把 `threeDS` 节点挂到 `CASE_MEDIUM_ANCHOR` 下，`position = (0, 0, 0.0019)` m，`eulerAngles = 0`，`scale = 0.001`（mm → m）。如果 App 用别的方式把卡带换算成米，保持同样的关系：卡带本地原点在锚点 +Z 方向 1.9 mm 处，无旋转。
- 此时卡带正面在世界 z = −0.385 mm，最低的背面模压字在 −4.30 mm，距托盘底面 (−4.35) 0.05 mm；卡爪下沿比正面高 0.085 mm，向卡带边缘内侧压 1.2 mm；卡座内腔（锚点坐标）x −17.0…18.0，y −18.0…18.0，四周约 0.5 mm 余隙。取出时卡带沿 +Z 离开即可（App 动画不需要模拟卡爪）。

## 封面贴图

三块网格共用一张图：真实封面纸平铺、从外侧看，**封底 | 书脊 | 封面**，u = 0 为封底开口边，u = 1 为封面开口边，v = 0 底、1 顶。SceneKit 导入后图像顶边就在上方，不需要 `contentsTransform`（与 PS2 相同）。

封面纸尺寸与 GameTDB `coverfullHQ`（1616 × 680 px，折线 777 / 847 px）一致：276 mm × (777, 70, 769) / 1616，取 0.1 mm：

```json
"insert_mm": {"back": 132.7, "spine": 12.0, "front": 131.3, "height": 116.1},
"u_splits": [0.480797101449, 0.524275362319]
```

直接把 1616 × 680 的全幅扫描当贴图即可 1:1 对上：折线误差 0.03 px / 0.23 px，横纵比误差 0.03 %。

| 区域 | 折线（纸张 u） | 网格实际覆盖的 u |
|---|---|---|
| 封底 `COVER_ART_BACK` | 0 … 0.4808 | 0 … 0.4792 |
| 书脊 `COVER_ART_SPINE` | 0.4808 … 0.5243 | 0.4822 … 0.5228 |
| 封面 `COVER_ART` | 0.5243 … 1 | 0.5259 … 1.0 |

纸张在盒上的位置：两条折线在书脊外侧两个角（x −67.5，z ∓6）；封底开口边 x = 65.2，封面开口边 x = 63.8；纸张 y 2.95…119.05 mm（v = (y − 2.95) / 116.1）。网格比折线略窄（盒壁圆角处的纸看不到），书脊文字要离折线留约 0.5 mm。NINTENDO 3DS 竖条在封面最右约 14 mm（u ≈ 0.949…1）。三块网格默认材质都是 `COVER_ART_default`（#EDEDED），在 SceneKit 中给三个节点分别设置同一张图片；外面的透明膜 `SLEEVE_*` 不要换材质。

## 商标隐藏

商标默认显示。把 `TRADEMARK_PRINTS` 的 `isHidden` 设为 `true` 即去掉盒子上唯一的商标（托盘底面模压的 “Nintendo 3DS” 纯文字）。弹片上的三角 `TRAY_EMBOSS` 不是商标。

## 尺寸与面数

| 项目 | 值 |
|---|---|
| 外形（关闭） | 135.0 × 122.0 × 12.0 mm（自检实测 x −67.500…67.500，y 0…122.000，z −6.000…6.000） |
| 全开 | x −214.5…67.5，z −6.0…0.37 mm |
| 三角面 | 2,851（预算 40,000） |

## 自检

脚本输出 `self-check ...` 行，任一失败退出码为 1（第 1–4 项失败时不导出；第 5 项失败时已导出到 `exports/` 但不复制到 `DuoDS/`）：

1. `u_splits` 与 `insert_mm` 完全一致，并与 GameTDB 折线相差 < 1 px；
2. 关闭包围盒与契约一致（容差 0.05 mm）；
3. 每个网格的 n 边形三角化覆盖正确（导出时三角化，防止布尔后出现横跨空腔的三角形）；
4. 四个铰链角点姿态下托盘 / 书脊 / 盒盖之间无三角形相交；
5. 盒子关闭时，App 真实 3DS 卡带（挂在锚点下）以及 33 × 35 × 3.8 mm + 键位凸耳的方块代理都与盒子所有网格无相交；另外在三个打开姿态下卡带与书脊 / 盒盖无相交。

最近一次输出：

```
self-check u_splits 0.480797 0.524275 (contract [0.480797101449, 0.524275362319]); GameTDB fold error px 0.03 0.23: ok
3DS-Case triangles: 2851 (budget 40000)
self-check closed bbox mm: -67.500..67.500, -0.000..122.000, -6.000..6.000 (ok)
self-check n-gon tessellation: ok
self-check spine=0.0000 lid=0.0000: collisions none
self-check spine=1.5708 lid=0.0000: collisions none
self-check spine=0.0000 lid=1.5708: collisions none
self-check spine=1.5708 lid=1.5708: collisions none
self-check fully open bbox mm: -214.50..67.50, -0.00..122.00, -6.00..0.37
self-check card world bbox mm: -17.000..17.000, 42.500..77.500, -4.300..-0.342
self-check real threeDS card in closed case: collisions none
self-check 33 x 35 x 3.8 card proxy (+key tab) in closed case: collisions none
self-check card vs lid/spine at spine=1.5708 lid=0.0000: collisions none
self-check card vs lid/spine at spine=0.0000 lid=1.5708: collisions none
self-check card vs lid/spine at spine=1.5708 lid=1.5708: collisions none
self-check passed
```

## 精度边界

- 外形 135 × 122 × 12 来自维基百科 Keep case 条目，与厂商 136 × 123~124 × 12.5 相差约 1 mm（厂商数据含公差/包装）。
- 卡带座和卡扣位置来自售后替换盒（Retro Game Fan、ZedLabz、Mediaxpo）的产品照片，约 ±2–3 mm；这些替换盒按零售盒开模，但不保证完全相同。托盘底面浅方格凹坑（只在 ZedLabz 照片中出现）没有建模。
- 壁厚、卡爪、弹片、加强筋、书脊凸块、指扣凹槽深度、铰链轴位置是结构估计（`contract.json` 的 `estimated_keys`）。
- 颜色是照片近似值。“Nintendo 3DS” 模压字的字体不是原厂字形（用 Blender 内置字体）；原厂盒内侧可能还有其他模压标志（中等可信度，未建模）。
- 不在范围内：说明书、真实封面图案、实物测量。

## 重建

从仓库根目录运行（需要 Blender 5.2；约 40 秒，大部分是渲染）：

```sh
/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python-exit-code 1 \
  --python Handheld_Cases/3DS/source/build_3ds_case.py
```

脚本依次：检查契约 → 建模 → 相交自检 → 导出 `exports/3DS-Case.usdz` → 导入真实卡带做放入检查 → 复制到 `DuoDS/Resources/3DS-Case.usdz` → 渲染 → 保存 `.blend`。
