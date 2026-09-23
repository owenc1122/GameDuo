# PS2 模型设计：主机、DualShock 2、记忆卡、光盘与光盘盒

日期：2026-09-22 · 状态：已确认

## 目标

为 Game Duo 后续的 PS2 支持准备可交互的 3D 资产，接入方式与现有 PSP-2000 / UMD 相同：运行时 SceneKit 按固定节点名控制可动部件。本次只交付模型，不包含 PS2 模拟内核和 App 接入代码。

## 已确认的决定

| 项 | 决定 |
|---|---|
| 主机型号 | 初代厚机 SCPH-30001（NTSC-U，黑色），前置托盘光驱 |
| 用途 | 仅 App 运行时资产：USDZ、面数预算、固定节点名 |
| 地区 | 美版：黑色 DVD 盒、顶部白色 PlayStation 2 横条、蓝底 DVD |
| 交互 | 托盘弹出/收回；RESET、EJECT 按下；电源与弹出指示灯；手柄插头与记忆卡插拔；光盘可取出；盒盖可开合 |
| 手柄 | 完整 DualShock 2，所有按键、肩键、摇杆均可操作 |
| 资料 | 官方规格 + 公开照片/拆机图 + 开源 CAD 仅作测量交叉验证，不复制第三方网格 |
| 做法 | Blender Python 脚本程序化建模，可重跑 |
| 商标 | 默认显示，全部挂在 `TRADEMARK_PRINTS` 下，可一键隐藏 |
| 运行机器 | M2 上建模和验证；完成后只新增文件同步到 M5 |

## 目录

```
PS2_Model/              主机、DualShock 2、8 MB 记忆卡
PS2_Disc_Case/          DVD 光盘、美版光盘盒
  *.blend               可编辑源文件
  source/*.py           建模、导出、验证脚本
  exports/*.usdz        运行时资产（同时复制到 DuoDS/Resources/）
  renders/              检查渲染图
  REFERENCE_NOTES.md    每个尺寸的来源与可信度
  validation.json       自动校验结果
  README.md             节点约定与接入说明
```

## 坐标与单位

米制；X 向右、Y 向上、Z 指向物件正面（主机前面板、手柄朝向玩家的一侧、盒子封面）。不施加额外缩放。每个物件的根节点位于其外形包围盒底面中心。

## 节点约定

### 主机 `PS2-Console.usdz`

| 节点 | 类型 | 动作 |
|---|---|---|
| `PS2_CONSOLE` | 根 | — |
| `DISC_TRAY` | 平移 | 本地 +Z，0 为收回，最大行程见 REFERENCE_NOTES |
| `TRAY_DISC_ANCHOR` | 空节点，`DISC_TRAY` 子节点 | 光盘数据面朝下放置的位置 |
| `BTN_RESET`、`BTN_EJECT` | 平移 | 本地 -Z 按下约 1 mm |
| `LED_POWER` | 材质 | `off` / 红色待机 / 绿色开机 |
| `LED_EJECT` | 材质 | `off` / 蓝色 |
| `PORT_CTRL_1`、`PORT_CTRL_2` | 空节点 | 手柄插头完全插入时的对位 |
| `SLOT_MC_1`、`SLOT_MC_2` | 空节点 | 记忆卡完全插入时的对位 |
| `TRADEMARK_PRINTS` | 组 | 所有商标印刷 |

### 记忆卡 `PS2-MemoryCard.usdz`

`PS2_MEMORY_CARD` 根节点；原点在插入端中心，沿本地 -Z 插入，与 `SLOT_MC_n` 对齐即为完全插入。

### DualShock 2 `PS2-DualShock2.usdz`

| 节点 | 动作 |
|---|---|
| `DUALSHOCK2` | 根 |
| `DPAD` | 以中心为支点向四个方向倾斜 |
| `BTN_TRIANGLE`、`BTN_CIRCLE`、`BTN_CROSS`、`BTN_SQUARE` | 沿按键轴按下 |
| `L1`、`R1` | 平移按下 |
| `L2`、`R2` | 绕铰链旋转 |
| `STICK_L`、`STICK_R` | 以球心为支点倾斜；沿轴按下为 L3/R3 |
| `BTN_SELECT`、`BTN_START`、`BTN_ANALOG` | 按下 |
| `LED_ANALOG` | 材质 `off` / 红色 |
| `CABLE` | 从手柄到插头的一段线缆 |
| `CTRL_PLUG` | 原点在插入端中心，与 `PORT_CTRL_n` 对齐即为完全插入 |
| `TRADEMARK_PRINTS` | 商标印刷 |

### 光盘 `PS2-DVD.usdz`

`PS2_DVD` 根节点在盘心；`DISC_LABEL` 为印刷面材质槽（运行时替换贴图，默认白底）；数据面为 PS2 蓝黑色。

### 光盘盒 `PS2-Case.usdz`

| 节点 | 动作 |
|---|---|
| `PS2_CASE` | 根 |
| `CASE_LID` | 绕书脊铰链旋转，0 为关闭，约 180° 全开 |
| `CASE_DISC_ANCHOR` | 光盘在卡轴上的位置 |
| `COVER_ART` | 封面材质槽，默认空白 |
| `TRADEMARK_PRINTS` | 顶部 PlayStation 2 横条等印刷 |

## 面数预算（三角面）

主机 ≤ 60k；DualShock 2 ≤ 40k；光盘盒 + 光盘 ≤ 15k；记忆卡 ≤ 3k。

## 材质

全部为 USD Preview Surface 可表达的参数（基色、粗糙度、金属度、透明度、自发光）。主机哑光黑、顶部横纹、蓝色 PS2 标识；手柄黑色，△绿 ○红 ×蓝 □粉；DVD 数据面蓝黑；盒体黑色，透明外封套。

## 尺寸依据

每个尺寸在 `REFERENCE_NOTES.md` 中标明来源等级：**官方**、**交叉验证**（两个以上独立来源一致）、**照片校准**（以官方外形尺寸为比例尺从正视照片测得）。关键外形：主机 301 × 78 × 182 mm；DVD 120 × 1.2 mm，中心孔 15 mm；美版盒 190 × 135 × 14 mm。

## 验收

1. 外形尺寸与目标相差 ≤ 0.5 mm，写入 `validation.json`。
2. 面数不超预算；上表节点全部存在。
3. 每个可动部件在两端极限位置与周围几何无相交。
4. Swift 脚本在 SceneKit 中载入每个 USDZ，找到全部节点并执行一次各动作。
5. 渲染：主机正面/背面/托盘打开，手柄正面/顶部，记忆卡插入，盒子打开并将光盘放上托盘。

## 不在范围内

PS2 模拟内核；App 内 PS2 平台、游戏库和插盘动画代码；真实游戏封面；实机测量。
