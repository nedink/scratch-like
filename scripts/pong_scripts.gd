class_name PongScripts
extends RefCounted

## The three Milestone 2 block scripts — two paddles and a ball — expressed
## purely as data, exactly the shape a visual editor would emit. Each is an
## Array of block dictionaries with substacks nested under "inputs".
##
## Together they prove the M2 block set is sufficient to build rally Pong with
## **no operators or variables**: serve angles and clamp targets are literals,
## and "who won the rally" is implicit in which side the ball passed.
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
			_point(60),  # serve up-and-to-the-right
			_forever([
				_move(BALL_SPEED),
				_if(_edge("top"), [_point("bounce")]),
				_if(_edge("bottom"), [_point("bounce")]),
				_if(_touching("LeftPaddle"), [_point("bounce")]),
				_if(_touching("RightPaddle"), [_point("bounce")]),
				_if(_edge("left"), [  # ball passed left -> serve back to the right
					_go_to(CENTER.x, CENTER.y),
					_point(60),
					_wait(SERVE_DELAY),
				]),
				_if(_edge("right"), [  # ball passed right -> serve back to the left
					_go_to(CENTER.x, CENTER.y),
					_point(240),
					_wait(SERVE_DELAY),
				]),
			]),
		]),
	]


# --- Tiny block builders (just to keep the data above readable) ------------

static func _hat(body: Array) -> Dictionary:
	return {"opcode": "when_flag_clicked", "inputs": {"body": body}}


static func _forever(body: Array) -> Dictionary:
	return {"opcode": "forever", "inputs": {"body": body}}


static func _if(condition: Dictionary, body: Array) -> Dictionary:
	return {"opcode": "if", "inputs": {"condition": condition, "body": body}}


static func _move(steps: float) -> Dictionary:
	return {"opcode": "move_steps", "inputs": {"steps": steps}}


static func _point(direction: Variant) -> Dictionary:
	return {"opcode": "point_in_direction", "inputs": {"direction": direction}}


static func _go_to(x: float, y: float) -> Dictionary:
	return {"opcode": "go_to", "inputs": {"x": x, "y": y}}


static func _wait(seconds: float) -> Dictionary:
	return {"opcode": "wait_seconds", "inputs": {"seconds": seconds}}


static func _edge(side: String) -> Dictionary:
	return {"opcode": "touching_edge?", "inputs": {"side": side}}


static func _touching(sprite_name: String) -> Dictionary:
	return {"opcode": "touching_sprite?", "inputs": {"name": sprite_name}}


static func _key_pressed(key: String) -> Dictionary:
	return {"opcode": "key_pressed?", "inputs": {"key": key}}
