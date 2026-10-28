# 网格容器模块

往 **M×N** 的格子里摆 **m×n** 的矩形块。支持一次方向调整（0 ↔ 90）、自动放入
（放不下时可**重排**已有块）、格间搬运（搬走 / 合并 / 换位）、跨容器搬运，
以及**不需要物品表**的存读档。

Godot 4.7 · 纯 GDScript · 8 个文件 · 无插件、无 autoload、无单例。

```bash
godot --path .                                                    # 跑 demo
godot --headless --path . --script res://tests/run_tests.gd       # 14 组 / 17412 断言
```

> 第一次来？看[文档入口](docs/README.md)。要动手？直接跳
> [01 · 快速接入](docs/01-quickstart.md)。

---

## 边界：这个模块认识什么，不认识什么

这是最重要的一节。**模块只认识几何和位置**：

| | 容器模块（`scripts/`） | 你的游戏（示例见 `demo/`） |
|---|---|---|
| 装的是几行几列 | ✅ `CellGrid.new(Vector2i(9, 4))` | |
| 每块占 m×n 格、能不能转 90° | ✅ | |
| 每块在哪儿、转没转 | ✅ 位置索引 `at_cell()` / `cells_of()` | |
| 名字、图标、颜色、描述 | ❌ 不认识 | ✅ `DemoItemCatalog` |
| 数量、堆叠上限、"25 个切几块" | ❌ 不认识 | ✅ `DemoItemRules.blocks_of()` |
| 两块什么时候能合并 | ❌ 只提供注入点 `merge_rule` | ✅ `DemoItemRules.merge_payload()` |
| 这块东西进哪个容器（拾取路由） | ❌ 不认识 | ✅ `demo.gd` 里一行 `if` |
| 界面、输入、动画、皮肤 | ❌ 一行都没有 | ✅ `DemoGridBoard` |

块的身份挂在 `Placement.payload` 上，容器把它当**不透明**的东西：搬进搬出、写进快照、
还给你，但**从不解读、从不比较**。于是同一份代码既能服务「背包里的枪」，
也能服务「网格上的建筑」。

**判断分层有没有做对，只有一个检验**：改上表右列的任何一条，`scripts/` 里不需要改一个字。
判据第 10 组拿它当断言（甚至检查 `cell_grid.gd` 的源码里不出现 `ItemDef` / `max_stack` / `def_id`）。

---

## 一分钟接入

```gdscript
# ① 建一个 9×4 的背包。没有物品表，没有数量概念。
var bag := CellGrid.new(Vector2i(9, 4))
bag.changed.connect(_on_bag_changed)          # 唯一的接线：内容变了就重绘

# ② 放一块 2×1、可旋转的东西。payload 随便你放什么，容器不读它。
var res := bag.place_auto({"id": "plank", "count": 3}, Vector2i(2, 1), true)
if not res["ok"]:
    print(res["reason"])                      # 理由说人话，可以直接给玩家看

# ③ 搬：先只读地问，再提交（两段共用同一段判定）
var order := {"from": 0, "cell": Vector2i(0, 0), "rot": 90}
if GridOps.problem(bag, chest, order) == "":
    GridOps.move(bag, chest, order)

# ④ 放不下时重排兜底（显式选这一档 —— 代价是位置跳动）
var fit := GridOps.insert_fitting(bag, blocks)
print(fit["placed"], fit["left"], fit["repacked"])

# ⑤ 存读档：不需要物品表
var text := JSON.stringify(bag.snapshot())
bag.restore(JSON.parse_string(text))          # 返回 "" = 成功（全或无）
```

**返回值只有两种形状**：判定（只读）→ `String`，空串 = 可以；动作（写入）→ `Dictionary`，
成功与失败的**键集合完全相同**。细节见 [03 · API](docs/03-api.md#返回值契约)。

---

## 文档

| 文件 | 内容 |
|---|---|
| [docs/README.md](docs/README.md) | 文档入口 + 目录 + 环境 |
| [01 · 快速接入](docs/01-quickstart.md) | 拷进来 → 建网格 → 放第一块 → 搬 → 存读档 → 检查清单 |
| [02 · 概念](docs/02-concepts.md) | 网格 / 块 / `payload` / 键与下标 / 方向 / 为什么没有"数量" |
| [03 · API](docs/03-api.md) | 按类逐个过：签名、返回键、失败理由 |
| [04 · 常见做法](docs/04-recipes.md) | 拾取、拖拽、整理、多容器、准入、合并、存读档、扩容 |
| [05 · 接界面](docs/05-view.md) | `GridLayout` + 三条纪律 + 拖影 + 重排动画 |
| [06 · 坑](docs/06-pitfalls.md) | 点偏一格 / 自己判定 / JSON 整数 / 键漂移 / 准入后门… |
| [07 · 设计笔记](docs/07-design.md) | 为什么两档、为什么不做物品、重排算法、实测、判据怎么读 |

只有三节是"必须先读"的：[边界](#边界这个模块认识什么不认识什么)、
[返回值契约](docs/03-api.md#返回值契约)、[三条界面纪律](docs/05-view.md#三条纪律)。

---

## 目录

```
container-system/
├── README.md      ← 你正在看的（入口 + 边界）
├── docs/          ← 用户文档
├── scripts/       ← 模块本体：8 个 .gd = 8 个概念，整目录拷走即用
├── demo/          ← 游戏侧参考实现（不属于模块）
├── tests/         ← run_tests.gd（模型判据）+ demo_smoke.gd（接线冒烟）
└── refs/          ← 旧项目快照，只读参考，不参与构建
```

`scripts/` 里没有任何绘制代码、没有任何物品定义：

| 文件 | 概念 |
|---|---|
| `grid_shape.gd` | 纯几何：旋转、相交、展开成格 |
| `placement.gd` | 一条占位：锚点 + 形状 + 方向 + 不透明 payload |
| `cell_grid.gd` | `CellGrid`：M×N 网格，唯一真相 = `placements[]`，带位置索引 |
| `place_finder.gd` / `first_fit_finder.gd` | 找位策略（在线、不动已有块） |
| `repacker.gd` | `GridRepacker`：允许挪动已有块的重排（离线装箱） |
| `grid_ops.gd` | `GridOps`：搬 / 转 / 批量放入的唯一入口 |
| `grid_layout.gd` | `GridLayout`：格 ↔ 像素的纯换算 |

依赖单向：`grid_shape` 不认识任何东西，`grid_ops` 只认识 `CellGrid`。
`CellGrid` 这名字是为了避开 Godot 内建的 `GridContainer`（Control）——
撞名后解析器会解析到内建类，报错长得像"你的函数不存在"。

---

## 命令

```bash
# 模型判据（headless，不建场景，几秒）
godot --headless --path . --script res://tests/run_tests.gd

# demo 接线冒烟（跨板拖拽、落点、存读档、准入）
godot --headless --path . --script res://tests/demo_smoke.gd

# 跑 demo（主场景已设为 demo/demo.tscn，F5 也行）
godot --path .

# 新增/删除脚本后刷新全局类缓存
godot --headless --path . --import
```

demo 操作：左键拖动、拖到另一块板上、`R` 换方向、右键原地转。
七个按钮：随机拾取、双向搬运、整理（重排）、存档 / 读档、清空。

---

## 两个档位（本模块唯一"两种算法"的地方）

二维矩形装箱是 NP-hard，工程上分 online / offline 两种玩法，两者都留着，
因为**代价完全不同**：

| | 便宜的那档（默认） | 贵的那档（兜底） |
|---|---|---|
| 放入 | `place_auto()` | `GridOps.insert_fitting()` |
| 搬运 | `GridOps.move()` | `GridOps.move_fitting()` |
| 动不动已有块 | 不动 | 目标里全部拿出来重排 |
| 代价 | 便宜、可预测、顺序稳定 | 位置跳动；最坏 8 轮搜索 |
| 用在哪 | 默认；**拖拽落点只用这档** | 拾取兜底、整理按钮、整板搬运 |

拆成两个函数而不是"自动挑"，是因为**位置跳动必须由调用方显式选择** ——
玩家盯着拖影松手时，东西不该自己重新排一遍。原因和实测数据见
[07 · 设计笔记](docs/07-design.md#两档策略为什么不让-move-自己重排)。
