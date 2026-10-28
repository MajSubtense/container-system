class_name FirstFitFinder
extends PlaceFinder
## 默认找位：**行优先 + 旋转兜底**。
##
## 顺序是语义，不是实现细节：
##   ① 先在整个网格里找「正放」放得下的第一个锚点（y 外、x 内）；
##   ② 全都放不下、且这件东西可旋转时，再**从头**扫一遍「转 90°」的形状。
## ⇒ 放进去的东西总落在「最靠上、再最靠左」的空位，同一串操作永远得到同一个布局
##   （搬运往返才能回到同一格，存档读档才不会慢慢漂）。
##
## 注意：不是「每个锚点都试两个方向」。先整体试正放，是让正放优先于旋转 ——
## 否则一格里能竖着塞进去的东西，会被横着塞到别的角落。

func find(grid: Vector2i, cells: Vector2i, rotatable: bool, fits: Callable) -> Dictionary:
	var base := GridShape.normalize(cells)
	var shapes: Array[Vector2i] = [base]
	if GridShape.can_rotate(base, rotatable):
		shapes.append(Vector2i(base.y, base.x))
	for idx in shapes.size():
		var shape: Vector2i = shapes[idx]
		if shape.x > grid.x or shape.y > grid.y:
			continue
		for y in grid.y:
			for x in grid.x:
				var anchor := Vector2i(x, y)
				if bool(fits.call(shape, anchor)):
					return {"anchor": anchor, "cells": shape, "rot": 0 if idx == 0 else 90}
	return {}
