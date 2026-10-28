# 03 · API 参考

七个全局类：`CellGrid` `Placement` `GridShape` `PlaceFinder` `FirstFitFinder`
`GridOps` `GridRepacker` `GridLayout`（八个文件、八个概念）。

**先读这一节，其余当手册查。**

---

## 返回值契约

只有两种形状。这不是风格问题 —— 它决定了你要不要在每条分支上写一套不同的读法。

### 判定（只读）→ `String`

**空串 = 可以**，非空 = 理由（说人话，可以直接给玩家看）。

```gdscript
CellGrid.fits_at()            CellGrid.can_place_at()
CellGrid.move_to_cell_problem()   CellGrid.move_within_problem()
CellGrid.rotate_problem()     CellGrid.restore()      # restore 空串 = 成功
GridOps.problem()
```

### 动作（写入）→ `Dictionary`

**成功与失败的键集合完全相同**，失败时附加字段取空值：

| 调用 | 键 | 失败时的空值 |
|---|---|---|
| `place_auto()` / `place_at()` | `ok, reason, placement, key` | `placement = null`，`key = -1` |
| `move_to_cell()` / `move_within()` / `merge_into()` | `ok, reason, moved` | `moved = 0` |
| `rotate()` / `GridOps.rotate()` | `ok, reason, rot` | `rot = -1` |
| `GridOps.move()` | `ok, reason, moved` | `moved = 0` |
| `GridOps.move_fitting()` | `ok, reason, moved, repacked, moves` | `moved = 0`，`repacked = false`，`moves = 0` |
| `GridOps.insert_fitting()` | `ok, reason, placed, left, repacked, moves` | `placed = 0`，`left = []` |
| `GridRepacker.plan()` | `ok, reason, layout, moves, attempt, tried` | `layout = []`，`moves = 0`，`attempt = ""` |

于是永远只有两种组合：

```gdscript
if res["ok"]:      # ⇒ reason 一定是 ""
	…
else:              # ⇒ reason 一定非空
	print(res["reason"])
```

这两个例外返回的不是 Result，因为它们回答的不是"成没成"：

| 调用 | 返回 | 语义 |
|---|---|---|
| `GridOps.insert_all()` | `Array` | **没收下的那些**（放下的已经进网格了） |
| `remove_at(key)` | `Placement` / `null` | "取出来"，取出成功就一定有东西 |

判据第 14 组会**逐个比对成功/失败字典的键集合**，并断言 `ok` 与 `reason` 自洽。
所以"某个罕见失败路径少了一个 `moved` 键"这类崩溃不会漏到调用方。

---

## CellGrid

M×N 的网格。唯一真相是内部的 `placements[]`。

### 构造

```gdscript
var grid := CellGrid.new(Vector2i(9, 4))                  # 9 列 4 行
var grid := CellGrid.new(Vector2i(9, 4), MyFinder.new())  # 换找位策略
```

`DEFAULT_SIZE = Vector2i(9, 4)`。尺寸为 0 或负数会被夹到 0（容量 0，什么都放不进）。

### 注入点

```gdscript
var finder: PlaceFinder      # 默认 FirstFitFinder.new()
var accepts: Callable        # func(payload) -> bool，空 = 什么都收
var merge_rule: Callable     # func(新来的, 已在场上的) -> Variant，返回 null = 不能合
```

三个都是**公开字段**，构造后随时可换：

```gdscript
bag.merge_rule = DemoItemRules.merge_hook(catalog)
bag.accepts = func(payload) -> bool: return DemoItemRules.id_of(payload) != &"rifle"
```

`merge_rule` 必须是**纯函数** —— `can_merge_at()`（判定）和 `merge_into()`（提交）
会各问一次。

### 读

| 方法 | 返回 | 说明 |
|---|---|---|
| `grid_size()` | `Vector2i(W, H)` | 列 × 行 |
| `capacity()` | `int` | **格数** = W×H，不是件数 |
| `used_cells()` | `int` | 所有块面积之和（重叠不可能存在） |
| `free_cells()` | `int` | `max(0, capacity - used_cells)` |
| `count()` | `int` | 块数 |
| `is_empty()` | `bool` | |
| `describe()` | `String` | 一行诊断（`"网格 9×4（3 块 / 12 格）：…"`），**不是界面文案** |

界面上的"已用 3 / 36 格"要自己拼 —— `"已用 %d / %d 格" % [grid.used_cells(), grid.capacity()]`。
模块不提供这句话，因为换个游戏 / 语言就得改。

### 位置索引

| 方法 | 返回 | 说明 |
|---|---|---|
| `placements()` | `Array[Placement]` | 一块一条。**数组是副本，元素是网格持有的对象 ⇒ 只读** |
| `at_cell(cell)` | `Placement` / `null` | 这一格被谁占着（命中测试） |
| `key_at_cell(cell)` | `int` | 这一格属于第几条，`-1` = 空 |
| `cells_of(key)` | `Array[Vector2i]` | 这一块展开成哪些格（行优先），键不存在返回空数组 |
| `index_of_key(key)` | `int` | 键合法就返回它自己，否则 `-1` |

`cells_of()` 和 `GridShape.cells_at()` 是同一段几何，别在视图里再写一遍。

### 判定

#### `fits_at(cells, anchor, ignore_index := -1) -> String`

**唯一判定入口。** 其他所有判定最终都问到它。

- `cells` 是**实际形状**（已旋转的宽 × 高），不是 `base_cells`。
- `ignore_index`：把第几条当作已经拿开（挪动自己、换位时必须给，否则会被自己挡住）。

```gdscript
grid.fits_at(Vector2i(1, 3), Vector2i(2, 0))          # "" = 放得下
```

失败理由形如 `"2×3 放在 (5, 3) 会越出 9×4 的网格"` / `"(1, 0) 那块（2×2）已经占了这儿"`。

#### `can_place_at(payload, anchor, cells, rotatable := false, rot := -1) -> String`

**带方向**的判定。`cells` 这里是 **base**（会自己按 `rot` 旋转）。

- `anchor.x < 0`：问"随便哪儿都行吗"（等价于自动放入能不能成功）。
- `rot = -1`：正放不行再试转过来；`0/90`：就这个方向。
- 会先问 `admits(payload)`。

#### `admits(payload) -> bool`

这个网格收不收这个 payload（注入的 `accepts`，没注入 = 都收）。
**"收不收"和"放不放得下"是两件事**，而且先后有别 —— 收的东西才轮到讨论位置。

#### `move_to_cell_problem(key, anchor, rot := -1) -> String`

把第 `key` 块搬到 `anchor` 行不行。`rot < 0` = **保持原方向**。

#### `move_within_problem(from_key, to_key := null) -> String`

同容器搬运行不行。内部拿副本跑一遍 `move_within()` 取理由 —— 所以它和提交**必然一致**。

#### `rotate_problem(key) -> String`

能不能转。固定方向的块、方的东西、转开会越界/重叠的块，各有各的理由：

```
"2×1 这块是固定方向的"
"3×3 是方的，转不转一个样"
"转过来就放不下了：1×4 放在 (8, 0) 会越出 9×4 的网格"
```

#### `room_for(cells, rotatable := false) -> int`

还能放几块这么大的。**干跑**：在一份副本上反复 `place_auto`，与真实放入同源
（不会出现"它说还能放 2 块，实际放不进"）。大网格 + 海量块时才有性能顾虑。

### 写入

#### `place_auto(payload, cells, rotatable := false) -> Dictionary`

自己挑位置。顺序是**语义**，不是实现细节：

1. 先在整个网格里找"正放"放得下的第一个锚点（行优先：y 外、x 内）
2. 全都放不下、且可旋转时，再**从头**扫一遍转 90° 的形状

⇒ 东西总落在"最靠上、再最靠左"的空位，同一串操作永远得到同一个布局。

返回 `{ok, reason, placement, key}`。失败理由分三种（重要）：

| 理由 | 意思 | 重排能救吗 |
|---|---|---|
| `网格只有 2×2：1×3 放不下，转过来 3×1 也不行` | **网格尺寸本身**装不下 | 不能 |
| `空位不够：2×3 要 6 格，只剩 4 格` | 面积不够 | 腾空了才行 |
| `还剩 3 格空位，但拼不出 1×3（空位被隔碎了）` | 面积够、形状凑不出 | **能** |

三种混成一句"放不下"，会让人以为"多空几格就行"，误判成算法 bug。

#### `place_at(payload, anchor, cells, rotatable := false, rot := -1) -> Dictionary`

点名落点。`cells` 是 base。

- `rot = -1`：自己适配（正放优先，不行再转）
- `rot = 0/90`：就这个方向，放不下就**拒绝**，不偷偷换方向

返回 `{ok, reason, placement, key}`。

#### `remove_at(key) -> Placement`

取走一块并返回它（取不到返回 `null`）。**「取出来」不是「成没成」** ——
真实游戏里拿到这个 `Placement` 之后该生成掉落物。

⚠️ 键是下标，删除会让后面的前移。

#### `move_to_cell(key, anchor, rot := -1) -> Dictionary`

把第 `key` 块整体搬到 `anchor`。`rot < 0` = **保持原方向**（不是自动挑）。

返回 `{ok, reason, moved}`，`moved` 是 0（原地没动）或 1。
原地没动时**不发 `changed`**。

#### `rotate(key) -> Dictionary`

转 90°（只有两态，一次调用就是"转过来"）。返回 `{ok, reason, rot}`。

#### `can_merge_at(key, payload) -> bool` / `merge_into(key, payload) -> Dictionary`

```gdscript
if grid.can_merge_at(3, incoming):
	grid.merge_into(3, incoming)
```

合并**不改形**：合并后的东西沿用目标那一块的锚点与形状。
`merge_into` 返回 `{ok, reason, moved}`（`moved = 1`）。

#### `move_within(from_key, to_key := null) -> Dictionary`

同容器的格间搬运，三种语义（规则只写在这一个地方）：

| 情形 | 行为 |
|---|---|
| `to_key == null`，或目标是空 | 搬到第一块放得下的空地（忽略自己） |
| `merge_rule` 说能合 | 两块塌成一块（沿用目标的位置与形状），源消失 |
| 目标有东西、合不了 | **整块换位**（换完会重叠就拒绝） |

返回 `{ok, reason, moved}`，`moved` = 0 / 1 / 2（换位动了两块）。

换位是**交换锚点、不重排数组**，所以键不漂。

#### `clear() -> void`

一次清空，**只发一次 `changed`**。已经空了就什么都不做。

### 存读档

#### `snapshot() -> Array[Dictionary]`

```gdscript
[
  {"payload": …, "anchor": [x, y], "base": [w, h], "rot": 0, "rotatable": false},
  …
]
```

- `anchor` / `base` 用数组，因为 **JSON 走不过 `Vector2i`**；这样 `JSON.stringify()` 直接可用。
- `payload` 原样带上 ⇒ 读档**不需要任何物品目录**。
- 形状用 `base` 而不是"查表" ⇒ 换物品表、热更新不会让旧档认不出形状。

#### `restore(data: Array) -> String`

空串 = 成功；非空 = 拒绝理由。三条性质：

1. **全或无**：先拿一个同样大小的空网格试摆，全部放得下才动真格
   （"改了一半"的背包比不还原更坏）。
2. **不问 `accepts`**：存档里的东西本来就该待在原来的格子里。规则改严之后读档把它们
   扔掉才是灾难（要不要清理是游戏自己的迁移逻辑）。
3. **只发一次 `changed`**。

`anchor` / `base` 接受 `Vector2i` / `Vector2` / `[x, y]` 三种写法；
`base` 缺失时会退回读 `cells` 键（兼容旧快照）。

⚠️ 走 JSON 的两笔代价，容器不会替你修（修它就得先认识 payload）：

| 现象 | 原因 | 游戏侧怎么处理 |
|---|---|---|
| `StringName` → `String`、`Color` → 字符串 | JSON 只有那几种类型 | `StringName(str(p["id"]))` |
| `{"count": 1}` 读回来是 `1.0` | **Godot 的 JSON 解析把整数读成浮点** | `int(p["count"])` |

想连类型一起保真：`var_to_str(grid.snapshot())` / `str_to_var(text)`。

---

## Placement

一条占位记录。**只有 `CellGrid` 能改它**；`placements()` 返回的数组是副本，
但元素仍是网格持有的对象 ⇒ 当作只读。

| 字段 | 类型 | 含义 |
|---|---|---|
| `payload` | `Variant` | 不透明身份，容器从不解读 |
| `anchor` | `Vector2i` | 左上角那一格（不是中心） |
| `cells` | `Vector2i` | **旋转之后**的宽 × 高 |
| `base_cells` | `Vector2i` | **未旋转**的基准形状 |
| `rotatable` | `bool` | 是否允许转 90°（几何属性） |
| `rot` | `0` / `90` | 与 `cells` 永远自洽 |

| 方法 | 返回 |
|---|---|
| `Placement.make(payload, at, base, can_rotate := false, dir := 0)` | 新 `Placement`（`cells` 与 `rot` 由 base 推出） |
| `area()` | `cells.x * cells.y` |
| `covers(cell)` | 这一格在不在它覆盖范围内 |
| `copy()` | 浅拷贝（payload 是同一个引用） |

`str(placement)` 给的是 `"@(2, 0) 3x1 rot=90"`，**不带 payload** —— 它可能是任意结构，
塞进日志会把行撑爆。

---

## GridShape

纯几何、全部 `static`、无状态。这是"形状规则"的唯一定义处。

| 方法 | 说明 |
|---|---|
| `normalize(cells)` | 宽高至少 1（`(0, 3)` → `(1, 3)`） |
| `can_rotate(base, rotatable)` | `rotatable and base.x != base.y` |
| `of(base, rotatable, rot)` | 这个方向下**实际**占的形状；`rot < 0` = 正放 |
| `stored_rot(base, rotatable, requested_rot, used_shape)` | 该记下来的 `rot`，与 `of()` 同答案 |
| `contains(grid, anchor, size)` | 完全在网格内 |
| `intersects(a_pos, a_size, b_pos, b_size)` | 两个矩形相交 |
| `cells_at(anchor, size)` | 展开成格，行优先 |

⚠️ 所有 `base` 参数都必须是**未旋转**的形状。把 `Placement.cells` 传进去，
方向会整体错位 90°（`stored_rot()` 的注释里记着旧项目踩过这个坑）。

---

## PlaceFinder / FirstFitFinder

```gdscript
class_name MyFinder
extends PlaceFinder

func find(grid: Vector2i, cells: Vector2i, rotatable: bool, fits: Callable) -> Dictionary:
	# 找不到就返回 {}
	return {"anchor": Vector2i(0, 0), "cells": cells, "rot": 0}
```

- `find()` 必须**只读**：不改容器、不做提交。
- `fits` 是容器绑好的判定 `func(shape, anchor) -> bool`，已经带上 `ignore_index` 语义。
- 返回 `{"anchor", "cells", "rot"}`；`cells` 是**实际形状**（如果换了方向，
  这里给旋转后的），`rot` 是 0 或 90。

`FirstFitFinder` 的顺序（语义，不是实现细节）：

1. 整体先试正放（`base`）：按 y 外、x 内扫所有锚点
2. 都放不下、且可旋转，再从头扫一遍 `Vector2i(base.y, base.x)`

注意**不是**"每个锚点都试两个方向" —— 否则一格里能竖着塞的东西会被横着塞到别的角落。

换策略不需要改 `CellGrid`：

```gdscript
grid.finder = MyFinder.new()
```

---

## GridOps

搬 / 转 / 批量放入的**唯一入口**（`CellGrid` 自己的方法负责单格内的动作）。

### `move(from, to, order := null) -> Dictionary`

跨容器搬一块，**不动目标里已有的块**。返回 `{ok, reason, moved}`。

`order` 的写法：

| 写法 | 语义 |
|---|---|
| `3` / `{"from": 3}` | 搬到对面，位置自己挑（`place_auto`） |
| `{"from": 3, "cell": Vector2i(2, 0), "rot": 90}` | 点名落在这一格、这个方向 |
| `{"from": 3, "to": 1}` | 并进对面第 1 块 |

- `from == to`：自动转交 `move_within()`（同一套规矩，不用记两条路径）。
- `cell` 与 `to` 同时给：拒绝（"只能给一个"）。
- **跨容器不换位**：目标那格是别的东西又合不了 ⇒ 拒绝，理由写明
  `"那一格是别的东西 —— 跨容器只能合并，不能换位（请落在空格上）"`。
- 失败时**两边逐项不变**，包括回滚到原锚点与原方向。

### `problem(from, to, order := null) -> String`

**只读**地问同一件事，与 `move()` 共用 `_plan()`：

```gdscript
if GridOps.problem(a, b, {"from": 0, "cell": c}) == "":
	GridOps.move(a, b, {"from": 0, "cell": c})
```

界面染色、按钮可用性、拖影颜色都问它。

### `move_fitting(from, to, order := null) -> Dictionary`

先走便宜的 `move()`；搬不动才让**目标**重排腾地方。返回
`{ok, reason, moved, repacked, moves}`。

- **点名了 `cell` 或 `to` 时不重排**：玩家已经指着那一格说"放这儿"，
  "我把你自己挪开"不是他要的意思。此时它就是个 `move()`。
- `repacked` = 是不是靠重排才搬成的，`moves` = 为此挪动了几块已有的。
- 重排前先过 `admits()`（顺序见 [06 · 坑](06-pitfalls.md#5-准入规则被重排绕过)）。

### `rotate(grid, key) -> Dictionary`

`CellGrid.rotate()` 的空值安全包装：`grid == null` 也返回合法字典
（`{ok: false, rot: -1, reason: "网格为空"}`）。

### `insert_all(grid, blocks) -> Array`

依次放，放不下的**跳过并继续尝试后面更小的块**，返回没放下的那些。

```gdscript
blocks = [
	{"payload": …, "cells": Vector2i(1, 1), "rotatable": false},
	…
]
var left := GridOps.insert_all(bag, blocks)
```

`cells` 是 **base**。非字典的条目会被原样退回（不猜它想占几格）。
**返回值是 `Array` 而不是 Result**：它回答的是"还剩哪几块"。

### `insert_fitting(grid, blocks) -> Dictionary`

先 `insert_all`，还有剩的才重排。返回
`{ok, placed, left, repacked, moves, reason}`。

- **`ok` = 全部放下**（`left` 为空）。`ok = false` **不代表一块都没放进去** ——
  已经是"尽量多放"的语义，已放下的会留着。
- `left` 是原样的块（含被 `accepts` 拒收的），**绝不静默丢弃**。
- 调用方读 `placed` / `left` 决定把剩下的丢地上还是还给世界。

---

## GridRepacker

```gdscript
static func plan(container: CellGrid, incoming: Array = [], max_attempts: int = 8) -> Dictionary
```

**只读**地算一份新布局，一行都不改网格。

| 返回键 | 含义 |
|---|---|
| `ok` | 算出了完整布局 |
| `layout` | 与 `snapshot()` **同格式**，可直接喂 `restore()` |
| `moves` | 挪动了几块已有的（锚点或方向变了的才算，新块不计） |
| `attempt` | 成功那一轮的组合，如 `"area+tight"` |
| `tried` | 实际跑了几轮 |
| `reason` | 失败理由 |

`incoming` 每条：`{"payload", "cells", "rotatable"}`（`cells` 是 base）。

一般不用直接调它 —— `GridOps.insert_fitting()` / `move_fitting()` 已经串好了顺序。
单独调只有两个理由：

```gdscript
# 1. 纯整理：不加东西，只把现有块排紧
var plan := GridRepacker.plan(bag)
if plan["ok"]:
	bag.restore(plan["layout"])

# 2. 想拿到 moves / attempt 显示给玩家
```

⚠️ `plan()` **不认识 `accepts`**（布局是纯几何问题）。直接拿它的 `layout` 去 `restore()`
会绕过准入规则 —— 自己调的时候这条顺序得自己保证。

算法细节见 [07 · 设计笔记](07-design.md#重排是怎么做的)。

---

## GridLayout

格 ↔ 像素的**纯换算**：没有 Node、没有 `_draw`、没有状态。

```gdscript
var layout := GridLayout.new(Vector2(52, 52), Vector2(4, 4), Vector2(12, 42))
```

| 字段 / 方法 | 说明 |
|---|---|
| `cell_size` | 一格的宽高（像素），默认 `(52, 52)` |
| `spacing` | 格间缝隙，默认 `(4, 4)`。**缝隙不属于任何一格** |
| `origin` | 第 (0,0) 格左上角，默认 `(0,0)` |
| `step()` | `cell_size + spacing`（相邻两格的位移） |
| `board_size(grid)` | 整个网格占多大（含内部缝隙，不含外边距） |
| `cell_rect(cell)` | 一格 → `Rect2` |
| `cell_center(cell)` | 一格的中心 |
| `block_rect(anchor, cells)` | 一块覆盖的大矩形（含内部缝隙） |
| `cell_at(local, grid)` | 点 → 格；**缝隙里或网格外返回 `(-1, -1)`** |
| `cell_at_snapped(local, grid)` | 同上，但落在**格缝里**时吸附到最近的一格；网格外仍返回 `(-1, -1)`。拖拽落点用这个 |

`cell_rect()` 与 `cell_at()` 是同一套数学，所以"画在哪"和"点到哪"结构上不可能分家
（判据第 11 组逐格验证 `cell_at(cell_rect(i).center) == i`）。

**两个"点 → 格"的分工**：`cell_at()` 是严格版，缝隙与网格外都不认 —— 用于"点到哪一块"
（右键旋转、悬停高亮）。`cell_at_snapped()` 是容错版，只把缝隙吸附掉 —— 用于**拖拽落点**，
因为落点算的是"块左上角的连续像素位置"（`鼠标 − 抓取偏移`），它正好压在 4px 缝上完全
可能，用严格版会让"差两个像素"变成"整块放不下"。网格外它同样不给放 —— 拖到标题栏、
板外本来就该是"没落进格子"，那不是像素误差。

`local` 是**相对网格区域左上角**的坐标（通常是 `event.position - board.global_position`
里的那一段）。`origin` 一般设成网格区域在控件内的偏移。

细节与 UI 纪律见 [05 · 接界面](05-view.md)。

---

## 错误理由一览

理由都是给**玩家**看的（可以直接贴进状态栏），但不要拿它做分支判断 ——
它随时可能改措辞。要分支就自己看 `ok`，或者先自己判断再调用。

| 场景 | 理由长什么样 |
|---|---|
| 准入拒绝 | `这个网格不接收这一类东西` |
| 越界 | `1×4 放在 (8, 0) 会越出 9×4 的网格` |
| 重叠 | `(1, 0) 那块（2×2）已经占了这儿` |
| 网格太小 | `网格只有 2×2：1×3 放不下，转过来 3×1 也不行` |
| 面积不够 | `空位不够：2×3 要 6 格，只剩 4 格` |
| 空位被隔碎 | `还剩 3 格空位，但拼不出 1×3（空位被隔碎了）` |
| 转不了 | `2×1 这块是固定方向的` / `3×3 是方的，转不转一个样` |
| 跨容器撞到别的东西 | `那一格是别的东西 —— 跨容器只能合并，不能换位（请落在空格上）` |
| 重排也腾不出 | `…；重排也腾不出地方（重排了 8 轮都放不下：总面积够，但形状凑不出来）` |
| 快照坏了 | `快照里有一条没写 base（占几格）：{…}` |
