class_name Interpreter
extends RefCounted

## Tree-walking interpreter for "block scripts".
##
## A block script is plain, serializable data (see example_script.gd): an Array
## of block dictionaries shaped like
##
##     {"opcode": "move_steps", "inputs": {"steps": 5}}
##
## Substacks (the body of `forever`, the body/condition of `if`) are just nested
## Arrays / nested block dictionaries stored under "inputs". There is no UI here
## and no class hierarchy of "block" objects — exactly the data a visual editor
## would emit later.
##
## Execution model — GDScript coroutines on a fixed logical tick:
##   * Running a stack of blocks is an `await`-ing method, i.e. a coroutine.
##   * Long-running control blocks (`forever`) `await get_tree().physics_frame`
##     once per iteration, so the script cooperatively yields back to the engine
##     every *tick* instead of blocking it in an infinite loop.
##   * We deliberately tick on the **physics** frame, not the render frame. Blocks
##     count ticks, not seconds (`move_steps` moves a fixed N px per loop), so a
##     constant speed only falls out if the loop runs at a constant rate. The
##     physics frame fires at a fixed `physics_ticks_per_second` (default 60)
##     regardless of render FPS, and the engine clamps how many fire per render
##     frame — so motion is frame-rate-independent and a slow/bursty startup can't
##     fling a sprite across the screen. (This is Scratch's own fixed-tick model;
##     scaling each move by frame delta instead would wrongly turn a *one-shot*
##     `move 10` into a frame-rate-dependent distance.)
##   * We start a script with a plain (non-awaited) call. The coroutine then
##     keeps itself alive by awaiting the SceneTree's per-tick signal.
##
## Dispatch:
##   * Opcode -> handler `Callable`, looked up in a table. Adding a new block
##     type later is just registering one more entry plus its handler method.

## The Stage this interpreter runs under. Two reasons we hold it instead of a
## bare SceneTree (as M1 did):
##   * coroutines still need `await _tree.physics_frame` — we get the tree from
##     the Stage, which is a Node;
##   * cross-sprite blocks (`touching_sprite?`) resolve other entities through
##     `_stage.find_target(name)`.
var _stage: Stage

## SceneTree, cached from the Stage so coroutines can `await _tree.physics_frame`
## (a RefCounted has no get_tree() of its own).
var _tree: SceneTree

## The sprite this interpreter drives.
var _target: Target

## This target's full script (all hats), retained so a clone can locate and
## launch the `when_i_start_as_a_clone` hats. Set by run() / run_as_clone().
var _script: Array = []

## Per-interpreter "keep running" flag — the per-script counterpart to the Stage's
## global `_running`. `_run_stack` and `_on_forever` poll it alongside the Stage
## flag, so flipping it false unwinds *just this* coroutine within a frame. Both
## `stop "this script"` and `delete_this_clone` work by clearing it.
var _alive: bool = true

## Custom-block parameter frames (M31): a stack of `{param_name: value}` dicts, one per active
## `call`. `_on_call` evaluates a call's arguments in the *current* frame, pushes a new frame, runs
## the procedure body, then pops it; the `param` reporter reads the top frame. A stack (not a single
## dict) so a custom block can call another — or itself — each binding its own arguments, and the
## inner frame shadows the outer for the duration of the nested body. Per-interpreter, so each sprite
## (and clone) keeps its own frames.
var _frames: Array = []

## opcode (String) -> Callable for blocks that *do* something (statements).
var _statement_handlers: Dictionary = {}

## opcode (String) -> Callable for blocks that *return a value* (reporters /
## boolean conditions), e.g. "touching_edge?".
var _reporter_handlers: Dictionary = {}


func _init(stage: Stage, target: Target) -> void:
	_stage = stage
	_tree = stage.get_tree()
	_target = target
	_register_handlers()


# --- Dispatch tables -------------------------------------------------------

func _register_handlers() -> void:
	_statement_handlers = {
		"when_flag_clicked": _on_when_flag_clicked,
		"forever": _on_forever,
		"if": _on_if,
		"move_steps": _on_move_steps,
		"turn_degrees": _on_turn_degrees,
		"point_in_direction": _on_point_in_direction,
		"point_towards": _on_point_towards,
		"go_to": _on_go_to,
		"set_color": _on_set_color,
		"wait_seconds": _on_wait_seconds,
		"set_var": _on_set_var,
		"change_var": _on_change_var,
		"animate": _on_animate,
		"say": _on_say,
		"stop": _on_stop,
		"create_clone": _on_create_clone,
		"when_i_start_as_a_clone": _on_when_i_start_as_a_clone,
		"delete_this_clone": _on_delete_this_clone,
		"define": _on_define,
		"call": _on_call,
		"set_camera": _on_set_camera,
		"change_camera": _on_change_camera,
		"camera_follow": _on_camera_follow,
		"camera_stop_following": _on_camera_stop_following,
	}
	_reporter_handlers = {
		"touching_edge?": _on_touching_edge,
		"touching_sprite?": _on_touching_sprite,
		"key_pressed?": _on_key_pressed,
		"variable": _on_variable,
		"add": _on_add,
		"subtract": _on_subtract,
		"multiply": _on_multiply,
		"divide": _on_divide,
		"mod": _on_mod,
		"equals": _on_equals,
		"greater_than": _on_greater_than,
		"less_than": _on_less_than,
		"and": _on_and,
		"or": _on_or,
		"not": _on_not,
		"random": _on_random,
		"param": _on_param,
		"direction": _on_direction,
		"x_position": _on_x_position,
		"y_position": _on_y_position,
		"mouse_x": _on_mouse_x,
		"mouse_y": _on_mouse_y,
	}


# --- Entry point -----------------------------------------------------------

## Start every hat block in `script`. This is the equivalent of clicking the
## green flag. We launch each hat's body as a fire-and-forget coroutine so the
## caller (and the engine) is never blocked.
func run(script: Array) -> void:
	_script = script
	for block in script:
		if _opcode(block) == "when_flag_clicked":
			# No `await`: this returns as soon as the body first yields a frame.
			_run_stack(_body(block))


## Start this script as a freshly spawned clone: like run(), but the entry points
## are the `when_i_start_as_a_clone` hats instead of the green-flag hats.
func run_as_clone(script: Array) -> void:
	_script = script
	for block in script:
		if _opcode(block) == "when_i_start_as_a_clone":
			_run_stack(_body(block))


# --- Core walker -----------------------------------------------------------

## Run a list of blocks in order. This is a coroutine: any block that awaits
## (e.g. forever) suspends the whole stack until it resumes.
func _run_stack(blocks: Array) -> void:
	for block in blocks:
		# Bail mid-stack the moment `stop "all"` fires (Stage flag) or this script
		# alone is stopped/deleted (`_alive`), so no further blocks run.
		if not _stage.is_running() or not _alive:
			return
		await _execute(block)


## Run a single statement block by dispatching on its opcode.
func _execute(block: Dictionary) -> void:
	var opcode := _opcode(block)
	var handler: Callable = _statement_handlers.get(opcode, Callable())
	if handler.is_valid():
		# `await` works whether or not the handler is itself a coroutine:
		# for a plain handler it simply passes the (void) result through.
		await handler.call(block)
	else:
		push_warning("Interpreter: unknown statement opcode '%s'" % opcode)


## Evaluate an input. An input is either a literal value (number, string, ...)
## or a nested reporter block (a Dictionary with an "opcode"). This is how a
## condition like {"opcode": "touching_edge?"} gets turned into a bool.
func _evaluate(input: Variant) -> Variant:
	if typeof(input) == TYPE_DICTIONARY and input.has("opcode"):
		var opcode: String = input["opcode"]
		var handler: Callable = _reporter_handlers.get(opcode, Callable())
		if handler.is_valid():
			return handler.call(input)
		push_warning("Interpreter: unknown reporter opcode '%s'" % opcode)
		return null
	return input  # plain literal


# --- Statement handlers ----------------------------------------------------

## Hat block. As a nested statement it just runs its body; the real entry point
## is run() above.
func _on_when_flag_clicked(block: Dictionary) -> void:
	await _run_stack(_body(block))


## forever { body }  — run the body, yield one tick, repeat forever.
## The per-iteration `await` is what keeps this from freezing the engine. We yield
## on the *physics* frame (a fixed-rate tick), not the render frame, so a script
## that moves N px per loop holds a constant speed no matter the render FPS — see
## the fixed-tick note at the top of the file.
func _on_forever(block: Dictionary) -> void:
	var body := _body(block)
	while _stage.is_running() and _alive:
		await _run_stack(body)
		if not _stage.is_running() or not _alive:
			return
		await _tree.physics_frame


## if condition { body }
func _on_if(block: Dictionary) -> void:
	var condition: Variant = block.get("inputs", {}).get("condition")
	if _evaluate(condition):
		await _run_stack(_body(block))


## move_steps: step `steps` pixels along the current facing direction.
func _on_move_steps(block: Dictionary) -> void:
	var steps := float(_value(block, "steps"))
	_target.node.position += _direction_vector(_target.direction) * steps


## turn_degrees: rotate the facing direction clockwise by `degrees`.
func _on_turn_degrees(block: Dictionary) -> void:
	_target.direction = wrapf(_target.direction + float(_value(block, "degrees")), 0.0, 360.0)


## point_in_direction: set the facing direction.
##   * A number sets it absolutely (Scratch convention, 90 = right).
##   * The special value "bounce" reflects the current direction off whatever
##     the sprite is touching — viewport edges *and* other sprites (see
##     _bounce). It stays a runtime-computed sentinel because the block set has
##     no arithmetic to express a reflection as data yet.
func _on_point_in_direction(block: Dictionary) -> void:
	var arg: Variant = block.get("inputs", {}).get("direction")
	if typeof(arg) == TYPE_STRING and arg == "bounce":
		_target.direction = _bounce()
	else:
		_target.direction = wrapf(float(_evaluate(arg)), 0.0, 360.0)


## point_towards: face the sprite toward the world point (x, y) — Scratch's "point towards", the
## data-form complement to point_in_direction's fixed angle (which the block set otherwise can't
## compute, having no trig). The angle is derived the same way _bounce() converts a velocity vector
## back to a Scratch direction, so move_steps after it steps straight at the target. With (x, y) on
## the sprite (zero delta) atan2(0, 0) → 0 (faces up), a harmless default.
func _on_point_towards(block: Dictionary) -> void:
	var dx := float(_value(block, "x")) - _target.node.position.x
	var dy := float(_value(block, "y")) - _target.node.position.y
	_target.direction = wrapf(rad_to_deg(atan2(dx, -dy)), 0.0, 360.0)


## go_to: teleport the sprite to an absolute (x, y) position. Used to reset the
## ball to center and to clamp the paddles onto their rails.
func _on_go_to(block: Dictionary) -> void:
	var x := float(_value(block, "x"))
	var y := float(_value(block, "y"))
	_target.node.position = Vector2(x, y)


## set_color: recolour the sprite by regenerating its placeholder costume as a solid fill of `color`
## (a hex string like "#000000"), at the costume's current pixel size. Lets a script flash a sprite
## (e.g. the player's black↔white hit blink) — the looks-category complement to `say`, which instead
## paints a text costume. Nearest-neighbour filtering keeps the fill crisp if the sprite is scaled.
func _on_set_color(block: Dictionary) -> void:
	var sprite := _target.node as Sprite2D
	var size := sprite.texture.get_size()
	var image := Image.create(maxi(1, int(size.x)), maxi(1, int(size.y)), false, Image.FORMAT_RGBA8)
	image.fill(Color(String(_value(block, "color"))))
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.texture = ImageTexture.create_from_image(image)


## wait_seconds: suspend this script for `seconds`, yielding cooperatively the
## same way `forever` does. Used for the serve delay after a point.
func _on_wait_seconds(block: Dictionary) -> void:
	var seconds := float(_value(block, "seconds"))
	await _tree.create_timer(seconds).timeout


# --- Reporter handlers -----------------------------------------------------

## touching_edge?(side): true when the sprite has reached a viewport edge.
## `side` ∈ {"top","bottom","left","right","any"}, default "any" (M1 behavior).
## The ball needs to bounce off top/bottom but pass *through* left/right (the
## miss zones), which a single "any edge" test can't express.
func _on_touching_edge(block: Dictionary) -> bool:
	var side := String(block.get("inputs", {}).get("side", "any"))
	var bounds := _inner_bounds()  # area the sprite's center may occupy
	var pos := _target.node.position
	match side:
		"top":
			return pos.y <= bounds.position.y
		"bottom":
			return pos.y >= bounds.end.y
		"left":
			return pos.x <= bounds.position.x
		"right":
			return pos.x >= bounds.end.x
		_:
			return pos.x <= bounds.position.x or pos.x >= bounds.end.x \
				or pos.y <= bounds.position.y or pos.y >= bounds.end.y


## touching_sprite?(name): true when this sprite's box overlaps the named
## sprite's box. The name is resolved through the Stage's target registry.
func _on_touching_sprite(block: Dictionary) -> bool:
	var other_name := String(_value(block, "name"))
	var other := _stage.find_target(other_name)
	if other == null:
		push_warning("Interpreter: touching_sprite? unknown sprite '%s'" % other_name)
		return false
	return _sprite_rect(_target).intersects(_sprite_rect(other))


## key_pressed?(key): poll whether a key (by name, e.g. "w" or "Up") is held.
## This is a reporter, not an event hat — it lives inside `forever { if … }`.
func _on_key_pressed(block: Dictionary) -> bool:
	var key_name := String(_value(block, "key"))
	var keycode := OS.find_keycode_from_string(key_name)
	if keycode == KEY_NONE:
		push_warning("Interpreter: key_pressed? unknown key '%s'" % key_name)
		return false
	return Input.is_physical_key_pressed(keycode)


# --- Variables, operators & control (Milestone 3) --------------------------

## set_var: store `value` (which may itself be a reporter) into variable `name`.
func _on_set_var(block: Dictionary) -> void:
	_set_variable(String(_value(block, "name")), _value(block, "value"))


## change_var: add `by` to the current value of variable `name`.
func _on_change_var(block: Dictionary) -> void:
	var name := String(_value(block, "name"))
	_set_variable(name, float(_get_variable(name)) + float(_value(block, "by")))


## animate: smoothly interpolate variable `name` from its current value to `value` over `seconds`,
## one step per physics tick, using the chosen easing curve. Like `wait_seconds` (and Scratch's glide)
## it **blocks the calling script for the duration** — the blocks after it run only once the animation
## finishes — and it yields on the fixed physics tick the same way `forever` does, so the script never
## freezes the engine and the value advances at a constant real rate. The target is snapshotted once at
## the start (evaluated in the current frame); the start value is the variable's value at that moment.
## A non-positive duration sets the variable straight to the target. Easing (M41): "linear" (constant
## rate), "ease in" (slow start), "ease out" (slow end) — see `_ease_fraction`.
##
## The eased value rides through `_set_variable`, so it lands wherever the name resolves (local-first,
## then global) — exactly where a `set` block would write it — and any script reading the variable
## (e.g. `go to x: (var)`) sees it change each frame. We poll the Stage / `_alive` flags so a
## `stop "all"` or `stop "this script"` mid-animation unwinds this coroutine within a frame, leaving the
## variable partway (we only snap it exactly onto the target when we run to completion).
func _on_animate(block: Dictionary) -> void:
	var name := String(_value(block, "name"))
	var target := float(_value(block, "value"))
	var duration := float(_value(block, "seconds"))
	var easing := String(block.get("inputs", {}).get("easing", "linear"))
	var start := float(_get_variable(name))
	if duration <= 0.0:
		_set_variable(name, target)
		return
	var step := 1.0 / float(Engine.physics_ticks_per_second)
	var elapsed := 0.0
	while elapsed < duration and _stage.is_running() and _alive:
		await _tree.physics_frame
		elapsed += step
		var t := clampf(elapsed / duration, 0.0, 1.0)
		_set_variable(name, lerpf(start, target, _ease_fraction(easing, t)))
	# Snap exactly onto the target only when we ran to completion (a stop mid-animation leaves it partway).
	if _stage.is_running() and _alive:
		_set_variable(name, target)


## Map a normalized time `t` ∈ [0, 1] to an eased fraction ∈ [0, 1] (M41). Both eased modes are the
## standard quadratic curves: "ease in" accelerates from rest (t²), "ease out" decelerates to a stop
## (1 − (1 − t)²); anything else (incl. "linear") is the identity, a constant rate.
func _ease_fraction(mode: String, t: float) -> float:
	match mode:
		"ease in":
			return t * t
		"ease out":
			return 1.0 - (1.0 - t) * (1.0 - t)
		_:
			return t


## stop: end execution.
##   * "all" flips the Stage's running flag, which every forever / run-stack
##     polls, so every script unwinds within a frame (the game-over freeze).
##   * "this script" clears just this interpreter's `_alive` flag, so only this
##     coroutine unwinds — other sprites keep running.
func _on_stop(block: Dictionary) -> void:
	var mode := String(block.get("inputs", {}).get("mode", "all"))
	match mode:
		"all":
			_stage.stop_all()
		"this script":
			_alive = false
		_:
			push_warning("Interpreter: unsupported stop mode '%s'" % mode)


## say: replace this sprite's costume with `text` rendered through the Stage's
## bitmap font (M6). The input is stringified first, so a number reporter shows as
## a numeric readout. The optional `size` input picks the font face: "small" (the
## 3x5 default, meant to be scaled up) or "large" (5x9, sized to read at the
## viewport's own resolution with no scaling). We force nearest-neighbor filtering
## so glyphs stay crisp if the sprite *is* scaled. Unlike Scratch's speech bubble,
## the text *is* the costume — exactly the "text-rendering costume" path the docs noted.
func _on_say(block: Dictionary) -> void:
	var text := _stringify(_value(block, "text"))
	var size := String(block.get("inputs", {}).get("size", "small"))
	var sprite := _target.node as Sprite2D
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.texture = _stage.font().render(text, Color.WHITE, size)


## variable: read a variable's value (local-first, then global).
func _on_variable(block: Dictionary) -> Variant:
	return _get_variable(String(_value(block, "name")))


# Motion-state reporters (M35). They read the live Target so a script can compute a
# reflection (the data form of `point_in_direction "bounce"`): direction is the facing in
# Scratch degrees (90 = right, 0 = up), x/y_position the sprite's centre (Sprite2D is centred).
func _on_direction(_block: Dictionary) -> float:
	return _target.direction


func _on_x_position(_block: Dictionary) -> float:
	return _target.node.position.x


func _on_y_position(_block: Dictionary) -> float:
	return _target.node.position.y


# Mouse-position reporters. They return the cursor's location in *world* coordinates (the same space
# sprite x/y live in), via the Stage's get_global_mouse_position() — so it accounts for the runtime
# camera and the 480x352 content-scale automatically. Used to aim: `point towards (mouse x) (mouse y)`.
func _on_mouse_x(_block: Dictionary) -> float:
	return _stage.get_global_mouse_position().x


func _on_mouse_y(_block: Dictionary) -> float:
	return _stage.get_global_mouse_position().y


# Arithmetic. divide / mod guard division by zero (-> 0) so a bad script can't
# crash the runtime.
func _on_add(block: Dictionary) -> float:
	return float(_value(block, "a")) + float(_value(block, "b"))

func _on_subtract(block: Dictionary) -> float:
	return float(_value(block, "a")) - float(_value(block, "b"))

func _on_multiply(block: Dictionary) -> float:
	return float(_value(block, "a")) * float(_value(block, "b"))

func _on_divide(block: Dictionary) -> float:
	var b := float(_value(block, "b"))
	return 0.0 if b == 0.0 else float(_value(block, "a")) / b

func _on_mod(block: Dictionary) -> float:
	var b := float(_value(block, "b"))
	return 0.0 if b == 0.0 else fmod(float(_value(block, "a")), b)


# Comparison -> bool.
func _on_equals(block: Dictionary) -> bool:
	return is_equal_approx(float(_value(block, "a")), float(_value(block, "b")))

func _on_greater_than(block: Dictionary) -> bool:
	return float(_value(block, "a")) > float(_value(block, "b"))

func _on_less_than(block: Dictionary) -> bool:
	return float(_value(block, "a")) < float(_value(block, "b"))


# Boolean combinators -> bool.
func _on_and(block: Dictionary) -> bool:
	return bool(_value(block, "a")) and bool(_value(block, "b"))

func _on_or(block: Dictionary) -> bool:
	return bool(_value(block, "a")) or bool(_value(block, "b"))

func _on_not(block: Dictionary) -> bool:
	return not bool(_value(block, "a"))


## random: a uniform float in [from, to] — the varied serve angle. Godot's
## global RNG is auto-seeded, so serves differ from run to run.
func _on_random(block: Dictionary) -> float:
	return randf_range(float(_value(block, "from")), float(_value(block, "to")))


# --- Variable resolution ---------------------------------------------------

## Read variable `name`, checking this target's locals first, then the Stage's
## globals (Scratch's shadowing order). Unknown -> 0 with a warning.
func _get_variable(name: String) -> Variant:
	if _target.variables.has(name):
		return _target.variables[name]
	if _stage.has_var(name):
		return _stage.get_var(name)
	push_warning("Interpreter: read of undefined variable '%s'" % name)
	return 0


## Write variable `name`, resolved the same way: an existing local wins, else an
## existing global, else we create it in the global store (and warn — every
## variable the scripts touch is meant to be seeded up front).
func _set_variable(name: String, value: Variant) -> void:
	if _target.variables.has(name):
		_target.variables[name] = value
	elif _stage.has_var(name):
		_stage.set_var(name, value)
	else:
		push_warning("Interpreter: assignment to undeclared variable '%s' (creating global)" % name)
		_stage.set_var(name, value)


# --- Cloning (Milestone 4) -------------------------------------------------

## when_i_start_as_a_clone: as a nested statement it just runs its body; the real
## entry point for clones is run_as_clone() above.
func _on_when_i_start_as_a_clone(block: Dictionary) -> void:
	await _run_stack(_body(block))


## create_clone: spawn a runtime copy of this sprite (only "myself" is supported)
## that inherits its costume, direction, and *local* variables, then runs its own
## when_i_start_as_a_clone hats. The Stage owns node + interpreter creation; we
## just hand it this target and the script the clone should run.
func _on_create_clone(block: Dictionary) -> void:
	var which := String(block.get("inputs", {}).get("target", "myself"))
	if which != "myself":
		push_warning("Interpreter: create_clone only supports 'myself' (got '%s')" % which)
		return
	_stage.create_clone_of(_target, _script)


## delete_this_clone: remove the running clone — clear `_alive` so this coroutine
## unwinds within a frame, and hand the Stage the node to free and the interpreter
## to release. A no-op on an original (matching Scratch): only clones can delete
## themselves, and `create_clone` only ever makes "myself" clones.
func _on_delete_this_clone(_block: Dictionary) -> void:
	if not _target.is_clone:
		push_warning("Interpreter: delete_this_clone called on a non-clone; ignoring")
		return
	_alive = false
	_stage.remove_clone(self, _target)


# --- Custom blocks ("My Blocks", Milestone 30) -----------------------------

## define: the hat of a custom block (a procedure). As a nested statement it just runs its body
## — but a define is never started by run()/run_as_clone() (those launch only the green-flag /
## clone hats), so a define's body executes only when a `call` invokes it. The `name` input is the
## procedure's name, which `call` resolves against.
func _on_define(block: Dictionary) -> void:
	await _run_stack(_body(block))


## call: invoke the custom block named by this block's `name` input. We look the procedure up in
## this target's own script (_script, retained by run()/run_as_clone()) — custom blocks are
## per-sprite, like locals — and `await` its body, so the blocks after the call run only once the
## procedure returns (Scratch's sequential semantics). An unknown name warns and is a no-op.
##
## Parameters (M31): the matching `define` declares an ordered `params` list; this block carries an
## `args` dict keyed by parameter name. We evaluate each argument **in the current frame** (before
## pushing — so a `param` used as an argument refers to the caller's binding, Scratch's semantics),
## push the resulting `{param: value}` frame, run the body, then pop it. The body's `param` reporters
## read the top frame. A missing arg evaluates to 0; extra args not in `params` are ignored.
##
## The body runs in the same coroutine, so a recursive call without an intervening `wait`/`forever`
## would loop synchronously (as it would in Scratch); a call whose body never returns — e.g. one
## containing `forever` — never yields back to the caller (and never pops its frame), by design.
func _on_call(block: Dictionary) -> void:
	var proc_name := String(_value(block, "name"))
	for b in _script:
		if typeof(b) == TYPE_DICTIONARY and _opcode(b) == "define" \
				and String(b.get("inputs", {}).get("name", "")) == proc_name:
			var params: Array = b.get("inputs", {}).get("params", [])
			var args: Dictionary = block.get("inputs", {}).get("args", {})
			var frame := {}
			for p in params:
				frame[String(p)] = _evaluate(args.get(p, 0))  # evaluated in the *caller's* frame
			_frames.push_back(frame)
			await _run_stack(_body(b))
			if not _frames.is_empty():
				_frames.pop_back()
			return
	push_warning("Interpreter: call to undefined custom block '%s'" % proc_name)


## param: read the value bound to a custom-block parameter (M31). Resolves against the top frame —
## the one `_on_call` pushed for the procedure currently running — by the parameter's `name` (a fixed
## label, read directly, not evaluated). Read outside any custom block, or for an unknown parameter,
## yields 0 with a warning (so a stray `param` reporter can't crash a script).
func _on_param(block: Dictionary) -> Variant:
	var pname := String(block.get("inputs", {}).get("name", ""))
	if not _frames.is_empty():
		var frame: Dictionary = _frames.back()
		if frame.has(pname):
			return frame[pname]
	push_warning("Interpreter: read of parameter '%s' outside its custom block" % pname)
	return 0


# --- Camera (Milestone 37) -------------------------------------------------

## set_camera: scroll the view so its centre shows world point (x, y) — the same coordinate space
## sprites live in. The Stage owns the Camera2D; it also clears any active follow so a manual move
## takes control (camera_follow / camera_stop_following manage tracking).
func _on_set_camera(block: Dictionary) -> void:
	_stage.set_camera(float(_value(block, "x")), float(_value(block, "y")))


## change_camera: scroll the view by (dx, dy) relative to where it is now. Like set_camera it stops
## following first (a relative move is manual control).
func _on_change_camera(block: Dictionary) -> void:
	_stage.move_camera(float(_value(block, "dx")), float(_value(block, "dy")))


## camera_follow: track the named sprite — the Stage keeps the view centred on it each frame. An
## unknown name warns + no-ops there (the block's dropdown lists real sprites, so only a stale
## hand-edited name hits this).
func _on_camera_follow(block: Dictionary) -> void:
	_stage.camera_follow(String(_value(block, "name")))


## camera_stop_following: release tracking; the camera holds wherever it currently is.
func _on_camera_stop_following(_block: Dictionary) -> void:
	_stage.camera_stop_following()


# --- Helpers ---------------------------------------------------------------

## Stringify a `say` value the way Scratch does: a whole-number float reads as a
## bare integer, not "3.0". Our arithmetic blocks (and change_var) always produce
## floats, so a score of 3 arrives here as 3.0 — and since the font atlas has no
## "." glyph, str()'s "3.0" would paint as "3" + gap + "0". Dropping the trailing
## ".0" keeps the readout a single clean digit.
func _stringify(value: Variant) -> String:
	if typeof(value) == TYPE_FLOAT and value == floor(value) and is_finite(value):
		return str(int(value))
	return str(value)


func _opcode(block: Dictionary) -> String:
	return block.get("opcode", "")


func _body(block: Dictionary) -> Array:
	return block.get("inputs", {}).get("body", [])


## Read inputs[name] and evaluate it (handles both literals and reporters).
func _value(block: Dictionary, name: String) -> Variant:
	return _evaluate(block.get("inputs", {}).get(name))


## Convert a Scratch-convention direction (degrees) into a unit screen vector.
## 90 -> (1, 0) right, 0 -> (0, -1) up, 180 -> (0, 1) down.
func _direction_vector(degrees: float) -> Vector2:
	var rad := deg_to_rad(degrees)
	return Vector2(sin(rad), -cos(rad))


## The rectangle the sprite's *center* may sit in so the sprite stays fully on
## screen: the viewport shrunk by the sprite's half-size on every side.
func _inner_bounds() -> Rect2:
	var sprite := _target.node as Sprite2D
	var view := sprite.get_viewport_rect()
	var half := _sprite_size(sprite) * 0.5
	return Rect2(half, view.size - half * 2.0)


## A sprite's drawn size in world units (texture size scaled).
func _sprite_size(sprite: Sprite2D) -> Vector2:
	return sprite.texture.get_size() * sprite.scale


## A target's world-space axis-aligned box. Sprite2D is centered by default, so
## the box is centered on the node's position.
func _sprite_rect(target: Target) -> Rect2:
	var sprite := target.node as Sprite2D
	var size := _sprite_size(sprite)
	return Rect2(sprite.position - size * 0.5, size)


## Reflect the current direction off whatever the sprite is currently touching —
## the viewport's top/bottom/left/right edges and any overlapping sprite — and
## nudge the sprite clear so it doesn't re-trigger next frame. Returns the new
## direction in degrees.
##
## Rather than blindly negating a velocity component (which can make a sprite
## "stick" if it's flipped twice in a frame), we *steer away* from each surface:
## the component is forced to the sign that points back into open space. This is
## what makes calling bounce from several `if` branches in one frame safe.
func _bounce() -> float:
	var sprite := _target.node as Sprite2D
	var bounds := _inner_bounds()
	var pos := sprite.position
	var velocity := _direction_vector(_target.direction)

	# Walls: steer away from whichever edge we're on, then clamp inside.
	if pos.y <= bounds.position.y:
		velocity.y = absf(velocity.y)
	elif pos.y >= bounds.end.y:
		velocity.y = -absf(velocity.y)
	if pos.x <= bounds.position.x:
		velocity.x = absf(velocity.x)
	elif pos.x >= bounds.end.x:
		velocity.x = -absf(velocity.x)
	pos.x = clampf(pos.x, bounds.position.x, bounds.end.x)
	pos.y = clampf(pos.y, bounds.position.y, bounds.end.y)

	# Sprites: reflect off the shallowest-overlap axis and push out along it.
	# (A tall paddle is hit on its side, so x is the shallow axis -> flip x.)
	var size := _sprite_size(sprite)
	var my_rect := Rect2(pos - size * 0.5, size)
	for other_name in _stage.target_names():
		var other: Target = _stage.find_target(other_name)
		if other == _target:
			continue
		var other_rect := _sprite_rect(other)
		if not my_rect.intersects(other_rect):
			continue
		var overlap := my_rect.intersection(other_rect)
		if overlap.size.x <= overlap.size.y:
			if my_rect.get_center().x < other_rect.get_center().x:
				velocity.x = -absf(velocity.x)
				pos.x -= overlap.size.x
			else:
				velocity.x = absf(velocity.x)
				pos.x += overlap.size.x
		else:
			if my_rect.get_center().y < other_rect.get_center().y:
				velocity.y = -absf(velocity.y)
				pos.y -= overlap.size.y
			else:
				velocity.y = absf(velocity.y)
				pos.y += overlap.size.y
		my_rect = Rect2(pos - size * 0.5, size)

	sprite.position = pos
	# Inverse of _direction_vector(): vector -> Scratch direction.
	return rad_to_deg(atan2(velocity.x, -velocity.y))
