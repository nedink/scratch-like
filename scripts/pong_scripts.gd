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
## M41 makes the **right paddle auto-animate** (a CPU paddle): instead of arrow-key control it
## glides up and down on its own, driving `right_paddle_y` straight through the `animate` block,
## and the arrow keys move to the LEFT paddle (so it now answers W/S *and* the arrows).
##
## Layout assumptions (matched in stage.gd's _GAME_SIZE, the 480x352 window). These are the *script*
## (go_to) targets that drive the runtime — distinct from the grid-aligned model starting positions
## in sprites(). All vertical limits derive from the 352px-tall screen:
##   * paddles are 16x96 (half-height 48), so their center y is clamped to [48, 304] (= 352 - 48);
##   * left paddle rides x = 24, right paddle rides x = 456;
##   * the ball is 16x16 and serves from the center (240, 176) (= 480/2, 352/2).

const PADDLE_SPEED := 8.0
## How long the auto-animated right paddle takes to glide from one end of its rail to the
## other (M41). One full sweep top->bottom (or back) takes this many seconds.
const PADDLE_SWEEP_SECS := 1.4
const BALL_SPEED := 6.0
const PADDLE_TOP_Y := 48.0
const PADDLE_BOTTOM_Y := 304.0  # 352 (screen height) - 48 (paddle half-height)
const CENTER := Vector2(240, 176)  # screen centre: 480/2, 352/2
const SERVE_DELAY := 1.0
## Best-of-N (Milestone 5): take a round by reaching this many points, and win the
## match — firing `stop "all"` — by taking this many rounds. Each continuing round
## bumps the global `round` and re-serves from center.
const ROUND_POINTS := 5
const ROUNDS_TO_WIN := 2
## Serve angle = straight across (90 = right, 270 = left) ± a random spread.
const SERVE_SPREAD := 45.0
## Curved-paddle bounce: the paddles deflect the ball as if they were convex (bulging
## toward the centre of the playfield), so the outgoing angle depends on *where* the ball
## hits — centre sends it straight back, the ends deflect it steeply toward that end (the
## surface normal of a bulge tilts away from centre). This is degrees of deflection per
## pixel the ball's centre is offset from the paddle's centre; at the extreme reach
## (paddle half-height 48 + ball half 8 = 56px) that's ~50° off straight, never vertical.
const PADDLE_BOUNCE_CURVE := 0.9


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
		# Each paddle publishes its centre y here every tick (a `set` block in _paddle), so the
		# ball — a different sprite — can read the paddle's position for the curved bounce below.
		# (y_position reports the *running* sprite, so a global relay is how one sprite tells
		# another where it is.) Global so the ball can see them.
		{"name": "left_paddle_y", "value": 0, "scope": "global"},
		{"name": "right_paddle_y", "value": 0, "scope": "global"},
	]


## The project's stage background colour (Milestone 27): a single stage-level setting — the
## colour the stage view draws behind the sprites and the game paints its viewport with at RUN.
## A **hex string** like the sprite colours, so it serialises straight to JSON for SAVE/OPEN (the
## editor stores it under a top-level "background" key); the editor seeds its working copy from
## here and the Stage falls back to it when launched directly (no editor). The stock value is
## opaque black (`#000000ff`).
static func background() -> String:
	return "#000000ff"


## The project's stage-editor grid settings (Milestone 27): the alignment grid's visibility, snap
## behaviour, colour, and spacing. Like background() this is a stage-level project property — seeded
## into the editor's working copy, saved under a top-level "grid" key, and reloaded on OPEN — so a
## project remembers how its author set up the grid. `color` is a hex string with alpha (the
## JSON-clean format the sprite/background colours use); `step` is in model pixels. The stock values
## match the stage view's standalone defaults (a faint sky-blue 8px grid, show + snap on).
static func grid() -> Dictionary:
	return {
		"show": true,
		"snap": true,
		"color": "#" + Color(0.529, 0.808, 0.980, 0.35).to_html(true),
		"step": 8,
	}


## The project's sprite model (Milestone 24): the single declaration of every sprite's name,
## starting geometry (placeholder rectangle), and script — the sprite counterpart of variables(),
## and the one source both the runtime and the editor read.
##
## It retires a hardcoded set that lived only in stage.gd._ready (six literal _add_sprite + _run
## calls), the last pillar of the project model not yet data-owned. Stage._ready now loops this
## (build each placeholder from x/y/w/h/color, then run its script); the editor seeds its working
## _scripts from it and hands the edited model back at RUN (Stage.project_sprites). Geometry values
## are aligned to the editor's 16px grid (480x352 stage): the paddles 16x96 on their rails, the ball
## 16x16 near center, the two HUDs and the announcer 16x16 transparent placeholders (`say` supplies
## their costume each tick / on the win — the placeholder size is invisible, snapped to one grid cell
## so it sits cleanly on the grid in the stage view).
##
## `color` is a **hex string** (not a Color) so the model serialises straight to JSON for SAVE/OPEN
## (M22); Stage converts it with Color(hex). Each entry carries its `script` from the builders below —
## a sprite owns its scripts (Scratch). A sprite's *starting* position here is just the placeholder;
## real positioning is blocks (the ball `go_to`s center itself), so a new sprite the editor adds can
## position itself with a `go_to` block rather than needing a UI to move it.
static func sprites() -> Array:
	return [
		{"name": "LeftPaddle", "x": 32, "y": 176, "w": 16, "h": 96, "color": "#e6e6f2", "script": left_paddle()},
		{"name": "RightPaddle", "x": 448, "y": 176, "w": 16, "h": 96, "color": "#e6e6f2", "script": right_paddle()},
		{"name": "Ball", "x": 240, "y": 176, "w": 16, "h": 16, "color": "#ffcc40", "script": ball()},
		{"name": "P1Hud", "x": 32, "y": 32, "w": 16, "h": 16, "color": "#ffffff00", "script": p1_hud()},
		{"name": "P2Hud", "x": 448, "y": 32, "w": 16, "h": 16, "color": "#ffffff00", "script": p2_hud()},
		{"name": "Announcer", "x": -400, "y": -400, "w": 16, "h": 16, "color": "#ffffff00", "script": announcer()},
	]


## A keyboard-driven paddle: move on its vertical rail while any of its up/down keys is
## held, and clamp back onto the playfield at the top and bottom. `rail_x` is the fixed
## x, so the clamp targets are literals. `up_keys`/`down_keys` are *lists* so a paddle can
## answer more than one key (M41 gives the left paddle W/S *and* the arrows).
static func _paddle(up_keys: Array, down_keys: Array, rail_x: float, y_var: String) -> Array:
	return [
		_hat([
			_forever([
				# Publish our centre y so the ball can read where this paddle is (see the curved
				# bounce in ball()). y_position reports this running sprite — the paddle — so this
				# global is the relay one sprite uses to tell another its position.
				_set_var(y_var, _ypos()),
				_if(_keys_pressed(up_keys), [
					_point(0),  # up
					_move(PADDLE_SPEED),
				]),
				_if(_keys_pressed(down_keys), [
					_point(180),  # down
					_move(PADDLE_SPEED),
				]),
				_if(_edge("top"), [_go_to(rail_x, PADDLE_TOP_Y)]),
				_if(_edge("bottom"), [_go_to(rail_x, PADDLE_BOTTOM_Y)]),
			]),
		]),
	]


## "Any of these keys is down" as a boolean reporter: a single key_pressed?, or an `or` chain
## over several. Key names are Godot's canonical keycode-name strings (see
## OS.find_keycode_from_string), so "W"/"S"/"Up"/"Down", not "w"/"s".
static func _keys_pressed(keys: Array) -> Dictionary:
	var cond := _key_pressed(keys[0])
	for i in range(1, keys.size()):
		cond = _or(cond, _key_pressed(keys[i]))
	return cond


static func left_paddle() -> Array:
	# The left paddle now answers both its own W/S and the arrow keys (M41): the right
	# paddle gave up player control to auto-animate, so the arrows move here too.
	return _paddle(["W", "Up"], ["S", "Down"], 24.0, "left_paddle_y")


## The right paddle is a CPU paddle (M41): rather than reading keys it glides up and down its
## rail on its own, using the animation block to tween `right_paddle_y` — the very global the
## ball reads for the curved bounce, so animating it directly both moves the paddle and keeps
## that relay correct. `animate` blocks its script for the sweep duration (like a glide), so the
## sweep lives in its own hat; a second hat keeps the paddle node sitting on the value each frame
## (the animate writes the variable, but the node only moves when a `go to` reads it — and the
## ball needs the physical node there to register a `touching RightPaddle?`). We sweep with
## "ease out" so the paddle decelerates into each turning point and reverses gracefully.
static func right_paddle() -> Array:
	return [
		_hat([
			_set_var("right_paddle_y", PADDLE_TOP_Y),  # start at the top (the var seeds to 0)
			_forever([
				_animate("right_paddle_y", PADDLE_BOTTOM_Y, PADDLE_SWEEP_SECS, "ease out"),
				_animate("right_paddle_y", PADDLE_TOP_Y, PADDLE_SWEEP_SECS, "ease out"),
			]),
		]),
		_hat([
			_forever([
				_go_to(456.0, _var("right_paddle_y")),
			]),
		]),
	]


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
				# Bounce, expressed as blocks (M35) instead of the `point_in_direction "bounce"`
				# runtime sentinel — faithful to _bounce's sign-based steering + position nudge:
				#  * The top/bottom WALLS reflect flat off a horizontal surface -> 180 - direction
				#    (point_in_direction wraps the result).
				#  * The PADDLES are CURVED (convex, bulging toward the centre of the playfield), so
				#    they don't mirror the incoming angle — the outgoing angle depends on *where* the
				#    ball strikes: a hit at the paddle's centre goes straight back (90 right / 270
				#    left), a hit toward an end deflects steeply toward that end, because a bulge's
				#    surface normal tilts away from centre. We read the offset of the ball's centre
				#    from the paddle's centre (ball y_position - the paddle's relayed y) and add it,
				#    scaled by PADDLE_BOUNCE_CURVE, to the straight-back direction: LEFT paddle ->
				#    90 + offset*curve (negative offset = hit high -> up-right; positive = low ->
				#    down-right); RIGHT paddle -> 270 - offset*curve (mirror). See _paddle_bounce_dir.
				#  * The inner `if` gates the flip on the *sign* of the motion (only reflect if heading
				#    INTO the surface), so re-triggering next frame can't double-flip the ball into a
				#    stick — exactly what _bounce's absf() steering guarantees. Direction here is Scratch
				#    degrees (90 = right, 0 = up): heading up is dir<90 or dir>270, down is 90<dir<270,
				#    left is dir>180, right is dir<180.
				#  * The go_to is the nudge: snap the centre clear of the surface so the ball never
				#    lingers inside it. Edge bounds are the 8px-inset viewport (ball half-size); the
				#    paddle clear-x is a literal from the paddles' fixed rails (LeftPaddle right edge
				#    40 + ball half 8 = 48; RightPaddle left edge 440 - 8 = 432).
				_if(_edge("top"), [
					_if(_or(_lt(_dir(), 90), _gt(_dir(), 270)), [_point(_sub(180, _dir()))]),
					_go_to(_xpos(), 8),
				]),
				_if(_edge("bottom"), [
					_if(_and(_gt(_dir(), 90), _lt(_dir(), 270)), [_point(_sub(180, _dir()))]),
					_go_to(_xpos(), 344),
				]),
				_if(_touching("LeftPaddle"), [
					_if(_gt(_dir(), 180), [_point(_add(90, _paddle_bounce_dir("left_paddle_y")))]),
					_go_to(48, _ypos()),
				]),
				_if(_touching("RightPaddle"), [
					_if(_lt(_dir(), 180), [_point(_sub(270, _paddle_bounce_dir("right_paddle_y")))]),
					_go_to(432, _ypos()),
				]),
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


## The curved-paddle deflection (an expression, like the serve angles): how far off
## straight-back the bounce should aim, given where the ball struck the paddle. It is the
## ball's centre offset from the paddle's centre (ball y_position minus the paddle's relayed
## centre y, read from `paddle_y_var`) times PADDLE_BOUNCE_CURVE. A hit above the paddle
## centre is a negative offset (the screen y grows downward), so for the LEFT paddle
## `90 + offset*curve` aims up-right, and a hit below aims down-right; the RIGHT paddle uses
## `270 - offset*curve` for the mirror. This is what makes the paddle act convex: the angle
## tracks the contact point, not the incoming direction.
static func _paddle_bounce_dir(paddle_y_var: String) -> Dictionary:
	return _mul(_sub(_ypos(), _var(paddle_y_var)), PADDLE_BOUNCE_CURVE)


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


# Animation block (M41): tween a variable to a target over a duration, with
# linear / ease in / ease out interpolation. Blocks its script for the duration.
static func _animate(var_name: String, value: Variant, seconds: Variant, easing: String) -> Dictionary:
	return {"opcode": "animate", "inputs": {"name": var_name, "value": value, "seconds": seconds, "easing": easing}}


static func _var(var_name: String) -> Dictionary:
	return {"opcode": "variable", "inputs": {"name": var_name}}


static func _add(a: Variant, b: Variant) -> Dictionary:
	return {"opcode": "add", "inputs": {"a": a, "b": b}}


static func _gt(a: Variant, b: Variant) -> Dictionary:
	return {"opcode": "greater_than", "inputs": {"a": a, "b": b}}


static func _lt(a: Variant, b: Variant) -> Dictionary:
	return {"opcode": "less_than", "inputs": {"a": a, "b": b}}


static func _and(a: Variant, b: Variant) -> Dictionary:
	return {"opcode": "and", "inputs": {"a": a, "b": b}}


static func _or(a: Variant, b: Variant) -> Dictionary:
	return {"opcode": "or", "inputs": {"a": a, "b": b}}


# Motion-state reporters (M35) — read the ball's facing / centre so a bounce can be
# expressed as blocks instead of the `point_in_direction "bounce"` runtime sentinel.
static func _dir() -> Dictionary:
	return {"opcode": "direction", "inputs": {}}


static func _xpos() -> Dictionary:
	return {"opcode": "x_position", "inputs": {}}


static func _ypos() -> Dictionary:
	return {"opcode": "y_position", "inputs": {}}


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
