class_name GridShape
extends RefCounted
## 网格几何：全部纯函数、无状态。**这里没有"物品"这个概念，只有矩形。**
##
## 三条约定（整模块只在这一处定义，别处不许再写一份）：
##   ① 块的尺寸 = `base_cells`（宽 × 高，最小 1×1），**未旋转**的那个形状；
##   ② 方向只有两个状态：0（正放）/ 90（转过来）。矩形转两次回到原样，
##      所以没有 180 / 270；`rot = -1` 单独表示「没点名方向」；
##   ③ 形状由**数据**决定：`rotatable = false` 的块，任何方向参数都拿不到旋转形状。
##      「手里那个方向」不许绕过数据 —— 否则界面能转、容器不认，拖影就会说谎。


static func normalize(cells: Vector2i) -> Vector2i:
	return Vector2i(maxi(1, cells.x), maxi(1, cells.y))


## 方的东西转不转一个样 ⇒ 不提供方向（`rotate_problem()` 用的也是这条）。
## ★ 参数一律叫 `base`：传进来的必须是**未旋转**的基准形状，
##   把已经转过的 `Placement.cells` 传进来会让方向整体错位 90°。
static func can_rotate(base: Vector2i, rotatable: bool) -> bool:
	return rotatable and base.x != base.y


## 这件东西在 `rot` 下**实际**占什么形状。`rot < 0` = 没点名 ⇒ 正放。
static func of(base: Vector2i, rotatable: bool, rot: int) -> Vector2i:
	var c := normalize(base)
	if rot >= 0 and rotatable and posmod(rot, 180) != 0:
		return Vector2i(c.y, c.x)
	return c


## 要**记下来**的方向：必须与 `of()` 给出的是同一个答案。
## 旧代码在这条上踩过坑：记录写 90、实际形状却是正的 ⇒ 拿起来被画成横的。
static func stored_rot(base: Vector2i, rotatable: bool, requested_rot: int, used_shape: Vector2i) -> int:
	if requested_rot >= 0 and rotatable:
		return 90 if posmod(requested_rot, 180) != 0 else 0
	return 0 if used_shape == normalize(base) else 90


static func contains(grid: Vector2i, anchor: Vector2i, size: Vector2i) -> bool:
	return anchor.x >= 0 and anchor.y >= 0 \
		and anchor.x + size.x <= grid.x and anchor.y + size.y <= grid.y


## 两个矩形相交 ⇔ 不分离。
static func intersects(a_pos: Vector2i, a_size: Vector2i, b_pos: Vector2i, b_size: Vector2i) -> bool:
	return a_pos.x < b_pos.x + b_size.x and b_pos.x < a_pos.x + a_size.x \
		and a_pos.y < b_pos.y + b_size.y and b_pos.y < a_pos.y + a_size.y


## 这件东西占了哪些格（行优先）。画图与判据共用，别各写一份。
static func cells_at(anchor: Vector2i, size: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dy in size.y:
		for dx in size.x:
			out.append(anchor + Vector2i(dx, dy))
	return out
