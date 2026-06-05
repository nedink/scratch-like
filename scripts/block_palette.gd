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
## It lists only **stackable** blocks (hats + statements + C-blocks); a reporter pill has
## no valid drop target until slot-dropping exists (deferred — see CLAUDE.md), so
## BlockView.palette_groups() filters them out.
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

## The canvas this palette feeds. Set by the editor before any interaction.
var _canvas: BlockCanvas

var _state: int = _IDLE
var _press_pos: Vector2
var _pending_opcode: String = ""


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
		var header := Label.new()
		header.text = category.to_upper()
		header.add_theme_color_override("font_color", BlockView.category_color(category))
		header.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(header)
		for opcode in group["opcodes"]:
			var chip := BlockView.build_block(BlockView.make_block(opcode))
			chip.set_meta("palette_opcode", opcode)
			_passthrough(chip)
			add_child(chip)


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


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and _state == _IDLE:
			var opcode := _chip_at(event.position)
			if opcode != "":
				_state = _PENDING
				_press_pos = event.position
				_pending_opcode = opcode
				get_viewport().set_input_as_handled()
		elif not event.pressed and _state == _PENDING:
			# A plain click on a chip, never dragged — spawn nothing.
			_reset()
	elif event is InputEventMouseMotion and _state == _PENDING:
		if event.position.distance_to(_press_pos) > DRAG_THRESHOLD:
			var blocks := [BlockView.make_block(_pending_opcode)]
			_reset()
			if _canvas != null:
				_canvas.begin_spawn_drag(blocks, event.position)
			get_viewport().set_input_as_handled()


func _reset() -> void:
	_state = _IDLE
	_pending_opcode = ""


## The opcode of the chip under a global point (the deepest tagged node containing it), or
## "" if the point misses every chip. Smallest-area wins, mirroring BlockCanvas._block_at,
## though chips don't nest so it rarely matters.
func _chip_at(global_point: Vector2) -> String:
	var best := ""
	var best_area := INF
	for chip in _chips(self):
		var rect: Rect2 = (chip as Control).get_global_rect()
		if rect.has_point(global_point):
			var area := rect.size.x * rect.size.y
			if area < best_area:
				best_area = area
				best = String(chip.get_meta("palette_opcode"))
	return best


func _chips(node: Node, out: Array = []) -> Array:
	if node is Control and node.has_meta("palette_opcode"):
		out.append(node)
	for child in node.get_children():
		_chips(child, out)
	return out
