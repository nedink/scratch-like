#!/usr/bin/env python3
"""Generate platformer.json — a scratch-like save file (M40 flat single-stage shape).

A single-level platformer built only from the engine's existing opcodes. The character
has no "change y" block, so position is tracked in per-sprite variables (px/py/vx/vy)
and written each tick with go_to; gravity, jumping, solid landing, side-wall collision,
coins and a goal are all assembled from move/if/forever/variable/operator blocks.

All sprite geometry is aligned to the editor's default 8px grid and fits inside the
fixed 480x352 screen (the runtime/editor stage size), so the level sits cleanly on the
grid when opened in the stage editor.
"""

import json

# ---- block builders (mirror PongScripts' tiny helpers) --------------------

def hat(body):            return {"opcode": "when_flag_clicked", "inputs": {"body": body}}
def forever(body):        return {"opcode": "forever", "inputs": {"body": body}}
def if_(cond, body):      return {"opcode": "if", "inputs": {"condition": cond, "body": body}}
def go_to(x, y):          return {"opcode": "go_to", "inputs": {"x": x, "y": y}}
def set_var(n, v):        return {"opcode": "set_var", "inputs": {"name": n, "value": v}}
def change(n, by):        return {"opcode": "change_var", "inputs": {"name": n, "by": by}}
def say(t, size="large"): return {"opcode": "say", "inputs": {"text": t, "size": size}}
def stop(mode):           return {"opcode": "stop", "inputs": {"mode": mode}}

def var(n):               return {"opcode": "variable", "inputs": {"name": n}}
def add(a, b):            return {"opcode": "add", "inputs": {"a": a, "b": b}}
def sub(a, b):            return {"opcode": "subtract", "inputs": {"a": a, "b": b}}
def gt(a, b):             return {"opcode": "greater_than", "inputs": {"a": a, "b": b}}
def lt(a, b):             return {"opcode": "less_than", "inputs": {"a": a, "b": b}}
def eq(a, b):             return {"opcode": "equals", "inputs": {"a": a, "b": b}}
def and_(a, b):           return {"opcode": "and", "inputs": {"a": a, "b": b}}
def edge(side):           return {"opcode": "touching_edge?", "inputs": {"side": side}}
def touching(name):       return {"opcode": "touching_sprite?", "inputs": {"name": name}}
def key(k):               return {"opcode": "key_pressed?", "inputs": {"key": k}}


def any_touching(names):
    """Right-folded OR of touching_sprite? over a list of solid sprite names."""
    cond = touching(names[-1])
    for n in reversed(names[:-1]):
        cond = {"opcode": "or", "inputs": {"a": touching(n), "b": cond}}
    return cond


# ---- physics constants ----------------------------------------------------

SPEED = 4        # horizontal px/tick
GRAV = 1         # downward accel px/tick^2
JUMP = 12        # initial upward velocity
PW, PH = 16, 32  # player size (grid-aligned: 2x4 tiles)
HW = PW // 2     # half width (for screen-edge clamp)
VIEW_W, VIEW_H = 480, 352


def player_script(start_x, start_y, solids, hazards):
    """The controllable character.

    Per tick the two axes are resolved *independently* (the standard separate-axis
    collision response):

      1. Horizontal: read left/right into `vx`, move px, then if we end up inside a
         solid, step the whole `vx` back out — so the side of a platform stops the
         player like a vertical wall (they slide along it rather than passing through).
      2. Vertical: apply gravity to `vy`, move py, then if we end up inside a solid,
         step the whole `vy` back out (settles to a ~1px rest gap, self-corrects each
         frame) and, if we were falling, mark on_ground so a jump is allowed.

    Resolving the axes in separate passes (each with its own go_to + touching test) is
    what makes a floor a floor and a wall a wall without any shallowest-overlap logic.
    """
    # --- horizontal collision: hit the side of a solid -> step back like a wall ---
    wall_resolve = if_(any_touching(solids), [
        set_var("px", sub(var("px"), var("vx"))),   # undo this tick's horizontal move
        go_to(var("px"), var("py")),
    ])

    # --- vertical collision: land on / bonk under a solid ---
    grounded_resolve = if_(any_touching(solids), [
        set_var("py", sub(var("py"), var("vy"))),   # undo this tick's vertical move
        if_(gt(var("vy"), 0), [set_var("on_ground", 1)]),  # was falling -> landed
        set_var("vy", 0),
        go_to(var("px"), var("py")),
    ])

    hazard_cond = edge("bottom")
    for h in hazards:
        hazard_cond = {"opcode": "or", "inputs": {"a": touching(h), "b": hazard_cond}}

    respawn = if_(hazard_cond, [
        set_var("px", start_x),
        set_var("py", start_y),
        set_var("vy", 0),
        go_to(var("px"), var("py")),
    ])

    loop = forever([
        set_var("on_ground", 0),
        # --- horizontal: build vx from input, integrate, clamp, then collide ---
        set_var("vx", 0),
        if_(key("Right"), [set_var("vx", SPEED)]),
        if_(key("Left"),  [set_var("vx", -SPEED)]),
        set_var("px", add(var("px"), var("vx"))),
        if_(lt(var("px"), HW),            [set_var("px", HW)]),
        if_(gt(var("px"), VIEW_W - HW),   [set_var("px", VIEW_W - HW)]),
        go_to(var("px"), var("py")),
        wall_resolve,
        # --- vertical: gravity, integrate, then collide ---
        set_var("vy", add(var("vy"), GRAV)),
        set_var("py", add(var("py"), var("vy"))),
        go_to(var("px"), var("py")),
        grounded_resolve,
        # --- jump (only when grounded) ---
        if_(and_(eq(var("on_ground"), 1), key("Up")), [
            set_var("vy", -JUMP),
            set_var("on_ground", 0),
        ]),
        # --- death / respawn ---
        respawn,
        # --- reach the goal ---
        if_(touching("Goal"), [set_var("won", 1)]),
    ])

    return [hat([
        set_var("px", start_x),
        set_var("py", start_y),
        set_var("vx", 0),
        set_var("vy", 0),
        set_var("on_ground", 0),
        go_to(var("px"), var("py")),
        loop,
    ])]


def coin_script():
    """A collectible: when the player overlaps it, bump the score and vanish."""
    return [hat([
        forever([
            if_(touching("Player"), [
                change("score", 1),
                go_to(-200, -200),
                stop("this script"),
            ]),
        ]),
    ])]


def score_hud_script():
    return [hat([forever([say(var("score"), "large")])])]


def banner_script():
    """Watches the shared `won` flag; paints the win banner and freezes the game."""
    return [hat([
        forever([
            if_(eq(var("won"), 1), [
                go_to(240, 176),
                say("YOU WIN", "large"),
                stop("all"),
            ]),
        ]),
    ])]


# ---- sprite helpers -------------------------------------------------------

def sprite(name, x, y, w, h, color, script):
    return {"name": name, "x": x, "y": y, "w": w, "h": h, "color": color, "script": script}

COL_PLAYER = "#ff5a5aff"
COL_GROUND = "#5b4636ff"
COL_PLAT   = "#6ab04cff"
COL_COIN   = "#ffd23fff"
COL_SPIKE  = "#e63946ff"
COL_GOAL   = "#2ecc71ff"
COL_CLEAR  = "#ffffff00"

GROUND_TOP = 320                      # ground surface y (ground centered y=336, h=32)
PLAYER_REST = GROUND_TOP - PH // 2    # 304: player center when standing on ground (grid-aligned)


def common_sprites(player, solids, hazards, coins, goal_xy, extra=None):
    """Assemble a level's sprite list from its pieces. `solids`/`hazards` are
    (name, x, y, w, h) tuples; coins are (x, y); goal_xy is (x, y)."""
    sprites = []
    sprites.append(sprite("Player", player[0], player[1], PW, PH, COL_PLAYER,
                          player_script(player[0], player[1],
                                        [s[0] for s in solids],
                                        [h[0] for h in hazards])))
    sprites.append(sprite("Ground", 240, 336, 480, 32, COL_GROUND, []))
    for (n, x, y, w, h) in solids:
        if n == "Ground":
            continue
        sprites.append(sprite(n, x, y, w, h, COL_PLAT, []))
    for i, (x, y) in enumerate(coins, 1):
        sprites.append(sprite("Coin%d" % i, x, y, 16, 16, COL_COIN, coin_script()))
    for (n, x, y, w, h) in hazards:
        sc = extra.get(n, []) if extra else []
        sprites.append(sprite(n, x, y, w, h, COL_SPIKE, sc))
    sprites.append(sprite("Goal", goal_xy[0], goal_xy[1], 16, 48, COL_GOAL, []))
    sprites.append(sprite("ScoreHud", 40, 24, 16, 16, COL_CLEAR, score_hud_script()))
    sprites.append(sprite("Banner", 240, 176, 16, 16, COL_CLEAR, banner_script()))
    return sprites


def level_vars(extra_locals=None):
    v = [
        {"name": "score", "value": 0, "scope": "global"},
        {"name": "won", "value": 0, "scope": "global"},
        {"name": "px", "value": 0, "scope": "Player"},
        {"name": "py", "value": 0, "scope": "Player"},
        {"name": "vx", "value": 0, "scope": "Player"},
        {"name": "vy", "value": 0, "scope": "Player"},
        {"name": "on_ground", "value": 0, "scope": "Player"},
    ]
    if extra_locals:
        v += extra_locals
    return v


def grid():
    return {"show": True, "snap": True, "color": "#87cefa59", "step": 8}


# ---- The single stage: Meadow (gentle intro) ------------------------------

def meadow():
    """All centers and sizes are multiples of 8 and inside 480x352.

    Layout (y grows down): ground spans the floor; a tall Wall rises from the ground
    to demonstrate side-wall collision (the player must jump it, not walk through);
    three floating platforms step up to the right; coins sit on the path; the goal
    stands on the ground at the far right.
    """
    solids = [
        ("Ground", 240, 336, 480, 32),   # floor:   x[0,480]   y[320,352]
        ("Wall",   224, 288, 16, 64),    # pillar:  x[216,232] y[256,320]  (on the ground)
        ("Plat1",  160, 256, 64, 16),    #          x[128,192] y[248,264]
        ("Plat2",  288, 200, 64, 16),    #          x[256,320] y[192,208]
        ("Plat3",  400, 152, 64, 16),    #          x[368,432] y[144,160]
    ]
    coins = [(96, 296), (160, 232), (288, 176), (400, 128)]
    sprites = common_sprites(
        player=(40, PLAYER_REST), solids=solids, hazards=[], coins=coins,
        goal_xy=(456, 296))
    return sprites, level_vars(), "#87ceebff"


def main():
    sprites, variables, background = meadow()
    project = {
        "scripts": sprites,
        "variables": variables,
        "background": background,
        "grid": grid(),
    }
    with open("platformer.json", "w") as f:
        json.dump(project, f, indent="\t")
    print("wrote platformer.json with %d sprites" % len(project["scripts"]))


if __name__ == "__main__":
    main()
