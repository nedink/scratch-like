class_name BlockEditor
extends Control

## The editor scene root — the project's front door (M8), now with a palette of new
## blocks (M11) beside the draggable canvas (M9).
##
## Built runtime-first toward a drag-and-drop block editor: M8 a read-only renderer; M9
## interactive (pick a block up, drag it, snap it in/out of a stack); M10 RUN plays the
## edits; M11 a **palette** to drag *new* blocks from, so a script can be assembled from
## scratch. The canvas interaction lives in block_canvas.gd and the palette in
## block_palette.gd; this scene root is the chrome around them (a sprite selector and a
## RUN button) plus the workspace layout (palette | canvas).
##
## F5 launches *this* instead of the game; the game is reached through the RUN button,
## which switches to main.tscn (the Stage) and hands it the *edited* scripts (M10).
##
## Like stage.gd, the UI is built entirely in code; editor.tscn is a bare root
## Control + this script, matching the project's "generate the scene tree in code"
## idiom (main.tscn is likewise a bare Node2D + stage.gd).

## The game scene the RUN button launches. main.tscn is unchanged from M7 — it is
## just no longer the project's main_scene (the editor is); it is the *game* now.
const _GAME_SCENE := "res://main.tscn"

## Display name -> the sprite's block script, for the selector. This mirrors the
## name->script wiring inline in stage.gd._ready; the small duplication is fine for now.
## A later milestone where the editor *owns* the project model would unify the two.
## Populated in _ready (PongScripts calls aren't const-safe). As of M10 this is the
## **living project**: switching sprites (and RUN) persists the canvas's edits back
## here, so every sprite's edits accumulate for the session.
var _scripts: Array = []

## The currently-selected sprite index, so we know which entry to persist edits into
## before switching away. -1 until the first script loads.
var _current: int = -1

## The interactive block canvas (M9): drag/snap lives here. Reloaded on selection.
var _canvas: BlockCanvas

## The block palette (M11): the source of *new* blocks. Hands fresh blocks to the canvas.
var _palette: BlockPalette


func _ready() -> void:
	_scripts = [
		{"name": "LeftPaddle", "script": PongScripts.left_paddle()},
		{"name": "RightPaddle", "script": PongScripts.right_paddle()},
		{"name": "Ball", "script": PongScripts.ball()},
		{"name": "P1Hud", "script": PongScripts.p1_hud()},
		{"name": "P2Hud", "script": PongScripts.p2_hud()},
		{"name": "Announcer", "script": PongScripts.announcer()},
	]

	# Hand the project model to the renderer (M17) *before* the palette builds and the canvas
	# renders, so the `{name}` slots of variable/set/change and touching {name}? draw as
	# data-scoped dropdowns. Sprite names come straight from the script list above; variable
	# names from the one project model the runtime seeds from too (M18 — PongScripts.variables(),
	# no longer a separate hardcoded list here). (Static on BlockView, like Stage.project_scripts.)
	BlockView.project_sprites = _sprite_names()
	BlockView.project_variables = _variable_names()

	# A small default font size so the chunky blocks fit the 480x360 viewport (which
	# the project integer-stretches to fullscreen). One Theme on the root cascades to
	# every label and button below.
	var ui_theme := Theme.new()
	ui_theme.default_font_size = 11
	theme = ui_theme
	set_anchors_preset(Control.PRESET_FULL_RECT)

	# Dark backdrop behind everything (added first so it sits at the back).
	var backdrop := ColorRect.new()
	backdrop.color = Color("#1e1e22")
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)

	var page := VBoxContainer.new()
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	page.add_theme_constant_override("separation", 4)
	add_child(page)

	# Top bar: title + sprite selector + RUN.
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	page.add_child(bar)

	var title := Label.new()
	title.text = "scratch-like"
	bar.add_child(title)

	var selector := OptionButton.new()
	for entry in _scripts:
		selector.add_item(entry["name"])
	selector.item_selected.connect(_on_select)
	bar.add_child(selector)

	# Push RUN to the right edge.
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	var run := Button.new()
	run.text = "RUN"
	run.pressed.connect(_on_run)
	bar.add_child(run)

	# The workspace: a fixed-width palette of new blocks (M11) on the left, the editable
	# canvas filling the rest. Each sits in its own ScrollContainer (the palette's list
	# and a tall script both overflow). Hit-testing uses global coordinates throughout,
	# so both stay correct whatever their scroll offsets.
	var workspace := HBoxContainer.new()
	workspace.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.add_theme_constant_override("separation", 4)
	page.add_child(workspace)

	# Fixed-width viewport; the palette scrolls vertically through the block list and, if
	# a long block label overflows the width, horizontally too (rather than clipping it).
	var palette_scroll := ScrollContainer.new()
	palette_scroll.custom_minimum_size = Vector2(150, 0)
	palette_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.add_child(palette_scroll)

	_palette = BlockPalette.new()
	palette_scroll.add_child(_palette)

	# The canvas gets a generous minimum size so there's room to drag stacks around and
	# scrollbars appear when content overflows.
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.add_child(scroll)

	_canvas = BlockCanvas.new()
	_canvas.custom_minimum_size = Vector2(1200, 1200)
	scroll.add_child(_canvas)

	# The palette feeds fresh blocks to the canvas (M11) and doubles as the canvas's trash:
	# dragging a block back over the palette region deletes it (M16, Scratch's own gesture).
	_palette._canvas = _canvas
	_canvas._trash = palette_scroll

	_show(0)


## Load the script at `index` into the canvas, first persisting the outgoing sprite's
## edits so switching sprites doesn't discard them (M10 — edits are no longer a
## throwaway sandbox). The canvas works on a deep copy; _persist serializes it back.
func _show(index: int) -> void:
	_persist_current()
	_current = index
	_canvas.load_script(_scripts[index]["script"])


func _on_select(index: int) -> void:
	_show(index)


## The project's sprite names (M17), the sprites half of the project model — the targets a
## `touching {name}?` slot offers. Derived straight from the script list, the editor's existing
## name registry, so it stays in step with whatever sprites the project has.
func _sprite_names() -> Array:
	var names: Array = []
	for entry in _scripts:
		names.append(entry["name"])
	return names


## The project's variable names (M17), the variables half of the project model — the options a
## `{name}` slot of variable/set_var/change_var offers. As of M18 these are derived from the one
## project model the runtime also seeds from (PongScripts.variables()), rather than a list this
## file hardcoded separately — so the editor's dropdowns and the Stage's seeding can't drift apart.
func _variable_names() -> Array:
	var names: Array = []
	for v in PongScripts.variables():
		names.append(v["name"])
	return names


## Serialize the canvas's current edits back into the selected sprite's entry, so they
## survive a sprite switch or a RUN. A no-op before the first load (_current == -1).
func _persist_current() -> void:
	if _current >= 0 and _current < _scripts.size():
		_scripts[_current]["script"] = _canvas.export_script()


## RUN: hand the *edited* project to the Stage and switch to the game scene (M10). The
## scripts ride across the scene change on a static var (a plain value can't be passed
## through change_scene_to_file); the Stage reads it, falling back to PongScripts for
## any sprite it lacks — so launching main.tscn directly still plays stock Pong. We
## deep-duplicate so the running game can't mutate the editor's working data.
func _on_run() -> void:
	_persist_current()
	var project: Dictionary = {}
	for entry in _scripts:
		project[entry["name"]] = (entry["script"] as Array).duplicate(true)
	Stage.project_scripts = project
	get_tree().change_scene_to_file(_GAME_SCENE)
