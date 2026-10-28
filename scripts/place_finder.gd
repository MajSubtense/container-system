class_name PlaceFinder
extends RefCounted
## 找位策略（Strategy）。`find()` 必须**只读**：它不改容器、不做提交。
##
## 为什么单独立一个接口：自动放入算法是整模块里**唯一**会因游戏不同而变的东西
## （背包要「塞得进就行」，仓库可能要「贴着已有块排整齐」，载具可能要「从后往前」）。
## 容器只调 `finder.find()`，换算法 = 换一个对象，`CellGrid` 一行不用改。
##
## 返回 `{"anchor": Vector2i, "cells": Vector2i, "rot": int}`；找不到返回 `{}`。
## `fits` 是容器绑好的判定 `Callable(shape, anchor) -> bool`（已经带上 ignore 语义）。


func find(_grid: Vector2i, _cells: Vector2i, _rotatable: bool, _fits: Callable) -> Dictionary:
	return {}
