# PS2 模型构建通用说明（给建模 agent）

## 环境
- 仓库：`/Users/owwwwwen/Developer/GameDuo`，分支 `ps2-models`。**不要运行 git**，由协调者提交。
- 其他 agent 同时在建别的模型，只改你任务里列出的文件。
- M2 只有 8 GB 内存：Blender 一律后台运行 `-b`，渲染用低采样，不要同时开多个 Blender。
- Blender：`B="/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python-exit-code 1"`，运行 `$B --python <script.py>`（从仓库根目录）。

## 共享工具 `tools/ps2_blender/common.py`
脚本开头：
```python
import sys; from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools/ps2_blender"))
import common as C
```
先读 `common.py` 的文档字符串。主要 API：`load_contract(name)`、`reset_scene()`、`hex_rgba()`、`mat()`、`assign()`、`rounded_box()`、`cylinder()`、`bevel()`、`boolean()`、`empty()`、`set_parent()`、`apply_all()`、`descendants()`、`triangle_count()`、`export_usdz(root, path)`、`save_blend(path)`。

## 坐标约定（必须遵守）
- **在 Blender 里直接按 Y 向上建模**：Blender X = 右，Blender Y = 上，Blender Z = 物件正面。不要按 Blender 默认的 Z 向上。
- 米制，不缩放。根节点在世界原点、无旋转，根节点位置 = 契约规定的原点。
- 可动节点：用 `empty()` 或物体本身作为枢轴，**静止姿态旋转必须为 0**（需要倾斜时放在父级空节点上）；契约里的运动轴是该节点父空间下的本地轴。
- 导出命名：有子物体的网格物体导出后是 `NAME` 节点 + `NAME_mesh` 几何子节点；节点名不能重复（包括 `.001` 后缀）。
- 商标印刷全部放在 `TRADEMARK_PRINTS` 空节点下。可替换贴图的面（`COVER_ART`、`DISC_LABEL`）要有 0–1 UV。
- 材质只用 USD Preview Surface 能表达的参数（基色、粗糙度、金属度、透明度、自发光）。灯（LED）的材质默认关闭色，名字含 `_off`。

## 验收（你自己跑，全部通过才算完成）
1. `$B --python tools/ps2_blender/validate_ps2.py -- --only <资产名>`：输出 `OK <资产名>`（尺寸误差 ≤ 0.5 mm、面数不超、节点齐全、每个运动两端无穿模/无包含）。贴合面误报时才用 contract part 里的 `allow_touch`，并在报告里说明。
2. `xcrun swift tools/ps2_blender/verify_scenekit.swift --only <资产名>`：输出 `OK`。
3. 渲染 2–3 张检查图（Cycles 32 采样或 EEVEE，1280×960 以内）到对应目录 `renders/`，**自己用 Read 工具看图**，对照 `references/` 里的照片检查比例、颜色、部件位置，有明显不像的地方要改。
4. 保存 `.blend`。

## 需要改契约时
尺寸、`allow_touch` 等只写在 `tools/ps2_blender/contract_parts/<资产名>.json`（part 覆盖 `contract.json`）。不要改 `contract.json` 和 `common.py`；觉得它们需要改时在报告里说。

## 报告
状态（DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT）、做了什么、验证输出原文、面数、渲染图路径、与参考不符或是估算的地方、问题。
