# 06 · 坑

每一条都对应一个真实踩过的 bug（大多数是旧项目里踩的），按"发现它有多难"排序 ——
越靠前越难查，因为日志全绿、模型自洽。

---

## 1. 点偏一格

**症状**：点格子的右边缘，选中的是左边那格；或者缝里点一下，选中了上一格。

`GridLayout.cell_at()` 的边界判定用了 `>=`：

```gdscript
if inside.x >= cell_size.x or inside.y >= cell_size.y:
	return Vector2i(-1, -1)      # 恰好落在右/下边界上的那一点属于**缝隙**
```

写 `>` 的话，无缝时看不出来，一加 `spacing` 就变成"点边缘选中了相邻格"。

**别自己写这段数学。** 模块把它放在 `GridLayout` 里，就是为了让你没有机会写错一次。

### 更像 bug 的那一版：拖块时把"鼠标所在的格"当成锚点

**症状**：小东西拖得动，2×3 以上的块"怎么都挪不动一格"，一松手就弹回原位；
或者松手前块先往右下跳一下。

原因是落点算成了"鼠标在哪格、块就落哪格"，而块的位置是**左上角**：

```gdscript
# ❌ 鼠标格 = 锚点
var cell := layout.cell_at(mouse_local, grid)

# ✔ 块的左上角 = 鼠标 − 抓取偏移
var cell := layout.cell_at_snapped(mouse_local - session.grab_offset, grid)
```

抓在 3×2 的箱子中间时，鼠标格比锚点多出 `(1,1)`：整块向右下跳，跳过去常常越界或压到
别的东西，于是被拒、弹回原位 —— 玩家的描述是"挪不动"。1×1 的块完全看不出这个 bug，
所以它很容易活到玩家手里。

`grab_offset` 在按下时算一次（`pos - layout.block_rect(p.anchor, p.cells).position`），
之后整段拖动保持不变。**预览和落点必须调同一个函数**，否则幽灵块会再说一次谎。
用 `cell_at_snapped()` 而不是 `cell_at()`：左上角是连续量，正好压在 4px 格缝上完全可能。

还有一层会叠加上来：拖动中**源块仍然在模型里**（视图只是把它画成空槽）。任何
"落点上有没有同类东西"的检查都要跳过它自己，否则 `max_stack = 1` 的木箱挪一格
必然命中自己，被判定成"那一堆已经满了"。

---

## 2. 视图自己做了判定

**症状**：拖影是绿色的，松手却提示"放不下"。或者反过来，红色拖影但能放下。

原因通常是视图自己写了一段"看起来对"的判断：

```gdscript
# ❌ 这一段漏了：旋转、越界、重叠、准入、ignore 自己
if grid.at_cell(cell) == null:
	# 认为能放
```

旧项目的 `ContainerPainter._shape_of()` 漏了 `rotatable`，拖一个固定方向的 1×3 时，
拖影画成横的、放下去是竖的。

**规则**：视图只负责"问"和"上色"，判定一律来自模块。而且 `GridOps.problem()` 与
`GridOps.move()` 共用同一段计划，所以 `problem() == ""` ⟺ `move()` 会成功。
这条同源关系是结构保证的，别在中间插一段自己的判断把它破坏掉。

---

## 3. 拖拽落点用了重排版

**症状**：拖动时预览好端端的，松手之后**别的块跳位置了**，甚至玩家觉得"我放的是这儿，
怎么东西跑到那儿去了"。

错在松手时调了 `move_fitting()` / `insert_fitting()`。重排会挪动目标里已有的块。
代价本身合理（整板搬运、整理按钮就该这样），但**必须是玩家显式选择的动作**：

```gdscript
# ✅ 拖拽落点
var res := GridOps.move(from, to, order)

# ✅ "整板倒过去"按钮、拾取掉落
var res := GridOps.move_fitting(from, to, {"from": 0})
```

`move_fitting()` 在 `order` 里点名了 `cell` / `to` 时会退化成 `move()` ——
这是一个安全网，但别指望它：**你自己写的调用点才是决定性的**。

---

## 4. 改了 `placements()` 里的东西

**症状**：某一格永远放不下；或者东西画在 A 处、碰撞在 B 处。

```gdscript
var ps := grid.placements()      # 数组是副本
ps[0].anchor = Vector2i(0, 0)    # ❌ 元素是网格持有的那个对象，你改的是真数据
```

数组是副本（`assign` 出来的新 `Array`），但**元素仍是 `Placement` 对象本身**。
直接改它：网格的索引不会更新（其实索引是现算的，所以更糟 —— 数据和信号不一致），
界面也不会重绘（没发 `changed`）。

要改位置，走 `move_to_cell()` / `GridOps.move()`。

---

## 5. 准入规则被重排绕过

**症状**：明明写了"背包不收步枪"，批量拾取时枪还是进了背包 —— 而且只在
"放不下、需要重排"的时候发生。

原因链条很隐蔽：

1. `restore()` **刻意不问** `accepts` —— 存档里的东西本来就该待在原来的格子里。
   规则改严之后读档把它们扔掉才是灾难。
2. 两条重排路径（`insert_fitting` / `move_fitting`）都是**借道 `restore()`** 提交布局的。
3. ⇒ "放不下就重排"一度变成了**把被拒的东西塞进去的后门**。

模块现在的顺序是：**先问准入 → 再讨论放不收得下一块 → 最后才重排**。

但如果你是**自己**直接调 `GridRepacker.plan()` + `restore()`，这条顺序得自己保证：

```gdscript
# ❌ 绕过了 accepts
var plan := GridRepacker.plan(grid, incoming)
grid.restore(plan["layout"])

# ✅
var admitted := incoming.filter(func(b): return grid.admits(b["payload"]))
var plan := GridRepacker.plan(grid, admitted)
```

判据第 10 组 ③b 钉着这一条（`insert_fitting` / `move_fitting` 必须被挡住，
`restore()` 必须放行）。

---

## 6. JSON 把整数读成浮点

**症状**：读档后 `if payload["count"] == 1` 不成立。打印出来是 `1.0`。

```gdscript
JSON.stringify({"count": 1})     # → {"count":1}
JSON.parse_string('{"count":1}') # → {"count": 1.0}
```

这是 **Godot 的 JSON 解析行为**，不是模块的。同理 `StringName` 会变成 `String`，
`Color` 会变成字符串。

容器**不会**替你修 payload 的类型 —— 修它就得先认识它，而它是不透明的。
所以归一化是游戏侧的事：

```gdscript
static func count_of(payload) -> int:
	return int(payload.get("count", 0))

static func id_of(payload) -> StringName:
	return StringName(str(payload.get("id", "")))
```

想完全保类型：`var_to_str(grid.snapshot())` / `str_to_var(text)`。
两条路选一条，写进你的存档规范，别混用。

---

## 7. 把键存下来跨帧用

**症状**："我上次拖的是第 3 块，怎么变别的了" / 拖走一块之后，另一块突然高亮。

键就是 `placements()` 的下标，**删除会让后面的前移**：

```gdscript
grid.remove_at(0)
# 原来的第 1 块现在是第 0 块，第 2 块是第 1 块…
```

规则：

- ✅ 一次操作内用键（拿起 → 放下，这一小段里没人删东西）
- ❌ 存进成员变量跨帧用

跨帧要认人，用锚点或 payload：

```gdscript
var idx := grid.key_at_cell(saved_anchor)
```

有个例外：**同容器换位是交换锚点、不重排数组**，键不漂。合并会让源那块消失，后面的前移。

---

## 8. `rot = -1` 在两处含义不同

| 调用 | `rot = -1` 的意思 |
|---|---|
| `place_at(payload, anchor, cells, rotatable, -1)` | **自己适配**：正放不行再转过来 |
| `GridOps.move(..., {"rot": -1})` | 同上（走的是 `place_at`） |
| `move_to_cell(key, anchor, -1)` | **保持原方向**（这块已经在网格里了，有"原来的方向"） |

于是 `move_to_cell` 不会帮你把竖着的 1×3 变成横的 —— 它在网格里已经有"原来的方向"了。
同网格内想换方向，**先转再搬**：

```gdscript
if grid.rotate_problem(key) == "":
	grid.rotate(key)
grid.move_to_cell(key, target_cell)
```

第 3 行的 `GridOps.move(grid, grid, {...})` 会转交到 `move_to_cell`，所以同样是
"保持原方向"，不会自动适配。只有**跨容器**的 `{"cell": c, "rot": -1}` 走 `place_at`，
才真的会"正放不行就转过来"。

拖动中的 `session.rot` 也不能是 `-1`（见 [05](05-view.md#为什么拖动中的方向必须是-0--90)）。

---

## 9. 以为"面积够就能放下"

**症状**：2×2 的背包，已经占了一格，还剩 3 格，想放 1×3 —— 提示放不下。
看着像 bug，其实**几何上永远放不下**：3 个格是 L 形，1×3 需要一条直线。

这类"面积够、形状无解"的情况在装箱里是常态，跟算法聪不聪明无关。
判据第 2 组用**穷举所有锚点 × 两个方向**证明了这一点。

所以失败理由分三种，看清楚了再决定要不要重排：

| 理由 | 重排能救吗 |
|---|---|
| `网格只有 2×2：1×3 放不下，转过来 3×1 也不行` | 不能（网格尺寸就不够） |
| `空位不够：2×3 要 6 格，只剩 4 格` | 腾空了才行 |
| `还剩 3 格空位，但拼不出 1×3（空位被隔碎了）` | **能** |

只有第三种是"重排能救"的。把三种混成一句"放不下"，会让人一直去调算法。

---

## 10. 想搬"3 个过去"

**症状**：想找 `move(key, count)` 之类的接口。

**块是原子的。** 一个格子里就是一个东西，没有"搬一部分"：

```gdscript
# 拆堆是游戏的事
var p := grid.remove_at(key)
var total := count_of(p.payload)
spawn_drop(id, total)              # 或者拆成两块再放回去
```

跨容器搬运同理 —— 只搬整块。

---

## 11. 在循环里逐块删 / 逐块放

**症状**：清空一个 33 格的背包，界面重绘了 33 次，肉眼可见地卡一下。

```gdscript
# ❌ 33 次 changed
while not grid.is_empty():
	grid.remove_at(0)

# ✅ 1 次
grid.clear()
```

同理批量放入：`GridOps.insert_all()` / `insert_fitting()` 是"一个动作"的语义，
但内部**每个块**的 `place_auto` 会各发一次信号。如果你要"一口气放 20 块只重绘一次"，
就自己攒：把它们放到一个临时网格，再 `restore()` 过去；或者视图侧做一帧合并
（`queue_redraw()` 本身就是延迟到帧末的，通常够了）。

---

## 12. 在 `changed` 里改网格

**症状**：栈溢出，或者界面疯狂重绘。

`changed` 是"内容变了"的通知，处理函数里再改网格就会再发一次 → 递归。

要"放进去之后自动整理"，请在**调用侧**排顺序：

```gdscript
GridOps.insert_fitting(bag, blocks)
if auto_tidy:
	var plan := GridRepacker.plan(bag)
	if plan["ok"]:
		bag.restore(plan["layout"])
```

---

## 13. `base_cells` 和 `cells` 传反了

| 参数位置 | 要的是哪个 |
|---|---|
| `place_auto(payload, cells, …)` / `place_at(…, cells, …)` | **base** |
| `can_place_at(…, cells, …)` / `room_for(cells, …)` | **base** |
| `insert_all` / `insert_fitting` 的 `blocks[i]["cells"]` | **base** |
| `GridShape.of(base, …)` / `can_rotate(base, …)` | **base** |
| `GridShape.cells_at(anchor, size)` | 实际形状（`cells`） |
| `fits_at(cells, anchor)` | 实际形状（**已旋转**） |
| `block_rect(anchor, cells)` | 实际形状（`Placement.cells`） |

传反的后果：**方向整体错位 90°** —— 竖着的东西画成横的、或者"能放"变"不能放"。
`GridShape` 的参数一律叫 `base`，就是为了让这个错误在调用处就看得出来。

`GridRepacker` 内部特意取 `base_cells`：

```gdscript
# ❌ 拿已旋转的当基准，方向标记会整体错位
"base": p.cells
# ✅
"base": p.base_cells
```

---

## 14. 给方的东西写了旋转逻辑

3×3 转不转一个样，所以 `rotate()` 直接拒绝：

```
"3×3 是方的，转不转一个样"
```

`rotatable = false` 的块同样拒绝。这不是"没实现"，是**不该有**：让界面能转、
容器却拿不到旋转形状，"幽灵块说谎"就又回来了。

给玩家看的按钮该在这种时候置灰 —— 用 `rotate_problem(key) != ""` 判断。

---

## 15. 以为跨容器会换位

**症状**：把 A 拖到 B 里一块别的东西上，期望"两个东西互换位置"，结果被拒绝：
`那一格是别的东西 —— 跨容器只能合并，不能换位（请落在空格上）`。

这是**故意的**：对面那块东西被换进你的背包，玩家几乎不会预期这个。
同容器才换位（`move_within(from, to)`）。

要跨容器交换，自己在游戏侧写两步：先搬到临时空位，再搬另一块。

---

## 16. 读档不清理被规则拒收的东西

`restore()` **不问 `accepts`**。所以规则改严之后，旧存档里那些"现在不该在这里"的东西
会照样读回来。

这是设计和取舍：读档时把玩家的东西扔掉是灾难，而且可能触发连锁（合并规则变了、
堆叠上限降了……）。**要不要做"存档迁移"是游戏自己的逻辑**：

```gdscript
bag.restore(snapshot)
# 迁移：把不再允许的东西挪出去（游戏侧决定）
for i in range(bag.count() - 1, -1, -1):
	var p := bag.placements()[i]
	if not bag.admits(p.payload):
		var taken := bag.remove_at(i)
		spawn_drop(taken.payload, taken.anchor)
```

---

## 17. 在 `_process()` 里调 `room_for()`

`room_for()` 会在一份副本上反复真放一遍（与 `place_auto` 同源，精确）。
它对"玩家操作频率"是完全够用的，但**不是每帧该做的事**。

放在 `changed` 里更新 HUD 数字是对的：

```gdscript
func _on_changed() -> void:
	label.text = "还能放 %d 个" % bag.room_for(Vector2i(1, 1))
```

---

## 18. GDScript 自身的三个坑（接 demo 时都撞过）

这三条不是模块的问题，但接 UI 时几乎一定会遇到：

| 报错 | 原因 | 修法 |
|---|---|---|
| `UNUSED_PARAMETER` | 参数没用到 | 删掉，或者真的用上（demo 里 `mini(fs, 13)` 复用了一个原本闲置的字号） |
| `SHADOWED_VARIABLE_BASE_CLASS` | 局部变量 `name` 盖住了 `Node.name` | 改名（`item_name`） |
| `INCOMPATIBLE_TERNARY` | 三元两边类型不同：`StringName` 与 `String` 混用 | 显式标注：`var label: String = …`。**这条在 GDScript 里是错误不是警告** |
| `Invalid operands 'int' and 'StringName'` | 注入的 `accepts` / `merge_rule` 拿到的是**任意 Variant**，却直接和字面量比较 | 先归一化：`ItemRules.id_of(p) != &"rifle"`，不要写 `p != &"rifle"` |

还有一条：`class_name CellGrid` 是为了避开 Godot 内建的 `GridContainer`（Control）。
撞名之后解析器会把标识符解析到内建类上，报错长得像"你的函数不存在"。

---

## 症状 → 先查哪一条

| 症状 | 先看 |
|---|---|
| 点边缘选中相邻格 | 1 |
| 大块"怎么都挪不动一格"、一松手弹回原位 | 1（抓取偏移那一节） |
| 拖影颜色与结果不符 | 2 |
| 松手后整板洗牌 | 3 |
| 某格永远放不下 | 4 |
| 规则写了却偶尔不生效（尤其批量操作后） | 5 |
| 读档后数量判断不对 | 6 |
| 拖走一块后另一块"变身份" | 7 |
| 竖着的东西横着画 | 13 |
| 提示"面积够但放不下" | 9（不是 bug） |
| 界面卡顿 / 重绘过多 | 11 |
| 栈溢出 | 12 |
