# 美版 Nintendo DS 游戏盒（NTSC-U）

App 运行时资产 `NDS-Case.usdz`：美版零售 DS 游戏盒（深灰不透明 PP，外覆透明膜，书本式开合，横版 135 × 122 × 14.5 mm）。全部由 Blender Python 脚本程序化建模，可从零重建；运行时 SceneKit 按固定节点名控制书脊和盒盖，在三块封面网格上替换贴图，并把 DS 卡带从 `CASE_MEDIUM_ANCHOR` 取出交给插卡动画。共用契约见 [`../CONTRACT.md`](../CONTRACT.md)，调研见 [`../RESEARCH.md`](../RESEARCH.md) 第 1 节，每个尺寸的来源见 [`REFERENCE_NOTES.md`](REFERENCE_NOTES.md)。

## 文件

- `exports/NDS-Case.usdz`：运行时资产。脚本自检全部通过后会覆盖 `DuoDS/Resources/NDS-Case.usdz`（该文件已在 Xcode target 里，不要改 `project.pbxproj`）。
- `NDS_Case.blend`：脚本保存的场景，盒子加上一张放在卡座里的 App 真实 DS 卡带（卡带只在 `.blend` 里，不进 USDZ）。每次重建都会覆盖（Blender 会顺带生成 `.blend1` 备份，可删）。
- `source/build_nds_case.py`：建模、自检、导出、渲染、写 `contract.json`。通过 import 复用 `tools/ps2_blender/common.py`、`PS2_Disc_Case/source/build_dvd.py`（几何、文字、渲染）和 `PS2_Disc_Case/source/build_case.py`（`rplate`、`box_obj`、`bake_into`、`case_groups`、`group_collisions`），不修改它们。
- `contract.json`：脚本生成的数值契约（尺寸、铰链、锚点、`insert_mm`、`u_splits`、卡座、三角面数）。App 以它为准。
- `source/compare_photo.py`：普通 python3 + Pillow 脚本（不在 Blender 里跑），把参考照片和同视角渲染 `case_open_photo_view.png` 拼成 `renders/compare_photo.png`（整体上下对照 + GBA 卡托 / DS 卡座 / 说明书卡扣三组局部左右对照）。
- `renders/`：`case_closed`、`case_open`（全开，卡座里有真实卡带）、`case_open_holder_detail`（卡座特写）、`case_open_photo_view`（空盒，按参考照片视角和侧光）、`compare_photo`（与照片的对照图）、UV 验证图 `case_open_cover_outside`（全开盒子的外侧 = 平铺的封面纸）和 `case_closed_cover`（关闭时封面与书脊）。UV 验证图用的是中性测试图，不是游戏封面。
- `references/nds_case_na_inside_empty.jpg`：参考照片（Wikimedia Commons，Multicherry，CC BY-SA 4.0），见 REFERENCE_NOTES。

## 坐标与单位

米制，`metersPerUnit = 1`，stage `upAxis = "Y"`。X 向右、Y 向上、Z 指向盒子正面。SceneKit 中节点变换与 Blender 数值完全相同；根节点 `NDS_CASE` 是 USD defaultPrim。

| 根节点 | 位置 | 摆放 |
|---|---|---|
| `NDS_CASE` | 关闭盒子包围盒的底面中心；x −67.5…67.5，y 0…122，z −7.25…7.25 mm | 关闭、竖放，封面朝 +Z，书脊在 −X（横版：宽 135 > 高 122） |

## 节点

盒子是双活页铰链：托盘（后半，z < 0）⟷ 书脊 ⟷ 盒盖（前半，z > 0）。两条铰链线沿 Y，位于书脊外侧两个角：后铰链 (−67.5, y, −7.25) mm，前铰链 (−67.5, y, +7.25) mm。

| 节点 | 作用 | 轴 / 范围 |
|---|---|---|
| `NDS_CASE` | 根空节点 | — |
| `CASE_TRAY` | 静态后半：`TRAY_SHELL`（壳体，开口边底板上 2 个卡扣窗）、`TRAY_RAILS`（书脊侧矮墙、上下内筋、距开口边 21 mm 的高内墙、开口边梳状筋）、`DS_CARD_HOLDER`（厚方框：竖直外脚 + 圆肩 + 平顶，高出底板 5.0 mm，右墙留推片缺口；框内底板有下沉 0.4 mm 的中窗和 4 个卡扣下方的透光槽）、`DS_CARD_CLIPS`（左右墙各 2 个卡扣：竖柱在左右两侧给卡带定位，顶部卡舌压住卡带边缘 1.5 mm，全部在卡带正面上方）、`DS_PUSH_TAB`（凸起圆角推片，凹下的三角朝 −X）、`GBA_HOLDER`（开口朝上的 U 形 GBA 卡托：两条臂和横梁高 5.2 mm，臂顶各有一根高 5.8 mm 的卡柱和内侧钩，钩下底板有透光窗；两条面板线从卡柱延伸到顶墙）、`SLEEVE_BACK`、`COVER_ART_BACK`、`TRAY_HINGE_WEB` | 静态 |
| `CASE_MEDIUM_ANCHOR` | 空节点，`CASE_TRAY` 子节点，位于 (−10.5, 45.0, −3.485) mm，无旋转 | 见下文“卡带锚点” |
| `CASE_SPINE_HINGE` | 空节点，位于后铰链线 (−67.5, 61, −7.25) mm，绕 X 转 π（本地 +Y = 世界 −Y）；只是框架，不要动它 | 静态 |
| `CASE_SPINE` | 书脊（`SPINE_PANEL`、两条内筋 `SPINE_RIBS`、PP 5 回收标 `SPINE_EMBOSS`、`SLEEVE_SPINE`、`COVER_ART_SPINE`） | 本地 `rot_y` 0（关闭）→ `π/2` |
| `CASE_LID` | 盒盖，`CASE_SPINE` 子节点，位于前铰链线（父空间 (0, 0, −14.5) mm），静止旋转 0：`LID_SHELL`（2 个卡扣下方通孔）、`LID_RAILS`（书脊侧矮墙、上下筋、距开口边 15 mm 的高筋、梳状筋、2 个伸进托盘卡扣窗的锁钩）、`LID_CLIPS`（2 个说明书卡扣：从高筋伸出的宽舌片，长 19 mm、宽 6.4→10.8→8.2 mm，截面拱起，先压向底板再在末端向上卷起；下方底板各有 21 × 11 mm 的 D 形通孔）、`SLEEVE_FRONT`、`COVER_ART` | 本地 `rot_y` 0 → `π/2` |
| `COVER_ART` / `COVER_ART_SPINE` / `COVER_ART_BACK` | 封面、书脊、封底材质槽（分别在 `CASE_LID`、`CASE_SPINE`、`CASE_TRAY` 下），共用一张封面纸图 | 见下文“封面贴图” |
| `TRADEMARK_PRINTS` | 根节点下（静态）：托盘底面竖排模压 “NINTENDO DS”（Blender 内置字体的普通文字，不是描摹的任天堂标志）`TRAY_NDS_EMBOSS` | — |
| `TRADEMARK_PRINTS_LID` | `CASE_LID` 下：盒盖内侧模压 “Nintendo” 椭圆框（普通文字 + 跑道形框）`LID_NINTENDO_EMBOSS` | — |

开盒：`CASE_SPINE` 与 `CASE_LID` 各转 `π/2`，两个角度可以同时插值。全开 (π/2, π/2) 时托盘 | 书脊 | 盒盖并排平放，内面朝上，外面都在 z = −7.25 mm，总宽 135 + 14.5 + 135 = 284.5 mm（x −217.0…67.5）。四种角度组合 (0/π/2 × 0/π/2) 都通过相交检查。可动节点位置是铰链点，不是 0，运动时只改 `eulerAngles.y`，不要改 `position`。USD 导入器不会拆分这些空节点；三个 `COVER_ART*` 节点本身带 geometry。

塑料上没有横幅：“NINTENDO DS” 白色竖条属于封面纸，由 App 画进贴图。

## 卡带锚点 `CASE_MEDIUM_ANCHOR`

- 原点 = 盒子关闭时卡座里 DS 卡带**机身中心**：(−10.5, 45.0, −3.485) mm（卡座中心距铰链边 57 mm、距顶边 77 mm）。
- 旋转为单位矩阵：本地 +Z = 卡带正面（标签面）法线，指向盒盖；本地 +Y = 卡带“上”，金手指在 −Y；+X 向右。盒子全开时从上往下看，卡带标签正向可读。
- App 卡带模型 `DuoDS/Resources/Detailed-Cartridges.usdz` 的 `/root/ndsStandard`（毫米单位，Z-up stage，但 SceneKit 按原始数值读）：实测机身 X ±16.5、Y ±17.5、Z −3.8…0（标签平面在 Z = 0，朝 +Z），最低点是背面模压字 Z −3.915，最高点是标签上方小平台 Z +0.043；金手指在 −Y（y ≈ −12，背面）。它的轴与锚点完全一致，所以挂到锚点下时：
  - `rotation` = 单位；`scale` = 0.001（毫米 → 米）；
  - `position` = (0, 0, **+1.9 mm**)（卡带原点是标签平面，比机身中心高 1.9 mm）。
  - 这样卡带背面最低点离托盘底板 0.10 mm；左右离 4 根卡扣竖柱、上下离框墙各 0.3 mm（定位框 33.6 × 35.6 mm；框墙之间左右宽 38.0 mm，和照片一致）；卡扣卡舌压在卡带边缘上方 1.5 mm 宽，底面比标签面高 0.13 mm。
- 自检直接导入这份真实网格放到锚点，在盒子关闭时与盒子全部网格做三角形相交检查，并确认卡带包围盒在卡座内框里、在底板上方、在卡座墙顶以下。

## 封面贴图

三块网格共用一张封面纸图：从盒子外侧看平铺为 封底 | 书脊 | 封面，u = 0 为封底开口边，u = 1 为封面开口边；v = 0 底边、v = 1 顶边（纸张在盒上 y 3…119 mm）。和 PS2 一样，直接把正向图片设给 `diffuse.contents`，不需要 `contentsTransform`。

| 项目 | 值 |
|---|---|
| `insert_mm` | 封底 130.0，书脊 15.7，封面 130.0，高 116.0（总 275.7 × 116） |
| `u_splits` | [0.471527, 0.528473]（= 130/275.7，145.7/275.7） |
| GameTDB `coverfullHQ`（1616 × 680） | 与 275.7 × 116 mm 的比例一致（2.3765 vs 2.3767），5.862 px/mm；折线落在 762.0 / 854.0 px，实测 764 / 856 ±3 px。整张扫描图直接 1:1 贴上即可 |
| 封面网格实际覆盖的 u | 封底 0…0.4753，书脊 0.4761…0.5239，封面 0.5247…1 |

纸在书脊两侧各多包 1.05 mm 到正/背面（书脊纸 15.7 mm，塑料书脊 13.6 mm），所以网格覆盖比折线略宽；纸的开口边在 x = 64.0 mm，盒子开口边 3.5 mm 露出塑料（和透明膜的开口一致）。三块网格默认材质 `COVER_ART_default`（#EDEDED）；在 SceneKit 中给三个节点的几何分别设置同一张图片，不要假定它们共享同一个 `SCNMaterial`。透明膜 `SLEEVE_*` 在纸外侧，不要替换它们的材质。

## 商标隐藏

把 `TRADEMARK_PRINTS` 和 `TRADEMARK_PRINTS_LID` 的 `isHidden` 同时设为 `true`，即可去掉盒子塑料上全部任天堂字样。`SPINE_EMBOSS`（PP 5 回收标）、推片三角、GBA 面板线都不是商标，不需要隐藏。

## 尺寸与面数

| 项目 | 目标 | 实测（导出 USDZ 的包围盒） |
|---|---|---|
| 外形 W × H × T | 135 × 122 × 14.5 mm | 135.0 × 122.0 × 14.5 mm |
| 三角面 | ≤ 40,000 | 8,278 |

## 自检

脚本在导出前后打印 `self-check ...`，任一项失败退出码为 1，且**不会**覆盖 `DuoDS/Resources/NDS-Case.usdz`：

1. 四个铰链角度组合下托盘 / 书脊 / 盒盖网格互不相交；
2. 重新测量 `ndsStandard` 包围盒（与脚本常量偏差 < 0.05 mm）；真实卡带网格放在锚点，盒子关闭时与盒子全部网格不相交，且位于卡座内框内；
3. 重新打开导出的 USDZ：defaultPrim、全部契约节点名、包围盒、`CASE_LID` 位置 (0, 0, −14.5 mm)、三块封面网格的 u 范围。

## 重建

从仓库根目录运行（约 50 秒，含 6 张渲染）：

```sh
/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python-exit-code 1 \
    --python Handheld_Cases/NDS/source/build_nds_case.py
```

对照图另跑 `python3 Handheld_Cases/NDS/source/compare_photo.py`。需要 Blender 5.2。输出：`exports/NDS-Case.usdz`（并复制到 `DuoDS/Resources/`）、`contract.json`、`renders/*.png`、`NDS_Case.blend`。

## 精度边界

外形 135 × 122、封面纸 130 × 116 有多个来源；厚度 14.5 取 14–15 mm 各来源的中间值。卡座、GBA 卡托、说明书卡扣、内筋、卡扣窗位置来自一张略带透视的 Commons 照片（约 ±2–3 mm）；卡座内框按实测卡带尺寸加 0.3 mm 余隙推定，而不是按照片。壁厚 1.2、分模面 z = 0、各筋高度、卡带在盒内的 Z 高度、膜厚都是结构估计。塑料颜色 #36383B（粗糙度 0.45，模压字 #3E4043）是在曝光偏亮的照片基础上按“近黑”描述调暗的近似值；照片里的浅灰主要来自过曝。照片视角渲染的相机是目测对齐的，不是标定结果。模压字用 Blender 内置字体，不是任天堂字形。2010 年 11 月以后的“环保盒”（无 GBA 卡托、说明书后有镂空回收标）未建模。
