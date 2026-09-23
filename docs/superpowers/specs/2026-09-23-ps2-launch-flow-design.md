# PS2 启动流程设计：碟盒 Cover Flow、开盒、插卡插盘、游戏界面、退出、存档管理

日期：2026-09-23 · 状态：已确认 · 前置：`2026-09-22-ps2-models-design.md`（5 个 PS2 运行时模型）

## 范围

本轮做 1–6，不接 PS2 模拟内核（游戏画面用占位）。

1. PS2 平台接入游戏库：按内容识别、读游戏编号、自动封面。
2. Cover Flow 展示美版碟盒；点击开盒（双铰链、音效）；盒内光盘与记忆卡均可下拉。
3. 光盘插入主机动画；记忆卡插入主机动画。
4. 游戏界面：上游戏画面、中远处主机、下 DualShock 2（可按、震动、线缆连主机）。
5. 退出动画：老电视关机 → 托盘弹出 → 光盘飞回碟盒 → 盒盖扣上 → Cover Flow。
6. 记忆卡存档管理页（1:1 还原 PS2 浏览器外观；导入导出）。

不在范围：PS2 模拟内核（下一个子项目，候选 Play!）。

## 已确认的决定

| 项 | 决定 |
|---|---|
| 框架 | 沿用 SceneKit 与现有 `DragCartridgeSceneView` 状态机；PS2 新代码放 `DuoDS/App/PS2/`，原有文件只加平台分支 |
| 识别 | `.iso/.cso/.chd` 按内容区分：含 `SYSTEM.CNF`（`BOOT2`）→ PS2；含 `PSP_GAME/PARAM.SFO` → PSP；PS2 另支持 `.bin/.cue` |
| 编号 | 从 `SYSTEM.CNF` 的 `BOOT2 = cdrom0:\SLUS_203.12;1` 得 `SLUS-20312` |
| 封面 | ① 同目录同名图片 / 压缩包内 `cover.*` → ② 按编号从 `xlenore/ps2-covers` 下载并缓存（默认开启，设置可关）→ ③ 空白封面，可手动更换（沿用现有编辑封面） |
| 封面填充 | 按美版封面纸正面 129.5 × 183 mm 等比填满，居中裁切，不拉伸；书脊/背面用封面主色延展 |
| 记忆卡 | 每个游戏一张文件夹式记忆卡（目录，PS2 存档结构），卡面显示 8 MB 但不设容量上限 |
| 存档页 | 完整还原：3D 旋转图标（`icon.sys` + `.ico`）、名称/大小/日期、复制（导出）/删除/返回；导入 `.psu`、`.max`，导出 `.psu`；不使用 Sony BIOS 素材与声音 |
| 布局 | 所有设备同一套竖屏布局（Duo 内屏/外屏、普通 iPhone、iPad）；Duo 不避让镜头；其他设备避让灵动岛/刘海 |
| 音效 | 开盒/扣盒、记忆卡插入、托盘电机：免版税（Pixabay / Freesound CC0）候选先给用户试听确认；光盘卡上托盘沿用现有插入音效 |
| 占位画面 | 游戏封面 + 标题 + “等待 PS2 内核”；不使用 Sony 开机动画 |

## 交互流程

### Cover Flow 与开盒
- PS2 游戏在 Cover Flow 中是合上的 `PS2-Case`，封面贴 `COVER_ART`，`COVER_ART_SPINE` / `COVER_ART_BACK` 用封面主色延展；顶部黑色横条（商标）保留。
- 点击选中的盒子：`CASE_SPINE`、`CASE_LID` 依次转开（真实双铰链，约 0.55 s），播放开盒声。
- 打开态盒内：卡轴上的光盘（`DISC_LABEL` 贴该游戏封面，圆形裁切）与托架内的 8 MB 记忆卡。两者分别可下拉。
- 再点盒盖、或左右滑动 Cover Flow：盒子扣上，播放扣盒声。打开态下水平滑动先扣盒再滚动。

### 下拉记忆卡
- 主机从下方升起（与 PSP 主机升起同样的节奏）。`MC_DOOR_1` 翻开，记忆卡跟手插向 `SLOT_MC_1`；到位时咔哒声 + 震动。
- 进入该游戏存档页。退出存档页：卡拔出、翻盖合上、主机下沉、卡回到盒内托架。

### 下拉光盘
- 主机升起；托盘 `DISC_TRAY` 按光盘与托盘的距离同步弹出（跟手，最大 0.135 m）。
- 松手过阈值：光盘吸附到 `TRAY_DISC_ANCHOR`，播放现有插入音效与震动；托盘自动收回（约 0.9 s，托盘电机声）。
- 指示灯：`LED_POWER` 红 → 绿；`LED_EJECT` 蓝色闪烁（读盘，约 1.2 s）。随后进入游戏界面。

### 游戏界面（竖屏）
- 上半屏：游戏画面 4:3（支持 16:9 输入）按比例最大化；无内核时显示占位。
- 中间空隙：缩小的 PS2 主机，透视 + 轻景深表现“远处”；`LED_POWER` 绿常亮，读盘时 `LED_EJECT` 闪。
- 下半屏：DualShock 2 顶视 3D 模型，按正确比例最大化占满下半屏。十字键、△○×□、SELECT、START、ANALOG、双摇杆（倾斜 + 按下）直接在模型上操作并有真实行程；L1/L2/R1/R2 以 2D 按钮平铺在手柄上方对应位置。
- 手柄线：从手柄出线口沿自然下垂曲线连到远处主机 `PORT_CTRL_1`，随布局实时生成。
- 震动：所有按键按下/松开各一次（不同强度）；摇杆只在越过最大有效半径那一圈时震一次（回到圈内再越过会再震）。
- 输入：扩展桥接层支持右摇杆、L2/R2、L3/R3（libretro joypad id），内核接入即可用。

### 退出
- 长按远处主机 1 秒 → 仅上半屏播放老电视关机（画面收成白色横线 → 亮点 → 熄灭）。
- 远处主机托盘弹出，光盘升起并由远及近飞到眼前；画面随光盘上移，光盘回到碟盒卡轴，盒盖扣上（扣盒声），回到 Cover Flow。

### 存档管理页（1:1 外观还原）
- 深色背景 + 漂浮光晕；左上角“记忆卡（PS2）/1”。
- 存档以各自 3D 图标在网格中旋转展示，背景色/光照取 `icon.sys` 设定。
- 选中显示名称、大小、日期，操作：复制（导出到“文件”App，`.psu`）/ 删除（确认）/ 返回。
- 导入：从“文件”App 导入 `.psu` 或 `.max`（LZARI 解压）。

## 模块划分（`DuoDS/App/PS2/`）

| 模块 | 职责 | 依赖 |
|---|---|---|
| `Core/PS2Disc.swift` | 镜像识别、ISO9660 读取、`SYSTEM.CNF` 解析、编号 | Foundation |
| `Core/PS2CoverArt.swift` | 封面查找顺序、下载与缓存、裁切几何 | Foundation / CoreGraphics |
| `Core/PS2MemoryCard.swift` | 文件夹式记忆卡：列出/删除/导入/导出存档 | Foundation |
| `Core/PS2IconSys.swift`、`Core/PS2Icon.swift` | `icon.sys`、`.ico`（顶点动画 + 纹理）解析 | Foundation |
| `Core/PS2SaveArchive.swift` | `.psu` 读写、`.max`（LZARI）读取 | Foundation |
| `PS2CaseStage.swift` | Cover Flow 中碟盒节点、开合、盒内光盘/记忆卡、封面材质 | SceneKit |
| `PS2InsertionStage.swift` | 主机升起、托盘跟手弹出、吸附、收回、指示灯、记忆卡插入 | SceneKit |
| `PS2GameView.swift` | 游戏界面布局、远处主机、手柄线、占位画面、退出长按 | SwiftUI / SceneKit |
| `PS2ControllerView.swift` | DualShock 2 顶视模型、触控 → 输入、震动 | SceneKit / UIKit |
| `PS2CRTShutdown.swift` | 老电视关机效果 | SwiftUI / Core Animation |
| `PS2SaveBrowserView.swift` | 存档页 UI 与 3D 图标渲染 | SwiftUI / SceneKit |
| `PS2Feedback.swift` | 开盒/扣盒/记忆卡/托盘音效与震动 | AVFoundation / CoreHaptics |

`Core/` 只依赖 Foundation / CoreGraphics，另用 `tools/ps2_tests/`（SwiftPM，源码指向 `DuoDS/App/PS2/Core`）在 macOS 上 `swift test` 做单元测试。

原有文件改动（最小化）：`GamePlatform` 加 `.ps2`、`GameCardKind` 加 `.ps2Case`；`ROMFiles` 内容识别；`ROMMetadataReader` 分派；`DragCartridgeSceneView` 加 PS2 分支（开盒点击、双下拉目标、主机、托盘）；`EmulatorView` 路由到 `PS2GameView`；`exitGame` 走 PS2 退出；`AzaharCoreBridge` 扩展右摇杆/L2/R2/L3/R3 输入。

## 验收

1. Xcode 27.0 与 27.1 Beta 均可编译；在 iPhone Duo（iOS 27.1 模拟器）与普通 iPhone 模拟器上跑完整流程，逐步截图检查。
2. `swift test`（tools/ps2_tests）覆盖：PS2/PSP 识别、编号解析、封面查找顺序与裁切、`icon.sys`/`.ico` 解析、`.psu` 往返、`.max` 解压。
3. 现有 NDS/3DS/N64/PSP 流程不回归（模拟器上各跑一次插卡与退出）。
4. 音效来源与许可写入 `CREDITS.md`。
