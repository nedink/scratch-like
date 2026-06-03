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
## Execution model — GDScript coroutines:
##   * Running a stack of blocks is an `await`-ing method, i.e. a coroutine.
##   * Long-running control blocks (`forever`) `await get_tree().process_frame`
##     once per iteration, so the script cooperatively yields back to the engine
##     every frame instead of blocking it in an infinite loop.
##   * We start a script with a plain (non-awaited) call. The coroutine then
##     keeps itself alive by awaiting the SceneTree's per-frame signal.
##
## Dispatch:
##   * Opcode -> handler `Callable`, looked up in a table. Adding a new block
##     type later is just registering one more entry plus its handler method.

## The Stage this interpreter runs under. Two reasons we hold it instead of a
## bare SceneTree (as M1 did):
##   * coroutines still need `await _tree.process_frame` — we get the tree from
##     the Stage, which is a Node;
##   * cross-sprite blocks (`touching_sprite?`) resolve other entities through
##     `_stage.find_target(name)`.
var _stage: Stage

## SceneTree, cached from the Stage so coroutines can `await _tree.process_frame`
## (a RefCounted has no get_tree() of its own).
var _tree: SceneTree

## The sprite this interpreter drives.
var _target: Target

## This target's full script (all hats), retained so a clone can locate and
## launch the `when_i_start_as_a_clone` hats. Set by run() / run_as_clone().
var _script: Array = []

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
		"go_to": _on_go_to,
		"wait_seconds": _on_wait_seconds,
		"set_var": _on_set_var,
		"change_var": _on_change_var,
		"stop": _on_stop,
		"create_clone": _on_create_clone,
		"when_i_start_as_a_clone": _on_when_i_start_as_a_clone,
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
		# Bail mid-stack the moment `stop "all"` fires, so no further blocks run.
		if not _stage.is_running():
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


## forever { body }  — run the body, yield one frame, repeat forever.
## The per-iteration `await` is what keeps this from freezing the engine.
func _on_forever(block: Dictionary) -> void:
	var body := _body(block)
	while _stage.is_running():
		await _run_stack(body)
		if not _stage.is_running():
			return
		await _tree.process_frame


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


## go_to: teleport the sprite to an absolute (x, y) position. Used to reset the
## ball to center and to clamp the paddles onto their rails.
func _on_go_to(block: Dictionary) -> void:
	var x := float(_value(block, "x"))
	var y := float(_value(block, "y"))
	_target.node.position = Vector2(x, y)


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


## stop: end execution. Only "all" is supported — it flips the Stage's running
## flag, which every forever / run-stack polls, so all scripts unwind within a
## frame. (Stopping just *this* script would need per-coroutine unwinding and is
## deferred; "all" is all the game-over freeze needs.)
func _on_stop(block: Dictionary) -> void:
	var mode := String(block.get("inputs", {}).get("mode", "all"))
	if mode == "all":
		_stage.stop_all()
	else:
		push_warning("Interpreter: unsupported stop mode '%s'" % mode)


## variable: read a variable's value (local-first, then global).
func _on_variable(block: Dictionary) -> Variant:
	return _get_variable(String(_value(block, "name")))


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


# --- Helpers ---------------------------------------------------------------

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
