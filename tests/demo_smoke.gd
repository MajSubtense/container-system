extends SceneTree
## **demo 冒烟测试**：在真实场景里模拟跨容器拖拽，确认"视图 → GridOps"这段接线是通的。
##
## 为什么单独需要它：`run_tests.gd` 只测模型，测不到 demo 里"拿起 → 拖到另一块板 →
## 松手"这条路。这段接线断了的症状是"拖过去没反应"，而模型判据仍然全绿 ——
## 看起来像是模型的锅。所以这里用真实的 `demo.tscn`、真实的坐标换算跑一遍。
##
## 用法：`godot --headless --path . --script res://tests/demo_smoke.gd`
## 它访问 demo 的私有字段，改 demo 结构时要一起改 —— 这正是"冒烟"的含义。

var _fail := 0


func _initialize() -> void:
	_run()


func _check(ok: bool, what: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + what)
	if not ok:
		_fail += 1


## 游戏侧的"放进去"：按堆叠上限切块 → 自动放入（放不下才重排）。
func _stash(catalog: DemoItemCatalog, grid: CellGrid, id: StringName, n: int) -> Dictionary:
	return GridOps.insert_fitting(grid, DemoItemRules.blocks_of(catalog, id, n))


## 找一个空格（位置索引的典型用法：反过来问"哪一格是空的"）。
func _free_cell(grid: CellGrid) -> Vector2i:
	var g := grid.grid_size()
	for y in g.y:
		for x in g.x:
			if grid.key_at_cell(Vector2i(x, y)) < 0:
				return Vector2i(x, y)
	return Vector2i(-1, -1)


## 把网格内容压成一段可比较的文本 —— **按游戏侧的读法**压，不是按原始 Variant。
##
## ★ 为什么不直接 `JSON.stringify(snapshot())`：Godot 的 JSON 解析把整数读成**浮点**
##   （`{"count": 1}` 读回来是 `1.0`），于是"存档前后的原始 JSON 文本"必然不相等，
##   而这并不是数据错了 —— 是类型被 JSON 磨平了。容器不替 payload 做类型修复
##   （那就等于解读它了），归一化是游戏侧的事（`DemoItemRules.count_of()` 里的 `int()`）。
func _fingerprint(grid: CellGrid) -> String:
	var parts: Array[String] = []
	for p in grid.placements():
		parts.append("%s×%d@%d,%d/base%d,%d/rot%d" % [
			String(DemoItemRules.id_of(p.payload)), DemoItemRules.count_of(p.payload),
			p.anchor.x, p.anchor.y, p.base_cells.x, p.base_cells.y, p.rot])
	return "|".join(parts)


func _run() -> void:
	change_scene_to_file("res://demo/demo.tscn")
	await process_frame
	await process_frame

	var d = current_scene
	var catalog: DemoItemCatalog = d._catalog
	var bag: CellGrid = d._bag
	var chest: CellGrid = d._chest
	var bag_board = d._bag_board
	var chest_board = d._chest_board
	var session = d._session

	print("=== 场景 ===")
	print("背包 %d 块 / 箱子 %d 块" % [bag.count(), chest.count()])
	print("session.boards = %d 块" % session.boards.size())
	_check(session.boards.size() == 2, "两块板都注册进同一个 session")

	# ── 用例 1：背包 → 箱子（拖到箱子的第一个空格）
	var head: Placement = bag.placements()[0]
	var head_id := DemoItemRules.id_of(head.payload)
	var chest_before := chest.count()
	var slot := _free_cell(chest)
	_check(slot.x >= 0, "箱子里有空位可落：%s" % str(slot))
	var target = chest_board.global_position + chest_board.layout.cell_rect(slot).get_center()
	session.begin(bag_board, bag, 0, head.rot)
	session.mouse = target
	bag_board._drop_at(target)

	print("\n=== 用例 1：背包 → 箱子 ===")
	print("搬的是 %s（payload=%s）→ 箱子 %s" % [head_id, str(head.payload), str(slot)])
	_check(chest.count() == chest_before + 1, "箱子里多了 1 块 %s" % head_id)
	_check(not session.is_active(), "松手后 session 已清空")
	_check(d._status.text.contains("箱子"), "状态栏说明落点在箱子：%s" % d._status.text)

	# ── 用例 2：拖到所有容器外面
	var bag_n := bag.count()
	var chest_n := chest.count()
	session.begin(bag_board, bag, 0, bag.placements()[0].rot)
	var outside = Vector2(4.0, 4.0)
	session.mouse = outside
	bag_board._drop_at(outside)

	print("\n=== 用例 2：拖到容器外 ===")
	_check(bag.count() == bag_n, "背包块数不变")
	_check(chest.count() == chest_n, "箱子块数不变")
	_check(d._status.text.contains("外面"), "状态栏提示落在容器外：%s" % d._status.text)

	# ── 用例 3：落在箱子的标题栏上（不在格子里）
	bag_n = bag.count()
	session.begin(bag_board, bag, 0, bag.placements()[0].rot)
	var header_hit = chest_board.global_position + Vector2(20.0, 8.0)
	session.mouse = header_hit
	bag_board._drop_at(header_hit)

	print("\n=== 用例 3：落在标题栏 ===")
	_check(bag.count() == bag_n, "背包块数不变（没落进格子就不动）")
	_check(d._status.text.contains("格子里"), "状态栏提示落点不在格子里：%s" % d._status.text)

	# ── 用例 4：同容器内拖动（回归 —— 不该被跨容器改动弄坏）
	bag.clear()
	_stash(catalog, bag, &"gem", 1)               # 1×1，一定能放
	bag_n = bag.count()
	var first_anchor := bag.placements()[0].anchor
	session.begin(bag_board, bag, 0, bag.placements()[0].rot)
	var same_target = bag_board.global_position + bag_board.layout.cell_rect(Vector2i(8, 3)).get_center()
	session.mouse = same_target
	bag_board._drop_at(same_target)

	print("\n=== 用例 4：背包内拖动（回归）===")
	_check(bag.count() == bag_n, "块数不变")
	var moved_to := bag.placements()[0].anchor
	_check(moved_to == Vector2i(8, 3), "锚点从 %s 变到 %s" % [str(first_anchor), str(moved_to)])

	# ── 用例 4b：抓在块中间，只挪一格（回归：锚点曾被当成"鼠标格"）
	#    报上来的现象 —— 拖 2×3 的木箱，落点还在块范围内就弹回原位，一格都挪不动。
	#    两个根因叠在一起：
	#      ① 没有抓取偏移 ⇒ 锚点 = 鼠标所在格，整块凭空偏 (1,1)（跳位/越界被拒）；
	#      ② "同类堆已满"那句贴心话把**自己原来那块**当成挡路的（max_stack=1 必中）。
	print("\n=== 用例 4b：抓取偏移（只挪一格）===")
	bag.clear()
	_stash(catalog, bag, &"box", 1)               # 木箱 3×2，可转
	var crate: Placement = bag.placements()[0]
	var start := crate.anchor
	var cells := crate.cells
	print("木箱起点 %s，占 %s" % [str(start), str(cells)])

	var rect: Rect2 = bag_board.layout.block_rect(start, cells)
	var grip: Vector2 = bag_board.global_position + rect.get_center()
	var offset: Vector2 = grip - (bag_board.global_position + rect.position)
	_check(offset.length() > 1.0, "抓取点不在左上角（偏移 %.1f, %.1f）" % [offset.x, offset.y])

	var sx: float = bag_board.layout.step().x
	var sy: float = bag_board.layout.step().y

	# ① 向右挪一格
	session.begin(bag_board, bag, 0, crate.rot, offset)
	session.mouse = grip + Vector2(sx, 0.0)
	bag_board._drop_at(grip + Vector2(sx, 0.0))
	_check(bag.placements()[0].anchor == start + Vector2i(1, 0),
		"向右一格 ⇒ %s（期望 %s）· %s" % [str(bag.placements()[0].anchor),
			str(start + Vector2i(1, 0)), d._status.text])

	# ② 再向下挪一格（从新位置重新算抓取点）
	var now: Placement = bag.placements()[0]
	var rect2: Rect2 = bag_board.layout.block_rect(now.anchor, now.cells)
	var grip2: Vector2 = bag_board.global_position + rect2.get_center()
	session.begin(bag_board, bag, 0, now.rot, grip2 - (bag_board.global_position + rect2.position))
	session.mouse = grip2 + Vector2(0.0, sy)
	bag_board._drop_at(grip2 + Vector2(0.0, sy))
	_check(bag.placements()[0].anchor == start + Vector2i(1, 1),
		"再向下一格 ⇒ %s（期望 %s）· %s" % [str(bag.placements()[0].anchor),
			str(start + Vector2i(1, 1)), d._status.text])

	# ③ 鼠标不动 ⇒ 原地不动（预览与落点同源，不该自己滑走）
	var anchor_now := bag.placements()[0].anchor
	var rect3: Rect2 = bag_board.layout.block_rect(anchor_now, cells)
	var grip3: Vector2 = bag_board.global_position + rect3.get_center()
	session.begin(bag_board, bag, 0, now.rot, grip3 - (bag_board.global_position + rect3.position))
	session.mouse = grip3
	bag_board._drop_at(grip3)
	_check(bag.placements()[0].anchor == anchor_now,
		"原地松手不挪块（%s）· %s" % [str(bag.placements()[0].anchor), d._status.text])

	# ④ 拖到块会越界的位置 ⇒ 被拒，且块留在原处（不是"跳过去一半"）
	var bad := Vector2i(7, 1)                      # 3 宽：7+3 = 10 > 9，必越界
	var bad_offset := Vector2(sx * 0.5, sy * 0.5)
	var bad_corner: Vector2 = bag_board.global_position + bag_board.layout.cell_rect(bad).position
	session.begin(bag_board, bag, 0, now.rot, bad_offset)
	session.mouse = bad_corner + bad_offset
	bag_board._drop_at(bad_corner + bad_offset)
	_check(bag.placements()[0].anchor == anchor_now,
		"越界的落点被拒、块不动（%s）· %s" % [str(bag.placements()[0].anchor), d._status.text])
	_check(d._status.text.length() > 0, "给了拒绝理由：%s" % d._status.text)

	# ── 用例 5：箱子里只剩一格，拖一个 2×2 过来 → 应该被拒且两边都不变
	print("\n=== 用例 5：目标装不下 ===")
	chest.clear()
	_stash(catalog, chest, &"gem", 23)            # 6×4 = 24 格，只留 1 格
	_check(chest.free_cells() == 1, "箱子应该只剩 1 格（实际 %d）" % chest.free_cells())
	bag.clear()
	_stash(catalog, bag, &"medkit", 1)            # 2×2 药箱（不可转）
	bag_n = bag.count()
	chest_n = chest.count()
	var hole := _free_cell(chest)
	_check(hole.x >= 0, "唯一那个空格在 %s" % str(hole))
	session.begin(bag_board, bag, 0, bag.placements()[0].rot)
	var try_target = chest_board.global_position + chest_board.layout.cell_rect(hole).get_center()
	session.mouse = try_target
	bag_board._drop_at(try_target)
	_check(bag.count() == bag_n and chest.count() == chest_n,
		"装不下时两边都没变（背包 %d / 箱子 %d）" % [bag_n, chest_n])
	_check(d._status.text.length() > 0, "给了拒绝理由：%s" % d._status.text)

	# ── 用例 6：重排按钮（只是确认接线没断，算法本身由 run_tests 负责）
	print("\n=== 用例 6：整理按钮 ===")
	var before_cells := bag.used_cells()
	var before_count := bag.count()
	d._on_repack_bag()
	_check(bag.count() == before_count, "整理不会改变块数（%d）" % bag.count())
	_check(bag.used_cells() == before_cells, "整理不会改变占用格数（%d）" % bag.used_cells())
	_check(d._status.text.contains("整理"), "状态栏有反馈：%s" % d._status.text)

	# ── 用例 7：批量搬运走「搬不动就重排」（`_move_all` → `GridOps.move_fitting`）
	#    这是被报上来的那个场景：背包只剩 L 形 3 格，1×3 的钓竿"明明挪一下就能放下"。
	print("\n=== 用例 7：批量搬运（搬不动就重排）===")
	bag.clear()
	chest.clear()
	var peel := []
	for y in 4:
		for x in 9:
			if (x == 0 and y <= 1) or (x == 1 and y == 0):
				continue
			peel.append({"payload": {"id": &"pebble", "count": 1}, "anchor": [x, y],
				"base": [1, 1], "rot": 0, "rotatable": false})
	_check(bag.restore(peel) == "", "背包铺 33 个 1×1，只剩 L 形 3 格（%d）" % bag.free_cells())
	_stash(catalog, chest, &"rod", 1)
	_check(chest.count() == 1, "箱子里有 1×3 的钓竿")
	_check(not bool(GridOps.move(chest, bag, {"from": 0})["ok"]), "直接搬不动（空位被隔碎）")

	d._on_chest_to_bag()
	_check(chest.count() == 0, "钓竿搬过去了（箱子剩 %d 块）" % chest.count())
	_check(bag.count() == 34, "背包 34 块 = 33 + 钓竿（实际 %d）" % bag.count())
	_check(bag.used_cells() == 36, "36 格占满（实际 %d）" % bag.used_cells())
	_check(d._status.text.contains("重排"), "状态栏说明是靠重排腾的地方：%s" % d._status.text)

	# ── 用例 8：存档 / 读档（整段 JSON，全程不查物品表）
	print("\n=== 用例 8：存档 / 读档 ===")
	var bag_mark := _fingerprint(bag)
	var chest_mark := _fingerprint(chest)
	d._on_save()
	_check(String(d._slots_json).length() > 0, "存出一段 JSON（%d 字符）" % String(d._slots_json).length())
	bag.clear()
	chest.clear()
	_check(bag.count() == 0 and chest.count() == 0, "先清空两块板")
	d._on_load()
	_check(_fingerprint(bag) == bag_mark, "背包读回来逐块一致（位置 / 方向 / payload）")
	_check(_fingerprint(chest) == chest_mark, "箱子读回来逐块一致")
	_check(bag.count() + chest.count() > 0, "读回来的不是空板（%d + %d 块）" % [
		bag.count(), chest.count()])

	# ── 用例 9：注入的准入规则（背包不收长枪）—— 这是"游戏规则在容器外面"的活证据
	print("\n=== 用例 9：准入规则（枪不进背包）===")
	bag.clear()
	chest.clear()
	var rifle_blocks := DemoItemRules.blocks_of(catalog, &"rifle", 1)
	var into_bag := GridOps.insert_fitting(bag, rifle_blocks)
	_check(not bool(into_bag["ok"]), "背包拒绝长枪（%s）" % str(into_bag["reason"]))
	_check(str(into_bag["reason"]).contains("不接收"), "理由是准入规则给的：%s" % str(into_bag["reason"]))
	_check(bag.is_empty(), "背包一块都没进")
	_check(bool(GridOps.insert_fitting(chest, rifle_blocks)["ok"]), "箱子收得下同样的步枪")
	_check(chest.count() == 1, "箱子进了 1 块")
	_check(not bool(GridOps.move(chest, bag, {"from": 0})["ok"]), "从箱子拖回背包也被拒")
	_check(chest.count() == 1, "被拒时来源没动")
	bag.clear()
	chest.clear()

	print("\n=== 总计：%s ===" % ("全部通过" if _fail == 0 else "%d 项失败" % _fail))
	quit(0 if _fail == 0 else 1)
