# 开源许可证页数据（设置-关于）

- `OpenSourceLicenses.json`：每个组件的名称、用途、版权、许可证、上游地址、锁定版本、是否有修改。UI 直接读这个文件渲染列表，点进去显示 `licenseFile` 全文。
- `$(DuoSourceCodeURL)`：读 Info.plist 的 `DuoSourceCodeURL`（开源仓库地址，老板定了再填）。为空时显示"源码索取：privacy@spare.cool"之类的文字，不要显示占位符。
- `revision: "TODO"`（PPSSPP、DeSmuME）：老板 Mac 跑完 tools/export_vendor.sh 后，从 vendor-export 分支的 vendor/MANIFEST.tsv 补上。
- 加到 Xcode 时用 folder reference（蓝色文件夹）整个 Licenses 目录拷进 bundle。
- 增删内核必须同步改这个 JSON 和根目录 THIRD_PARTY_NOTICES.md。Delta 系的三个框架已在 store-fix 删除，不在列表里。DeSmuME 是 DS 的 HD 渲染内核，保留。
- 声音素材是 Freesound CC0（见 Resources/Audio/CREDITS.md），3D 模型和卡带/主机贴图为自建，不需要列。
