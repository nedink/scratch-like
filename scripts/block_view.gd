class_name BlockView
extends RefCounted

## The block renderer — the editor's drawing counterpart to the interpreter's
## execution. (M8 made it read-only; M9 tags what it draws so the canvas can drag it.)
##
## `interpreter.gd` tree-walks the block data (an Array of {opcode, inputs}
## dictionaries, with substacks nested under "inputs") to *execute* it. This walks
## the **exact same data** to *draw* it as a stack of visual Scratch-style blocks.
## Because blocks are already plain serializable dictionaries/arrays, the data model
## needs no change at all — this is purely a new view over it.
##
## The renderer is **table-driven, mirroring the interpreter's dispatch table**: the
## interpreter maps `opcode -> handler Callable`; here we map
## `opcode -> {category, template}`. Adding a block to the editor is one entry in
## `_OPCODES`, the same one-line extension story the interpreter has.
##
## The recursion mirrors the interpreter's too:
##   * a stack (Array)            -> build_stack  (cf. _run_stack)
##   * a reporter input (a dict)  -> build_reporter / build_input  (cf. _evaluate)
##   * a C-block / hat body       -> a nested stack (indented for C-blocks)
##
## M9 (drag/snap) needs to map a Control back to the data it draws, so build_stack /
## build_block stamp two kinds of `meta` onto the tree (read by block_canvas.gd):
##   * each statement panel  -> "blk_array" (the Array it lives in) + "blk_index";
##   * each stack column      -> "body_array" (the Array it renders).
## Because GDScript arrays are references, "blk_array" *is* the live data array — the
## canvas splices a dragged block straight into it (`array.insert(index, block)`),
## the drawing counterpart to the interpreter mutating the same arrays as it runs.
## A block's on-screen *position* is deliberately NOT stored here: it is UI state the
## canvas owns, keeping the block dictionaries free of editor assumptions.
##
## Text uses Godot's built-in UI font, NOT the PixelFont: block labels need
## lowercase + punctuation ("move_steps", "touching_edge?", ">"), which the font.png
## atlas deliberately lacks. The "defer new glyphs" rule governs *in-game* rendered
## text (sprite costumes via `say`); editor chrome is a separate layer.

## Hats are stack *roots*, not C-blocks: their body flows directly beneath the header
## at the same indent (Scratch hats have no "C" wrap). The canvas also uses this to
## forbid snapping a hat into the middle of a stack — a hat-led drag only repositions.
const HAT_OPCODES := ["when_flag_clicked", "when_i_start_as_a_clone"]

## C-blocks wrap their body in an indented "C". (The interpreter treats both the same
## way — a nested body Array — so this is purely a drawing distinction.)
const C_OPCODES := ["forever", "if"]

## Scratch's category palette. Keyed by the "category" each opcode declares below.
## A static var (not const) because a Color built from a hex *string* is not a
## constant expression in GDScript; this is initialized once at runtime instead.
static var _CATEGORY_COLORS := {
	"events": Color("#ffbf00"),
	"control": Color("#ffab19"),
	"motion": Color("#4c97ff"),
	"looks": Color("#9966ff"),
	"sensing": Color("#5cb1d6"),
	"variables": Color("#ff8c1a"),
	"operators": Color("#59c059"),
	"unknown": Color("#7f7f7f"),
}

## opcode -> {category, template, kind, defaults}. The editor's counterpart to the
## interpreter's `_register_handlers`. `template` is a label string with `{input_name}`
## placeholders; each placeholder is replaced by that input's rendered widget (a
## literal field or a nested reporter). A C-block's body is NOT a placeholder — it
## is rendered separately, indented (see build_block).
##
## M11 added two fields per entry (so adding a block to the *palette* is still one entry):
##   * `kind` ∈ {"hat", "statement", "reporter"} — the palette lists only the stackable
##     kinds (hat/statement); a reporter has no drop target yet (see CLAUDE.md), so it is
##     excluded. (Rendering ignores `kind`; HAT_OPCODES/C_OPCODES still drive shape.)
##   * `defaults` — the `inputs` dict a freshly-spawned block starts with, read by
##     make_block(). C-blocks/hats default an empty `body` array.
const _OPCODES := {
	# events (hats)
	"when_flag_clicked": {"category": "events", "kind": "hat", "template": "when flag clicked", "defaults": {"body": []}},
	"when_i_start_as_a_clone": {"category": "events", "kind": "hat", "template": "when I start as a clone", "defaults": {"body": []}},
	# control
	"forever": {"category": "control", "kind": "statement", "template": "forever", "defaults": {"body": []}},
	"if": {"category": "control", "kind": "statement", "template": "if {condition} then", "defaults": {"condition": true, "body": []}},
	"wait_seconds": {"category": "control", "kind": "statement", "template": "wait {seconds} seconds", "defaults": {"seconds": 1}},
	"stop": {"category": "control", "kind": "statement", "template": "stop {mode}", "defaults": {"mode": "all"}},
	"create_clone": {"category": "control", "kind": "statement", "template": "create clone of {target}", "defaults": {"target": "myself"}},
	"delete_this_clone": {"category": "control", "kind": "statement", "template": "delete this clone", "defaults": {}},
	# motion
	"move_steps": {"category": "motion", "kind": "statement", "template": "move {steps} steps", "defaults": {"steps": 10}},
	"turn_degrees": {"category": "motion", "kind": "statement", "template": "turn {degrees} degrees", "defaults": {"degrees": 15}},
	"point_in_direction": {"category": "motion", "kind": "statement", "template": "point in direction {direction}", "defaults": {"direction": 90}},
	"go_to": {"category": "motion", "kind": "statement", "template": "go to x: {x} y: {y}", "defaults": {"x": 0, "y": 0}},
	# looks
	"say": {"category": "looks", "kind": "statement", "template": "say {text} in {size}", "defaults": {"text": "Hello", "size": "small"}},
	# sensing
	"touching_edge?": {"category": "sensing", "kind": "reporter", "template": "touching {side} edge?", "defaults": {"side": "any"}},
	"touching_sprite?": {"category": "sensing", "kind": "reporter", "template": "touching {name}?", "defaults": {"name": ""}},
	"key_pressed?": {"category": "sensing", "kind": "reporter", "template": "key {key} pressed?", "defaults": {"key": "Space"}},
	# variables
	"set_var": {"category": "variables", "kind": "statement", "template": "set {name} to {value}", "defaults": {"name": "score", "value": 0}},
	"change_var": {"category": "variables", "kind": "statement", "template": "change {name} by {by}", "defaults": {"name": "score", "by": 1}},
	"variable": {"category": "variables", "kind": "reporter", "template": "{name}", "defaults": {"name": "score"}},
	# operators
	"add": {"category": "operators", "kind": "reporter", "template": "{a} + {b}", "defaults": {"a": 0, "b": 0}},
	"subtract": {"category": "operators", "kind": "reporter", "template": "{a} - {b}", "defaults": {"a": 0, "b": 0}},
	"multiply": {"category": "operators", "kind": "reporter", "template": "{a} * {b}", "defaults": {"a": 0, "b": 0}},
	"divide": {"category": "operators", "kind": "reporter", "template": "{a} / {b}", "defaults": {"a": 0, "b": 0}},
	"mod": {"category": "operators", "kind": "reporter", "template": "{a} mod {b}", "defaults": {"a": 0, "b": 0}},
	"equals": {"category": "operators", "kind": "reporter", "template": "{a} = {b}", "defaults": {"a": 0, "b": 0}},
	"greater_than": {"category": "operators", "kind": "reporter", "template": "{a} > {b}", "defaults": {"a": 0, "b": 0}},
	"less_than": {"category": "operators", "kind": "reporter", "template": "{a} < {b}", "defaults": {"a": 0, "b": 0}},
	"and": {"category": "operators", "kind": "reporter", "template": "{a} and {b}", "defaults": {"a": false, "b": false}},
	"or": {"category": "operators", "kind": "reporter", "template": "{a} or {b}", "defaults": {"a": false, "b": false}},
	"not": {"category": "operators", "kind": "reporter", "template": "not {a}", "defaults": {"a": false}},
	"random": {"category": "operators", "kind": "reporter", "template": "pick random {from} to {to}", "defaults": {"from": 1, "to": 10}},
}

## Category display order for the palette (operators are all reporters, so that group is
## empty after filtering and simply produces no chips).
const PALETTE_CATEGORY_ORDER := ["events", "control", "motion", "looks", "sensing", "variables", "operators"]


## A vertical run of blocks (a sprite's whole script, a hat's body, or a C-block's
## body — all the same thing: an Array). The drawing counterpart to the interpreter's
## _run_stack. The returned column is stamped with "body_array" = `blocks`, and each
## block panel with "blk_array" = `blocks` + "blk_index" = its position, so the canvas
## can splice a drag straight into this live array (see the class doc).
##
## An empty body still produces a small visible slot, so a C-block's empty interior is
## a reachable drop zone (the column's own rect names the array, index 0).
static func build_stack(blocks: Array) -> VBoxContainer:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	column.set_meta("body_array", blocks)
	var index := 0
	for block in blocks:
		if typeof(block) != TYPE_DICTIONARY:
			continue
		var panel := build_block(block)
		panel.set_meta("blk_array", blocks)
		panel.set_meta("blk_index", index)
		column.add_child(panel)
		index += 1
	if column.get_child_count() == 0:
		column.add_child(_empty_slot())
	return column


## One block: a category-colored panel whose header is built from the opcode's
## template. A hat's body flows directly beneath the header at the same indent (hats
## are stack roots, not C-blocks); forever/if wrap their body in an indented "C".
static func build_block(block: Dictionary) -> Control:
	var opcode := String(block.get("opcode", ""))
	var info: Dictionary = _OPCODES.get(opcode, {})
	var category := String(info.get("category", "unknown"))
	var template := String(info.get("template", opcode))

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _box(_CATEGORY_COLORS[category], 5))
	panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 3)
	panel.add_child(column)
	column.add_child(_header_from_template(template, block))

	if opcode in HAT_OPCODES:
		column.add_child(build_stack(block.get("inputs", {}).get("body", [])))
	elif opcode in C_OPCODES:
		var margin := MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 14)
		margin.add_child(build_stack(block.get("inputs", {}).get("body", [])))
		column.add_child(margin)

	return panel


## A reporter / boolean block, drawn inline inside its parent's header as a rounded
## pill. Recurses into its own reporter inputs to any depth — the drawing
## counterpart to the interpreter's _evaluate, which dispatches a reporter and
## evaluates *its* inputs the same way (e.g. add(90, random(-45, 45))).
static func build_reporter(block: Dictionary) -> Control:
	var opcode := String(block.get("opcode", ""))
	var info: Dictionary = _OPCODES.get(opcode, {})
	var category := String(info.get("category", "operators"))
	var template := String(info.get("template", opcode))

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _box(_CATEGORY_COLORS[category], 10))
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	panel.add_child(_header_from_template(template, block))
	return panel


## Render one input value: a nested reporter dictionary -> a pill (build_reporter);
## any literal (number / string / bool) -> a small white field.
static func build_input(value: Variant) -> Control:
	if typeof(value) == TYPE_DICTIONARY and value.has("opcode"):
		return build_reporter(value)
	return _literal_field(_stringify(value))


# --- Palette (M11) ---------------------------------------------------------

## A fresh block dictionary for `opcode`, in exactly the runtime shape — the factory the
## palette drags from. `defaults` is deep-duplicated so each spawned block owns its inputs
## dict and `body` array (no shared references between spawns, and none with the table).
static func make_block(opcode: String) -> Dictionary:
	var info: Dictionary = _OPCODES.get(opcode, {})
	var defaults: Dictionary = info.get("defaults", {})
	return {"opcode": opcode, "inputs": defaults.duplicate(true)}


## The opcodes the palette offers, grouped for display: an Array of
## {category, opcodes:[...]} in PALETTE_CATEGORY_ORDER. Only stackable kinds (hat /
## statement) are listed — a reporter has no drop target yet (see CLAUDE.md), so the
## operators group ends up empty and is dropped.
static func palette_groups() -> Array:
	var groups: Array = []
	for category in PALETTE_CATEGORY_ORDER:
		var opcodes: Array = []
		for opcode in _OPCODES:
			var info: Dictionary = _OPCODES[opcode]
			if info.get("category") == category and info.get("kind") != "reporter":
				opcodes.append(opcode)
		if not opcodes.is_empty():
			groups.append({"category": category, "opcodes": opcodes})
	return groups


## The display colour for a category (used by the palette for its group headers). Falls
## back to the "unknown" grey for an unrecognized category.
static func category_color(category: String) -> Color:
	return _CATEGORY_COLORS.get(category, _CATEGORY_COLORS["unknown"])


# --- Header assembly -------------------------------------------------------

## Split a template on `{name}` placeholders, emitting a Label for each literal span
## and the rendered input widget for each placeholder, packed left-to-right.
static func _header_from_template(template: String, block: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var inputs: Dictionary = block.get("inputs", {})

	var literal := ""
	var i := 0
	while i < template.length():
		if template[i] == "{":
			_push_label(row, literal)
			literal = ""
			var close := template.find("}", i)
			var key := template.substr(i + 1, close - i - 1)
			row.add_child(build_input(inputs.get(key)))
			i = close + 1
		else:
			literal += template[i]
			i += 1
	_push_label(row, literal)
	return row


## Add a white text label for a literal span, skipping spans that are only spacing
## (the inter-widget gaps come from the HBox separation instead).
static func _push_label(row: HBoxContainer, text: String) -> void:
	var trimmed := text.strip_edges()
	if trimmed == "":
		return
	var label := Label.new()
	label.text = trimmed
	label.add_theme_color_override("font_color", Color.WHITE)
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(label)


## The visible interior of an *empty* C-block body: a small faint slot, so a
## forever/if with nothing inside still has area to drop the first block into. (The
## column it lives in names the body array; the canvas treats this as the index-0 gap.)
static func _empty_slot() -> Control:
	var slot := PanelContainer.new()
	slot.custom_minimum_size = Vector2(40, 14)
	slot.add_theme_stylebox_override("panel", _box(Color(1, 1, 1, 0.12), 4))
	slot.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var spacer := Control.new()
	slot.add_child(spacer)
	return slot


## A literal input value: dark text on a small white rounded field.
static func _literal_field(text: String) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _box(Color.WHITE, 8))
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color("#303030"))
	panel.add_child(label)
	return panel


# --- Helpers ---------------------------------------------------------------

## A filled, rounded background box with a little padding — the visual body of every
## block, reporter, and literal field.
static func _box(color: Color, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	return sb


## Stringify a literal for display, matching the interpreter's _stringify: a whole-
## number float reads as a bare integer ("3", not "3.0"). null -> "" (an input the
## template names but the block omits).
static func _stringify(value: Variant) -> String:
	if value == null:
		return ""
	if typeof(value) == TYPE_FLOAT and value == floor(value) and is_finite(value):
		return str(int(value))
	if typeof(value) == TYPE_BOOL:
		return "true" if value else "false"
	return str(value)
