# scratch-like — a Scratch-style game engine in Godot 4

A small visual-programming game engine, built in stages. The end goal is a
drag-and-drop block editor where you snap blocks onto sprites to script them.
We are building it runtime-first so the execution model is solid before any UI
exists.

## Current state: Milestone 2 — multi-sprite runtime (Pong)

**Goal of this milestone:** prove the thing M1 set up but never exercised —
**multiple sprites each running their own block script concurrently, able to
sense each other**. The demo is a playable rally **Pong**: two keyboard paddles
and a ball, all driven entirely by block-script *data*.

There is still deliberately **no** visual editor, drag-and-drop, or UI panel
yet, and **no** variables/operators (so no on-screen score) — see
[Deliberately deferred](#deliberately-deferred-to-a-later-milestone).

## How to run

1. Open the **Godot 4.6** editor (this project uses the GL Compatibility
   renderer, so it runs on most hardware).
2. `Import` / open this folder (it already contains `project.godot`).
3. Press **F5** (Run Project). The main scene `main.tscn` launches the `Stage`.
4. A yellow ball serves from the center and bounces off the top/bottom walls and
   both paddles. **Player 1 = W/S**, **Player 2 = ↑/↓**. Miss the ball and it
   pauses ~1s, then re-serves from center toward the side that scored. There is
   no score display.

## Core design (the parts meant to outlive this milestone)

### Blocks are data, not objects

A script is an `Array` of block dictionaries, e.g.

```gdscript
{"opcode": "move_steps", "inputs": {"steps": 5}}
```

Substacks (the body of `forever`/`if`, an `if` condition) are nested `Array`s /
nested block dictionaries under `"inputs"`. This is fully serializable and is
exactly the shape a visual editor would emit later. See
[scripts/pong_scripts.gd](scripts/pong_scripts.gd) for the three Pong scripts;
it uses tiny static builder helpers (`_if`, `_move`, …) purely to keep the data
readable — the output is still plain dictionaries/arrays.

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
clockwise-positive) and the `name` it is registered under on the stage. Keeping
this separate from the node keeps the interpreter node-agnostic.

## Opcodes implemented

| opcode | kind | inputs | notes |
| --- | --- | --- | --- |
| `when_flag_clicked` | hat | `body` | entry point; each hat's body starts on play |
| `forever` | control | `body` | runs its body, yields one frame per loop |
| `if` | control | `condition`, `body` | runs `body` when the condition reporter is true |
| `move_steps` | statement | `steps` | moves `steps` px along the facing direction |
| `turn_degrees` | statement | `degrees` | rotates facing direction clockwise |
| `point_in_direction` | statement | `direction` | number sets direction absolutely; `"bounce"` reflects off whatever is touched (see below) |
| `go_to` | statement | `x`, `y` | sets position; resets the ball and clamps paddles |
| `wait_seconds` | statement | `seconds` | awaits a SceneTree timer; the serve delay |
| `touching_edge?` | reporter | `side` | true at a viewport edge; `side` ∈ {top,bottom,left,right,any}, default `any` |
| `touching_sprite?` | reporter | `name` | AABB overlap with the named sprite, resolved through the registry |
| `key_pressed?` | reporter | `key` | polls a key by name (`OS.find_keycode_from_string` → `Input.is_physical_key_pressed`). Use canonical names: `"W"`, `"S"`, `"Up"`, `"Down"` |

> Note on `"bounce"`: the block set has no arithmetic yet, so the reflection math
> can't be expressed as data. It lives in the runtime as a sentinel input of
> `point_in_direction`, and `_bounce()` reflects off both viewport edges and
> overlapping sprites (shallowest-overlap axis for sprite hits). It uses
> *sign-based steering* — forcing the velocity component away from the surface
> rather than negating it — so calling bounce from several `if` branches in one
> frame can't make a sprite stick. A later math/operator milestone can replace
> the sentinel with pure data.

## File layout

```
project.godot              Godot project config; main scene = main.tscn; 800x600 window
main.tscn                  Main scene: a single Node2D "Stage" running stage.gd
icon.svg                   Default project icon (skeleton)
scripts/
  stage.gd                 Runtime root: builds sprites, owns the name->Target registry, runs scripts
  interpreter.gd           Tree-walking, coroutine-driven block interpreter + dispatch tables
  target.gd                Wraps the controlled node + its direction and name
  pong_scripts.gd          The three hardcoded Pong block scripts (two paddles + ball), as data
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

- **Variables + math/boolean operators** — a whole *expression* layer (reporters
  nesting reporters) plus a scoping decision. This is its own "data &
  expressions" milestone, with an on-screen scoreboard as the motivating use.
- **On-screen score / `say` / HUD** — depends on the above + a text-display
  block.
- **Event hats (`when_key_pressed`)** — needs an event-dispatch system. Polling
  `key_pressed?` inside `forever` stays within the existing loop model.
- **`stop` / game-over**, **randomness** — only meaningful with a score; serve
  angles are fixed literals for now.

> Note: collision is axis-aligned box overlap (`Rect2.intersects`); a sprite's
> world box is centered on its node position (Sprite2D is centered by default).
