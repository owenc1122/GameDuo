# PS2 启动流程实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. 用户要求并行：同一波次内各任务只改自己的文件，不运行 git（协调者提交）。

**Goal:** 按 `docs/superpowers/specs/2026-09-23-ps2-launch-flow-design.md` 实现 PS2 碟盒 Cover Flow、开盒、插卡插盘、游戏界面、退出与存档页（无内核）。

**Architecture:** 纯逻辑放 `DuoDS/App/PS2/Core/`（Foundation/CoreGraphics，macOS 可测）；SceneKit/SwiftUI 界面放 `DuoDS/App/PS2/`；原有文件只加平台分支。

**Tech Stack:** Swift 6 / SwiftUI / SceneKit / AVFoundation / CoreHaptics；Xcode 27.0 与 27.1 Beta；SwiftPM 测试包 `tools/ps2_tests`。

**通用约定（每个 agent 必读）：** `docs/superpowers/plans/ps2-app-brief.md`。

---

## 波次 0（协调者）：脚手架
- 在 `DuoDS.xcodeproj` 注册 `DuoDS/App/PS2/` 下全部计划文件（先放空实现）、5 个 PS2 USDZ 资源；建 `tools/ps2_tests`（SwiftPM，源码路径指向 `DuoDS/App/PS2/Core`）；确认基线编译通过。

## 波次 A（并行，纯逻辑 + 素材，TDD）
- **A1 `Core/PS2Disc.swift`**：ISO9660（2048 与 2352 字节扇区、`.bin/.cue`、CSO v1、CHD 仅识别头不解压时返回 unknown 并说明）；`PS2DiscProbe.identify(url) -> .ps2(serial,title?) | .psp | .unknown`；`SYSTEM.CNF` `BOOT2` 解析为 `SLUS-20312`。测试：合成 ISO 夹具（PS2 与 PSP 各一）。
- **A2 `Core/PS2CoverArt.swift`**：查找顺序（同名图片 → 压缩包 `cover.*` 由调用方提供 → 缓存 → 下载 URL `https://raw.githubusercontent.com/xlenore/ps2-covers/main/covers/default/<SERIAL>.jpg`（先核实仓库实际路径））；缓存目录；`frontCropRect(imageSize:) ` 按 129.5:183 居中裁切；主色提取。测试：裁切几何、查找顺序（注入文件系统/网络）。
- **A3 `Core/PS2MemoryCard.swift` + `Core/PS2SaveArchive.swift`**：文件夹式记忆卡（每游戏 `AppSupport/PS2/MemoryCards/<SERIAL>/<存档目录>/…`）；列出存档（目录名、`icon.sys` 标题、大小、修改时间）、删除、导出 `.psu`、导入 `.psu` 与 `.max`（LZARI）。测试：`.psu` 往返、`.max` 解压（自制夹具 + 公开格式说明交叉验证）。
- **A4 `Core/PS2IconSys.swift` + `Core/PS2Icon.swift`**：`icon.sys`（964 字节：标题 Shift-JIS 两行断点、背景四角色、光照向量与颜色、三个图标文件名）；`.ico`（顶点数、形状数、纹理类型、顶点/法线/UV/颜色、动画帧、纹理 128×128 RGB555 未压缩与压缩）。输出与渲染无关的数据结构。测试：合成夹具。
- **A5 音效候选**：开盒、扣盒、记忆卡插入、托盘电机，各 2–3 个免版税候选（Pixabay 许可或 Freesound CC0），记录 URL/作者/许可，剪辑成可试听 wav 放 scratch（不进仓库），协调者发给用户确认。

## 波次 B（并行）
- **B1 游戏库接入**（改 `GameLibrary.swift`、`ROMFiles.swift`）：`GamePlatform.ps2`、`GameCardKind.ps2Case`；`.iso/.cso/.chd` 用 A1 按内容分派；PS2 扩展名 `.bin/.cue`；`ROMMetadataReader` PS2 分支（标题、编号、封面走 A2）；`saveInfo/routeSave/saveKey` 的 PS2 分支指向 A3；原 PSP 行为不变。
- **B2 游戏界面**（新 `PS2GameView.swift`、`PS2ControllerView.swift`、`PS2CRTShutdown.swift`；改 `EmulatorSession.swift`、`AzaharCoreBridge.h/.mm` 仅输入扩展）：布局、远处主机、线缆、手柄交互与震动、占位画面、长按 1 秒退出回调、关机效果。
- **B3 存档页**（新 `PS2SaveBrowserView.swift`）：用 A3/A4；外观还原；导入导出（`.fileImporter/.fileExporter`）。

## 波次 C
- **C1 Cover Flow 与插入**（新 `PS2CaseStage.swift`、`PS2InsertionStage.swift`、`PS2Feedback.swift`；改 `CartridgeInsertionView.swift`、`GameLibrary.swift` 的 `CartridgeSceneFactory`、`ContentView.swift` 路由与退出）：碟盒节点与封面、点击开合、双下拉目标、主机升起、托盘跟手、吸附、收回、指示灯、记忆卡插入 → 存档页、退出反向动画（光盘飞回碟盒）。

## 波次 D
- 在 Duo（iOS 27.1）与普通 iPhone 模拟器跑全流程并截图；回归 NDS/3DS/N64/PSP；整体审查；同步到 M5。
