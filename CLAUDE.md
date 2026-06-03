# scratch-like — a Scratch-style game engine in Godot 4

A small visual-programming game engine, built in stages. The end goal is a
drag-and-drop block editor where you snap blocks onto sprites to script them.
We are building it runtime-first so the execution model is solid before any UI
exists.

## Current state: Milestone 7 — numeric HUD

**Goal of this milestone:** turn the M6 font into a **live scoreboard**, retiring the
M4/M5 clone-built pip grids for a **real numeric readout**. Two **HUD** sprites (one
per player) park where the pips used to and `say` their score every tick, in the
`"large"` face. It is deliberately the thinnest milestone in the project: `say`
already stringifies a number reporter, so the readout is just `say (score)` inside a
`forever` — **no new opcode, and no font additions** (the digit glyphs `0–9` were
already in the atlas). The visible change is the scoreboard: instead of a growing
grid of green pips, each side shows a single climbing digit (0–5), resetting to 0
between rounds, and the **winning `ROUND_POINTS` stays frozen on screen** under the
"P1 WINS" / "P2 WINS" banner.

The one piece of real design was the freeze. M5's pip grid was decoupled from the
live score (it counted clones, cleared only when the global `round` advanced), so the
ball could zero the scores every round-end and the final pips still showed. The HUD
reads the *live* score, so `_on_round_won` had to move its score-zeroing **inside**
the "match continues" branch — on the clinching round the scores are left standing so
the winning number freezes on screen. See [Numeric HUD (M7)](#numeric-hud-m7).

There is still deliberately **no** visual editor, drag-and-drop, or UI panel yet.
Text is uppercase letters + digits only — the atlas has no lowercase or
punctuation. See [Deliberately deferred](#deliberately-deferred-to-a-later-milestone).

## How to run

1. Open the **Godot 4.6** editor (this project uses the GL Compatibility
   renderer, so it runs on most hardware).
2. `Import` / open this folder (it already contains `project.godot`).
3. Press **F5** (Run Project). The main scene `main.tscn` launches the `Stage`.
4. A yellow ball serves from the center at a **randomized angle** and bounces off
   the top/bottom walls and both paddles. **Player 1 = W/S**, **Player 2 = ↑/↓**.
   Miss the ball and it pauses ~1s, then re-serves from center toward the side
   that scored. Each point increments that player's **numeric score readout** (a
   single digit, top-left for P1, top-right for P2). **First to `ROUND_POINTS` (5)
   takes the round**: both readouts reset to 0 and the next round serves. **Taking
   `ROUNDS_TO_WIN` (2) rounds wins the match**, at which point the **"P1 WINS" /
   "P2 WINS"** banner appears at center and every script halts, freezing the game
   with the winner named and the winning score (5) left on screen.

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
paddles, the ball, the two numeric score readouts, and the announcer); it uses
tiny static builder helpers (`_if`, `_move`, …) purely to keep the data readable —
the output is still plain dictionaries/arrays.

### The interpreter is a coroutine-driven tree walker

[scripts/interpreter.gd](scripts/interpreter.gd):

- Running a stack of blocks is an `await`-ing method — a GDScript coroutine.
- `forever` runs its body, then does `await get_tree().physics_frame`, yielding
  one **tick** per iteration so it never blocks the engine. It ticks on the
  *physics* frame, not the render frame, on purpose: blocks count ticks, not
  seconds (`move_steps` moves a fixed N px per loop), so a constant *speed* only
  emerges if the loop runs at a constant rate. The physics frame fires at a fixed
  `physics_ticks_per_second` (60) regardless of render FPS and is clamped per
  render frame, which makes motion frame-rate-independent and keeps a slow or
  bursty startup from flinging a sprite across the screen. (Delta-scaling each
  move instead would wrongly make a *one-shot* `move 10` cover a frame-rate-
  dependent distance; the fixed tick is Scratch's own model.) `wait_seconds`
  instead awaits a real-time SceneTree timer — wall-clock seconds, not ticks.
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
alive because its interpreter is retained in `_interpreters`. The M4/M5 pip
scoreboard relied on all of this (the original parked off-screen and spawned one
clone per point, each deriving its grid cell from its inherited `index`); **M7's
numeric HUD replaced that scoreboard**, so the clone primitives now ship unexercised
by the demo, the same way `stop "this script"` does — see
[Numeric HUD (M7)](#numeric-hud-m7).

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

The M5 best-of-N scoreboard exercised this: each pip clone was stamped with the
`round` it was born in and watched the global `round`; when the ball bumped `round`
at the start of a new round, every clone deleted itself and the board cleared.
**M7's numeric HUD retired the pip clones**, so `delete_this_clone` now ships
unexercised by the demo (alongside `stop "this script"`), and nothing reads `round`
anymore — the ball still bumps it harmlessly. The `round`-driven board-clear is
preserved here as the documented design; see [Numeric HUD (M7)](#numeric-hud-m7)
for what replaced it and why the freeze logic had to change.

### On-screen text (M6)

[scripts/font.gd](scripts/font.gd) is a `PixelFont`: it loads `font.png` once and
`render(text, color, size)`s a string into a fresh transparent `ImageTexture`,
copying each white glyph pixel from the atlas as `color`. The atlas stacks two
**faces**, each a two-row grid of `A–Z` then `0–9`:

| face | glyph | spacing | letters y | digits y |
| --- | --- | --- | --- | --- |
| `"small"` (default) | 3×5 | 1px | 0 | 6 |
| `"large"` | 5×9 | 2px | 16 | 27 |

Within a face, glyphs step every `(cell + spacing)`px along a row and each row
steps one line below the last (so the digit row's y follows from the letter row's).
`render` uppercases letters, honors `"\n"`, and leaves a glyph-sized gap for a space
or any unsupported character. The `"large"` face exists so text can be drawn at the
**viewport's own resolution** — big enough to read without scaling the sprite up
(which the tiny `"small"` face needs to be legible). The Stage builds one shared
`PixelFont` (like the target registry — a runtime resource every sprite reaches,
never reloaded per sprite) and exposes it via `font()`.

The **`say`** block makes that text a sprite's *costume*: it stringifies its input,
renders it through the Stage's font in the requested `size` face, and assigns the
result to the target node's texture, forcing nearest-neighbor filtering so glyphs
stay crisp if the sprite *is* scaled. Stringifying means a number reporter shows as
a numeric readout — the path to a real HUD — though this demo only uses literal banners.

The Announcer is why `stop "all"` **moved off the ball**: the freeze must land
*after* the banner is painted, and it must read the same rounds-won totals, so the
one script that knows how to draw the result is the one that ends the match. It
`say`s in the `"large"` face at scale 1 — the banner is drawn 1:1, never scaled up.
`say` sets the costume synchronously, then `stop "all"` flips the global flag in the
same frame — every coroutine (the Announcer included) unwinds, frozen with the banner up.

### Numeric HUD (M7)

M6 left `say` able to stringify a number reporter ("the path to a real HUD") but the
demo only painted literal banners and the score still showed as M4/M5's grid of clone
pips. M7 cashes that in: two **HUD** sprites (`P1Hud`, `P2Hud`) replace the pip
sprites at the same corners and run the project's smallest script —

```gdscript
[ when_flag_clicked → forever → say (variable score) in "large" ]
```

— so each readout re-renders its live score through the shared font every tick. There
is **no new opcode and no font change**: `say` already stringifies, and `0–9` were
already in the atlas. The HUD sprites carry no costume of their own (a transparent
1×1 placeholder, like the Announcer); `say` supplies one each tick, in white. Drawing
at the `"large"` face, scale 1, follows M6's no-scaling rule — a single digit is small
but legible at the viewport's own resolution.

The load-bearing change was in **`_on_round_won`**, not the HUD script. M5 zeroed both
scores *unconditionally* at every round-end and relied on the pip clones — which were
decoupled from the live score and only cleared on a `round` bump — to keep the final
pips up through the freeze. The HUD reads the *live* score, so unconditional zeroing
would freeze it showing "0 0" under the banner. The fix: move the score-zeroing
(and the `round` bump and re-serve) **inside** the `if rounds < ROUNDS_TO_WIN` branch.
A continuing round still zeroes (clearing the `score > ROUND_POINTS-1` condition so it
can't bank twice); the clinching round skips the branch, leaving the winning
`ROUND_POINTS` on screen while the ball loops harmlessly until the Announcer freezes
the game. (Re-rendering a costume 60×/sec is wasteful but matches Scratch's redraw
model and is fine for two one-digit readouts; guarding it to re-`say` only on change
is left as polish.)

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
| `go_to` | statement | `x`, `y` | sets position (inputs may be expressions); resets the ball, clamps paddles, parks the announcer/HUD |
| `wait_seconds` | statement | `seconds` | awaits a SceneTree timer; the serve delay |
| `touching_edge?` | reporter | `side` | true at a viewport edge; `side` ∈ {top,bottom,left,right,any}, default `any` |
| `touching_sprite?` | reporter | `name` | AABB overlap with the named sprite, resolved through the registry |
| `key_pressed?` | reporter | `key` | polls a key by name (`OS.find_keycode_from_string` → `Input.is_physical_key_pressed`). Use canonical names: `"W"`, `"S"`, `"Up"`, `"Down"` |
| `set_var` | statement | `name`, `value` | sets a variable (local-first, then global; unseeded → creates a global) |
| `change_var` | statement | `name`, `by` | adds `by` to a variable — the score increment |
| `say` | statement | `text`, `size` | renders `text` (stringified) through the bitmap font in the `size` face (`"small"` default / `"large"`) and sets it as the sprite's costume; the winner banner |
| `stop` | statement | `mode` | `"all"` halts every script (the game-over freeze); `"this script"` unwinds only the calling coroutine (clears its `_alive` flag) |
| `create_clone` | statement | `target` | only `"myself"` is supported: spawns a clone that inherits locals and runs the clone hats |
| `delete_this_clone` | statement | — | removes the running clone (frees its node, releases its interpreter); a no-op on an original |
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
font.png                   3x5-pixel bitmap font atlas (A-Z, 0-9); baked into a PixelFont
scripts/
  stage.gd                 Runtime root: builds sprites, owns the name->Target registry + shared font, runs scripts
  interpreter.gd           Tree-walking, coroutine-driven block interpreter + dispatch tables
  target.gd                Wraps the controlled node + its direction and name
  font.gd                  PixelFont: bakes font.png into rendered text costumes (the `say` block)
  pong_scripts.gd          The hardcoded Pong block scripts (two paddles, ball, two numeric HUDs, announcer), as data
CLAUDE.md                  This file
```

## Conventions for extending

- New block? Add a handler method and one entry in `_register_handlers()` in
  [scripts/interpreter.gd](scripts/interpreter.gd). Statements go in
  `_statement_handlers`; reporters/conditions go in `_reporter_handlers`.
- Keep blocks expressible as plain dictionaries/arrays — no UI assumptions, no
  bespoke classes per block.
- Any potentially long-running block must `await get_tree().physics_frame` (the
  fixed-rate logical tick — see the interpreter section) or a real-time timer, so
  it yields to the engine. Use the tick for per-frame motion, the timer for
  wall-clock waits.
- Cross-sprite blocks resolve other entities through the stage registry
  (`stage.find_target(name)`), never by reaching into the scene tree directly.
- Stay scoped to the current milestone; don't add block types beyond what the
  milestone calls for.

## Deliberately deferred (to a later milestone)

- **Deleting *another* sprite's clones / `create_clone` of a named sprite** —
  `create_clone` and `delete_this_clone` only act on `"myself"` / the running
  clone. Spawning or culling another target's clones needs the registry to track
  clones, not just originals.
- **Labelled HUD / string `join` / lowercase + punctuation** — M7's HUD shows a bare
  number; a labelled readout like `P1:5` needs a `join` reporter (to combine a literal
  with the score) and at least a colon glyph. The atlas still covers only `A–Z`/`0–9`,
  so labels, lowercase, and punctuation wait until a format actually needs them. (When
  added, the clean spot is extending each digit row rightward past `9` — no new atlas
  rows, no moving existing glyphs.)
- **Multi-digit HUD alignment** — the HUD sprite is centered, so a bare number growing
  from one digit to two would shift by half a glyph. This demo's scores are always one
  digit (reset at 5, rounds cap at 2), so it never surfaces; left-aligning a growing
  readout is deferred.
- **Event hats (`when_key_pressed`)** — needs an event-dispatch system. Polling
  `key_pressed?` inside `forever` stays within the existing loop model.

> Note: collision is axis-aligned box overlap (`Rect2.intersects`); a sprite's
> world box is centered on its node position (Sprite2D is centered by default).
