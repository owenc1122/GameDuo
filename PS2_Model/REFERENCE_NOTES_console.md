# PS2 主机 SCPH-30001（NTSC-U/C，黑色，前置托盘）参考数据

对应数据文件：`tools/ps2_blender/contract_parts/PS2-Console.json`。

## 坐标约定

- 单位 mm（模型内按 m 使用）。原点在包围盒底面中心。
- X 为宽度，向右为正（正对前面看）。Y 为高度，向上为正。Z 为深度，朝前为正。
- 前面鳍片前沿在 z=+91，后面在 z=−91，左侧在 x=−150.5，右侧在 x=+150.5。
- 等级说明：
  - **官方**：Sony 官方说明书原文。
  - **交叉验证**：两个相互独立的来源一致。
  - **照片校准**：用官方外形尺寸给照片定比例，再用 OpenCV 标定相机后求出。本文列出了所用照片。
  - **估计**：没有可测量的依据，只是给建模留的占位数值，JSON 里也标成 `估计`。
- 注意：任务模板里的等级只有前三种。为了不把估计值冒充成测量值，另外加了第四种"估计"。

## 1. 官方规格

| 项目 | 数值(mm) | 来源 URL | 等级 |
|---|---|---|---|
| 外形 W×H×D | 301 × 78 × 182（约值） | SCPH-30001 英/法/西说明书 Specifications 页：https://archive.org/details/scph-30001_202606 | 官方 |
| 质量 | 2.2 kg（4 lb 14 oz） | 同上 | 官方 |
| 外形（日版 39000） | 约 301 × 78 × 182，约 2.2 kg | JA SCPH-39000 说明书：https://archive.org/details/ja-scph-39000-web | 交叉验证 |
| 前面接口 | 手柄口×2、MEMORY CARD 槽×2、USB×2、S400 i.LINK×1 | SCPH-30001 说明书 "Inputs/outputs on the console front" | 官方 |
| 后面接口 | AV MULTI OUT×1、DIGITAL OUT (OPTICAL)×1、EXPANSION BAY×1，另有 MAIN POWER 开关、AC IN | 同上（Rear panel 图示） | 官方 |
| 指示灯 | 待机亮红，开机变绿（位于 ⏻/RESET 键） | 同上，"Playing a game" 一节 | 官方 |
| 维基/Dimensions.com | 78.7 × 302.3 × 182.9 mm，2.2 kg | https://en.wikipedia.org/wiki/PlayStation_2 ；https://www.dimensions.com/element/playstation-2 | 仅供参考 |

说明：维基和 Dimensions.com 的数字由英寸换算而来（3.1 × 11.9 × 7.2 in），没有引用来源，不采用。模型一律使用官方的 301 × 78 × 182。

## 2. 整体形体

| 项目 | 数值(mm) | 来源 URL | 等级 |
|---|---|---|---|
| 上层（鳍片叠层）高度 | y 37.7 → 78，高约 40.3 | 背面照片的右侧鳍片剖面；FR 照片中前面鳍片的投影 | 交叉验证（两张照片，偏差 < 0.8） |
| 鳍片数量与节距 | 6 片（第 1 片即顶板），节距 7.28，鳍厚约 4.2（顶板约 4.6），槽高约 3.0 | 同上 | 交叉验证 |
| 各鳍片 y 范围 | 73.5–78.0 / 66.5–70.8 / 59.3–63.6 / 52.0–56.2 / 44.8–48.9 / 37.7–41.6 | 同上 | 交叉验证 |
| 鳍片槽深 | 约 3.0 | 背面照片（右侧鳍片剖面） | 照片校准，photo: scph30001_back_evanamos_3840.jpg |
| 鳍片分布面 | 前面、右侧（x+）有鳍片；左侧（x−）和后面是平板 | FR/FL/BL/BR 四视照片 | 照片校准 |
| 下层箱体 | x −150.5 → +122.5（宽 273），y 0 → 36.0，z −91 → +70（深 161） | FR 相机求底边 z 值（全宽一致为 69.3–70.0）；背面相机求 x+ 侧面在 122.1–122.5 | 交叉验证（前视、后视） |
| 下层前面缩进 | 比鳍片前沿缩进约 21（z ≈ 70）。若机脚把箱底抬高 2 mm，缩进约为 18.5 | FR 标定 | 照片校准，photo: scph30001_FR_evanamos_3840.jpg |
| 右侧悬挑 | 上层在 x 122.5 → 150.5 处悬空，约 28 | 前视、后视两种测量 | 交叉验证 |
| 上下层之间的缝 | 下层顶面 y ≈ 36.0，上层底面 y ≈ 37.7，缝约 1.7 | 背面照片 | 照片校准，photo: scph30001_back_evanamos_3840.jpg |
| 侧面格栅 | 两侧都没有格栅。进风口只有下层前面的格栅和后部风扇（鳍片槽是否通风无法确认） | FR/FL/BR | 照片校准 |
| 底面脚垫 | 6 个方形橡胶螺丝盖兼脚垫，约 7.5 见方，位置 (x,z)：(−144,−78)、(−17.8,−81)、(110.5,−79)、(−140.3,40.2)、(−22.1,62.7)、(107,62.7) | iFixit 底面照片：https://www.ifixit.com/Teardown/Sony+PlayStation+2+Teardown/1250 （第 4 步） | 照片校准（以下层底面 273×161 作比例，约 ±4） |
| 左侧竖放垫 | 4 个小橡胶垫，大致在四角 | FR 照片 | 估计（±5） |

## 3. 前面布局（z=+91 为鳍片面，z=+70 为下层前面）

"中心"一列为 (x 距中线, y 距底面)。

| 项目 | 中心 (x, y) | 宽 × 高 | 来源 | 等级 |
|---|---|---|---|---|
| 托盘前脸/开口（第 3、4 片） | (60.3, 57.9) | 126.5 × 12.1（x −3.0 → +123.5，y 51.8 → 63.9） | FR 照片分缝点 + iFixit 右前特写 | 照片校准，photo: scph30001_FR_evanamos_3840.jpg、ifixit_front_right_buttons_1600.jpg |
| 托盘行程 | 135（区间 128–145） | — | iFixit 光驱俯视照片推算：碟心到托盘前沿约 73，加碟片半径 61，再留约 2 的余量 | 照片校准（推算，把握较低） |
| 托盘长度（弹出后外形） | 约 156；弹出时前沿 z=226，后端 z≈70 | — | iFixit 光驱照片：https://guide-images.cdn.ifixit.com/igi/fmXPhajFUeuLaA6J.huge | 估计 |
| ⏻/RESET 键 | (136.0, 69.0) | 11.0 × 10.5 | FR 标定（10.5×10）；iFixit 特写（约 12.8×11.2） | 照片校准 |
| 电源 LED | (140.4, 71.7) | Ø 约 1.6 | FR 标定 | 照片校准；颜色（红/绿）为官方 |
| ⏏ OPEN 键 | (136.2, 46.3) | 11.0 × 10.5 | FR 标定 | 照片校准 |
| OPEN LED | (140.2, 42.2) | Ø 约 1.6 | FR 标定；蓝色取自 30007R 照片 | 照片校准 |
| SONY 竖排字标 | (145.6, 58.5) | 5.3 × 24（S 在上方） | FR 标定 + iFixit 特写 | 照片校准 |
| PlayStation 彩色家族标（可旋转） | (60.8, 54.5) | 11.5 × 9.5 | FR 标定 + iFixit 特写 | 照片校准 |
| MEMORY CARD 槽 1 | (−100.8, 61.5) | 41 × 9.5 | FR 标定 + iFixit 左前特写的比例 | 照片校准，photo: ifixit_front_left_ports_1600.jpg |
| MEMORY CARD 槽 2 | (−50.3, 61.5) | 41 × 9.5 | 同上（两槽间距 50.5） | 照片校准 |
| 手柄口 1 | (−100.8, 47.0) | 37.3 × 9.5 | 同上 | 照片校准 |
| 手柄口 2 | (−50.3, 47.0) | 37.3 × 9.5 | 同上 | 照片校准 |
| "1"、"MAGICGATE"、"2" 印字（第 2 片） | x −100.8 / −74.5 / −50.3，y 68.6 | — | iFixit 左前特写 | 照片校准 |
| 蓝色 USB/i.LINK 面板 | (−120.9, 17.0)，z≈70 | 35.5 × 25（下缘 y≈4.5；上缘被悬挑挡住，偏估计） | FR 蓝色像素分割 + iFixit 左前特写 | 照片校准 |
| USB 1（上） | (−128.3, 22.0) | 13.3 × 6.5（含金属壳） | 同上 | 照片校准 |
| USB 2（下） | (−128.3, 13.3) | 13.3 × 6.5 | FR 孔洞分割 | 照片校准 |
| i.LINK S400 | (−112.3, 20.2) | 7.0 × 4.6 | FR 孔洞分割 + iFixit 特写 | 照片校准 |
| 下层前面格栅 | (4.5, 19.0) | 187 × 26（x −89 → +98；下缘 y 6.1 实测，上缘 y≈32 为估计） | FR 逐列扫描；横槽节距约 3.1 | 照片校准 |

## 4. 后面布局（z=−91）

| 项目 | 中心 (x, y) | 宽 × 高 | 来源 | 等级 |
|---|---|---|---|---|
| 风扇格栅 | (−49.3, 41.2) | 61.3 × 62.2 | 背面相机标定（rms 4 px） | 照片校准，photo: scph30001_back_evanamos_3840.jpg |
| MAIN POWER 翘板 | (−112.3, 63.1) | 20.6 × 11.8（外框 26.5 × 15.3） | 同上 | 照片校准 |
| AC IN（C8） | (−112.1, 46.8) | 26.5 × 14.7 | 同上 | 照片校准 |
| DIGITAL OUT (OPTICAL) | (−94.7, 16.3) | 11.9 × 11.0 | 同上 | 照片校准 |
| AV MULTI OUT | (−122.9, 15.1) | 22.1 × 8.1 | 同上 | 照片校准 |
| EXPANSION BAY 开口 | (51.8, 21.8) | 124.6 × 30.4（x −10.5 → +114.1） | 同上；开口深度 145 为估计 | 照片校准 |
| EXPANSION BAY 盖板 | (51.8, 21.8) | 约 128 × 32 | BR 照片目估 | 估计 |
| 铭牌贴纸区（上层后面） | (67.0, 58.5) | 125.8 × 24.5 | 同上 | 照片校准 |

说明：后面 x− 这一半（风扇和电源）是一块从底到顶齐平的平面。x+ 这一半中，上层后面贴着铭牌，下面是扩展仓。

## 5. 顶面

| 项目 | 数值(mm) | 来源 | 等级 |
|---|---|---|---|
| 蓝色 PS2 标 | 中心 (x 20.5, z 0)，沿 z 长 128，字高（x 方向）24。文字沿 +z（后→前）读，字头朝 +x | FR 与背面两台相机分别求出：x 8.8–33.4，z −65.7 → +65.3 | 交叉验证 |
| PlayStation 2 压纹字标 | 中心 (x −1.3, z 1)，长 62，字高约 9.5，在 PS2 标的 −x 侧约 5.5 | FR 标定 | 照片校准 |
| CD/DOLBY/dts/DVD 标识条 | x 61 → 139，z 78 → 88 | FR 标定 | 照片校准 |

## 6. 颜色与材质（sRGB 近似值）

| 部位 | Hex | 依据 | 等级 |
|---|---|---|---|
| 机身哑光黑（细颗粒磨砂） | #242426（照片亮面实测 #4D4D4D，含布光） | Evan Amos 照片取样后，按反照率压暗 | 估计 |
| 按键面/托盘前脸（略有光泽） | #1C1C1E / #202022 | 同上 | 估计 |
| 蓝色端口面板 | #2E5AA6（阴影处实测 #32528A） | FR + iFixit | 照片校准 |
| 顶面 PS2 标渐变 | 字头 #757ABB（蓝紫）→ 字脚 #92CAE9（青蓝） | FR 像素取样 | 照片校准 |
| RESET 图标 | #3FBFB0（青绿；实测 #4F9995） | FR | 照片校准 |
| OPEN 图标 | #6F86D6（实测 #677BA9） | FR | 照片校准 |
| SONY 前面字标 | #D6D6D6 银白 | iFixit 特写 | 照片校准 |
| PS 家族标 红/黄/绿/蓝 | #D52B1E / #F2B43A / #2FA39A / #2F6FB0 | FR 取样（偏暗，已提亮） | 估计 |
| LED 待机红 / 开机绿 / OPEN 蓝 | #FF2A1A / #35E06A / #3A7BFF | 红绿为官方说明书文字，蓝为照片；Hex 本身是估计值 | 官方（颜色种类）/ 估计（Hex） |

## 7. 照片（已下载到 `PS2_Model/references/console/`）

| 文件 | 原始 URL | 许可 | 用途 |
|---|---|---|---|
| scph30001_FR_evanamos_3840.jpg | https://commons.wikimedia.org/wiki/File:Sony-PlayStation-2-30001-Console-FR.jpg | Public domain（Evan-Amos） | 主标定相机：正面、左侧、顶面。像素坐标以这张 3840 宽的缩略图为准 |
| scph30001_back_evanamos_3840.jpg | https://commons.wikimedia.org/wiki/File:PS2-Fat-Console-Back.jpg | Public domain（Evan-Amos） | 后面接口、右侧鳍片剖面（没装扩展仓盖） |
| scph30001_BR_evanamos_1920.jpg | https://commons.wikimedia.org/wiki/File:Sony-PlayStation-2-30001-Console-BR.jpg | Public domain | 后面带扩展仓盖、左侧 |
| scph30001_FL_evanamos_1920.jpg | https://commons.wikimedia.org/wiki/File:Sony-PlayStation-2-30001-Console-FL.jpg | Public domain | 右侧鳍片、下层右端 |
| ifixit_front_left_ports_1600.jpg | https://www.ifixit.com/Teardown/Sony+PlayStation+2+Teardown/1250 （第 1 步，igi/cgH5rrus13xmGFdH） | iFixit CC BY-NC-SA 3.0 | 近正视：存储卡槽、手柄口、USB、i.LINK 的比例 |
| ifixit_front_right_buttons_1600.jpg | 同上（igi/MBtZPKgOyS4hyNDu） | iFixit CC BY-NC-SA 3.0 | 近正视：RESET/OPEN、LED、SONY、托盘分缝 |

`PS2_Model/references/` 根目录下还有几张较早下载的主机照片（2026-09-22 用 Commons API 按文件名与图像比对确认来源，与 Commons 缩略图逐像素一致，差异只来自重新压缩）：

| 文件 | 原始 URL | 作者 / 许可 | 用途 |
|---|---|---|---|
| scph30001_back_evanamos.jpg | https://commons.wikimedia.org/wiki/File:PS2-Fat-Console-Back.jpg | Evan-Amos / Public domain | 与 `console/scph30001_back_evanamos_3840.jpg` 同一原图的 1600 宽版本（重复，测量以 3840 版为准） |
| scph30001_fl_evanamos.jpg | https://commons.wikimedia.org/wiki/File:Sony-PlayStation-2-30001-Console-FL.jpg | Evan-Amos / Public domain | 与 `console/scph30001_FL_evanamos_1920.jpg` 同一原图的 1600 宽版本（重复） |
| scph30001_set_evanamos.jpg | https://commons.wikimedia.org/wiki/File:PS2-Fat-Console-Set.jpg | Evan-Amos / Public domain | 主机 + 手柄 + 记忆卡合影：整体比例、颜色对照 |
| scph30007r_front.jpg | https://commons.wikimedia.org/wiki/File:SCPH-30007R_front_view_20210103.jpg | Solomon203 / CC BY-SA 4.0（原图，字节一致） | 插着记忆卡的前面：记忆卡外露约 15 mm（估计）、OPEN LED 蓝色 |
| scph30007r_rear.jpg | https://commons.wikimedia.org/wiki/File:SCPH-30007R_rear_view_20210103.jpg | Solomon203 / CC BY-SA 4.0 | 背面贴纸、扩展仓盖、风扇格栅、电源开关布局核对 |
| scph5001_eject_reset_deniwilliams.jpg | https://commons.wikimedia.org/wiki/File:Sony_Playstation_2_SCPH-5001_V9_-_Bot%C3%B5es_Eject_e_Reset_Eject_and_Reset_buttons_(19290929960).jpg | Deni Williams / CC BY 2.0 | RESET / EJECT 键与图标、LED 位置特写（SCPH-50001 同款前面板） |

另外参考过但没有放进仓库的资料：
- SCPH-30001 说明书封面线图（只说明布局关系，比例不准）。
- iFixit 光驱照片（用来推算托盘行程）。
- iFixit 底面照片（脚垫）。
- Commons 上的 "SCPH-30000 vertical.jpg"（CC BY-SA 3.0，Qurren）和 "PlayStation 2 comparison.png"。

## 8. 开源 CAD 核对

| 来源 | URL | 许可 | 标注尺寸 |
|---|---|---|---|
| GrabCAD "Playstation 2 Fat Version"（renato diego） | https://grabcad.com/library/playstation-2-fat-version-1 | GrabCAD 社区条款（非商业） | 页面没有给出尺寸（需要登录才能看文件），没有下载 |
| Sketchfab "PS2 FAT Remaster"（Patrixon95F） | https://sketchfab.com/3d-models/ps2-fat-remaster-d3f4ebafa77346d9988b68785f660b83 | CC BY | 描述里没有尺寸 |
| Sketchfab "PS2 Fat"（ricinreine）、"PS2_Fat_LowPoly"（TolgaKorkmaz） | https://sketchfab.com/3d-models/ps2-fat-b7400859dec14c83b80226afcc8c41e3 ；https://sketchfab.com/3d-models/ps2-fat-lowpoly-17ee3260915f41778fd22aa99ab957e0 | CC BY | 没有尺寸，作者自称"不完美" |

结论：没有找到带尺寸、能说明精度的开源 CAD，所以本文数据没有用 CAD 交叉验证。

## 测量方法

1. **FR 相机**：把顶面四角（301 × 182）和左后下角作为已知点，用 OpenCV 的 solvePnP 求相机姿态，焦距用一维搜索确定（重投影 rms 约 10 px，相当于 1 mm 左右）。
   - 用光线与平面求交得到各点坐标：鳍片面 z=91，下层前面 z=70，顶面 y=78，左侧 x=−150.5。
   - 检验：下层前面底边沿全宽得到的 z 在 69.3–70.0 之间，彼此一致。
2. **背面相机**：用同样方法标定（rms 约 4 px）。顶面 PS2 标的求交结果与 FR 相机相差在 2 mm 以内。

## 精度边界

- **官方数据只有这几项**：外形 301 × 78 × 182、质量 2.2 kg、接口的种类和数量、LED 的红绿色。其余全部是照片测量或估计，不是 Sony 的工程图。
- **照片校准的误差**：
  - 整体结构（鳍片高度、下层范围、后面接口）约 ±1.5 mm。
  - 小部件（按键、LED、USB、卡槽开口）约 ±2 mm。
  - 被悬挑挡住的上缘（USB 面板、前格栅）约 ±4 mm。
- **把握较低的几项**：
  - 托盘行程 135 mm：由光驱照片推算，可能范围 128–145。
  - 托盘长度 156：估计。
  - 扩展仓深度 145：估计。
  - 左侧竖放垫的位置：估计。
  - 机身基色 Hex：照片受布光影响。
  - 下层前面缩进 21 mm：如果机脚高度不是 0，会变为约 18.5–21。
- **没有核实的项**：鳍片槽是否为通风口，鳍片与按键的倒角半径，USB/手柄口/卡槽的内部深度。JSON 中的深度值都是占位。
- **机型差异**：用到的 iFixit 照片是同代机型（带 S400 i.LINK 和扩展仓），但不能确认是否为 30001。Evan Amos 的照片是 SCPH-30001 R（翻新机），外壳与 30001 相同。
