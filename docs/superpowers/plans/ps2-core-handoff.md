# PS2 内核接入：交接说明（2026-09-23，从 M2 移到 M5）

分支 `ps2-core`，最新提交 `8fe939a`。完整 Git 历史在 `work/GameDuo-history.bundle`：
`git clone work/GameDuo-history.bundle ~/Developer/GameDuo -b ps2-core`（包含 main、ps2-models、ps2-launch-flow、ps2-core）。

设计：`docs/superpowers/specs/2026-09-23-ps2-core-design.md`。Play! 补丁说明：`ThirdParty/PlayWeb/README.md`。

## 已完成、已验证（iPhone Duo 模拟器，M2）

- Play!（BSD-2）编译成 WebAssembly，跑在 WKWebView 里，由 WebKit 的 JIT 执行重编译后的代码；符合 App Store 规则。
- 画面在上半屏（内屏竖屏、外屏都验证过），显式提交帧，已无频闪。
- 手柄：全部按键、摇杆；补全了 Play! 的 libpad 协议（ps2sdk 自制游戏也能识别 DualShock 2）；震动链路已接通（未在真机感受）。
- 读盘：ISO 从游戏库启动正常；修了 Play! 读取超过一个扇区的光盘目录时丢文件的 bug。
- 记忆卡：双向同步自检通过（`-ps2-core-card-selftest`）。
- 前后台：切后台暂停、回前台恢复；长按主机退出时先暂停并同步存档。
- 声音：AudioWorklet + 环形缓冲 + 动态速率控制；统计显示 0 次缓冲见底（44.1 kHz 满速）。
- 启动失败（空壳光盘）会显示"无法启动：光盘里没有可运行的 PS2 程序"。
- 性能：TyraCraft 3D 场景大多 58–59 fps（M2 模拟器）；模拟速度约为实时的 98%。

## 未完成

1. **声音听感仍然卡（用户反馈）**：音频线程统计干净（无欠载），怀疑是模拟出的声音本身断续，或 Mac 模拟器的 CoreAudio 过载。下一步：用 `-ps2-core-audio-capture` 录 10 秒实际输出（写到 App 的 Documents/duo_audio_capture.pcm，44.1 kHz 立体声 Int16），分析是否有断口；在真机上听一次对比。
2. BIN/CUE（MODE2/2352）和 CSO 镜像已生成但未跑：`~/Developer/ps2core/games/disc/TyraCraft.{cue,bin,cso}`。CHD 未测（需要 chdman 生成）。
3. 商业游戏兼容性与重型 3D 性能：需要用户自己的正版镜像。
4. 真机测试（性能、震动、声音）。
5. 自制程序的 SBV 补丁：TyraCraft 的 ELF 是手工去掉了检查的版本；Play! HLE BIOS 无法真正打 SBV 补丁，尚无通用方案。

## 编译

- Play! Web 核心：`ThirdParty/PlayWeb/build.sh`。需要 Python ≥ 3.10 给 emsdk：
  `EMSDK_PYTHON=/Applications/Blender.app/Contents/Resources/5.2/python/bin/python3.13 ThirdParty/PlayWeb/build.sh`
  工作目录 `~/Developer/ps2core`（已同步：打好补丁的 `Play-` 源码、测试游戏；emsdk 首次运行会自动下载安装）。产物自动拷到 `DuoDS/Resources/PS2Web/`。
- 注意：`Source/iop/*` 等文件是 CRLF 换行，修改时要保留；Play! 补丁改完后用 `git diff > ThirdParty/PlayWeb/duo.patch` 更新（新文件先 `git add -N`）。
- App：同之前（arm64 模拟器，`-derivedDataPath build/DD`）。

## QA 启动参数（DEBUG）

- `-ps2-autoplay N`：插入第 N 个 PS2 游戏（加 `-ps2-autoplay-card` 则插记忆卡）。
- `-ps2-core-elf <文件夹>`：直接启动文件夹里的 ELF（`~/Developer/ps2core/games/tyracraft/host`）。
- `-ps2-core-disc <镜像>`：启动指定光盘镜像。
- `-ps2-core-card-selftest`、`-ps2-core-audio-capture`、`-ps2-hittest-selftest`。
- 日志前缀：`DUO_PS2_CORE`（帧率、存档、错误）、`DUO_PS2_AUDIO`（音频统计）。
- TyraCraft 操作：✕ 确认；存档页 R1 切到 Create，✕ 新建世界。
- `~/Developer/ps2core/m2-qa-scripts/` 是 M2 上用的脚本（路径和模拟器 UDID 需按 M5 修改）。
