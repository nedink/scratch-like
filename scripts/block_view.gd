class_name BlockView
extends RefCounted

## The Milestone 8 block renderer — the editor's drawing counterpart to the
## interpreter's execution.
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
##   * a C-block body             -> an indented nested stack
##
## Text uses Godot's built-in UI font, NOT the PixelFont: block labels need
## lowercase + punctuation ("move_steps", "touching_edge?", ">"), which the font.png
## atlas deliberately lacks. The "defer new glyphs" rule governs *in-game* rendered
## text (sprite costumes via `say`); editor chrome is a separate layer.

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

## opcode -> {category, template}. The editor's counterpart to the interpreter's
## `_register_handlers`. `template` is a label string with `{input_name}`
## placeholders; each placeholder is replaced by that input's rendered widget (a
## literal field or a nested reporter). A C-block's body is NOT a placeholder — it
## is rendered separately, indented (see build_block).
const _OPCODES := {
	# events (hats)
	"when_flag_clicked": {"category": "events", "template": "when flag clicked"},
	"when_i_start_as_a_clone": {"category": "events", "template": "when I start as a clone"},
	# control
	"forever": {"category": "control", "template": "forever"},
	"if": {"category": "control", "template": "if {condition} then"},
	"wait_seconds": {"category": "control", "template": "wait {seconds} seconds"},
	"stop": {"category": "control", "template": "stop {mode}"},
	"create_clone": {"category": "control", "template": "create clone of {target}"},
	"delete_this_clone": {"category": "control", "template": "delete this clone"},
	# motion
	"move_steps": {"category": "motion", "template": "move {steps} steps"},
	"turn_degrees": {"category": "motion", "template": "turn {degrees} degrees"},
	"point_in_direction": {"category": "motion", "template": "point in direction {direction}"},
	"go_to": {"category": "motion", "template": "go to x: {x} y: {y}"},
	# looks
	"say": {"category": "looks", "template": "say {text} in {size}"},
	# sensing
	"touching_edge?": {"category": "sensing", "template": "touching {side} edge?"},
	"touching_sprite?": {"category": "sensing", "template": "touching {name}?"},
	"key_pressed?": {"category": "sensing", "template": "key {key} pressed?"},
	# variables
	"set_var": {"category": "variables", "template": "set {name} to {value}"},
	"change_var": {"category": "variables", "template": "change {name} by {by}"},
	"variable": {"category": "variables", "template": "{name}"},
	# operators
	"add": {"category": "operators", "template": "{a} + {b}"},
	"subtract": {"category": "operators", "template": "{a} - {b}"},
	"multiply": {"category": "operators", "template": "{a} * {b}"},
	"divide": {"category": "operators", "template": "{a} / {b}"},
	"mod": {"category": "operators", "template": "{a} mod {b}"},
	"equals": {"category": "operators", "template": "{a} = {b}"},
	"greater_than": {"category": "operators", "template": "{a} > {b}"},
	"less_than": {"category": "operators", "template": "{a} < {b}"},
	"and": {"category": "operators", "template": "{a} and {b}"},
	"or": {"category": "operators", "template": "{a} or {b}"},
	"not": {"category": "operators", "template": "not {a}"},
	"random": {"category": "operators", "template": "pick random {from} to {to}"},
}


## Render a whole sprite's script: a column of hat stacks. Each top-level block is a
## hat (e.g. when_flag_clicked) whose `body` flows directly beneath it at the same
## indent — Scratch hats are not C-blocks, so the body is not wrapped.
static func build_script(script: Array) -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	for hat in script:
		if typeof(hat) != TYPE_DICTIONARY:
			continue
		var stack := VBoxContainer.new()
		stack.add_theme_constant_override("separation", 2)
		stack.add_child(build_block(hat))  # the hat header itself
		stack.add_child(build_stack(hat.get("inputs", {}).get("body", [])))
		column.add_child(stack)
	return column


## A vertical run of statement blocks (the body of a hat / forever / if). The
## drawing counterpart to the interpreter's _run_stack.
static func build_stack(blocks: Array) -> VBoxContainer:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	for block in blocks:
		if typeof(block) == TYPE_DICTIONARY:
			column.add_child(build_block(block))
	return column


## One statement block: a category-colored panel whose header is built from the
## opcode's template. forever/if are C-blocks — their `body` is rendered as an
## indented nested stack inside the same panel, so the "C" wrap reads.
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

	if opcode == "forever" or opcode == "if":
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
