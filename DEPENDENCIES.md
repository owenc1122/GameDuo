# DuoDS 后端依赖说明

DuoDS 的应用层代码是独立实现，不复制 Delta 的界面、皮肤、工程结构或桥接源码。下面的仓库只作为可验证的模拟器后端和接口参考/依赖使用。

## 当前后端

- [Azahar](https://github.com/azahar-emu/azahar)：Nintendo 3DS 模拟器核心，GPL-2.0-or-later。当前锁定提交为 `c2237de04d8c08cb5ad0ba3fb98e5a9640203257`，使用上游自带的 `citra_libretro` iOS 目标构建，没有复制 Azahar 的桌面或移动端界面。DuoDS 仅实现 libretro 前端适配，并保留 3DS XL 拟物外壳。
- [melonDS DS 1.3.1](https://github.com/JesseTG/melonds-ds)：当前实际运行的 DS/DSi libretro 后端，GPL-3.0-or-later。锁定 `bc4e4b67d2d470d7c682810a1e892cafd6f9082b`，上游 melonDS 锁定 `7117178c2dd56df32b6534ba6a54ad1f8547e693`。替换旧版 Delta 桥接的运行路径后，TrailMix 白屏消失。源码与完整许可证保留在 `ThirdParty/melonds-ds`，CMake 依赖版本由上游固定。
- [ParaLLEl N64](https://github.com/libretro/parallel-n64)：原生 N64 后端，锁定 `6e4c44c51885c8dc16e46d68464c517e6fca6712`。iOS 使用 cached interpreter、Angrylion 软件渲染和 cxd4 RSP，无需 JIT。修复 arm64 逐帧停止标志及切换 ROM 时的缓存清理；补丁保留在 `RuntimeValidation/Formats/patches/parallel-n64-lifecycle.patch`。各组成部分的 GPL/LGPL 等许可证保留在源码树，不能将整体当作宽松许可代码。
- [libarchive](https://github.com/libarchive/libarchive)：ZIP、7Z、RAR/RAR5 解包，BSD 系列许可。链接 Apple SDK 的 `libarchive`，仅使用公开 API；缺失的公开头文件取自 `abaa707d92fce052f386b6cc2c8d0593ce61e639`。不会用 shell 解压用户文件。
- [DeSmuME（libretro）](https://github.com/libretro/desmume)：DS 的 HD 渲染模式后端（2x 超采样光栅化），GPL-2.0-or-later。原画模式仍走 melonDS DS。打包为 `ThirdParty/StoreCores/DeSmuMECore.xcframework`，锁定版本见 vendor-export 分支 `vendor/MANIFEST.tsv`。
- [PPSSPP](https://github.com/hrydgard/ppsspp)：PSP libretro 后端及运行时资源（`DuoDS/Resources/PPSSPP`），GPL-2.0-or-later。本地加了 `retro_duo_*` 帧率/计数/抗锯齿接口，补丁见 vendor-export 分支。
- [Play!](https://github.com/jpd002/Play-)：PS2 后端（WebAssembly，`ThirdParty/PlayWeb`），BSD-2-Clause。
- 已移除（1.0.1）：MelonDSDeltaCore、DeltaCore、ZIPFoundation。输入枚举改为自有的 `DuoInput`（rawValue 与旧枚举一致，已存按键映射不受影响），音频环形缓冲改为自有的 `AudioRingBuffer`。完整第三方清单与许可证见 `THIRD_PARTY_NOTICES.md` 和 `DuoDS/Resources/Licenses/`。

当前锁定的上游源码版本记录在各自 Git checkout 中。更新依赖时，必须重新确认许可证、iOS 构建目标、模拟器架构和接口兼容性，并更新本文件。

## 构建与本地适配

`tools/build_melonds_core.sh`、`tools/build_n64_core.sh`、`tools/build_azahar_core.sh` 分别生成包含 iOS arm64 与 Simulator arm64 的 XCFramework。Azahar 新增公开于本地桥接的 CIA/ZCIA 安装入口，按标题 ID 安装游戏、更新和 DLC；损坏安装流不会无限循环。DS 和 N64 的 SRAM 在暂停保存/退出时原子落盘；DS 旧 DLDI 镜像只在新位置不存在时复制迁移，保留原件。

当前只验证了模拟器实际运行及 iPhone 编译，未进行实体 iPhone 帧率验收。所有核心使用软件渲染/解释器，复杂游戏的性能和系统文件依赖不能由文件扩展名支持来保证。具体格式、测试证据和限制见 `RuntimeValidation/Formats/REPORT.md`。

## 当前测试 ROM

- [BotRandomness/Mars3DS](https://github.com/BotRandomness/Mars3DS)：MIT 许可的开源单人 3DS 自制射击游戏。当前固定使用 `v1.0.0` 的 `Mars3D.3dsx`，用于验证 Azahar 的 3DSX 启动、双屏视频、立体声音频、圆形摇杆、按键和触摸输入。
- [devkitPro/3ds-hbmenu](https://github.com/devkitPro/3ds-hbmenu)：当前固定使用 `v2.4.3` 的 `boot.3dsx`，在夹具中重命名为 `HomebrewMenu.3dsx`。它是开源 Homebrew Menu，不是任天堂 HOME Menu，也不包含任天堂系统文件。
- [gruvw/tic-tac-tile](https://github.com/gruvw/tic-tac-tile)：单人井字棋模式由 AI 对手响应，同时覆盖上下屏、底部触屏、按键和音频。当前固定使用其 `v1.0.0` release 中的 `tic-tac-tile.nds`，仅作为本地开发测试夹具；上游页面未显示许可证文件，正式分发前不得把它当作已获授权的产品资源。
- [Fabulu/trailmix](https://github.com/Fabulu/trailmix)：Trail Mix v3.0.0，MIT，验证新版 DS 内核从标题进入游戏。源码中描述的 SD 卡存档与卡带 SRAM 属于不同存储，不将共享 SD 镜像当作单个游戏存档删除。
- [PeterLemon/N64](https://github.com/PeterLemon/N64)：Unlicense，InputCPU 和 HelloWorld 自制测试程序，验证字节序转换、方向键、画面和连续启动。SyntheticMK64 仅是修改测试程序头部的路由夹具，没有 Mario Kart 内容。
- [EstebanPdN/mario-kart-64-3ds](https://github.com/EstebanPdN/mario-kart-64-3ds)：截图对应 v1.5 的开源移植版。用户仍需提供自己的美版原始游戏数据；程序文件不包含原作资源。导入美版 z64/n64/v64 后自动规范化并放入虚拟 SD 的 `3ds/MK64/mk64.z64`，或接受用户自己的 `mk64.o2r`。
- 原先的 [Chi-Iroh/Pong-NDS](https://github.com/Chi-Iroh/Pong-NDS) 仍保留在 `TestFixtures/` 作为旧测试素材，但不再随应用默认加载。

## 不包含的内容

- 不包含任何商业 ROM、BIOS、固件、游戏存档或从第三方项目提取的资源。
- 不包含或伪造任天堂 HOME Menu、共享字体、系统档案、密钥或主机唯一数据。Azahar 要运行依赖这些文件的标题时，仍必须使用用户从自己 3DS 导出的文件；开源 Homebrew Menu 不能替代任天堂固件。
- 不复用 Delta 的控制器皮肤、映射文件和产品文案。
- 不将第三方项目的源码复制到 `DuoDS/App`；应用层只通过公开模块接口调用模拟器。

## 构建边界

运行 `tools/build_azahar_core.sh` 会按 Azahar 官方 CI 参数分别构建 iOS 真机和 arm64 模拟器核心，并生成 `ThirdParty/AzaharCore.xcframework`。随后构建 `DuoDS.xcworkspace`；Xcode 会从 XCFramework 自动选择当前平台，工程不再依赖任何额外的 Xcode 子工程。

## ROM 元数据与 3D 卡带依据

- NDS banner 的偏移、32×32 tiled 4bpp 图标、BGR555 调色板和多语言标题读取方式，依据 [Epicpkmn11/bannergif.py](https://gist.github.com/Epicpkmn11/282e10b07b3aba997078aee5bd59105e) 与 [TinkeDSi](https://github.com/R-YaTian/TinkeDSi) 的公开格式说明重新实现为 Swift；没有复制其界面或代码结构。
- NDS/DSi 类型使用 ROM header `0x12` 的 unit code；`0=NDS`、`2=NDS+DSi`、`3=DSi only` 的定义由 [ImHex NDS pattern](https://github.com/WerWolv/ImHex-Patterns/blob/master/patterns/nds.hexpat) 交叉确认。
- 红外 Slot-1 卡带沿用当前 melonDS 内核的 game-code 判定规则，来源是项目已锁定版本中的 `NDSCart.cpp`，因此前端识别和实际内核识别保持一致。
- 3DSX 的 SMDH 偏移、SMDH 标题结构、48×48 tiled RGB565 图标顺序，依据 [devkitPro/3dstools](https://github.com/devkitPro/3dstools) 的 `3dsxtool.cpp` 和 `smdhtool.cpp` 重新实现。
- DS/3DS 实体卡的基础几何比例使用公开记录的 `33 × 35 × 3.8 mm`。SceneKit 模型按真实毫米比例生成厚度、倒角、3DS 防误插凸耳、背部触点和标签材质，不使用 2D 卡片冒充 3D。
- 前端按游戏目标机器选择实体卡带：`.3dsx` 与 `.3ds`/CCI/CXI 都显示白色 3DS 卡，`.nds` 会继续细分普通 NDS、红外黑卡、DSi enhanced 和白色 DSi exclusive。自制程序虽然通常从 SD 卡启动，但这里按用户选择的“目标机器卡带陈列”规则展示，不把启动介质当作游戏平台。
