class_name BlockEditor
extends Control

## The Milestone 8 editor scene root — the project's new front door.
##
## For seven milestones this was built runtime-first toward a drag-and-drop block
## editor. M8 lays its first stone: a **read-only block renderer**. There is no
## dragging, palette, or building yet — the editor draws an existing sprite's block
## script as a stack of visual Scratch-style blocks (see block_view.gd, the drawing
## counterpart to the interpreter's execution).
##
## F5 now launches *this* instead of the game. The game still runs exactly as before
## — it is reached through the RUN button, which switches to main.tscn (the Stage).
##
## Like stage.gd, the UI is built entirely in code; editor.tscn is a bare root
## Control + this script, matching the project's "generate the scene tree in code"
## idiom (main.tscn is likewise a bare Node2D + stage.gd).

## The game scene the RUN button launches. main.tscn is unchanged from M7 — it is
## just no longer the project's main_scene (the editor is); it is the *game* now.
const _GAME_SCENE := "res://main.tscn"

## Display name -> the sprite's block script, for the selector. This mirrors the
## name->script wiring inline in stage.gd._ready; for a read-only view the small
## duplication is fine. A later milestone where the editor *owns* the project model
## would unify the two. Populated in _ready (PongScripts calls aren't const-safe).
var _scripts: Array = []

## The scrollable canvas the rendered block stack lives in; rebuilt on selection.
var _canvas: ScrollContainer


func _ready() -> void:
	_scripts = [
		{"name": "LeftPaddle", "script": PongScripts.left_paddle()},
		{"name": "RightPaddle", "script": PongScripts.right_paddle()},
		{"name": "Ball", "script": PongScripts.ball()},
		{"name": "P1Hud", "script": PongScripts.p1_hud()},
		{"name": "P2Hud", "script": PongScripts.p2_hud()},
		{"name": "Announcer", "script": PongScripts.announcer()},
	]

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

	_canvas = ScrollContainer.new()
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(_canvas)

	_show(0)


## Render the script at `index` into the canvas, replacing whatever was there.
func _show(index: int) -> void:
	for child in _canvas.get_children():
		child.queue_free()
	_canvas.add_child(BlockView.build_script(_scripts[index]["script"]))


func _on_select(index: int) -> void:
	_show(index)


## RUN: hand off to the game scene. The editor is read-only, so this launches the
## existing M7 Pong unchanged — it does not run an edited script.
func _on_run() -> void:
	get_tree().change_scene_to_file(_GAME_SCENE)
