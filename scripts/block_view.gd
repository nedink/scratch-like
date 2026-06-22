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
## `define` (M30, a custom-block definition) is a hat too: it sits at the root and runs only
## when a `call` invokes it (never on the green flag).
const HAT_OPCODES := ["when_flag_clicked", "when_i_start_as_a_clone", "define"]

## C-blocks wrap their body in an indented "C". (The interpreter treats both the same
## way — a nested body Array — so this is purely a drawing distinction.)
const C_OPCODES := ["forever", "while", "if"]

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
	"custom": Color("#ff6680"),
	"camera": Color("#0fbd8c"),
	"animation": Color("#cf63cf"),
	"unknown": Color("#7f7f7f"),
}

## The project model (M17): the variable names and sprite names the current project defines.
## The editor (editor.gd) owns these — it sets them before anything renders — and the `{name}`
## slots of variable/set_var/change_var (variables) and touching_sprite? (sprites) read them to
## render as **data-scoped dropdowns**: a fixed-choice menu of the project's *real* names rather
## than M12 free text. Static (like Stage.project_sprites) so the value reaches the static render
## path from one place. Empty by default — the palette built before the editor sets them, or any
## non-editor caller — in which case those slots fall back to a plain text field, exactly as
## before M17.
##
## `project_variables` is **scoped to the sprite being edited** (M19): the editor re-points it on
## every sprite switch to globals + that sprite's own locals, hiding other sprites' locals (Scratch
## semantics). This renderer is unchanged by that — it just lists whatever names it's handed; the
## scoping is the editor choosing *which* names. `project_sprites` is not scoped (every sprite is a
## valid `touching` target). The runtime model (PongScripts.variables(), M18) feeds both this and
## the Stage's seeding; the editor maps it to names, filtering by scope.
##
## `project_custom_blocks` (M30) is the sibling for **custom blocks** (Scratch's "My Blocks"): the
## names of the `define` hats in the sprite being edited. The editor re-derives it per sprite (it
## scans the sprite's script for `define` blocks), so a `call {name}` slot lists that sprite's real
## procedures — the custom-block twin of `project_variables`. Like a variable, a custom block is
## **per-sprite** (a `define` lives in one sprite's script and `call` resolves it there), so this is
## not global.
static var project_variables: Array = []
static var project_sprites: Array = []
static var project_custom_blocks: Array = []

## `project_custom_block_params` (M31) is the parameter sibling of `project_custom_blocks`: a map of
## custom-block name -> its ordered parameter-name list, for the sprite being edited. The editor
## re-derives it per sprite (from the `define` hats' `params`) alongside `project_custom_blocks`, and
## the palette reads it to build each `call` chip with one `args` slot per parameter (see
## BlockPalette). Empty (no editor) -> call chips have no parameter slots, exactly as an M30 call.
static var project_custom_block_params: Dictionary = {}

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
##
## M17 added one more, the *data-scoped* sibling of `enums`:
##   * `data_enums` — `input_key -> source` where source ∈ {"variables", "sprites"}. The slot's
##     options aren't a fixed literal list; they are pulled at render time from the project model
##     (project_variables / project_sprites, owned by the editor). So `variable`/`set_var`/
##     `change_var`'s `{name}` lists the project's real variables and `touching_sprite?`'s
##     `{name}` lists its real sprites — a menu of actual names rather than free text. It renders
##     through the same _enum_field path; when the model is empty (non-editor caller) it falls
##     back to a text field. The matching `defaults` point at a real name so a freshly-spawned
##     block lands on a valid menu item (not a phantom appended value).
##
## M23 added two optional fields, the **slot-typing** pair (Scratch's hexagon-vs-round
## distinction) — both consumed by the editor's reporter-drop, neither touching the runtime:
##   * `output` — a reporter's value kind, "boolean" or (default) "value". The `?`-suffixed
##     sensing reporters and the comparison/boolean operators (`equals`/`>`/`<`/`and`/`or`/
##     `not`) are booleans; arithmetic, `random`, and `variable` are values. `build_reporter`
##     shapes a boolean pill with a tight (angular) corner radius vs a value pill's round one
##     — the same corner-radius shorthand M13 used for number-vs-text literal fields (true
##     hexagon geometry stays deferred).
##   * `bool_inputs` — `[input_key, …]` naming the slots that expect a boolean (`if`'s
##     `condition`, `and`/`or`'s `a`/`b`, `not`'s `a`); every other slot is a value slot.
##     build_input stamps each widget's expected kind as `slot_type` meta, and the canvas's
##     _nearest_slot only offers a reporter the slots whose `slot_type` matches its `output`
##     — so a boolean can't land in `move`'s `steps` nor a value in an `if` condition.
##
## M30 added one optional field:
##   * `palette` — default true. When false (the custom-block `define`/`call`), palette_groups
##     does not list it as a generic draggable chip; the palette renders the My-Blocks group
##     specially instead (a "Make a Block" button + one pre-named `call` chip per defined block),
##     the same way the variables group is rendered specially. make_block() still mints it (the
##     editor uses it for the `define` a "Make a Block" creates).
const _OPCODES := {
	# events (hats)
	"when_flag_clicked": {"category": "events", "kind": "hat", "template": "when flag clicked", "defaults": {"body": []}},
	"when_i_start_as_a_clone": {"category": "events", "kind": "hat", "template": "when I start as a clone", "defaults": {"body": []}},
	# control
	"forever": {"category": "control", "kind": "statement", "template": "forever", "defaults": {"body": []}},
	"while": {"category": "control", "kind": "statement", "template": "while {condition}", "defaults": {"condition": true, "body": []}, "bool_inputs": ["condition"]},
	"if": {"category": "control", "kind": "statement", "template": "if {condition} then", "defaults": {"condition": true, "body": []}, "bool_inputs": ["condition"]},
	"wait_seconds": {"category": "control", "kind": "statement", "template": "wait {seconds} seconds", "defaults": {"seconds": 1}},
	"stop": {"category": "control", "kind": "statement", "template": "stop {mode}", "defaults": {"mode": "all"}, "enums": {"mode": ["all", "this script"]}},
	"create_clone": {"category": "control", "kind": "statement", "template": "create clone of {target}", "defaults": {"target": "myself"}, "enums": {"target": ["myself"]}},
	"delete_this_clone": {"category": "control", "kind": "statement", "template": "delete this clone", "defaults": {}},
	# motion
	"move_steps": {"category": "motion", "kind": "statement", "template": "move {steps} steps", "defaults": {"steps": 10}},
	"turn_degrees": {"category": "motion", "kind": "statement", "template": "turn {degrees} degrees", "defaults": {"degrees": 15}},
	"point_in_direction": {"category": "motion", "kind": "statement", "template": "point in direction {direction}", "defaults": {"direction": 90}},
	"go_to": {"category": "motion", "kind": "statement", "template": "go to x: {x} y: {y}", "defaults": {"x": 0, "y": 0}},
	"point_towards": {"category": "motion", "kind": "statement", "template": "point towards x: {x} y: {y}", "defaults": {"x": 0, "y": 0}},
	# velocity (M43) — built-in continuous motion: the Stage drifts every sprite by its velocity once a
	# physics tick (px/tick, the move_steps unit). `set velocity` assigns it, `change velocity` adds to
	# it (gravity / steering). Plain {opcode, inputs} statements — no data-shape change.
	"set_velocity": {"category": "motion", "kind": "statement", "template": "set velocity to x: {x} y: {y}", "defaults": {"x": 0, "y": 0}},
	"change_velocity": {"category": "motion", "kind": "statement", "template": "change velocity by x: {dx} y: {dy}", "defaults": {"dx": 0, "dy": 0}},
	# motion reporters (M35) — expose the sprite's motion state as data, so a reflection (the
	# `point_in_direction "bounce"` sentinel) can be expressed as blocks. No inputs: each reads the
	# running Target's facing / position. `direction` stands in for velocity (speed is a separate var).
	"direction": {"category": "motion", "kind": "reporter", "template": "direction", "defaults": {}},
	"x_position": {"category": "motion", "kind": "reporter", "template": "x position", "defaults": {}},
	"y_position": {"category": "motion", "kind": "reporter", "template": "y position", "defaults": {}},
	# cross-sprite position reporters (M43) — read *another* sprite's centre, picked from a sprites
	# dropdown (the touching_sprite? "sprites" source). They retire the demo's relay-global pattern: the
	# ball reads `y position of (RightPaddle)` instead of a `right_paddle_y` global the paddle published.
	"x_position_of": {"category": "motion", "kind": "reporter", "template": "x position of {name}", "defaults": {"name": "Ball"}, "data_enums": {"name": "sprites"}},
	"y_position_of": {"category": "motion", "kind": "reporter", "template": "y position of {name}", "defaults": {"name": "Ball"}, "data_enums": {"name": "sprites"}},
	# velocity reporters (M43) — the running sprite's built-in velocity components (value output).
	"velocity_x": {"category": "motion", "kind": "reporter", "template": "velocity x", "defaults": {}},
	"velocity_y": {"category": "motion", "kind": "reporter", "template": "velocity y", "defaults": {}},
	# looks
	"say": {"category": "looks", "kind": "statement", "template": "say {text} in {size}", "defaults": {"text": "Hello", "size": "small"}, "enums": {"size": ["small", "large"]}},
	"set_color": {"category": "looks", "kind": "statement", "template": "set color {color}", "defaults": {"color": "#ffffff"}},
	"set_size": {"category": "looks", "kind": "statement", "template": "set size to w: {w} h: {h}", "defaults": {"w": 16, "h": 16}},
	"go_to_layer": {"category": "looks", "kind": "statement", "template": "go to {layer} layer", "defaults": {"layer": "front"}, "enums": {"layer": ["front", "back"]}},
	"change_layer": {"category": "looks", "kind": "statement", "template": "go {direction} {num} layers", "defaults": {"direction": "forward", "num": 1}, "enums": {"direction": ["forward", "backward"]}},
	# sensing
	"touching_edge?": {"category": "sensing", "kind": "reporter", "output": "boolean", "template": "touching {side} edge?", "defaults": {"side": "any"}, "enums": {"side": ["any", "top", "bottom", "left", "right"]}},
	"touching_sprite?": {"category": "sensing", "kind": "reporter", "output": "boolean", "template": "touching {name}?", "defaults": {"name": "Ball"}, "data_enums": {"name": "sprites"}},
	"key_pressed?": {"category": "sensing", "kind": "reporter", "output": "boolean", "template": "key {key} pressed?", "defaults": {"key": "Space"}},
	"mouse_x": {"category": "sensing", "kind": "reporter", "template": "mouse x", "defaults": {}},
	"mouse_y": {"category": "sensing", "kind": "reporter", "template": "mouse y", "defaults": {}},
	"mouse_down?": {"category": "sensing", "kind": "reporter", "output": "boolean", "template": "mouse down?", "defaults": {}},
	# variables
	"set_var": {"category": "variables", "kind": "statement", "template": "set {name} to {value}", "defaults": {"name": "p1_score", "value": 0}, "data_enums": {"name": "variables"}},
	"change_var": {"category": "variables", "kind": "statement", "template": "change {name} by {by}", "defaults": {"name": "p1_score", "by": 1}, "data_enums": {"name": "variables"}},
	"variable": {"category": "variables", "kind": "reporter", "template": "{name}", "defaults": {"name": "p1_score"}, "data_enums": {"name": "variables"}},
	# operators
	"add": {"category": "operators", "kind": "reporter", "template": "{a} + {b}", "defaults": {"a": 0, "b": 0}},
	"subtract": {"category": "operators", "kind": "reporter", "template": "{a} - {b}", "defaults": {"a": 0, "b": 0}},
	"multiply": {"category": "operators", "kind": "reporter", "template": "{a} * {b}", "defaults": {"a": 0, "b": 0}},
	"divide": {"category": "operators", "kind": "reporter", "template": "{a} / {b}", "defaults": {"a": 0, "b": 0}},
	"mod": {"category": "operators", "kind": "reporter", "template": "{a} mod {b}", "defaults": {"a": 0, "b": 0}},
	"equals": {"category": "operators", "kind": "reporter", "output": "boolean", "template": "{a} = {b}", "defaults": {"a": 0, "b": 0}},
	"greater_than": {"category": "operators", "kind": "reporter", "output": "boolean", "template": "{a} > {b}", "defaults": {"a": 0, "b": 0}},
	"less_than": {"category": "operators", "kind": "reporter", "output": "boolean", "template": "{a} < {b}", "defaults": {"a": 0, "b": 0}},
	"and": {"category": "operators", "kind": "reporter", "output": "boolean", "template": "{a} and {b}", "defaults": {"a": false, "b": false}, "bool_inputs": ["a", "b"]},
	"or": {"category": "operators", "kind": "reporter", "output": "boolean", "template": "{a} or {b}", "defaults": {"a": false, "b": false}, "bool_inputs": ["a", "b"]},
	"not": {"category": "operators", "kind": "reporter", "output": "boolean", "template": "not {a}", "defaults": {"a": false}, "bool_inputs": ["a"]},
	"random": {"category": "operators", "kind": "reporter", "template": "pick random {from} to {to}", "defaults": {"from": 1, "to": 10}},
	# custom blocks — "My Blocks" (M30). `define {name}` is the procedure hat (its body is the function);
	# `call {name}` invokes it. Both carry `palette: false` so palette_groups doesn't list them as generic
	# chips: a `define` is created via the palette's "Make a Block" button, and `call` is offered as one
	# pre-named chip per defined block (see BlockPalette) — the My-Blocks twin of the variables group's
	# Make button + rows. `call`'s `name` is a data-scoped dropdown of the sprite's own custom blocks
	# (data_enums "custom_blocks" -> project_custom_blocks), the custom-block sibling of touching_sprite?.
	# Parameters (M31): a `define` carries an ordered `params` list (the procedure's parameter names),
	# a `call` an `args` dict keyed by those names (one value/reporter per parameter), and `param` is
	# the reporter that reads a parameter inside the body. `define`/`call` headers are rendered
	# **dynamically** from this data (their shape depends on the params, which a fixed template can't
	# express) — see _define_header / _call_header. `param` carries palette:false like define/call (it
	# enters scripts only by dragging a copy out of the define hat's prototype, never as a generic
	# chip) and renders as a read-only name pill (build_reporter special-cases it).
	"define": {"category": "custom", "kind": "hat", "palette": false, "template": "define {name}", "defaults": {"name": "block", "params": [], "body": []}},
	"call": {"category": "custom", "kind": "statement", "palette": false, "template": "call {name}", "defaults": {"name": "block", "args": {}}, "data_enums": {"name": "custom_blocks"}},
	"param": {"category": "custom", "kind": "reporter", "output": "value", "palette": false, "template": "{name}", "defaults": {"name": "param"}},

	# Camera (M37): scroll the runtime view. The camera shows the world point given by its position at
	# the screen centre, so camera coordinates are the *same space sprites live in* (default 240,176 =
	# the identity view today). `set_camera`/`change_camera` move it (movement); `camera_follow` /
	# `camera_stop_following` track a sprite (tracking). The Stage owns a Camera2D and carries these out
	# (set_camera / move_camera / camera_follow / camera_stop_following). `camera_follow`'s {name} is a
	# data-scoped dropdown of the project's sprites (the touching_sprite? "sprites" source).
	"set_camera": {"category": "camera", "kind": "statement", "template": "set camera to x: {x} y: {y}", "defaults": {"x": 240, "y": 176}},
	"change_camera": {"category": "camera", "kind": "statement", "template": "change camera by x: {dx} y: {dy}", "defaults": {"dx": 0, "dy": 0}},
	"camera_follow": {"category": "camera", "kind": "statement", "template": "camera follow {name}", "defaults": {"name": "Ball"}, "data_enums": {"name": "sprites"}},
	"camera_stop_following": {"category": "camera", "kind": "statement", "template": "camera stop following", "defaults": {}},

	# Animation (M41): smoothly interpolate a variable's value over time. `animate {name} to {value}
	# over {seconds} secs {easing}` is a single statement that blocks for its duration (like wait /
	# Scratch glide) while tweening the named variable from its current value to {value}. `{name}` is a
	# data-scoped dropdown of the project's variables (the set_var/variable "variables" source — no new
	# resolver), and `{easing}` is a fixed-choice dropdown of the interpolation curves. The interpreter
	# owns the tween (_on_animate / _ease_fraction); this is a plain {opcode, inputs} statement, so
	# persistence (M22) and RUN (M10) carry it untouched.
	"animate": {"category": "animation", "kind": "statement", "template": "animate {name} to {value} over {seconds} secs {easing}", "defaults": {"name": "p1_score", "value": 100, "seconds": 1, "easing": "linear"}, "data_enums": {"name": "variables"}, "enums": {"easing": ["linear", "ease in", "ease out"]}},
}

## Category display order for the palette (operators are all reporters, so that group is
## empty after filtering and simply produces no chips).
const PALETTE_CATEGORY_ORDER := ["events", "control", "motion", "animation", "looks", "sensing", "variables", "operators", "camera"]


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


## A reporter / boolean block, drawn inline inside its parent's header as a pill.
## Recurses into its own reporter inputs to any depth — the drawing counterpart to the
## interpreter's _evaluate, which dispatches a reporter and evaluates *its* inputs the same
## way (e.g. add(90, random(-45, 45))). A **boolean** reporter (output "boolean", M23) gets a
## tight corner radius (angular) where a **value** reporter stays round — Scratch's
## hexagon-vs-round shorthand, approximated with corner radii as M13 did for number-vs-text
## literal slots (true hexagon geometry is still deferred).
static func build_reporter(block: Dictionary) -> Control:
	var opcode := String(block.get("opcode", ""))
	# A custom-block parameter reporter (M31) shows its parameter name as read-only text — there is no
	# editable field (its name binds it to the define's parameter, not a value you type). build_input
	# stamps the slot meta on this pill when it sits in a slot, so it's still grabbable-out / droppable
	# -over like any reporter.
	if opcode == "param":
		return _param_pill(String(block.get("inputs", {}).get("name", "")))
	var info: Dictionary = _OPCODES.get(opcode, {})
	var category := String(info.get("category", "operators"))
	var template := String(info.get("template", opcode))
	var radius := 3 if reporter_output_type(opcode) == "boolean" else 10

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _box(_CATEGORY_COLORS[category], radius))
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	panel.add_child(_header_from_template(template, block))
	return panel


## Render one input value, read from `inputs[key]`: a nested reporter dictionary ->
## a pill (build_reporter); an enum slot (non-empty `options`, M13) -> a dropdown
## (_enum_field); any other literal -> a small white **editable** field (M12), shaped
## by its value type (oval for a number, rectangular for text — M13).
##
## Three kinds of meta are stamped here:
##   * `lit_inputs`/`lit_key` — only on an *editable* widget (literal field, dropdown), so
##     whoever wires editing (the canvas) can write the chosen value straight back into the
##     data. `inputs` is a reference, so that write *is* the edit. (The palette renders the
##     same widgets but leaves them inert; only the canvas wires them.)
##   * `slot_inputs`/`slot_key` — on **every** widget, the reporter pill included. This names
##     the slot as a drop target so the canvas (M14) can drop a dragged reporter into it,
##     overwriting `inputs[key]` with the reporter dict. A reporter pill is a slot (you can
##     drop *onto* it to replace it) but not an editable literal, hence the two metas split.
##   * `slot_default` — the opcode's default literal for this key. M15 restores it when a
##     reporter is *grabbed out* of the slot: pulling the reporter leaves the slot's default
##     literal (we never kept the literal a reporter displaced, so the default stands in).
##   * `slot_type` — the slot's expected value kind, "boolean" or (default) "value" (M23). The
##     canvas's _nearest_slot offers a dragged reporter only the slots whose `slot_type` matches
##     its `output`, so a boolean and a value can't drop into each other's slots.
static func build_input(inputs: Dictionary, key: String, options: Array = [], default: Variant = null, slot_type := "value") -> Control:
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
	widget.set_meta("slot_default", default)
	widget.set_meta("slot_type", slot_type)
	return widget


## Coerce a field's typed text back to a stored value, directed by the slot's previous
## type so the interpreter sees what it expects (it `float()`s numeric inputs and
## `String()`s text ones). A numeric slot keeps a number (int when whole); a bool slot
## maps true/false; anything else stays a String — including non-numeric text typed into
## a numeric slot, which keeps sentinels like point_in_direction's "bounce" expressible.
## A numeric slot also evaluates an arithmetic expression (M29): "2+3" commits as 5, so
## the field shows the result once _commit_literal re-stringifies it.
static func coerce_literal(text: String, prev: Variant) -> Variant:
	var t := text.strip_edges()
	match typeof(prev):
		TYPE_INT, TYPE_FLOAT:
			if t.is_valid_float():
				return _as_number(t.to_float())
			var computed: Variant = _eval_arithmetic(t)
			if computed != null:
				return computed
			return t
		TYPE_BOOL:
			return t.to_lower() == "true"
		_:
			return t


## Normalize a float to the numeric-slot convention: int when whole (the interpreter
## `float()`s it regardless), else the float.
static func _as_number(f: float) -> Variant:
	if is_finite(f) and f == floor(f):
		return int(f)
	return f


# Only digits, whitespace, and arithmetic operators/parens — anything with a letter or
# other symbol is rejected before parsing, so Expression can never resolve an identifier
# or call (OS, randi, …); such text falls back to being kept as a string.
const _ARITHMETIC_RE := r"^[0-9.+\-*/%() \t]+$"


## Evaluate `text` as an arithmetic expression via Godot's Expression (M29). Returns a
## finite number (int when whole) or null when the text isn't safe/evaluable arithmetic —
## a name (the "bounce" sentinel), a parse failure, or a ÷0 → inf/nan result — so the
## caller falls back to keeping the raw string.
static func _eval_arithmetic(text: String) -> Variant:
	if text.is_empty():
		return null
	var re := RegEx.create_from_string(_ARITHMETIC_RE)
	if re.search(text) == null:
		return null
	var expr := Expression.new()
	if expr.parse(text) != OK:
		return null
	var result: Variant = expr.execute([], null, false)
	if expr.has_execute_failed():
		return null
	if not (result is int or result is float):
		return null
	var f := float(result)
	if not is_finite(f):
		return null
	return _as_number(f)


# --- Palette (M11) ---------------------------------------------------------

## A fresh block dictionary for `opcode`, in exactly the runtime shape — the factory the
## palette drags from. `defaults` is deep-duplicated so each spawned block owns its inputs
## dict and `body` array (no shared references between spawns, and none with the table).
static func make_block(opcode: String) -> Dictionary:
	var info: Dictionary = _OPCODES.get(opcode, {})
	var defaults: Dictionary = info.get("defaults", {})
	return {"opcode": opcode, "inputs": defaults.duplicate(true)}


## The opcodes whose `{name}` input names a variable — the three the rename/delete cascade
## (M21) walks for. Kept here beside the `data_enums` declarations that mark those same slots
## (`set_var`/`change_var`/`variable` all map `name -> "variables"`).
const _VARIABLE_OPCODES := ["variable", "set_var", "change_var"]


## Count how many blocks in `blocks` reference the variable `name` (M21) — blocks whose opcode
## is one of `_VARIABLE_OPCODES` and whose `inputs.name` equals it. Recurses into nested reporter
## inputs and `body` substacks, the same tree the interpreter walks. The editor sums this across
## the scripts where a variable is in scope to report a deletion's usage count.
static func count_variable_refs(blocks: Array, name: String) -> int:
	var count := 0
	for block in blocks:
		if typeof(block) != TYPE_DICTIONARY:
			continue
		var opcode := String(block.get("opcode", ""))
		var inputs: Dictionary = block.get("inputs", {})
		if opcode in _VARIABLE_OPCODES and String(inputs.get("name", "")) == name:
			count += 1
		for key in inputs:
			var value: Variant = inputs[key]
			if typeof(value) == TYPE_DICTIONARY and value.has("opcode"):
				count += count_variable_refs([value], name)
			elif typeof(value) == TYPE_ARRAY:
				count += count_variable_refs(value, name)
	return count


## Rewrite every reference to `old_name` in `blocks` to `new_name` (M21), in place — the cascade
## a UI rename performs across a script. Same walk as count_variable_refs: a `_VARIABLE_OPCODES`
## block's `inputs.name` is reassigned, and nested reporter inputs / `body` substacks recurse.
## (`blocks` and the dicts within are references, so this mutates the live script the caller holds.)
static func rewrite_variable_refs(blocks: Array, old_name: String, new_name: String) -> void:
	for block in blocks:
		if typeof(block) != TYPE_DICTIONARY:
			continue
		var opcode := String(block.get("opcode", ""))
		var inputs: Dictionary = block.get("inputs", {})
		if opcode in _VARIABLE_OPCODES and String(inputs.get("name", "")) == old_name:
			inputs["name"] = new_name
		for key in inputs:
			var value: Variant = inputs[key]
			if typeof(value) == TYPE_DICTIONARY and value.has("opcode"):
				rewrite_variable_refs([value], old_name, new_name)
			elif typeof(value) == TYPE_ARRAY:
				rewrite_variable_refs(value, old_name, new_name)


## Remove every reference to `name` from `blocks` (M21 delete), in place. A `set_var`/`change_var`
## statement naming it is dropped from its array; a `variable` reporter naming it is plucked from its
## slot, which reverts to the host opcode's default literal (M15's slot_default rule) — so `move
## (speed)` becomes `move 10` rather than leaving a hole. Host blocks (`move`, `if`, an operator) are
## kept; only the reference goes. Recurses into nested reporters and `body` substacks, the same tree
## count/rewrite walk. (Mutates the live arrays/dicts the caller holds.)
static func strip_variable_refs(blocks: Array, name: String) -> void:
	var i := 0
	while i < blocks.size():
		var block: Variant = blocks[i]
		if typeof(block) != TYPE_DICTIONARY:
			i += 1
			continue
		var opcode := String(block.get("opcode", ""))
		var inputs: Dictionary = block.get("inputs", {})
		if (opcode == "set_var" or opcode == "change_var") and String(inputs.get("name", "")) == name:
			blocks.remove_at(i)  # drop the statement; don't advance — the next block shifts down
			continue
		_strip_input_refs(opcode, inputs, name)
		i += 1


## Scrub one block's input slots (helper for strip_variable_refs): a `variable` reporter naming
## `name` reverts to this opcode's default for that key; any other nested reporter recurses (it may
## itself hold a `variable`, e.g. `speed + 1`); a `body` array recurses as a substack.
static func _strip_input_refs(opcode: String, inputs: Dictionary, name: String) -> void:
	var defaults: Dictionary = _OPCODES.get(opcode, {}).get("defaults", {})
	for key in inputs:
		var value: Variant = inputs[key]
		if typeof(value) == TYPE_DICTIONARY and value.has("opcode"):
			if String(value.get("opcode", "")) == "variable" and String(value.get("inputs", {}).get("name", "")) == name:
				inputs[key] = defaults.get(key)
			else:
				_strip_input_refs(String(value.get("opcode", "")), value.get("inputs", {}), name)
		elif typeof(value) == TYPE_ARRAY:
			strip_variable_refs(value, name)


## The opcodes whose `{name}` input names a sprite — the targets a sprite rename/delete cascade
## (M25) walks for: `touching_sprite?` and the M43 cross-sprite position reporters
## (`x_position_of` / `y_position_of`), all of which carry a `{name}` `data_enums` mapping to
## "sprites". They are the sprite analog of _VARIABLE_OPCODES. Unlike a variable, a sprite name is
## globally unique, so the cascade is unscoped — it rewrites/strips every match in every script (any
## sprite may reference any other), with no global-vs-local distinction.
const _SPRITE_OPCODES := ["touching_sprite?", "x_position_of", "y_position_of"]


## Count how many blocks in `blocks` reference the sprite `name` (M25) — the sprite counterpart of
## count_variable_refs. A `touching {name}?` whose `inputs.name` matches is one reference. Recurses
## into nested reporter inputs and `body` substacks. The editor sums this across the other scripts to
## report how many references a sprite deletion will clear.
static func count_sprite_refs(blocks: Array, name: String) -> int:
	var count := 0
	for block in blocks:
		if typeof(block) != TYPE_DICTIONARY:
			continue
		var opcode := String(block.get("opcode", ""))
		var inputs: Dictionary = block.get("inputs", {})
		if opcode in _SPRITE_OPCODES and String(inputs.get("name", "")) == name:
			count += 1
		for key in inputs:
			var value: Variant = inputs[key]
			if typeof(value) == TYPE_DICTIONARY and value.has("opcode"):
				count += count_sprite_refs([value], name)
			elif typeof(value) == TYPE_ARRAY:
				count += count_sprite_refs(value, name)
	return count


## Rewrite every reference to sprite `old_name` in `blocks` to `new_name` (M25), in place — the
## sprite counterpart of rewrite_variable_refs, the cascade a UI sprite-rename performs across a
## script. A `_SPRITE_OPCODES` block's `inputs.name` is reassigned; nested reporter inputs / `body`
## substacks recurse. (`blocks` and the dicts within are references, so this mutates the live script.)
static func rewrite_sprite_refs(blocks: Array, old_name: String, new_name: String) -> void:
	for block in blocks:
		if typeof(block) != TYPE_DICTIONARY:
			continue
		var opcode := String(block.get("opcode", ""))
		var inputs: Dictionary = block.get("inputs", {})
		if opcode in _SPRITE_OPCODES and String(inputs.get("name", "")) == old_name:
			inputs["name"] = new_name
		for key in inputs:
			var value: Variant = inputs[key]
			if typeof(value) == TYPE_DICTIONARY and value.has("opcode"):
				rewrite_sprite_refs([value], old_name, new_name)
			elif typeof(value) == TYPE_ARRAY:
				rewrite_sprite_refs(value, old_name, new_name)


## Remove every dangling reference to the deleted sprite `name` from `blocks` (M25 delete), in place —
## the sprite counterpart of strip_variable_refs. Every block naming another sprite (the
## `_SPRITE_OPCODES`: `touching_sprite?` and the M43 position-of reporters) is a **reporter** (never a
## statement), so this never drops a block; it reverts the reporter to its host opcode's default
## literal for that slot (M15's slot_default rule), so `if (touching Ghost?)` becomes `if true` and
## `(y position of Ghost)` reverts to its default once `Ghost` is gone. Recurses into nested reporters
## and `body` substacks. (Mutates the live arrays/dicts the caller holds.)
static func strip_sprite_refs(blocks: Array, name: String) -> void:
	for block in blocks:
		if typeof(block) != TYPE_DICTIONARY:
			continue
		_strip_sprite_input_refs(String(block.get("opcode", "")), block.get("inputs", {}), name)


## Scrub one block's input slots of references to sprite `name` (helper for strip_sprite_refs): a
## `_SPRITE_OPCODES` reporter naming it reverts to this opcode's default for that key; any other
## nested reporter recurses (it may itself hold one, e.g. `not (touching Ghost?)`); a `body` array
## recurses as a substack.
static func _strip_sprite_input_refs(opcode: String, inputs: Dictionary, name: String) -> void:
	var defaults: Dictionary = _OPCODES.get(opcode, {}).get("defaults", {})
	for key in inputs:
		var value: Variant = inputs[key]
		if typeof(value) == TYPE_DICTIONARY and value.has("opcode"):
			if String(value.get("opcode", "")) in _SPRITE_OPCODES and String(value.get("inputs", {}).get("name", "")) == name:
				inputs[key] = defaults.get(key)
			else:
				_strip_sprite_input_refs(String(value.get("opcode", "")), value.get("inputs", {}), name)
		elif typeof(value) == TYPE_ARRAY:
			strip_sprite_refs(value, name)


## The opcodes whose `{name}` input names a custom block (M32) — the targets a custom-block rename
## cascade walks. `define` is the definition (its own name) and `call` invokes it by name, so renaming
## the block rewrites both. (`param` names a *parameter*, not the block, so it is untouched by a name
## rename — and its sibling `args` keys likewise.) Custom blocks are per-sprite, so the cascade runs
## within one sprite's script only, unlike the globally-unique sprite cascade (M25).
const _CUSTOM_BLOCK_OPCODES := ["define", "call"]


## Rewrite every reference to the custom block `old_name` in `blocks` to `new_name` (M32), in place —
## the custom-block counterpart of rewrite_sprite_refs. A `_CUSTOM_BLOCK_OPCODES` block's `inputs.name`
## is reassigned; nested reporter inputs / `body` substacks recurse (a `call` may sit inside an `if`
## body, the `define`'s body holds the procedure). A `call`'s `args` sub-dict and a `param`'s name are
## *not* rewritten — they bind to parameters, not the block name. (`blocks` and the dicts within are
## references, so this mutates the live script the caller holds.)
static func rewrite_custom_block_refs(blocks: Array, old_name: String, new_name: String) -> void:
	for block in blocks:
		if typeof(block) != TYPE_DICTIONARY:
			continue
		var opcode := String(block.get("opcode", ""))
		var inputs: Dictionary = block.get("inputs", {})
		if opcode in _CUSTOM_BLOCK_OPCODES and String(inputs.get("name", "")) == old_name:
			inputs["name"] = new_name
		for key in inputs:
			var value: Variant = inputs[key]
			if typeof(value) == TYPE_DICTIONARY and value.has("opcode"):
				rewrite_custom_block_refs([value], old_name, new_name)
			elif typeof(value) == TYPE_ARRAY:
				rewrite_custom_block_refs(value, old_name, new_name)


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
			if _OPCODES[opcode].get("category") == category and _OPCODES[opcode].get("palette", true):
				opcodes.append(opcode)
		if not opcodes.is_empty():
			groups.append({"category": category, "opcodes": opcodes})
	return groups


## Whether an opcode is a reporter (a value/boolean block that lives in a slot, not a stack).
## The canvas reads this to ghost a dragged reporter as a pill and to target slots, not gaps.
static func is_reporter(opcode: String) -> bool:
	return _OPCODES.get(opcode, {}).get("kind", "") == "reporter"


## A reporter's output kind (M23): "boolean" or (default) "value". The canvas's _nearest_slot
## matches this against a slot's expected `slot_type` so a boolean reporter only lands in a
## boolean slot and a value reporter only in a value slot. A non-reporter opcode reports "value"
## (harmless — only reporters are ever dragged into slots).
static func reporter_output_type(opcode: String) -> String:
	return String(_OPCODES.get(opcode, {}).get("output", "value"))


## The display colour for a category (used by the palette for its group headers). Falls
## back to the "unknown" grey for an unrecognized category.
static func category_color(category: String) -> Color:
	return _CATEGORY_COLORS.get(category, _CATEGORY_COLORS["unknown"])


# --- Header assembly -------------------------------------------------------

## The dropdown options for an opcode's input slot, or [] for a free-text slot. A fixed-choice
## `enums` list (M13) wins; otherwise a `data_enums` source (M17) resolves to the project model
## the editor owns — so the slot becomes a menu of the project's real variables / sprites. An
## empty model (no editor) yields [], so the slot falls back to a text field, exactly as before.
static func _options_for(info: Dictionary, key: String) -> Array:
	var enums: Dictionary = info.get("enums", {})
	if enums.has(key):
		return enums[key]
	match String(info.get("data_enums", {}).get(key, "")):
		"variables": return project_variables
		"sprites": return project_sprites
		"custom_blocks": return project_custom_blocks
		_: return []


## Split a template on `{name}` placeholders, emitting a Label for each literal span
## and the rendered input widget for each placeholder, packed left-to-right.
static func _header_from_template(template: String, block: Dictionary) -> HBoxContainer:
	# Custom blocks (M31) have a data-driven shape — a define shows one parameter pill per declared
	# parameter, a call one argument slot per parameter — that a fixed template can't express, so they
	# build their header from the block's own data instead of the template.
	var opcode := String(block.get("opcode", ""))
	if opcode == "define":
		return _define_header(block)
	if opcode == "call":
		return _call_header(block)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var inputs: Dictionary = block.get("inputs", {})
	var info: Dictionary = _OPCODES.get(opcode, {})

	var literal := ""
	var i := 0
	while i < template.length():
		if template[i] == "{":
			_push_label(row, literal)
			literal = ""
			var close := template.find("}", i)
			var key := template.substr(i + 1, close - i - 1)
			var slot_type := "boolean" if key in info.get("bool_inputs", []) else "value"
			row.add_child(build_input(inputs, key, _options_for(info, key), info.get("defaults", {}).get(key), slot_type))
			i = close + 1
		else:
			literal += template[i]
			i += 1
	_push_label(row, literal)
	return row


## The header of a `define` hat (M31): "define" + an editable name field + one **spawnable** parameter
## pill per declared parameter. The pills are the procedure's prototype — dragging a copy of one out
## (the canvas's _spawn_at / begin_spawn_drag path) is how a parameter reporter gets into the body, so
## each is stamped via _spawn_param_pill. The name field is an ordinary editable literal (the
## procedure's name). `params` is absent on an M30 define, which simply yields no pills.
static func _define_header(block: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var inputs: Dictionary = block.get("inputs", {})
	_push_label(row, "define")
	# Stamp the name field so the canvas can recognise an in-place rename of the procedure and cascade
	# it to this sprite's `call`s (M32) — without this marker it would commit like any other literal.
	var name_field := build_input(inputs, "name", [], inputs.get("name"))
	name_field.set_meta("define_name", true)
	row.add_child(name_field)
	for p in inputs.get("params", []):
		row.add_child(_spawn_param_pill(String(p)))
	return row


## The header of a `call` block (M31): "call" + a name dropdown (the sprite's custom blocks, via the
## existing `custom_blocks` data-enum) + one argument slot per parameter. The arg slots are built
## against the **`args` sub-dict** (not the block's top-level inputs), so each widget's stamped
## `slot_inputs`/`lit_inputs` reference points into `args` — the canvas's commit / drop / grab code
## then writes straight into `args[param]` with no special-casing (it relies only on the dict
## reference + key). A parameter's label precedes its slot so a multi-arg call reads `call f a: _ b: _`.
## `args` is absent on an M30 call, which yields just the name dropdown.
static func _call_header(block: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var inputs: Dictionary = block.get("inputs", {})
	var info: Dictionary = _OPCODES.get("call", {})
	_push_label(row, "call")
	row.add_child(build_input(inputs, "name", _options_for(info, "name"), info.get("defaults", {}).get("name")))
	var args: Dictionary = inputs.get("args", {})
	for p in args:
		_push_label(row, String(p) + ":")
		row.add_child(build_input(args, String(p), [], 0))
	return row


## A custom-block parameter pill (M31): a small custom-pink reporter pill whose only content is the
## parameter's name as read-only white text. Used both as the value rendered when a `param` reporter
## sits in a slot (build_reporter) and, stamped by _spawn_param_pill, as the prototype pill in a
## define hat.
static func _param_pill(name: String) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _box(_CATEGORY_COLORS["custom"], 10))
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var label := Label.new()
	label.text = name
	label.add_theme_color_override("font_color", Color.WHITE)
	panel.add_child(label)
	return panel


## A parameter pill for the define hat's prototype (M31), stamped so the canvas treats a press-and-drag
## on it as *spawning a fresh `param` reporter of this name* (begin_spawn_drag), rather than grabbing
## the hat — Scratch's "drag a copy of the argument out of the definition" gesture.
static func _spawn_param_pill(name: String) -> Control:
	var pill := _param_pill(name)
	pill.set_meta("spawn_opcode", "param")
	pill.set_meta("spawn_name", name)
	return pill


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
	# Items are listed alphabetically (case-insensitive), regardless of the order the
	# fixed-choice enum / project list supplied them in.
	var sorted := options.map(func(o): return String(o))
	sorted.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	var selected := -1
	for i in sorted.size():
		dd.add_item(sorted[i])
		if sorted[i] == current:
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
