# App Review 测试游戏：商标审计与“review-safe”呈现

交给 App Review 的三款开源测试游戏在屏幕上出现时，不显示任何 Sony / Nintendo 商标或标志；其他游戏保持原样。

| 游戏 | 文件 | 大小 | SHA-256 |
|---|---|---|---|
| Trail Mix 3.1.1（NDS，MIT） | `TestFixtures/TrailMix.nds`（Debug 内置） | 4,640,768 | `f1977761…009d3f` |
| Trail Mix 3.0.0（旧版，启动时被原地升级） | — | 4,715,520 | `f83cdf6e…4f5e1f` |
| Mars3DS（3DS homebrew，MIT） | `TestFixtures/3DS/Mars3D.3dsx`（Debug 内置） | 713,384 | `00fb87d9…0a335b` |
| 2048 for PSP 1.0.0（MIT） | `TestFixtures/PSP/2048/EBOOT.PBP`；导入 zip 后库里指向的也是这份 EBOOT.pbp | 168,079 | `d981baac…43ea2a2` |

## 识别

`DuoDS/App/ReviewSafeGames.swift` 的 `ReviewSafeGames.entries`：每个可能成为 `GameLibraryItem.url` 的 ROM 文件一行（名称、字节数、SHA-256）。按文件内容识别，不看标题或文件名。

- 只有字节数与表中某行相同的文件才会被计算哈希；其他文件只做一次 `stat`。
- 哈希在 `GameLibraryStore.reload()` → `refreshReviewSafety()` → `ReviewSafeGames.warmUp` 中于后台线程流式计算（每次 1 MiB），结果按“路径 + 大小 + 修改时间”缓存在内存和 `UserDefaults`（`reviewSafeGames.hashes.v1`）里。
- 字节数吻合但哈希还没算完时按 review-safe 处理，所以测试游戏不会先闪出商标；算完发现不是测试游戏时，该卡片的 `appearanceRevision` 会变化，Cover Flow 重建它，恢复原样。
- 以后加一款测试游戏只需在 `entries` 里加一行。

## 清单

| # | 位置 | 元素 | 文件 / 节点 / 材质 | 处理方式 |
|---|---|---|---|---|
| 1 | 游戏库 Cover Flow 下方平台行 | “NINTENDO DS” / “NINTENDO 3DS” / “SONY PSP” | `GameLibrary.swift` `GameLibraryView`（`game.platform.rawValue`） | 改为“开源测试游戏”（已有 xcstrings 条目：en “Open-Source Test Game”，zh-Hant “開源測試遊戲”），大写显示 |
| 2 | DS / 3DS 卡带正面 | 标签上方模压 “NINTENDO DS” / “NINTENDO 3DS” | `Detailed-Cartridges.usdz` 各卡型 `Front_platform*` | 隐藏节点 |
| 3 | DS / 3DS 卡带背面 | 模压 “Nintendo” | `Back_maker_mark*` | 隐藏节点 |
| 4 | DS / 3DS 卡带背面 | 型号 “NTR-005” / “CTR-005” | `Molded_model_number*` | 隐藏节点 |
| 5 | 卡带模型缺失时的代码备用卡带 | `SCNText` “NINTENDO DS…” 品牌字和 NTR/CTR 型号 | `CartridgeSceneFactory.addEmbossedMark` / `addBackContacts` | 不生成 |
| 6 | UMD 外壳 | “PSP” 标志 | `PSP-UMD.usdz` `PSP_shell_vector___path6945/6947/6949*` | 隐藏节点 |
| 7 | UMD 外壳 | PlayStation 风格手柄标记 | `Gamepad___photo_traced_shell_mark*` | 隐藏节点 |
| 8 | UMD 中心白色徽章 | “UMD” 字样（运行时由 `filledUMDBadgeLetter` 填充） | `UMD_shell_vector___svg_*`（白色底座 `Fixed_UMD_white_centre_badge` 保留，无字） | 隐藏节点 |
| 9 | DS 盒 | 托盘模压 “NINTENDO DS”、盒盖内侧 “Nintendo” 椭圆框 | `NDS-Case.usdz` `TRADEMARK_PRINTS/TRAY_NDS_EMBOSS`、`TRADEMARK_PRINTS_LID/LID_NINTENDO_EMBOSS` | 隐藏 `TRADEMARK_PRINTS*` |
| 10 | 3DS 盒 | 托盘模压 “Nintendo 3DS” | `3DS-Case.usdz` `TRADEMARK_PRINTS/TRAY_NINTENDO_3DS_EMBOSS` | 同上 |
| 11 | UMD 盒 | 卡座模压 “UMD” | `PSP-UMD-Case.usdz` `TRADEMARK_PRINTS/TRAY_UMD_EMBOSS` | 同上 |
| 12 | 盒内封面纸（占位图） | 正面白色竖条 “NINTENDO DS” / “NINTENDO 3DS”，黑色横条 “PSP” | `HandheldCaseCoverArt.swift` `drawFrontBanner` | `HandheldCaseInsert.render(neutral: true)`：不画横条，标题区占满正面 |
| 13 | 封面纸书脊 | 顶部 “NINTENDO DS/3DS” 白块或 “PSP” 黑块 | `drawSpineStrip` | neutral 下不画 |
| 14 | 封面纸封底 | 底部 “NINTENDO DS” / “NINTENDO 3DS” / “PSP” | `drawPlaceholder`、`drawGeneratedBack` 的 footer | neutral 下不画 |
| 15 | 封面纸扫描图 | GameTDB / libretro 零售封面（homebrew 的产品码可能撞上零售游戏，比如 2048 的 `UCJS10041` 就是 LocoRoco 的） | `handheldInsertTexture` 使用 `game.caseArt` | review-safe 游戏忽略 `caseArt`，一律用 neutral 占位图 |
| 16 | 3DS XL 主机（插卡动画；DS 和 3DS 共用） | 底面 “Nintendo”、“NINTENDO 3DS XL”、“SPR-001”、电池 “SPR-003”、额定值 | `3DSXL-Cartridge-Open-Transition.usdz` `Underside_·_Manufacturer / Model_name / Model_number / Battery_type / Power_rating` | 按选中游戏可逆隐藏（`ReviewSafeScene.applyConsole`） |
| 17 | 3DS XL 主机 | 外盖、内面、按键图例（A/B/X/Y、HOME/SELECT/START、3D/OFF、POWER、MIC、SD） | 同上 | 通用文字，不是商标，保留。外盖没有 “3DS XL” 标志，贴图只有法线和粗糙度 |
| 18 | DS / 3DS 游戏界面 | 主机外观图 | `Nintendo-3DS-XL-180deg.png`、`Controls/*.png` | 已逐区放大检查：只有 SELECT/HOME/START/POWER/MIC/3D/OFF 和 ABXY，没有标志，不需处理 |
| 19 | PSP 主机（插盘动画、游戏界面、关机交接） | 正面 “SONY”、PlayStation 标志、“PSP” 标志；背面 “SONY”、UMD 仓盖 “PSP” 标志、“UMD”；另有 VOL / POWER / HOLD / WLAN 图标 | `PSP2000-UMD-Open-Transition.usdz` `Housing_Rear_USD`、`UMD_DOOR_PIVOT_Geometry/Cube_118_USD` 的材质 `Logo___pale_silver_print`、`Print___original_vector_marks` | 这些印刷是平贴图层，换成同一几何体的 `Shell___Ice_Silver_metallic_paint` 后看不出来。VOL/POWER/HOLD 这些通用字共用这一材质，会一并消失。L/R 肩键上的同名材质不动（该几何体没有外壳材质） |
| 20 | PSP 面键 | △ ○ × □ 符号（Sony 注册商标） | `BUTTON_CROSS/CIRCLE/SQUARE/TRIANGLE` 下的 `Controls___charcoal_original_glyphs` | 换成不可见材质，只剩透明键帽。方向键箭头和 HOME/SELECT/START 保留 |
| 21 | PSP 顶边 | “WLAN” 开关字样 | `Print___`/几何 | 通用字，保留 |

### 实现与复原

- 卡带、UMD、盒子、封面纸是每个游戏单独构建的：构建时隐藏节点（`ReviewSafeScene.hideTrademarkNodes`），传入 `neutral`。
- 两台主机的场景所有游戏共用。`ReviewSafeScene.applyConsole(_:to:)` 在 Cover Flow 每次 `layout()` 时按选中游戏开关：状态没变就直接返回；把原几何体和原 `isHidden` 用 KVC 存在节点上，关掉时逐一还原。PSP 游戏界面的模型在 `PSP2000SceneView.makeUIView` 里设置；关机交接把这些节点搬回 Cover Flow 后调用 `ReviewSafeScene.invalidate`，下一帧再按选中游戏调整一次。macOS 离线测试：开启 → 关闭后与原图逐像素比较，差异 0 像素。

## 没有处理 / 残留风险

- 主机外形本身（3DS XL、PSP-2000 的造型）、DS / 3DS 卡带和 UMD 的外形、零售盒的造型都没改，只去掉了文字和标志。外观设计 / 商业外观算不算问题，由产品方判断。
- 无障碍标签 “Nintendo DS screen”（`ModelScreenOverlay` / `XLScreenPanel`）和 “PSP-2000 银色实体操作界面” 屏幕上看不到，没改。
- 教程（`CartridgeTutorialView`）的兼容列表写着 “Nintendo DS / Nintendo 3DS / Sony PSP”，设置里写着 “PSP”。这些与所选游戏无关，不在本次范围内。
- 游戏自己的图标和画面（Trail Mix 标题、Mars3DS 的像素卡带图标、2048）照原样显示。
