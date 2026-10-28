class_name GridRepacker
extends RefCounted
## **允许挪动已有块的装箱** —— 把整个网格当白纸重排一遍。
##
## ══ 这解决的是什么问题 ═══════════════════════════════════
## 二维矩形装箱（2D rectangular packing），NP-hard，工程上分两种玩法：
##
##   · **online**：来一块放一块，不许动已经放好的 —— 就是 `FirstFitFinder`。
##     便宜、稳定、可预测；代价是会把网格切碎，最后落到
##     「总面积明明够，但每一块空隙都塞不进这一块」的死局。
##   · **offline / repack / defrag**：允许把已有块全部拿出来重新排 —— 就是这个文件。
##     代价是玩家会看到位置跳动，换来「只要凑得出来就放得下」。
##
## 工业界的成熟解法是 MaxRects 家族（BSSF / BLSF / BAF / BL，
## 见 Jylänki 那篇 "A Thousand Ways to Pack the Bin"）。这里的规模小到
## 不值得上那套空间树，直接做**有限轮离线装箱**：
##
##   排序键四种：面积降序 / 长边降序 / 周长降序 / 高度降序（大块先放，小块填缝）
##   评分器两种：贴边接触最大（紧凑）/ 左上优先（稳定）
##   ⇒ 8 轮全失败才认输；面积下界先判，挡掉绝大多数「真的装不下」。
##
## 多轮不是因为贪心有多聪明，而是因为**没有单一排序对所有人都好**：
## 一堆 2×2 和一排 1×4 混在一起时，按面积排和按长边排会得到完全不同的结果，
## 而判断哪一轮能成需要真的跑一遍 —— 所以干脆都试，谁先成听谁的。
##
## ══ 它只看形状，不看块是什么 ═══════════════════════════
## `payload` 在这里是纯粹被搬运的行李：进布局时原样带过去，没有一次读取或比较。
## 于是"背包里的枪"和"网格上的建筑"共用这同一份算法。
##
## ★ 它同样**不认识** `accepts`（准入规则）：布局是纯几何问题，"这块东西该不该在这个
##   箱子里"是另一个问题。所以直接拿它的 `layout` 去 `restore()` 会绕过准入 ——
##   `GridOps.insert_fitting()` / `move_fitting()` 都是**先筛准入、再问重排**的。
##   自己直接调 `plan()` 时，这条顺序得你自己保证。
##
## ══ 为什么返回布局、不直接改网格 ═════════════════════════
## 布局交给 `grid.restore()` 提交，于是「全或无、失败回滚」是白送的。
## 这个文件因此**一行都不碰真实网格**，可以随便试、随便推翻。
##
## ══ 用法 ═══════════════════════════════════════════════
## 一般不用直接调它 —— `GridOps.insert_fitting()` 已经把
## 「先直接放，放不下才重排」串好了。单独调是为了拿到 `moves`（挪动了几块）。

## 一轮尝试的排序键（决定处理的先后：大块先放，小块最后填缝）
const SORTS: Array[String] = ["area", "long_side", "perimeter", "tall"]
## 一轮尝试的评分器（决定每块放在哪：紧凑 vs 左上）
const SCORERS: Array[String] = ["tight", "bl"]


## 只读地算一份新布局。`incoming` = 还想放进去的块（空数组 = 只整理现有块）。
## 每条：`{"payload": 任意, "cells": Vector2i(m, n), "rotatable": bool}`。
##
## 返回 `{"ok", "reason", "layout": Array, "moves": int, "attempt": String, "tried": int}`；
## `layout` 的格式与 `snapshot()` 一致，可直接喂给 `restore()`。
static func plan(container: CellGrid, incoming: Array = [],
		max_attempts: int = 8) -> Dictionary:
	if container == null:
		return _fail("网格是空的")
	var grid := container.grid_size()
	if grid.x <= 0 or grid.y <= 0:
		return _fail("网格尺寸不合法：%s" % str(grid))

	var entries := _entries_of(container, incoming)
	if entries.is_empty():
		return _fail("没有要放的东西")

	# ① 面积下界：必要条件，O(n)，先挡掉绝大多数「真的装不下」——
	#    没有这一条，网格一满就要跑满 8 轮搜索，而结果必然是失败。
	var need := 0
	for e in entries:
		need += int(e["base"].x) * int(e["base"].y)
	if need > grid.x * grid.y:
		return _fail("面积不够：要 %d 格，网格只有 %d 格" % [need, grid.x * grid.y])

	# ② 多轮尝试，谁先成听谁的
	var tried := 0
	for sort_key in SORTS:
		for scorer in SCORERS:
			if tried >= max_attempts:
				break
			tried += 1
			var order := _sorted(entries, sort_key)
			var layout := _pack(grid, order, scorer)
			if layout.is_empty():
				continue
			return {"ok": true, "reason": "", "layout": layout,
				"attempt": "%s+%s" % [sort_key, scorer], "tried": tried,
				"moves": _count_moves(order, layout)}
	return _fail("重排了 %d 轮都放不下：总面积够，但形状凑不出来" % tried, tried)


# ══ 收集 ══════════════════════════════════════════════

## 把「已有的每一块」+「新块的每一块」摊平成待放列表。
## ★ 形状基准统一取 `base_cells`（**未旋转**的形状），因为 `rot` 是相对它的方向；
##   若拿 `Placement.cells`（已旋转）当基准，方向标记会整体错位 90°。
static func _entries_of(container: CellGrid, incoming: Array) -> Array:
	var out := []
	for p in container.placements():
		out.append({
			"payload": p.payload,
			"base": GridShape.normalize(p.base_cells),
			"rotatable": p.rotatable,
			"orig": p.anchor,          # 原位（相对它算"挪动了几块"）
			"orig_rot": p.rot,
		})
	for b in incoming:
		if not (b is Dictionary):
			continue
		var d := b as Dictionary
		out.append({
			"payload": d.get("payload"),
			"base": GridShape.normalize(d.get("cells", Vector2i.ONE)),
			"rotatable": bool(d.get("rotatable", false)),
			"orig": null,              # 新块没有原位 ⇒ 怎么放都不算「挪动」
			"orig_rot": -1,
		})
	return out


## 四种排序键。同分时按原顺序 ⇒ **稳定**，同样的输入永远得到同样的布局（存档不会漂）。
static func _sorted(entries: Array, key: String) -> Array:
	var idx := range(entries.size())
	idx.sort_custom(func(a: int, b: int) -> bool:
		var ra := _rank(entries[a], key)
		var rb := _rank(entries[b], key)
		if ra != rb:
			return ra > rb
		return a < b)
	var out := []
	for i in idx:
		out.append(entries[i])
	return out


static func _rank(e: Dictionary, key: String) -> int:
	var c: Vector2i = e["base"]
	match key:
		"long_side":
			return maxi(c.x, c.y)
		"perimeter":
			return 2 * (c.x + c.y)
		"tall":
			return c.y * 100 + c.x      # 高的先放，利于把列填满
		_:
			return c.x * c.y


# ══ 装箱 ══════════════════════════════════════════════

## 逐块找位置。任何一块找不到 ⇒ 返回空数组（这一轮失败，交给下一个排序/评分组合）。
static func _pack(grid: Vector2i, order: Array, scorer: String) -> Array:
	var board := _Board.new(grid)
	var layout := []
	for e in order:
		var dirs := _dirs(e["base"], bool(e["rotatable"]))
		var best := {}
		var best_score := 0
		for di in dirs.size():
			var shape: Vector2i = dirs[di]
			for y in grid.y:
				for x in grid.x:
					var anchor := Vector2i(x, y)
					if not board.fits(anchor, shape):
						continue
					var score := board.score(anchor, shape, scorer, e["orig"], int(e["orig_rot"]),
						0 if di == 0 else 90)
					if best.is_empty() or score < best_score:
						best_score = score
						best = {"anchor": anchor, "shape": shape, "rot": 0 if di == 0 else 90}
		if best.is_empty():
			return []
		board.mark(best["anchor"], best["shape"])
		layout.append({
			"payload": e["payload"],
			"anchor": [best["anchor"].x, best["anchor"].y],
			"base": [int(e["base"].x), int(e["base"].y)],
			"rot": int(best["rot"]),
			"rotatable": bool(e["rotatable"]),
		})
	return layout


static func _dirs(base: Vector2i, rotatable: bool) -> Array[Vector2i]:
	var out: Array[Vector2i] = [base]
	if GridShape.can_rotate(base, rotatable):
		out.append(Vector2i(base.y, base.x))
	return out


## 挪动块数：anchor 或方向变了的才算（新加入的块本来就"没有原位"，不计）。
static func _count_moves(order: Array, layout: Array) -> int:
	var n := 0
	for i in order.size():
		var e: Dictionary = order[i]
		if e["orig"] == null:
			continue
		var l: Dictionary = layout[i]
		if Vector2i(int(l["anchor"][0]), int(l["anchor"][1])) != e["orig"] \
				or int(l["rot"]) != int(e["orig_rot"]):
			n += 1
	return n


static func _fail(reason: String, tried: int = 0) -> Dictionary:
	return {"ok": false, "reason": reason, "layout": [], "moves": 0, "attempt": "", "tried": tried}


# ══ 占用位图 ═══════════════════════════════════════════

## 一格一字节的占用位图。用内部类是因为 `PackedByteArray` 是**值类型**：
## 当参数传进去再改，改的是副本，调用方看不见（这个坑会让标记全部失效）。
class _Board extends RefCounted:
	var grid: Vector2i
	var occ: PackedByteArray

	func _init(g: Vector2i) -> void:
		grid = g
		occ = PackedByteArray()
		occ.resize(maxi(0, g.x * g.y))

	func fits(anchor: Vector2i, shape: Vector2i) -> bool:
		if anchor.x < 0 or anchor.y < 0:
			return false
		if anchor.x + shape.x > grid.x or anchor.y + shape.y > grid.y:
			return false
		for yy in shape.y:
			var row := (anchor.y + yy) * grid.x + anchor.x
			for xx in shape.x:
				if occ[row + xx] != 0:
					return false
		return true

	func mark(anchor: Vector2i, shape: Vector2i) -> void:
		for yy in shape.y:
			var row := (anchor.y + yy) * grid.x + anchor.x
			for xx in shape.x:
				occ[row + xx] = 1

	## 四条边各有多少格**贴着**已占用格或网格边界。越多越紧凑 —— 这是
	## 「别再切出新碎片」的量化：贴边多的放法，剩下的空位是整块的。
	func contacts(anchor: Vector2i, shape: Vector2i) -> int:
		var n := 0
		for x in shape.x:
			if anchor.y == 0 or occ[(anchor.y - 1) * grid.x + anchor.x + x] != 0:
				n += 1
			var by := anchor.y + shape.y
			if by >= grid.y or occ[by * grid.x + anchor.x + x] != 0:
				n += 1
		for y in shape.y:
			if anchor.x == 0 or occ[(anchor.y + y) * grid.x + anchor.x - 1] != 0:
				n += 1
			var rx := anchor.x + shape.x
			if rx >= grid.x or occ[(anchor.y + y) * grid.x + rx] != 0:
				n += 1
		return n

	## 越小越好。
	func score(anchor: Vector2i, shape: Vector2i, scorer: String, orig, orig_rot: int, rot: int) -> int:
		var pos := anchor.y * grid.x + anchor.x
		if scorer == "bl":
			return pos
		var base := grid.x * grid.y + 1
		var s := pos - contacts(anchor, shape) * base
		# 原位折算成「多一个接触面」的优先权：能不动就不动，
		# 玩家看到的是「只是旁边挪了一下」，而不是「整个网格被洗牌」。
		if orig != null and anchor == orig and rot == orig_rot:
			s -= base
		return s
