class_name CellGrid
extends RefCounted
## **M×N 的格子**：往上面摆 m×n 的矩形块。位置是一等公民。
##
## ══ 它认识什么、不认识什么 ═══════════════════════════════
## 认识：几行几列、每块占哪几格、能不能转 90°、位置索引。
## 不认识：名字、图标、颜色、数量、堆叠上限、物品目录、拾取策略。
## 所以它没有 `count_of()` / `total()` / `add(stack)` ——
## **"一堆 25 个木头占几格"是游戏的规则**（上限是设计参数），
## 游戏把它切成 3 块，再来问容器"这 3 块放得下吗"。
##
## 块的"身份"挂在 `Placement.payload` 上，容器把它当**不透明**的东西：
## 搬进搬出、写快照、还给你，但从不解读、从不比较。
## 于是同一个模块能同时服务"背包里的枪"和"网格上的建筑"。
##
## ══ 数据模型：只有一份真相 ════════════════════════════
## `_items = [Placement, …]`，一块一条。占位**不另存稠密表**，相交/命中全部现算。
## 存两份就会长出「表里有、列表里没有」的状态，界面上表现为「某一格永远放不下」；
## 位置索引（`at_cell()`）因此是**查询**而不是第二份数据。
##
## ══ 唯一判定入口 ═════════════════════════════════════
## `fits_at()` 只读，`place_*()` / `move_*()` / `room_for()` 全部问它
## ⇒「界面说能放、松手放不下」在结构上不可能。
##
## ══ 返回值只有两种形状 ═════════════════════════════════
## **判定**（只读）→ `String`：空串 = 可以，非空 = 理由。
##   `fits_at()` `can_place_at()` `move_to_cell_problem()` `rotate_problem()`
##   `move_within_problem()` `restore()`（空串 = 还原成功）
## **动作**（写入）→ `Dictionary`，成功与失败的**键集合完全相同**，
##   失败时附加字段取空值（`-1` / `0` / `null`）⇒ 可以先读 `ok`，再用同一批键：
##   · 放入 `place_auto()` / `place_at()` → `{ok, reason, placement, key}`
##   · 搬运 `move_to_cell()` / `move_within()` / `merge_into()` → `{ok, reason, moved}`
##   · 旋转 `rotate()` → `{ok, reason, rot}`
## 两条不变式（判据第 14 组钉住）：`ok == true` ⇒ `reason == ""`；
## `ok == false` ⇒ `reason != ""`。**永远只有这两种组合。**

signal changed

const DEFAULT_SIZE := Vector2i(9, 4)

## 找位策略（默认行优先 + 旋转兜底）。换算法 = 换个对象，本文件一行不用改。
var finder: PlaceFinder = null
## 可选准入 `Callable(payload) -> bool`。空 = 什么都收。
## 「枪不进这个容器」是**拥有这一格的那一层**的规矩，网格只负责问一句。
var accepts: Callable = Callable()
## 可选合并规则 `Callable(新来的 payload, 已在场上的 payload) -> Variant`。
## 返回新 payload = 可以合并（两块塌成一块）；返回 `null` = 不能合并。
## 空 = 永不合并（纯几何块语义）。
## ★ "25 个 + 10 个 = 35 个、上限 999" 是**游戏规则**，容器只负责问、不负责算。
var merge_rule: Callable = Callable()

var _size: Vector2i = DEFAULT_SIZE
var _items: Array[Placement] = []


func _init(size: Vector2i = DEFAULT_SIZE, place_finder: PlaceFinder = null) -> void:
	_size = Vector2i(maxi(0, size.x), maxi(0, size.y))
	finder = place_finder if place_finder != null else FirstFitFinder.new()


# ══ 读 / 位置索引 ═════════════════════════════════════

func grid_size() -> Vector2i:
	return _size


## 容量 = **格数**（不是块数）："还剩多少地方"只有格数说得清。
func capacity() -> int:
	return _size.x * _size.y


## 一块一条。**数组是副本，元素是本网格持有的对象 ⇒ 只读**；
## 要比较两个时刻的内容请用 `snapshot()`。
func placements() -> Array[Placement]:
	var out: Array[Placement] = []
	out.assign(_items)
	return out


func count() -> int:
	return _items.size()


## 这一格被哪一块占着（null = 空）。这就是**位置索引**：
## 界面拿它做命中测试，不必自己遍历 `placements()` 去拼重建索引。
func at_cell(cell: Vector2i) -> Placement:
	var i := key_at_cell(cell)
	return null if i < 0 else _items[i]


## 这一格属于 `placements()` 里的第几条（-1 = 空）。键就是下标。
func key_at_cell(cell: Vector2i) -> int:
	for i in _items.size():
		if _items[i].covers(cell):
			return i
	return -1


## 第 `key` 块占了哪些格（行优先）。画图/范围特效共用，别各写一份。
func cells_of(key) -> Array[Vector2i]:
	var i := index_of_key(key)
	if i < 0:
		var empty: Array[Vector2i] = []
		return empty
	var p := _items[i]
	return GridShape.cells_at(p.anchor, p.cells)


func index_of_key(key) -> int:
	if key is int or key is float:
		var i := int(key)
		return i if i >= 0 and i < _items.size() else -1
	return -1


func used_cells() -> int:
	var n := 0
	for p in _items:
		n += p.area()
	return n


func free_cells() -> int:
	return maxi(0, capacity() - used_cells())


func is_empty() -> bool:
	return _items.is_empty()


## 一次清空。**一次 `changed`** —— 挨个 `remove_at()` 会发 N 次信号，
## 界面就要跟着重绘 N 遍（而且中间那些瞬间里，网格处于"只清了一半"的状态）。
func clear() -> void:
	if _items.is_empty():
		return
	_items.clear()
	_did_change()


## 诊断用的一行摘要（"现在装了什么"）。给日志和错误信息用，**不是界面文案**。
##
## 界线在这里：**失败理由是给玩家看的**（`"空位不够：2×3 要 6 格，只剩 4 格"` 直接贴进状态栏
## 就行），所以写成了说人话的中文；但**界面文案**（标题、容量读数、按钮）一概不在模块里 ——
## 那是每款游戏都要换的东西。`describe()` 属于前者（诊断），`capacity_text()` 曾属于后者，已挪走。
func describe() -> String:
	var parts: Array[String] = []
	for p in _items:
		parts.append("%s@%s" % ["%dx%d" % [p.cells.x, p.cells.y], str(p.anchor)])
	var body: String = "空" if parts.is_empty() else "、".join(parts)
	return "网格 %d×%d（%d 块 / %d 格）：%s" % [
		_size.x, _size.y, _items.size(), used_cells(), body]


# ══ 判定（全部只读）═════════════════════════════════

## ★ 唯一判定入口：`cells` 放在 `anchor` 放得下吗（空串 = 放得下）。
## `ignore_index` = 把第几条当作已经拿开（换位、挪动自己时必须给）。
func fits_at(cells: Vector2i, anchor: Vector2i, ignore_index: int = -1) -> String:
	if cells.x <= 0 or cells.y <= 0:
		return "形状不合法（%d×%d）" % [cells.x, cells.y]
	if not GridShape.contains(_size, anchor, cells):
		return "%d×%d 放在 %s 会越出 %d×%d 的网格" % [
			cells.x, cells.y, str(anchor), _size.x, _size.y]
	for i in _items.size():
		if i == ignore_index:
			continue
		var p := _items[i]
		if GridShape.intersects(anchor, cells, p.anchor, p.cells):
			return "%s 那块（%d×%d）已经占了这儿" % [str(p.anchor), p.cells.x, p.cells.y]
	return ""


## 这个网格收不收这个 payload —— 也就是注入的 `accepts` 准入规则（没注入 = 什么都收）。
##
## ★ 单独立一个方法，是因为"收不收"和"放不放得下"是**两件事**，而且先后有别：
##   收的东西才轮到讨论位置。`GridOps` 的重排路径必须先用它筛一遍 ——
##   `restore()` 是**刻意不问**准入的（见下），于是"放不下就重排"那条路会借道
##   `restore()` 把被拒的东西偷偷塞进去。
func admits(payload) -> bool:
	return not accepts.is_valid() or bool(accepts.call(payload))


## 只读地问：「这块放得下吗」。`anchor` 的 x < 0 = 问「随便哪儿都行吗」。
## `rot = -1` = 没点名方向（正放，不行再转过来）；`0/90` = 就照这个方向。
func can_place_at(payload, anchor: Vector2i, cells: Vector2i,
		rotatable: bool = false, rot: int = -1) -> String:
	if not admits(payload):
		return "这个网格不接收这一类东西"
	var base := GridShape.normalize(cells)
	if anchor.x < 0:
		if not _anywhere(base, rotatable).is_empty():
			return ""
		return _auto_reason(base, rotatable)
	if _landing(base, anchor, rotatable, rot, -1).is_empty():
		return _landing_reason(base, anchor, rotatable, rot, -1)
	return ""


## 还能放几块这么大的（**干跑：在一份副本上真放一遍**，与 `place_auto()` 同源）。
func room_for(cells: Vector2i, rotatable: bool = false) -> int:
	var base := GridShape.normalize(cells)
	if base.x <= 0 or base.y <= 0:
		return 0
	var probe := _probe_copy()
	var n := 0
	while true:
		var spot := probe._find_spot(base, rotatable, -1)
		if spot.is_empty():
			break
		probe._put_back(Placement.make(null, spot["anchor"], base, rotatable, int(spot["rot"])))
		n += 1
		if n > capacity():
			break
	return n


# ══ 写入 ═════════════════════════════════════════════

## 自己挑位置放一块。返回 `{"ok", "reason", "placement", "key"}`。
func place_auto(payload, cells: Vector2i, rotatable: bool = false) -> Dictionary:
	var base := GridShape.normalize(cells)
	if not admits(payload):
		return _place_fail("这个网格不接收这一类东西")
	var spot := _find_spot(base, rotatable, -1)
	if spot.is_empty():
		return _place_fail(_auto_reason(base, rotatable))
	return _commit(Placement.make(payload, spot["anchor"], base, rotatable, int(spot["rot"])))


## 点名锚点放一块。`rot = -1` 表示"正放，正放不行再转过来"。
func place_at(payload, anchor: Vector2i, cells: Vector2i,
		rotatable: bool = false, rot: int = -1) -> Dictionary:
	var base := GridShape.normalize(cells)
	if not admits(payload):
		return _place_fail("这个网格不接收这一类东西")
	var land := _landing(base, anchor, rotatable, rot, -1)
	if land.is_empty():
		return _place_fail(_landing_reason(base, anchor, rotatable, rot, -1))
	return _commit(Placement.make(payload, anchor, base, rotatable, int(land["rot"])))


## 取走第 `key` 块，返回它（取不到返回 null）。★ 键是下标，删除会让后面的前移。
func remove_at(key) -> Placement:
	var i := index_of_key(key)
	if i < 0:
		return null
	var p := _items[i]
	_items.remove_at(i)
	_did_change()
	return p


## 把第 `key` 块整体搬到 `anchor`。`rot < 0` = 保持原方向。
func move_to_cell(key, anchor: Vector2i, rot: int = -1) -> Dictionary:
	var i := index_of_key(key)
	if i < 0:
		return _move_fail("网格里没有第 %s 块" % str(key))
	var p := _items[i]
	var want: int = p.rot if rot < 0 else rot
	var land := _landing(p.base_cells, anchor, p.rotatable, want, i)   # 自己那块不算挡路
	if land.is_empty():
		return _move_fail(_landing_reason(p.base_cells, anchor, p.rotatable, want, i))
	var shape: Vector2i = land["cells"]
	if p.anchor == anchor and p.cells == shape:
		return _move_ok(0)
	p.anchor = anchor
	p.cells = shape
	p.rot = int(land["rot"])
	_did_change()
	return _move_ok(1)


func move_to_cell_problem(key, anchor: Vector2i, rot: int = -1) -> String:
	var i := index_of_key(key)
	if i < 0:
		return "网格里没有第 %s 块" % str(key)
	var p := _items[i]
	var want: int = p.rot if rot < 0 else rot
	if _landing(p.base_cells, anchor, p.rotatable, want, i).is_empty():
		return _landing_reason(p.base_cells, anchor, p.rotatable, want, i)
	return ""


## 转个方向（只有两态，一次调用就是"转过来"）。
func rotate_problem(key) -> String:
	var i := index_of_key(key)
	if i < 0:
		return "网格里没有第 %s 块" % str(key)
	var p := _items[i]
	if not p.rotatable:
		return "%d×%d 这块是固定方向的" % [p.base_cells.x, p.base_cells.y]
	if p.base_cells.x == p.base_cells.y:
		return "%d×%d 是方的，转不转一个样" % [p.base_cells.x, p.base_cells.y]
	var next := 0 if p.rot != 0 else 90
	var why := fits_at(GridShape.of(p.base_cells, p.rotatable, next), p.anchor, i)
	return "" if why == "" else "转过来就放不下了：%s" % why


func rotate(key) -> Dictionary:
	var why := rotate_problem(key)
	if why != "":
		return _rot_fail(why)
	var p := _items[index_of_key(key)]
	var next := 0 if p.rot != 0 else 90
	p.rot = next
	p.cells = GridShape.of(p.base_cells, p.rotatable, next)
	_did_change()
	return {"ok": true, "reason": "", "rot": next}


## 只读地问：「手上这块并得进第 `key` 块吗」。
func can_merge_at(key, payload) -> bool:
	var i := index_of_key(key)
	return i >= 0 and _merged_payload(payload, _items[i].payload) != null


## 把手上这一块并进第 `key` 块（跨容器搬运的合并路径）。
## 合并**不改形**：合并后的东西沿用目标那一块的锚点与形状。
func merge_into(key, payload) -> Dictionary:
	var i := index_of_key(key)
	if i < 0:
		return _move_fail("目标那块不见了")
	var merged = _merged_payload(payload, _items[i].payload)
	if merged == null:
		return _move_fail("这两块不能合并")
	_items[i].payload = merged
	_did_change()
	return _move_ok(1)


## 网格内的格间搬运。三种语义（规则只写在这里，别处不许再写一份）：
##   ① 目标是空格 / 没点名 ⇒ 搬到第一块放得下的空地（忽略自己）
##   ② 合并规则说能合   ⇒ 两块塌成一块（沿用目标的位置与形状）
##   ③ 异类            ⇒ **整块换位**（只搬一部分已经没有这个概念：块是原子的）
func move_within(from_key, to_key = null) -> Dictionary:
	var ia := index_of_key(from_key)
	if ia < 0:
		return _move_fail("网格里没有第 %s 块" % str(from_key))
	if to_key != null and index_of_key(to_key) == ia:
		return _move_ok(0)

	if to_key == null:
		var p := _items[ia]
		var spot := _find_spot(p.base_cells, p.rotatable, ia)
		if spot.is_empty():
			return _move_fail("网格里找不到放得下它（%d×%d）的地方" % [p.cells.x, p.cells.y])
		p.anchor = spot["anchor"]
		p.cells = spot["cells"]
		p.rot = int(spot["rot"])
		_did_change()
		return _move_ok(1)

	var ib := index_of_key(to_key)
	if ib < 0:
		return _move_fail("网格里没有第 %s 块" % str(to_key))
	var src := _items[ia]
	var dst := _items[ib]

	# ② 合并
	var merged = _merged_payload(src.payload, dst.payload)
	if merged != null:
		dst.payload = merged
		_items.remove_at(ia)                    # 塌成一块，源那一块消失
		_did_change()
		return _move_ok(1)

	# ③ 换位：两件都先拿开再判，否则会被**自己原来的占位**挡住
	var s_anchor := src.anchor
	var d_anchor := dst.anchor
	var probe := _probe_copy_without(ia, ib)
	var bad := probe.fits_at(src.cells, d_anchor) + probe.fits_at(dst.cells, s_anchor)
	if bad != "":
		return _move_fail("换位放不下：%s" % bad)
	# 两件"各自放得下"还不够：换完之后彼此不许压住（1×1 钻进 2×1 的位置就会）
	if GridShape.intersects(d_anchor, src.cells, s_anchor, dst.cells):
		return _move_fail("换位后两块会互相重叠（%d×%d ↔ %d×%d）" % [
			src.cells.x, src.cells.y, dst.cells.x, dst.cells.y])
	src.anchor = d_anchor
	dst.anchor = s_anchor
	_did_change()
	return _move_ok(2)


func move_within_problem(from_key, to_key = null) -> String:
	var probe := _probe_copy()
	var r := probe.move_within(from_key, to_key)
	return str(r["reason"])


# ══ 存读档（不需要物品表）═════════════════════════════

## 逐块快照。`anchor` 用 `[x, y]`：JSON 走不过 Vector2i，这样 `JSON.stringify` 直接可用。
## `payload` 原样带上 ⇒ 读档时**不需要任何物品目录**就能还原整个网格。
##
## ★ 想走 JSON 的话，你的 payload 必须是 JSON 安全的 —— 这是唯一的约束，但要说清两件事：
##   ① `StringName` 会变成 `String`、`Color` 变成字符串、节点/资源直接存不进去；
##   ② **整数会被读成浮点**（`1` → `1.0`）—— 这是 Godot 的 JSON 解析行为，不是本模块的。
## 容器**不会**替你把 payload 修回原类型：修它就得先认识它，而它是不透明的。
## 归一化请在游戏侧做（`int(payload["count"])`）。想连类型一起存，改用
## `var_to_str(grid.snapshot())` / `str_to_var(…)`。
func snapshot() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p in _items:
		out.append({
			"payload": p.payload,
			"anchor": [p.anchor.x, p.anchor.y],
			"base": [p.base_cells.x, p.base_cells.y],
			"rot": p.rot,
			"rotatable": p.rotatable,
		})
	return out


## 按快照逐块放回原位。返回空串 = 成功；非空 = 拒绝理由。
## ★ 全或无：先拿一个同样大小的空网格试摆，全部放得下才动真格 ——
##   "改了一半"的背包比不还原更坏。
## ★ 读档**不问 `accepts`**：存档里的东西本来就该待在它原来的格子里，
##   如果这期间规则改严了，读档时把它们扔掉才是灾难（要不要清理是游戏自己的迁移逻辑）。
func restore(data: Array) -> String:
	var probe := CellGrid.new(_size, finder)
	for e in data:
		if not (e is Dictionary):
			return "快照里有一条不是字典：%s" % str(e)
		var d := e as Dictionary
		var raw_base = d.get("base", d.get("cells", null))
		if raw_base == null:
			return "快照里有一条没写 base（占几格）：%s" % str(d)
		var base := _vec2_of(raw_base)
		if base.x <= 0 or base.y <= 0:
			return "快照里的 base 不合法：%s" % str(raw_base)
		var rotatable := bool(d.get("rotatable", false))
		var rot := int(d.get("rot", 0))
		var anchor := _vec2_of(d.get("anchor", null))
		var shape := GridShape.of(base, rotatable, rot)
		var why := probe.fits_at(shape, anchor)
		if why != "":
			return "%d×%d 放不回 %s：%s" % [shape.x, shape.y, str(anchor), why]
		probe._put_back(Placement.make(d.get("payload"), anchor, base, rotatable, rot))
	_items.clear()
	for p in probe._items:
		_put_back(p)
	_did_change()
	return ""


# ══ 内部 ═════════════════════════════════════════════

## 这块东西在这个方向下**实际**是什么形状（`rot < 0` = 两种都试）。
func _dirs(base: Vector2i, rotatable: bool, rot: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if rot >= 0:
		out.append(GridShape.of(base, rotatable, rot))
		return out
	out.append(base)
	if GridShape.can_rotate(base, rotatable):
		out.append(Vector2i(base.y, base.x))
	return out


## 这一格上实际会用哪个形状。空字典 = 一个方向都放不下。
func _landing(base: Vector2i, anchor: Vector2i, rotatable: bool, rot: int,
		ignore_index: int) -> Dictionary:
	for shape in _dirs(base, rotatable, rot):
		if fits_at(shape, anchor, ignore_index) == "":
			return {"cells": shape, "rot": GridShape.stored_rot(base, rotatable, rot, shape)}
	return {}


func _landing_reason(base: Vector2i, anchor: Vector2i, rotatable: bool, rot: int,
		ignore_index: int) -> String:
	var bad := ""
	for shape in _dirs(base, rotatable, rot):
		var why := fits_at(shape, anchor, ignore_index)
		if why == "":
			return ""
		if bad == "":
			bad = why
	return bad


## 自动放入失败时，给一句**能照着改主意**的理由。三种失败彼此不相干，
## 混成一句「放不下」会让调用方以为"多空几格就行"，而这三种里只有第二种是：
##
##   ① **网格本身就装不下这个尺寸** —— 跟空多少格毫无关系。
##      2×2 里放 1×3 时"还剩 3 格"听着像够，其实永远放不下（3 格连不成直线）；
##   ② **空位不够**：面积就不够，腾一腾还有救；
##   ③ **空位被隔碎**：面积够，但剩下的空位拼不出这个形状 —— 这才是重排能救的那种。
func _auto_reason(base: Vector2i, rotatable: bool) -> String:
	var shapes := _dirs(base, rotatable, -1)
	var roomy := false
	for s in shapes:
		if s.x <= _size.x and s.y <= _size.y:
			roomy = true
			break
	if not roomy:
		if shapes.size() > 1:
			var alt: Vector2i = shapes[1]
			return "网格只有 %d×%d：%d×%d 放不下，转过来 %d×%d 也不行" % [
				_size.x, _size.y, base.x, base.y, alt.x, alt.y]
		return "网格只有 %d×%d：放不下 %d×%d" % [_size.x, _size.y, base.x, base.y]
	var need := base.x * base.y
	if free_cells() < need:
		return "空位不够：%d×%d 要 %d 格，只剩 %d 格" % [
			base.x, base.y, need, free_cells()]
	return "还剩 %d 格空位，但拼不出 %d×%d（空位被隔碎了）" % [free_cells(), base.x, base.y]


## 自动找位：把判定包成 Callable 交给策略对象（策略因此不认识网格）。
func _find_spot(base: Vector2i, rotatable: bool, ignore_index: int) -> Dictionary:
	var ignore := ignore_index
	var fits := func(shape: Vector2i, anchor: Vector2i) -> bool:
		return fits_at(shape, anchor, ignore) == ""
	return finder.find(_size, base, rotatable, fits)


func _anywhere(base: Vector2i, rotatable: bool) -> Dictionary:
	return _find_spot(base, rotatable, -1)


func _merged_payload(incoming, existing) -> Variant:
	if not merge_rule.is_valid():
		return null
	return merge_rule.call(incoming, existing)


func _commit(p: Placement) -> Dictionary:
	_items.append(p)
	_did_change()
	return {"ok": true, "reason": "", "placement": p, "key": _items.size() - 1}

## 内部放回（不发信号）。只给已经校验过的路径用（还原 / 重排提交）。
func _put_back(p: Placement) -> void:
	_items.append(p)


## 内容相同的副本（干跑、换位判定的靶子）。
func _probe_copy() -> CellGrid:
	var c := CellGrid.new(_size, finder)
	c.accepts = accepts
	c.merge_rule = merge_rule
	for p in _items:
		c._put_back(p.copy())
	return c


func _probe_copy_without(ia: int, ib: int) -> CellGrid:
	var c := CellGrid.new(_size, finder)
	c.accepts = accepts
	c.merge_rule = merge_rule
	for i in _items.size():
		if i == ia or i == ib:
			continue
		c._put_back(_items[i].copy())
	return c


## 认 `Vector2i` / `Vector2` / `[x, y]` 三种写法。认不出来返回 `(-1, -1)`：
## 让 `fits_at()` 去拒绝，**不猜**一个"大概的位置"。
func _vec2_of(raw: Variant) -> Vector2i:
	if raw is Vector2i:
		return raw
	if raw is Vector2:
		return Vector2i(int((raw as Vector2).x), int((raw as Vector2).y))
	if raw is Array and (raw as Array).size() >= 2:
		return Vector2i(int((raw as Array)[0]), int((raw as Array)[1]))
	return Vector2i(-1, -1)


## 内容变了的广播。★ 发出点只有这一处 ⇒ 一个动作只会重绘一次。
func _did_change() -> void:
	changed.emit()


# ══ 返回值构造器（成功 / 失败**键集合相同**，见文件开头）════════════

static func _place_fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "placement": null, "key": -1}


static func _move_ok(moved: int) -> Dictionary:
	return {"ok": true, "reason": "", "moved": moved}


static func _move_fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "moved": 0}


static func _rot_fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "rot": -1}
