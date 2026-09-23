# PS2 App 开发通用说明（给开发 agent）

## 环境
- 仓库根目录下工作，分支 `ps2-launch-flow`。**不要运行 git**（协调者提交）。其他 agent 同时在改别的文件，只改任务里列出的文件；需要改列表外的文件时先在报告里说明。
- 设计：`docs/superpowers/specs/2026-09-23-ps2-launch-flow-design.md`；计划：`docs/superpowers/plans/2026-09-23-ps2-launch-flow.md`；模型与节点约定：`PS2_Model/README.md`、`PS2_Disc_Case/README.md`（滑动类动作是相对静止位置的偏移；USD 导入会出现 `NAME` + `NAME_mesh`）。
- M2 只有 8 GB 内存：同一时间只跑一个 `xcodebuild`；编译前用 `pgrep -f xcodebuild` 看有没有别人在编，有就等（`until ! pgrep -f "xcodebuild .*DuoDS" >/dev/null; do sleep 15; done`）。
- 编译（模拟器）：
  ```bash
  DEVELOPER_DIR=/Applications/Xcode-Beta-27.1.app/Contents/Developer xcodebuild -workspace DuoDS.xcworkspace -scheme DuoDS -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData build 2>&1 | tail -30
  ```
  代码也必须能用正式版 Xcode 27.0 编译：不要用 iOS 27.1 才有的 API。
- 纯逻辑单元测试：`cd tools/ps2_tests && swift test`（macOS，源码来自 `DuoDS/App/PS2/Core`，所以 Core 里只能 import Foundation / CoreGraphics / ImageIO / zlib 等 macOS 也有的框架，不能用 UIKit/SceneKit）。

## 代码风格
- 跟周围代码一致：SwiftUI + SceneKit，中文用户可见文字用 `String(localized:)`，注释少而准。
- PS2 新代码放 `DuoDS/App/PS2/`；文件已在 Xcode 工程里注册（空实现），直接填写。要新增文件时在报告里列出，协调者注册。
- 不要把大段逻辑塞进 `ContentView.swift` / `CartridgeInsertionView.swift`，那里只加分支和调用。

## 报告
状态（DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT）、改了哪些文件、公开 API（签名）、测试与编译输出原文、问题。
