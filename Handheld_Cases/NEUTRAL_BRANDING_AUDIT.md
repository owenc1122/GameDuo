# 中性外观：商标审计

所有用户、所有游戏看到的卡带、UMD、零售盒、封面纸和主机模型（DS/3DS/PSP/PS2）一律不带 Sony / Nintendo 的名称、标志和型号（1.0.1 起，老板 10-03 要求去掉机身标识）。联网下载的零售封面保留。
1.0 build 13 曾按 ROM 的 SHA-256 只对 App Review 的测试游戏隐藏商标，这属于对审核区别对待，已整段删除，不要再加回任何"识别审核环境"的逻辑。

运行时规则在 `DuoDS/App/NeutralBranding.swift`。长期目标是把这些节点和贴图直接从 USDZ/PNG 资产里删掉，删完后对应规则可以去掉。

## 清单

| # | 位置 | 元素 | 文件 / 节点 / 材质 | 处理方式 |
|---|---|---|---|---|
| 1 | 游戏库 Cover Flow 下方平台行 | “NINTENDO DS” / “NINTENDO 3DS” / “SONY PSP” | `GameLibrary.swift` `GameLibraryView`（`game.platform.rawValue`） | 改用 `GamePlatform.displayName`（DS / 3DS / N64 / PSP / PS2，不带厂商名）；rawValue 已持久化，不能改 |
| 2 | DS / 3DS 卡带正面 | 标签上方模压 “NINTENDO DS” / “NINTENDO 3DS” | `Detailed-Cartridges.usdz` 各卡型 `Front_platform*` | 隐藏节点 |
| 3 | DS / 3DS 卡带背面 | 模压 “Nintendo” | `Back_maker_mark*` | 隐藏节点 |
| 4 | DS / 3DS 卡带背面 | 型号 “NTR-005” / “CTR-005” | `Molded_model_number*` | 隐藏节点 |
| 5 | 卡带模型缺失时的代码备用卡带 | `SCNText` “NINTENDO DS…” 品牌字和 NTR/CTR 型号 | `CartridgeSceneFactory.addBackContacts` | 品牌字和型号的代码已删除 |
| 6 | UMD 外壳 | “PSP” 标志 | `PSP-UMD.usdz` `PSP_shell_vector___path6945/6947/6949*` | 隐藏节点 |
| 7 | UMD 外壳 | PlayStation 风格手柄标记 | `Gamepad___photo_traced_shell_mark*` | 隐藏节点 |
| 8 | UMD 中心白色徽章 | “UMD” 字样（运行时由 `filledUMDBadgeLetter` 填充） | `UMD_shell_vector___svg_*`（白色底座 `Fixed_UMD_white_centre_badge` 保留，无字） | 隐藏节点 |
| 9 | DS 盒 | 托盘模压 “NINTENDO DS”、盒盖内侧 “Nintendo” 椭圆框 | `NDS-Case.usdz` `TRADEMARK_PRINTS/TRAY_NDS_EMBOSS`、`TRADEMARK_PRINTS_LID/LID_NINTENDO_EMBOSS` | 隐藏 `TRADEMARK_PRINTS*` |
| 10 | 3DS 盒 | 托盘模压 “Nintendo 3DS” | `3DS-Case.usdz` `TRADEMARK_PRINTS/TRAY_NINTENDO_3DS_EMBOSS` | 同上 |
| 11 | UMD 盒 | 卡座模压 “UMD” | `PSP-UMD-Case.usdz` `TRADEMARK_PRINTS/TRAY_UMD_EMBOSS` | 同上 |
| 12 | 盒内封面纸（占位图） | 正面白色竖条 “NINTENDO DS” / “NINTENDO 3DS”，黑色横条 “PSP” | `HandheldCaseCoverArt.swift` `drawFrontBanner` | `HandheldCaseInsert.render(neutral: true)`：不画横条，标题区占满正面 |
| 13 | 封面纸书脊 | 顶部 “NINTENDO DS/3DS” 白块或 “PSP” 黑块 | `drawSpineStrip` | neutral 下不画 |
| 14 | 封面纸封底 | 底部 “NINTENDO DS” / “NINTENDO 3DS” / “PSP” | `drawPlaceholder`、`drawGeneratedBack` 的 footer | neutral 下不画 |
| 15 | 封面纸扫描图 | GameTDB / libretro 零售封面 | `handheldInsertTexture` 使用 `game.caseArt` | **保留**（老板 10-03 要求联网封面必须有，`onlineCoversEnabled = true`）。封面是游戏发行商的零售包装图，上面自带的平台横条照原样显示 |
| 16 | 3DS XL 主机（插卡动画；DS 和 3DS 共用） | 底面 “Nintendo”、“NINTENDO 3DS XL”、“SPR-001”、电池 “SPR-003”、额定值 | `3DSXL-Cartridge-Open-Transition.usdz` `Underside_·_Manufacturer / Model_name / Model_number / Battery_type / Power_rating` | 隐藏（`NeutralBranding.applyConsole`） |
| 17 | 3DS XL 主机 | 外盖、内面、按键图例（A/B/X/Y、HOME/SELECT/START、3D/OFF、POWER、MIC、SD） | 同上 | 通用文字，不是商标，保留。外盖没有 “3DS XL” 标志，贴图只有法线和粗糙度 |
| 18 | DS / 3DS 游戏界面 | 主机外观图 | `Nintendo-3DS-XL-180deg.png`、`Controls/*.png` | 已逐区放大检查：只有 SELECT/HOME/START/POWER/MIC/3D/OFF 和 ABXY，没有标志，不需处理 |
| 19 | PSP 主机（插盘动画、游戏界面、关机交接） | 正面 “SONY”、PlayStation 标志、“PSP” 标志；背面 “SONY”、UMD 仓盖 “PSP” 标志、“UMD”；另有 VOL / POWER / HOLD / WLAN 图标 | `PSP2000-UMD-Open-Transition.usdz` `Housing_Rear_USD`、`UMD_DOOR_PIVOT_Geometry/Cube_118_USD` 的材质 `Logo___pale_silver_print`、`Print___original_vector_marks` | 这些印刷是平贴图层，换成同一几何体的 `Shell___Ice_Silver_metallic_paint` 后看不出来。VOL/POWER/HOLD 这些通用字共用这一材质，会一并消失。L/R 肩键上的同名材质不动（该几何体没有外壳材质） |
| 20 | PSP 面键 | △ ○ × □ 符号 | `BUTTON_*` 下的 `Controls___charcoal_original_glyphs` | **保留**：玩游戏要靠它认键（PPSSPP 自带 UI 也画这些符号），属功能性标示 |
| 21 | PSP 顶边 | “WLAN” 开关字样 | `Print___`/几何 | 通用字，保留 |
| 22 | PS2 主机 | 顶部 “PlayStation 2” 标志和字标、“SONY”、背面贴纸（SONY/SCE/型号/条码）、保修封条、MagicGate、i.LINK 图标、光盘媒体标志 | `PS2-Console.usdz` `TRADEMARK_PRINTS/PRINT_PS2_LOGO_TOP、PRINT_WORDMARK_TOP、PRINT_SONY、PRINT_ST_*、PRINT_REAR_STICKER、PRINT_WARRANTY_*、PRINT_MAGICGATE、PRINT_ILINK_ICON、PRINT_MEDIA_*` | 隐藏（`NeutralBranding.hidePS2Prints`，`PS2GameView` 和 `PS2StageAssets` 加载时）。“MEMORY CARD”、端口号、电源/USB/AC 图标、S400 保留 |
| 23 | DualShock 2 | “DUALSHOCK 2”、“PlayStation”、“SONY”、PS 标志 | `PS2-DualShock2.usdz` `PRINT_DUALSHOCK2、PRINT_PLAYSTATION、PRINT_SONY、PRINT_PS_LOGO` | 隐藏。START/SELECT/ANALOG、方向箭头、△○×□ 键帽保留 |
| 24 | PS2 记忆卡 | “PlayStation 2”、PS 标志、模压 “SONY”、MagicGate、“MEMORY CARD”、“8MB” | `PS2-MemoryCard.usdz` `TRADEMARK_PRINTS` | 整组隐藏 |
| 25 | PS2 盒 | 盒盖 “PlayStation 2” 横条和 PS 标志、书脊 PS 标志和字标、托盘模压 PS 标志 | `PS2-Case.usdz` `TRADEMARK_PRINTS_LID`、`TRADEMARK_PRINTS_SPINE`、`TRAY_PS_LOGO_EMBOSS` | 一律隐藏（原来没封面时显示横条，现在不显示） |
| 26 | PS2 光盘 | 标签面 PS 标志框、“PlayStation 2” 字标 | `PS2-DVD.usdz` `LABEL_PS_LOGO_BOX`、`LABEL_WORDMARK` | 一律隐藏（原来没封面时显示） |

### 实现

- 卡带、UMD、盒子、封面纸是每个游戏单独构建的：构建时隐藏节点（`NeutralBranding.hideTrademarkNodes`），封面纸传 `neutral: true`。
- 两台主机的场景所有游戏共用：`NeutralBranding.applyConsole(to:)` 对每个场景只执行一次（KVC 标记），PSP 关机交接把节点搬回 Cover Flow 后调用 `NeutralBranding.invalidate` 重新处理。

## 没有处理 / 残留风险

- 主机外形本身（3DS XL、PSP-2000 的造型）、DS / 3DS 卡带和 UMD 的外形、零售盒的造型都没改，只去掉了文字和标志。外观设计 / 商业外观算不算问题，由产品方判断。
- 无障碍标签 “Nintendo DS screen”（`ModelScreenOverlay` / `XLScreenPanel`）和 “PSP-2000 银色实体操作界面” 屏幕上看不到，没改。
- 教程（`CartridgeTutorialView`）的兼容列表写着 “Nintendo DS / Nintendo 3DS / Sony PSP”，设置里写着 “PSP”。这些与所选游戏无关，不在本次范围内。
- 游戏自己的图标和画面照原样显示。
