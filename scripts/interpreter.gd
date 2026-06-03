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

## SceneTree, kept so coroutines can `await _tree.process_frame`.
## (A RefCounted has no get_tree() of its own, so we are handed one.)
var _tree: SceneTree

## The sprite this interpreter drives.
var _target: Target

## opcode (String) -> Callable for blocks that *do* something (statements).
var _statement_handlers: Dictionary = {}

## opcode (String) -> Callable for blocks that *return a value* (reporters /
## boolean conditions), e.g. "touching_edge?".
var _reporter_handlers: Dictionary = {}


func _init(tree: SceneTree, target: Target) -> void:
	_tree = tree
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
	}
	_reporter_handlers = {
		"touching_edge?": _on_touching_edge,
	}


# --- Entry point -----------------------------------------------------------

## Start every hat block in `script`. This is the equivalent of clicking the
## green flag. We launch each hat's body as a fire-and-forget coroutine so the
## caller (and the engine) is never blocked.
func run(script: Array) -> void:
	for block in script:
		if _opcode(block) == "when_flag_clicked":
			# No `await`: this returns as soon as the body first yields a frame.
			_run_stack(_body(block))


# --- Core walker -----------------------------------------------------------

## Run a list of blocks in order. This is a coroutine: any block that awaits
## (e.g. forever) suspends the whole stack until it resumes.
func _run_stack(blocks: Array) -> void:
	for block in blocks:
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
	while true:
		await _run_stack(body)
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
##   * The special value "bounce" reflects the current direction off whichever
##     viewport edge(s) the sprite is touching — this is the milestone's
##     "if on edge, bounce" behaviour, computed in code because the block set
##     has no arithmetic to express a reflection as data yet.
func _on_point_in_direction(block: Dictionary) -> void:
	var arg: Variant = block.get("inputs", {}).get("direction")
	if typeof(arg) == TYPE_STRING and arg == "bounce":
		_target.direction = _bounce_off_edges()
	else:
		_target.direction = wrapf(float(_evaluate(arg)), 0.0, 360.0)


# --- Reporter handlers -----------------------------------------------------

## touching_edge?: true when the sprite has reached any viewport edge.
func _on_touching_edge(_block: Dictionary) -> bool:
	var bounds := _inner_bounds()  # area the sprite's center may occupy
	var pos := _target.node.position
	return pos.x <= bounds.position.x or pos.x >= bounds.end.x \
		or pos.y <= bounds.position.y or pos.y >= bounds.end.y


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
	var half := sprite.texture.get_size() * sprite.scale * 0.5
	return Rect2(half, view.size - half * 2.0)


## Reflect the current direction off whatever edge(s) the sprite is on, and nudge
## the sprite back inside the bounds so it doesn't re-trigger next frame. Handles
## corners naturally (both axes flip). Returns the new direction in degrees.
func _bounce_off_edges() -> float:
	var sprite := _target.node as Sprite2D
	var bounds := _inner_bounds()
	var velocity := _direction_vector(_target.direction)

	if sprite.position.x <= bounds.position.x or sprite.position.x >= bounds.end.x:
		velocity.x = -velocity.x
	if sprite.position.y <= bounds.position.y or sprite.position.y >= bounds.end.y:
		velocity.y = -velocity.y

	# Clamp back inside the playable area.
	sprite.position.x = clampf(sprite.position.x, bounds.position.x, bounds.end.x)
	sprite.position.y = clampf(sprite.position.y, bounds.position.y, bounds.end.y)

	# Inverse of _direction_vector(): vector -> Scratch direction.
	return rad_to_deg(atan2(velocity.x, -velocity.y))
