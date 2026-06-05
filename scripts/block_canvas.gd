class_name BlockCanvas
extends Control

## The Milestone 9 interactive canvas — the editor's drawing surface, now with
## **drag / snap / detach**. M8's renderer was read-only; M9 lets you pick a block up,
## drag it, and snap it into (or out of) a stack.
##
## The design stays faithful to the project's spine — **blocks are data, and the view
## walks the data**. So a drag does not reparent Control nodes; it mutates the block
## **data** and re-renders, exactly the way the interpreter mutates the same arrays as
## it runs. Concretely:
##   * BlockView stamps each statement panel with the live Array it lives in
##     ("blk_array") + its index, and each stack column with its Array ("body_array").
##   * Picking up a block detaches it *and its successors* (Scratch's "grab the rest of
##     the stack" rule) by slicing them out of that live array.
##   * The detached blocks float as a ghost following the cursor.
##   * Dropping over a gap splices them into that gap's live array (`array.insert`);
##     dropping on empty canvas leaves them as a new free-floating stack.
##   * Either way we re-render from the data — the single source of truth.
##
## Scope deliberately matched to one milestone: statement blocks snap into stacks and
## C-block bodies; whole stacks (and hat-led drags) only reposition. The edited result
## is serialized by export_script() and run by the Stage (M10). Dragging a *reporter*
## into an input slot and a palette to drag *new* blocks from are still ahead — see
## CLAUDE.md.
##
## Position is the editor's own UI state (a Vector2 per top-level stack), kept here and
## out of the block dictionaries, so the data stays exactly the runtime's shape.

## Pixels the cursor must travel after pressing before a click becomes a drag, so a
## plain click on a block doesn't pop it loose and relocate it.
const DRAG_THRESHOLD := 4.0

## How near (px) the dragged stack's top-left must be to a gap for it to snap there.
const SNAP_DISTANCE := 34.0

# Drag state machine.
const _IDLE := 0
const _PENDING := 1  # pressed on a block, not yet moved past the threshold
const _DRAGGING := 2

## Top-level stacks: each {"blocks": Array, "pos": Vector2}. "blocks" is a live block
## Array (a hat-led stack is just [hat], its run nested in the hat's body); "pos" is
## the stack's canvas-local top-left. This is the editor's working copy — load_script
## deep-duplicates so edits never touch the pristine source.
var _stacks: Array = []

## Holds the rendered stack Controls; walked for hit-testing and snap targets. Kept
## separate from the ghost/highlight overlays so those never appear as drop targets.
var _layer: Control

## The floating copy of the blocks being dragged, and the thin bar marking where they
## would snap. Both are overlay children of the canvas (drawn above _layer).
var _ghost: Control
var _highlight: Panel

var _state: int = _IDLE
var _press_pos: Vector2          # global position of the initial press
var _pending: Dictionary = {}    # {array, index} of the block pressed
var _grab_offset: Vector2        # ghost top-left relative to the cursor, held constant
var _grabbed: Array = []         # the detached blocks riding the cursor
var _snap: Dictionary = {}       # current snap target {array, index} or empty


func _ready() -> void:
	clip_contents = true
	# PASS (not the default STOP) so the mouse wheel reaches the enclosing
	# ScrollContainer to scroll — we drive dragging from _input, not _gui_input, so we
	# don't need to capture GUI events here.
	mouse_filter = Control.MOUSE_FILTER_PASS
	_layer = Control.new()
	_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_layer)

	# The snap marker: a bright bar shown at the gap a drop would land in.
	_highlight = Panel.new()
	_highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hl := StyleBoxFlat.new()
	hl.bg_color = Color("#ffd24d")
	hl.set_corner_radius_all(2)
	_highlight.add_theme_stylebox_override("panel", hl)
	_highlight.visible = false
	add_child(_highlight)


## Load a sprite's script for editing. Deep-duplicated so dragging mutates only this
## working copy, not the array passed in. Each top-level block becomes one stack, laid
## out down the canvas.
func load_script(script: Array) -> void:
	_cancel_drag()
	_stacks.clear()
	var y := 12.0
	for block in script:
		if typeof(block) != TYPE_DICTIONARY:
			continue
		_stacks.append({"blocks": [block.duplicate(true)], "pos": Vector2(12, y)})
		y += 150.0  # rough vertical spread; the user drags from here
	_render()


## Serialize the edited canvas back to the runtime's script shape: a flat Array of
## top-level block dictionaries (each stack's blocks, in canvas order). This is the M10
## hand-off — the editor reads it to persist a sprite's edits and to run them in the
## Stage. Position is dropped here, exactly because it is editor-only UI state that the
## runtime shape never carried. (A hat-led stack contributes its hat, whose body holds
## the run; a loose stack contributes its blocks as top-level siblings.)
func export_script() -> Array:
	var out: Array = []
	for stack in _stacks:
		for block in stack["blocks"]:
			out.append(block)
	return out


# --- Rendering -------------------------------------------------------------

## Rebuild every top-level stack from the data and place it at its stored position.
## Called after each structural change (grab, drop) — the data is the source of truth.
func _render() -> void:
	for child in _layer.get_children():
		child.queue_free()
	for stack in _stacks:
		var ctrl := BlockView.build_stack(stack["blocks"])
		_passthrough(ctrl, true)
		_wire_literals(ctrl)
		_layer.add_child(ctrl)
		ctrl.position = stack["pos"]
		ctrl.size = ctrl.get_combined_minimum_size()


## Make a rendered subtree transparent to mouse picking, so this canvas's _input sees
## presses over blocks (and the wheel still reaches the surrounding ScrollContainer).
## When `keep_literals` is set (the on-canvas render), an editable literal field (M12) is
## left interactive (MOUSE_FILTER_STOP) so it can take focus and clicks; everything else,
## and the whole ghost subtree, is ignored.
func _passthrough(node: Node, keep_literals := false) -> void:
	if node is Control:
		if keep_literals and node.has_meta("lit_key"):
			(node as Control).mouse_filter = Control.MOUSE_FILTER_STOP
			return  # a leaf field; leave it (and stop) interactive
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_passthrough(child, keep_literals)


## Wire each editable input widget in a freshly-rendered subtree to commit its chosen
## value back into the block data. A literal field (M12, LineEdit) commits on Enter or
## focus loss; an enum dropdown (M13, OptionButton) commits on selection. Both carry the
## live `inputs` dict + key as meta (stamped by BlockView), so committing is a direct
## write into the same array the runtime reads — the editor-side echo of M9's
## splice-into-data.
func _wire_literals(node: Node) -> void:
	if node.has_meta("lit_key"):
		if node is LineEdit:
			var field := node as LineEdit
			field.text_submitted.connect(_on_literal_submitted.bind(field))
			field.focus_exited.connect(_commit_literal.bind(field))
			return
		if node is OptionButton:
			var dd := node as OptionButton
			dd.item_selected.connect(_on_enum_selected.bind(dd))
			return
	for child in node.get_children():
		_wire_literals(child)


func _on_literal_submitted(_text: String, field: LineEdit) -> void:
	_commit_literal(field)
	field.release_focus()


## Write an enum dropdown's chosen option back into the block data. Enum values are all
## strings (the interpreter reads these slots as strings), so the option text is stored
## verbatim — no coercion, unlike a free-text literal field.
func _on_enum_selected(index: int, dd: OptionButton) -> void:
	var inputs: Dictionary = dd.get_meta("lit_inputs")
	var key := String(dd.get_meta("lit_key"))
	inputs[key] = dd.get_item_text(index)


## Coerce the field's text to the slot's type and write it into the live block data, then
## normalize the field to the stored value's display (so "8.0"/" 8 " settle to "8").
func _commit_literal(field: LineEdit) -> void:
	var inputs: Dictionary = field.get_meta("lit_inputs")
	var key := String(field.get_meta("lit_key"))
	var coerced: Variant = BlockView.coerce_literal(field.text, inputs.get(key))
	inputs[key] = coerced
	var normalized := BlockView._stringify(coerced)
	if field.text != normalized:
		field.text = normalized


# --- Input -----------------------------------------------------------------

## We drive the drag from _input (which runs before GUI input) and do our own global
## hit-testing, so nested block panels never intercept the press. We only consume the
## event when we actually act on it; a press that misses every block falls through to
## the ScrollContainer / buttons untouched.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and _state == _IDLE:
			# A press on an editable literal field (M12) belongs to that field: let it
			# fall through to GUI focus/editing rather than grabbing the block.
			if _over_literal(event.position):
				return
			# Grabbing anything else commits whatever field was being edited.
			get_viewport().gui_release_focus()
			var hit := _block_at(event.position)
			if not hit.is_empty():
				_state = _PENDING
				_press_pos = event.position
				_pending = hit
				get_viewport().set_input_as_handled()
		elif not event.pressed:
			if _state == _DRAGGING:
				_drop()
				get_viewport().set_input_as_handled()
			elif _state == _PENDING:
				_state = _IDLE  # a plain click, never moved — leave the block be
	elif event is InputEventMouseMotion:
		if _state == _PENDING and event.position.distance_to(_press_pos) > DRAG_THRESHOLD:
			_begin_drag()
			_update_drag(event.position)
			get_viewport().set_input_as_handled()
		elif _state == _DRAGGING:
			_update_drag(event.position)
			get_viewport().set_input_as_handled()


## The deepest statement block under a global point: among every tagged panel whose
## rect contains the point, the smallest-area one — so a click inside a forever's body
## grabs the inner block, not the forever. Returns {array, index} or {} if none.
func _block_at(global_point: Vector2) -> Dictionary:
	var best: Control = null
	var best_area := INF
	for panel in _tagged_panels(_layer):
		var rect: Rect2 = panel.get_global_rect()
		if rect.has_point(global_point):
			var area := rect.size.x * rect.size.y
			if area < best_area:
				best_area = area
				best = panel
	if best == null:
		return {}
	return {"array": best.get_meta("blk_array"), "index": best.get_meta("blk_index")}


func _tagged_panels(node: Node, out: Array = []) -> Array:
	if node is Control and node.has_meta("blk_index"):
		out.append(node)
	for child in node.get_children():
		_tagged_panels(child, out)
	return out


## True when a global point lands on an editable input widget — a literal field (M12) or
## an enum dropdown (M13). The press handler uses this to defer to the widget instead of
## starting a block drag (so the field takes focus / the dropdown opens). The widget is
## always smaller than the block it sits in, so checking it first lets the inner one win.
func _over_literal(global_point: Vector2) -> bool:
	for field in _literal_fields(_layer):
		if (field as Control).get_global_rect().has_point(global_point):
			return true
	return false


func _literal_fields(node: Node, out: Array = []) -> Array:
	if node is Control and node.has_meta("lit_key"):
		out.append(node)
	for child in node.get_children():
		_literal_fields(child, out)
	return out


# --- Drag lifecycle --------------------------------------------------------

## Begin dragging freshly-spawned blocks (the M11 palette hand-off). Unlike _begin_drag
## there is nothing to detach — the blocks are new and already live only on the cursor —
## so we just seed _grabbed, build the ghost, and fall into the existing drag flow.
## `blocks` must be freshly made (BlockView.make_block), since _drop splices them straight
## into the canvas data. `global_point` is the cursor position to anchor the first frame.
func begin_spawn_drag(blocks: Array, global_point: Vector2) -> void:
	_cancel_drag()
	_grabbed = blocks
	_grab_offset = Vector2(10, 8)  # cursor sits just inside the block's header
	_ghost = BlockView.build_stack(_grabbed)
	_passthrough(_ghost)
	_ghost.modulate.a = 0.75
	add_child(_ghost)
	_ghost.size = _ghost.get_combined_minimum_size()
	_state = _DRAGGING
	_update_drag(global_point)  # position the ghost + show any snap immediately


## Detach the pressed block and its successors from their array (Scratch's "the rest of
## the stack comes with you") and start them floating as a ghost.
func _begin_drag() -> void:
	var arr: Array = _pending["array"]
	var index: int = _pending["index"]

	# Anchor the ghost so the grabbed block sits exactly where it was on press.
	var origin := _grabbed_block_top_left(arr, index)
	_grab_offset = _press_pos - origin

	_grabbed = arr.slice(index)
	for i in range(arr.size() - 1, index - 1, -1):
		arr.remove_at(i)
	# If we emptied a top-level stack (grabbed it whole), drop its now-empty entry.
	for s in range(_stacks.size() - 1, -1, -1):
		if is_same(_stacks[s]["blocks"], arr) and arr.is_empty():
			_stacks.remove_at(s)

	_render()

	_ghost = BlockView.build_stack(_grabbed)
	_passthrough(_ghost)
	_ghost.modulate.a = 0.75
	add_child(_ghost)
	_ghost.size = _ghost.get_combined_minimum_size()

	_state = _DRAGGING


## Move the ghost to follow the cursor and refresh the snap highlight.
func _update_drag(global_point: Vector2) -> void:
	_ghost.position = (global_point - _grab_offset) - global_position
	_snap = _nearest_gap()
	if _snap.is_empty():
		_highlight.visible = false
	else:
		_highlight.visible = true
		_highlight.position = _snap["marker"] - global_position
		_highlight.size = Vector2(maxf(_snap["width"], 24.0), 4)


## Place the dragged blocks: into the snap gap if one is active, else as a new
## free-floating stack where the ghost came to rest. Then re-render from the data.
func _drop() -> void:
	if not _snap.is_empty():
		var arr: Array = _snap["array"]
		var index: int = _snap["index"]
		for i in range(_grabbed.size()):
			arr.insert(index + i, _grabbed[i])
	else:
		_stacks.append({"blocks": _grabbed, "pos": _ghost.position})
	_clear_drag_overlays()
	_render()


## Abandon any in-progress drag without committing it (used by load_script). The
## grabbed blocks are already detached from the data, so re-home them as a loose stack
## rather than losing them.
func _cancel_drag() -> void:
	if _state == _DRAGGING and not _grabbed.is_empty():
		_stacks.append({"blocks": _grabbed, "pos": _ghost.position})
	_clear_drag_overlays()


func _clear_drag_overlays() -> void:
	if _ghost != null:
		_ghost.queue_free()
		_ghost = null
	_highlight.visible = false
	_grabbed = []
	_snap = {}
	_state = _IDLE
	_pending = {}


# --- Snapping --------------------------------------------------------------

## The nearest insertion gap to the ghost's top-left, within SNAP_DISTANCE. A gap is a
## {array, index} splice point with a global "marker" position and a "width" for the
## highlight bar. Hat-led drags never snap (a hat can't sit mid-stack) — they only
## reposition on the canvas.
func _nearest_gap() -> Dictionary:
	if _grabbed.is_empty() or String(_grabbed[0].get("opcode", "")) in BlockView.HAT_OPCODES:
		return {}
	var anchor := global_position + _ghost.position  # ghost top-left, in global space
	var best := {}
	var best_dist := SNAP_DISTANCE
	for gap in _all_gaps():
		var d := anchor.distance_to(gap["marker"])
		if d < best_dist:
			best_dist = d
			best = gap
	return best


## Every insertion gap across all rendered stacks: before each block, after the last
## block, and the interior of each empty body. Derived from the meta BlockView stamped.
func _all_gaps() -> Array:
	var gaps: Array = []
	for column in _columns(_layer):
		var arr: Array = column.get_meta("body_array")
		var blocks: Array = []
		for child in column.get_children():
			if child is Control and child.has_meta("blk_index"):
				blocks.append(child)
		if blocks.is_empty():
			var r: Rect2 = column.get_global_rect()
			gaps.append({"array": arr, "index": 0, "marker": r.position, "width": r.size.x})
		else:
			for panel in blocks:
				var pr := (panel as Control).get_global_rect()
				gaps.append({"array": arr, "index": panel.get_meta("blk_index"),
					"marker": pr.position, "width": pr.size.x})
			var last := (blocks[blocks.size() - 1] as Control).get_global_rect()
			gaps.append({"array": arr, "index": blocks.size(),
				"marker": Vector2(last.position.x, last.end.y), "width": last.size.x})
	return gaps


func _columns(node: Node, out: Array = []) -> Array:
	if node is Control and node.has_meta("body_array"):
		out.append(node)
	for child in node.get_children():
		_columns(child, out)
	return out


## The global top-left of the block at (array, index), found via the rendered panel, so
## the ghost can start exactly where the grabbed block sat. Falls back to the press
## position if the panel can't be located.
func _grabbed_block_top_left(arr: Array, index: int) -> Vector2:
	for panel in _tagged_panels(_layer):
		if is_same(panel.get_meta("blk_array"), arr) and int(panel.get_meta("blk_index")) == index:
			return panel.get_global_rect().position
	return _press_pos
