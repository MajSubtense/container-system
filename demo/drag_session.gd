class_name DemoDragSession
extends RefCounted
## 【**游戏侧** · 不属于容器模块】**跨板拖拽的共享状态**。
##
## 为什么要这个对象：拖动会横跨两个 Control，"从 A 拿起 → 落到 B"这件事必须由
## 一个第三方记住"拿的是谁的哪一块"。让两块板各记一半，迟早出现
## "A 以为在拖、B 以为没拖"这种看不出原因的 bug —— 而且只在跨板时才出现。
##
## 它**只存状态、不含判定**："能不能放下"永远问 `GridOps.problem()`。
## 它也不认识任何容器规则，只认识坐标和下标。

## 拿起的来源板（用 `==` 比较即可）
var source: Control = null
## 来源网格（跨网格搬运时 `GridOps.move` 的第一个参数）
var source_container: CellGrid = null
## 在来源网格里的键（下标）
var key: int = -1
## 当前方向：0 / 90。
## ★ 拖动中**永远是具体方向，不会是 -1** —— 否则预览画的是正放、
##   松手时容器自作主张转了一下，玩家就会看到"幽灵块说谎"。
var rot: int = 0
## 鼠标全局坐标，由来源板在拖动中持续写入
var mouse := Vector2.ZERO
## 抓取偏移（像素）：**块左上角 → 鼠标**的向量，拿起时算一次，拖动中不变。
## ★ 没有它就只能把"鼠标所在的格"当成块的左上角 ⇒ 抓 2×3 的箱子时
##   锚点会凭空多出 (1,1)，整块向右下跳；落点再按这个偏移判，看起来就是
##   "怎么拖都挪不动一格，一松手又弹回原位"。
var grab_offset := Vector2.ZERO
## 所有可落点，由宿主注册
var boards: Array[Control] = []


func is_active() -> bool:
	return source != null


## `offset` = 鼠标相对**块左上角**的像素偏移。手指/鼠标抓在块的哪个位置，
## 拖动全程就该保持那个位置 —— 否则块会跳，且"只挪一格"永远做不到。
func begin(board: Control, container: CellGrid, cell_key: int, direction: int,
		offset: Vector2 = Vector2.ZERO) -> void:
	source = board
	source_container = container
	key = cell_key
	rot = 0 if direction == 0 else 90
	grab_offset = offset


func clear() -> void:
	source = null
	source_container = null
	key = -1
	rot = 0
	grab_offset = Vector2.ZERO


func flip() -> void:
	rot = 0 if rot == 90 else 90


## 松手落在哪块板上：**纯几何**判断。
##
## 这里刻意不用 `gui_get_hovered_control()` —— 那样"能不能落"就取决于
## 控件各自的 `mouse_filter`，拖到按钮或标签上会莫名变成"拖到容器外"。
## 网格该不该收下这一块，是模型的事；鼠标在不在这个矩形里，是几何的事。
func board_at(global_pos: Vector2) -> Control:
	for b in boards:
		if is_instance_valid(b) and Rect2(b.global_position, b.size).has_point(global_pos):
			return b
	return null
