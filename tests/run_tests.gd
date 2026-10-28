extends SceneTree
## 容器模块的 headless 判据。**不依赖任何测试插件**，直接跑：
##
##   godot --headless --path . --script res://tests/run_tests.gd
##
## 每一节对应一条不该被破坏的语义（数字就是设计笔记里的编号）。
## 11 组手写边界 + 2 组随机性质 + 1 组返回值契约（手写的边界用例照不到的组合由随机的兜住）。
##
## ★ 注意判据里**没有任何物品定义**：这个模块只认识"一块 m×n 的矩形 + 一个不透明
##   payload"。如果哪天这里有 `ItemDef` 之类的东西，说明分层又漏了。

var _pass := 0
var _fail := 0
var _section := ""


func _initialize() -> void:
	var t0 := Time.get_ticks_msec()
	print("═══ 容器系统判据 ═══")

	test_place_and_geometry()
	test_auto_fit_with_rotation()
	test_rotation_rules()
	test_failure_keeps_everything()
	test_remove_and_index_shift()
	test_move_within_semantics()
	test_position_index()
	test_snapshot_roundtrip()
	test_repack_offline_packing()
	test_payload_agnostic()
	test_layout_roundtrip()
	test_property_random_ops()
	test_property_repack()
	test_result_contract()

	var ms := Time.get_ticks_msec() - t0
	print("\n═══ %d 通过 / %d 失败（%d ms）═══" % [_pass, _fail, ms])
	quit(0 if _fail == 0 else 1)


# ══ 1. 放入与几何 ═════════════════════════════════════════

func test_place_and_geometry() -> void:
	_section = "1 放入与几何"
	_begin(_section)
	var g := CellGrid.new(Vector2i(4, 4))
	_eq(g.capacity(), 16, "容量 = 格数")
	_eq(g.count(), 0, "空网格 0 块")

	var r1 := g.place_auto("a", Vector2i(2, 2))
	_check(bool(r1["ok"]), "第一个 2×2 应该放得下（%s）" % str(r1["reason"]))
	_eq(int(r1["key"]), 0, "第一块的键是 0")
	_eq(g.placements()[0].anchor, Vector2i(0, 0), "首适配落在左上角")
	_eq(g.placements()[0].cells, Vector2i(2, 2), "占位形状 2×2")
	_eq(g.placements()[0].rot, 0, "正放的方向是 0")

	g.place_auto("b", Vector2i(2, 2))
	_eq(g.placements()[1].anchor, Vector2i(2, 0), "行优先：第二块落在 (2,0)")
	_eq(g.count(), 2, "两块")
	_eq(g.used_cells(), 8, "占 8 格")
	_eq(g.free_cells(), 8, "还剩 8 格")
	_check(not g.is_empty(), "不空")

	# 形状与方向必须自洽（`cells` 由 base + rotatable + rot 推出来）
	for p in g.placements():
		_eq(p.cells, GridShape.of(p.base_cells, p.rotatable, p.rot),
			"cells 必须与 base/rot 自洽（%s）" % str(p))

	# 越界与重叠都要被说出理由
	_check(g.can_place_at("c", Vector2i(3, 3), Vector2i(2, 1)) != "", "越界要被拒绝")
	_check(g.can_place_at("c", Vector2i(1, 1), Vector2i(2, 2)) != "", "重叠要被拒绝")
	_eq(g.can_place_at("c", Vector2i(-1, -1), Vector2i(2, 2)), "",
		"x < 0 的锚点 = 问「随便哪儿都行吗」，这儿还有空 ⇒ 空串（可以）")

	# 1×1 只占一格，但仍是**一块**（不是"1 个数量"）
	var g2 := CellGrid.new(Vector2i(4, 2))
	g2.place_auto("tiny", Vector2i(1, 1))
	_eq(g2.used_cells(), 1, "1×1 占 1 格")
	_eq(g2.count(), 1, "1×1 是 1 块")


# ══ 2. 自动放入 + 旋转兜底 ═════════════════════════════════

func test_auto_fit_with_rotation() -> void:
	_section = "2 自动放入 + 旋转兜底"
	_begin(_section)

	# 1 列 4 行里放一块 4×1：横着放不下 ⇒ 自动转成 1×4
	var g := CellGrid.new(Vector2i(1, 4))
	var r := g.place_auto("rug", Vector2i(4, 1), true)
	_check(bool(r["ok"]), "横着放不下但能转，应该成功（%s）" % str(r["reason"]))
	_eq(g.placements()[0].cells, Vector2i(1, 4), "转过来了：1×4")
	_eq(g.placements()[0].rot, 90, "方向记成 90")
	_eq(g.placements()[0].base_cells, Vector2i(4, 1), "基准形状仍是 4×1（不会漂）")

	# 同形状但**不许转** ⇒ 老实失败
	var g2 := CellGrid.new(Vector2i(1, 4))
	var r2 := g2.place_auto("plank", Vector2i(4, 1), false)
	_check(not bool(r2["ok"]), "rotatable=false ⇒ 不许自作主张转")
	_check(str(r2["reason"]).contains("网格只有"),
		"理由要先报网格尺寸（这块转不了，跟空几格无关）：%s" % str(r2["reason"]))

	# ★「面积够 ≠ 放得下」的最小例子，也是被报上来的那个场景：
	#   2×2 里只剩 3 格、但呈 L 形，1×3 永远放不进 —— 三种失败原因必须分得开。
	var g5 := CellGrid.new(Vector2i(2, 2))
	g5.place_at("x", Vector2i(1, 1), Vector2i.ONE)
	_eq(g5.free_cells(), 3, "空着 3 格")
	var r5 := g5.place_auto("rod", Vector2i(1, 3), true)
	_check(not bool(r5["ok"]), "2×2 里放 1×3：面积 3 = 3 也不行")
	_check(str(r5["reason"]).contains("网格只有 2×2"),
		"理由要说清是**网格装不下这个尺寸**，不是空位不够：%s" % str(r5["reason"]))
	# 穷举确认这不是找位算法漏了：所有锚点 × 两个方向都无解
	var any_spot := false
	for span in [0, 90]:
		var shape := GridShape.of(Vector2i(1, 3), true, span)
		for y in 2:
			for x in 2:
				if g5.fits_at(shape, Vector2i(x, y)) == "":
					any_spot = true
	_check(not any_spot, "穷举所有锚点与方向：2×2 里真的凑不出 3 连")

	# 正放优先：3×3 里放 2×1 可转的块，应该正放而不是先转
	var g3 := CellGrid.new(Vector2i(3, 3))
	g3.place_auto("x", Vector2i(2, 1), true)
	_eq(g3.placements()[0].cells, Vector2i(2, 1), "正放优先于旋转（不是每个锚点都试两个方向）")

	# room_for 与 place_auto 同源：说还能放 4 块，就真能放 4 块
	var g4 := CellGrid.new(Vector2i(2, 2))
	_eq(g4.room_for(Vector2i(1, 1)), 4, "2×2 里能放 4 个 1×1")
	for i in 4:
		_check(bool(g4.place_auto(i, Vector2i(1, 1))["ok"]), "第 %d 个 1×1 放得下" % (i + 1))
	_eq(g4.room_for(Vector2i(1, 1)), 0, "放满之后一块都放不下了")


# ══ 3. 旋转规则 ═════════════════════════════════════════

func test_rotation_rules() -> void:
	_section = "3 旋转规则"
	_begin(_section)

	# 方的转不转一个样
	var g := CellGrid.new(Vector2i(4, 4))
	g.place_auto("sq", Vector2i(2, 2), true)
	_check(g.rotate_problem(0).contains("方的"), "方的东西不提供方向")
	_check(not bool(g.rotate(0)["ok"]), "方的东西转不动")

	# 固定方向的转不动
	var g2 := CellGrid.new(Vector2i(4, 4))
	g2.place_auto("fx", Vector2i(1, 2), false)
	_check(g2.rotate_problem(0).contains("固定方向"), "rotatable=false 拒绝旋转")

	# 转不开就拒绝（4×2 里一根 4×1 转过来需要 4 行）
	var g3 := CellGrid.new(Vector2i(4, 2))
	g3.place_auto("bar", Vector2i(4, 1), true)
	_eq(g3.placements()[0].cells, Vector2i(4, 1), "先正放")
	_check(g3.rotate_problem(0).contains("放不下"), "转不开要说理由是放不下")
	var before := g3.snapshot()
	_check(not bool(g3.rotate(0)["ok"]), "转不开 ⇒ 拒绝")
	_eq(g3.snapshot(), before, "拒绝时一格不动")

	# 转得开就真的转
	var g4 := CellGrid.new(Vector2i(4, 4))
	g4.place_auto("bar", Vector2i(4, 1), true)
	_check(bool(g4.rotate(0)["ok"]), "4×4 里转得开")
	_eq(g4.placements()[0].cells, Vector2i(1, 4), "形状变成 1×4")
	_eq(g4.placements()[0].rot, 90, "方向 90")
	_check(bool(g4.rotate(0)["ok"]), "再转一次回来")
	_eq(g4.placements()[0].cells, Vector2i(4, 1), "回到 4×1")
	_eq(g4.placements()[0].rot, 0, "方向回到 0")


# ══ 4. 失败不变式 ═══════════════════════════════════════

func test_failure_keeps_everything() -> void:
	_section = "4 失败不变式"
	_begin(_section)
	var g := CellGrid.new(Vector2i(3, 3))
	g.place_auto("big", Vector2i(2, 2))
	var before := g.snapshot()

	var r := g.place_at("other", Vector2i(1, 1), Vector2i(2, 2))
	_check(not bool(r["ok"]), "重叠 ⇒ 拒绝")
	_eq(g.snapshot(), before, "拒绝时网格一格不动")

	var r2 := g.place_auto("wide", Vector2i(3, 2))
	_check(not bool(r2["ok"]), "剩 5 格放不下 6 格的东西")
	_eq(g.count(), 1, "件数没变")

	# 点名方向却放不下 ⇒ 拒绝，不偷偷换个方向
	var g2 := CellGrid.new(Vector2i(3, 1))
	var r3 := g2.place_at("bar", Vector2i(0, 0), Vector2i(2, 1), true, 90)
	_check(not bool(r3["ok"]), "点名 90° 但放不下 ⇒ 拒绝（不偷偷改回正放）")
	_eq(g2.count(), 0, "什么都没放进去")


# ══ 5. 取出与下标前移 ═══════════════════════════════════

func test_remove_and_index_shift() -> void:
	_section = "5 取出与下标前移"
	_begin(_section)
	var g := CellGrid.new(Vector2i(3, 3))
	g.place_auto("a", Vector2i(3, 1))       # @(0,0)
	g.place_auto("b", Vector2i(1, 1))       # @(0,1)
	g.place_auto("c", Vector2i(1, 1))       # @(1,1)
	_eq(g.count(), 3, "三块")

	var piece := g.remove_at(0)
	_check(piece != null and piece.payload == "a", "取出来的应该是 a")
	_eq(g.count(), 2, "取走之后少一条")
	_eq(g.placements()[0].anchor, Vector2i(0, 1), "下标前移：原第 2 块变成第 1 块")
	_eq(g.remove_at(99), null, "越界的键取不到东西")
	_eq(g.remove_at(-1), null, "负数键也取不到")


# ══ 6. 格间搬运三语义 ═══════════════════════════════════

func test_move_within_semantics() -> void:
	_section = "6 格间搬运"
	_begin(_section)

	# ① 目标没点名 ⇒ 搬到第一块放得下的空地（要忽略自己）
	var g := CellGrid.new(Vector2i(3, 2))
	g.place_at("a", Vector2i(0, 0), Vector2i(1, 1))
	g.place_at("b", Vector2i(2, 1), Vector2i(1, 1))
	var m := g.move_within(1)
	_check(bool(m["ok"]), "空地搬运应该成功（%s）" % str(m["reason"]))
	_eq(g.placements()[1].anchor, Vector2i(1, 0), "搬到第一个空位 (1,0)")

	# ② 合并：靠注入的 merge_rule（容器只问、不算）
	var g2 := CellGrid.new(Vector2i(3, 2))
	g2.merge_rule = func(a, b) -> Variant: return int(a) + int(b)
	g2.place_at(3, Vector2i(0, 0), Vector2i(1, 1))
	g2.place_at(4, Vector2i(1, 0), Vector2i(1, 1))
	var m2 := g2.move_within(1, 0)
	_check(bool(m2["ok"]), "合并应该成功")
	_eq(g2.count(), 1, "塌成一块")
	_eq(g2.placements()[0].payload, 7, "合并后的 payload 由**外面的规则**算出来（3+4=7）")
	_eq(g2.placements()[0].anchor, Vector2i(0, 0), "合并沿用目标的位置")

	# ③ 不能合并 ⇒ 整块换位
	var g3 := CellGrid.new(Vector2i(4, 2))
	g3.place_at("bar", Vector2i(0, 0), Vector2i(2, 1))
	g3.place_at("box", Vector2i(2, 0), Vector2i(2, 2))
	var m3 := g3.move_within(0, 1)
	_check(bool(m3["ok"]), "换位应该成功（%s）" % str(m3["reason"]))
	_eq(g3.placements()[0].anchor, Vector2i(2, 0), "bar 换到 box 的锚点")
	_eq(g3.placements()[1].anchor, Vector2i(0, 0), "box 换到 bar 的锚点")

	# 换位放不下 ⇒ 两边都不动
	var g4 := CellGrid.new(Vector2i(4, 1))
	g4.place_at("wide", Vector2i(0, 0), Vector2i(3, 1))
	g4.place_at("tiny", Vector2i(3, 0), Vector2i(1, 1))
	var before := g4.snapshot()
	var m4 := g4.move_within(0, 1)
	_check(not bool(m4["ok"]), "3×1 换到最后一格会越界 ⇒ 拒绝")
	_eq(g4.snapshot(), before, "拒绝时两块都在原位")

	# 拖到自己那一块 = 成功、0 块
	var m5 := g4.move_within(0, 0)
	_check(bool(m5["ok"]) and int(m5["moved"]) == 0, "拖回自己 = 成功、0 块")
	# 把占满整块网格的东西挪一挪：必须忽略自己才可能成功
	var g5 := CellGrid.new(Vector2i(2, 2))
	g5.place_auto("full", Vector2i(2, 2))
	_check(bool(g5.move_within(0)["ok"]), "占满整格的东西挪一挪 = 成功（原地）")


# ══ 7. 位置索引 ═════════════════════════════════════════

func test_position_index() -> void:
	_section = "7 位置索引"
	_begin(_section)
	var g := CellGrid.new(Vector2i(4, 4))
	g.place_at("a", Vector2i(1, 1), Vector2i(2, 2))
	g.place_at("b", Vector2i(0, 3), Vector2i(3, 1))

	# 格 → 第几块（界面拿它做命中测试，不必自己拼建索引）
	_eq(g.key_at_cell(Vector2i(1, 1)), 0, "(1,1) 属于第 0 块")
	_eq(g.key_at_cell(Vector2i(2, 2)), 0, "(2,2) 属于第 0 块")
	_eq(g.key_at_cell(Vector2i(0, 3)), 1, "(0,3) 属于第 1 块")
	_eq(g.key_at_cell(Vector2i(0, 0)), -1, "空格返回 -1")
	_eq(g.key_at_cell(Vector2i(9, 9)), -1, "网格外的格也返回 -1")
	_check(g.at_cell(Vector2i(2, 2)) != null, "at_cell 直接给那一块")
	_eq(g.at_cell(Vector2i(0, 0)), null, "空格给 null")

	# cells_of 展开的格数必须等于面积，且并集正好是占用的格（不多不少、不重复）
	var seen := {}
	var sum := 0
	for i in g.count():
		for cell in g.cells_of(i):
			_check(not seen.has(cell), "格 %s 被两块同时占用" % str(cell))
			seen[cell] = i
			sum += 1
	_eq(sum, g.used_cells(), "cells_of 并集大小 == used_cells")
	_eq(seen.size(), g.used_cells(), "没有重复格")
	_eq(g.cells_of(99).size(), 0, "越界的键给空数组")

	# 索引是**查询**不是第二份数据：搬动之后立刻一致
	g.move_to_cell(0, Vector2i(0, 0))
	_eq(g.key_at_cell(Vector2i(0, 0)), 0, "搬动之后位置索引立刻跟上")
	_eq(g.key_at_cell(Vector2i(2, 2)), -1, "原来的格子空出来了")


# ══ 8. 存读档（不需要物品表）══════════════════════════════

func test_snapshot_roundtrip() -> void:
	_section = "8 存读档"
	_begin(_section)
	var g := CellGrid.new(Vector2i(4, 3))
	g.place_at({"id": "wood", "count": 25}, Vector2i(0, 0), Vector2i(1, 2), true, 0)
	g.place_at({"id": "box", "count": 1}, Vector2i(2, 1), Vector2i(2, 2))
	var snap := g.snapshot()
	_eq(snap.size(), 2, "两块")

	# ★ 读档不需要任何物品目录：payload 原样带回来
	var g2 := CellGrid.new(Vector2i(4, 3))
	_eq(g2.restore(snap), "", "还原成功")
	_eq(g2.snapshot(), snap, "还原后快照一模一样（含 payload）")
	_eq(g2.placements()[0].payload, {"id": "wood", "count": 25}, "payload 是原样还回来的")
	_eq(g2.placements()[0].cells, Vector2i(1, 2), "方向也还回来了")

	# 走一遍 JSON（anchor / base 用数组就是为了这一步）
	var text := JSON.stringify(snap)
	var parsed = JSON.parse_string(text)
	var g3 := CellGrid.new(Vector2i(4, 3))
	_eq(g3.restore(parsed), "", "从 JSON 也能还原")
	_eq(g3.count(), 2, "两块都在")
	_eq(g3.placements()[0].base_cells, Vector2i(1, 2), "形状从 JSON 读回来")
	_eq(String(g3.placements()[0].payload["id"]), "wood", "payload 从 JSON 读回来")

	# 坏快照：全或无，网格一个字都不改
	var g4 := CellGrid.new(Vector2i(2, 2))
	g4.place_auto("keep", Vector2i(2, 2))
	var before := g4.snapshot()
	var bad := [
		{"payload": "x", "anchor": [0, 0], "base": [2, 2], "rot": 0, "rotatable": false},
		{"payload": "y", "anchor": [1, 1], "base": [2, 2], "rot": 0, "rotatable": false},
	]
	_check(g4.restore(bad) != "", "重叠的快照要被拒绝")
	_eq(g4.snapshot(), before, "被拒绝时原内容一字未动")
	_check(g4.restore([{"payload": "z"}]) != "", "缺 base 的要被拒绝（不猜占几格）")


# ══ 9. 重排装箱（允许挪动已有块）═══════════════════════════

func test_repack_offline_packing() -> void:
	_section = "9 重排（装不下就腾地方）"
	_begin(_section)

	# ① 在线切碎 vs 离线重排：3×3 里两条竖 1×2 占了 x=0/x=1 的两列，
	#    2×2 怎么都塞不进（面积其实够 8/9）。
	var g := CellGrid.new(Vector2i(3, 3))
	g.place_auto("v", Vector2i(1, 2), true)     # @(0,0)
	g.place_auto("v", Vector2i(1, 2), true)     # @(1,0)
	_eq(g.placements()[0].anchor, Vector2i(0, 0), "第一条竖条在 (0,0)")
	_eq(g.placements()[1].anchor, Vector2i(1, 0), "第二条竖条在 (1,0)")
	_check(not bool(g.place_auto("sq", Vector2i(2, 2))["ok"]), "在线放法：2×2 放不进")

	var before := g.snapshot()
	var incoming := [_block("sq", Vector2i(2, 2))]
	var plan := GridRepacker.plan(g, incoming)
	_check(bool(plan["ok"]), "重排应该找得到解（%s）" % str(plan.get("reason", "")))
	_eq(g.snapshot(), before, "plan() 是只读的，网格必须一字未动")
	_check(int(plan["moves"]) >= 1, "至少挪动了一块（实际 %d）" % int(plan["moves"]))
	_check(str(plan["attempt"]) != "", "要说清是哪一轮成功的：%s" % str(plan["attempt"]))

	_eq(g.restore(plan["layout"]), "", "布局能提交")
	_eq(g.count(), 3, "三块都在")
	_check(g.used_cells() == 8, "4+2+2=8 格（实际 %d）" % g.used_cells())
	_check_invariants(g, 3, "重排后")

	# ② insert_fitting：放得下时**绝不打扰已有布局**
	var g2 := CellGrid.new(Vector2i(4, 2))
	g2.place_auto("a", Vector2i(1, 1))
	var anchor_before := g2.placements()[0].anchor
	var r1 := GridOps.insert_fitting(g2, [_block("b", Vector2i(1, 1))])
	_check(bool(r1["ok"]), "直接放得下就该成功")
	_eq(bool(r1["repacked"]), false, "没重排过")
	_eq(int(r1["moves"]), 0, "一块都没挪")
	_eq(g2.placements()[0].anchor, anchor_before, "已有那块原地不动")

	# ③ insert_fitting：放不下 → 走重排，并且真的放下了
	var g3 := CellGrid.new(Vector2i(3, 3))
	g3.place_auto("v", Vector2i(1, 2), true)
	g3.place_auto("v", Vector2i(1, 2), true)
	var r2 := GridOps.insert_fitting(g3, [_block("sq", Vector2i(2, 2))])
	_check(bool(r2["ok"]), "重排后应该放得下")
	_eq(bool(r2["repacked"]), true, "标记为重排")
	_check(int(r2["moves"]) >= 1, "报告挪动块数（%d）" % int(r2["moves"]))
	_eq(g3.count(), 3, "三块都在（含新放进去的）")
	_check_invariants(g3, 3, "insert_fitting 重排后")

	# ④ 面积下界：先挡掉，别跑满 8 轮才失败
	var g4 := CellGrid.new(Vector2i(2, 2))
	g4.place_auto("full", Vector2i(2, 2))
	var p2 := GridRepacker.plan(g4, [_block("x", Vector2i(2, 2))])
	_eq(bool(p2["ok"]), false, "8 格塞进 4 格必须失败")
	_eq(int(p2["tried"]), 0, "面积下界先挡掉，一轮都没跑")
	_check(str(p2["reason"]).contains("面积"), "理由说的是面积不够：%s" % str(p2["reason"]))

	# ⑤ 面积够 ≠ 装得下：9 个 2×2 塞 9×4（36 格正好，但 9 列奇数铺不满）
	var w := CellGrid.new(Vector2i(9, 4))
	for y in 2:
		for x in 4:
			w.place_at("b", Vector2i(x * 2, y * 2), Vector2i(2, 2))
	_eq(w.used_cells(), 32, "先铺 32 格")
	var wbefore := w.snapshot()
	var p3 := GridRepacker.plan(w, [_block("b", Vector2i(2, 2))])
	_eq(bool(p3["ok"]), false, "面积正好 36 但铺不满，必须失败")
	_eq(int(p3["tried"]), 8, "8 轮全跑完了才认输")
	_check(str(p3["reason"]).contains("形状"), "理由要区分「面积不够」和「形状凑不出」：%s" % str(p3["reason"]))
	_eq(w.snapshot(), wbefore, "失败时网格一字未动")

	# ⑥ 装不下时余量照实报，绝不吞
	var g5 := CellGrid.new(Vector2i(2, 2))
	g5.place_auto("full", Vector2i(2, 2))
	var r3 := GridOps.insert_fitting(g5, [_block("x", Vector2i(2, 2))])
	_eq(bool(r3["ok"]), false, "放不下就是放不下")
	_eq((r3["left"] as Array).size(), 1, "没放下的那块要原样还回来")

	# ⑦ 只整理：不给新块也能跑
	var g6 := CellGrid.new(Vector2i(4, 4))
	g6.place_at("a", Vector2i(0, 0), Vector2i(2, 2))
	g6.place_at("b", Vector2i(2, 0), Vector2i(2, 2))
	var p4 := GridRepacker.plan(g6)
	_check(bool(p4["ok"]), "只整理现有块也要能算出布局")
	_eq((p4["layout"] as Array).size(), 2, "整理不会凭空多出一块")

	# ══ 搬不动就重排：`move_fitting()` ══════════════════════

	# ⑧ 直接搬得成时**绝不打扰目标里已有的块**
	var m1_from := CellGrid.new(Vector2i(2, 2))
	m1_from.place_at("rod", Vector2i(0, 0), Vector2i(1, 2), true)
	m1_from.place_at("box", Vector2i(1, 0), Vector2i(1, 2), true)
	var m1_to := CellGrid.new(Vector2i(4, 2))
	m1_to.place_at("keep", Vector2i(0, 0), Vector2i(1, 1))
	var keep_anchor := m1_to.placements()[0].anchor
	var m1 := GridOps.move_fitting(m1_from, m1_to, {"from": 0})
	_check(bool(m1["ok"]), "搬得成（%s）" % str(m1["reason"]))
	_eq(bool(m1["repacked"]), false, "没重排")
	_eq(int(m1["moves"]), 0, "一块都没挪")
	_eq(m1_to.placements()[0].anchor, keep_anchor, "目标里原有的块原地不动")
	_eq(m1_from.count(), 1, "来源少了一块")

	# ⑨ L 形空位：`move()` 失败，`move_fitting()` 靠重排搬成
	#    9×4 铺满 33 个 1×1，只在左上留 3 格且呈 L 形
	var m2_to := CellGrid.new(Vector2i(9, 4))
	var full := []
	for y in 4:
		for x in 9:
			if (x == 0 and y <= 1) or (x == 1 and y == 0):
				continue
			full.append({"payload": "pebble", "anchor": [x, y], "base": [1, 1],
				"rot": 0, "rotatable": false})
	_eq(m2_to.restore(full), "", "先铺 33 个 1×1")
	_eq(m2_to.free_cells(), 3, "只剩 3 格，且呈 L 形")

	var m2_from := CellGrid.new(Vector2i(3, 1))
	m2_from.place_at("rod", Vector2i(0, 0), Vector2i(1, 3), true)
	var direct := GridOps.move(m2_from, m2_to, {"from": 0})
	_check(not bool(direct["ok"]), "空位是碎的 ⇒ 直接搬不动（%s）" % str(direct["reason"]))
	_check(str(direct["reason"]).contains("隔碎"),
		"理由要说是空位被隔碎（这才是重排能救的那种）：%s" % str(direct["reason"]))
	_eq(m2_to.count(), 33, "失败的判定不改目标")

	var m2 := GridOps.move_fitting(m2_from, m2_to, {"from": 0})
	_check(bool(m2["ok"]), "重排后应该搬得成（%s）" % str(m2["reason"]))
	_eq(bool(m2["repacked"]), true, "标记为靠重排")
	_check(int(m2["moves"]) >= 1, "报告挪动块数（%d）" % int(m2["moves"]))
	_eq(m2_from.count(), 0, "来源空了")
	_eq(m2_to.count(), 34, "目标多了一块")
	_eq(m2_to.used_cells(), 36, "36 格全占满")
	_check_invariants(m2_to, 34, "move_fitting 重排后")

	# ⑩ 点名了落点 ⇒ 不重排（玩家已经指着那一格说"放这儿"）
	var m3_to := CellGrid.new(Vector2i(9, 4))
	m3_to.restore(full)
	var m3_from := CellGrid.new(Vector2i(3, 1))
	m3_from.place_at("rod", Vector2i(0, 0), Vector2i(1, 3), true)
	var m3 := GridOps.move_fitting(m3_from, m3_to, {"from": 0, "cell": Vector2i(5, 2)})
	_check(not bool(m3["ok"]), "点名的格子被占 ⇒ 拒绝，不偷偷洗牌")
	_eq(bool(m3["repacked"]), false, "没重排")
	_eq(m3_from.count(), 1, "来源没动")
	_eq(m3_to.count(), 33, "目标没动")

	# ⑪ 目标真的装不下 ⇒ 两边都不变，理由同时说清"网格太小"和"重排也不行"
	var m4_to := CellGrid.new(Vector2i(2, 2))
	m4_to.place_at("x", Vector2i(1, 1), Vector2i.ONE)
	var m4_from := CellGrid.new(Vector2i(3, 1))
	m4_from.place_at("rod", Vector2i(0, 0), Vector2i(1, 3), true)
	var m4 := GridOps.move_fitting(m4_from, m4_to, {"from": 0})
	_check(not bool(m4["ok"]), "2×2 里 1×3 怎么排都放不下")
	_check(str(m4["reason"]).contains("网格只有 2×2"), "理由先报尺寸：%s" % str(m4["reason"]))
	_check(str(m4["reason"]).contains("重排也"), "再报重排也救不了：%s" % str(m4["reason"]))
	_eq(m4_from.count(), 1, "来源没动（没有静默吞掉）")
	_eq(m4_to.count(), 1, "目标没动")


# ══ 10. payload 不透明（解耦判据）══════════════════════════

## 这一节是分层的证据：容器对 payload **一无所知**，游戏规则全部从外面注入。
func test_payload_agnostic() -> void:
	_section = "10 payload 不透明"
	_begin(_section)

	# ① 任意 Variant 都能当 payload
	var g := CellGrid.new(Vector2i(3, 3))
	var samples := [null, 7, "text", [1, 2, 3], {"deep": {"x": 1}}, true]
	for i in samples.size():
		var r := g.place_auto(samples[i], Vector2i(1, 1))
		_check(bool(r["ok"]), "第 %d 种 payload（%s）应该能放" % [i, str(samples[i])])
	_eq(g.count(), samples.size(), "全部放进去")
	for i in samples.size():
		_eq(g.placements()[i].payload, samples[i], "payload 原样留着（第 %d 个）" % i)

	# ② 同一份代码，注入不同规则 ⇒ 不同行为（证明规则在容器外面）
	var merge_sum := CellGrid.new(Vector2i(3, 1))
	merge_sum.merge_rule = func(a, b) -> Variant: return int(a) + int(b)
	merge_sum.place_at(3, Vector2i(0, 0), Vector2i(1, 1))
	merge_sum.place_at(4, Vector2i(1, 0), Vector2i(1, 1))
	merge_sum.move_within(1, 0)
	_eq(merge_sum.count(), 1, "有合并规则 ⇒ 塌成一块")

	var no_rule := CellGrid.new(Vector2i(3, 1))
	no_rule.place_at(3, Vector2i(0, 0), Vector2i(1, 1))
	no_rule.place_at(4, Vector2i(1, 0), Vector2i(1, 1))
	no_rule.move_within(1, 0)
	_eq(no_rule.count(), 2, "没有合并规则 ⇒ 走换位，仍是两块")
	# 换位是**交换锚点**、不重排数组 ⇒ 键不动（键是下标，会漂的键不能当地址用）
	_eq(no_rule.placements()[0].payload, 3, "第 0 块还是原来那一块（键没漂）")
	_eq(no_rule.placements()[0].anchor, Vector2i(1, 0), "它换到了对方的锚点")
	_eq(no_rule.placements()[1].payload, 4, "第 1 块也是原来那一块")
	_eq(no_rule.placements()[1].anchor, Vector2i(0, 0), "它也换到了对方的锚点")

	# ③ 准入规则也是注入的
	var strict := CellGrid.new(Vector2i(3, 3))
	strict.accepts = func(p) -> bool: return p != &"rifle"
	_check(not bool(strict.place_auto(&"rifle", Vector2i(1, 1))["ok"]), "准入规则能拒绝")
	_check(bool(strict.place_auto(&"bread", Vector2i(1, 1))["ok"]), "别的东西照收")
	_check(not strict.admits(&"rifle") and strict.admits(&"bread"), "admits() 给出同一答案")

	# ③b 准入规则**不能被重排绕过**。
	#     这条曾经是真 bug：`restore()` 刻意不问准入（读档不该问），而两条重排路径
	#     都借道 `restore()` 提交布局 ⇒ "放不下就重排"变成了把被拒的东西塞进去的后门。
	var gate := CellGrid.new(Vector2i(3, 3))
	gate.accepts = func(p) -> bool: return p != &"rifle"
	var r_gate := GridOps.insert_fitting(gate, [_block(&"rifle", Vector2i(2, 2))])
	_check(not bool(r_gate["ok"]), "insert_fitting 也遵守准入（%s）" % str(r_gate["reason"]))
	_check(gate.is_empty(), "重排没把它偷偷塞进来")
	_check((r_gate["left"] as Array).size() == 1, "被拒的那块原样退回，没静默丢弃")
	_check(str(r_gate["reason"]).contains("不接收"), "理由说是准入：%s" % str(r_gate["reason"]))

	var gate_src := CellGrid.new(Vector2i(2, 2))
	gate_src.place_at(&"rifle", Vector2i(0, 0), Vector2i(2, 2))
	var r_gate_move := GridOps.move_fitting(gate_src, gate, {"from": 0})
	_check(not bool(r_gate_move["ok"]), "move_fitting 也遵守准入（%s）" % str(r_gate_move["reason"]))
	_check(gate_src.count() == 1 and gate.is_empty(), "两边都没动")

	# 但 `restore()` 自己**必须**不看准入：存档里的东西本来就该在它原来的格子里，
	# 规则改严之后读档把它们扔掉才是灾难。
	var old_save := [{"payload": &"rifle", "anchor": [0, 0], "base": [2, 2],
		"rot": 0, "rotatable": false}]
	_eq(gate.restore(old_save), "", "restore 不因准入规则拒绝旧档")
	_eq(gate.count(), 1, "旧档里的步枪读回来了")

	# ④ 模块里不该出现"物品"这类词（这条断言是防止有人把游戏逻辑塞回来）
	var checker := FileAccess.open("res://scripts/cell_grid.gd", FileAccess.READ)
	_check(checker != null, "能读到 cell_grid.gd")
	if checker != null:
		var src := checker.get_as_text()
		checker.close()
		for word in ["ItemDef", "ItemStack", "ItemDB", "max_stack", "def_id"]:
			_check(not src.contains(word), "容器本体里不该出现 %s（那是游戏侧的东西）" % word)


# ══ 11. 格 ↔ 像素（GridLayout）════════════════════════════

## 这一节钉的是**写 UI 时唯一会出人命的地方**：画在哪、点到哪，必须是同一套数学。
## 只要 `cell_at(cell_rect(i).center) == i` 对每一格都成立，就不可能"点偏一格"。
func test_layout_roundtrip() -> void:
	_section = "11 格 ↔ 像素"
	_begin(_section)
	var grid := Vector2i(9, 4)
	var layout := GridLayout.new(Vector2(52.0, 52.0), Vector2(4.0, 4.0), Vector2(12.0, 42.0))
	var step := layout.step()
	_eq(step, Vector2(56.0, 56.0), "步长 = 格 + 缝隙")
	_eq(layout.board_size(grid), Vector2(9.0 * 52.0 + 8.0 * 4.0, 4.0 * 52.0 + 3.0 * 4.0),
		"整板尺寸 = 格 × 数量 + 缝隙 × (数量-1)")
	_eq(layout.board_size(Vector2i.ZERO), Vector2.ZERO, "空网格尺寸为 0")

	# ① 每一格的中心都必须回到自己（这是"点偏一格"的结构性排除）
	var bad := 0
	for y in grid.y:
		for x in grid.x:
			var cell := Vector2i(x, y)
			if layout.cell_at(layout.cell_rect(cell).get_center(), grid) != cell:
				bad += 1
	_eq(bad, 0, "全部 36 格的中心都能点回自己")

	# ② 四条边上的点也要落对（中心不对不代表边界就对）
	_eq(layout.cell_at(layout.cell_rect(Vector2i(3, 2)).position, grid), Vector2i(3, 2),
		"左上角点属于这一格")
	_eq(layout.cell_at(layout.cell_rect(Vector2i(3, 2)).end - Vector2(1.0, 1.0), grid),
		Vector2i(3, 2), "右下角内侧仍属于这一格")

	# ③ 缝隙与网格外都不属于任何一格
	_eq(layout.cell_at(layout.cell_rect(Vector2i(3, 2)).end + Vector2(2.0, 2.0), grid),
		Vector2i(-1, -1), "落在格缝里 ⇒ (-1,-1)")
	_eq(layout.cell_at(Vector2(0.0, 0.0), grid), Vector2i(-1, -1), "网格外（原点左上）⇒ (-1,-1)")
	_eq(layout.cell_at(layout.cell_rect(Vector2i(8, 3)).end + Vector2(1.0, 1.0), grid),
		Vector2i(-1, -1), "越过最后一格 ⇒ (-1,-1)")

	# ④ 一块的矩形必须刚好覆盖它占的所有格（画出来的框不能漏格、不能多格）
	var block := layout.block_rect(Vector2i(2, 1), Vector2i(3, 2))
	_eq(block.position, layout.cell_rect(Vector2i(2, 1)).position, "块矩形左上 = 锚点格的左上")
	_eq(block.end, layout.cell_rect(Vector2i(4, 2)).end, "块矩形右下 = 最后一格的右下")
	var outside := 0
	for cell in GridShape.cells_at(Vector2i(2, 1), Vector2i(3, 2)):
		if not block.encloses(layout.cell_rect(cell)):
			outside += 1
	_eq(outside, 0, "这块占的 6 格全部落在块矩形内（画出来不漏格）")
	# 1×1 的块中心必然落在自己那一格里（块中心落到缝隙是正常的：缝隙不属于任何格）
	_eq(layout.cell_at(layout.block_rect(Vector2i(4, 3), Vector2i.ONE).get_center(), grid),
		Vector2i(4, 3), "1×1 块的中心点回自己")

	# ⑤ 换一套尺寸也要成立（别把常量写死在里面）
	var big := GridLayout.new(Vector2(80.0, 40.0), Vector2(0.0, 0.0), Vector2.ZERO)
	_eq(big.cell_at(big.cell_rect(Vector2i(5, 3)).get_center(), Vector2i(8, 8)), Vector2i(5, 3),
		"无缝、非正方形的格也要能点回去")
	_eq(big.block_rect(Vector2i(0, 0), Vector2i(2, 2)).size, Vector2(160.0, 80.0),
		"无缝时块的尺寸 = 格 × 数量")

	# ⑥ 格子右下边界上**正好那一点**属于缝隙（这段最容易被 `>` 写成"算进前一格"）
	_eq(layout.cell_at(layout.cell_rect(Vector2i(3, 2)).end, grid), Vector2i(-1, -1),
		"格子右下边界上的点属于缝隙，不属于任何一格")

	# ⑦ 拖拽落点用的容错版：缝隙里吸附到**最近**的格，网格外仍然不放宽
	#    （拖块的左上角时，那个点是连续的，正好压在 4px 缝上完全可能）
	var seam_y := layout.cell_rect(Vector2i(3, 2)).get_center().y
	var seam := Vector2(layout.cell_rect(Vector2i(3, 2)).end.x + 1.0, seam_y)
	_eq(layout.cell_at(seam, grid), Vector2i(-1, -1), "严格版：缝隙里还是 (-1,-1)")
	_eq(layout.cell_at_snapped(seam, grid), Vector2i(3, 2), "容错版：离 (3,2) 更近 ⇒ 吸附过去")
	var seam_right := Vector2(layout.cell_rect(Vector2i(3, 2)).end.x + 3.5, seam_y)
	_eq(layout.cell_at_snapped(seam_right, grid), Vector2i(4, 2), "靠右半边 ⇒ 吸附到右边那格")
	_eq(layout.cell_at_snapped(Vector2(0.0, 0.0), grid), Vector2i(-1, -1),
		"容错版也不收网格外的点（拖到标题栏/板外仍是没落进格子）")
	_eq(layout.cell_at_snapped(layout.cell_rect(Vector2i(8, 3)).end + Vector2(40.0, 40.0), grid),
		Vector2i(-1, -1), "越过右下角的点仍算板外")
	_eq(layout.cell_at_snapped(layout.cell_rect(Vector2i(0, 0)).position, grid), Vector2i(0, 0),
		"恰好压在左上角原点上也属于 (0,0)")


# ══ 12. 随机性质测试 ═════════════════════════════════════

func test_property_random_ops() -> void:
	_section = "12 随机性质"
	_begin(_section)
	var g := CellGrid.new(Vector2i(6, 5))
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261024
	var shapes: Array[Vector2i] = [
		Vector2i(1, 1), Vector2i(2, 1), Vector2i(1, 2), Vector2i(2, 2),
		Vector2i(3, 1), Vector2i(1, 3), Vector2i(3, 2),
	]
	var expected := 0
	var seq := 0

	for step in 300:
		var action := rng.randi_range(0, 4)
		var shape: Vector2i = shapes[rng.randi_range(0, shapes.size() - 1)]
		var rot := rng.randi_range(0, 1) == 0
		if action == 0:
			seq += 1
			if bool(g.place_auto(seq, shape, rot)["ok"]):
				expected += 1
		elif action == 1:
			if g.count() > 0:
				var i := rng.randi_range(0, g.count() - 1)
				if g.remove_at(i) != null:
					expected -= 1
		elif action == 2:
			if g.count() > 0:
				var i2 := rng.randi_range(0, g.count() - 1)
				var cell := Vector2i(rng.randi_range(-1, 6), rng.randi_range(-1, 5))
				var rots: Array[int] = [-1, 0, 90]
				g.move_to_cell(i2, cell, rots[rng.randi_range(0, 2)])
		elif action == 3:
			if g.count() > 0:
				g.rotate(rng.randi_range(0, g.count() - 1))
		else:
			if g.count() > 1:
				g.move_within(rng.randi_range(0, g.count() - 1),
					rng.randi_range(0, g.count() - 1))
		_check_invariants(g, expected, "第 %d 步" % step)


func _check_invariants(g: CellGrid, expected_total: int, tag: String) -> void:
	var size := g.grid_size()
	var ps := g.placements()
	var cells := 0
	for i in ps.size():
		var p := ps[i]
		_check(p.cells == GridShape.of(p.base_cells, p.rotatable, p.rot),
			"%s：第 %d 块 cells=%s 与 rot=%d 不自洽" % [tag, i, str(p.cells), p.rot])
		_check(GridShape.contains(size, p.anchor, p.cells),
			"%s：第 %d 块越界 %s %s" % [tag, i, str(p.anchor), str(p.cells)])
		for j in range(i + 1, ps.size()):
			_check(not GridShape.intersects(p.anchor, p.cells, ps[j].anchor, ps[j].cells),
				"%s：第 %d 与第 %d 块重叠" % [tag, i, j])
		cells += p.cells.x * p.cells.y
	_check(ps.size() == expected_total,
		"%s：块数不守恒（期望 %d，实际 %d）" % [tag, expected_total, ps.size()])
	_check(cells == g.used_cells(), "%s：used_cells 与 placements 不一致" % tag)
	_check(cells <= g.capacity(), "%s：占用格数超过容量" % tag)
	# 位置索引必须与 placements 一致（查和改对不上是最难查的一类 bug）
	for i in ps.size():
		_check(g.key_at_cell(ps[i].anchor) == i or g.cells_of(i).is_empty(),
			"%s：第 %d 块的锚点查不到自己" % [tag, i])


# ══ 13. 重排的随机性质测试 ═══════════════════════════════

## 重排最容易出的错不是"排得不好"，而是"重排之后东西多了/少了/叠在一起"。
## 所以每一步都查全套不变量，并额外钉一条：**重排成功 ⇒ 新块必须全部放下**。
func test_property_repack() -> void:
	_section = "13 重排性质"
	_begin(_section)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7777
	var shapes: Array[Vector2i] = [
		Vector2i(1, 1), Vector2i(2, 1), Vector2i(1, 2), Vector2i(2, 2),
		Vector2i(3, 1), Vector2i(3, 2),
	]
	var repacked := 0
	var failed := 0

	for round_i in 12:
		var g := CellGrid.new(Vector2i(5, 4))
		var expected := 0
		for step in 25:
			var shape: Vector2i = shapes[rng.randi_range(0, shapes.size() - 1)]
			var blocks := [_block(step, shape, rng.randi_range(0, 1) == 0)]
			var r := GridOps.insert_fitting(g, blocks)
			var placed := int(r["placed"])
			expected += placed
			if bool(r["repacked"]):
				repacked += 1
				_eq(placed, 1, "重排成功时新块应该整块放下")
			if placed == 0:
				failed += 1
			_eq((r["left"] as Array).size(), 1 - placed, "left 的数目要和 placed 对得上")
			_check_invariants(g, expected, "第 %d 轮第 %d 步" % [round_i, step])
	_check(repacked > 0, "12 轮里总该有几轮真的靠重排放下过（实际 %d 次）" % repacked)
	_check(failed > 0, "也总会有真的放不下的时候（实际 %d 次）" % failed)


# ══ 14. 返回值契约（这条写进文档之后不能再变）═══════════════

## 两种返回值：**判定 → String**（空串 = 可以），**动作 → Dictionary**（`{ok, reason, …}`）。
##
## 这一节钉的是"读法"本身：同一个函数，成功与失败的**键集合必须完全相同**，
## 并且永远只有两种组合（`ok` 真 ⇒ `reason` 空；`ok` 假 ⇒ `reason` 非空）。
## 少了它，调用方就得按分支写两套读法 —— 而错的那一套不会报错，只会在某个罕见
## 失败路径上崩（`res["moved"]` 取不到）。
##
## ★ 还有一条：**一个动作只发一次 `changed`**。界面按信号重绘，多发就是多画，
##   而"发到一半"的中间态会被画出来（清空一半的背包）。
func test_result_contract() -> void:
	_section = "14 返回值契约"
	_begin(_section)

	# ── 放入 ──
	var g := CellGrid.new(Vector2i(2, 2))
	var ok_auto := g.place_auto("a", Vector2i(1, 1))
	var bad_auto := g.place_auto("b", Vector2i(3, 1))
	_same_keys(ok_auto, bad_auto, "place_auto 成功/失败键集合相同")
	_probe_result(ok_auto, "place_auto 成功")
	_probe_result(bad_auto, "place_auto 失败")

	var ok_at := g.place_at("c", Vector2i(1, 0), Vector2i(1, 1))
	var bad_at := g.place_at("d", Vector2i(9, 9), Vector2i(1, 1))
	_same_keys(ok_at, bad_at, "place_at 成功/失败键集合相同")
	_probe_result(ok_at, "place_at 成功")
	_probe_result(bad_at, "place_at 失败")

	# ── 格内搬运 ──
	var m := CellGrid.new(Vector2i(3, 1))
	m.place_at("x", Vector2i(0, 0), Vector2i.ONE)
	var ok_cell := m.move_to_cell(0, Vector2i(2, 0))
	var bad_cell := m.move_to_cell(0, Vector2i(9, 9))
	_same_keys(ok_cell, bad_cell, "move_to_cell 成功/失败键集合相同")
	_probe_result(ok_cell, "move_to_cell 成功")
	_probe_result(bad_cell, "move_to_cell 失败")

	var w := CellGrid.new(Vector2i(3, 1))
	w.place_at("p", Vector2i(0, 0), Vector2i.ONE)
	w.place_at("q", Vector2i(2, 0), Vector2i.ONE)
	var ok_within := w.move_within(1)              # 搬到中间那块空地
	var bad_within := w.move_within(99)            # 没有这一块
	_same_keys(ok_within, bad_within, "move_within 成功/失败键集合相同")
	_probe_result(ok_within, "move_within 成功")
	_probe_result(bad_within, "move_within 失败")

	# ── 旋转 ──
	var r := CellGrid.new(Vector2i(4, 4))
	r.place_auto("r", Vector2i(2, 1), true)
	var ok_rot := r.rotate(0)
	var bad_rot := r.rotate(99)
	_same_keys(ok_rot, bad_rot, "rotate 成功/失败键集合相同")
	_probe_result(ok_rot, "rotate 成功")
	_probe_result(bad_rot, "rotate 失败")

	# ── 合并 ──
	var c := CellGrid.new(Vector2i(2, 1))
	c.merge_rule = func(a, b) -> Variant:
		return null if a is String else int(a) + int(b)
	c.place_at(1, Vector2i(0, 0), Vector2i.ONE)
	var ok_merge := c.merge_into(0, 2)
	var bad_merge := c.merge_into(0, "不是数字")
	_same_keys(ok_merge, bad_merge, "merge_into 成功/失败键集合相同")
	_probe_result(ok_merge, "merge_into 成功")
	_probe_result(bad_merge, "merge_into 失败")

	# ── GridOps 三层 ──
	var from := CellGrid.new(Vector2i(2, 1))
	from.place_at("rod", Vector2i(0, 0), Vector2i(1, 2), true)
	var to := CellGrid.new(Vector2i(3, 3))
	var ok_move := GridOps.move(from, to, {"from": 0})
	var bad_move := GridOps.move(from, to, {"from": 0})     # 来源已经没有这一块
	_same_keys(ok_move, bad_move, "GridOps.move 成功/失败键集合相同")
	_probe_result(ok_move, "GridOps.move 成功")
	_probe_result(bad_move, "GridOps.move 失败")

	var f2 := CellGrid.new(Vector2i(2, 1))
	f2.place_at("rod", Vector2i(0, 0), Vector2i(1, 2), true)
	var t2 := CellGrid.new(Vector2i(2, 2))
	t2.place_at("x", Vector2i(1, 1), Vector2i.ONE)
	var ok_fit := GridOps.move_fitting(f2, t2, {"from": 0})
	var bad_fit := GridOps.move_fitting(f2, t2, {"from": 0})
	_same_keys(ok_fit, bad_fit, "GridOps.move_fitting 成功/失败键集合相同")
	_probe_result(ok_fit, "GridOps.move_fitting 成功")
	_probe_result(bad_fit, "GridOps.move_fitting 失败")
	# ← 失败结果里没有 moved 曾经是个真 bug：调用方一读 res["moved"] 就崩
	_check(bad_fit.has("moved") and int(bad_fit["moved"]) == 0,
		"move_fitting 失败时 moved 是 0（键必须在，值给空）")
	_check(bad_fit.has("repacked") and bad_fit.has("moves"),
		"move_fitting 失败时也要有 repacked / moves（键集合恒定）")

	var i_ok := CellGrid.new(Vector2i(2, 2))
	var ok_ins := GridOps.insert_fitting(i_ok, [_block("a", Vector2i(1, 1))])
	var i_bad := CellGrid.new(Vector2i(1, 1))
	i_bad.place_auto("full", Vector2i(1, 1))
	var bad_ins := GridOps.insert_fitting(i_bad, [_block("b", Vector2i(1, 1))])
	_same_keys(ok_ins, bad_ins, "GridOps.insert_fitting 成功/失败键集合相同")
	_probe_result(ok_ins, "GridOps.insert_fitting 成功")
	_probe_result(bad_ins, "GridOps.insert_fitting 失败")
	_eq(bool(bad_ins["ok"]), false, "insert_fitting 的 ok 表示「全部放下」")
	_check((bad_ins["left"] as Array).size() == 1, "没放下的那块在 left 里")
	_check(str(bad_ins["reason"]) != "", "并且给了理由")

	# 空输入不算失败（没东西要放 = 全部放下）
	var nothing := GridOps.insert_fitting(CellGrid.new(Vector2i(2, 2)), [])
	_eq(bool(nothing["ok"]), true, "空列表 ⇒ ok（没什么要放的）")

	# ── 一个动作 = 一次 changed ──
	var hits := [0]
	var h := CellGrid.new(Vector2i(3, 1))
	h.changed.connect(func() -> void: hits[0] += 1)
	h.place_auto("a", Vector2i.ONE)
	_eq(hits[0], 1, "放入发 1 次 changed")
	h.place_auto("b", Vector2i.ONE)
	_eq(hits[0], 2, "再放一块再 +1")
	h.place_auto("c", Vector2i(5, 5))
	_eq(hits[0], 2, "失败不发信号（网格没变就不该重绘）")
	var snap := h.snapshot()
	h.clear()
	_eq(hits[0], 3, "clear() 清两块也只发 1 次（不是每块一次）")
	h.clear()
	_eq(hits[0], 3, "已经空了再 clear 不发信号")
	_eq(h.restore(snap), "", "快照能还原")
	_eq(hits[0], 4, "restore 只发 1 次")
	_eq(h.count(), 2, "两块都在")


# ══ 夹具与断言 ═══════════════════════════════════════════

func _block(payload, cells: Vector2i, rotatable: bool = false) -> Dictionary:
	return {"payload": payload, "cells": cells, "rotatable": rotatable}


## 两次调用的返回**键集合**必须完全一样（成功与失败不能是两套形状）。
func _same_keys(a: Dictionary, b: Dictionary, what: String) -> void:
	var ka := a.keys()
	var kb := b.keys()
	ka.sort()
	kb.sort()
	_eq(ka, kb, "%s（成功 %s / 失败 %s）" % [what, str(ka), str(kb)])


## `ok` 与 `reason` 只有两种合法组合：真/空、假/非空。永远不该出现"假/空"。
func _probe_result(res: Dictionary, what: String) -> void:
	_check(res.has("ok") and res.has("reason"), "%s：结果里必须有 ok 与 reason" % what)
	var ok := bool(res.get("ok", false))
	var reason := str(res.get("reason", ""))
	_check(ok == (reason == ""), "%s：ok=%s 与 reason=%s 不自洽" % [
		what, str(ok), "空" if reason == "" else "「%s」" % reason])


func _begin(name: String) -> void:
	print("\n── %s" % name)


func _check(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		printerr("  ✗ [%s] %s" % [_section, what])


func _eq(actual, expected, what: String) -> void:
	if actual == expected:
		_pass += 1
	else:
		_fail += 1
		printerr("  ✗ [%s] %s —— 期望 %s，实际 %s" % [_section, what, str(expected), str(actual)])
