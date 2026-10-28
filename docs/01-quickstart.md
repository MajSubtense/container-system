# 01 · 快速接入

目标：从零到一个能放、能搬、能存的背包。**不涉及界面**（界面在 [05](05-view.md)）。

---

## 0. 拷进来

把 `scripts/` 整个目录复制到你的项目里（放在哪都行，叫什么都行）：

```
your-game/
└── addons/或任意位置/grid_container/     ← scripts/ 里的 8 个 .gd
```

不需要注册插件、不需要 autoload。每个文件第一行是 `class_name`，
Godot 会把它注册成全局类，任何脚本里直接写 `CellGrid` / `GridOps` 就能用。

> 如果编辑器标红说"找不到 CellGrid"，重启一次编辑器，或者跑
> `godot --headless --path . --import` 刷新全局类缓存。
> 这是 Godot 的类缓存问题，不是模块的问题。

---

## 1. 建一个网格

```gdscript
extends Node

var bag: CellGrid

func _ready() -> void:
	bag = CellGrid.new(Vector2i(9, 4))   # 9 列 4 行
	print(bag.capacity())                # 36 —— 容量是"格数"，不是"件数"
```

**构造只需要尺寸。** 没有物品表、没有"背包类型"、没有容量上限配置 ——
那些都是游戏侧的事。

---

## 2. 放第一块

```gdscript
# 一块 2×1 的东西。payload 随便放什么，容器不读它。
var res := bag.place_auto({"id": "plank", "count": 3}, Vector2i(2, 1), true)

if res["ok"]:
	print("放进了第 %d 块，位置 %s" % [res["key"], bag.placements()[res["key"]].anchor])
else:
	print("放不下：", res["reason"])     # 理由是说人话的，可以直接给玩家看
```

三个参数是：**身份**、**基准形状**（未旋转的宽 × 高）、**能不能转 90°**。

`place_auto` 会按"最上一行、再最左"找一个放得下的空位；正放放不下、且这块可旋转时，
再试一次转过来的形状。放进去之后 `res["key"]` 就是它的位置索引。

> `payload` 是**不透明**的：容器会把它搬进搬出、写进快照、原样还给你，
> 但从不解读、从不比较。所以放 `{"id": ..., "count": ...}` 可以，
> 放一个自定义 `RefCounted`、一个整数、甚至 `null` 也都可以。

---

## 3. 订阅 `changed`

**这是唯一需要你接线的东西。** 网格内容一变就发一次（一个动作只发一次）：

```gdscript
func _ready() -> void:
	bag = CellGrid.new(Vector2i(9, 4))
	bag.changed.connect(_on_bag_changed)

func _on_bag_changed() -> void:
	queue_redraw()      # 或者刷新 HUD 数字、播放动画
```

不要在 `changed` 的处理函数里再改网格 —— 那会递归。要"放进去后自动整理"，
请在**调用的那一侧**排顺序：

```gdscript
GridOps.insert_fitting(bag, blocks)
# 需要整理再显式调
```

---

## 4. 搬一块

跨容器搬运只有一个入口：

```gdscript
var chest := CellGrid.new(Vector2i(6, 4))

# ① 先只读地问（界面染色、按钮可用性都问这个）
var why := GridOps.problem(bag, chest, {"from": 0, "cell": Vector2i(2, 1), "rot": 90})
if why == "":
	# ② 再提交
	var res := GridOps.move(bag, chest, {"from": 0, "cell": Vector2i(2, 1), "rot": 90})
	print(res["ok"], res["reason"])
```

`problem()` 和 `move()` 走的是**同一段判定**，所以"界面说能放、按下去却失败"
在结构上不可能发生。

`order` 可以写得很省：

| 写法 | 意思 |
|---|---|
| `3` | 把第 3 块搬到对面，位置自己挑 |
| `{"from": 3}` | 同上 |
| `{"from": 3, "cell": Vector2i(2, 0), "rot": 90}` | 点名落在这一格、这个方向 |
| `{"from": 3, "to": 1}` | 并进对面第 1 块（合并） |

**跨容器不会换位**：对面那一格是别的东西、又合不了，就直接拒绝。理由：
把对面的东西换进你的背包，玩家不会预期这个。

---

## 5. 放不下的时候

默认的 `place_auto` / `move` **不动已有的块**。这会把网格切碎，最后落到
"总面积够，但每块空隙都塞不进这一块"。

两档兜底，**显式选择**才生效：

```gdscript
# 放入：先直接放，放不下才把已有块重排
var res := GridOps.insert_fitting(bag, blocks)
print(res["placed"], res["left"], res["repacked"], res["moves"])

# 搬运：先直接搬，搬不动才让目标重排
var fit := GridOps.move_fitting(bag, chest, {"from": 0})
print(fit["ok"], fit["repacked"], fit["moves"])
```

重排的代价是**玩家会看到位置跳动**，所以模块不会替你决定要不要重排 ——
尤其是拖拽松手那一刻，别用 `_fitting` 那一档（见 [06 · 坑](06-pitfalls.md#3-拖拽落点用了重排版)）。

---

## 6. 存读档

```gdscript
# 存
var data := bag.snapshot()
var text := JSON.stringify(data)

# 读（返回 "" = 成功；非空 = 拒绝理由。全或无）
var err := bag.restore(JSON.parse_string(text))
```

`payload` 原样进快照，**读档不需要物品表**。想连类型一起保真就别走 JSON：

```gdscript
var text := var_to_str(bag.snapshot())
var err := bag.restore(str_to_var(text))
```

走 JSON 的两笔代价（整数变浮点、`StringName` 变 `String`）必须由游戏侧归一化，
细节见 [03 · API 的存读档一节](03-api.md#存读档)。

---

## 7. 接进已有项目时，你要写的东西

按 `demo/` 的规模估：

| 你要写的 | demo 里的对应 | 大概行数 |
|---|---|---|
| 物品目录：id → 形状 / 能否转 / 名字 / 颜色 / 堆叠上限 | `demo/item_catalog.gd` | ~140 |
| 规则：一堆切几块、什么时候合并、谁不许进、去哪 | `demo/item_rules.gd` + `demo/demo.gd` | ~110 |
| 视图：画格子、画块、把拖动翻译成 `GridOps` 调用 | `demo/grid_board.gd` | ~300 |

`scripts/` 一行都不用改。**这也是判断分层有没有做对的唯一标准**：
改上面任何一条，模块里不需要动一个字。

---

## 8. 接完的检查清单

- [ ] `scripts/` 里没有出现任何物品名、颜色、数量、上限
- [ ] 视图里没有 `if 这样就能放` 的判断 —— 全部问 `problem()` / `can_place_at()`
- [ ] 格 → 像素、像素 → 格都用 `GridLayout`，没有第二份坐标数学
- [ ] 清空用 `clear()`，不是 `while not is_empty(): remove_at(0)`
- [ ] 存读档试过"存 → 清空 → 读"（不是只存不读）
- [ ] 拖拽落点用的是 `move()`，不是 `move_fitting()`

前五条都对应一个具体的坑，见 [06](06-pitfalls.md)。

---

## 下一步

- 想弄明白"为什么没有 `add(25 个木头)`" → [02 · 概念](02-concepts.md)
- 要开始画界面 → [05 · 接界面](05-view.md)
- 要写拾取 / 拖拽 / 整理 / 多容器路由 → [04 · 常见做法](04-recipes.md)
