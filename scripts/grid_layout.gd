class_name GridLayout
extends RefCounted
## **格 ↔ 像素**的纯几何映射：没有 Node、没有 `_draw`、没有状态。
##
## ══ 为什么它属于模块，而不是视图 ═══════════════════════════
## 这是"两套坐标"必然相遇的唯一地点，而拖拽类 bug 十有八九出在
## 「画在哪」和「点到哪」各写了一段数学（然后有一天它们不再相同）。
## 把它放进模块带来两件事：
##   ① 接入方不必每家重写一遍最容易写错的那十几行；
##   ② 一条 headless 断言就能钉死：`cell_at(cell_rect(i).center) == i`。
##
## 它**不画任何东西** —— 只是把格子编号换算成矩形，把点换算回格子编号。
## 用什么颜色、画什么图标、要不要加动画，仍然全是视图的事。

## 一格多宽多高（像素）。
var cell_size := Vector2(52.0, 52.0)
## 格与格之间的缝隙。缝隙不属于任何一格（`cell_at()` 会返回 `(-1, -1)`）。
var spacing := Vector2(4.0, 4.0)
## 第 (0, 0) 格左上角的像素位置。界面上通常让它是"网格区域左上角"。
var origin := Vector2.ZERO


func _init(cell: Vector2 = Vector2(52.0, 52.0), gap: Vector2 = Vector2(4.0, 4.0),
		offset: Vector2 = Vector2.ZERO) -> void:
	cell_size = cell
	spacing = gap
	origin = offset


## 相邻两格的位移。
func step() -> Vector2:
	return cell_size + spacing


## 整个网格在屏幕上占多大（含内部缝隙，不含外边距）。
func board_size(grid: Vector2i) -> Vector2:
	if grid.x <= 0 or grid.y <= 0:
		return Vector2.ZERO
	return Vector2(grid) * cell_size + Vector2(maxi(0, grid.x - 1), maxi(0, grid.y - 1)) * spacing


## 一格 → 矩形。
func cell_rect(cell: Vector2i) -> Rect2:
	return Rect2(origin + Vector2(cell) * step(), cell_size)


func cell_center(cell: Vector2i) -> Vector2:
	return cell_rect(cell).get_center()


## 一块（`anchor` + 旋转后的 `cells`）→ 覆盖所有格子的那个大矩形（含内部缝隙）。
func block_rect(anchor: Vector2i, cells: Vector2i) -> Rect2:
	var a := cell_rect(anchor)
	var b := cell_rect(anchor + cells - Vector2i.ONE)
	return Rect2(a.position, b.end - a.position)


## 点 → 格。落在**缝隙里**或**网格外**都返回 `(-1, -1)`。
## 与 `cell_rect()` 是同一套数学（这是它们必须待在同一处的原因）。
func cell_at(local: Vector2, grid: Vector2i) -> Vector2i:
	var p := local - origin
	if p.x < 0.0 or p.y < 0.0:
		return Vector2i(-1, -1)
	var s := step()
	var cx := floori(p.x / s.x)
	var cy := floori(p.y / s.y)
	if cx < 0 or cy < 0 or cx >= grid.x or cy >= grid.y:
		return Vector2i(-1, -1)
	var inside := p - Vector2(float(cx) * s.x, float(cy) * s.y)
	# `>=` 而不是 `>`：恰好落在格子右/下边界上的那一点属于**缝隙**，
	# 不属于任何一格。写 `>` 会让"正边界"这一点被算进前一格（无缝时看不出来，
	# 一加缝隙就变成"点边缘选中了左边那格"）。
	if inside.x >= cell_size.x or inside.y >= cell_size.y:
		return Vector2i(-1, -1)
	return Vector2i(cx, cy)


## 点 → 格，**容错**版本：落在缝隙上时吸附到最近的一格。
##
## 为什么不直接用 `cell_at()`：拖拽落点算的是**块左上角**的位置
## （`鼠标 - 抓取偏移`），那个点是连续的，正好压在 4px 的格缝上完全可能。
## 用严格版会让"差两像素"变成"整块放不下"，玩家看到的是预览闪一下然后拒绝。
##
## 仍然**不放宽到网格外**：拖到标题栏、边框上还是返回 `(-1, -1)` ——
## 那里本来就不该落东西，和"缝隙只是像素问题"不是一回事。
func cell_at_snapped(local: Vector2, grid: Vector2i) -> Vector2i:
	var exact := cell_at(local, grid)
	if exact.x >= 0 or grid.x <= 0 or grid.y <= 0:
		return exact
	var p := local - origin
	var board := board_size(grid)
	if p.x < 0.0 or p.y < 0.0 or p.x > board.x or p.y > board.y:
		return Vector2i(-1, -1)
	# 落在缝隙里 ⇒ 取最近的格**中心**（不是在缝的两边二选一，直接四舍五入）
	var s := step()
	var cx := clampi(roundi((p.x - cell_size.x * 0.5) / s.x), 0, grid.x - 1)
	var cy := clampi(roundi((p.y - cell_size.y * 0.5) / s.y), 0, grid.y - 1)
	return Vector2i(cx, cy)
