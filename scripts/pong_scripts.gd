class_name PongScripts
extends RefCounted

## The Pong scripts — two paddles, a ball, two numeric score readouts, and an
## announcer — expressed purely as data, exactly the shape a visual editor would
## emit. Each is an Array of block dictionaries with substacks nested under "inputs".
##
## M3 layered *data & expressions* onto the M2 motion blocks: the ball tracks the
## score in **variables** (`change p2_score by 1`) and serves at a randomized angle
## built from a **nested reporter expression** (`add 90, random(-45, 45)`). M5 makes
## the match **best-of-N**: reaching ROUND_POINTS takes a round and bumps the global
## `round`; taking ROUNDS_TO_WIN rounds lets the Announcer paint the winner banner
## and fire `stop "all"`. M7 replaces M4/M5's clone-built pip grids with a live
## numeric HUD — each player's score `say`n through the bitmap font every tick.
##
## Layout assumptions (matched in stage.gd, 480x360 window):
##   * paddles are 16x96, so their center y is clamped to [48, 312];
##   * left paddle rides x = 24, right paddle rides x = 456;
##   * the ball is 16x16 and serves from the center (240, 180).

const PADDLE_SPEED := 8.0
const BALL_SPEED := 6.0
const PADDLE_TOP_Y := 48.0
const PADDLE_BOTTOM_Y := 312.0
const CENTER := Vector2(240, 180)
const SERVE_DELAY := 1.0
## Best-of-N (Milestone 5): take a round by reaching this many points, and win the
## match — firing `stop "all"` — by taking this many rounds. Each continuing round
## bumps the global `round` and re-serves from center.
const ROUND_POINTS := 5
const ROUNDS_TO_WIN := 2
## Serve angle = straight across (90 = right, 270 = left) ± a random spread.
const SERVE_SPREAD := 45.0


## The project's variable model (Milestone 18): the single declaration of every variable's
## name, initial value, and scope — the one source both the runtime and the editor read.
##
## It replaces a duplication that had quietly drifted: through M17 the editor hardcoded a flat
## *name list* (editor._PROJECT_VARIABLES) while stage._ready hardcoded the *seeds*, and the two
## disagreed in shape — `round` started at 1 in the Stage but the editor's list carried no value,
## and `speed` was a flat name in the editor but a Ball-*local* in the Stage. One declaration ends
## that: Stage._ready seeds from it (a "global" entry on the Stage, a sprite-named scope on that
## target's locals), and the editor derives its `{name}` dropdown options from the names here.
##
## `scope` is "global" or a sprite name (a per-sprite local). Carrying scope in the data is what a
## later "make a variable" / local-vs-global scoping milestone builds on (see CLAUDE.md). Every
## declared variable seeds to **0**: a non-zero starting value is set by a `set` block in the owning
## script (the Ball's `set speed to BALL_SPEED`), as in Scratch — so it lives in the editable program,
## not a hidden seed. The editor can now add / rename / delete entries from the UI (M20/M21); add a
## stock one here.
static func variables() -> Array:
	return [
		{"name": "p1_score", "value": 0, "scope": "global"},
		{"name": "p2_score", "value": 0, "scope": "global"},
		{"name": "p1_rounds", "value": 0, "scope": "global"},
		{"name": "p2_rounds", "value": 0, "scope": "global"},
		{"name": "round", "value": 0, "scope": "global"},  # only `change`d, never read (vestigial)
		{"name": "speed", "value": 0, "scope": "Ball"},     # set to BALL_SPEED by a block in ball()
	]


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
	return _paddle("W", "S", 24.0)


static func right_paddle() -> Array:
	return _paddle("Up", "Down", 456.0)


## The ball: serve from center, then forever move and reflect off the top/bottom
## walls and either paddle. Passing the left or right edge is a missed rally, so
## the ball re-serves from center toward the player who just scored.
static func ball() -> Array:
	return [
		_hat([
			# Initialize the ball's speed with a block, not a non-zero seed (Scratch's model): the
			# variable declares to 0 (PongScripts.variables) and this sets it up front, so the starting
			# value lives in the editable program rather than a hidden seed — and is editable in the
			# canvas (click the `{6}` literal) instead of only via PongScripts.
			_set_var("speed", BALL_SPEED),
			_go_to(CENTER.x, CENTER.y),
			_point(_serve_right()),
			_forever([
				_move(_var("speed")),  # speed is a per-sprite local, set by the block above
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
				# Round end: first to ROUND_POINTS takes the round (see _on_round_won;
				# on the match-winning round it leaves the board alone and the Announcer
				# freezes the game with its banner).
				_if(_gt(_var("p1_score"), ROUND_POINTS - 1), _on_round_won("p1_rounds", _serve_right())),
				_if(_gt(_var("p2_score"), ROUND_POINTS - 1), _on_round_won("p2_rounds", _serve_left())),
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


## The blocks that run when a player takes a round (the body of the round-end `if`).
## Bank the round on `rounds_var`, then — *only if the match isn't over* — zero both
## per-round scores, bump the global `round`, and re-serve from center along `serve`.
##
## Zeroing the scores clears the `score > ROUND_POINTS-1` condition so a continuing
## round can't bank twice. On the match-*winning* round that whole branch is skipped:
## the scores are left standing (so the HUD freezes showing the winning ROUND_POINTS,
## not 0) and the ball keeps looping — re-firing this block harmlessly, since the
## Announcer, watching the same rounds totals, paints the banner and fires
## `stop "all"` within a frame. M6 moved the freeze there so the win shows on screen.
##
## (M5 zeroed the scores *unconditionally* and the freeze relied on the pip clones,
## which were decoupled from the live score, staying up. M7's HUD reads the live
## score every tick, so the zeroing had to move inside the continue-branch to keep
## the winning number on screen. `round` was M5's signal for the pips to clear; with
## the pips gone nothing reads it, but the ball still bumps it harmlessly — the
## `delete_this_clone` machinery ships unexercised, like `stop "this script"`.)
static func _on_round_won(rounds_var: String, serve: Dictionary) -> Array:
	return [
		_change(rounds_var, 1),
		_if(_lt(_var(rounds_var), ROUNDS_TO_WIN), [
			_set_var("p1_score", 0),
			_set_var("p2_score", 0),
			_change("round", 1),
			_go_to(CENTER.x, CENTER.y),
			_point(serve),
			_wait(SERVE_DELAY),
		]),
	]


## The match announcer (Milestone 6). It parks off-screen (seeded in stage.gd) and
## watches the global rounds-won totals the ball drives. The instant a player reaches
## ROUNDS_TO_WIN it jumps to center, `say`s their banner — which swaps in a font.png
## costume — and fires `stop "all"`. Because `say` sets the costume synchronously
## before the stop, the game-over freeze lands with the winner named on screen.
##
## This is why the ball no longer stops the game itself: the freeze has to happen
## *after* the text is painted, and it has to read the same rounds totals, so the
## one script that knows how to draw the result is the one that ends the match.
static func announcer() -> Array:
	return [
		_hat([
			_forever([
				_if(_gt(_var("p1_rounds"), ROUNDS_TO_WIN - 1), [
					_go_to(CENTER.x, CENTER.y),
					_say("P1 WINS", "large"),
					_stop("all"),
				]),
				_if(_gt(_var("p2_rounds"), ROUNDS_TO_WIN - 1), [
					_go_to(CENTER.x, CENTER.y),
					_say("P2 WINS", "large"),
					_stop("all"),
				]),
			]),
		]),
	]


## A live numeric score readout (Milestone 7). The HUD sprite parks where its
## player's pip grid used to sit (seeded in stage.gd) and `say`s its score every
## tick, in the "large" face so it reads at the viewport's own resolution. This is
## the M6 payoff the deferred-list named — a real numeric scoreboard *replacing*
## the M4/M5 pip clones — and it is deliberately tiny: `say` already stringifies a
## number reporter, so the readout is just `say (score)` in a forever loop, with no
## new opcode and no font additions (the digit glyphs were already in the atlas).
##
## Re-rendering each tick allocates a fresh costume 60x/sec; that is fine for a
## one-digit readout and matches Scratch's redraw model. Guarding it to re-`say`
## only when the score changes is left as polish.
static func _score_hud(score_name: String) -> Array:
	return [
		_hat([
			_forever([
				_say(_var(score_name), "large"),
			]),
		]),
	]


static func p1_hud() -> Array:
	return _score_hud("p1_score")


static func p2_hud() -> Array:
	return _score_hud("p2_score")


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


static func _lt(a: Variant, b: Variant) -> Dictionary:
	return {"opcode": "less_than", "inputs": {"a": a, "b": b}}


static func _random(from: float, to: float) -> Dictionary:
	return {"opcode": "random", "inputs": {"from": from, "to": to}}


static func _stop(mode: String) -> Dictionary:
	return {"opcode": "stop", "inputs": {"mode": mode}}


# On-screen text (Milestone 6).

static func _say(text: Variant, size: String = "small") -> Dictionary:
	return {"opcode": "say", "inputs": {"text": text, "size": size}}


# Cloning (Milestone 4).

static func _clone_hat(body: Array) -> Dictionary:
	return {"opcode": "when_i_start_as_a_clone", "inputs": {"body": body}}


static func _clone() -> Dictionary:
	return {"opcode": "create_clone", "inputs": {"target": "myself"}}


static func _delete_clone() -> Dictionary:
	return {"opcode": "delete_this_clone", "inputs": {}}


static func _sub(a: Variant, b: Variant) -> Dictionary:
	return {"opcode": "subtract", "inputs": {"a": a, "b": b}}


static func _mul(a: Variant, b: Variant) -> Dictionary:
	return {"opcode": "multiply", "inputs": {"a": a, "b": b}}


static func _div(a: Variant, b: Variant) -> Dictionary:
	return {"opcode": "divide", "inputs": {"a": a, "b": b}}


static func _mod(a: Variant, b: Variant) -> Dictionary:
	return {"opcode": "mod", "inputs": {"a": a, "b": b}}
