class_name PongScripts
extends RefCounted

## The Milestone 3 Pong scripts — two paddles and a ball — expressed purely as
## data, exactly the shape a visual editor would emit. Each is an Array of block
## dictionaries with substacks nested under "inputs".
##
## M3 layers *data & expressions* onto the M2 motion blocks: the ball now tracks
## the score in **variables** (`change p2_score by 1`), serves at a randomized
## angle built from a **nested reporter expression** (`add 90, random(-45, 45)`),
## reads its own speed from a **per-sprite local** variable, and ends the match
## with `stop "all"` once a player reaches WIN_SCORE. (There is still no on-screen
## score — that visible scoreboard is M4's clone work; here the win shows as the
## whole game freezing.)
##
## Layout assumptions (matched in stage.gd, 800x600 window):
##   * paddles are 16x96, so their center y is clamped to [48, 552];
##   * left paddle rides x = 40, right paddle rides x = 760;
##   * the ball is 16x16 and serves from the center (400, 300).

const PADDLE_SPEED := 8.0
const BALL_SPEED := 6.0
const PADDLE_TOP_Y := 48.0
const PADDLE_BOTTOM_Y := 552.0
const CENTER := Vector2(400, 300)
const SERVE_DELAY := 1.0
## First player to this many points wins, which fires `stop "all"`.
const WIN_SCORE := 11
## Serve angle = straight across (90 = right, 270 = left) ± a random spread.
const SERVE_SPREAD := 45.0
## Scoreboard pips: clones laid out left-to-right, wrapping every PIP_COLS.
const PIP_COLS := 5
const PIP_GAP := 14.0


## A keyboard-driven paddle: move on its vertical rail while a key is held, and
## clamp back onto the playfield at the top and bottom. `rail_x` is the fixed x,
## so the clamp targets are literals.
static func _paddle(up_key: String, down_key: String, rail_x: float) -> Array:
	return [
		_hat([
			_forever([
				_if(_key_pressed(up_key), [
					_point(0),  # up
					_move(PADDLE_SPEED),
				]),
				_if(_key_pressed(down_key), [
					_point(180),  # down
					_move(PADDLE_SPEED),
				]),
				_if(_edge("top"), [_go_to(rail_x, PADDLE_TOP_Y)]),
				_if(_edge("bottom"), [_go_to(rail_x, PADDLE_BOTTOM_Y)]),
			]),
		]),
	]


static func left_paddle() -> Array:
	# Key names are Godot's canonical keycode-name strings (see
	# OS.find_keycode_from_string), so "W"/"S"/"Up"/"Down", not "w"/"s".
	return _paddle("W", "S", 40.0)


static func right_paddle() -> Array:
	return _paddle("Up", "Down", 760.0)


## The ball: serve from center, then forever move and reflect off the top/bottom
## walls and either paddle. Passing the left or right edge is a missed rally, so
## the ball re-serves from center toward the player who just scored.
static func ball() -> Array:
	return [
		_hat([
			_go_to(CENTER.x, CENTER.y),
			_point(_serve_right()),
			_forever([
				_move(_var("speed")),  # speed is a per-sprite local (seeded in stage.gd)
				_if(_edge("top"), [_point("bounce")]),
				_if(_edge("bottom"), [_point("bounce")]),
				_if(_touching("LeftPaddle"), [_point("bounce")]),
				_if(_touching("RightPaddle"), [_point("bounce")]),
				_if(_edge("left"), [  # passed left -> Player 2 scores, re-serve right
					_change("p2_score", 1),
					_go_to(CENTER.x, CENTER.y),
					_point(_serve_right()),
					_wait(SERVE_DELAY),
				]),
				_if(_edge("right"), [  # passed right -> Player 1 scores, re-serve left
					_change("p1_score", 1),
					_go_to(CENTER.x, CENTER.y),
					_point(_serve_left()),
					_wait(SERVE_DELAY),
				]),
				# First to WIN_SCORE wins -> stop all scripts (the game-over freeze).
				_if(_gt(_var("p1_score"), WIN_SCORE - 1), [_stop("all")]),
				_if(_gt(_var("p2_score"), WIN_SCORE - 1), [_stop("all")]),
			]),
		]),
	]


## Serve directions as *expressions*, not literals: straight across, ± a random
## spread. This is the M3 headline — a reporter (random) nested inside another
## reporter (add) feeding a block input, evaluated fresh on every serve.
static func _serve_right() -> Dictionary:
	return _add(90.0, _random(-SERVE_SPREAD, SERVE_SPREAD))


static func _serve_left() -> Dictionary:
	return _add(270.0, _random(-SERVE_SPREAD, SERVE_SPREAD))


## A clone-built score readout. The original parks off-screen (seeded there in
## stage.gd) and, whenever its player's score outruns the count of pips it has
## made, bumps the count, stashes it in the local `index`, and clones itself.
## Each clone inherits that `index` and places itself in a grid:
##   col = (index - 1) mod PIP_COLS,  row = (index - 1 - col) / PIP_COLS
## This is the M4 payoff: the grid math exercises the full M3 operator palette.
static func _pips(score_name: String, origin_x: float, origin_y: float) -> Array:
	return [
		_clone_hat([
			_set_var("col", _mod(_sub(_var("index"), 1), PIP_COLS)),
			_set_var("row", _div(_sub(_sub(_var("index"), 1), _var("col")), PIP_COLS)),
			_go_to(
				_add(origin_x, _mul(_var("col"), PIP_GAP)),
				_add(origin_y, _mul(_var("row"), PIP_GAP)),
			),
		]),
		_hat([
			_set_var("count", 0),
			_forever([
				# When the score has outrun our pip count, add one more pip.
				_if(_gt(_var(score_name), _var("count")), [
					_change("count", 1),
					_set_var("index", _var("count")),
					_clone(),
				]),
			]),
		]),
	]


static func p1_pips() -> Array:
	return _pips("p1_score", 20.0, 20.0)


static func p2_pips() -> Array:
	return _pips("p2_score", 430.0, 20.0)


# --- Tiny block builders (just to keep the data above readable) ------------

static func _hat(body: Array) -> Dictionary:
	return {"opcode": "when_flag_clicked", "inputs": {"body": body}}


static func _forever(body: Array) -> Dictionary:
	return {"opcode": "forever", "inputs": {"body": body}}


static func _if(condition: Dictionary, body: Array) -> Dictionary:
	return {"opcode": "if", "inputs": {"condition": condition, "body": body}}


static func _move(steps: Variant) -> Dictionary:
	return {"opcode": "move_steps", "inputs": {"steps": steps}}


static func _point(direction: Variant) -> Dictionary:
	return {"opcode": "point_in_direction", "inputs": {"direction": direction}}


static func _go_to(x: Variant, y: Variant) -> Dictionary:
	return {"opcode": "go_to", "inputs": {"x": x, "y": y}}


static func _wait(seconds: float) -> Dictionary:
	return {"opcode": "wait_seconds", "inputs": {"seconds": seconds}}


static func _edge(side: String) -> Dictionary:
	return {"opcode": "touching_edge?", "inputs": {"side": side}}


static func _touching(sprite_name: String) -> Dictionary:
	return {"opcode": "touching_sprite?", "inputs": {"name": sprite_name}}


static func _key_pressed(key: String) -> Dictionary:
	return {"opcode": "key_pressed?", "inputs": {"key": key}}


# Variables, operators & control (Milestone 3).

static func _set_var(var_name: String, value: Variant) -> Dictionary:
	return {"opcode": "set_var", "inputs": {"name": var_name, "value": value}}


static func _change(var_name: String, by: Variant) -> Dictionary:
	return {"opcode": "change_var", "inputs": {"name": var_name, "by": by}}


static func _var(var_name: String) -> Dictionary:
	return {"opcode": "variable", "inputs": {"name": var_name}}


static func _add(a: Variant, b: Variant) -> Dictionary:
	return {"opcode": "add", "inputs": {"a": a, "b": b}}


static func _gt(a: Variant, b: Variant) -> Dictionary:
	return {"opcode": "greater_than", "inputs": {"a": a, "b": b}}


static func _random(from: float, to: float) -> Dictionary:
	return {"opcode": "random", "inputs": {"from": from, "to": to}}


static func _stop(mode: String) -> Dictionary:
	return {"opcode": "stop", "inputs": {"mode": mode}}


# Cloning (Milestone 4).

static func _clone_hat(body: Array) -> Dictionary:
	return {"opcode": "when_i_start_as_a_clone", "inputs": {"body": body}}


static func _clone() -> Dictionary:
	return {"opcode": "create_clone", "inputs": {"target": "myself"}}


static func _sub(a: Variant, b: Variant) -> Dictionary:
	return {"opcode": "subtract", "inputs": {"a": a, "b": b}}


static func _mul(a: Variant, b: Variant) -> Dictionary:
	return {"opcode": "multiply", "inputs": {"a": a, "b": b}}


static func _div(a: Variant, b: Variant) -> Dictionary:
	return {"opcode": "divide", "inputs": {"a": a, "b": b}}


static func _mod(a: Variant, b: Variant) -> Dictionary:
	return {"opcode": "mod", "inputs": {"a": a, "b": b}}
