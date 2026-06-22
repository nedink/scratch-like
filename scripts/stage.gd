class_name Stage
extends Node2D

## The multi-sprite runtime root. This is the Milestone 2 replacement for M1's
## one-shot wiring in main.gd: instead of building a single sprite and running
## one script, the Stage builds *several* sprites and runs each one's block
## script as an independent coroutine.
##
## Its load-bearing new job is the **target registry** — a name -> Target map.
## This is the first time the block language names another entity, so anything
## cross-sprite (`touching_sprite?` today, more later) is resolved through here.
##
## Like M1, the sprites are generated in code (colored placeholder rectangles)
## so the scene stays a near-empty root and the project needs no image assets.

## The editor scene to return to on ESC — the inverse of editor.gd's RUN.
## In-game, ESC drops back into the block editor; in the editor it quits the program.
const _EDITOR_SCENE := "res://editor.tscn"

## The runtime's fixed logical resolution (M26). The window is sized for the editor now, so the
## game re-imposes this on itself (see _apply_game_scaling). go_to coordinates, edge detection,
## and the pixel-art costumes are all authored against it — it must stay 480x352.
const _GAME_SIZE := Vector2i(480, 352)

## name (String) -> Target. The single source of truth for "who is on stage".
var _targets: Dictionary = {}

## Interpreters are held so their fire-and-forget coroutines (and the RefCounted
## interpreters themselves) outlive _ready() and keep running.
var _interpreters: Array[Interpreter] = []

## Every live Target whose node should be moved by its built-in velocity (M43): all registered
## sprites *plus* clones (which aren't in the name registry). _physics_process walks this each tick
## and applies `node.position += velocity`. A clone is appended in create_clone_of and removed in
## remove_clone, so this stays in step with what's actually on stage.
var _movables: Array[Target] = []

## name (String) -> value. Global ("for all sprites") variables, shared by every
## script. M3's scores live here; per-sprite locals live on each Target instead.
var _variables: Dictionary = {}

## Cleared by the `stop "all"` block. Every forever / run-stack polls this and
## bails when it goes false, so the whole game halts within a frame — the
## game-over freeze. As of M6 the Announcer paints the winner's banner in the
## same frame it fires this, so the freeze finally lands with the win on screen.
var _running: bool = true

## The shared bitmap font (M6). Built once from font.png; the interpreter renders
## `say` text through it. Held on the Stage like the target registry — one runtime
## resource every sprite reaches, never reloaded per sprite.
var _font: PixelFont

## The project's sprite model, the editor's RUN hand-off (M24): an Array of
## {name, x, y, w, h, color, script} dicts — every sprite the project holds, with its placeholder
## geometry and script. The editor sets this *static* (so it survives change_scene_to_file, which
## can't pass a value) right before launching the game; _ready falls back to PongScripts.sprites()
## when it is empty, so launching this scene directly (no editor) still builds and plays stock Pong.
## Static, so it outlives any one Stage instance.
static var project_sprites: Array = []

## The project's variable model (M18/M20): an Array of {name, value, scope} dicts the Stage seeds at
## _ready (a "global" entry to the Stage store, a sprite-scoped one to that target's locals). Falls
## back to PongScripts.variables() on a direct launch.
static var project_variables: Array = []

## The project's stage background colour as a hex string (M27). Falls back to PongScripts.background().
static var project_background: String = ""

## The runtime camera (M37). A Camera2D centred at the screen midpoint (240,176) by default, which
## reproduces the no-camera identity view exactly — so a project with no camera blocks renders as
## before. The camera blocks (set_camera / change_camera / camera_follow / camera_stop_following)
## scroll it. Its `position` is the world point shown at screen centre, so camera coordinates are the
## same space sprite coordinates live in.
var _camera: Camera2D

## The sprite the camera tracks (M37), or null when not following. While set, _process keeps the
## camera centred on it each frame. set_camera / move_camera clear it (manual control wins).
var _camera_follow: Target = null


func _ready() -> void:
	# Re-impose the runtime's fixed logical resolution (M26). The project window is now sized for
	# the *editor* (a large window, stretch "disabled"), so the game has to opt back into the
	# 480x352 logical viewport it has always assumed: go_to coordinates, edge detection via
	# get_viewport_rect(), and the integer-upscaled pixel-art costumes all depend on it. Setting
	# content_scale_size keeps get_viewport_rect() reporting 480x352 — so no runtime logic changes —
	# while content_scale_factor forces a *whole-number* upscale (crisp glyphs, the old look) and
	# ASPECT_KEEP centers + letterboxes the slack. editor.gd._ready resets this on the ESC return.
	_apply_game_scaling()

	# Paint the stage background (M27): a full-viewport ColorRect. It sits on a CanvasLayer at layer -1
	# (M37) so it stays **screen-fixed** when the camera pans (a CanvasLayer is not transformed by a
	# Camera2D) and draws *behind* the sprites (the negative layer). Its colour is the project's
	# background hex (the editor's, else PongScripts'); the 480x352 logical viewport is the space sprite
	# coordinates live in, so size it to _GAME_SIZE.
	var bg_layer := CanvasLayer.new()
	bg_layer.layer = -1
	add_child(bg_layer)
	var background := ColorRect.new()
	background.color = Color(_background_hex())
	background.position = Vector2.ZERO
	background.size = Vector2(_GAME_SIZE)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg_layer.add_child(background)

	_font = PixelFont.new()

	# Build every sprite from the project's sprite model (Milestone 24) — the editor's edited
	# model when it handed one over (Stage.project_sprites, which may include sprites *added in the
	# UI*), else PongScripts (a direct launch still builds stock Pong — see _sprite_model).
	# Each entry carries the placeholder geometry stage.gd used to hardcode plus the sprite's script:
	#   * the paddles 16x96 on their rails and the ball 16x16 near center (the playfield);
	#   * the two HUDs (top corners) and the Announcer (parked off-screen) as 16x16 transparent
	#     placeholders — they carry no costume of their own, `say` supplies one each tick / on the
	#     win, drawn at the sprite's native scale 1 (the 480x352 window is integer-upscaled, so even
	#     the native "large" glyph reads cleanly). See pong_scripts.gd for why each script exists.
	# `color` is a hex string in the model (JSON-friendly for SAVE/OPEN); Color() parses it here.
	# We build *all* sprites first so the registry is fully populated before variable seeding, which
	# needs a sprite-scoped local's target to already exist.
	var model: Array = _sprite_model()
	for s in model:
		_add_sprite(String(s["name"]), Vector2(s["x"], s["y"]), int(s["w"]), int(s["h"]), Color(String(s["color"])))

	# The runtime camera (M37). Centred at the screen midpoint, so by default the view is identical to
	# the old no-camera transform (the screen shows world (0,0)-(480,352)). make_current() routes the
	# viewport through it; the camera blocks then scroll it.
	_camera = Camera2D.new()
	_camera.position = Vector2(_GAME_SIZE) * 0.5
	add_child(_camera)
	_camera.make_current()

	# Seed every variable from the one project model (Milestone 18) — the same declaration
	# the editor reads its `{name}` dropdown options from, so the two can no longer drift.
	# A "global" entry lands on the Stage's store; a sprite-scoped one lands on that target's
	# locals — e.g. the ball's `speed`, which move_steps reads as a variable, proving the
	# local store works alongside the globals. As of M20 the model comes from the editor when
	# it handed one over (so a variable *made in the UI* is seeded too), else PongScripts — see
	# _variable_model. The scores are global so the ball can drive them and the HUDs can watch.
	# Every declared variable seeds to 0; non-zero starts (the ball's `speed`) come from `set` blocks
	# in the scripts, not the seed (Scratch's model — the starting value lives in the editable program).
	for v in _variable_model():
		if v["scope"] == "global":
			set_var(v["name"], v["value"])
		else:
			var host := find_target(v["scope"])
			if host:
				host.variables[v["name"]] = v["value"]
			else:
				push_warning("Stage: variable '%s' scoped to unknown sprite '%s'" % [v["name"], v["scope"]])

	# "Press the green flag" on the first *rendered* frame, not during scene
	# construction. A script's first `forever` iteration runs synchronously the
	# moment it starts (the interpreter only yields at the first `await`), so
	# starting scripts here in _ready would run all the edge/collision logic before
	# the SceneTree has processed a single frame — when `get_viewport_rect()` may not
	# yet report the configured window size. With a zero/stale viewport, every sprite
	# reads itself as past an edge (paddles snap to a rail, the ball "scores" at
	# center) and they trip each other's triggers. Waiting one frame guarantees the
	# viewport is sized before any block runs. (Intermittent because the viewport is
	# ready early on some launches but not others.)
	await get_tree().process_frame

	# Run each sprite's script (the same model, second pass). The script rides inside the entry now
	# (M24), so there is no separate name->script lookup; an editor-edited or UI-added sprite's
	# script is simply the one in its entry.
	for s in model:
		_run(find_target(String(s["name"])), s["script"])


## Keep the camera on the followed sprite each frame (M37). A no-op until `camera_follow` sets a
## target. Runs on the render frame (not the physics tick the scripts use) so tracking is smooth.
func _process(_delta: float) -> void:
	if _camera_follow != null and is_instance_valid(_camera_follow.node):
		_camera.position = _camera_follow.node.position


## Apply every sprite's built-in velocity (M43): the "modifies position once a frame behind the
## scenes" half of the velocity feature. We run on the **physics** tick (not _process's render
## frame) and add the raw per-tick velocity with no delta scaling — the same fixed-tick model
## move_steps uses, so `set velocity y: 6` and `move 6` in a forever cover the same ground. Godot
## emits `physics_frame` (which the script coroutines await) *after* all _physics_process calls, so
## each tick velocity moves the sprite first, then its script runs (reading the moved position) — a
## consistent order. A zero velocity (every sprite that never sets it) is a no-op, so existing
## projects render unchanged.
func _physics_process(_delta: float) -> void:
	for t in _movables:
		if t.velocity != Vector2.ZERO and is_instance_valid(t.node):
			t.node.position += t.velocity


## ESC returns to the editor (the inverse of RUN's editor→game hand-off). Unhandled-input,
## so anything that wants ESC first — a focused control — gets it before we leave the scene.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		get_tree().change_scene_to_file(_EDITOR_SCENE)


## Lock the window into the fixed 480x352 logical viewport with a strict integer upscale (M26).
## content_scale_size = _GAME_SIZE makes get_viewport_rect() report 480x352 (so every bit of
## edge/position logic is untouched); VIEWPORT mode renders the whole 2D world into that small
## viewport and blits it up to fill the window. ASPECT_KEEP preserves the 4:3 ratio (letterboxing
## the slack), and STRETCH_INTEGER snaps the fit to a whole-number scale so the pixel-art / `say`
## glyphs stay crisp. content_scale_factor stays 1.0: it is an *extra* multiplier on top of the
## automatic fit, not the fit itself — setting it to the integer factor (as a first cut did) zooms
## the view that many times too far. The editor undoes all of this on the ESC return.
func _apply_game_scaling() -> void:
	var win := get_window()
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	win.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_INTEGER
	win.content_scale_size = _GAME_SIZE
	win.content_scale_factor = 1.0


## The sprite model to build from (M24): the editor's edited model when it handed one over
## (Stage.project_sprites — every sprite the project holds, including UI-added ones), else the
## hardcoded PongScripts.sprites(). Launching this scene directly (no editor) still builds stock Pong.
func _sprite_model() -> Array:
	return project_sprites if not project_sprites.is_empty() else PongScripts.sprites()


## The variable model to seed from (M18/M20): the editor's model when handed one over
## (Stage.project_variables), else PongScripts.variables().
func _variable_model() -> Array:
	return project_variables if not project_variables.is_empty() else PongScripts.variables()


## The background colour hex to paint (M27): the editor's when handed one over (Stage.project_background),
## else PongScripts.background().
func _background_hex() -> String:
	return project_background if project_background != "" else PongScripts.background()


# --- Camera (Milestone 37) -------------------------------------------------

## set_camera: centre the view on world point (x, y). Clears any follow so the manual position holds
## (camera_follow / camera_stop_following manage tracking).
func set_camera(x: float, y: float) -> void:
	_camera_follow = null
	if _camera:
		_camera.position = Vector2(x, y)


## change_camera: scroll the view by (dx, dy) from its current centre. Also stops following (a manual
## move is manual control).
func move_camera(dx: float, dy: float) -> void:
	_camera_follow = null
	if _camera:
		_camera.position += Vector2(dx, dy)


## camera_follow: track the named sprite — _process re-centres on it each frame. Unknown name warns
## and leaves the camera where it is (the block's dropdown lists real sprites).
func camera_follow(target_name: String) -> void:
	var target := find_target(target_name)
	if target == null:
		push_warning("Stage: camera follow unknown sprite '%s'" % target_name)
		return
	_camera_follow = target


## camera_stop_following: release tracking; the camera holds its current position.
func camera_stop_following() -> void:
	_camera_follow = null


# --- Layer / z-order (Milestone 42) ----------------------------------------
#
# The runtime counterpart of the M42 stage-editor Layer buttons. Visual order is controlled here by
# the node's `z_index` (CanvasItem's draw-order key) rather than child order: the editor's sprite-array
# order sets the *initial* stack (every node built at z_index 0, so build order breaks the tie — a later
# sprite draws on top), and these blocks override it at play time. z_index decouples layer from tree
# position, so it composes cleanly with the camera / clones without reparenting anything.

## go to front / back layer: set `node`'s z_index just past the current extreme over all registered
## sprites, so it draws in front of (to_front) / behind every other sprite. Computed against the
## registry (the addressable originals — clones share an original's name and aren't individually
## restacked); an empty stage just lands the node at ±1 off the default 0.
func set_layer(node: Node2D, to_front: bool) -> void:
	var extreme := 0
	var seen := false
	for t in _targets.values():
		if t.node == node or not is_instance_valid(t.node):
			continue
		var z := (t.node as Node2D).z_index
		if not seen:
			extreme = z
			seen = true
		else:
			extreme = maxi(extreme, z) if to_front else mini(extreme, z)
	node.z_index = (extreme + 1) if to_front else (extreme - 1)


## go forward / backward N layers: shift `node`'s z_index by `by` (positive = toward the front).
## Clamped to the engine's CanvasItem z range so a runaway loop can't push it out of bounds.
func change_layer(node: Node2D, by: int) -> void:
	node.z_index = clampi(node.z_index + by, RenderingServer.CANVAS_ITEM_Z_MIN, RenderingServer.CANVAS_ITEM_Z_MAX)


## Look up another target by the name it was registered under. Returns null if
## there is no such target (callers warn / no-op rather than crash).
func find_target(target_name: String) -> Target:
	return _targets.get(target_name)


## All registered target names — used by collision code that needs to scan
## every other sprite on the stage.
func target_names() -> Array:
	return _targets.keys()


## The shared bitmap font, so the interpreter's `say` block can render text
## without each sprite reloading the atlas.
func font() -> PixelFont:
	return _font


# --- Global variables & run state (Milestone 3) ----------------------------

## Read a global variable. Returns 0 when unset; interpreters resolve a sprite's
## locals before falling back here, so this is only reached for true globals.
func get_var(var_name: String) -> Variant:
	return _variables.get(var_name, 0)


## Write a global variable.
func set_var(var_name: String, value: Variant) -> void:
	_variables[var_name] = value


## Whether a global by this name exists — used by the interpreter's local-first
## variable resolution to decide whether an assignment lands locally or here.
func has_var(var_name: String) -> bool:
	return _variables.has(var_name)


## True until `stop "all"` runs. Scripts poll this to know when to unwind.
func is_running() -> bool:
	return _running


## The `stop "all"` block: flip the flag every script is watching.
func stop_all() -> void:
	_running = false


# --- Setup helpers ---------------------------------------------------------

## Build one sprite (placeholder texture + start position), register it, and
## return its Target.
func _add_sprite(target_name: String, pos: Vector2, w: int, h: int, color: Color) -> Target:
	var sprite := Sprite2D.new()
	sprite.texture = _make_placeholder_texture(w, h, color)
	sprite.position = pos
	add_child(sprite)

	var target := Target.new(sprite, target_name)
	_targets[target_name] = target
	_movables.append(target)  # so _physics_process applies its built-in velocity (M43)
	return target


## Create an interpreter for a target and start its script as a fire-and-forget
## coroutine (run() returns as soon as the script first yields a frame).
func _run(target: Target, script: Array) -> void:
	var interpreter := Interpreter.new(self, target)
	_interpreters.append(interpreter)
	interpreter.run(script)


## Spawn a clone of `source`: a new node copying its costume + transform, a new
## Target inheriting its direction and *local* variables (Scratch semantics), and
## a fresh interpreter that launches the script's when_i_start_as_a_clone hats.
## Clones are deliberately *not* added to the name registry — they share the
## original's name but aren't individually addressable, so find_target and
## touching_sprite? keep resolving the single original. Retaining the interpreter
## in _interpreters keeps the clone (and its node) alive.
func create_clone_of(source: Target, script: Array) -> void:
	var src := source.node as Sprite2D
	var clone_node := Sprite2D.new()
	clone_node.texture = src.texture
	clone_node.position = src.position
	clone_node.scale = src.scale
	add_child(clone_node)

	var clone := Target.new(clone_node, source.name)
	clone.direction = source.direction
	clone.variables = source.variables.duplicate()
	clone.velocity = source.velocity  # inherit built-in velocity, like direction / locals (M43)
	clone.is_clone = true
	_movables.append(clone)  # moved by its velocity each tick, then released in remove_clone

	var interpreter := Interpreter.new(self, clone)
	_interpreters.append(interpreter)
	interpreter.run_as_clone(script)


## Tear down a clone (the `delete_this_clone` block): free its node and release its
## interpreter. The interpreter has already cleared its own `_alive`, so its
## coroutine is unwinding; erasing it here is safe because the suspended coroutine
## still holds a reference until it returns, and queue_free defers node removal to
## frame end. Unlike `stop "all"`, this touches only the one clone.
func remove_clone(interpreter: Interpreter, clone: Target) -> void:
	clone.node.queue_free()
	_interpreters.erase(interpreter)
	_movables.erase(clone)  # stop applying velocity to a freed clone (M43)


## Generate a plain colored rectangle in code so the project has no dependency
## on any imported image asset. (Later milestones can swap in real costumes.)
func _make_placeholder_texture(w: int, h: int, color: Color) -> Texture2D:
	var image := Image.create(w, h, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)
