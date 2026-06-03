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

## name (String) -> Target. The single source of truth for "who is on stage".
var _targets: Dictionary = {}

## Interpreters are held so their fire-and-forget coroutines (and the RefCounted
## interpreters themselves) outlive _ready() and keep running.
var _interpreters: Array[Interpreter] = []

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


func _ready() -> void:
	_font = PixelFont.new()

	# Two tall thin paddles on the rails, one small ball in the center.
	var paddle := Color(0.9, 0.9, 0.95)
	var ball_color := Color(1.0, 0.8, 0.25)
	var left := _add_sprite("LeftPaddle", Vector2(40, 300), 16, 96, paddle)
	var right := _add_sprite("RightPaddle", Vector2(760, 300), 16, 96, paddle)
	var ball := _add_sprite("Ball", Vector2(400, 300), 16, 16, ball_color)

	# Milestone 3 state, seeded up front (this code stands in for a future
	# editor's "make a variable" step). Scores are global; the ball's speed is a
	# per-sprite local, which both lets move_steps read it as a variable and
	# proves the local store works alongside the globals.
	set_var("p1_score", 0)
	set_var("p2_score", 0)
	# Milestone 5 best-of-N state: per-round scores (above) reset each round, while
	# rounds-won persist for the match, and a monotonic `round` counter signals the
	# pip clones to clear (each clone deletes itself once `round` passes its birth
	# round). All global so the ball can drive them and the pip sprites can watch.
	set_var("p1_rounds", 0)
	set_var("p2_rounds", 0)
	set_var("round", 1)
	ball.variables["speed"] = PongScripts.BALL_SPEED

	# Milestone 4: a score readout made of clones. Each pip sprite parks itself
	# off-screen and clones one small marker per point (see pong_scripts.gd).
	var pip := Color(0.4, 0.9, 0.5)
	var off_screen := Vector2(-100, -100)
	var p1_pips := _add_sprite("P1Pips", off_screen, 10, 10, pip)
	var p2_pips := _add_sprite("P2Pips", off_screen, 10, 10, pip)
	# Seed the locals the layout math writes to, so they resolve as locals (and
	# are inherited by each clone) rather than leaking into the global store.
	# `my_round` lets the maker notice a new round and restart its pip count;
	# `born_round` is stamped onto each clone so it knows when to delete itself.
	# Note there is deliberately no local `round` — both maker and clone read the
	# *global* `round` the ball drives; a local would shadow it.
	for pips in [p1_pips, p2_pips]:
		pips.variables = {"count": 0, "index": 0, "col": 0, "row": 0, "my_round": 1, "born_round": 1}

	# Milestone 6: a text banner. The Announcer parks off-screen until a player
	# takes the match, then jumps to center, `say`s the winner (a font.png costume),
	# and fires `stop "all"` itself — so the game-over freeze lands with the winner
	# named on screen, the payoff earlier milestones kept deferring. It `say`s in the
	# "large" (5x9) face, sized to read at the viewport's own resolution, so the node
	# stays at scale 1 — the banner is drawn 1:1, never scaled up.
	var announcer := _add_sprite("Announcer", Vector2(-400, -400), 1, 1, Color(1, 1, 1, 0))

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

	_run(left, PongScripts.left_paddle())
	_run(right, PongScripts.right_paddle())
	_run(ball, PongScripts.ball())
	_run(p1_pips, PongScripts.p1_pips())
	_run(p2_pips, PongScripts.p2_pips())
	_run(announcer, PongScripts.announcer())


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
	clone.is_clone = true

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


## Generate a plain colored rectangle in code so the project has no dependency
## on any imported image asset. (Later milestones can swap in real costumes.)
func _make_placeholder_texture(w: int, h: int, color: Color) -> Texture2D:
	var image := Image.create(w, h, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)
