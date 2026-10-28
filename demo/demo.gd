extends Control
## 【**游戏侧** · 不属于容器模块】接入示例的宿主：建两个网格、画两块板、五个按钮。
##
## 这个文件里**没有一行网格规则** —— 它只做五件事：
##   ① 构造：`CellGrid.new(尺寸)` + 游戏侧的 `DemoItemCatalog` + 共享的 `DemoDragSession`；
##   ② 把游戏规则注入容器：`merge_rule`（怎么算同一种东西）、`accepts`（枪不许进背包）；
##   ③ 触发动作：`GridOps.move` / `GridOps.insert_fitting` / `GridRepacker.plan`；
##   ④ 显示结果：把 `res["reason"]` 直接贴到状态栏（错误信息是给玩家看的）；
##   ⑤ 存档：`snapshot()` → `JSON.stringify()` → `restore()`，全程不查物品表。
##
## ══ 一眼看清哪边是"容器"、哪边是"游戏" ═══════════════════
## 下面的代码里，凡是谈到**数量 / 上限 / 名字 / 颜色 / 去哪个容器**的，
## 全部落在 `DemoItemCatalog` / `DemoItemRules` 或这个文件里 —— 一行都没进 `scripts/`。
## 容器那边只见到"一块 m×n、能不能转、payload 原样带着"。
##
## 自动放入 / 搬运都有两档，**默认走便宜的那档**（不动已有块）：
##   · 放入：`grid.place_auto()`        → `GridOps.insert_fitting()`（放不下才重排）
##   · 搬运：`GridOps.move()`           → `GridOps.move_fitting()`（搬不动才重排目标）
## 拖拽落点只用便宜的那档：玩家盯着拖影松手时，东西不该自己重新排一遍。

var _catalog: DemoItemCatalog = null
var _bag: CellGrid = null
var _chest: CellGrid = null
var _bag_board: DemoGridBoard = null
var _chest_board: DemoGridBoard = null
var _session := DemoDragSession.new()
var _status: Label = null
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_install_font()

	_catalog = DemoItemCatalog.new()
	var err := _catalog.load_json("res://demo/items.json")

	# ★ 容器构造只给尺寸。没有物品表、没有数量概念。
	_bag = CellGrid.new(Vector2i(9, 4))
	_chest = CellGrid.new(Vector2i(6, 4))
	# 游戏规则注入之一：怎么算"能合并"是这一款游戏的事
	_bag.merge_rule = DemoItemRules.merge_hook(_catalog)
	_chest.merge_rule = DemoItemRules.merge_hook(_catalog)
	# 游戏规则注入之二：**背包不收长枪**（枪得放箱子）。
	# 容器只负责问一句「这个东西收吗」，不负责知道"枪"是什么 —— 也不负责写这句话的含义。
	# 想验证它在起作用：把箱子里的步枪拖回背包，会被拒绝并给出理由。
	_bag.accepts = func(payload) -> bool:
		return DemoItemRules.id_of(payload) != &"rifle"

	_build_ui()

	if err != "":
		_set_status("物品表载入有问题：\n" + err, false)
	else:
		_set_status("左键拖动 · 可以拖到另一块板上 · R 换方向 · 右键原地转", true)
	for i in 7:
		_pickup_one(true)


## 系统字体：Godot 自带字体没有中文字形，不装这个中文会变成空白。
func _install_font() -> void:
	var sys := SystemFont.new()
	sys.font_names = PackedStringArray([
		"Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC",
		"Noto Sans CJK SC", "Source Han Sans SC", "SimHei"])
	var t := Theme.new()
	t.default_font = sys
	t.default_font_size = 14
	theme = t


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.08, 0.10)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 20)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	margin.add_child(root)

	var head := Label.new()
	head.text = "容器系统 · 接入示例   容器：scripts/（只认 m×n 与位置）   游戏侧：demo/"
	head.add_theme_font_size_override("font_size", 16)
	root.add_child(head)

	var boards := HBoxContainer.new()
	boards.add_theme_constant_override("separation", 28)
	root.add_child(boards)

	# ★ 两块板拿到的是**同一个** session —— 这就是跨容器拖拽的全部机制
	_bag_board = DemoGridBoard.new()
	_bag_board.name = "BagBoard"
	_bag_board.setup(_bag, _catalog, "背包 9×4", _session)
	_bag_board.status.connect(_on_board_status)
	boards.add_child(_bag_board)

	_chest_board = DemoGridBoard.new()
	_chest_board.name = "ChestBoard"
	_chest_board.setup(_chest, _catalog, "箱子 6×4", _session)
	_chest_board.status.connect(_on_board_status)
	boards.add_child(_chest_board)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	root.add_child(buttons)
	buttons.add_child(_make_button("随机拾取", _on_pickup))
	buttons.add_child(_make_button("背包 → 箱子", _on_bag_to_chest))
	buttons.add_child(_make_button("箱子 → 背包", _on_chest_to_bag))
	buttons.add_child(_make_button("整理背包（重排）", _on_repack_bag))
	buttons.add_child(_make_button("存档", _on_save))
	buttons.add_child(_make_button("读档", _on_load))
	buttons.add_child(_make_button("清空箱子", _on_clear_chest))

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(0.0, 52.0)
	root.add_child(_status)


func _make_button(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(action)
	return b


# ══ 游戏规则（全都在这一侧）══════════════════════════════

## 拾取路由：这块东西该进哪个容器。**一行 if 就是全部** —— 容器不知道它存在。
func _stash_target(id: StringName) -> CellGrid:
	return _chest if id == &"rifle" else _bag


## 随机造一件"掉落物"（真实游戏里这一步是地上的掉落物）。
func _roll_drop() -> Dictionary:
	var ids := _catalog.ids()
	if ids.is_empty():
		return {}
	var id: StringName = ids[_rng.randi_range(0, ids.size() - 1)]
	var cap := _catalog.max_stack_of(id)
	var n := 1 if cap <= 1 else _rng.randi_range(1, mini(cap, 24))
	return {"id": id, "count": n}


# ══ 动作 ══════════════════════════════════════════════

## 拾取：路由到目标 → **按堆叠上限切成块** → 自动放入（放不下才重排）。
## 余量必须被报告出来 —— 真实游戏里这些该留在地上。
func _pickup_one(silent: bool) -> void:
	var drop := _roll_drop()
	if drop.is_empty():
		return
	var id: StringName = drop["id"]
	var n := int(drop["count"])
	var target := _stash_target(id)
	var blocks := DemoItemRules.blocks_of(_catalog, id, n)
	var res := GridOps.insert_fitting(target, blocks)

	var placed: int = int(res["placed"])
	var left_blocks: Array = res["left"]
	var left := 0
	for b in left_blocks:
		left += DemoItemRules.count_of((b as Dictionary).get("payload"))
	if silent:
		return

	var tail := ""
	if bool(res["repacked"]):
		tail = "（空位碎了，靠重排腾出来的；挪动了 %d 块）" % int(res["moves"])
	# ★ 别叫 `name`：`Node` 已经有 `name` 属性，局部变量会 SHADOWED_VARIABLE_BASE_CLASS
	var item_name := _catalog.name_of(id)
	if left == 0:
		_set_status("拾到 %s×%d → %d 块放进「%s」%s" % [
			item_name, n, placed, "箱子" if target == _chest else "背包", tail], true)
	else:
		_set_status("%s：进了 %d 个，%d 个没地方放（真实游戏里这些该留在地上）%s" % [
			item_name, n - left, left, tail], false)


## 纯整理：不加新东西，只把现有块重新排紧。
## 和拾取走的是同一段算法，区别只是"要不要多放几块"。
func _on_repack_bag() -> void:
	var plan := GridRepacker.plan(_bag)
	if not bool(plan["ok"]):
		_set_status("整理不了：%s" % str(plan["reason"]), false)
		return
	var err := _bag.restore(plan["layout"])
	if err != "":
		_set_status("整理失败（布局被否决，背包没变）：%s" % err, false)
		return
	_set_status("整理完成：%d 块里的 %d 块挪了位置（%s），占用 %d/%d 格" % [
		_bag.count(), int(plan["moves"]), str(plan["attempt"]),
		_bag.used_cells(), _bag.capacity()], true)


## 跨容器搬运（批量版）：两轮。
##   ① 先找**能直接搬**的那一块（不动目标里已有的块）—— 便宜、玩家看不出变化；
##   ② 一块都搬不动了，才让目标**重排**腾地方（`GridOps.move_fitting`），成了就回 ①。
##
## ★ 一件搬不动**不该挡住后面所有件**：所以是"从前往后找第一块搬得成的"，
##   不是"从第 0 块开始、失败就停"。上一版是后者，症状是「箱子里有个大件，
##   背包明明放得下小件，却一块都搬不过去」。
func _on_bag_to_chest() -> void:
	_move_all(_bag, _chest, "背包", "箱子")


func _on_chest_to_bag() -> void:
	_move_all(_chest, _bag, "箱子", "背包")


func _move_all(from: CellGrid, to: CellGrid, from_name: String, to_name: String) -> void:
	if from.is_empty():
		_set_status("「%s」里已经没东西了" % from_name, true)
		return
	var moved := 0
	var repacks := 0
	var guard := 0
	var reason := ""
	while not from.is_empty() and guard < 400:
		guard += 1
		var k := -1
		for i in from.count():
			if bool(GridOps.move(from, to, {"from": i})["ok"]):
				k = i
				break
		if k >= 0:
			moved += 1
			continue
		# 没有能直接搬的了 ⇒ 只为一个块重排；再不成就是真塞不下
		var fit := GridOps.move_fitting(from, to, {"from": 0})
		if not bool(fit["ok"]):
			reason = str(fit["reason"])
			break
		moved += 1
		if bool(fit.get("repacked", false)):
			repacks += 1

	var tail := "" if repacks == 0 else "（其中 %d 块是重排腾出来的地方）" % repacks
	if not from.is_empty():
		_set_status("搬了 %d 块从%s进%s，还剩 %d 块放不下%s：%s" % [
			moved, from_name, to_name, from.count(), tail, reason], false)
	else:
		_set_status("搬运完成：%d 块从%s进了%s%s" % [moved, from_name, to_name, tail], true)


## 取出（不是搬运）：`remove_at` 返回那一块，真实游戏里这里该生成掉落物。
func _on_clear_chest() -> void:
	var n := _chest.count()
	_chest.clear()          # ★ 一次 clear = 一次 changed，不是 N 次
	_set_status("箱子清空：%d 块（真实游戏里这一步应该生成地上的掉落物）" % n, true)


# ══ 存档 / 读档 ═══════════════════════════════════════

## 存成一段 **JSON 字符串**，刻意不存对象：这是"快照不需要物品表"的现场证明 ——
## `snapshot()` 把 `payload` 原样带上，`restore()` 原样还回来。
##
## ★ 代价写在这里而不是藏在文档里：走 JSON 就等于把 payload 过了一遍 JSON ——
##   ① `StringName` 变成 `String`；② **整数变成浮点**（`1` 读回来是 `1.0`，Godot 的 JSON 就是这样）。
##   容器不替 payload 改类型（改就等于解读它了），所以归一化是游戏侧的事：
##   `DemoItemRules.id_of()` 用 `StringName(str(…))`、`count_of()` 用 `int(…)`，
##   两个都吃 String / StringName / int / float 四种写法。
##   想要类型完全不变，就别走 JSON —— 用 `var_to_str()` / `str_to_var()` 存那一段快照。
var _slots_json := ""


func _on_save() -> void:
	_slots_json = JSON.stringify({"bag": _bag.snapshot(), "chest": _chest.snapshot()})
	_set_status("已存档：%d 字符（背包 + 箱子整个进了 JSON，一个物品表都没用）" % _slots_json.length(), true)


func _on_load() -> void:
	if _slots_json == "":
		_set_status("还没有存过档（先点「存档」）", false)
		return
	var parsed = JSON.parse_string(_slots_json)
	if not (parsed is Dictionary):
		_set_status("读档失败：这段 JSON 解析不出来", false)
		return
	var d := parsed as Dictionary
	# ★ 不要预检：`restore()` 本身就是全或无的（先拿副本试摆，全部放得下才落地）
	var e_bag := _bag.restore(d.get("bag", []))
	var e_chest := _chest.restore(d.get("chest", []))
	if e_bag != "" or e_chest != "":
		_set_status("读档失败：%s %s" % [e_bag, e_chest], false)
		return
	_set_status("已读档：背包 %d 块 / 箱子 %d 块（位置、方向、payload 全都是原样）" % [
		_bag.count(), _chest.count()], true)


# ══ 状态栏 ════════════════════════════════════════════

func _on_pickup() -> void:
	_pickup_one(false)


func _on_board_status(text: String, is_ok: bool) -> void:
	_set_status(text, is_ok)


func _set_status(text: String, is_ok: bool) -> void:
	if _status == null:
		return
	_status.text = text
	_status.add_theme_color_override("font_color",
		Color(0.66, 0.86, 0.70) if is_ok else Color(0.95, 0.55, 0.55))
