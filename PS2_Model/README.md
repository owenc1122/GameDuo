# PS2 主机、DualShock 2 与 8 MB 记忆卡

初代厚机 SCPH-30001（NTSC-U/C，黑色，前置托盘）、DualShock 2（SCPH-10010，黑色）和 8 MB 记忆卡（SCPH-10020，黑色）的 App 运行时资产。全部由 Blender Python 脚本程序化建模，可从零重建；运行时 SceneKit 按固定节点名控制可动部件，接入方式与 PSP-2000 / UMD 相同。光盘与光盘盒见 `../PS2_Disc_Case/README.md`，总体设计见 `docs/superpowers/specs/2026-09-22-ps2-models-design.md`。

参考数据（每个尺寸的来源与可信度），按物件分开：

- 主机：[`REFERENCE_NOTES_console.md`](REFERENCE_NOTES_console.md)
- DualShock 2：[`REFERENCE_NOTES_controller.md`](REFERENCE_NOTES_controller.md)
- 记忆卡：[`REFERENCE_NOTES_memory_card.md`](REFERENCE_NOTES_memory_card.md)

## 文件

- `exports/PS2-Console.usdz`、`exports/PS2-DualShock2.usdz`、`exports/PS2-MemoryCard.usdz`：运行时资产。已按 `PS2-Console.usdz`、`PS2-DualShock2.usdz`、`PS2-MemoryCard.usdz` 复制到 `DuoDS/Resources/`，**尚未加入 Xcode target**，接入时需手动添加。
- `PS2-Console.blend`、`PS2-DualShock2.blend`、`PS2-MemoryCard.blend`：构建脚本保存的源文件，每次重建都会覆盖，不要手工编辑后指望保留；要改请改脚本或契约。
- `source/build_console.py`、`source/build_dualshock2.py`、`source/build_memory_card.py`：建模与导出脚本。`source/render_dualshock2.py` 是手柄检查渲染（由 `build_dualshock2.py --render` 调用）。`source/trace_memory_card_prints.py` 从照片描出记忆卡 “MagicGate” 字样，结果 `source/memory_card_prints_traced.json` 已提交，构建时直接读取，不必重跑（需要 opencv）。
- `validation.json`：`tools/ps2_blender/validate_ps2.py` 写入的自动校验结果（尺寸、面数、节点、各运动两端穿模检查）。
- `renders/`：检查图。主机 `console_front34 / rear / tray_open`（托盘弹出、1 号槽插卡），手柄 `ds2_front / top / motion`，记忆卡 `memory_card_top / prints / 34_rear / 34_connector`。
- `references/console|controller|memory_card/`：参考照片，来源与许可见各 REFERENCE_NOTES。
- 尺寸、颜色、运动范围等数据写在 `tools/ps2_blender/contract.json` 与 `tools/ps2_blender/contract_parts/<资产名>.json`（part 覆盖主文件，脚本通过 `common.load_contract()` 读取合并结果）。

## 坐标与单位

米制，1 单位 = 1 m，`metersPerUnit = 1`，stage `upAxis = "Y"`。X 向右、Y 向上、Z 指向物件正面。不要额外施加厘米/毫米缩放。SceneKit 忽略 upAxis，节点变换与 Blender 中的数值完全相同。根节点是 USD defaultPrim，即 SceneKit 场景根下的第一个节点，没有额外 `/root` 包装。

| 资产 | 根节点 | 根节点位置 | 摆放 |
|---|---|---|---|
| 主机 | `PS2_CONSOLE` | 包围盒底面中心；x −150.5…150.5，y 0…78，z −91…91 mm | 平放，前面板（鳍片）朝 +Z |
| DualShock 2 | `DUALSHOCK2` | 机身包围盒底面中心（不含线缆和插头） | 平放在桌面，按键朝上（+Y），握把朝玩家（+Z），肩键和线缆朝 −Z |
| 记忆卡 | `PS2_MEMORY_CARD` | 接口端面中心；卡体 x −21…21，y −3.75…3.75，z 0…56.5 mm | 平放，标签面朝上（+Y），接口端朝 −Z |

## SceneKit 接入约定

所有可动节点的静止姿态为位置 0、旋转 0（需要倾斜的部件把倾角放在父级 `*_MOUNT` 空节点上）；表中的轴是该节点在父节点空间中的本地轴，运动时直接写 `position` 或 `eulerAngles` 的对应分量。范围两端都已通过穿模检查（`validation.json`）。

USD 导入器会把**带子节点的网格**拆成 transform 节点 `NAME` 和几何子节点 `NAME_mesh`（例如 `BTN_RESET` → `BTN_RESET` + `BTN_RESET_mesh`，`DISC_TRAY` → `DISC_TRAY` + `DISC_TRAY_mesh`）。移动时操作 `NAME`；换材质时找带 geometry 的节点，即 `NAME` 本身或其 `NAME_mesh` 子节点。节点名在各自资产内唯一，用 `childNode(withName:recursively: true)` 查找。

### 主机 `PS2-Console.usdz`

| 节点 | 作用 | 轴 / 范围 |
|---|---|---|
| `DISC_TRAY` | 光驱托盘（含托盘面板、120/80 mm 盘槽） | 本地 Z 平移，0（收回）→ `0.135` m（弹出） |
| `TRAY_DISC_ANCHOR` | 空节点，`DISC_TRAY` 子节点；光盘圆心（厚度中点）落在 120 mm 盘槽上的位置 | 静止；把 `PS2_DVD` 以单位变换挂到这里即为标签面朝上放在托盘上 |
| `TRADEMARK_PRINTS_TRAY` | `DISC_TRAY` 子节点；托盘面板上的彩色 PS 标志（随托盘移动，所以不能放在 `TRADEMARK_PRINTS` 下） | — |
| `BTN_RESET` | RESET/电源键（有 `BTN_RESET_mesh` 几何子节点） | 本地 Z 平移，0 → `-0.001` m（按下） |
| `BTN_EJECT` | EJECT 键（有 `BTN_EJECT_mesh` 几何子节点） | 本地 Z 平移，0 → `-0.001` m |
| `LED_POWER` | 电源指示灯镜片，**`BTN_RESET` 的子节点**（实机导光柱是键帽的一部分，随键移动） | 材质 `LED_POWER_off`（#2B1C1C）；待机红 `#FF2A1A`，开机绿 `#35E06A` |
| `LED_EJECT` | 弹出指示灯镜片，**`BTN_EJECT` 的子节点** | 材质 `LED_EJECT_off`（#1C1F2B）；亮起蓝 `#3A7BFF` |
| `MC_DOOR_1`、`MC_DOOR_2` | 记忆卡槽弹簧门（印 MEMORY CARD），原点在铰链线 (x, 65.45, 89.6) mm | 本地 X 旋转，0（关闭）→ `π/2`（向内上翻进门袋） |
| `SLOT_MC_1`、`SLOT_MC_2` | 空节点；记忆卡完全插入时 `PS2_MEMORY_CARD` 根节点的位姿，位于 (−100.8 / −50.3, 61.5, 49.5) mm | 静止 |
| `PORT_CTRL_1`、`PORT_CTRL_2` | 空节点；手柄插头完全插入时 `CTRL_PLUG` 的位姿，位于 (−100.8 / −50.3, 47.0, 82.3) mm | 静止 |
| `TRADEMARK_PRINTS` | 其余全部印刷：顶面蓝色 PS2 标志与 “PlayStation 2” 凸字、银色竖排 SONY、背面贴纸、光盘格式条、“1 / MagicGate / 2”、接口标记、蓝色面板图标、背面接口文字、保修封条、EXPANSION BAY | — |
| `BODY`、`DETAILS` | 静态机身与附件（USB 面板、接口、风扇、电源开关、扩展仓盖、脚垫） | 静态 |

指示灯：LED 默认是关闭色，材质名含 `_off`。开灯时替换该节点几何的材质，或把 `emission.contents` 设为上面的颜色（官方说明书：待机亮红，开机变绿）。

**卡槽门必须先开**：门关闭时插入的记忆卡与门相交。App 显示某个槽里的记忆卡之前，先把对应的 `MC_DOOR_n` 转到 `π/2`（或隐藏该门）；拔卡后再转回 0。

### DualShock 2 `PS2-DualShock2.usdz`

| 节点 | 作用 | 轴 / 范围 |
|---|---|---|
| `DPAD` | 一体十字键，支点在 (−46.5, 50.5, −12.5) mm | 本地 X、Z 旋转，各 `±0.0873` rad（±5°）；按哪个方向就向哪边倾 |
| `BTN_TRIANGLE`、`BTN_CIRCLE`、`BTN_CROSS`、`BTN_SQUARE` | △（绿）○（红）×（蓝）□（粉）面键，符号在键帽几何里 | 本地 Y 平移，0 → `-0.002` m |
| `BTN_SELECT`、`BTN_START` | SELECT / START | 本地 Y 平移，0 → `-0.001` m |
| `BTN_ANALOG` | ANALOG 键 | 本地 Y 平移，0 → `-0.0008` m |
| `LED_ANALOG` | 模拟模式指示灯（根节点直接子节点） | 材质 `LED_ANALOG_off`（#4A0E0C）；亮起红 `#FF2B1C` |
| `STICK_L`、`STICK_R` | 左右摇杆，支点在球心 (∓23, 44, 10.5) mm | 本地 X、Z 旋转，各 `±0.4363` rad（±25°）；本地 Y 平移 0 → `-0.0008` m 为 L3/R3 |
| `L1`、`R1` | L1/R1，挂在 `L1_MOUNT` / `R1_MOUNT` 下（父级绕 X 转 −90°，本地 −Y = 世界 +Z，即压进机身的方向） | 本地 Y 平移，0 → `-0.002` m |
| `L2`、`R2` | L2/R2，铰链在 (∓46.5, 28, −40) mm | 本地 X 旋转，0 → `-0.1396` rad（−8°，扳机向机身方向扣下） |
| `CABLE` | 从机身出线口到插头的一段静态线缆（含磁环） | 静态；插头移走后线缆不会跟随，App 插线时可隐藏 |
| `CTRL_PLUG` | 手柄插头，原点在插入端面中心，沿本地 −Z 插入；挂在 `CTRL_PLUG_MOUNT` 下（静止时放在手柄前方桌面上） | 插入主机：把 `CTRL_PLUG` 的世界变换设为 `PORT_CTRL_n` 的世界变换（或以单位变换挂到 `PORT_CTRL_n` 下） |
| `TRADEMARK_PRINTS` | SONY、PS 标志、“PlayStation”、“DUALSHOCK 2”、SELECT/START/ANALOG 字样、L/R 字母、十字键箭头 | — |
| `DS2_BODY`、`DS2_SEAM`、`DS2_SCREWS` | 静态机身、合模线、背面螺丝 | 静态 |

`size_mm` 157 × 62 × 95 含摇杆高度，不含 `CABLE` 和 `CTRL_PLUG`。

### 记忆卡 `PS2-MemoryCard.usdz`

| 节点 | 作用 |
|---|---|
| `PS2_MEMORY_CARD` | 根节点，原点在接口端面中心，沿本地 −Z 插入；把它的世界变换设为 `SLOT_MC_n` 的世界变换即为完全插入（插入 41.5 mm，外露 15 mm，标签面朝上）。插卡前先打开对应的 `MC_DOOR_n`。 |
| `SHELL` | 黑色卡体（倒角、防滑波纹、三角标记、接口窗口） |
| `CONNECTOR_PINS` | 8 个金色触点 |
| `TRADEMARK_PRINTS` | PS 标志、“PlayStation 2”、8MB、MEMORY CARD、MagicGate 印刷，以及凸起 0.2 mm 的 SONY（`EMBOSS_SONY`） |

记忆卡没有可动部件。

### 对位约定汇总

| 空节点 | 对齐对象 | 含义 |
|---|---|---|
| `TRAY_DISC_ANCHOR`（主机，`DISC_TRAY` 子节点） | `PS2_DVD` 根节点 | 光盘在托盘里，标签面朝上、数据面朝下；随托盘移动 |
| `SLOT_MC_1` / `SLOT_MC_2`（主机） | `PS2_MEMORY_CARD` 根节点 | 记忆卡完全插入时的位姿 |
| `PORT_CTRL_1` / `PORT_CTRL_2`（主机） | `CTRL_PLUG`（手柄） | 手柄插头完全插入时的位姿 |

对位空节点都没有旋转，两个物件的本地坐标系直接重合即可。插拔动画沿对齐后的本地 Z 平移：记忆卡和插头从 +Z 方向（主机前方）移入到 0。

## 商标隐藏

商标默认显示。需要隐藏时把下列节点的 `isHidden` 设为 `true`：

| 资产 | 要隐藏的组 |
|---|---|
| 主机 | `TRADEMARK_PRINTS`、`TRADEMARK_PRINTS_TRAY`（后者在托盘下，随托盘移动） |
| DualShock 2 | `TRADEMARK_PRINTS` |
| 记忆卡 | `TRADEMARK_PRINTS`（包括凸字 SONY） |

这些组里除商标外也包含普通印刷（主机接口文字、手柄 SELECT/START、记忆卡 8MB 等），隐藏后这些文字一起消失。面键符号、RESET/EJECT 图标、卡槽门上的 MEMORY CARD 字样属于部件本身，不在商标组内。

## 尺寸与面数

`validation.json` 中的测量值（在根节点空间测量顶点包围盒，容差 0.5 mm）：

| 资产 | 目标尺寸 (mm) | 实测 (mm) | 三角面 / 预算 |
|---|---|---|---|
| 主机 | 301 × 78 × 182 | 301.0 × 78.04 × 182.16 | 16,321 / 60,000 |
| DualShock 2（不含线缆、插头） | 157 × 62 × 95 | 157.037 × 62.0 × 95.008 | 37,068 / 40,000 |
| 记忆卡 | 42 × 7.5 × 56.5 | 42.0 × 7.5 × 56.5 | 2,780 / 3,000 |

## 精度边界

REFERENCE_NOTES 中每个数值都标有等级：**官方**（Sony 说明书）、**交叉验证**（两个以上独立来源一致）、**照片校准**（以官方或交叉验证的外形尺寸为比例尺，从照片测得）、**估计**（无可测依据，仅为建模占位；契约 JSON 中列在 `estimated_keys` 或标为 `估计`）。

- **主机**：只有外形 301 × 78 × 182、质量 2.2 kg、接口种类数量、LED 红/绿色是官方数据。鳍片、上下层、接口、按键位置为照片校准（整体约 ±1.5 mm，小部件约 ±2 mm，被悬挑遮挡处约 ±4 mm）。托盘行程 135 mm 由照片推算（可能 128–145）；托盘长度、扩展仓深度、侧面垫位置、按键与接口内部深度、记忆卡外露 15 mm 均为估计。
- **DualShock 2**：外形 157 × 95、重量为交叉验证；按键 X/Z 布局约 ±1.5 mm，高度方向约 ±3 mm（线稿前视与侧视自身差约 3 mm）。所有行程、摇杆与 L2/R2 转轴、插头主体尺寸、磁环为工程估计，可能差 30% 以上。
- **记忆卡**：宽 42、厚 7.5 为两个独立社区 CAD 交叉验证；长 56.5 为三张照片长宽比（约 ±1 mm）；印刷位置约 ±0.5 mm；接口窗口、隔筋、防呆为估计。
- **印刷字形**：PS 标志、SONY、“PlayStation 2” 字标、SELECT/START、L/R、面键符号和方向键箭头来自共享矢量 `tools/ps2_blender/vectors/`（Sony 官方手册矢量或 Wikimedia Commons，见该目录 `README.md`）。没有公开矢量的字样用系统字体近似：主机 RESET、MEMORY CARD、MagicGate、1/2、S400、背面文字和贴纸小字用 Arial / Arial Bold；手柄 “DUALSHOCK 2”、“ANALOG” 用 Arial Bold / Arial；记忆卡 8MB、MEMORY CARD 用 Helvetica，MagicGate 从照片描摹。字体字形为近似，大小和位置按照片拟合。
- 所有颜色都是照片近似值，没有色度计数据。不在范围内：实机测量、生产丝印母版。

## 重建方法

从仓库根目录运行：

```sh
tools/ps2_blender/run_all.sh            # 重建五个 PS2 资产并运行全部检查
tools/ps2_blender/run_all.sh --render   # 另外输出主机、手柄、记忆卡的检查渲染
```

脚本按顺序（M2 只有 8 GB 内存，Blender 一次只开一个）执行：记忆卡 → DualShock 2 → 主机（带 `--check`，用记忆卡 `.blend` 和手柄插头代理做插槽配合检查，因此记忆卡必须先建）→ DVD → 光盘盒；然后运行 `tools/ps2_blender/tests/run_tests.sh`（校验器自测）、`validate_ps2.py`（全部资产，更新 `validation.json`）和 `verify_scenekit.swift`（SceneKit 实际载入、找节点、执行每个动作）。任一步失败则退出码非 0；日志在 `build/ps2_logs/`。

单独构建某个资产：

```sh
B="/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python-exit-code 1"
$B --python PS2_Model/source/build_memory_card.py [-- --render]
$B --python PS2_Model/source/build_dualshock2.py [-- --render]
$B --python PS2_Model/source/build_console.py [-- --check] [--render]
$B --python tools/ps2_blender/validate_ps2.py -- --only PS2-Console
xcrun swift tools/ps2_blender/verify_scenekit.swift --only PS2-Console
```

需要 Blender 5.2（脚本用到自带的 OpenVDB、`import_curve.svg` 和 USD 导出）以及 macOS 系统字体 Arial、Helvetica。重建后如需更新 App 资源，把 `exports/*.usdz` 再复制到 `DuoDS/Resources/`。
