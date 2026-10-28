# 05 · 接界面

模块里**一行绘制代码都没有**。这一节说怎么接，以及三条必须守住的纪律。

---

## 三条纪律

### 1. 不许自己判定

"能不能放 / 能不能转"只问：

```gdscript
grid.can_place_at(payload, anchor, cells, rotatable, rot)
grid.move_to_cell_problem(key, anchor, rot)
grid.rotate_problem(key)
GridOps.problem(from, to, order)
```

把判定写进视图，就会出现"幽灵块说谎"：拖影是绿的，松手却放不下。
旧项目踩过这个坑 —— `ContainerPainter._shape_of()` 漏了 `rotatable`，
拖一个固定方向的 1×3 时，拖影画成横的、放下去是竖的。

### 2. 空槽也要画

玩家要能看出这个容器有几格、还剩几格。只画有东西的格子，背包看起来就是一堆浮空的块。

```gdscript
for y in grid.grid_size().y:
	for x in grid.grid_size().x:
		var r := layout.cell_rect(Vector2i(x, y))
		draw_rect(r, Color(1, 1, 1, 0.05), true)
		draw_rect(r, Color(1, 1, 1, 0.10), false, 1.0)
```

### 3. 坐标只有一处

格 → 像素、像素 → 格必须用**同一段数学**，否则就是"点偏一格"。
模块直接给了 `GridLayout`，别自己再写一份。

```gdscript
var layout := GridLayout.new(Vector2(52, 52), Vector2(4, 4), Vector2(12, 42))

layout.cell_rect(cell)          # 画
layout.cell_at(local_pos, grid_size)   # 点
```

判据第 11 组逐格验证 `cell_at(cell_rect(i).center) == i`，并检查缝隙与网格外返回 `(-1,-1)`。

---

## 一个最小的板

```gdscript
class_name GridBoard
extends Control

var container: CellGrid
var layout := GridLayout.new(Vector2(52, 52), Vector2(4, 4), Vector2(12, 42))

func setup(target: CellGrid) -> void:
	container = target
	var board := layout.board_size(target.grid_size())
	custom_minimum_size = Vector2(board.x + 24, board.y + 54)   # 四周留白 + 标题
	target.changed.connect(queue_redraw)     # ← 唯一的接线
	queue_redraw()

func _draw() -> void:
	if container == null:
		return
	var g := container.grid_size()

	# ① 地板
	for y in g.y:
		for x in g.x:
			var r := layout.cell_rect(Vector2i(x, y))
			draw_rect(r, Color(1, 1, 1, 0.05), true)
			draw_rect(r, Color(1, 1, 1, 0.10), false, 1.0)

	# ② 块
	for p in container.placements():
		_draw_block(p)

func _draw_block(p: Placement) -> void:
	# ★ 这一个函数认识 payload —— 因为它是**游戏侧**的代码，愿意认识多少就认识多少
	var color := catalog.color_of(p.payload)
	var r := layout.block_rect(p.anchor, p.cells)
	draw_rect(r, Color(color, 0.72), true)
	draw_rect(r, Color(color, 0.95), false, 1.0)
	draw_string(get_theme_default_font(), r.position + Vector2(6, 18),
		catalog.name_of(p.payload), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 12, 13)
```

`block_rect(anchor, cells)` 返回的大矩形**含内部缝隙**，所以一块 2×2 看起来是连续的一整块，
不是四个带缝的小方块。想画成"四个格子各一块"也行，用 `cells_of(key)` 逐格画。

---

## 拖影

拖影是"幽灵块会不会说谎"的现场。三件事各来自不同的地方：

| 画什么 | 从哪来 |
|---|---|
| 形状 | `GridShape.of(base_cells, rotatable, session.rot)` |
| 位置 | 块的**左上角** = `鼠标 − 抓取偏移`，再过 `layout.cell_at_snapped()` |
| 颜色 | `GridOps.problem(from, to, order)` 是否为空串 |

```gdscript
## 全局坐标 → 块的左上角落在哪格。预览和落点**都调它**（同一个函数 = 不会分家）。
func anchor_at_global(gpos: Vector2) -> Vector2i:
	return layout.cell_at_snapped(gpos - global_position - session.grab_offset,
		container.grid_size())
```

`session.grab_offset` 在按下时算一次：

```gdscript
var grab := pos - layout.block_rect(p.anchor, p.cells).position   # 按下点 − 块左上角
session.begin(self, container, i, p.rot, grab)
```

**少了这一步，块一大就挪不动。** 直接把鼠标所在格当锚点，抓 3×2 的木箱中间等于把
锚点算成 `原锚点 + (1,1)` —— 整块向右下跳，跳过去常常越界或压到别的东西，
于是被拒、弹回原位，玩家的感受是"怎么拖都挪不动一格"。1×1 的块完全看不出这个 bug，
所以它很容易活到玩家手里。

用 `cell_at_snapped()` 而不是 `cell_at()`：块的左上角是连续量，正好压在 4px 格缝上
完全可能，严格版会让"差两个像素"变成"整块放不下"。

```gdscript
func _draw_preview(anchor: Vector2i) -> void:
	var from_grid := session.source_container
	var i := from_grid.index_of_key(session.key)
	if i < 0:
		return
	var p := from_grid.placements()[i]

	# ★ 形状必须与容器同一份几何，而且方向是**具体值**
	var shape := GridShape.of(p.base_cells, p.rotatable, session.rot)
	var r := layout.block_rect(anchor, shape)

	var order := {"from": session.key, "cell": anchor, "rot": session.rot}
	var ok := GridOps.problem(from_grid, container, order) == ""
	if ok:
		draw_rect(r, Color(0.35, 0.85, 0.45, 0.22), true)
		draw_rect(r, Color(0.45, 0.95, 0.55, 0.90), false, 2.0)
	else:
		draw_rect(r, Color(0.95, 0.35, 0.35, 0.22), true)
		draw_rect(r, Color(1.00, 0.45, 0.45, 0.90), false, 2.0)
```

### 为什么拖动中的方向必须是 `0` / `90`

如果 `session.rot` 是 `-1`（"没点名方向"）：

- 预览用 `GridShape.of(base, rotatable, -1)` 画的是**正放**
- 松手时 `place_at` / `move` 会先试正放、放不下再转 ⇒ 结果可能是**转过来的**

于是预览和结果分家。所以：

```gdscript
func begin(board, container, cell_key: int, direction: int) -> void:
	rot = 0 if direction == 0 else 90      # 拿起时的方向就是预览方向
```

玩家用 `R` 换方向时也是 `rot = 0 if rot == 90 else 90`。

### 跨容器拖拽不需要特殊分支

`problem(from_grid, container, order)` 本来就同时接受来源与目标。
当 `from_grid == container` 时它是同容器搬运，不等时是跨容器搬运 —— 视图不需要知道区别。

唯一要注意的是**来源板要把被拖走的那一块画成空槽**：

```gdscript
var is_source := session.is_active() and session.source == self
for i in container.count():
	if is_source and i == session.key:
		_draw_empty_slot(container.placements()[i])   # 东西已经拿在手上了
	else:
		_draw_block(container.placements()[i])
```

---

## 输入

### 点击 → 是哪一块

```gdscript
func _cell_at(pos: Vector2) -> Vector2i:
	return layout.cell_at(pos, container.grid_size())      # 缝隙/框外 = (-1,-1)

func _key_at(pos: Vector2) -> int:
	var cell := _cell_at(pos)
	if cell.x < 0:
		return -1
	return container.key_at_cell(cell)                     # ← 位置索引，别自己遍历
```

`key_at_cell()` 就是为这一步准备的。自己遍历 `placements()` 去拼索引，
迟早会漏掉 `rot`（拿旋转后的 `cells` 当没旋转的用）。

### 跨板松手：用几何判断落点

```gdscript
func board_at(global_pos: Vector2) -> Control:
	for b in boards:
		if is_instance_valid(b) and Rect2(b.global_position, b.size).has_point(global_pos):
			return b
	return null
```

**不要用 `gui_get_hovered_control()`** —— 那样"能不能落"就取决于各个控件的
`mouse_filter`，拖到按钮或标签上会莫名变成"拖到容器外"。
网格该不该收下这一块，是模型的事；鼠标在不在这个矩形里，是几何的事。

### 拖动中的事件要在 `_input()` 里接

`_gui_input()` 只在指针还在本控件上时才来，而拖动时鼠标早就跑出去了。
同理，`R` 键也放 `_input()`（焦点可能被别的控件抢走）。

只有**来源板**处理松手（`session.source == self`），否则两块板会重复处理同一次事件。

### 失焦要收尾

```gdscript
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and session.source == self:
		session.clear()
		redraw_all_boards()
```

Alt+Tab 会丢掉那次松手。不主动收尾的话，session 会一直"举着"东西：
模型没错，但交互卡住了 —— 这类 bug 最难查，因为日志全绿。

---

## 界面文案全在视图

| 内容 | 谁提供 |
|---|---|
| "已用 3 / 36 格" | 视图自己拼：`"已用 %d / %d 格" % [grid.used_cells(), grid.capacity()]` |
| 物品名字、颜色、图标 | 游戏侧的目录（看 payload） |
| 失败理由 | 模块给（`res["reason"]` 可以直接贴到状态栏） |
| 标题、按钮、提示 | 视图 |

界限在这里：**失败理由是"诊断信息"**，写成说人话的中文是应该的；
**界面文案**（标题、读数、按钮）每款游戏都要换，模块里一个字都不该有。
`capacity_text()` 曾经在 `CellGrid` 上，后来被挪走了 —— 就是这条界线。

---

## 重排的过渡动画

`insert_fitting` / `move_fitting` / 整理按钮之后，块会**瞬间**跳到位。
从模型角度看这是对的（一次 `changed`，一个最终布局），但视觉上很突兀。

动画是视图的事。思路：`changed` 里先算每块的新旧位置差，再补间。

```gdscript
var _prev: Dictionary = {}      # 块的身份 → 上一帧的 Rect2

func _on_changed() -> void:
	for p in container.placements():
		var target := layout.block_rect(p.anchor, p.cells)
		# 用 payload 或锚点当作"同一块"的身份（键会漂，别用键）
		…
	queue_redraw()
```

注意两点：

1. **别用键当身份** —— 键是下标，`restore()` 之后顺序按快照来，可能全变了。
   用 payload（或 payload + 锚点）认人。
2. 动画期间**不要**再改网格。模型只保证"当前布局"，没有"过渡中的布局"。

如果暂时不想做动画，一个便宜的办法：在重排后让整个板闪一下 / 暂停 80ms，
比"瞬间洗牌"更容易被玩家接受。

---

## 常见症状对照

| 症状 | 大概原因 |
|---|---|
| 点边缘选中了左边那格 | 自己写了坐标数学，`cell_at` 的边界用了 `>` 而不是 `>=` |
| 拖影是绿的、松手失败 | 视图自己判定了，或者拖动中 `rot = -1` |
| 拖动时块是横的、放下去是竖的 | 拖影用了 `p.cells`（已旋转）当 base |
| 拖到按钮上就"掉到容器外" | 用了 `gui_get_hovered_control()` |
| 松手后东西还在手上（session 没清） | 没处理失焦，或两块板都处理了松手 |
| 整板重绘好多次 | 在循环里 `remove_at` / `place_auto`，每次都是一个 `changed` |
| 空格永远放不下 | 视图改了 `placements()` 拿到的 `Placement`（它是网格持有的对象） |
