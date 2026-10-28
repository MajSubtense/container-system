class_name DemoGridBoard
extends Control
## 【**游戏侧** · 不属于容器模块】**一种**可视化方案。
##
## 这一层只做三件事：把 `placements()` 画出来、把鼠标位置翻译成格子、把拖动/旋转
## 翻译成 `GridOps` 的调用。**它不做任何判定** —— "能不能放"一律问
## `GridOps.problem()`，"放下去"一律调 `GridOps.move()`。
## 这条边界就是接入契约：换一套美术、换一套输入（手柄/触屏）都不影响模型。
##
## ══ 它认识"物品"吗 ════════════════════════════════════
## 认识 —— 因为它是**游戏侧**的代码。它拿 `payload` 去 `DemoItemCatalog` 查名字和颜色。
## 模型那边完全不认识，这里愿意认识多少就认识多少。
##
## ══ 跨网格拖拽 ═══════════════════════════════════════
## 拖拽状态不归任何一块板，而是放在共享的 `DemoDragSession` 里。每块板只回答两个问题：
##   「被按下的是我的第几块」→ 写进 session；
##   「鼠标现在在我身上吗」→ 是就画一个影子，颜色问 `problem()`。
## 于是"拖到另一块板上"不需要任何特殊分支 —— 目标板只是在画它自己的那份预览。

signal status(text: String, is_ok: bool)

const PAD := 12.0
const HEADER := 30.0

var container: CellGrid = null
## 格 ↔ 像素的换算**直接用模块给的 `GridLayout`** —— 视图不再自己写一份坐标数学。
## （这段曾经是 demo 里最容易写错、也最容易被抄错的十几行，所以固化进了模块。）
var layout := GridLayout.new(Vector2(52.0, 52.0), Vector2(4.0, 4.0), Vector2(PAD, HEADER + PAD))
var catalog: DemoItemCatalog = null
var title: String = ""
var session: DemoDragSession = null

var _hover: Vector2i = Vector2i(-1, -1)


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP


## 绑定一个网格与**共享的**拖拽会话。之后所有重绘都由网格的 `changed` 信号驱动。
func setup(target: CellGrid, item_catalog: DemoItemCatalog, board_title: String,
		shared: DemoDragSession) -> void:
	container = target
	catalog = item_catalog
	title = board_title
	session = shared
	if session != null and not session.boards.has(self):
		session.boards.append(self)
	var board := layout.board_size(target.grid_size())
	custom_minimum_size = Vector2(board.x + PAD * 2.0, HEADER + board.y + PAD * 2.0)
	target.changed.connect(queue_redraw)
	queue_redraw()


# ══ 绘制 ══════════════════════════════════════════════

func _draw() -> void:
	if container == null:
		return
	var f := get_theme_default_font()
	var fs := get_theme_default_font_size()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.10, 0.11, 0.13, 0.85))
	draw_string(f, Vector2(PAD, 22.0), title, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fs,
		Color(0.86, 0.88, 0.92))
	draw_string(f, Vector2(size.x - PAD - 130.0, 22.0), _capacity_text(),
		HORIZONTAL_ALIGNMENT_RIGHT, 130.0, 12, Color(0.60, 0.66, 0.74))

	var dragging := session != null and session.is_active()
	# 我是来源板 ⇒ 被拖走的那一块画成"空槽"（东西已经拿在手上了）
	var is_source := dragging and session.source == self
	# 我是当前悬停的目标板 ⇒ 给整个板描一圈，让玩家知道会落到这儿
	var is_target := dragging and session.board_at(session.mouse) == self

	var g := container.grid_size()
	for y in g.y:
		for x in g.x:
			var cell := Vector2i(x, y)
			var r := layout.cell_rect(cell)
			draw_rect(r, Color(1, 1, 1, 0.05), true)
			var edge := Color(1, 1, 1, 0.10)
			if cell == _hover and not dragging:
				edge = Color(0.55, 0.75, 1.00, 0.65)
			draw_rect(r, edge, false, 1.0)

	if is_target:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.55, 0.75, 1.00, 0.45), false, 2.0)

	var ps := container.placements()
	for i in ps.size():
		if is_source and i == session.key:
			var ghost := layout.block_rect(ps[i].anchor, ps[i].cells)
			draw_rect(ghost, Color(1, 1, 1, 0.03), true)
			draw_rect(ghost, Color(1, 1, 1, 0.30), false, 1.0)
			continue
		_draw_block(ps[i], f, fs)

	if dragging:
		var anchor := anchor_at_global(session.mouse)
		if anchor.x >= 0:
			_draw_preview(anchor, f, fs)


func _draw_block(p: Placement, f: Font, fs: int) -> void:
	var id := DemoItemRules.id_of(p.payload)
	var base := catalog.color_of(id) if catalog != null else Color(0.40, 0.46, 0.56)
	var r := layout.block_rect(p.anchor, p.cells)
	draw_rect(r, Color(base.r, base.g, base.b, 0.72), true)
	draw_rect(r, Color(base.r, base.g, base.b, 0.95), false, 1.0)
	var inset := r.grow(-6.0)
	# 块上的字比标题小一号：`mini(fs, 13)` 而不是写死 13，换主题字号时这里会跟着变
	var text_size := mini(fs, 13)
	# 名字和数量来自游戏侧（`catalog` / `payload`），模型不知道这些
	var label: String = String(id) if catalog == null else catalog.name_of(id)
	draw_string(f, Vector2(inset.position.x, inset.position.y + 14.0), label,
		HORIZONTAL_ALIGNMENT_LEFT, inset.size.x, text_size, Color(1, 1, 1, 0.92))
	var n := DemoItemRules.count_of(p.payload)
	if n > 1:
		draw_string(f, Vector2(inset.position.x, inset.end.y - 1.0), "×%d" % n,
			HORIZONTAL_ALIGNMENT_RIGHT, inset.size.x, text_size, Color(1, 1, 1, 0.85))


## 拖影：形状与颜色**都来自模型**。形状用 `GridShape.of()`（与容器同一份几何），
## 颜色问 `GridOps.problem()` —— 视图只负责上色，不负责算。
##
## 注意 `from` 是 `session.source_container`：跨网格时它和 `container` 不是同一个，
## 而 `problem()` 本来就同时接受（来源, 目标）。视图不需要知道这是"跨网格"。
func _draw_preview(anchor: Vector2i, f: Font, fs: int) -> void:
	var from_grid := session.source_container
	if from_grid == null:
		return
	var i := from_grid.index_of_key(session.key)
	if i < 0:
		return
	var p := from_grid.placements()[i]
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
	var label := _label_of(p.payload)
	draw_string(f, r.position + Vector2(6.0, 20.0), label,
		HORIZONTAL_ALIGNMENT_LEFT, maxf(10.0, r.size.x - 8.0), mini(fs, 14),
		Color(1, 1, 1, 0.95))


# ══ 输入 ══════════════════════════════════════════════

func _gui_input(event: InputEvent) -> void:
	if container == null:
		return
	if event is InputEventMouseMotion:
		var cell := _cell_at(event.position)
		if cell != _hover:
			_hover = cell
			queue_redraw()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_begin_drag(event.position)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if session != null and session.is_active():
				return          # 拖动中按右键不转容器里的东西，避免误操作
			_rotate_at(event.position)
			accept_event()


## 拖动中的事件只能在这里接，两个原因：
##   · 鼠标可能已经跑出这块控件（`_gui_input` 只在指针在本控件上时才来）；
##   · 焦点可能被别的控件抢走，所以 R 键也放这儿，而不是 `_gui_input`。
## 只有**来源板**处理（`session.source == self`），否则两块板会重复处理同一次松手。
func _input(event: InputEvent) -> void:
	if session == null or not session.is_active() or session.source != self:
		return
	if event is InputEventMouseMotion:
		session.mouse = get_global_mouse_position()
		_redraw_all()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		session.flip()
		_redraw_all()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_drop_at(get_global_mouse_position())
		get_viewport().set_input_as_handled()


## 拖动中窗口失焦（Alt+Tab、点到别的窗口）：那次松手永远收不到，
## 不主动收尾的话 session 会一直"举着"东西，模型没错但交互就卡住了。
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and session != null and session.source == self:
		session.clear()
		_redraw_all()


func _begin_drag(pos: Vector2) -> void:
	var cell := _cell_at(pos)
	var i := container.key_at_cell(cell)          # ← 位置索引：格 → 第几块
	if i < 0:
		status.emit("这一格是空的", false)
		return
	var p := container.placements()[i]
	# 抓在块的哪儿，就一直在那儿：记下"按下点 − 块左上角"（**局部坐标**，
	# 和 `layout` 同一套数学；用全局坐标在有缩放的 Control 上会差一截）。
	# 少了这一步，抓 2×3 的木箱中间就会把锚点算成鼠标所在格，整块跳位。
	var grab := pos - layout.block_rect(p.anchor, p.cells).position
	session.begin(self, container, i, p.rot, grab)
	session.mouse = get_global_mouse_position()
	grab_focus()
	_redraw_all()
	status.emit("拿起 %s —— 拖到任意一块板上放下，R 换方向" % _label_of(p.payload), true)


## 松手：落点由**几何**决定（`board_at`），合法性由**模型**决定（`problem`）。
func _drop_at(global_pos: Vector2) -> void:
	var from_grid := session.source_container
	var key := session.key
	var rot := session.rot
	var idx := -1 if from_grid == null else from_grid.index_of_key(key)
	var p: Placement = null if idx < 0 else from_grid.placements()[idx]
	var target := session.board_at(global_pos) as DemoGridBoard
	var cell := Vector2i(-1, -1)
	if target != null:
		# ★ 落点 = **块的左上角**落在哪格，不是鼠标在哪格。
		#   和绘制预览用的是同一个函数 ⇒ 幽灵块与结果不可能分家。
		cell = target.anchor_at_global(global_pos)
	session.clear()
	_redraw_all()

	if p == null:
		return
	var label := _label_of(p.payload)

	if target == null:
		status.emit("%s 没动：拖到了所有容器的外面（真实游戏里这一步是「丢在地上」）" % label, false)
		return
	if cell.x < 0:
		status.emit("%s 没动：落点不在「%s」的格子里" % [label, target.title], false)
		return

	# ★ 游戏侧的一句贴心话：落到同种东西上但那堆已经满了 ⇒ 直接说清楚，
	#   不要让它悄悄变成"换位"。这条规则属于游戏，容器不知道"满"是什么意思。
	#   按**落点覆盖的所有格**找，而不是只看左上角那一格 —— 2×3 的箱子
	#   恰好只有左上角压到同类堆才算命中，那是运气，不是规则。
	var shape := GridShape.of(p.base_cells, p.rotatable, rot)
	var same_id := DemoItemRules.id_of(p.payload)
	var same_grid := from_grid == target.container
	for c in GridShape.cells_at(cell, shape):
		var occupied := target.container.at_cell(c)
		if occupied == null or DemoItemRules.id_of(occupied.payload) != same_id:
			continue
		# ★ 自己原来那一块不算挡路：拖动中它**还在模型里**（视图只是把它画成空槽），
		#   不跳过的话"只挪一格"必然压到自己，然后被当成"同类堆已满"顶回来 ——
		#   症状就是"落点还在块范围内就弹回原位，一格都挪不动"。
		if same_grid and occupied == p:
			continue
		if not target.container.can_merge_at(target.container.key_at_cell(c), p.payload):
			status.emit("%s 那一堆已经到上限了（%d），不会再合并" % [
				label, catalog.max_stack_of(same_id)], false)
			return
		break

	var order := {"from": key, "cell": cell, "rot": rot}
	var why := GridOps.problem(from_grid, target.container, order)
	if why != "":
		status.emit(why, false)
		return
	var res := GridOps.move(from_grid, target.container, order)
	if not bool(res["ok"]):
		status.emit(str(res["reason"]), false)
		return
	var where := "原处" if from_grid == target.container else "「%s」" % target.title
	status.emit("%s → %s %s · %s" % [label, where, str(cell), _rot_text(rot)], true)


func _rotate_at(pos: Vector2) -> void:
	var cell := _cell_at(pos)
	var i := container.key_at_cell(cell)
	if i < 0:
		return
	var res := GridOps.rotate(container, i)
	if bool(res["ok"]):
		status.emit("原地转过来了：现在 %d°" % int(res["rot"]), true)
	else:
		status.emit(str(res["reason"]), false)


func _redraw_all() -> void:
	if session == null:
		queue_redraw()
		return
	for b in session.boards:
		if is_instance_valid(b):
			b.queue_redraw()


# ══ 几何 ═══════════════════════════════════════════════

## 点 → 格。**换算本身在 `GridLayout` 里**（与绘制用的是同一段数学，不可能分家）。
## 落在格缝里或框外返回 `(-1, -1)`。
func _cell_at(pos: Vector2) -> Vector2i:
	if container == null:
		return Vector2i(-1, -1)
	return layout.cell_at(pos, container.grid_size())


## 全局坐标 → **块的左上角**落在本板的哪一格。
##
## 拖拽的预览和落点都必须走这一条，两个理由：
##   ① `gpos - 抓取偏移` 才是块的左上角，直接用 `gpos` 等于把"鼠标格"当锚点
##      （抓 2×3 的木箱中间时锚点会凭空多出 (1,1)，整块跳位、且挪不动一格）；
##   ② 用 `cell_at_snapped()`：左上角压在 4px 格缝上也吸附到最近格，
##      不会因为差两个像素就"整块放不下"。
##
## ★ 别再退回"鼠标在哪格，块就落哪格"——那种写法对 1×1 的块看不出来，
##   块一大就变成"永远弹回原位"。
func anchor_at_global(gpos: Vector2) -> Vector2i:
	if container == null:
		return Vector2i(-1, -1)
	var offset := session.grab_offset if session != null else Vector2.ZERO
	return layout.cell_at_snapped(gpos - global_position - offset, container.grid_size())


# ══ 小工具 ════════════════════════════════════════════

## 容量读数。**文案在游戏侧拼** —— 模块只给 `used_cells()` / `capacity()` 两个数，
## 因为"已用 3 / 36 格"和"3 of 36 slots"该长什么样，是这一款游戏的事。
func _capacity_text() -> String:
	return "已用 %d / %d 格" % [container.used_cells(), container.capacity()]


func _label_of(payload) -> String:
	var id := DemoItemRules.id_of(payload)
	if id == &"":
		return "这一块"
	# ★ 显式标 String：`StringName` 与 `String` 混在三元里，GDScript 会报
	#   INCOMPATIBLE_TERNARY（"Values of the ternary operator are not mutually compatible"）
	var label: String = String(id) if catalog == null else catalog.name_of(id)
	return label


func _rot_text(rot: int) -> String:
	return "自动方向" if rot < 0 else "%d°" % rot
