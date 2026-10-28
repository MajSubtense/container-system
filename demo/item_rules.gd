class_name DemoItemRules
extends RefCounted
## 【**游戏侧** · 不属于容器模块】这些数据怎么用 —— 也就是"玩法规则"。
##
## 容器只回答"这块 2×1 放得下吗"。下面这三件事**一件都不该进容器**：
##
##   ① **一堆东西占几个格子**（切块）：`blocks_of()`。
##      25 个木头、上限 99 ⇒ 一块；250 个 ⇒ 3 块（99/99/52）。
##      容器不认识"数量"，所以它看到的就是 3 个 1×1 的块。
##   ② **两块什么时候能塌成一块**（合并）：`merge_payload()`。
##      "同一种东西、加起来不超过上限" 是**设计**，别的游戏可能允许超堆、或者按品质分堆。
##   ③ **这块东西该进哪个容器**（路由）：在宿主里一行 `if`，见 `demo.gd`。
##
## 改这三件事**不需要动 `scripts/` 里的任何一行** —— 这一条就是分层有没有做对的检验。

## payload 的形状由游戏定（容器只会原样搬运它）。
## 这里用一个能直接 `JSON.stringify` 的字典，于是存读档不需要任何额外编码器。
static func payload_of(id: StringName, count: int) -> Dictionary:
	return {"id": id, "count": count}


static func id_of(payload) -> StringName:
	if payload is Dictionary:
		return StringName(str((payload as Dictionary).get("id", "")))
	return &""


static func count_of(payload) -> int:
	if payload is Dictionary:
		return int((payload as Dictionary).get("count", 0))
	return 0


## 一堆东西 → 若干块。超过 `max_stack` 就切开（**一块都不能丢**：切出来的总数必须等于原数）。
static func blocks_of(catalog: DemoItemCatalog, id: StringName, count: int) -> Array:
	var out := []
	if count <= 0:
		return out
	var cells := catalog.cells_of(id)
	var rotatable := catalog.rotatable_of(id)
	var cap := catalog.max_stack_of(id)
	var left := count
	while left > 0:
		var take: int = mini(left, cap)
		out.append({
			"payload": payload_of(id, take),
			"cells": cells,
			"rotatable": rotatable,
		})
		left -= take
	return out


## 合并规则：同一种东西、且加起来不超过它的上限 ⇒ 塌成一块。
## 返回新 payload；返回 `null` = 不能合并（容器会改走"换位"或者拒绝）。
##
## ★ 容器拿到的只是一个 `Callable`，它不知道"上限"这个词。
static func merge_payload(catalog: DemoItemCatalog, incoming, existing) -> Variant:
	var a := id_of(incoming)
	var b := id_of(existing)
	if a == &"" or a != b:
		return null
	var total := count_of(incoming) + count_of(existing)
	if total > catalog.max_stack_of(a):
		return null
	return payload_of(a, total)


## 给容器装上一个"合并规则"（容器只认 `Callable(a, b) -> Variant`）。
## 用 Callable 而不是继承：游戏侧的规矩通常就这几行，值得为它建一个类吗？
static func merge_hook(catalog: DemoItemCatalog) -> Callable:
	return func(incoming, existing) -> Variant:
		return merge_payload(catalog, incoming, existing)
