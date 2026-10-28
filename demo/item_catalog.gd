class_name DemoItemCatalog
extends RefCounted
## 【**游戏侧** · 不属于容器模块】物品目录：这块东西**是什么**。
##
## 名字、颜色、堆叠上限、图标 —— 全都是这一款游戏的设计，别的游戏完全不长这样，
## 所以它们一行都不在 `scripts/` 里。容器只知道"这块占 m×n 格、能不能转"。
##
## 两条来源都进同一个目录：
##   · 编辑器：代码里 `register()`；
##   · 配置：`load_json("res://demo/items.json")`。

## 一条物品 = `{"id", "name", "cells": Vector2i, "rotatable": bool, "max_stack": int, "color": Color}`
var _defs: Dictionary = {}
var _errors: Array[String] = []


func register(def: Dictionary) -> String:
	var id := StringName(str(def.get("id", "")))
	if id == &"":
		return "缺 id：%s" % str(def)
	if _defs.has(id):
		return "重复的 id：%s" % String(id)
	_defs[id] = def
	return ""


func has_def(id: StringName) -> bool:
	return _defs.has(id)


func get_def(id: StringName) -> Dictionary:
	return _defs.get(id, {})


## 按 id 排序返回：随机取值、界面列目录都要求个稳定的序。
func ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for k in _defs.keys():
		out.append(k)
	out.sort()
	return out


func size() -> int:
	return _defs.size()


## 载入过程中攒下的问题（一条坏数据不该让整张表都进不来）。
func errors() -> Array[String]:
	return _errors.duplicate()


func clear() -> void:
	_defs.clear()
	_errors.clear()


# ══ 取字段（拿不到就给个安全默认值）════════════════════════

func name_of(id: StringName) -> String:
	return str(get_def(id).get("name", String(id)))


func cells_of(id: StringName) -> Vector2i:
	return get_def(id).get("cells", Vector2i.ONE)


func rotatable_of(id: StringName) -> bool:
	return bool(get_def(id).get("rotatable", false))


func max_stack_of(id: StringName) -> int:
	return maxi(1, int(get_def(id).get("max_stack", 1)))


func color_of(id: StringName) -> Color:
	var d := get_def(id)
	return d.get("color", Color(0.40, 0.46, 0.56))


# ══ JSON ═══════════════════════════════════════════════

## 格式：`{"items": [{"id": "rifle", "name": "步枪", "cells": "1x4",
##                   "rotatable": true, "max_stack": 1, "color": "#c0653c"}]}`
## 返回空串 = 全部成功，否则是逐条问题（换行分隔）。
func load_json(path: String) -> String:
	_errors.clear()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "打不开 %s" % path
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		return "%s 不是合法的 JSON 对象" % path
	var items = (parsed as Dictionary).get("items", [])
	if not (items is Array):
		return "%s 里没有 items 数组" % path
	for raw in items:
		if not (raw is Dictionary):
			_errors.append("有一条不是字典：%s" % str(raw))
			continue
		var d := raw as Dictionary
		var id := StringName(str(d.get("id", "")))
		if id == &"":
			_errors.append("缺 id：%s" % str(d))
			continue
		var shape := _parse_cells(str(d.get("cells", "")))
		if shape.x <= 0:
			_errors.append("%s 的 cells 写法不对：%s" % [String(id), str(d.get("cells", ""))])
			continue
		var entry := {
			"id": id,
			"name": str(d.get("name", String(id))),
			"cells": shape,
			"rotatable": bool(d.get("rotatable", false)),
			"max_stack": maxi(1, int(d.get("max_stack", 1))),
			"color": _parse_color(str(d.get("color", ""))),
		}
		var err := register(entry)
		if err != "":
			_errors.append(err)
	return "\n".join(_errors)


## `"2x1"` → `(2, 1)`。写错就返回 `(0,0)`，**不猜**（"3*1" / "3,1" / "31" 一律拒绝）。
func _parse_cells(text: String) -> Vector2i:
	var parts := text.strip_edges().to_lower().split("x", false)
	if parts.size() != 2:
		return Vector2i.ZERO
	if not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.ZERO
	var w := int(parts[0])
	var h := int(parts[1])
	return Vector2i(w, h) if w > 0 and h > 0 else Vector2i.ZERO


func _parse_color(text: String) -> Color:
	var fallback := Color(0.40, 0.46, 0.56)
	var t := text.strip_edges()
	if not t.begins_with("#"):
		return fallback
	return Color.from_string(t, fallback)
