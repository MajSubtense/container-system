class_name Placement
extends RefCounted
## 一条占位记录：**一块 m×n 的东西在哪儿、什么形状、什么方向**。
##
## ══ `payload` 是不透明的 ═════════════════════════════════
## 容器**从不读** `payload`，只负责原样带着它走：快照里带上、取出时还给你。
## 它回答"这块占位属于游戏里的哪个东西"，可以是物品实例、id、句柄，甚至 null。
## 叫什么名字、什么颜色、能不能堆叠、多少个 —— 容器一概不知道，那是游戏性设计。
##
## ══ 形状为什么存两份 ══════════════════════════════════
## `cells` 是**旋转之后**的宽×高（画图、命中、相交都用它）；
## `base_cells` 是**未旋转**的基准形状。两份并存是为了让这一条**自描述**：
## 转方向只要 `(base_cells, rotatable, rot)`，不必回头问物品表。
## 于是换物品表、热更新、读旧存档都不会让已经放好的东西"认不出自己是什么形状"。
##
## ══ 谁能改它 ═════════════════════════════════════════
## 只有 `CellGrid` 能改。`placements()` 返回的是数组副本（元素仍是同一个对象）⇒ 外部只读。

## 不透明身份。容器只搬进搬出，从不比较、从不解读。
var payload: Variant = null
## 左上角所在的格。
var anchor: Vector2i = Vector2i.ZERO
## 旋转**之后**的宽 × 高。
var cells: Vector2i = Vector2i.ONE
## 未旋转的基准形状（`cells` 由它 + `rotatable` + `rot` 推出来）。
var base_cells: Vector2i = Vector2i.ONE
## 这块能不能转 90°（形状属性，不是玩法属性："矩形能不能转"属于几何）。
var rotatable: bool = false
## 0 = 正放，90 = 转过来。
var rot: int = 0


## `cells` 与 `rot` 由基准形状推出来 ⇒ 两者不可能自相矛盾。
## 参数名避开成员名（同名会报 SHADOWED_VARIABLE_BASE_CLASS），并且刻意叫 `base` / `dir`：
## 这两个词就是 `GridShape` 里的词，读一遍就知道该传哪个形状。
static func make(new_payload: Variant, at: Vector2i, base: Vector2i,
		can_rotate: bool = false, dir: int = 0) -> Placement:
	var p := Placement.new()
	p.payload = new_payload
	p.anchor = at
	p.base_cells = GridShape.normalize(base)
	p.rotatable = can_rotate
	p.cells = GridShape.of(p.base_cells, p.rotatable, dir)
	p.rot = GridShape.stored_rot(p.base_cells, p.rotatable, dir, p.cells)
	return p


func area() -> int:
	return cells.x * cells.y


func covers(cell: Vector2i) -> bool:
	return cell.x >= anchor.x and cell.y >= anchor.y \
		and cell.x < anchor.x + cells.x and cell.y < anchor.y + cells.y


func copy() -> Placement:
	return Placement.make(payload, anchor, base_cells, rotatable, rot)


## 打印里**不带 payload** —— 它可能是任意结构，塞进日志会把行撑爆。
func _to_string() -> String:
	return "@%s %dx%d rot=%d" % [str(anchor), cells.x, cells.y, rot]
