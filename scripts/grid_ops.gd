class_name GridOps
extends RefCounted
## **唯一改动网格的入口**：搬 / 转 / 批量放 / 装不下就重排，全部走这里。
##
## ══ 搬有两档，默认走便宜的那档 ═══════════════════════════
##   · `move()`         —— online：不动目标里已有的块。拖拽落点、预览都用它；
##   · `move_fitting()` —— 直接搬不动时，让**目标**重排腾地方（代价是位置跳动）。
## 同理，放入也分两档：`place_auto()`（online）/ `insert_fitting()`（先放、放不下才重排）。
## 分成两档而不是"自动挑"，是因为**位置跳动必须由调用方显式选择** ——
## 玩家盯着拖影松手时，东西不该自己重新排一遍。
##
## ══ 为什么只留一个入口 ══════════════════════════════════
## "从 A 拿一块放进 B" 这种动作，谁都能自己写一遍，每条路都要记得四件事：
##   来源有没有这一块 · 目标放不放得下 · 失败时两边不许变 · 位置和方向别丢
## 少写一条的症状都是"东西凭空多了 / 少了 / 换个地方了"，而且都不报错。
##
## ══ 三条硬规则 ═════════════════════════════════════════
##   ① **先校验、后提交**：`problem()` 与 `move()` 走同一段 `_plan()`，
##      判定阶段一个字节都不改 ⇒「界面说能放、按下去放不上」在结构上不可能；
##   ② **失败时两边都不许变**：回滚到**原来的锚点与方向**，不是"随便找个空位塞回去"；
##   ③ **块是原子的**：没有"搬 3 个过去"这回事 —— 一个格子里就是一个东西。
##      要拆堆是游戏的事（容器不认识"数量"），拆完再来放两块小的。
##
## ══ 写法（`order`）══════════════════════════════════════
##   · 只给来源键：      `move(a, b, 3)`             —— b 自己挑位置
##   · 点名落点那一格：  `{"from": 3, "cell": Vector2i(2, 0), "rot": 90}`
##   · 点名落点那一块：  `{"from": 3, "to": 1}`       —— 合并（跨容器也需要同一套规矩）
##   · 同网格（a == b）：自动转交网格自己的 `move_within()`
##   ★ `rot` 省略 = `-1` = 没点名方向（正放，不行再转过来）；
##     `0` / `90` = 照这个方向放，放不下就**拒绝并说理由**（不偷偷换个方向）。


## 搬（返回 `{"ok", "moved", "reason"}`，`moved` = 0/1/2 块）。
static func move(from: CellGrid, to: CellGrid, order = null) -> Dictionary:
	if from != null and from == to:
		return _move_within(from, order)
	var plan := _plan(from, to, order)
	if not bool(plan["ok"]):
		return _result(false, 0, str(plan["reason"]))

	var idx := int(plan["src_index"])
	var origin: Placement = from.placements()[idx]
	var origin_anchor := origin.anchor
	var origin_rot := origin.rot
	var taken := from.remove_at(idx)
	if taken == null:
		# 判定阶段不许有副作用；走到这里说明有人绕过规矩改了网格
		return _result(false, 0, "提交时来源已经没有这一块了（判定阶段有副作用）")

	# 三条路都只"搬 1 块"：放空格 / 合并（源那块消失）/ 自动找位
	var res: Dictionary
	if plan["cell"] != null:
		res = to.place_at(taken.payload, plan["cell"], taken.base_cells,
			taken.rotatable, int(plan["rot"]))
	elif int(plan["to_index"]) >= 0:
		res = to.merge_into(int(plan["to_index"]), taken.payload)
	else:
		res = to.place_auto(taken.payload, taken.base_cells, taken.rotatable)

	if not bool(res["ok"]):
		var back := from.place_at(taken.payload, origin_anchor, taken.base_cells,
			taken.rotatable, origin_rot)
		if not bool(back["ok"]):
			push_error("回滚失败：%dx%d 没能放回 %s（%s）" % [
				taken.base_cells.x, taken.base_cells.y, str(origin_anchor), str(back["reason"])])
		return _result(false, 0, "%s —— 已回滚，两边都没变" % str(res["reason"]))
	return _result(true, 1, "")


## **只读**地问：「这一块搬得成吗」（空串 = 搬得成）。界面染色、按钮可用性问它。
static func problem(from: CellGrid, to: CellGrid, order = null) -> String:
	if from != null and from == to:
		return _within_problem(from, order)
	return str(_plan(from, to, order)["reason"])


## 「装不下就重排」版的搬：**先走便宜的 `move()`，搬不动才让目标网格重排腾地方**。
##
## ══ 为什么单独一个函数，而不让 `move()` 自己重排 ═════════════
## 重排会挪动目标里已有的块（玩家看到位置跳动）。这是个**该被显式选择**的代价，
## 而 `move()` 是原语：它对"搬得成吗"的回答必须和"搬过去会怎样"完全一致，
## 不能夹带一次洗牌 —— 否则拖拽预览（`problem()`）会和松手结果分家。
##
## ══ 什么时候不重排 ═════════════════════════════════════
## `order` 里点名了落点（`cell`）或合并目标（`to`）时**直接拒绝，不动别人的东西**：
## 玩家已经指着那一格说"放这儿"，"我把你自己挪开"不是他要的意思。
##
## 返回 `{"ok", "moved", "reason", "repacked", "moves"}`：
## `repacked` = 是不是靠重排才搬成的，`moves` = 为此挪动了几块已有的。
static func move_fitting(from: CellGrid, to: CellGrid, order = null) -> Dictionary:
	if from == null or to == null:
		return _fit_result(false, 0, "来源或目标为空", false, 0)
	if from == to:
		var w := _move_within(from, order)
		return _fit_result(bool(w["ok"]), int(w["moved"]), str(w["reason"]), false, 0)

	var sel := _split(order)
	if sel["cell"] != null or sel["to"] != null:
		var pinned := move(from, to, order)
		return _fit_result(bool(pinned["ok"]), int(pinned["moved"]), str(pinned["reason"]),
			false, 0)
	if sel["from"] == null:
		return _fit_result(false, 0, "要说清搬哪一块（键）", false, 0)
	var i := from.index_of_key(sel["from"])
	if i < 0:
		return _fit_result(false, 0, "来源里没有这一块（键 %s）—— %s" % [
			str(sel["from"]), from.describe()], false, 0)

	var direct := move(from, to, order)
	if bool(direct["ok"]):
		return _fit_result(true, int(direct["moved"]), "", false, 0)

	# 直接搬不动 ⇒ 先问准入，再问重排。
	# ★ 顺序不能颠倒：`restore()` 刻意不问准入（读档不该问），重排借道 restore，
	#   于是"搬不动就重排"会变成绕过 `accepts` 的后门。
	if not to.admits(from.placements()[i].payload):
		return _fit_result(false, 0, str(direct["reason"]), false, 0)

	# 问重排。它只算布局、不碰任何网格；提交走 `restore()`（全或无）。
	var p := from.placements()[i]
	var plan := GridRepacker.plan(to, [{
		"payload": p.payload,
		"cells": p.base_cells,
		"rotatable": p.rotatable,
	}])
	if not bool(plan["ok"]):
		return _fit_result(false, 0, "%s；重排也腾不出地方（%s）" % [
			str(direct["reason"]), str(plan["reason"])], false, 0)

	var origin_anchor := p.anchor
	var origin_rot := p.rot
	var taken := from.remove_at(i)
	if taken == null:
		return _fit_result(false, 0, "提交时来源已经没有这一块了（判定阶段有副作用）", false, 0)
	var err := to.restore(plan["layout"])
	if err == "":
		return _fit_result(true, 1, "", true, int(plan["moves"]))

	# 布局被否决 ⇒ 回滚到**原来的锚点与方向**（不是"随便找个空位塞回去"）
	var back := from.place_at(taken.payload, origin_anchor, taken.base_cells,
		taken.rotatable, origin_rot)
	if not bool(back["ok"]):
		push_error("回滚失败：%dx%d 没能放回 %s（%s）" % [
			taken.base_cells.x, taken.base_cells.y, str(origin_anchor), str(back["reason"])])
	return _fit_result(false, 0, "重排布局被否决（%s）—— 已回滚，两边都没变" % err, false, 0)


## 转方向（返回 `{"ok", "rot", "reason"}`）。
static func rotate(grid: CellGrid, key) -> Dictionary:
	if grid == null:
		return {"ok": false, "rot": -1, "reason": "网格为空"}
	var why := grid.rotate_problem(key)
	if why != "":
		return {"ok": false, "rot": -1, "reason": why}
	return grid.rotate(key)


# ══ 批量放入 ═══════════════════════════════════════════

## 依次放，放不下的跳过（**后面更小的块仍然会被尝试**），返回没放下的那些。
##
## `blocks` 的每条：`{"payload": 任意, "cells": Vector2i(m, n), "rotatable": bool}`
## ★ 容器不认识"数量" —— 25 个木头要占几个格子、切几块，是**你的规则**，
##   切好之后把每一块交进来就行（demo 的 `DemoItemRules.blocks_of()` 就是这一步）。
## ★ 返回值是 `Array` 而不是 Result 字典：它答的是"还剩哪几块"，不是"成没成"。
##   非字典的条目会被原样退回（不猜它想占几格）。
static func insert_all(grid: CellGrid, blocks: Array) -> Array:
	var left := []
	if grid == null:
		return blocks
	for b in blocks:
		if not (b is Dictionary):
			left.append(b)
			continue
		var d := b as Dictionary
		var res := grid.place_auto(d.get("payload"), d.get("cells", Vector2i.ONE),
			bool(d.get("rotatable", false)))
		if not bool(res["ok"]):
			left.append(b)
	return left


## 装不下就**重排**：把已有块挪一挪，给新块腾地方（算法在 `GridRepacker`）。
##
## 顺序是刻意的 —— **先直接放，放不下才重排**：
##   直接放不打扰已有布局，玩家看到的是"塞进了空位"；重排是兜底，代价是位置跳动。
##   所以它绝不会为了"排得更整齐"无事生非。
##
## 返回 `{"ok", "placed", "left", "repacked", "moves", "reason"}`：
##   `ok` = **全部**都放下了（`left` 为空），`placed` = 放进去几块，
##   `left` = 没放下的块（原样，**绝不静默丢弃**；含被准入规则拒收的那些），
##   `repacked` = 这次是不是靠重排才放下的，`moves` = 挪动了几块已有的。
## ★ `ok = false` 不代表一块都没放进去（"尽量多放"的语义）——
##   已经放下的部分会留着，调用方读 `placed` / `left` 决定把剩下的丢地上还是还给世界。
## ★ **准入先过一遍**：被拒的块根本不进"放不放得下"的讨论。不能只靠 `place_auto()`
##   自己的检查 —— 重排走的是 `restore()`，而它刻意不问准入（读档不该问），
##   于是"放不下 ⇒ 重排"这条路会把被拒的东西偷偷塞进去。
static func insert_fitting(grid: CellGrid, blocks: Array) -> Dictionary:
	if grid == null or blocks.is_empty():
		return _insert_result(0, [], false, 0, "")

	var admitted := []
	var refused := []
	for b in blocks:
		if b is Dictionary and grid.admits((b as Dictionary).get("payload")):
			admitted.append(b)
		else:
			refused.append(b)

	var unplaced := insert_all(grid, admitted)
	var repacked := false
	var moves := 0
	var note := ""
	if not unplaced.is_empty():
		var plan := GridRepacker.plan(grid, unplaced)
		if bool(plan["ok"]):
			var err := grid.restore(plan["layout"])
			if err == "":
				repacked = true
				moves = int(plan["moves"])
				unplaced = []
			else:
				push_warning("重排布局提交失败（restore 是全或无，网格没变）：%s" % err)
		else:
			note = str(plan["reason"])

	var left := refused + unplaced
	if left.is_empty():
		return _insert_result(blocks.size(), [], repacked, moves, "")

	var why: Array[String] = []
	if not refused.is_empty():
		why.append("%d 块这个网格不接收" % refused.size())
	if not unplaced.is_empty():
		why.append("%d 块腾不出地方%s" % [
			unplaced.size(), "" if note == "" else "（%s）" % note])
	var placed := blocks.size() - left.size()
	return _insert_result(placed, left, repacked, moves,
		"只放进了 %d / %d 块：%s" % [placed, blocks.size(), "；".join(why)])


# ══ 同网格 ══════════════════════════════════════════════

static func _within_problem(grid: CellGrid, order) -> String:
	var sel := _split(order)
	if sel["from"] == null:
		return "同网格搬运要说清是哪一块（键）"
	if sel["cell"] != null:
		if sel["to"] != null:
			return "同时点名了「哪一块」（to）和「哪一格」（cell）—— 只能给一个"
		return grid.move_to_cell_problem(sel["from"], sel["cell"], int(sel["rot"]))
	return grid.move_within_problem(sel["from"], sel["to"])


static func _move_within(grid: CellGrid, order) -> Dictionary:
	var sel := _split(order)
	if sel["from"] == null:
		return _result(false, 0, "同网格搬运要说清是哪一块（键）")
	if sel["cell"] != null:
		if sel["to"] != null:
			return _result(false, 0, "同时点名了「哪一块」（to）和「哪一格」（cell）—— 只能给一个")
		return grid.move_to_cell(sel["from"], sel["cell"], int(sel["rot"]))
	return grid.move_within(sel["from"], sel["to"])


# ══ 判定（只读，一个字节都不改）═════════════════════════════

static func _plan(from: CellGrid, to: CellGrid, order) -> Dictionary:
	if from == null or to == null:
		return {"ok": false, "reason": "来源或目标为空"}
	if from == to:
		return {"ok": false, "reason": "来源与目标是同一个网格 —— 请走 move_within（move() 会自动转交）"}

	var sel := _split(order)
	if sel["from"] == null:
		return {"ok": false, "reason": "要说清搬哪一块（键）"}
	var cell = sel["cell"]
	var dst_key = sel["to"]
	if cell != null and dst_key != null:
		return {"ok": false, "reason": "同时点名了「哪一块」（to）和「哪一格」（cell）—— 只能给一个"}

	var i := from.index_of_key(sel["from"])
	if i < 0:
		return {"ok": false, "reason": "来源里没有这一块（键 %s）—— %s" % [
			str(sel["from"]), from.describe()]}
	var p := from.placements()[i]

	var why := ""
	var to_index := -1
	if cell != null:
		why = to.can_place_at(p.payload, cell, p.base_cells, p.rotatable, int(sel["rot"]))
	elif dst_key != null:
		to_index = to.index_of_key(dst_key)
		if to_index < 0:
			why = "目标网格里没有第 %s 块" % str(dst_key)
		elif not to.can_merge_at(to_index, p.payload):
			# ★ 跨容器**不换位**：对面那块东西被换到你的背包里，玩家几乎不会预期这个。
			why = "那一格是别的东西 —— 跨容器只能合并，不能换位（请落在空格上）"
	else:
		why = to.can_place_at(p.payload, Vector2i(-1, -1), p.base_cells, p.rotatable, -1)
	if why != "":
		return {"ok": false, "reason": why}

	return {"ok": true, "reason": "", "src_index": i, "cell": cell,
		"to_index": to_index, "rot": int(sel["rot"])}


## `order` 拆成来源 / 目标 / 格 / 方向。非字典写法 = "只给来源键，目标自己挑"。
## 三种写法（见文件头）：`3` / `{"from": 3}` / `{"from": 3, "cell": …}` / `{"from": 3, "to": …}`
static func _split(order) -> Dictionary:
	if order is Dictionary:
		var d := order as Dictionary
		return {"from": d.get("from", null), "to": d.get("to", null),
			"cell": d.get("cell", null), "rot": int(d.get("rot", -1))}
	return {"from": order, "to": null, "cell": null, "rot": -1}


static func _result(ok: bool, moved: int, reason: String) -> Dictionary:
	return {"ok": ok, "moved": moved, "reason": reason}


## `move_fitting()` 的返回：比 `move()` 多两个字段，但 `ok` / `moved` / `reason` 完全同义
## ⇒ 调用方可以先用一套读法处理，只在关心"有没有洗牌"时才去看 `repacked`。
static func _fit_result(ok: bool, moved: int, reason: String,
		repacked: bool, moves: int) -> Dictionary:
	return {"ok": ok, "moved": moved, "reason": reason,
		"repacked": repacked, "moves": moves}


## `insert_fitting()` 的返回。`ok` = **全部**放下（`left` 为空）。
static func _insert_result(placed: int, left: Array, repacked: bool, moves: int,
		reason: String) -> Dictionary:
	return {"ok": left.is_empty(), "placed": placed, "left": left,
		"repacked": repacked, "moves": moves, "reason": reason}
