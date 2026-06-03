# scratch-like — a Scratch-style game engine in Godot 4

A small visual-programming game engine, built in stages. The end goal is a
drag-and-drop block editor where you snap blocks onto sprites to script them.
We are building it runtime-first so the execution model is solid before any UI
exists.

## Current state: Milestone 5 — clone lifecycle

**Goal of this milestone:** complete the clone lifecycle M4 left half-built. M4
could only *create* clones; M5 adds **`delete_this_clone`** (a clone removes
itself) and its sibling **`stop "this script"`** (one coroutine unwinds without
touching the others). Both ride the same new primitive: a **per-interpreter
`_alive` flag**, polled exactly where `stop "all"` already polls the Stage's
global flag. The motivating demo turns Pong into a **best-of-N match** — a round
ends at `ROUND_POINTS`, and the pip scoreboard must now *clear and rebuild* each
round (every pip clone deletes itself when the round advances): exactly the reset
M4's create-only clones couldn't do. Taking `ROUNDS_TO_WIN` rounds still fires
`stop "all"` for the full game-over freeze, leaving the final pips on screen.

There is still deliberately **no** visual editor, drag-and-drop, or UI panel yet,
and **no text rendering** (the score is shown as a count of pips, not a number).
See [Deliberately deferred](#deliberately-deferred-to-a-later-milestone).

## How to run

1. Open the **Godot 4.6** editor (this project uses the GL Compatibility
   renderer, so it runs on most hardware).
2. `Import` / open this folder (it already contains `project.godot`).
3. Press **F5** (Run Project). The main scene `main.tscn` launches the `Stage`.
4. A yellow ball serves from the center at a **randomized angle** and bounces off
   the top/bottom walls and both paddles. **Player 1 = W/S**, **Player 2 = ↑/↓**.
   Miss the ball and it pauses ~1s, then re-serves from center toward the side
   that scored. Each point adds a green **pip** to that player's grid (top-left
   for P1, top-right for P2). **First to `ROUND_POINTS` (5) takes the round**: the
   pips clear, scores reset, and the next round serves. **Taking `ROUNDS_TO_WIN`
   (2) rounds wins the match**, at which point every script halts and the game
   freezes with the final round's pips on screen.

## Core design (the parts meant to outlive this milestone)

### Blocks are data, not objects

A script is an `Array` of block dictionaries, e.g.

```gdscript
{"opcode": "move_steps", "inputs": {"steps": 5}}
```

Substacks (the body of `forever`/`if`, an `if` condition) are nested `Array`s /
nested block dictionaries under `"inputs"`. This is fully serializable and is
exactly the shape a visual editor would emit later. See
[scripts/pong_scripts.gd](scripts/pong_scripts.gd) for the Pong scripts (two
paddles, the ball, and the two clone-built scoreboards); it uses tiny static
builder helpers (`_if`, `_move`, …) purely to keep the data readable — the output
is still plain dictionaries/arrays.

### The interpreter is a coroutine-driven tree walker

[scripts/interpreter.gd](scripts/interpreter.gd):

- Running a stack of blocks is an `await`-ing method — a GDScript coroutine.
- `forever` runs its body, then does `await get_tree().process_frame`, yielding
  one frame per iteration so it never blocks the engine. `wait_seconds` yields
  the same cooperative way (awaits a SceneTree timer).
- Dispatch is table-driven: `opcode` (String) → handler `Callable`. Statement
  blocks and reporter/condition blocks have separate tables. **Adding a new
  block type = register one entry + write its handler method.**
- An interpreter is built per sprite as `Interpreter.new(stage, target)`. It
  gets the SceneTree from the stage (a `RefCounted` has no `get_tree()`) and
  resolves *other* sprites via `stage.find_target(name)`.

### The `Stage` is the multi-sprite runtime root + target registry

[scripts/stage.gd](scripts/stage.gd) is the scene root (replaces M1's `main.gd`).
It builds each sprite in code, runs each script as an independent fire-and-forget
coroutine, and — the load-bearing M2 concept — owns the **target registry**:
`name (String) → Target`. This is the first time the block language refers to
*another entity* by name; `touching_sprite?` and anything cross-sprite later
rides on `find_target` / `target_names`.

### A `Target` wraps the controlled node

[scripts/target.gd](scripts/target.gd) holds the scene node plus script-level
state: the facing `direction` (Scratch convention: 90 = right, 0 = up,
clockwise-positive), the `name` it is registered under on the stage, and (M3) a
`variables` dict of its **per-sprite locals**. Keeping this separate from the
node keeps the interpreter node-agnostic.

### Expressions and variables (M3)

The tree walker already recursed for this: `_evaluate()` turns an input into a
value, and if that input is itself a reporter dictionary it dispatches and the
reporter's own inputs are evaluated the same way. So an operator like
`{"opcode": "add", "inputs": {"a": {"opcode": "variable", …}, "b": 1}}` nests to
any depth with **no change to the walker** — M3 was almost entirely "register
more reporter handlers." All reporters are synchronous (no `await`), matching how
`_evaluate()` calls them.

Variables live in two stores: **globals** on the `Stage` (`get_var`/`set_var`/
`has_var`) and **per-sprite locals** in each `Target.variables`. The interpreter
resolves a name **local-first, then global** (Scratch's shadowing order); an
assignment to an unseeded name creates a global with a warning. Both stores are
seeded in code up front (in `Stage._ready`) — that seeding stands in for a future
editor's "make a variable" step.

`stop "all"` clears a `Stage._running` flag that `forever` and `_run_stack` poll
before each step, so every coroutine unwinds within a frame. (M5 generalizes this:
the same two poll sites also check a per-interpreter `_alive` flag, which is how
`stop "this script"` and `delete_this_clone` unwind a single coroutine — see
[Clone lifecycle (M5)](#clone-lifecycle-m5).)

### Cloning (M4)

`create_clone` (only `"myself"` for now) calls `Stage.create_clone_of(source,
script)`, which copies the source's costume + transform into a fresh node, builds
a new `Target` that **inherits the source's `direction` and local variables**
(`variables.duplicate()` — the Scratch idiom: set a local, then clone, and the
clone reads it), and starts a new interpreter via `run_as_clone()`. That launches
the `when_i_start_as_a_clone` hats instead of the green-flag hats, which is why
each interpreter now **retains its `_script`**.

Clones are **not** added to the name registry — they share the original's name
but aren't individually addressable, so `find_target` / `touching_sprite?` keep
resolving the single original (and `_bounce` never sees a clone). The clone stays
alive because its interpreter is retained in `_interpreters`. The pip scoreboard
relies on all of this: the original parks off-screen and spawns one clone per
point; each clone derives its grid cell from its inherited `index`.

### Clone lifecycle (M5)

M4 was create-only; M5 lets a clone **delete itself** and lets any script **stop
just itself**, both on one new primitive: a per-interpreter `_alive` flag. The two
poll sites that already watch the Stage's `is_running()` (`_run_stack` before each
block, `_on_forever` each loop) now also check `_alive`, so flipping it false
unwinds *that one* coroutine within a frame — the per-script counterpart to how
`stop "all"` flips the global flag.

- `stop "this script"` simply sets `_alive = false`.
- `delete_this_clone` sets `_alive = false` **and** calls `Stage.remove_clone`,
  which `queue_free()`s the clone's node and erases its interpreter from
  `_interpreters`. It is a no-op on an original (a `Target.is_clone` flag, set in
  `create_clone_of`, guards it — matching Scratch). Erasing the interpreter mid-
  unwind is safe: the suspended coroutine keeps the object alive until it returns.

The best-of-N scoreboard exercises this: each pip clone is stamped with the
`round` it was born in and watches the global `round`; when the ball bumps `round`
at the start of a new round, every clone deletes itself and the board clears. The
match-end freeze deliberately bumps `round` only on rounds that *continue* — the
clinching round fires `stop "all"` first, so the final pips stay up.
(`stop "this script"` has no load-bearing use in this demo, which keeps `stop
"all"` for the match freeze; it ships as the documented sibling primitive.)

## Opcodes implemented

| opcode | kind | inputs | notes |
| --- | --- | --- | --- |
| `when_flag_clicked` | hat | `body` | entry point; each hat's body starts on play |
| `when_i_start_as_a_clone` | hat | `body` | entry point for a freshly spawned clone |
| `forever` | control | `body` | runs its body, yields one frame per loop |
| `if` | control | `condition`, `body` | runs `body` when the condition reporter is true |
| `move_steps` | statement | `steps` | moves `steps` px along the facing direction |
| `turn_degrees` | statement | `degrees` | rotates facing direction clockwise |
| `point_in_direction` | statement | `direction` | number sets direction absolutely; `"bounce"` reflects off whatever is touched (see below) |
| `go_to` | statement | `x`, `y` | sets position (inputs may be expressions); resets the ball, clamps paddles, places pips |
| `wait_seconds` | statement | `seconds` | awaits a SceneTree timer; the serve delay |
| `touching_edge?` | reporter | `side` | true at a viewport edge; `side` ∈ {top,bottom,left,right,any}, default `any` |
| `touching_sprite?` | reporter | `name` | AABB overlap with the named sprite, resolved through the registry |
| `key_pressed?` | reporter | `key` | polls a key by name (`OS.find_keycode_from_string` → `Input.is_physical_key_pressed`). Use canonical names: `"W"`, `"S"`, `"Up"`, `"Down"` |
| `set_var` | statement | `name`, `value` | sets a variable (local-first, then global; unseeded → creates a global) |
| `change_var` | statement | `name`, `by` | adds `by` to a variable — the score increment |
| `stop` | statement | `mode` | `"all"` halts every script (the game-over freeze); `"this script"` unwinds only the calling coroutine (clears its `_alive` flag) |
| `create_clone` | statement | `target` | only `"myself"` is supported: spawns a clone that inherits locals and runs the clone hats |
| `delete_this_clone` | statement | — | removes the running clone (frees its node, releases its interpreter); a no-op on an original. Clears the round's pips |
| `variable` | reporter | `name` | reads a variable, resolving local-first then global |
| `add` / `subtract` / `multiply` / `divide` / `mod` | reporter | `a`, `b` | arithmetic; `divide`/`mod` guard ÷0 → 0 |
| `equals` / `greater_than` / `less_than` | reporter | `a`, `b` | numeric comparison → bool |
| `and` / `or` / `not` | reporter | `a`, `b` (`not`: `a`) | boolean combinators → bool |
| `random` | reporter | `from`, `to` | uniform float in `[from, to]`; the varied serve angle |

> Note on `"bounce"`: the reflection math still lives in the runtime as a sentinel
> input of `point_in_direction` rather than as data. M3 added arithmetic, so this
> *could* now be expressed as blocks, but `_bounce()` also reflects off both
> viewport edges and overlapping sprites (shallowest-overlap axis for sprite
> hits) using *sign-based steering* — forcing the velocity component away from the
> surface rather than negating it, so calling bounce from several `if` branches in
> one frame can't make a sprite stick. Replacing it with pure data is left for
> when sprites expose their velocity/position as reporters.

## File layout

```
project.godot              Godot project config; main scene = main.tscn; 800x600 window
main.tscn                  Main scene: a single Node2D "Stage" running stage.gd
icon.svg                   Default project icon (skeleton)
scripts/
  stage.gd                 Runtime root: builds sprites, owns the name->Target registry, runs scripts
  interpreter.gd           Tree-walking, coroutine-driven block interpreter + dispatch tables
  target.gd                Wraps the controlled node + its direction and name
  pong_scripts.gd          The hardcoded Pong block scripts (two paddles, ball, two clone-built scoreboards), as data
CLAUDE.md                  This file
```

## Conventions for extending

- New block? Add a handler method and one entry in `_register_handlers()` in
  [scripts/interpreter.gd](scripts/interpreter.gd). Statements go in
  `_statement_handlers`; reporters/conditions go in `_reporter_handlers`.
- Keep blocks expressible as plain dictionaries/arrays — no UI assumptions, no
  bespoke classes per block.
- Any potentially long-running block must `await get_tree().process_frame` (or a
  timer) so it yields to the engine.
- Cross-sprite blocks resolve other entities through the stage registry
  (`stage.find_target(name)`), never by reaching into the scene tree directly.
- Stay scoped to the current milestone; don't add block types beyond what the
  milestone calls for.

## Deliberately deferred (to a later milestone)

- **Deleting *another* sprite's clones / `create_clone` of a named sprite** —
  `create_clone` and `delete_this_clone` only act on `"myself"` / the running
  clone. Spawning or culling another target's clones needs the registry to track
  clones, not just originals.
- **On-screen text / `say` / HUD** — a text-rendering "costume" so a sprite can
  display a value (a real numeric score instead of pips). Still the path to a HUD.
- **Event hats (`when_key_pressed`)** — needs an event-dispatch system. Polling
  `key_pressed?` inside `forever` stays within the existing loop model.

> Note: collision is axis-aligned box overlap (`Rect2.intersects`); a sprite's
> world box is centered on its node position (Sprite2D is centered by default).
