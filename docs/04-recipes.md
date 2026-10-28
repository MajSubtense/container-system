# 04 · 常见做法

这一段是"抄作业"。每节都是**能直接跑的形状**，变量名按 demo 的习惯来：

```gdscript
var bag: CellGrid          # 玩家背包
var chest: CellGrid        # 箱子
var catalog: DemoItemCatalog
```

如果还没有这些，先看 [01 · 快速接入](01-quickstart.md)。

---

## 1. 拾取：掉落物 → 放进背包

真实流程有四步，模块只管第 3、4 步：

```gdscript
func pickup(drop: Dictionary) -> void:
	var id: StringName = drop["id"]
	var n: int = drop["count"]

	# ① 路由：这块该进哪个容器（游戏规则，一行 if）
	var target := chest if id == &"rifle" else bag

	# ② 切块：一堆 N 个要占几格（游戏规则，见下面的说明）
	var blocks := blocks_of(id, n)

	# ③ 放入：先直接放，放不下才重排
	var res := GridOps.insert_fitting(target, blocks)

	# ④ 余量必须处理 —— 绝不静默丢弃
	var left := 0
	for b in res["left"]:
		left += int(b["payload"]["count"])
	if left > 0:
		spawn_drop_on_ground(id, left)
```

`blocks_of()` 是游戏侧的东西，12 行就够（demo 里在 `DemoItemRules`）：

```gdscript
func blocks_of(id: StringName, count: int) -> Array:
	var out := []
	var cells := catalog.cells_of(id)       # 基准形状，如 Vector2i(1, 1)
	var rot := catalog.rotatable_of(id)
	var cap := catalog.max_stack_of(id)
	var left := count
	while left > 0:
		var take := mini(left, cap)
		out.append({"payload": {"id": id, "count": take},
			"cells": cells, "rotatable": rot})
		left -= take
	return out
```

> **为什么切块不进模块**："上限 99" 是设计参数。有些游戏允许超堆、有些按重量算、
> 有些按品质分堆。模块里写死一套，每款游戏都得先改它。

`insert_fitting()` 的 `ok` 表示**全部放下**。`ok = false` 时 `placed` 可能大于 0：

```gdscript
if not res["ok"]:
	print("只放下了 %d / %d 块：%s" % [res["placed"], blocks.size(), res["reason"]])
```

---

## 2. 跨容器拖拽

拖拽横跨两块板，最容易出的 bug 是"A 以为在拖、B 以为没拖" —— 而且只在跨板时出现。
解法：**状态不归任何一块板**，放到一个共享对象里。

```gdscript
class_name DragSession
extends RefCounted

var source: Control = null          # 来源板（用 == 比较）
var source_container: CellGrid = null
var key: int = -1
var rot: int = 0                    # ★ 拖动中必须是具体的 0 / 90
var mouse := Vector2.ZERO
var boards: Array[Control] = []     # 所有可落点，宿主注册

func is_active() -> bool: return source != null
func flip() -> void: rot = 0 if rot == 90 else 90
func clear() -> void:
	source = null
	source_container = null
	key = -1
	rot = 0

## 松手落在哪块板上：纯几何。
func board_at(global_pos: Vector2) -> Control:
	for b in boards:
		if is_instance_valid(b) and Rect2(b.global_position, b.size).has_point(global_pos):
			return b
	return null
```

每块板只回答两个问题：

```gdscript
# 按下：我是来源
func _begin_drag(pos: Vector2) -> void:
	var i := container.key_at_cell(cell_at(pos))     # ← 位置索引：格 → 第几块
	if i < 0:
		return
	var p := container.placements()[i]
	# ★ 记下"按下点 − 块左上角"。抓在块的哪儿，整段拖动就一直保持在那儿。
	var grab := pos - layout.block_rect(p.anchor, p.cells).position
	session.begin(self, container, i, p.rot, grab)    # 拿起时的方向就是预览方向
	session.mouse = get_global_mouse_position()

# 拖动中：只有来源板处理事件
func _input(event: InputEvent) -> void:
	if not session.is_active() or session.source != self:
		return
	if event is InputEventMouseMotion:
		session.mouse = get_global_mouse_position()
		redraw_all_boards()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_R:
		session.flip()
		redraw_all_boards()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_drop_at(get_global_mouse_position())

# 松手
func _drop_at(global_pos: Vector2) -> void:
	var from_grid := session.source_container
	var key := session.key
	var rot := session.rot
	var idx := from_grid.index_of_key(key) if from_grid != null else -1
	var p: Placement = from_grid.placements()[idx] if idx >= 0 else null
	var target := session.board_at(global_pos) as Board
	# ★ 问的是"块的**左上角**落在哪格"，不是"鼠标落在哪格"（见要点 1）
	var cell := target.anchor_at_global(global_pos) if target != null else Vector2i(-1, -1)
	session.clear()
	redraw_all_boards()

	if p == null or target == null or cell.x < 0:
		return                                   # 丢在容器外 / 落在边框上

	var order := {"from": key, "cell": cell, "rot": rot}
	var why := GridOps.problem(from_grid, target.container, order)
	if why != "":
		status.emit(why, false)                  # 理由直接给玩家看
		return
	GridOps.move(from_grid, target.container, order)
```

四个要点：

1. **落点算的是块的左上角，不是鼠标所在的格**。这是最容易漏、症状也最怪的一步：

   ```gdscript
   func anchor_at_global(gpos: Vector2) -> Vector2i:
       return layout.cell_at_snapped(gpos - global_position - session.grab_offset,
           container.grid_size())
   ```

   直接拿鼠标格当锚点，抓一块 3×2 的木箱中间就等于把锚点算成 `原锚点 + (1,1)`
   —— 整块向右下跳，跳过去往往越界或压到别的东西，于是被拒、弹回原位。玩家会描述成
   「怎么都挪不动一格」。用 `cell_at_snapped()` 而不是 `cell_at()`：块的左上角是连续量，
   正好压在 4px 格缝上完全可能，严格版会让"差两个像素"变成"整块放不下"。

   **同一个函数必须同时给预览和落点用**，否则幽灵块和结果会分家。

2. **只在来源板处理松手**（`session.source == self`），否则两块板会重复处理同一次事件。
3. 拖动中的鼠标事件要在 `_input()` 里接 —— `_gui_input()` 只在指针还在本控件上时才来，
   而拖动时鼠标早就跑出去了。
4. 窗口失焦（Alt+Tab）会丢掉那次松手，主动收尾：

```gdscript
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and session.source == self:
		session.clear()
```

对应的可视化在 [05 · 接界面](05-view.md#拖影)。

---

## 3. 同容器拖动 / 原地旋转

同容器不用 `GridOps`（它也会自动转交），直接问网格：

```gdscript
# 拖到另一格
var why := bag.move_to_cell_problem(key, target_cell)
if why == "":
	bag.move_to_cell(key, target_cell)

# 原地转（右键）
var res := GridOps.rotate(bag, key)      # 或 bag.rotate(key)
if not res["ok"]:
	status.emit(res["reason"], false)
```

同容器搬运**不会自动换方向**：`move_to_cell(key, cell, rot = -1)` 的 `-1` 是
**保持原方向**（这块已经在网格里了，它"原来"朝哪就朝哪）。想让它在落点自动适配，
先转再搬：

```gdscript
if bag.rotate_problem(key) == "":
	bag.rotate(key)                 # 转到想要的方向
bag.move_to_cell(key, target_cell)  # 再搬
```

跨容器的 `GridOps.move(..., {"cell": c, "rot": -1})` 是另一回事 —— 那一路走
`place_at`，`-1` 真的会"正放不行就转过来"。

---

## 4. 「整理」按钮（纯重排）

不加新东西，只把现有块排紧：

```gdscript
func on_repack() -> void:
	var plan := GridRepacker.plan(bag)          # 只读，一行都不改网格
	if not plan["ok"]:
		status.emit("整理不了：%s" % plan["reason"], false)
		return
	var err := bag.restore(plan["layout"])      # 全或无
	if err != "":
		status.emit("整理失败（布局被否决，背包没变）：%s" % err, false)
		return
	status.emit("挪了 %d 块（%s）" % [plan["moves"], plan["attempt"]], true)
```

`plan()["layout"]` 和 `snapshot()` 同格式 —— 所以也可以直接存档、回放、做撤销。

**别在拾取之后自动整理**：玩家刚看到东西塞进某个空位，下一秒整板洗牌，会以为出了 bug。
整理应该是玩家的显式动作。

---

## 5. 多容器与拾取路由

容器之间不知道彼此存在。路由是游戏侧的事：

```gdscript
func stash_target(id: StringName) -> CellGrid:
	if id == &"rifle" or id == &"bow":
		return weapon_rack
	if catalog.is_food(id):
		return fridge
	return bag

func pickup(drop: Dictionary) -> void:
	var target := stash_target(drop["id"])
	var blocks := blocks_of(drop["id"], drop["count"])
	var res := GridOps.insert_fitting(target, blocks)
	# 目标满了？要不要试第二个容器？也是游戏规则：
	if not res["ok"]:
		var overflow := GridOps.insert_fitting(backup_bag, res["left"])
		res["left"] = overflow["left"]
```

跨容器**移动**（不是拾取）用 `GridOps.move` / `move_fitting`，它们的第一个参数是来源。

---

## 6. 准入规则：这个容器不收某类东西

```gdscript
bag.accepts = func(payload) -> bool:
	return ItemRules.id_of(payload) != &"rifle"

# 问一句（不涉及位置）
if bag.admits(payload):
	…

# 带位置的判定也会先问它
bag.can_place_at(payload, Vector2i(0, 0), Vector2i(2, 1))
```

`accepts` 是**拥有这一格的那一层**的规矩。模块只负责问一句，不负责知道"枪"是什么，
也不负责写这句话的含义。

⚠️ 它拿到的是**任意 `Variant`**，所以别直接和字面量比较：

```gdscript
# ❌ payload 是整数（比如合并后的计数）时直接崩：
#    Invalid operands 'int' and 'StringName' in operator '!='
bag.accepts = func(p) -> bool: return p != &"rifle"

# ✅ 先归一化，任何类型都安全
bag.accepts = func(p) -> bool: return ItemRules.id_of(p) != &"rifle"
```

`id_of()` 对不认识的 payload 返回 `&""`，于是"不是枪" ⇒ 照收。

⚠️ 它必须挡住**所有**进入路径，包括重排。模块内部已经保证了这一点
（`insert_fitting` / `move_fitting` 先筛准入再重排），但如果你是**自己**直接调
`GridRepacker.plan()` + `restore()`，就得自己先 `admits()` 一遍。
原因见 [06 · 坑](06-pitfalls.md#5-准入规则被重排绕过)。

---

## 7. 堆叠合并

```gdscript
# 合并规则：同 id、且加起来不超过上限
bag.merge_rule = func(incoming, existing) -> Variant:
	if ItemRules.id_of(incoming) != ItemRules.id_of(existing):
		return null
	var total := ItemRules.count_of(incoming) + ItemRules.count_of(existing)
	if total > catalog.max_stack_of(ItemRules.id_of(incoming)):
		return null
	return {"id": ItemRules.id_of(incoming), "count": total}
```

返回新 payload = 能合，返回 `null` = 不能合。之后：

- **同容器**拖到同种东西上：两块塌成一块（源消失），`moved = 1`
- **跨容器**拖到同种东西上：`GridOps.move` 的 `{"from": 3, "to": 1}` 路径，同样塌成一块
- **合不了**：同容器改走换位；跨容器直接拒绝

⚠️ 必须是**纯函数**：判定（`can_merge_at`）和提交（`merge_into`）各问一次，
两次结果必须一致。别在里面改状态、别在里面发信号。

"那一堆已经满了"这话该不该说、怎么说，是游戏侧的事（demo 在 `grid_board.gd` 里
提前检查并给一句贴心话，否则拖到满堆上会悄悄变成换位，玩家莫名其妙）。

---

## 8. 存读档

### 走 JSON（存档文件、跨进程）

```gdscript
func save_game(path: String) -> void:
	var data := {
		"bag": bag.snapshot(),
		"chest": chest.snapshot(),
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()

func load_game(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return
	# ★ 不要预检：restore 本身就是全或无的
	var e1 := bag.restore(parsed["bag"])
	var e2 := chest.restore(parsed["chest"])
	if e1 != "" or e2 != "":
		push_warning("读档失败：%s %s" % [e1, e2])
```

**必须做类型归一化**（容器不会替你做，因为它不认识 payload）：

```gdscript
static func id_of(payload) -> StringName:
	return StringName(str(payload.get("id", "")))     # StringName 会被 JSON 变成 String

static func count_of(payload) -> int:
	return int(payload.get("count", 0))               # 整数会被 JSON 读成浮点：1 → 1.0
```

### 走 `var_to_str`（保类型，单人存档够用）

```gdscript
var text := var_to_str(bag.snapshot())
var err := bag.restore(str_to_var(text))
```

保 `StringName` / `Color` / `Vector2i` 等类型，代价是那串东西不能给别人读、
跨引擎不通用。两条路选一条，写进你的存档规范。

### 首次进入 / 空档

```gdscript
# 空数组 = 清空（会发一次 changed）
bag.restore([])
```

---

## 9. 批量搬运（把一整板倒过去）

要点：一件搬不动**不该挡住后面所有件**。所以是"从前往后找第一块搬得成的"，
不是"从第 0 块开始、失败就停"：

```gdscript
func move_all(from: CellGrid, to: CellGrid) -> void:
	var guard := 0
	while not from.is_empty() and guard < 400:
		guard += 1
		# ① 找第一块能直接搬的（不动目标已有块）
		var k := -1
		for i in from.count():
			if GridOps.move(from, to, {"from": i})["ok"]:
				k = i
				break
		if k >= 0:
			continue
		# ② 一块都搬不动了 ⇒ 只为一个块重排目标
		var fit := GridOps.move_fitting(from, to, {"from": 0})
		if not fit["ok"]:
			break        # 真塞不下了；剩下的留在 from 里
```

`guard` 是防御性上限：`move_fitting` 一边成功一边改变网格，理论上会收敛，
但循环里加个上限比事后查"为什么卡住了"便宜。

**这里用 `move_fitting` 是对的**：玩家点的是"整板倒过去"，接受了位置跳动。
拖拽落点就不能用（见下一节）。

---

## 10. 取出（不是搬运）

```gdscript
var taken := bag.remove_at(key)
if taken != null:
	spawn_drop(taken.payload, taken.anchor)     # 游戏侧：生成掉落物
```

`remove_at` 返回 `Placement` 或 `null`。**"取出来"不是"成没成"**，所以它不返回 Result。

清空整板：

```gdscript
for p in bag.placements():
	spawn_drop(p.payload, p.anchor)
bag.clear()          # 一次清空 = 一次 changed
```

注意顺序：先记下内容，再 `clear()`。`clear()` 之后 `placements()` 就空了。

---

## 11. 扩容 / 换尺寸

没有 `resize()` —— 网格尺寸是构造参数，改了它所有位置的含义都要重算。
正确做法是新建一个再还原：

```gdscript
func upgrade_bag(old: CellGrid, new_size: Vector2i) -> CellGrid:
	var bigger := CellGrid.new(new_size)
	bigger.finder = old.finder
	bigger.accepts = old.accepts
	bigger.merge_rule = old.merge_rule
	var err := bigger.restore(old.snapshot())
	if err != "":
		push_error("扩容失败（原有内容放不进新尺寸）：%s" % err)
		return old
	return bigger
```

`restore()` 是全或无的，所以"扩容失败"不会毁掉旧背包。
缩小尺寸同理 —— 装不下的那些会让整次还原失败，需要你先决定丢什么。

---

## 12. 给玩家看"还能放几个"

```gdscript
var n := bag.room_for(Vector2i(1, 1))         # 还能放几个 1×1
label.text = "还能放 %d 个" % n
```

`room_for()` 是**干跑**：在副本上反复真放一遍，和 `place_auto` 同源。
所以它不会出现"说能放 2 个，实际放不进"。

⚠️ 每次调用都会跑一遍装箱。放在 `changed` 里更新是可以的（玩家操作频率低），
但**不要**在 `_process()` 里每帧调。
