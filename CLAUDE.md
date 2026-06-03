# scratch-like — a Scratch-style game engine in Godot 4

A small visual-programming game engine, built in stages. The end goal is a
drag-and-drop block editor where you snap blocks onto sprites to script them.
We are building it runtime-first so the execution model is solid before any UI
exists.

## Current state: Milestone 1 — runtime only

**Goal of this milestone:** prove the runtime works with *no editor*. A single
sprite moves and bounces off the four screen edges forever, driven entirely by a
hardcoded "block script" that is expressed as plain data.

There is deliberately **no** visual editor, drag-and-drop, or UI panel yet.

## How to run

1. Open the **Godot 4.6** editor (this project uses the GL Compatibility
   renderer, so it runs on most hardware).
2. `Import` / open this folder (it already contains `project.godot`).
3. Press **F5** (Run Project). The main scene `main.tscn` is configured as the
   project's main scene, so it launches automatically.
4. A blue square sprite starts in the center and bounces around the window,
   reflecting off all four edges indefinitely.

## Core design (the parts meant to outlive this milestone)

### Blocks are data, not objects

A script is an `Array` of block dictionaries, e.g.

```gdscript
{"opcode": "move_steps", "inputs": {"steps": 5}}
```

Substacks (the body of `forever`/`if`, an `if` condition) are nested `Array`s /
nested block dictionaries under `"inputs"`. This is fully serializable and is
exactly the shape a visual editor would emit later. See
[scripts/example_script.gd](scripts/example_script.gd) for the milestone's
script.

### The interpreter is a coroutine-driven tree walker

[scripts/interpreter.gd](scripts/interpreter.gd):

- Running a stack of blocks is an `await`-ing method — a GDScript coroutine.
- `forever` runs its body, then does `await get_tree().process_frame`, yielding
  one frame per iteration so it never blocks the engine.
- Dispatch is table-driven: `opcode` (String) → handler `Callable`. Statement
  blocks and reporter/condition blocks have separate tables. **Adding a new
  block type = register one entry + write its handler method.**

### A `Target` wraps the controlled node

[scripts/target.gd](scripts/target.gd) holds the scene node plus script-level
state (currently just `direction`, in Scratch's convention: 90 = right, 0 = up,
clockwise-positive). Keeping this separate from the node keeps the interpreter
node-agnostic, which makes multiple sprites and an editor straightforward later.

## Opcodes implemented this milestone

| opcode | kind | notes |
| --- | --- | --- |
| `when_flag_clicked` | hat | entry point; started on play |
| `forever` | control | runs its `body` substack, yields one frame per loop |
| `if` | control | runs `body` when `condition` reporter is true |
| `move_steps` | statement | moves `steps` px along the facing direction |
| `turn_degrees` | statement | rotates facing direction clockwise |
| `point_in_direction` | statement | sets direction; special value `"bounce"` reflects off the touched edge(s) |
| `touching_edge?` | reporter | true when the sprite reaches any viewport edge |

> Note on `"bounce"`: the block set has no arithmetic yet, so the reflection math
> can't be expressed as data. For this milestone it lives in the runtime, exposed
> as a special input value of `point_in_direction`. A later milestone with math /
> per-edge blocks can replace it with pure data.

## File layout

```
project.godot              Godot project config; main scene = main.tscn; 800x600 window
main.tscn                  Main scene: Node2D "Main" (main.gd) + child Sprite2D "Sprite"
icon.svg                   Default project icon (skeleton)
scripts/
  main.gd                  Entry point: builds the sprite, "clicks the green flag"
  interpreter.gd           Tree-walking, coroutine-driven block interpreter + dispatch tables
  target.gd                Wraps the controlled node + its direction state
  example_script.gd        The hardcoded Milestone 1 block script, as data
CLAUDE.md                  This file
```

## Conventions for extending

- New block? Add a handler method and one entry in `_register_handlers()` in
  [scripts/interpreter.gd](scripts/interpreter.gd). Statements go in
  `_statement_handlers`; reporters/conditions go in `_reporter_handlers`.
- Keep blocks expressible as plain dictionaries/arrays — no UI assumptions, no
  bespoke classes per block.
- Any potentially long-running block must `await get_tree().process_frame` so it
  yields to the engine.
- Stay scoped to the current milestone; don't add block types beyond what the
  milestone calls for.
