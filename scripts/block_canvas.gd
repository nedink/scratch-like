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
## into an array. A reporter released off any slot lands as a **free-floating top-level stack**
## (M46 — Scratch's loose reporter on the workspace; through M45 it was discarded). It is inert at
## runtime (run() starts only hats, so a loose reporter never executes) but persists with the project.
##
## M15 adds the reverse: **grab a reporter pill already in a slot** to pull it back out.
## A press over a pill (checked before the statement it sits in, _reporter_at) detaches the
## reporter dict, leaves the slot's default literal behind (slot_default — we never kept the
## literal the reporter displaced), and rides the very same _dragging_reporter flow as a
## palette spawn: re-drop it into another slot, drop it on empty canvas to leave it floating, or
## drag it onto the palette to delete it. A free-floating reporter is itself grabbable again (it is
## its own top-level stack, found by _block_at — M46). A pill whose interior is entirely a literal field — a
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
var _grabbed_collapsed := false  # (M47) the grab took a whole collapsed stack — re-home it collapsed if it lands free

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

## --- Keyboard authoring mode (M51) ---
## A keyboard cursor that lives *alongside* mouse drag/drop — click to place it, arrows/Tab to move it,
## Enter/typing to open a fuzzy block picker that inserts a block at the cursor. Like selection (M46) it
## is editor-only UI state, never serialized, and stored as **data references** (a live Array + index, or
## a live inputs dict + key) so it survives _render() — re-resolved to a widget each render by matching
## the same meta BlockView stamps. Tagged by `kind`:
##   * {"kind": "gap",  "array": <live body Array>, "index": int}  — an insertion point (0..size)
##   * {"kind": "slot", "inputs": <live inputs dict>, "key": String} — an input slot of a block
##   * {"kind": "new",  "pos": Vector2 (canvas-local)}              — "start a new top-level stack here"
##   * {} — no cursor.
## Nested reporter expressions (move (score + 1)) are built recursively: a reporter picked into a slot
## drops the cursor into its first operand, so you fill it (with a literal or another reporter) and Tab on.
var _cursor: Dictionary = {}
var _caret: Panel                  # the cursor marker overlay (a direct canvas child, never freed by _render)
var _caret_bar_style: StyleBoxFlat  # filled bar — a gap / new insertion point
var _caret_box_style: StyleBoxFlat  # hollow outline — a slot
var _picker: PopupPanel            # the shared fuzzy block picker, built lazily (see _ensure_picker)
var _picker_edit: LineEdit
var _picker_list: ItemList
var _picker_opcodes: Array = []    # the candidate opcodes for the open picker (scoped by the cursor)


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

	# The keyboard cursor marker (M51): a bright-green filled bar at a gap / new-stack point, or a
	# hollow outline around a slot — deliberately a different hue from the gold snap bar and the white
	# selection border so the three read apart. A direct child of the canvas (added after _layer), so it
	# draws above the blocks and _render never frees it.
	_caret = Panel.new()
	_caret.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_caret_bar_style = StyleBoxFlat.new()
	_caret_bar_style.bg_color = Color("#5dff9b")
	_caret_bar_style.set_corner_radius_all(2)
	_caret_box_style = StyleBoxFlat.new()
	_caret_box_style.bg_color = Color(0, 0, 0, 0)
	_caret_box_style.border_color = Color("#5dff9b")
	_caret_box_style.set_border_width_all(2)
	_caret_box_style.set_corner_radius_all(3)
	_caret.visible = false
	add_child(_caret)


## Load a sprite's script for editing. Deep-duplicated so dragging mutates only this
## working copy, not the array passed in. Each top-level block becomes one stack, laid
## out down the canvas.
func load_script(script: Array) -> void:
	_cancel_drag()
	_selected = []  # a sprite switch starts with nothing selected (M46)
	_cursor = {}    # …and with no keyboard cursor (M51) — it would point into the outgoing script
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
	_drop_empty_stacks()
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
	_drop_empty_stacks()
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
		# A collapsed stack (M47) renders as a one-line summary bar instead of its full tree; the bar is
		# a pure summary, so nothing inside it is interactive (no _wire_literals, no kept literal fields).
		var collapsed: bool = stack.get("collapsed", false)
		var ctrl: Control = BlockView.build_collapsed_stack(stack["blocks"]) if collapsed \
			else BlockView.build_stack(stack["blocks"])
		# A multi-block script (something to hide) gets a collapse chevron inside its first block's
		# header, to the right of the text — so it reads as part of the block (M47).
		if BlockView.count_blocks(stack["blocks"]) > 1:
			_add_collapse_chevron(ctrl, stack, collapsed)
		# Pass the block through to _input (so the wheel still reaches the ScrollContainer and we hit-test
		# presses ourselves); the chevron is found by its global rect, not its mouse_filter, so leaving it
		# IGNORE is fine. A collapsed bar keeps no editable fields — it's a summary, not a header.
		_passthrough(ctrl, not collapsed)
		if not collapsed:
			_wire_literals(ctrl)
		_layer.add_child(ctrl)
		ctrl.position = stack["pos"]
		ctrl.size = ctrl.get_combined_minimum_size()
		extent = extent.max(ctrl.position + ctrl.size)
	_apply_selection_highlight()  # outline the selected blocks (M46)
	_update_caret()               # re-resolve + redraw the keyboard cursor (M51)
	_fit_to_content(extent)


## Add the collapse chevron (M47) into the first block's header, to the right of its text — so it reads
## as part of the block. The chevron carries the stack dict as the `collapse_stack` meta, so a press on
## it (found by global rect in _collapse_toggle_at, checked before any grab) flips that stack's
## `collapsed`. The glyphs are plain ASCII (+ / -) so they render in the web export too, unlike the
## geometric-triangle Unicode that tofus there: + = collapsed (click to expand) / - = expanded (click to
## collapse). An expanding spacer pushes the glyph to the header's right edge — for a hat/C-block, whose
## panel is as wide as its body, that right-justifies it the full block width away from the text.
func _add_collapse_chevron(ctrl: Control, stack: Dictionary, collapsed: bool) -> void:
	var header := _first_header(ctrl, collapsed)
	if header == null:
		return
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var chevron := Label.new()
	chevron.text = "+" if collapsed else "-"
	chevron.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	chevron.set_meta("collapse_stack", stack)
	header.add_child(chevron)


## The header row (HBoxContainer) of the first block in a rendered top-level stack — where the chevron is
## attached. A collapsed bar exposes its summary row as %Row; an expanded stack's first child is the
## block panel, whose header is the first HBox under its %Content (a statement/hat) or directly under the
## panel (a free-floating reporter pill).
func _first_header(ctrl: Control, collapsed: bool) -> HBoxContainer:
	if collapsed:
		return ctrl.get_node_or_null("%Row") as HBoxContainer
	if ctrl.get_child_count() == 0:
		return null
	var panel := ctrl.get_child(0)
	var content := panel.get_node_or_null("%Content")
	var container: Node = content if content != null else panel
	for c in container.get_children():
		if c is HBoxContainer:
			return c as HBoxContainer
	return null


## Where a free-landing dragged stack should store its `pos` (M47). The ghost is the bare block(s) and
## _render now draws the block with no left gutter, so the two share a left edge — the ghost position is
## exactly where the landed block should sit.
func _land_pos() -> Vector2:
	return _ghost.position


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
			# A press on a collapse chevron (M47) toggles that script's collapsed state — checked
			# before any grab / marquee so the chevron never selects, drags, or clears. Commit any
			# open field edit first, as a grab would.
			var toggle: Variant = _collapse_toggle_at(event.position)
			if toggle != null:
				get_viewport().gui_release_focus()
				var st := toggle as Dictionary  # the stack dict (a reference into _stacks)
				st["collapsed"] = not st.get("collapsed", false)
				_render()
				get_viewport().set_input_as_handled()
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
				# A reporter drag (targets slots / re-homes free, M46) when the press is on an in-slot
				# pill (rep) OR a free-floating reporter — a top-level stack whose single block is a
				# reporter, found by _block_at. A statement press is a normal stack drag.
				_pending_reporter = not rep.is_empty() or _hit_is_reporter(hit)
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


## The stack dict whose collapse chevron (M47) is under a global point, or null. The chevron carries its
## owning stack dict as the `collapse_stack` meta (stamped in _add_collapse_chevron), so the press handler
## can flip that stack's `collapsed` directly. Checked before _front_stack_at — the chevron sits inside
## the first block's header, so this gives a press on it priority over grabbing the block it lives in.
func _collapse_toggle_at(global_point: Vector2) -> Variant:
	for c in _chevrons(_layer):
		if (c as Control).get_global_rect().has_point(global_point):
			return c.get_meta("collapse_stack")
	return null


func _chevrons(node: Node, out: Array = []) -> Array:
	if node is Control and node.has_meta("collapse_stack"):
		out.append(node)
	for child in node.get_children():
		_chevrons(child, out)
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
## to the freshly-built body column by is_same. Walks up to the **outermost** stack column (the topmost
## ancestor carrying `body_array` — the top-level stack's blocks); its body_array is [define_dict] for a
## define stack, whose body is returned.
func _enclosing_define_body(node: Node) -> Variant:
	var n: Node = node
	var top_column: Control = null
	while n != null:
		if n is Control and (n as Control).has_meta("body_array"):
			top_column = n  # keep climbing — the last (outermost) match is the top-level stack column
		n = n.get_parent()
	if top_column == null:
		return null
	var arr: Array = top_column.get_meta("body_array", [])
	if not arr.is_empty() and typeof(arr[0]) == TYPE_DICTIONARY \
			and String((arr[0] as Dictionary).get("opcode", "")) == "define":
		return (arr[0] as Dictionary).get("inputs", {}).get("body")
	return null


# --- Drag lifecycle --------------------------------------------------------

## Begin dragging freshly-spawned blocks (the M11 palette hand-off). Unlike _begin_drag
## there is nothing to detach — the blocks are new and already live only on the cursor —
## so we just seed _grabbed, build the ghost, and fall into the existing drag flow.
## `blocks` must be freshly made (BlockView.make_block), since _drop splices them straight
## into the canvas data. `global_point` is the cursor position to anchor the first frame.
func begin_spawn_drag(blocks: Array, global_point: Vector2) -> void:
	_cancel_drag()
	_grabbed_collapsed = false  # a fresh spawn is never a collapsed stack (M47)
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
	# Multi-block move (M46): if the grabbed block is part of a 2+ selection, gather the whole
	# selection (topmost-selected, in document order) and drag it as one run, leaving the rest behind.
	# Covers statements AND free-floating reporters (both are blocks in a top-level stack, so both have
	# `array`); an in-slot pill press has no `array` and so never multi-drags — it pulls out of its slot.
	if _pending.has("array") and _selected.size() >= 2:
		var clicked: Variant = _pending_clicked_block()
		if clicked != null and _is_selected(clicked):
			_begin_multi_drag()
			return
	if _pending_reporter:
		_begin_reporter_drag()
		return
	var arr: Array = _pending["array"]
	var index: int = _pending["index"]
	# Dragging a single / unselected block manipulates just that run — drop any standing selection.
	_selected = []

	# If this grab takes a whole collapsed top-level stack (its bar is the only grab target, so the
	# press is always at index 0 of the stack's blocks), remember so _drop re-homes it still collapsed
	# (M47). Any other grab — a block out of a stack, an expanded stack — re-homes expanded.
	_grabbed_collapsed = false
	for stack in _stacks:
		if index == 0 and is_same(stack["blocks"], arr) and stack.get("collapsed", false):
			_grabbed_collapsed = true
			break

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


## True when `hit` (a _block_at result) names a free-floating reporter — a top-level stack whose
## block is a reporter (M46). Such a press starts a reporter drag (targets slots / re-homes free)
## rather than a statement drag, even though _block_at, not _reporter_at, found it.
func _hit_is_reporter(hit: Dictionary) -> bool:
	if not hit.has("array"):
		return false
	var arr: Array = hit["array"]
	var index: int = int(hit["index"])
	if index < 0 or index >= arr.size():
		return false
	var block: Variant = arr[index]
	return block is Dictionary and BlockView.is_reporter(String((block as Dictionary).get("opcode", "")))


## Start a single reporter pill floating as a _dragging_reporter drag. Two origins (M46): an **in-slot**
## pill (M15) detaches out of its slot, which reverts to its opcode default literal (slot_default, since
## we never kept the literal the reporter displaced); a **free-floating** reporter (its own top-level
## stack) detaches by dropping that stack. From here it targets slots, re-homes free on empty canvas, or
## (over the palette) deletes — see _drop / begin_spawn_drag.
func _begin_reporter_drag() -> void:
	_grabbed_collapsed = false  # a single reporter is never a collapsed stack (M47)
	var reporter: Variant
	if _pending.has("array"):
		# Free-floating reporter: lift it out of its top-level stack and drop the now-empty stack.
		var arr: Array = _pending["array"]
		var index: int = int(_pending["index"])
		reporter = arr[index]
		_grab_offset = _press_pos - _grabbed_block_top_left(arr, index)
		for s in range(_stacks.size() - 1, -1, -1):
			if is_same(_stacks[s]["blocks"], arr):
				_stacks.remove_at(s)
		_selected = []
	else:
		var inputs: Dictionary = _pending["inputs"]
		var key: String = _pending["key"]
		reporter = inputs.get(key)

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
## here deletes them. Otherwise: a reporter drops into the targeted slot (overwriting its live
## `inputs[key]`) or, off any slot, lands as a **free-floating top-level stack** (M46 — Scratch's
## loose reporter on the workspace; a confined `param` drag is the exception, discarded off its
## body); a statement stack splices into the snap gap if one is active, else lands free. Then
## re-render from the data.
func _drop() -> void:
	if _trashing:
		pass  # over the palette: delete the grabbed blocks (don't re-home them)
	elif _dragging_reporter:
		if not _snap.is_empty():
			var inputs: Dictionary = _snap["inputs"]
			inputs[String(_snap["key"])] = _grabbed[0]
		elif _spawn_scope_body == null:
			# Off every slot: land the reporter as its own free-floating stack. A confined `param`
			# (scope set) has no home outside its define body, so it is discarded (M31) instead.
			_stacks.append({"blocks": _grabbed, "pos": _land_pos()})
	elif not _snap.is_empty():
		var arr: Array = _snap["array"]
		var index: int = _snap["index"]
		for i in range(_grabbed.size()):
			arr.insert(index + i, _grabbed[i])
	else:
		# Land free — keeping it collapsed if it was grabbed as a whole collapsed stack (M47).
		_stacks.append({"blocks": _grabbed, "pos": _land_pos(), "collapsed": _grabbed_collapsed})
	_clear_drag_overlays()
	_render()


## Abandon any in-progress drag without committing it (used by load_script). The
## grabbed blocks are already detached from the data, so re-home them as a loose stack
## rather than losing them.
func _cancel_drag() -> void:
	# A statement stack or a free reporter is re-homed so it isn't lost (a reporter now has a top-level
	# home, M46); a confined `param` drag (scope set) is discarded — it has no home outside its body.
	if _state == _DRAGGING and not _grabbed.is_empty() and _spawn_scope_body == null:
		_stacks.append({"blocks": _grabbed, "pos": _land_pos(), "collapsed": _grabbed_collapsed})
	_cursor = {}  # an abandoned drag (sprite switch) drops the keyboard cursor too (M51)
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
# Selection is a set of block dicts (by identity) — statement blocks, in-slot reporter pills, and
# free-floating reporters alike. It is editor-only UI state, never serialized. Three ways in — click
# (Shift/Cmd to toggle), double-click (the block + everything after it in this script, plus its nested
# children), and rubber-band over empty canvas — and three things you can do with it: delete
# (Delete/Backspace, or drag onto the palette/trash), move together (drag any selected block), and
# duplicate (Cmd/Ctrl+D). Move/delete/duplicate act on the *statement-level* picks (statements and
# free-floating reporters — both are blocks in a top-level stack); an in-slot pill is highlight-only.
# The drag and trash paths reuse the existing _begin_drag / _drop machinery.

## The block dict a rendered top-level panel stands for (a statement, or a free-floating reporter pill —
## M46), via the blk_array/blk_index meta BlockView stamps. null if the index is stale (shouldn't happen
## between renders).
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
		# A plain click on empty canvas (M51): clear the selection and seat a "new stack here" keyboard
		# cursor at the click point, so the user can start typing a script from nothing.
		var had_sel := not _selected.is_empty()
		_selected = []
		_cursor = {"kind": "new", "pos": _press_pos - global_position}
		if had_sel:
			_render()  # re-render to drop the selection outlines (also redraws the caret)
		else:
			_update_caret()
		return
	if _pending_spawn:
		return  # a define-hat prototype param pill spawns on drag; a click does nothing
	var block: Variant = _pending_clicked_block()
	if typeof(block) != TYPE_DICTIONARY:
		return
	# Place the keyboard cursor where the click landed (M51): on the slot of a clicked reporter pill, or
	# at the gap *before* a clicked statement / free reporter (so Enter inserts there, Right enters its
	# slots). Set before _render so _update_caret draws it on the rebuilt tree.
	if _pending.has("inputs"):
		_cursor = {"kind": "slot", "inputs": _pending["inputs"], "key": String(_pending["key"])}
	elif _pending.has("array"):
		_cursor = {"kind": "gap", "array": _pending["array"], "index": int(_pending["index"])}
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


## The block dict the pending press is over — keyed off the `_pending` shape: a statement or a
## free-floating reporter at {array, index} (from _block_at), else an in-slot reporter pill's
## `inputs[key]` dict (from _reporter_at). null if the index is stale / the slot no longer holds a
## reporter / the press wasn't over a block.
func _pending_clicked_block() -> Variant:
	if _pending.has("array"):
		var arr: Array = _pending["array"]
		var index: int = int(_pending["index"])
		return arr[index] if index >= 0 and index < arr.size() else null
	if _pending.has("inputs"):
		var inputs: Dictionary = _pending["inputs"]
		return inputs.get(String(_pending["key"]))
	return null


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
	_grabbed_collapsed = false  # a gathered multi-selection lands expanded (M47)
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
	_drop_empty_stacks()
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
	_drop_empty_stacks()
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

## Keyboard ops on the selection (M46): Delete/Backspace removes it, Cmd/Ctrl+D duplicates it,
## Cmd/Ctrl+E collapses/expands the scripts it touches (M47). Ignored while a text field is focused (so
## typing — incl. Delete — inside a literal is unaffected) or nothing is selected. set_input_as_handled
## only when we actually act, so other keys propagate untouched.
func _handle_key(event: InputEventKey) -> void:
	if not event.pressed or event.echo:
		return
	# The fuzzy picker (M51) owns its own keys while open (driven by _picker_edit.gui_input) — never let
	# the canvas steal them.
	if _picker != null and _picker.visible:
		return
	# A focused literal field (M12) owns typing/Backspace — leave it untouched (so editing a value, incl.
	# deleting characters, is unaffected by the navigation/selection ops below).
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return
	var kc := event.keycode
	# Keyboard authoring (M51): navigation / picker / type-to-edit, driven by the cursor and independent
	# of the selection. Handled first so arrows/Tab/Enter/typing work whenever a cursor is placed.
	if not _cursor.is_empty() and _handle_cursor_nav(event):
		get_viewport().set_input_as_handled()
		return
	# Selection ops (M46/M47): act on the multi-selection when there is one.
	if not _selected.is_empty():
		if kc == KEY_DELETE or kc == KEY_BACKSPACE:
			_delete_selection()
			get_viewport().set_input_as_handled()
		elif kc == KEY_D and (event.meta_pressed or event.ctrl_pressed):
			_duplicate_selection()
			get_viewport().set_input_as_handled()
		elif kc == KEY_E and (event.meta_pressed or event.ctrl_pressed):
			_toggle_collapse_selection()
			get_viewport().set_input_as_handled()
		return
	# Cursor delete (M51): with no selection, Delete/Backspace removes the block at/around the cursor (or
	# reverts a reporter slot to its default). Left to last so a real selection-delete wins when both exist.
	if not _cursor.is_empty() and (kc == KEY_DELETE or kc == KEY_BACKSPACE):
		_cursor_delete(kc == KEY_DELETE)
		get_viewport().set_input_as_handled()


## Collapse / expand every top-level script the selection touches (M47, Cmd/Ctrl+E). Only collapsible
## stacks (more than one block — a lone block has nothing to hide) participate. The toggle is uniform:
## if any touched script is currently expanded, collapse them all; otherwise expand them all — so a
## mixed selection resolves to one consistent state rather than flipping each independently.
func _toggle_collapse_selection() -> void:
	var stacks := _stacks_with_selection()
	if stacks.is_empty():
		return
	var any_expanded := false
	for st in stacks:
		var d := st as Dictionary
		if BlockView.count_blocks(d["blocks"]) > 1 and not d.get("collapsed", false):
			any_expanded = true
			break
	for st in stacks:
		var d := st as Dictionary
		if BlockView.count_blocks(d["blocks"]) > 1:
			d["collapsed"] = any_expanded
	_render()


## The top-level stacks containing any selected block (M47) — a stack qualifies if a selected block is
## one of its statements or nested in a C-block body (the structure a collapse acts on). An in-slot
## reporter pill selection isn't matched here; you collapse a script by selecting its blocks.
func _stacks_with_selection() -> Array:
	var out: Array = []
	for stack in _stacks:
		if _blocks_contain_selected(stack["blocks"]):
			out.append(stack)
	return out


func _blocks_contain_selected(blocks: Array) -> bool:
	for b in blocks:
		if typeof(b) != TYPE_DICTIONARY:
			continue
		if _is_selected(b):
			return true
		var body: Variant = (b.get("inputs", {}) as Dictionary).get("body")
		if body is Array and _blocks_contain_selected(body):
			return true
	return false


# --- Keyboard authoring: cursor + fuzzy picker (M51) -----------------------

## Move the keyboard cursor and redraw its marker. No _render() — the block tree is unchanged by a
## pure navigation; only the overlay moves. (Structural edits call _render(), which redraws the caret.)
func _set_cursor(c: Dictionary) -> void:
	_cursor = c
	_update_caret()


## Drop any top-level stack left empty by an edit (shared by the delete cascades, multi-drag, and the
## cursor delete). The _begin_drag pickup keeps its own is_same-guarded version (it must not drop the
## stack it is mid-detaching from).
func _drop_empty_stacks() -> void:
	for s in range(_stacks.size() - 1, -1, -1):
		if (_stacks[s]["blocks"] as Array).is_empty():
			_stacks.remove_at(s)


## Re-resolve the cursor to the current Control tree and redraw the caret marker. Called at the end of
## _render() (so the cursor survives a rebuild) and after every cursor move. Purely a *draw* — it never
## mutates `_cursor` (doing so here would wipe a still-valid cursor whenever its marker can't be drawn,
## e.g. a gap in a collapsed stack that renders no body column — and crash the picker, which keys off the
## cursor data). An unresolvable marker just hides the caret; the cursor's data stays usable for insert /
## navigation, and a genuinely stale cursor is harmless (inserting into an orphan array is a no-op).
func _update_caret() -> void:
	var g := _cursor_global_rect()
	if g.is_empty():
		_caret.visible = false
		return
	var kind := String(g["kind"])
	var rect: Rect2 = g["rect"]
	var local := rect.position - global_position
	if kind == "slot":
		_caret.add_theme_stylebox_override("panel", _caret_box_style)
		_caret.position = local
		_caret.size = rect.size
	else:  # gap / new — a thin insertion bar
		_caret.add_theme_stylebox_override("panel", _caret_bar_style)
		_caret.position = local
		_caret.size = Vector2(maxf(rect.size.x, 60.0), 3.0)
	_caret.visible = true


## The cursor's marker geometry as a global-space {kind, rect}, or {} if it doesn't resolve.
func _cursor_global_rect() -> Dictionary:
	var kind := String(_cursor.get("kind", ""))
	if kind == "new":
		var pos: Vector2 = _cursor.get("pos", Vector2.ZERO)
		return {"kind": "new", "rect": Rect2(global_position + pos, Vector2(80, 3))}
	if kind == "slot":
		var ctrl := _cursor_control()
		if ctrl == null:
			return {}
		return {"kind": "slot", "rect": ctrl.get_global_rect()}
	if kind == "gap":
		var arr: Array = _cursor["array"]
		var r: Variant = _gap_global_marker(arr, int(_cursor["index"]))
		if r == null:
			return {}
		return {"kind": "gap", "rect": r}
	return {}


## The global rect (a thin bar) of the gap at `index` of the live body Array `arr`, mirroring _all_gaps:
## before the index-th block, after the last block, or the empty body column. null if `arr` isn't rendered.
func _gap_global_marker(arr: Array, index: int) -> Variant:
	for column in _columns(_layer):
		if not is_same((column as Control).get_meta("body_array"), arr):
			continue
		var panels: Array = []
		for child in column.get_children():
			if child is Control and (child as Control).has_meta("blk_index"):
				panels.append(child)
		if panels.is_empty():
			var cr: Rect2 = (column as Control).get_global_rect()
			return Rect2(cr.position, Vector2(cr.size.x, 3))
		if index < panels.size():
			var pr: Rect2 = (panels[maxi(index, 0)] as Control).get_global_rect()
			return Rect2(pr.position, Vector2(pr.size.x, 3))
		var last: Rect2 = (panels[panels.size() - 1] as Control).get_global_rect()
		return Rect2(Vector2(last.position.x, last.end.y), Vector2(last.size.x, 3))
	return null


## The rendered input widget the slot cursor points at (by is_same inputs + key), or null. The same
## meta-match _reporter_at / _nearest_slot use, so it finds a literal field, an enum dropdown, or a pill.
func _cursor_control() -> Control:
	if String(_cursor.get("kind", "")) != "slot":
		return null
	var target_inputs: Dictionary = _cursor["inputs"]
	var target_key := String(_cursor["key"])
	for slot in _slots(_layer):
		var c := slot as Control
		if is_same(c.get_meta("slot_inputs"), target_inputs) and String(c.get_meta("slot_key")) == target_key:
			return c
	return null


## Handle a keyboard event against the active cursor (M51). Returns true if it acted (the caller then
## marks the event handled). Arrows/Tab navigate; Enter/typing open the picker (or focus a literal field /
## open a dropdown); Escape clears the cursor. Delete/Backspace are deliberately left to _handle_key.
func _handle_cursor_nav(event: InputEventKey) -> bool:
	match event.keycode:
		KEY_UP:
			_cursor_move_vertical(-1)
			return true
		KEY_DOWN:
			_cursor_move_vertical(1)
			return true
		KEY_LEFT:
			_cursor_move_horizontal(-1)
			return true
		KEY_RIGHT:
			_cursor_move_horizontal(1)
			return true
		KEY_TAB:
			_cursor_move_horizontal(-1 if event.shift_pressed else 1)
			return true
		KEY_ESCAPE:
			_set_cursor({})
			return true
		KEY_ENTER, KEY_KP_ENTER:
			_activate_cursor("")
			return true
	# A printable character starts the picker (or edits a literal in place). Exclude Delete (unicode 127)
	# and Backspace so they fall through to the delete path; exclude modifier combos (Cmd+D etc.).
	if event.keycode != KEY_DELETE and event.keycode != KEY_BACKSPACE \
			and event.unicode > 32 and event.unicode != 127 \
			and not (event.ctrl_pressed or event.meta_pressed or event.alt_pressed):
		_type_at_cursor(char(event.unicode))
		return true
	return false


## Enter on the cursor: open the picker (gap/new → statements/hats; slot → type-matched reporters), or —
## on an enum/data dropdown slot — open that dropdown instead.
func _activate_cursor(seed: String) -> void:
	if String(_cursor.get("kind", "")) == "slot":
		var ctrl := _cursor_control()
		if ctrl is OptionButton:
			(ctrl as OptionButton).show_popup()
			return
	_open_picker(seed)


## A printable char at the cursor: edit a literal slot's field in place (focus it and seed the char), open
## an enum dropdown, else open the block picker seeded with the char (a gap, or a reporter slot).
func _type_at_cursor(ch: String) -> void:
	if String(_cursor.get("kind", "")) == "slot":
		var ctrl := _cursor_control()
		if ctrl is LineEdit:
			var le := ctrl as LineEdit
			le.grab_focus()
			le.text = ch
			le.caret_column = le.text.length()
			return
		if ctrl is OptionButton:
			(ctrl as OptionButton).show_popup()
			return
	_open_picker(ch)


## Up/Down: step the cursor through the statement gaps in document order (_ordered_gaps), clamped (no
## wrap). From a slot, first resolve to the gap before the statement that contains it.
func _cursor_move_vertical(dir: int) -> void:
	var gaps := _ordered_gaps()
	if gaps.is_empty():
		return
	var cur := _current_gap_pos()
	var idx := _index_of_gap(gaps, cur)
	if idx == -1:
		idx = 0 if dir > 0 else gaps.size() - 1
	else:
		idx = clampi(idx + dir, 0, gaps.size() - 1)
	var g: Dictionary = gaps[idx]
	_set_cursor({"kind": "gap", "array": g["array"], "index": int(g["index"])})


## Left/Right/Tab: walk the current block's header slots (left-to-right, descending into nested reporter
## pills). From a gap, Right/Tab enters the first slot of the block after it; Left at a slot's start (or
## Shift+Tab past it) ascends back to the gap before the owning statement.
func _cursor_move_horizontal(dir: int) -> void:
	var kind := String(_cursor.get("kind", ""))
	if kind == "new":
		return
	if kind == "gap":
		if dir <= 0:
			return
		var arr: Array = _cursor["array"]
		var idx := int(_cursor["index"])
		if idx < 0 or idx >= arr.size():
			return
		var blk: Variant = arr[idx]
		if not (blk is Dictionary):
			return
		var panel := _panel_for_block(blk)
		if panel == null:
			return
		var slots := _header_slots(panel)
		if not slots.is_empty():
			_enter_slot(slots[0] as Control)
		return
	# slot:
	var ctrl := _cursor_control()
	if ctrl == null:
		return
	var stmt := _owning_statement_panel(ctrl)
	if stmt == null:
		return
	var hslots := _header_slots(stmt)
	var pos := _index_of_same(hslots, ctrl)
	if pos == -1:
		return
	var nxt := pos + dir
	if nxt < 0:
		var owner := _find_owner_statement_top(_cursor["inputs"])
		if not owner.is_empty():
			_set_cursor({"kind": "gap", "array": owner["array"], "index": int(owner["index"])})
		return
	if nxt >= hslots.size():
		return  # past the last header slot: stay (v1)
	_enter_slot(hslots[nxt] as Control)


## The {array, index} gap the cursor currently corresponds to (for vertical navigation): a gap cursor as
## itself, a slot cursor as the gap before its containing statement, a "new" cursor as {} (no anchor).
func _current_gap_pos() -> Dictionary:
	var kind := String(_cursor.get("kind", ""))
	if kind == "gap":
		return {"array": _cursor["array"], "index": int(_cursor["index"])}
	if kind == "slot":
		return _find_owner_statement_top(_cursor["inputs"])
	return {}


## Every statement gap across the canvas in document order — a data walk of _stacks (each blocks array,
## recursing into C-block/hat bodies), independent of the rendered tree. Collapsed stacks are skipped.
func _ordered_gaps() -> Array:
	var out: Array = []
	for stack in _stacks:
		if stack.get("collapsed", false):
			continue
		_walk_gaps(stack["blocks"], out)
	return out


func _walk_gaps(arr: Array, out: Array) -> void:
	for i in range(arr.size()):
		out.append({"array": arr, "index": i})
		var b: Variant = arr[i]
		if b is Dictionary:
			var inputs: Dictionary = (b as Dictionary).get("inputs", {})
			var body: Variant = inputs.get("body")
			if body is Array:
				_walk_gaps(body, out)
	out.append({"array": arr, "index": arr.size()})


func _index_of_gap(gaps: Array, cur: Dictionary) -> int:
	if cur.is_empty():
		return -1
	var cur_arr: Array = cur["array"]
	var cur_idx := int(cur["index"])
	for i in range(gaps.size()):
		var g: Dictionary = gaps[i]
		if int(g["index"]) == cur_idx and is_same(g["array"], cur_arr):
			return i
	return -1


func _enter_slot(slot_ctrl: Control) -> void:
	_set_cursor({"kind": "slot", "inputs": slot_ctrl.get_meta("slot_inputs"),
		"key": String(slot_ctrl.get_meta("slot_key"))})


## The input slots in a block's *header* (its own inputs + nested reporter pills), in left-to-right tree
## order — NOT descending into a C-block body column (those slots belong to other statements, reached via
## Up/Down). Used for Tab/Left/Right slot navigation within one block.
func _header_slots(node: Node, out: Array = []) -> Array:
	for child in node.get_children():
		if child is Control and (child as Control).has_meta("body_array"):
			continue  # a body substack — skip it and its slots
		if child is Control and (child as Control).has_meta("slot_key"):
			out.append(child)
		_header_slots(child, out)
	return out


## The nearest ancestor statement / free-reporter panel (a blk_index-tagged Control) of `ctrl`, or null.
func _owning_statement_panel(ctrl: Control) -> Control:
	var n: Node = ctrl
	while n != null and n != _layer:
		if n is Control and (n as Control).has_meta("blk_index"):
			return n as Control
		n = n.get_parent()
	return null


func _panel_for_block(block: Variant) -> Control:
	for p in _tagged_panels(_layer):
		if is_same(_block_of(p), block):
			return p as Control
	return null


func _index_of_same(arr: Array, ctrl: Control) -> int:
	for i in range(arr.size()):
		if is_same(arr[i], ctrl):
			return i
	return -1


## The {array, index} of the top-level-walk statement whose subtree (header inputs / nested reporters)
## contains `inputs` — the statement a slot belongs to, even when the slot is inside a nested reporter.
func _find_owner_statement_top(inputs: Dictionary) -> Dictionary:
	for stack in _stacks:
		var r := _find_owner_statement(stack["blocks"], inputs)
		if not r.is_empty():
			return r
	return {}


func _find_owner_statement(blocks: Array, target: Dictionary) -> Dictionary:
	for i in range(blocks.size()):
		var b: Variant = blocks[i]
		if not (b is Dictionary):
			continue
		var binputs: Dictionary = (b as Dictionary).get("inputs", {})
		if _inputs_reach(binputs, target):
			return {"array": blocks, "index": i}
		var body: Variant = binputs.get("body")
		if body is Array:
			var r := _find_owner_statement(body, target)
			if not r.is_empty():
				return r
	return {}


## Whether `target` is `inputs` itself or the inputs of any reporter nested within it (descending through
## reporter slots and plain arg maps, but NOT through `body` arrays — those are statement substacks).
func _inputs_reach(inputs: Dictionary, target: Dictionary) -> bool:
	if is_same(inputs, target):
		return true
	for k in inputs:
		var v: Variant = inputs[k]
		if v is Dictionary:
			var d: Dictionary = v
			if d.has("opcode"):
				if _inputs_reach(d.get("inputs", {}), target):
					return true
			elif _inputs_reach(d, target):  # a plain map (a call's args)
				return true
	return false


## Delete at the cursor: at a gap, remove the block after (Delete) or before (Backspace) it; at a slot
## holding a reporter, revert that slot to its default literal (the M15 grab-out behaviour).
func _cursor_delete(after: bool) -> void:
	var kind := String(_cursor.get("kind", ""))
	if kind == "gap":
		var arr: Array = _cursor["array"]
		var idx := int(_cursor["index"])
		if after:
			if idx < arr.size():
				arr.remove_at(idx)
		elif idx > 0:
			arr.remove_at(idx - 1)
			_cursor["index"] = idx - 1
		_drop_empty_stacks()
		_render()
	elif kind == "slot":
		var inputs: Dictionary = _cursor["inputs"]
		var key := String(_cursor["key"])
		if typeof(inputs.get(key)) == TYPE_DICTIONARY:
			var ctrl := _cursor_control()
			if ctrl != null and ctrl.has_meta("slot_default"):
				inputs[key] = ctrl.get_meta("slot_default")
				_render()


## The expected type ("value"/"boolean") of the slot the cursor is on — scopes the reporter picker.
func _cursor_slot_type() -> String:
	var ctrl := _cursor_control()
	if ctrl != null:
		return String(ctrl.get_meta("slot_type", "value"))
	return "value"


## The first template slot key of a freshly-made block (for descending the cursor into a nested reporter),
## or "" if it has none / only a body.
func _first_slot_key(block: Dictionary) -> String:
	var op := String(block.get("opcode", ""))
	var t := BlockView.opcode_template(op)
	var i := t.find("{")
	if i == -1:
		return ""
	var c := t.find("}", i)
	var key := t.substr(i + 1, c - i - 1)
	if key == "body":
		return ""
	var inputs: Dictionary = block.get("inputs", {})
	return key if inputs.has(key) else ""


## Build the shared fuzzy block picker once — a PopupPanel with a search LineEdit over a results ItemList
## — and reuse it (the lazy-popup pattern of BlockPalette._ensure_color_popup). A direct canvas child, so
## _render never frees it.
func _ensure_picker() -> void:
	if is_instance_valid(_picker):
		return
	_picker = PopupPanel.new()
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(240, 280)
	_picker_edit = LineEdit.new()
	_picker_edit.placeholder_text = "search blocks…"
	_picker_edit.text_changed.connect(_picker_refilter)
	_picker_edit.gui_input.connect(_picker_nav)
	box.add_child(_picker_edit)
	_picker_list = ItemList.new()
	_picker_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_picker_list.custom_minimum_size = Vector2(0, 240)
	_picker_list.item_activated.connect(_picker_choose_index)
	box.add_child(_picker_list)
	_picker.add_child(box)
	_picker.popup_hide.connect(_on_picker_hide)
	add_child(_picker)


## The opcodes the picker offers, scoped to the cursor: a slot → reporters whose output matches the slot
## type (the M23 rule); a gap → statements/C-blocks; a "new" stack → those plus hats. Drawn from
## palette_groups so palette:false opcodes (define/call/param) are excluded.
func _picker_candidates() -> Array:
	var universe: Array = []
	for g in BlockView.palette_groups():
		universe.append_array((g as Dictionary)["opcodes"] as Array)
	var out: Array = []
	var kind := String(_cursor.get("kind", ""))
	if kind == "slot":
		var st := _cursor_slot_type()
		for op in universe:
			var ops := String(op)
			if BlockView.is_reporter(ops) and BlockView.reporter_output_type(ops) == st:
				out.append(ops)
	else:  # gap / new
		var allow_hats := kind == "new"
		for op in universe:
			var ops := String(op)
			if BlockView.is_reporter(ops):
				continue
			if ops in BlockView.HAT_OPCODES:
				if allow_hats:
					out.append(ops)
			else:
				out.append(ops)
	return out


## Open the picker just below the caret, scoped + seeded. The caret is a Control positioned at the cursor,
## so its screen position (which already accounts for the editor's content scale) anchors the popup; a tiny
## constant screen offset drops it below. Falls back to centred if the caret isn't shown.
func _open_picker(seed: String) -> void:
	if _cursor.is_empty():
		return
	_ensure_picker()
	_picker_opcodes = _picker_candidates()
	_update_caret()  # make sure the caret is positioned for the current cursor
	var size := Vector2i(260, 300)
	if _caret.visible:
		var screen := _caret.get_screen_position() + Vector2(0, 20)
		_picker.popup(Rect2i(Vector2i(screen), size))
	else:
		_picker.popup_centered(size)
	_picker_edit.text = seed
	_picker_refilter(seed)
	_picker_edit.grab_focus()
	_picker_edit.caret_column = _picker_edit.text.length()


## Refill the results list with the candidates fuzzy-matching `query` (subsequence over the brace-stripped
## label), ranked by prefix bonus then shorter label. Auto-selects the top hit so Enter has a target.
func _picker_refilter(query: String) -> void:
	if not is_instance_valid(_picker_list):
		return
	_picker_list.clear()
	var q := query.strip_edges().to_lower()
	var scored: Array = []
	for op in _picker_opcodes:
		var ops := String(op)
		var label := BlockView.opcode_label(ops).to_lower()
		if q == "" or q.is_subsequence_ofn(label):
			scored.append({"op": ops, "score": _match_score(q, label)})
	scored.sort_custom(func(a, b): return float(a["score"]) > float(b["score"]))
	for e in scored:
		var idx := _picker_list.add_item(BlockView.opcode_template(String(e["op"])))
		_picker_list.set_item_metadata(idx, String(e["op"]))
	if _picker_list.item_count > 0:
		_picker_list.select(0)


func _match_score(q: String, label: String) -> float:
	var s := -float(label.length()) * 0.1  # shorter labels first, all else equal
	if q == "":
		return s
	if label.begins_with(q):
		s += 100.0
	else:
		for w in label.split(" ", false):
			if w.begins_with(q):
				s += 50.0
				break
	return s


## Drive the results list from the search field (M51): Up/Down move the selection, Enter commits the
## highlighted block, Escape closes the picker — all consumed so the LineEdit keeps the typed text.
func _picker_nav(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return
	match k.keycode:
		KEY_DOWN:
			_picker_move(1)
			_picker_edit.accept_event()
		KEY_UP:
			_picker_move(-1)
			_picker_edit.accept_event()
		KEY_ENTER, KEY_KP_ENTER:
			_picker_commit()
			_picker_edit.accept_event()
		KEY_ESCAPE:
			_picker.hide()
			_picker_edit.accept_event()


func _picker_move(d: int) -> void:
	if _picker_list.item_count == 0:
		return
	var sel := _picker_list.get_selected_items()
	var cur := sel[0] if sel.size() > 0 else 0
	var nxt := clampi(cur + d, 0, _picker_list.item_count - 1)
	_picker_list.select(nxt)
	_picker_list.ensure_current_is_visible()


func _picker_commit() -> void:
	if _picker_list.item_count == 0:
		return
	var sel := _picker_list.get_selected_items()
	_picker_choose_index(sel[0] if sel.size() > 0 else 0)


func _picker_choose_index(i: int) -> void:
	if i < 0 or i >= _picker_list.item_count:
		return
	_picker_choose(String(_picker_list.get_item_metadata(i)))


## Insert the chosen block at the cursor and advance it. At a gap/new: splice the statement in (creating a
## stack for "new"); the cursor descends into its body if it's a hat/C-block, else moves to the gap after.
## At a slot: nest the reporter (overwriting whatever was there) and descend into its first operand, so
## nested expressions build recursively. Then re-render and close.
func _picker_choose(opcode: String) -> void:
	var kind := String(_cursor.get("kind", ""))
	if kind != "slot" and kind != "gap" and kind != "new":
		_picker.hide()  # no usable cursor (shouldn't happen) — don't insert into nothing
		return
	var block := BlockView.make_block(opcode)
	if kind == "slot":
		var inputs: Dictionary = _cursor["inputs"]
		inputs[String(_cursor["key"])] = block
		var fk := _first_slot_key(block)
		if fk != "":
			_cursor = {"kind": "slot", "inputs": block["inputs"], "key": fk}
		_render()
	else:
		var arr: Array
		var idx: int
		if kind == "new":
			var pos: Vector2 = _cursor.get("pos", Vector2(12, 12))
			var stack := {"blocks": [block], "pos": pos}
			_stacks.append(stack)
			arr = stack["blocks"]
			idx = 0
		else:  # gap
			arr = _cursor["array"]
			idx = clampi(int(_cursor["index"]), 0, arr.size())
			arr.insert(idx, block)
		var binputs: Dictionary = block["inputs"]
		var body: Variant = binputs.get("body")
		if body is Array:
			_cursor = {"kind": "gap", "array": body, "index": 0}
		else:
			_cursor = {"kind": "gap", "array": arr, "index": idx + 1}
		_render()
	_picker.hide()


func _on_picker_hide() -> void:
	_picker_opcodes = []
