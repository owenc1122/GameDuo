# PS2 内核接入设计（App Store 路线）

日期：2026-09-23　分支：`ps2-core`　前置：`2026-09-23-ps2-launch-flow-design.md`（界面流程已完成）

## 目标

在 App Store 规则内让 PS2 游戏稳定运行，性能尽量接近原生：
- 游戏画面在上半屏（现有 50% 布局不变），DS2 手柄可操作，有声音、手柄震动。
- 镜像格式：ISO、BIN/CUE（含多轨）、CSO、CHD、ISZ。
- 每个游戏独立记忆卡，游戏内存档实时落盘到 App 的记忆卡文件夹，存档页照常可见。
- 退出、切后台、内核崩溃都能安全收尾，不丢存档。

## 为什么是 WebAssembly + WKWebView

App Store 不允许 App 自己 JIT；WebKit 的 JIT 是例外。Play!（BSD-2）的代码生成器有 WebAssembly 后端：EE/VU 的 MIPS 代码在运行时被重编译成 wasm，再由 WebKit JIT 成 ARM64。原型实测（`b086cd0`）：
- 自定义协议 + COOP/COEP → `crossOriginIsolated=true`；共享 `WebAssembly.Memory` + Worker + Atomics 可用；全局 `SharedArrayBuffer` 缺失，用共享内存的 `buffer.constructor` 补上。
- wasm 紧循环 ≈ 原生速度；WebGL2、SIMD 可用。
- TyraCraft（开源 PS2 自制游戏）满速 59fps，不限帧约 1.7–1.8 倍余量（M2 模拟器，轻场景）。

## 组成

### 1. Play! Web 构建（`ThirdParty/PlayWeb/`）

- 固定 Play! 提交 `83700b2`，本地补丁 `duo.patch`，构建脚本 `build.sh`（emsdk + cmake/ninja，EMSDK_PYTHON 用 ≥3.10 的 Python），产物 `Play.js` / `Play.wasm` 拷到 `DuoDS/Resources/PS2Web/`，连同 `index.html`、`duo.js` 一起进 App 包。`LICENSE-Play.txt` 保留 BSD 版权声明。
- 补丁内容（`Source/ui_js/`）：
  - **输入**：去掉键盘回调，改为 `CInputProviderDuo`：每个按键、每根摇杆轴一个绑定目标，导出 `duoSetPad(buttonsMask, lx, ly, rx, ry)` 一次写入整帧手柄状态；马达绑定把大小马达强度回调给 JS（`Module.duoOnVibration`）。
  - **控制**：导出 `duoInit(w, h)`、`duoBootDisc(path)`、`duoBootElf(path)`、`duoPause()`、`duoResume()`、`duoSetPresentation(w, h)`、`duoGetFrames()`。
  - **读盘**：`CJsDiscImageDeviceStream` 记住文件路径；读取在调用它的工作线程里用同步 XHR（带 Range）完成，不再绕主线程轮询；256 KB 块缓存 + 顺序预读。BIN/CUE 的多个文件按文件名各自请求。
  - **记忆卡**：mc0 指向 `/duo/mc0`（MEMFS）。
  - **自制程序 SBV 补丁**：加载 ELF 时识别 ps2sdk `sbv_patch_*` 的调用失败分支，令其视为成功（HLE BIOS 无法真正打补丁；Play! 本身支持从内存加载 IRX）。

### 2. App 侧内核宿主（`DuoDS/App/PS2/Web/`）

| 文件 | 职责 |
|---|---|
| `PS2WebCore.swift` | 持有 WKWebView；启动/暂停/恢复/停止；手柄状态合帧下发（CADisplayLink，状态变化才发）；接收 JS 消息（就绪、首帧、帧率、震动、存档写入、错误）；WebContent 进程崩溃处理 |
| `PS2WebSchemeHandler.swift` | `duops2://` 协议：包内 Web 资源（加 SAB 垫片）、光盘文件（Range，仅限本次游戏的镜像目录）、记忆卡读写（GET 清单/文件，PUT/DELETE 回写） |
| `PS2WebPad.swift` | 手柄状态模型：libretro 按键 id → PS2 按键位；摇杆 −1…1 → 0…255；纯逻辑，SwiftPM 可测 |
| `PS2CardSync.swift` | 记忆卡双向同步的纯逻辑（路径校验、防目录穿越），SwiftPM 可测 |

- **输入接口**：新增 `PS2InputSink` 协议（`setPS2Button` / `setPS2Analog`），`EmulatorSession` 与 `PS2WebCore` 都实现；`PS2ControllerView` 改为依赖协议。
- **画面**：`PS2ScreenView` 在内核首帧后显示 WKWebView（透明背景、canvas 按实际像素尺寸），之前继续显示封面占位；显像管关机效果照常叠加。
- **记忆卡**：启动前把该游戏的记忆卡文件夹整体写入 `/duo/mc0`；JS 每 1 秒比对 mc0 的文件大小/修改时间，变化的文件 PUT 回 App，删除的 DELETE；暂停、退出、切后台前强制同步一次。
- **声音**：Play! 的 OpenAL → WebAudio；WKWebView 设 `mediaTypesRequiringUserActionForPlayback = []`，JS 在启动时 `resume()` 音频上下文。
- **震动**：大马达 → 强度随值变化的连续震动，小马达 → 轻脉冲（CoreHaptics），遵循系统触感设置。
- **生命周期**：进入后台 → 同步存档 + 暂停；回前台 → 恢复（若不是用户暂停）。长按主机退出 → 暂停 → 同步存档 → 显像管关机动画 → 销毁 WebView。WebContent 进程被系统终止 → 显示"内核已停止"并允许直接退出，存档以最后一次同步为准。

### 3. 启动流程接线

`PS2RuntimeModel` 在光盘插入动画结束（现有"开始游戏"时刻）创建 `PS2WebCore`，传入镜像 URL 与该游戏记忆卡目录；"等待 PS2 内核"占位改为"正在启动…"，首帧到达后切换。

## 测试

- SwiftPM（`tools/ps2_tests`）：`PS2WebPad` 映射、`PS2CardSync` 路径校验与差异计算、Range 解析。
- 模拟器实测（DEBUG 启动参数）：`-ps2-core-elf <dir>` 直接启动文件夹里的 ELF（TyraCraft），验证画面、帧率、手柄输入、震动日志、存档落盘、暂停/恢复、切后台、退出。
- 镜像格式：用脚本把 TyraCraft 打成 ISO / CSO / BIN+CUE 验证读盘路径。

## 已知限制（Play! 上游）

- 浏览器环境无内存页写保护：运行时在 EE 上加载模块的游戏可能出错（JIT 缓存无法失效）。
- 无法控制浮点舍入模式：个别游戏可能有画面/逻辑问题。
- 兼容性以 Play! 为准（见 jpd002/Play-Compatibility）。
