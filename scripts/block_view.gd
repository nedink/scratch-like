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
	"variables": Color("ff731aff"),
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
##
## M13 added one optional field:
##   * `enums` — `input_key -> [allowed values]` for slots that are really a fixed choice
##     (`stop {mode}`, `say … in {size}`, `create clone of {target}`, `touching {side} edge?`).
##     Such a slot renders as a dropdown (build_input -> _enum_field) instead of a free-text
##     field; an opcode with no `enums` (or a key not listed) keeps the M12 text field.
const _OPCODES := {
	# events (hats)
	"when_flag_clicked": {"category": "events", "kind": "hat", "template": "when flag clicked", "defaults": {"body": []}},
	"when_i_start_as_a_clone": {"category": "events", "kind": "hat", "template": "when I start as a clone", "defaults": {"body": []}},
	# control
	"forever": {"category": "control", "kind": "statement", "template": "forever", "defaults": {"body": []}},
	"if": {"category": "control", "kind": "statement", "template": "if {condition} then", "defaults": {"condition": true, "body": []}},
	"wait_seconds": {"category": "control", "kind": "statement", "template": "wait {seconds} seconds", "defaults": {"seconds": 1}},
	"stop": {"category": "control", "kind": "statement", "template": "stop {mode}", "defaults": {"mode": "all"}, "enums": {"mode": ["all", "this script"]}},
	"create_clone": {"category": "control", "kind": "statement", "template": "create clone of {target}", "defaults": {"target": "myself"}, "enums": {"target": ["myself"]}},
	"delete_this_clone": {"category": "control", "kind": "statement", "template": "delete this clone", "defaults": {}},
	# motion
	"move_steps": {"category": "motion", "kind": "statement", "template": "move {steps} steps", "defaults": {"steps": 10}},
	"turn_degrees": {"category": "motion", "kind": "statement", "template": "turn {degrees} degrees", "defaults": {"degrees": 15}},
	"point_in_direction": {"category": "motion", "kind": "statement", "template": "point in direction {direction}", "defaults": {"direction": 90}},
	"go_to": {"category": "motion", "kind": "statement", "template": "go to x: {x} y: {y}", "defaults": {"x": 0, "y": 0}},
	# looks
	"say": {"category": "looks", "kind": "statement", "template": "say {text} in {size}", "defaults": {"text": "Hello", "size": "small"}, "enums": {"size": ["small", "large"]}},
	# sensing
	"touching_edge?": {"category": "sensing", "kind": "reporter", "template": "touching {side} edge?", "defaults": {"side": "any"}, "enums": {"side": ["any", "top", "bottom", "left", "right"]}},
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


## Render one input value, read from `inputs[key]`: a nested reporter dictionary ->
## a pill (build_reporter); an enum slot (non-empty `options`, M13) -> a dropdown
## (_enum_field); any other literal -> a small white **editable** field (M12), shaped
## by its value type (oval for a number, rectangular for text — M13).
##
## Two kinds of meta are stamped here:
##   * `lit_inputs`/`lit_key` — only on an *editable* widget (literal field, dropdown), so
##     whoever wires editing (the canvas) can write the chosen value straight back into the
##     data. `inputs` is a reference, so that write *is* the edit. (The palette renders the
##     same widgets but leaves them inert; only the canvas wires them.)
##   * `slot_inputs`/`slot_key` — on **every** widget, the reporter pill included. This names
##     the slot as a drop target so the canvas (M14) can drop a dragged reporter into it,
##     overwriting `inputs[key]` with the reporter dict. A reporter pill is a slot (you can
##     drop *onto* it to replace it) but not an editable literal, hence the two metas split.
static func build_input(inputs: Dictionary, key: String, options: Array = []) -> Control:
	var value: Variant = inputs.get(key)
	var widget: Control
	if typeof(value) == TYPE_DICTIONARY and value.has("opcode"):
		widget = build_reporter(value)
	else:
		if options.is_empty():
			widget = _literal_field(_stringify(value), typeof(value))
		else:
			widget = _enum_field(options, _stringify(value))
		widget.set_meta("lit_inputs", inputs)
		widget.set_meta("lit_key", key)
	widget.set_meta("slot_inputs", inputs)
	widget.set_meta("slot_key", key)
	return widget


## Coerce a field's typed text back to a stored value, directed by the slot's previous
## type so the interpreter sees what it expects (it `float()`s numeric inputs and
## `String()`s text ones). A numeric slot keeps a number (int when whole); a bool slot
## maps true/false; anything else stays a String — including non-numeric text typed into
## a numeric slot, which keeps sentinels like point_in_direction's "bounce" expressible.
static func coerce_literal(text: String, prev: Variant) -> Variant:
	var t := text.strip_edges()
	match typeof(prev):
		TYPE_INT, TYPE_FLOAT:
			if t.is_valid_float():
				var f := t.to_float()
				if is_finite(f) and f == floor(f):
					return int(f)
				return f
			return t
		TYPE_BOOL:
			return t.to_lower() == "true"
		_:
			return t


# --- Palette (M11) ---------------------------------------------------------

## A fresh block dictionary for `opcode`, in exactly the runtime shape — the factory the
## palette drags from. `defaults` is deep-duplicated so each spawned block owns its inputs
## dict and `body` array (no shared references between spawns, and none with the table).
static func make_block(opcode: String) -> Dictionary:
	var info: Dictionary = _OPCODES.get(opcode, {})
	var defaults: Dictionary = info.get("defaults", {})
	return {"opcode": opcode, "inputs": defaults.duplicate(true)}


## The opcodes the palette offers, grouped for display: an Array of
## {category, opcodes:[...]} in PALETTE_CATEGORY_ORDER. As of M14 **every** kind is listed,
## reporters included — a reporter now has a drop target (a value/condition slot), so you can
## drag a fresh `+` / `score` / `touching edge?` in. (Through M13 reporters were filtered out
## because they had nowhere to land.)
static func palette_groups() -> Array:
	var groups: Array = []
	for category in PALETTE_CATEGORY_ORDER:
		var opcodes: Array = []
		for opcode in _OPCODES:
			if _OPCODES[opcode].get("category") == category:
				opcodes.append(opcode)
		if not opcodes.is_empty():
			groups.append({"category": category, "opcodes": opcodes})
	return groups


## Whether an opcode is a reporter (a value/boolean block that lives in a slot, not a stack).
## The canvas reads this to ghost a dragged reporter as a pill and to target slots, not gaps.
static func is_reporter(opcode: String) -> bool:
	return _OPCODES.get(opcode, {}).get("kind", "") == "reporter"


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
	var info: Dictionary = _OPCODES.get(String(block.get("opcode", "")), {})
	var enums: Dictionary = info.get("enums", {})

	var literal := ""
	var i := 0
	while i < template.length():
		if template[i] == "{":
			_push_label(row, literal)
			literal = ""
			var close := template.find("}", i)
			var key := template.substr(i + 1, close - i - 1)
			row.add_child(build_input(inputs, key, enums.get(key, [])))
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


## A literal input value: dark text on a small white field. As of M12 this is an editable
## LineEdit (it was a static Label through M11) — the canvas wires its
## text_submitted/focus_exited to write the typed value back into the block data; the
## palette leaves it inert (mouse-ignored). It grows to fit its text and keeps a small
## minimum width so an empty field is still clickable.
##
## M13 shapes the field by the slot's value type, Scratch-style: a numeric slot is an
## oval (large corner radius), a string/bool slot a rectangle (slight radius), so the two
## kinds read apart at a glance. The type is the slot's *current* value type — the same
## signal coerce_literal keys off — so a numeric slot holding the "bounce" sentinel
## (a String) reads as text, consistent with how its value coerces.
static func _literal_field(text: String, value_type := TYPE_STRING) -> LineEdit:
	var numeric := value_type == TYPE_INT or value_type == TYPE_FLOAT
	var radius := 11 if numeric else 3
	var field := LineEdit.new()
	field.text = text
	field.expand_to_text_length = true
	field.alignment = HORIZONTAL_ALIGNMENT_CENTER
	field.custom_minimum_size = Vector2(16, 0)
	field.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	field.context_menu_enabled = false
	field.add_theme_stylebox_override("normal", _box(Color.WHITE, radius))
	field.add_theme_stylebox_override("focus", _box(Color("#fff4c2"), radius))
	field.add_theme_color_override("font_color", Color("#303030"))
	field.add_theme_color_override("font_uneditable_color", Color("#303030"))
	field.add_theme_color_override("caret_color", Color("#303030"))
	return field


## An enum slot (M13): a white dropdown listing the opcode's fixed choices, dark text to
## match the literal field. The current value is pre-selected; if it isn't among the
## options (an odd value from a hand-written script) it is appended and selected so it
## stays visible and editable rather than silently snapping to option 0. The canvas wires
## `item_selected` to write the chosen text back into the block data; the palette leaves
## it inert (mouse-ignored, like the literal field).
static func _enum_field(options: Array, current: String) -> OptionButton:
	var dd := OptionButton.new()
	dd.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dd.fit_to_longest_item = true
	var selected := -1
	for i in options.size():
		dd.add_item(String(options[i]))
		if String(options[i]) == current:
			selected = i
	if selected == -1:
		dd.add_item(current)
		selected = dd.item_count - 1
	dd.select(selected)
	for state in ["normal", "hover", "pressed", "focus"]:
		dd.add_theme_stylebox_override(state, _box(Color.WHITE, 6))
	for color in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		dd.add_theme_color_override(color, Color("#303030"))
	return dd


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
