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
## is serialized by export_script() and run by the Stage (M10).
##
## M14 adds the second drop kind: a **reporter** dragged from the palette drops into a
## **value/condition slot**. It rides the same machinery — palette mints a fresh dict and
## hands it here (begin_spawn_drag), the ghost follows the cursor, a highlight marks the
## target — but the target is a slot (_nearest_slot, found via the `slot_*` meta BlockView
## stamps on every input widget) instead of a stack gap, and the drop *writes* the reporter
## into the slot's live `inputs[key]` (overwriting whatever was there) instead of splicing
## into an array. A reporter released off any slot is **discarded** — it can't become a
## top-level orphan the interpreter couldn't run.
##
## M15 adds the reverse: **grab a reporter pill already in a slot** to pull it back out.
## A press over a pill (checked before the statement it sits in, _reporter_at) detaches the
## reporter dict, leaves the slot's default literal behind (slot_default — we never kept the
## literal the reporter displaced), and rides the very same _dragging_reporter flow as a
## palette spawn: re-drop it into another slot, or release off every slot to discard it
## (the editor's reporter "trash"). A pill whose interior is entirely a literal field — a
## bare `variable`/`score` — is grabbed by its thin coloured border; the wider operator /
## sensing pills are grabbed by their body. (Full-body grab of a `variable` waits for its
## free-text name to become a data-scoped menu — see CLAUDE.md.)
##
## M16 makes the palette double as a **trash**: drag a block (a statement stack or a reporter
## pill) back over the palette region and release to delete it. Pickup already detaches the
## grabbed blocks from the data, so deleting is just _drop **not re-homing** them — the
## statement counterpart to M14/M15's "a reporter released off any slot is discarded". While
## the ghost is over the palette the snap is suppressed and the ghost tints red (_over_trash /
## _trashing). No new opcode, no data-model change — a deleted block is one the export simply
## no longer contains.
##
## M23 makes the reporter drop **type-aware**: each slot carries an expected `slot_type`
## ("boolean"/"value", stamped by BlockView from the opcode's `bool_inputs`) and each reporter
## an `output` kind. _nearest_slot only offers a dragged reporter the slots whose type matches,
## so a boolean can't land in `move`'s value slot nor a value in an `if` condition — Scratch's
## hexagon-vs-round refusal. A mismatched release discards the reporter (the off-slot path).
## Still no runtime change — the interpreter already coped with any reporter anywhere; this only
## constrains what the editor *lets* you assemble.
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
var _snap: Dictionary = {}       # current snap target (a stack gap or a value slot) or empty
var _dragging_reporter := false  # the drag is a single reporter pill -> targets slots, not gaps
var _pending_reporter := false   # the pending press was on an on-canvas reporter pill (M15)
var _pending_spawn := false      # the pending press was on a spawnable prototype pill (M31) -> mint a copy
var _trashing := false           # the ghost is currently over the palette -> a drop deletes it (M16)
var _spawn_scope_body: Variant = null  # (M31) when dragging a `param`, the define body Array its drops are confined to; null otherwise

## --- Multi-block selection (M46) ---
## References to the selected block dicts (identity, via is_same) — statement blocks *and* reporter
## pills. Editor-only UI state — like a stack's canvas position, it is never serialized (export_script()
## is untouched). It survives _render() because the block dicts in _stacks persist (only the Control tree
## is rebuilt), so a panel's blk_array[blk_index] (a statement) or a slot's inputs[key] (a pill) resolves
## back to the same dict. A click selects a statement or a pill; double-click selects that block plus all
## of its nested children (a C-block's body, a reporter's input pills — _select_subtree). The rubber-band
## stays statement-level (it reselects the statement panels it covers).
var _selected: Array = []
var _marquee := false            # the drag is a rubber-band selection over empty canvas (not a block drag)
var _marquee_base: Array = []    # selection snapshot captured when an additive (Shift) marquee started
var _marquee_panel: Panel        # the rubber-band rectangle overlay (a direct child of the canvas, not _layer)

## The palette region, set by the editor (editor.gd) — dragging a block back over it and
## releasing **deletes** it (Scratch's own gesture, M16). Left null when unset (no trash).
var _trash: Control

## Editor hook (M32): called (no args) after an in-place rename of a `define`'s name has cascaded to
## this sprite's `call`s, so the editor can re-derive its custom-block name list and rebuild the
## palette + canvas (which is also where the re-render happens). Left unset for non-editor callers,
## in which case the canvas re-renders itself.
var on_custom_block_renamed := Callable()


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

	# The rubber-band selection rectangle (M46): a faint sky-blue fill + thin border, shown while a
	# marquee drag is in progress. A direct child of the canvas (not _layer), so _render never frees it.
	_marquee_panel = Panel.new()
	_marquee_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mq := StyleBoxFlat.new()
	mq.bg_color = Color(0.29, 0.82, 1.0, 0.12)
	mq.border_color = Color("#4ad0ff")
	mq.set_border_width_all(1)
	mq.set_corner_radius_all(2)
	_marquee_panel.add_theme_stylebox_override("panel", mq)
	_marquee_panel.visible = false
	add_child(_marquee_panel)


## Load a sprite's script for editing. Deep-duplicated so dragging mutates only this
## working copy, not the array passed in. Each top-level block becomes one stack, laid
## out down the canvas.
func load_script(script: Array) -> void:
	_cancel_drag()
	_selected = []  # a sprite switch starts with nothing selected (M46)
	_stacks.clear()
	for block in script:
		if typeof(block) != TYPE_DICTIONARY:
			continue
		_stacks.append({"blocks": [block.duplicate(true)], "pos": Vector2(12, 12)})
	_render()
	_reflow_stacks()  # flow by measured height so tall hats don't overlap


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


## Add a freshly-created top-level block as a new free-floating stack and re-render (M30). The
## editor calls this when "Make a Block" mints a `define {name}` hat, so the new procedure appears
## on the canvas immediately (it then rides export_script() → persistence/RUN like any block). It is
## placed below the existing stacks; the user drags it wherever they like, exactly as for a hat
## dropped from the palette. `block` must be freshly made (BlockView.make_block) so it owns its data.
func add_definition(block: Dictionary) -> void:
	_stacks.append({"blocks": [block], "pos": Vector2(12, 12)})
	_render()
	_reflow_stacks()  # place it below the existing stacks, using their measured heights


## Re-render every stack from the current data without otherwise touching it. The editor
## calls this after minting a new variable (M20) so any already-rendered `{name}` dropdown
## picks up the new option. Positions live in _stacks (untouched here), so blocks stay put;
## this just rebuilds the Control tree — and thus each dropdown's option list — from the
## (now-extended) BlockView.project_variables.
func refresh() -> void:
	_render()


## Rewrite every reference to `old_name` in the working stacks to `new_name`, in place, then
## re-render (M21). This is the current sprite's half of the editor's rename cascade: the canvas
## holds the authoritative working copy of the edited sprite, so a rename has to rewrite *these*
## block dicts (the editor rewrites the other sprites' `_scripts` directly). Mutating in place and
## re-rendering — rather than reloading via load_script — keeps each stack's canvas position, so a
## rename never reshuffles the layout. The walk itself lives on BlockView (shared with the editor).
func rename_variable(old_name: String, new_name: String) -> void:
	for stack in _stacks:
		BlockView.rewrite_variable_refs(stack["blocks"], old_name, new_name)
	_render()


## Remove every reference to `var_name` from the working stacks (M21 delete), in place, then
## re-render — the current sprite's half of the delete cascade (the editor strips the other sprites'
## _scripts directly). Like rename_variable this mutates in place to preserve canvas positions. A
## top-level stack left empty (a loose `set`/`change` that was the whole stack) is dropped.
func delete_variable_refs(var_name: String) -> void:
	for stack in _stacks:
		BlockView.strip_variable_refs(stack["blocks"], var_name)
	for s in range(_stacks.size() - 1, -1, -1):
		if (_stacks[s]["blocks"] as Array).is_empty():
			_stacks.remove_at(s)
	_render()


## Rewrite every reference to list `old_name` in the working stacks to `new_name`, in place, then
## re-render (M44) — the list counterpart of rename_variable. The walk lives on BlockView (shared with
## the editor, which rewrites the other sprites' _scripts directly). In place to preserve canvas positions.
func rename_list(old_name: String, new_name: String) -> void:
	for stack in _stacks:
		BlockView.rewrite_list_refs(stack["blocks"], old_name, new_name)
	_render()


## Remove every reference to list `list_name` from the working stacks (M44 delete), in place, then
## re-render — the list counterpart of delete_variable_refs. A top-level stack left empty (a loose list
## statement that was the whole stack) is dropped.
func delete_list_refs(list_name: String) -> void:
	for stack in _stacks:
		BlockView.strip_list_refs(stack["blocks"], list_name)
	for s in range(_stacks.size() - 1, -1, -1):
		if (_stacks[s]["blocks"] as Array).is_empty():
			_stacks.remove_at(s)
	_render()


## Rewrite every reference to sprite `old_name` in the working stacks to `new_name`, in place, then
## re-render (M25) — the sprite counterpart of rename_variable. The canvas holds the authoritative
## working copy of the edited sprite, so a sprite rename has to rewrite *these* block dicts (the editor
## rewrites the other sprites' `_scripts` directly). Mutating in place and re-rendering — rather than
## reloading via load_script — keeps each stack's canvas position. The walk lives on BlockView (shared).
func rename_sprite(old_name: String, new_name: String) -> void:
	for stack in _stacks:
		BlockView.rewrite_sprite_refs(stack["blocks"], old_name, new_name)
	_render()


# --- Rendering -------------------------------------------------------------

## Rebuild every top-level stack from the data and place it at its stored position.
## Called after each structural change (grab, drop) — the data is the source of truth.
func _render() -> void:
	for child in _layer.get_children():
		child.queue_free()
	var extent := Vector2.ZERO
	for stack in _stacks:
		var ctrl := BlockView.build_stack(stack["blocks"])
		_passthrough(ctrl, true)
		_wire_literals(ctrl)
		_layer.add_child(ctrl)
		ctrl.position = stack["pos"]
		ctrl.size = ctrl.get_combined_minimum_size()
		extent = extent.max(ctrl.position + ctrl.size)
	_apply_selection_highlight()  # outline the selected blocks (M46)
	_fit_to_content(extent)


## Grow the canvas's minimum size to cover every stack (plus a margin), so the enclosing
## ScrollContainer can always scroll to the end of the longest / lowest script — and never
## smaller than the visible viewport, so it still fills the panel when scripts are short.
## Without this the canvas kept a fixed minimum (editor.tscn), capping how far you could
## scroll once a script flowed past it.
const _CONTENT_MARGIN := 80.0
func _fit_to_content(extent: Vector2) -> void:
	var floor_size := Vector2.ZERO
	var view := get_parent() as Control
	if view != null:
		floor_size = view.size
	custom_minimum_size = (extent + Vector2(_CONTENT_MARGIN, _CONTENT_MARGIN)).max(floor_size)


## Flow the top-level stacks top-to-bottom using their *rendered* heights, so a tall hat
## (a when-flag-clicked with several blocks, or a forever) never overlaps the group below
## it. Used only on the default-layout paths (load_script / add_definition); a grab/drop
## re-render keeps each stack's stored position, so a user's hand-placed layout survives.
## Awaits one frame first: a freshly built block tree doesn't have its nested minimum sizes
## propagated until the next layout pass, so measuring immediately reads heights too small
## (the under-spacing that left the groups overlapping). After the frame, each ctrl.size is
## final; we write the flowed positions back into _stacks and re-apply them to the controls.
const _FLOW_GAP := 24.0
func _reflow_stacks() -> void:
	await get_tree().process_frame
	var children := _layer.get_children()
	if children.size() != _stacks.size():
		return  # rendered tree out of step with the data (e.g. re-rendered meanwhile)
	var y := 12.0
	var extent := Vector2.ZERO
	for i in range(_stacks.size()):
		var ctrl := children[i] as Control
		ctrl.position = Vector2(12, y)
		_stacks[i]["pos"] = ctrl.position
		extent = extent.max(ctrl.position + ctrl.size)
		y += ctrl.size.y + _FLOW_GAP
	_fit_to_content(extent)


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
	var old_value: Variant = inputs.get(key)
	var coerced: Variant = BlockView.coerce_literal(field.text, old_value)
	# Renaming a `define`'s name in place (M32): cascade the new name to this sprite's `call`s. A
	# custom block's name must stay unique within the sprite (`call` resolves by name) and non-blank,
	# so a blank or colliding rename is rejected — the field reverts to the old name, nothing cascades.
	if field.has_meta("define_name"):
		var old_name := String(old_value)
		var new_name := String(coerced)
		if new_name == "" or (new_name != old_name and _other_define_named(inputs, new_name)):
			field.text = BlockView._stringify(old_value)
			return
		inputs[key] = coerced
		field.text = BlockView._stringify(coerced)
		if new_name != old_name:
			# Defer the cascade + re-render: _render() frees this very field, which we must not do
			# from inside its own commit signal.
			_rename_custom_block_deferred.call_deferred(old_name, new_name)
		return
	inputs[key] = coerced
	var normalized := BlockView._stringify(coerced)
	if field.text != normalized:
		field.text = normalized


## True if some *other* `define` hat in the working stacks already carries `name` (M32) — the
## collision guard for an in-place rename. `self_inputs` is the renamed define's own inputs dict;
## we exclude it by reference (is_same, since two distinct defines can hold equal-by-value dicts).
func _other_define_named(self_inputs: Dictionary, name: String) -> bool:
	for stack in _stacks:
		for block in stack["blocks"]:
			if typeof(block) != TYPE_DICTIONARY or String(block.get("opcode", "")) != "define":
				continue
			var bi: Dictionary = block.get("inputs", {})
			if not is_same(bi, self_inputs) and String(bi.get("name", "")) == name:
				return true
	return false


## Cascade a `define` rename across the working stacks (M32), deferred from _commit_literal so we
## don't free the committing field mid-signal. The define's own name is already updated (in
## _commit_literal); this rewrites the matching `call`s. Then the editor re-derives its custom-block
## name list and rebuilds/refreshes (which re-renders); with no editor hook we re-render ourselves.
func _rename_custom_block_deferred(old_name: String, new_name: String) -> void:
	for stack in _stacks:
		BlockView.rewrite_custom_block_refs(stack["blocks"], old_name, new_name)
	if on_custom_block_renamed.is_valid():
		on_custom_block_renamed.call()
	else:
		_render()


# --- Input -----------------------------------------------------------------

## We drive the drag from _input (which runs before GUI input) and do our own global
## hit-testing, so nested block panels never intercept the press. We only consume the
## event when we actually act on it; a press that misses every block falls through to
## the ScrollContainer / buttons untouched.
func _input(event: InputEvent) -> void:
	# In Stage mode (M27) the canvas is hidden but still receives _input; ignore events unless we're
	# the visible surface, so a press on the stage view can't grab a stale (scrolled-off) block here.
	if not is_visible_in_tree():
		return
	if event is InputEventKey:
		_handle_key(event as InputEventKey)  # Delete / Cmd+D on the selection (M46)
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and _state == _IDLE:
			# Modifier / double-click flags for selection (M46), captured before any early return.
			# Typed explicitly: `event` is statically InputEvent, so these properties read as Variant.
			var additive: bool = event.shift_pressed or event.meta_pressed or event.ctrl_pressed
			var double_click: bool = event.double_click
			# A ScrollContainer only clips *rendering*: a block scrolled above the viewport keeps a
			# global rect that overlaps the chrome above the canvas (the top bar's sprite selector).
			# Ignore a press outside the visible canvas region so it falls through to that chrome
			# rather than grabbing a scrolled-up block. (Guarded to the initial press only — a drag
			# in progress legitimately travels off-canvas, e.g. onto the palette trash, M16.)
			if not _in_view(event.position):
				return
			# Scope every press-time hit-test to the front-most stack actually under the cursor, so
			# a click never reaches a field, dropdown, or block belonging to a stack drawn *behind*
			# it. Block bodies are mouse-transparent (_passthrough leaves only literal fields
			# interactive), so without this an occluded field would catch the press — see
			# _front_stack_at. null means empty canvas: nothing to grab, let the event fall through.
			var root := _front_stack_at(event.position)
			if root == null:
				# A press on the ScrollContainer's scrollbar must still drive scrolling — don't start a
				# marquee there (the old empty-canvas fall-through let the scrollbar grab it).
				if _over_scrollbar(event.position):
					return
				# Empty canvas (M46): begin a rubber-band selection if the press turns into a drag;
				# a plain click here (no drag) clears the selection. Commit any open field edit first.
				get_viewport().gui_release_focus()
				_state = _PENDING
				_press_pos = event.position
				_pending = {"marquee": true, "additive": additive}
				get_viewport().set_input_as_handled()
				return
			# A press on an editable literal field (M12) belongs to that field: let it
			# fall through to GUI focus/editing rather than grabbing the block.
			if _over_literal(root, event.position):
				return
			# Grabbing anything else commits whatever field was being edited.
			get_viewport().gui_release_focus()
			# A press on a define hat's prototype parameter pill (M31) spawns a *fresh copy* of
			# that `param` reporter (Scratch's "drag a copy of the argument out"), checked before
			# _reporter_at / _block_at so it wins over the hat it sits in.
			var spawn := _spawn_at(root, event.position)
			if not spawn.is_empty():
				_state = _PENDING
				_press_pos = event.position
				_pending = spawn
				_pending_spawn = true
				get_viewport().set_input_as_handled()
				return
			# A press on a reporter pill grabs *that reporter* out of its slot (M15), checked
			# before _block_at so the pill wins over the statement it sits in; otherwise grab
			# the statement block under the cursor (M9).
			var rep := _reporter_at(root, event.position)
			var hit: Dictionary = rep if not rep.is_empty() else _block_at(root, event.position)
			if not hit.is_empty():
				_state = _PENDING
				_press_pos = event.position
				_pending = hit
				_pending["double"] = double_click  # (M46) click-select on release
				_pending["additive"] = additive
				_pending_reporter = not rep.is_empty()
				get_viewport().set_input_as_handled()
		elif not event.pressed:
			if _state == _DRAGGING:
				if _marquee:
					_finish_marquee()
				else:
					_drop()
				get_viewport().set_input_as_handled()
			elif _state == _PENDING:
				_on_pending_click()  # a press released without moving — a click (M46)
				_pending_reporter = false
				_pending_spawn = false
				_pending = {}
				_state = _IDLE
	elif event is InputEventMouseMotion:
		if _state == _PENDING and event.position.distance_to(_press_pos) > DRAG_THRESHOLD:
			if _pending.get("marquee", false):
				_begin_marquee()
				_update_marquee(event.position)
			else:
				_begin_drag()
				_update_drag(event.position)
			get_viewport().set_input_as_handled()
		elif _state == _DRAGGING:
			if _marquee:
				_update_marquee(event.position)
			else:
				_update_drag(event.position)
			get_viewport().set_input_as_handled()


## The front-most top-level stack actually under a global point — the highest-z (last) child of
## _layer one of whose rendered block panels contains the point. Press-time hit-testing is scoped
## to this stack (see _input), so a press never reaches a field, dropdown, or block of a stack drawn
## behind the one under the cursor: the block bodies are mouse-transparent (_passthrough), so without
## this an occluded field would catch the press. Tested against the actual panels, not the stack
## root's bounding rect, so a click in a short stack's empty right-hand margin correctly falls through
## to whatever sits behind it there. Returns null when no stack covers the point (empty canvas).
func _front_stack_at(global_point: Vector2) -> Control:
	var children := _layer.get_children()
	for i in range(children.size() - 1, -1, -1):
		var root := children[i] as Control
		if root == null:
			continue
		for panel in _tagged_panels(root):
			if (panel as Control).get_global_rect().has_point(global_point):
				return root
	return null


## The deepest statement block under a global point, within `root` (the front stack): among every
## tagged panel whose rect contains the point, the smallest-area one — so a click inside a forever's
## body grabs the inner block, not the forever. Returns {array, index} or {} if none.
func _block_at(root: Node, global_point: Vector2) -> Dictionary:
	var best: Control = null
	var best_area := INF
	for panel in _tagged_panels(root):
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


## True when a global point lands inside the canvas's visible region — its enclosing
## ScrollContainer's rect. The press handler gates on this so a press on the chrome above
## the canvas (the top bar) never grabs a block whose scrolled-up global rect overlaps it.
func _in_view(global_point: Vector2) -> bool:
	var view := get_parent() as Control
	return view == null or view.get_global_rect().has_point(global_point)


## True when a global point lands on an editable input widget — a literal field (M12) or
## an enum dropdown (M13). The press handler uses this to defer to the widget instead of
## starting a block drag (so the field takes focus / the dropdown opens). The widget is
## always smaller than the block it sits in, so checking it first lets the inner one win. Scoped to
## `root` (the front stack), so a field belonging to a stack drawn behind it never claims the press.
func _over_literal(root: Node, global_point: Vector2) -> bool:
	for field in _literal_fields(root):
		if (field as Control).get_global_rect().has_point(global_point):
			return true
	return false


func _literal_fields(node: Node, out: Array = []) -> Array:
	if node is Control and node.has_meta("lit_key"):
		out.append(node)
	for child in node.get_children():
		_literal_fields(child, out)
	return out


## The deepest reporter pill under a global point — the pickup counterpart to _block_at
## (M15). A slot widget holds a reporter only when its `inputs[key]` is a dict (a literal
## field / dropdown holds a plain value and is skipped), so this finds just the pills; among
## nested pills the smallest-area one wins, so pressing an inner `score` in `add {score} {1}`
## grabs `score`, not the whole `add`. Returns {inputs, key, default, origin} — enough for
## _begin_reporter_drag to detach the dict, restore the slot's default, and anchor the ghost
## — or {} if no pill is under the point. (A press on a pill's inner literal field is taken by
## _over_literal first, so the field still edits; only the pill's own body/border lands here.)
func _reporter_at(root: Node, global_point: Vector2) -> Dictionary:
	var best: Control = null
	var best_area := INF
	for slot in _slots(root):
		var inputs: Dictionary = slot.get_meta("slot_inputs")
		var key := String(slot.get_meta("slot_key"))
		if typeof(inputs.get(key)) != TYPE_DICTIONARY:
			continue  # a literal/enum slot, not a reporter pill
		var rect: Rect2 = (slot as Control).get_global_rect()
		if rect.has_point(global_point):
			var area := rect.size.x * rect.size.y
			if area < best_area:
				best_area = area
				best = slot
	if best == null:
		return {}
	return {"inputs": best.get_meta("slot_inputs"), "key": String(best.get_meta("slot_key")),
		"default": best.get_meta("slot_default"), "origin": best.get_global_rect().position, "control": best}


## The deepest spawnable prototype pill under a global point (M31) — a define hat's parameter pill,
## tagged by BlockView with `spawn_opcode` + `spawn_name`. Smallest-area wins (cf. _block_at). Returns
## {spawn_opcode, spawn_name} so _begin_drag can mint a fresh copy, or {} if none is under the point.
## Checked before _reporter_at / _block_at so pressing a prototype pill spawns a copy rather than
## grabbing the hat it sits in.
func _spawn_at(root: Node, global_point: Vector2) -> Dictionary:
	var best: Control = null
	var best_area := INF
	for pill in _spawnables(root):
		var rect: Rect2 = (pill as Control).get_global_rect()
		if rect.has_point(global_point):
			var area := rect.size.x * rect.size.y
			if area < best_area:
				best_area = area
				best = pill
	if best == null:
		return {}
	# Record the define body this prototype belongs to (M31), so the minted `param` can drop only
	# into slots inside that function — a parameter is meaningful only within its own define's body.
	return {"spawn_opcode": String(best.get_meta("spawn_opcode")), "spawn_name": String(best.get_meta("spawn_name")),
		"scope_body": _enclosing_define_body(best)}


func _spawnables(node: Node, out: Array = []) -> Array:
	if node is Control and node.has_meta("spawn_opcode"):
		out.append(node)
	for child in node.get_children():
		_spawnables(child, out)
	return out


## The body Array of the `define` whose rendered subtree contains `node` (M31), or null if `node`
## is not inside a define stack. A `param` reporter is bound to the function that declares it, so its
## drops are confined to slots in this body (see _nearest_slot). The Array reference is the live data,
## stable across re-renders — so it survives the _render() a reporter pickup triggers and matches back
## to the freshly-built body column by is_same. Walks up to the top-level stack column (a direct child
## of _layer); its body_array is the stack's blocks, and a define stack is [define_dict].
func _enclosing_define_body(node: Node) -> Variant:
	var n: Node = node
	while n != null:
		if n is Control and n.get_parent() == _layer:
			var arr: Array = (n as Control).get_meta("body_array", [])
			if not arr.is_empty() and typeof(arr[0]) == TYPE_DICTIONARY \
					and String((arr[0] as Dictionary).get("opcode", "")) == "define":
				return (arr[0] as Dictionary).get("inputs", {}).get("body")
			return null
		n = n.get_parent()
	return null


# --- Drag lifecycle --------------------------------------------------------

## Begin dragging freshly-spawned blocks (the M11 palette hand-off). Unlike _begin_drag
## there is nothing to detach — the blocks are new and already live only on the cursor —
## so we just seed _grabbed, build the ghost, and fall into the existing drag flow.
## `blocks` must be freshly made (BlockView.make_block), since _drop splices them straight
## into the canvas data. `global_point` is the cursor position to anchor the first frame.
func begin_spawn_drag(blocks: Array, global_point: Vector2) -> void:
	_cancel_drag()
	_grabbed = blocks
	# A single reporter targets slots (and ghosts as a pill); anything else is a stack.
	_dragging_reporter = blocks.size() == 1 and BlockView.is_reporter(String(blocks[0].get("opcode", "")))
	_grab_offset = Vector2(10, 8)  # cursor sits just inside the block's header
	_ghost = BlockView.build_reporter(_grabbed[0]) if _dragging_reporter else BlockView.build_stack(_grabbed)
	_passthrough(_ghost)
	_ghost.modulate.a = 0.75
	add_child(_ghost)
	_ghost.size = _ghost.get_combined_minimum_size()
	_state = _DRAGGING
	_update_drag(global_point)  # position the ghost + show any snap immediately


## Detach the pressed block and its successors from their array (Scratch's "the rest of
## the stack comes with you") and start them floating as a ghost. A reporter pickup (M15)
## takes a different path — it detaches a single reporter dict out of one slot.
func _begin_drag() -> void:
	if _pending_spawn:
		# A prototype parameter pill (M31): mint a fresh `param` reporter of that name and hand it to
		# the normal spawn-drag flow (it then targets value slots / discards off-slot like any reporter).
		# Confine its drops to slots inside the define it came from — set after begin_spawn_drag, which
		# clears drag state. The motion handler re-runs _update_drag right after, so the scope applies
		# from the first frame.
		var scope: Variant = _pending.get("scope_body")
		var blk := BlockView.make_block(String(_pending["spawn_opcode"]))
		blk["inputs"]["name"] = String(_pending["spawn_name"])
		begin_spawn_drag([blk], _press_pos)
		_spawn_scope_body = scope
		return
	if _pending_reporter:
		_begin_reporter_drag()
		return
	var arr: Array = _pending["array"]
	var index: int = _pending["index"]

	# Multi-block move (M46): if the grabbed block is part of a 2+ selection, gather the whole
	# selection (topmost-selected, in document order) and drag it as one run, leaving the rest behind.
	var grabbed_block: Variant = arr[index] if index < arr.size() else null
	if grabbed_block != null and _selected.size() >= 2 and _is_selected(grabbed_block):
		_begin_multi_drag()
		return
	# Dragging a single / unselected block manipulates just that run — drop any standing selection.
	_selected = []

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


## Pull an on-canvas reporter out of its slot (M15) and start it floating. The slot reverts
## to its opcode default literal (slot_default), since we never kept the literal the reporter
## displaced. From here it is an ordinary _dragging_reporter drag — drop it into another slot
## or release off every slot to discard it (cf. begin_spawn_drag, which spawns a fresh one).
func _begin_reporter_drag() -> void:
	var inputs: Dictionary = _pending["inputs"]
	var key: String = _pending["key"]
	var reporter: Variant = inputs.get(key)

	# A `param` reporter (M31) is bound to its define — moving it stays confined to that function's
	# body. Computed from the source slot's subtree *before* _render() frees it; the body Array is the
	# live data, so it stays valid across the re-render (and matches the rebuilt column by is_same).
	if typeof(reporter) == TYPE_DICTIONARY and String((reporter as Dictionary).get("opcode", "")) == "param":
		_spawn_scope_body = _enclosing_define_body(_pending.get("control"))

	# Anchor the ghost so the grabbed pill sits exactly where it was on press.
	_grab_offset = _press_pos - _pending["origin"]
	inputs[key] = _pending["default"]  # slot reverts to its default literal
	_grabbed = [reporter]
	_dragging_reporter = true

	_render()

	_ghost = BlockView.build_reporter(reporter)
	_passthrough(_ghost)
	_ghost.modulate.a = 0.75
	add_child(_ghost)
	_ghost.size = _ghost.get_combined_minimum_size()

	_state = _DRAGGING


## Move the ghost to follow the cursor and refresh the snap highlight. Over the palette
## (the trash, M16) we suppress any snap and tint the ghost red, signalling that releasing
## will delete it rather than place it.
func _update_drag(global_point: Vector2) -> void:
	_ghost.position = (global_point - _grab_offset) - global_position
	_trashing = _over_trash(global_point)
	_snap = {} if _trashing else (_nearest_slot() if _dragging_reporter else _nearest_gap())
	if _snap.is_empty():
		_highlight.visible = false
	else:
		_highlight.visible = true
		_highlight.position = _snap["marker"] - global_position
		# A slot target highlights its whole rect; a stack gap is a thin bar.
		_highlight.size = _snap["size"] if _snap.has("size") else Vector2(maxf(_snap["width"], 24.0), 4)
	_ghost.modulate = Color(1, 0.5, 0.5, 0.55) if _trashing else Color(1, 1, 1, 0.75)


## True when a global point lands on the palette region (the trash, M16). Comparable to the
## event positions used throughout this file (cf. _over_literal / _block_at), since both are
## in the same global space. Null `_trash` (unset) means there is no trash, so nothing deletes.
func _over_trash(global_point: Vector2) -> bool:
	return _trash != null and _trash.get_global_rect().has_point(global_point)


## Place the dragged blocks. Over the palette (the trash, M16) the grabbed blocks are simply
## **not re-homed** — they were already detached from the data on pickup, so dropping them
## here deletes them (the statement counterpart to a reporter's off-slot discard). Otherwise:
## a reporter drops into the targeted slot (overwriting its live `inputs[key]`) or, off any
## slot, is discarded; a statement stack splices into the snap gap if one is active, else lands
## as a new free-floating stack. Then re-render from the data.
func _drop() -> void:
	if _trashing:
		pass  # over the palette: delete the grabbed blocks (don't re-home them)
	elif _dragging_reporter:
		if not _snap.is_empty():
			var inputs: Dictionary = _snap["inputs"]
			inputs[String(_snap["key"])] = _grabbed[0]
		# Released off every slot: discard (no top-level orphan reporters).
	elif not _snap.is_empty():
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
	# A statement stack is re-homed so it isn't lost; a reporter (fresh from the palette) is
	# discarded — it has no top-level home.
	if _state == _DRAGGING and not _grabbed.is_empty() and not _dragging_reporter:
		_stacks.append({"blocks": _grabbed, "pos": _ghost.position})
	_clear_drag_overlays()


func _clear_drag_overlays() -> void:
	if _ghost != null:
		_ghost.queue_free()
		_ghost = null
	_highlight.visible = false
	_grabbed = []
	_snap = {}
	_dragging_reporter = false
	_pending_reporter = false
	_pending_spawn = false
	_trashing = false
	_spawn_scope_body = null
	_marquee = false
	_marquee_base = []
	if _marquee_panel != null:
		_marquee_panel.visible = false
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


## The nearest value/condition slot to the ghost's top-left, within SNAP_DISTANCE — the
## reporter-drag counterpart to _nearest_gap. A slot is any rendered input widget (literal
## field, dropdown, or an existing reporter pill) that BlockView stamped with `slot_*`; the
## returned dict carries the live `inputs` dict + key so the drop writes straight into the
## data, plus the slot's global rect (marker + size) so the highlight outlines the whole slot.
## Distance is measured to the slot's rect (0 when the anchor is inside), so a small slot is
## still easy to hit. Among slots at (near-)equal distance — e.g. a nested reporter's inner
## slot and the pill wrapping it both contain the anchor at distance 0 — the **smaller**
## (deeper) slot wins, so you fill an inner slot rather than replacing the whole reporter
## (cf. _block_at's smallest-area rule). The epsilon keeps that tie-break from letting a
## strictly-farther slot win on area alone.
##
## M23 type-filters the candidates: only slots whose expected `slot_type` matches the dragged
## reporter's `output` are considered, so a boolean reporter (`touching edge?`, `>`) is offered
## only boolean slots (`if`'s condition, `and`'s operands) and a value reporter only value slots.
## A mismatched hover finds no slot — no highlight — and a release there discards the reporter,
## the existing off-slot behavior (M14). Scratch's hexagon-vs-round refusal, enforced here.
func _nearest_slot() -> Dictionary:
	var anchor := global_position + _ghost.position  # ghost top-left, in global space
	var drag_type := BlockView.reporter_output_type(String(_grabbed[0].get("opcode", "")))
	# A `param` drag (M31) is confined to slots inside its own define's body; any other reporter
	# may land in any slot on the canvas.
	var candidates: Array = _scoped_slots() if _spawn_scope_body != null else _slots(_layer)
	var best := {}
	var best_dist := SNAP_DISTANCE
	var best_area := INF
	for slot in candidates:
		if String(slot.get_meta("slot_type", "value")) != drag_type:
			continue  # boolean ⇄ value mismatch: not a legal drop target
		var r: Rect2 = (slot as Control).get_global_rect()
		var d := _dist_to_rect(anchor, r)
		if d >= SNAP_DISTANCE:
			continue
		var area := r.size.x * r.size.y
		if best.is_empty() or d < best_dist - 0.5 or (d <= best_dist + 0.5 and area < best_area):
			best_dist = d
			best_area = area
			best = {"inputs": slot.get_meta("slot_inputs"), "key": slot.get_meta("slot_key"),
				"marker": r.position, "size": r.size}
	return best


func _slots(node: Node, out: Array = []) -> Array:
	if node is Control and node.has_meta("slot_key"):
		out.append(node)
	for child in node.get_children():
		_slots(child, out)
	return out


## The slots inside the define body a `param` drag is confined to (M31) — every input widget in the
## subtree of the rendered body column whose body_array is_same `_spawn_scope_body`. The Array is the
## live data, so it matches the current column even after a pickup's re-render. Empty if no such column
## (so the param finds no legal target outside its function, and a release there discards it).
func _scoped_slots() -> Array:
	for column in _columns(_layer):
		if is_same((column as Control).get_meta("body_array", []), _spawn_scope_body):
			return _slots(column)
	return []


## Distance from a point to a rectangle: 0 inside, else the gap to the nearest edge/corner.
func _dist_to_rect(p: Vector2, r: Rect2) -> float:
	var cx := clampf(p.x, r.position.x, r.end.x)
	var cy := clampf(p.y, r.position.y, r.end.y)
	return p.distance_to(Vector2(cx, cy))


## The global top-left of the block at (array, index), found via the rendered panel, so
## the ghost can start exactly where the grabbed block sat. Falls back to the press
## position if the panel can't be located.
func _grabbed_block_top_left(arr: Array, index: int) -> Vector2:
	for panel in _tagged_panels(_layer):
		if is_same(panel.get_meta("blk_array"), arr) and int(panel.get_meta("blk_index")) == index:
			return panel.get_global_rect().position
	return _press_pos


# --- Multi-block selection (M46) -------------------------------------------
#
# Selection is a set of statement-block dicts (by identity). It is editor-only UI state, never
# serialized. Three ways in — click (Shift/Cmd to toggle), double-click (the block + everything after
# it in this script), and rubber-band over empty canvas — and three things you can do with it: delete
# (Delete/Backspace, or drag onto the palette/trash), move together (drag any selected block), and
# duplicate (Cmd/Ctrl+D). The drag and trash paths reuse the existing _begin_drag / _drop machinery.

## The block dict a rendered statement panel stands for, via the blk_array/blk_index meta BlockView
## stamps. null if the index is stale (shouldn't happen between renders).
func _block_of(panel: Control) -> Variant:
	var arr: Array = panel.get_meta("blk_array")
	var idx := int(panel.get_meta("blk_index"))
	return arr[idx] if idx >= 0 and idx < arr.size() else null


func _is_selected(block: Variant) -> bool:
	for b in _selected:
		if is_same(b, block):
			return true
	return false


func _toggle_selected(block: Variant) -> void:
	for i in range(_selected.size()):
		if is_same(_selected[i], block):
			_selected.remove_at(i)
			return
	_selected.append(block)


## The selected statement blocks in document order, excluding any whose ancestor block is also selected
## (so a selected `forever` and a block inside it collapse to just the `forever` — its body travels with
## it). Each entry is {array, block}: the live Array it sits in (for removal / move) and the block dict.
## Shared by delete, multi-drag, and duplicate.
func _topmost_selected_in_order() -> Array:
	var out: Array = []
	for stack in _stacks:
		_collect_topmost(stack["blocks"], false, out)
	return out


func _collect_topmost(blocks: Array, ancestor_selected: bool, out: Array) -> void:
	for block in blocks:
		if typeof(block) != TYPE_DICTIONARY:
			continue
		var sel := _is_selected(block)
		if sel and not ancestor_selected:
			out.append({"array": blocks, "block": block})
		var body: Variant = (block.get("inputs", {}) as Dictionary).get("body")
		if body is Array:
			_collect_topmost(body, ancestor_selected or sel, out)


## Outline every selected block after a render — both statement panels and reporter pills (M46) —
## duplicating its category stylebox and adding a white border, so selection reads at a glance without
## touching BlockView. Cheap (no rebuild); called at the end of _render, so it re-applies cleanly each
## time the tree is rebuilt (incl. live marquee). A pill is a slot whose inputs[key] is the selected dict.
func _apply_selection_highlight() -> void:
	if _selected.is_empty():
		return
	for panel in _tagged_panels(_layer):
		var block: Variant = _block_of(panel)
		if block != null and _is_selected(block):
			_outline_selected(panel as Control)
	for slot in _slots(_layer):
		var inputs: Dictionary = slot.get_meta("slot_inputs")
		var v: Variant = inputs.get(String(slot.get_meta("slot_key")))
		if typeof(v) == TYPE_DICTIONARY and _is_selected(v):
			_outline_selected(slot as Control)


## Apply the white selection border to one block panel / pill by duplicating its "panel" stylebox.
func _outline_selected(control: Control) -> void:
	var sb := control.get_theme_stylebox("panel")
	if sb is StyleBoxFlat:
		# duplicate() is statically typed Resource, so cast back to StyleBoxFlat before touching its
		# members (else unsafe-access warnings, which are errors here).
		var hi := (sb as StyleBoxFlat).duplicate() as StyleBoxFlat
		hi.set_border_width_all(3)
		hi.border_color = Color.WHITE
		control.add_theme_stylebox_override("panel", hi)


## A press released without crossing the drag threshold — a click. Updates the selection: a click on a
## statement block or a reporter pill selects it (Shift/Cmd toggles; double-click selects it plus all of
## its nested children — for a statement, the block + following siblings at that body level, each with its
## subtree; for a pill, the pill plus the pills nested in its inputs), and a click on empty canvas clears
## the selection. Spawn-pill / literal presses don't select (they have their own gestures, or fell through
## to GUI).
func _on_pending_click() -> void:
	if _pending.get("marquee", false):
		if not _selected.is_empty():
			_selected = []
			_render()
		return
	if _pending_spawn:
		return  # a define-hat prototype param pill spawns on drag; a click does nothing
	var block: Variant = _pending_clicked_block()
	if typeof(block) != TYPE_DICTIONARY:
		return
	var additive: bool = _pending.get("additive", false)
	if _pending.get("double", false):
		if not additive:
			_selected = []
		if _pending_reporter:
			_select_subtree(block)
		else:
			# the block + every following sibling at this body level, each with its nested children
			var arr: Array = _pending["array"]
			for b in arr.slice(int(_pending["index"])):
				if b is Dictionary:
					_select_subtree(b)
	elif additive:
		_toggle_selected(block)
	else:
		_selected = [block]
	_render()


## The block dict the pending press is over — a reporter pill's `inputs[key]` dict (_pending_reporter) or
## the statement at _pending {array, index}. null if the slot no longer holds a reporter / the index is
## stale / the press wasn't over a block at all.
func _pending_clicked_block() -> Variant:
	if _pending_reporter:
		var inputs: Dictionary = _pending["inputs"]
		return inputs.get(String(_pending["key"]))
	if not _pending.has("array"):
		return null
	var arr: Array = _pending["array"]
	var index: int = int(_pending["index"])
	return arr[index] if index >= 0 and index < arr.size() else null


## Select `block` and everything nested inside it (M46) — the statements in its `body` substack and the
## reporter pills in its input slots, recursively. `block` is a real block dict (it has an `opcode`); a
## plain input map like a `call`'s `args` (no `opcode`) isn't itself selected, but is descended into for
## the reporter dicts it holds. Used by double-click's "select children".
func _select_subtree(block: Dictionary) -> void:
	if not _is_selected(block):
		_selected.append(block)
	_select_inputs(block.get("inputs", {}))


func _select_inputs(inputs: Dictionary) -> void:
	for key in inputs:
		var v: Variant = inputs[key]
		if v is Array:  # a body substack — statement dicts
			for child in v:
				if child is Dictionary:
					_select_subtree(child)
		elif v is Dictionary:
			if (v as Dictionary).has("opcode"):
				_select_subtree(v)  # a reporter pill in this slot
			else:
				_select_inputs(v)  # a plain map (a call's args): descend for its reporter values


# --- Rubber-band selection -------------------------------------------------

## Start a marquee drag over empty canvas. Snapshots the current selection when additive (Shift), so the
## rubber-band adds to it; otherwise the rectangle replaces the selection.
func _begin_marquee() -> void:
	_marquee = true
	_marquee_base = _selected.duplicate() if _pending.get("additive", false) else []
	_marquee_panel.visible = true
	_state = _DRAGGING


## Size the rubber-band rectangle and reselect the statement panels it covers (union with the additive
## base). Re-renders to refresh the highlights live; the marquee overlay is a direct child of the canvas
## (not _layer), so _render leaves it alone.
func _update_marquee(global_point: Vector2) -> void:
	var rect := _rect_from_points(_press_pos, global_point)  # global space
	_marquee_panel.position = rect.position - global_position
	_marquee_panel.size = rect.size
	var sel: Array = _marquee_base.duplicate()
	for panel in _tagged_panels(_layer):
		if not (panel as Control).get_global_rect().intersects(rect):
			continue
		var block: Variant = _block_of(panel)
		if block != null and not _contains_same(sel, block):
			sel.append(block)
	_selected = sel
	_render()


func _finish_marquee() -> void:
	_marquee = false
	_marquee_base = []
	_marquee_panel.visible = false
	_state = _IDLE
	_pending = {}


## True when a global point lands on a visible scrollbar of the enclosing ScrollContainer — so an
## empty-canvas press there is left to scroll rather than starting a marquee.
func _over_scrollbar(global_point: Vector2) -> bool:
	var view := get_parent()
	if view is ScrollContainer:
		var vb := (view as ScrollContainer).get_v_scroll_bar()
		var hb := (view as ScrollContainer).get_h_scroll_bar()
		if vb != null and vb.visible and vb.get_global_rect().has_point(global_point):
			return true
		if hb != null and hb.visible and hb.get_global_rect().has_point(global_point):
			return true
	return false


func _contains_same(arr: Array, block: Variant) -> bool:
	for b in arr:
		if is_same(b, block):
			return true
	return false


func _rect_from_points(a: Vector2, b: Vector2) -> Rect2:
	var tl := Vector2(minf(a.x, b.x), minf(a.y, b.y))
	return Rect2(tl, Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) - tl)


# --- Multi-block move / delete / duplicate ---------------------------------

## Gather a 2+ selection into one run and drag it together (M46). Removes each topmost-selected block
## from its array (by identity — not Array.erase, which compares dicts by value and could mis-match two
## equal blocks), drops any emptied top-level stack, and floats the gathered blocks as a single ghost
## stack. From there the normal _drop snaps the run into a gap, lands it free, or (over the palette,
## M16) deletes it. Selection is cleared as part of the pickup.
func _begin_multi_drag() -> void:
	var picks := _topmost_selected_in_order()
	if picks.is_empty():
		return
	# Anchor the ghost to the block actually under the cursor (measured before removal), so the run
	# doesn't jump to a different selected block's position when the pickup begins.
	var arr: Array = _pending["array"]
	var index: int = _pending["index"]
	var grabbed_block: Variant = arr[index] if index < arr.size() else picks[0]["block"]
	_grab_offset = _press_pos - _panel_top_left_of(grabbed_block)
	_grabbed = []
	for pick in picks:
		_grabbed.append(pick["block"])
		_remove_block(pick["array"], pick["block"])
	for s in range(_stacks.size() - 1, -1, -1):
		if (_stacks[s]["blocks"] as Array).is_empty():
			_stacks.remove_at(s)
	_selected = []
	_dragging_reporter = false
	_render()
	_ghost = BlockView.build_stack(_grabbed)
	_passthrough(_ghost)
	_ghost.modulate.a = 0.75
	add_child(_ghost)
	_ghost.size = _ghost.get_combined_minimum_size()
	_state = _DRAGGING


## Delete the current selection (M46) — the keyboard route (Delete/Backspace); dragging a selection onto
## the palette deletes it via _begin_multi_drag + _drop's trash branch. Removes each topmost-selected
## block (its body goes with it) and drops any emptied top-level stack.
func _delete_selection() -> void:
	for pick in _topmost_selected_in_order():
		_remove_block(pick["array"], pick["block"])
	for s in range(_stacks.size() - 1, -1, -1):
		if (_stacks[s]["blocks"] as Array).is_empty():
			_stacks.remove_at(s)
	_selected = []
	_render()


## Duplicate the current selection (M46, Cmd/Ctrl+D): deep-copy the topmost-selected run into a new
## free-floating stack offset from the originals, and select the copies so a further drag moves them.
func _duplicate_selection() -> void:
	var picks := _topmost_selected_in_order()
	if picks.is_empty():
		return
	var copies: Array = []
	for pick in picks:
		copies.append((pick["block"] as Dictionary).duplicate(true))
	var anchor := Vector2(24, 24)
	if not _stacks.is_empty():
		anchor = (_stacks[0]["pos"] as Vector2) + Vector2(30, 30)
	_stacks.append({"blocks": copies, "pos": anchor})
	_selected = copies
	_render()


## Remove `block` from `arr` by identity (the first is_same match).
func _remove_block(arr: Array, block: Variant) -> void:
	for i in range(arr.size()):
		if is_same(arr[i], block):
			arr.remove_at(i)
			return


## The on-screen top-left of the panel rendering `block`, by identity — used to anchor a multi-drag ghost
## before the blocks are removed. Falls back to the press position if no panel is found.
func _panel_top_left_of(block: Variant) -> Vector2:
	for panel in _tagged_panels(_layer):
		if is_same(_block_of(panel), block):
			return panel.get_global_rect().position
	return _press_pos


# --- Keyboard -------------------------------------------------------------

## Keyboard ops on the selection (M46): Delete/Backspace removes it, Cmd/Ctrl+D duplicates it. Ignored
## while a text field is focused (so typing — incl. Delete — inside a literal is unaffected) or nothing
## is selected. set_input_as_handled only when we actually act, so other keys propagate untouched.
func _handle_key(event: InputEventKey) -> void:
	if not event.pressed or event.echo or _selected.is_empty():
		return
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return
	if event.keycode == KEY_DELETE or event.keycode == KEY_BACKSPACE:
		_delete_selection()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_D and (event.meta_pressed or event.ctrl_pressed):
		_duplicate_selection()
		get_viewport().set_input_as_handled()
