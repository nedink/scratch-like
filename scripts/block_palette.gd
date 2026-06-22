class_name BlockPalette
extends VBoxContainer

## The Milestone 11 block palette — the source of *new* blocks. M9 let you rearrange the
## blocks a sprite already had; M11 lets you drag fresh ones in, so a script can be built
## from scratch.
##
## It stays true to the project's spine — **blocks are data** — and reuses M9's whole drag
## machinery rather than duplicating it. The palette doesn't snap or splice anything
## itself: when a press on a chip turns into a drag, it mints a fresh block dictionary
## (BlockView.make_block) and hands it to the canvas via BlockCanvas.begin_spawn_drag.
## From that instant the **canvas** owns the drag — its own _input drives the ghost, the
## snap highlight, and the drop into the live data, identical to dragging an existing
## block. So the palette is just a chooser + a hand-off.
##
## As of M14 it lists **every** kind — hats, statements, C-blocks, and reporters. A reporter
## chip is rendered as a pill (build_reporter) so it looks like what lands in a slot; on drag
## the canvas ghosts it as a pill and targets value/condition slots instead of stack gaps.
## (Through M13 reporters were filtered out because they had nowhere to drop.)
##
## Interaction mirrors the canvas's: we drive from _input with manual global hit-testing
## and a PENDING→threshold state machine, so nested chip panels never intercept the press
## and the mouse wheel still reaches the enclosing ScrollContainer. The palette consumes
## events ONLY during its own PENDING window; once it hands off it goes idle and never
## competes with the canvas for the drag's motion/release (works whatever the sibling
## tree order).

## Pixels the cursor must travel after pressing a chip before it becomes a spawn-drag, so
## a plain click doesn't fling a block onto the canvas. Matches the canvas's threshold.
const DRAG_THRESHOLD := 4.0

const _IDLE := 0
const _PENDING := 1  # pressed on a chip, not yet moved past the threshold

## Extra vertical gap inserted *above* each category header (beyond the VBox's base `separation`),
## so the palette's groups read as distinct groups. See _add_group_header.
const _GROUP_GAP := 12

## The canvas this palette feeds. Set by the editor before any interaction.
var _canvas: BlockCanvas

## Called when the "Make a Variable" button atop the variables group is pressed (M20). Set by
## the editor, which owns the project variable model and pops the name/scope dialog. Left unset
## (an invalid Callable) by any non-editor caller, in which case no button is drawn.
var _on_make_variable: Callable

## Called with a variable name when its palette row's Rename / Delete menu item is chosen (M21).
## Set by the editor (which owns the model and pops the rename/delete dialogs); left unset by a
## non-editor caller, in which case the per-variable management rows are not drawn.
var _on_rename_variable: Callable
var _on_delete_variable: Callable

## Called when the "Make a Block" button atop the My-Blocks group is pressed (M30). Set by the
## editor, which pops the name dialog and mints a `define` hat on the canvas. Left unset by a
## non-editor caller, in which case the My-Blocks group (button + call chips) isn't drawn.
var _on_make_block: Callable

## Called for the lists group (M44), the list twin of the variable callbacks: "Make a List" mints a
## list, and each in-scope list's row offers Rename / Delete. Set by the editor; left unset by a
## non-editor caller, in which case the Make button / management rows aren't drawn (the list *chips*
## still appear — they come through palette_groups like any category).
var _on_make_list: Callable
var _on_rename_list: Callable
var _on_delete_list: Callable

var _state: int = _IDLE
var _press_pos: Vector2
## The chip pressed, held through the PENDING window so the motion handler can read its opcode and
## (for a pre-named `call` chip, M30) its `palette_name` when it mints the dragged block.
var _pending_chip: Control


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	# PASS (not the default STOP) so the mouse wheel reaches the enclosing ScrollContainer
	# to scroll the list — we drive dragging from _input, not _gui_input, so we don't need
	# to capture GUI events here. (Same rationale as BlockCanvas.)
	mouse_filter = Control.MOUSE_FILTER_PASS
	_build()


## Build the chip list once: a category header, then one chip per stackable opcode, for
## each non-empty group. Each chip is a normal rendered block (so it looks exactly like
## what lands on the canvas), stamped with its opcode and made mouse-transparent so the
## wheel reaches the ScrollContainer and our _input does the hit-testing.
func _build() -> void:
	for group in BlockView.palette_groups():
		var category := String(group["category"])
		_add_group_header(category)
		# The "Make a Variable" affordance sits atop the variables group, as in Scratch (M20). It
		# is a real Button (not a mouse-ignored chip), so GUI handles its click normally; our
		# _input ignores it (it carries no `palette_opcode` meta, so _chip_at misses it) and never
		# starts a drag. It calls back to the editor, which owns the project variable model.
		if category == "variables" and _on_make_variable.is_valid():
			var make_btn := Button.new()
			make_btn.text = "Make a Variable"
			make_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			make_btn.pressed.connect(_on_make_variable)
			add_child(make_btn)
			# Beneath it, one management row per in-scope variable (M21): a button that pops a
			# Rename / Delete menu, calling back to the editor. project_variables is already the
			# editor's per-sprite scoped list (M19), so the rows re-scope on every rebuild().
			if _on_rename_variable.is_valid() or _on_delete_variable.is_valid():
				for var_name in BlockView.project_variables:
					add_child(_make_variable_row(String(var_name)))
			# The "Make a List" affordance + per-list rows sit atop the lists group (M44), the exact
			# twin of the variables group's Make button + rows — a real Button + MenuButtons, not chips,
			# so GUI handles their clicks and _chip_at skips them. The list *chips* (the 9 list blocks)
			# then follow via the generic loop below, since they carry palette:true like any category.
			if category == "lists" and _on_make_list.is_valid():
				var make_list_btn := Button.new()
				make_list_btn.text = "Make a List"
				make_list_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
				make_list_btn.pressed.connect(_on_make_list)
				add_child(make_list_btn)
				if _on_rename_list.is_valid() or _on_delete_list.is_valid():
					for list_name in BlockView.project_lists:
						add_child(_make_list_row(String(list_name)))
		var self_state_separated := false
		for opcode in group["opcodes"]:
			# The running-sprite self-state reporters (position/velocity) come last in the group
			# (palette_groups sorts them there); set them off with a separator before the first one,
			# so they read as a distinct "this sprite" cluster (M43 grouping).
			if BlockView.is_self_state_reporter(opcode) and not self_state_separated:
				_add_separator()
				self_state_separated = true
			var block := BlockView.make_block(opcode)
			# A reporter chip is drawn as a pill (build_reporter) so it matches what lands in a
			# slot; everything stackable keeps the statement/hat shape (build_block).
			var chip := BlockView.build_reporter(block) if BlockView.is_reporter(opcode) else BlockView.build_block(block)
			# Left-justify every chip in the palette column: build_reporter centres its pill
			# (SIZE_SHRINK_CENTER, for inline use in a slot), so without this reporter chips
			# would sit centred while statement/hat chips (SIZE_SHRINK_BEGIN) sit left.
			chip.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			chip.set_meta("palette_opcode", opcode)
			_passthrough(chip)
			add_child(chip)
	# The "My Blocks" (custom blocks) group, rendered specially like the variables group (M30): a
	# "Make a Block" button atop, then one draggable `call` chip per custom block the sprite defines
	# (BlockView.project_custom_blocks, re-derived per sprite by the editor — the custom-block twin of
	# the per-variable rows). `define`/`call` carry palette:false, so palette_groups never lists them as
	# generic chips; this is the only place they enter the palette. Left undrawn when the editor hasn't
	# wired the Make callback (a non-editor caller).
	if _on_make_block.is_valid():
		_add_group_header("custom", "MY BLOCKS")
		var make_btn := Button.new()
		make_btn.text = "Make a Block"
		make_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		make_btn.pressed.connect(_on_make_block)
		add_child(make_btn)
		for block_name in BlockView.project_custom_blocks:
			# A `call` chip pre-set to this procedure's name — its own palette block, as in Scratch.
			# `palette_name` carries the name through the drag so the minted block calls it (see _input).
			# Parameters (M31): give the chip one `args` slot per the block's declared parameters
			# (project_custom_block_params), so the chip shows its argument slots, and stamp
			# `palette_params` so the drag mints a matching `args` dict. Each arg defaults to 0.
			var params: Array = BlockView.project_custom_block_params.get(String(block_name), [])
			var block := BlockView.make_block("call")
			block["inputs"]["name"] = String(block_name)
			block["inputs"]["args"] = _args_for(params)
			var chip := BlockView.build_block(block)
			chip.set_meta("palette_opcode", "call")
			chip.set_meta("palette_name", String(block_name))
			chip.set_meta("palette_params", params)
			_passthrough(chip)
			add_child(chip)


## A category header label, preceded (for every group but the first) by a blank spacer so the groups
## read as distinct groups instead of one undifferentiated column — without it the VBox's uniform
## `separation` leaves a header floating equidistant between the group above and the one it labels.
## `text` overrides the default upper-cased category name (used for "MY BLOCKS", whose category is
## "custom"). The spacer/header are mouse-ignored, so the wheel still scrolls and _chip_at skips them.
func _add_group_header(category: String, text := "") -> void:
	if get_child_count() > 0:
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(0, _GROUP_GAP)
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(spacer)
	var header := Label.new()
	header.text = text if text != "" else category.to_upper()
	header.add_theme_color_override("font_color", BlockView.category_color(category))
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(header)


## A thin horizontal rule used inside a group to set off the running-sprite self-state reporters
## from the rest (M43 grouping). Mouse-ignored, like the headers/spacers, so the wheel still scrolls
## and _chip_at skips it.
func _add_separator() -> void:
	var sep := HSeparator.new()
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(sep)


## A fresh `args` dict for a `call` block (M31): one entry per parameter name, each defaulting to 0
## (a value parameter). Keyed by name in parameter order, so the rendered slots read left-to-right in
## the order the procedure declares them.
func _args_for(params: Array) -> Dictionary:
	var args := {}
	for p in params:
		args[String(p)] = 0
	return args


## Make a rendered chip transparent to mouse picking (cf. BlockCanvas._passthrough): our
## _input still sees presses over it, and the wheel still scrolls the palette. A chip is a
## throwaway template, so its editable widgets are inert here (the real editing happens
## once it lands on the canvas): mouse-ignore disables the enum dropdown (M13), and a
## literal field (M12) is additionally marked non-editable so it can't take a caret.
func _passthrough(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	if node is LineEdit:
		(node as LineEdit).editable = false
	for child in node.get_children():
		_passthrough(child)


## A management row for one in-scope variable (M21): a MenuButton labelled with the variable's
## name whose popup offers Rename / Delete. A MenuButton (not a plain Button + hand-placed
## PopupMenu) so the menu positions itself. Like the "Make a Variable" button it carries no
## `palette_opcode` meta and is left mouse-interactive (not run through _passthrough), so our
## _input drag hit-test (_chip_at) skips it and GUI handles the click. The menu routes back to the
## editor's rename/delete callbacks, bound with this row's name.
func _make_variable_row(var_name: String) -> MenuButton:
	var row := MenuButton.new()
	row.text = var_name
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var menu := row.get_popup()
	menu.add_item("Rename", 0)
	menu.add_item("Delete", 1)
	menu.id_pressed.connect(_on_variable_menu.bind(var_name))
	return row


## Route a variable row's menu choice to the editor (M21): Rename (id 0) or Delete (id 1), each
## with the row's variable name. The callbacks pop the editor's dialogs and mutate the model.
func _on_variable_menu(id: int, var_name: String) -> void:
	if id == 0 and _on_rename_variable.is_valid():
		_on_rename_variable.call(var_name)
	elif id == 1 and _on_delete_variable.is_valid():
		_on_delete_variable.call(var_name)


## A management row for one in-scope list (M44) — the list twin of _make_variable_row: a MenuButton
## labelled with the list's name whose popup offers Rename / Delete, routed back to the editor.
func _make_list_row(list_name: String) -> MenuButton:
	var row := MenuButton.new()
	row.text = list_name
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var menu := row.get_popup()
	menu.add_item("Rename", 0)
	menu.add_item("Delete", 1)
	menu.id_pressed.connect(_on_list_menu.bind(list_name))
	return row


## Route a list row's menu choice to the editor (M44): Rename (id 0) or Delete (id 1).
func _on_list_menu(id: int, list_name: String) -> void:
	if id == 0 and _on_rename_list.is_valid():
		_on_rename_list.call(list_name)
	elif id == 1 and _on_delete_list.is_valid():
		_on_delete_list.call(list_name)


## Rebuild the chip list from scratch. The editor calls this on a sprite switch (M19): the
## variable chips (`variable`/`set`/`change`) draw the project's `{name}` dropdown, which is now
## **scoped to the selected sprite**, so the palette must re-render to show that sprite's variables
## (globals + its own locals). Children are removed synchronously before rebuilding so a stale chip
## never lingers in the tree for _chip_at to hit.
func rebuild() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_build()


func _input(event: InputEvent) -> void:
	# In Stage mode (M27) the palette is hidden but still receives _input; ignore events unless we're
	# the visible surface, so a press elsewhere can't start a spawn-drag from a scrolled-off chip.
	if not is_visible_in_tree():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and _state == _IDLE:
			var chip := _chip_at(event.position)
			if chip != null:
				_state = _PENDING
				_press_pos = event.position
				_pending_chip = chip
				get_viewport().set_input_as_handled()
		elif not event.pressed and _state == _PENDING:
			# A plain click on a chip, never dragged — spawn nothing.
			_reset()
	elif event is InputEventMouseMotion and _state == _PENDING:
		if event.position.distance_to(_press_pos) > DRAG_THRESHOLD:
			var block := BlockView.make_block(String(_pending_chip.get_meta("palette_opcode")))
			# A pre-named chip (a `call`, M30) carries its target's name so the minted block calls it;
			# every other chip uses its opcode's defaults verbatim. A parameterized call (M31) also
			# rebuilds its `args` dict fresh from the chip's `palette_params`, so the dragged block owns
			# its own args (no shared reference with the chip).
			if _pending_chip.has_meta("palette_name"):
				block["inputs"]["name"] = String(_pending_chip.get_meta("palette_name"))
			if _pending_chip.has_meta("palette_params"):
				block["inputs"]["args"] = _args_for(_pending_chip.get_meta("palette_params"))
			_reset()
			if _canvas != null:
				_canvas.begin_spawn_drag([block], event.position)
			get_viewport().set_input_as_handled()


func _reset() -> void:
	_state = _IDLE
	_pending_chip = null


## The chip under a global point (the deepest tagged node containing it), or null if the point
## misses every chip. Smallest-area wins, mirroring BlockCanvas._block_at, though chips don't nest
## so it rarely matters. Returns the Control (not just its opcode) so the caller can also read a
## pre-named chip's `palette_name` (M30) when minting the dragged block.
##
## A ScrollContainer only *clips rendering*; a chip scrolled above the viewport keeps a global
## rect that overlaps the chrome above the palette (the top bar's sprite selector). So we first
## reject any point outside the visible palette region (our parent ScrollContainer's rect) — else
## a press on the selector would hit a scrolled-up chip here, go PENDING, and get swallowed by
## set_input_as_handled() instead of opening the dropdown.
func _chip_at(global_point: Vector2) -> Control:
	var view := get_parent() as Control
	if view != null and not view.get_global_rect().has_point(global_point):
		return null
	var best: Control = null
	var best_area := INF
	for chip in _chips(self):
		var rect: Rect2 = (chip as Control).get_global_rect()
		if rect.has_point(global_point):
			var area := rect.size.x * rect.size.y
			if area < best_area:
				best_area = area
				best = chip
	return best


func _chips(node: Node, out: Array = []) -> Array:
	if node is Control and node.has_meta("palette_opcode"):
		out.append(node)
	for child in node.get_children():
		_chips(child, out)
	return out
