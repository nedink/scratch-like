# scratch-like — a Scratch-style game engine in Godot 4

A small visual-programming game engine, built in stages. The end goal is a
drag-and-drop block editor where you snap blocks onto sprites to script them.
We are building it runtime-first so the execution model is solid before any UI
exists.

## Current state: Milestone 11 — a palette to drag *new* blocks from

**Goal of this milestone:** let you **add blocks, not just rearrange them**. Through M10
the editor could only shuffle the blocks a sprite already had; M11 adds the missing
source — a **palette** of every stackable block type down the left side. Drag one out and
it rides the cursor and snaps into a stack exactly like an existing block, so a script
can now be assembled from scratch and RUN.

This is small because M9 already built the hard part. The palette **reuses M9's whole drag
machinery**: the one new ingredient is a **factory for fresh block dictionaries**,
[`BlockView.make_block(opcode)`](#block-palette-m11), which mints a block in exactly the
runtime shape with default inputs. When a press on a palette chip turns into a drag, the
palette hands that fresh block to [`BlockCanvas.begin_spawn_drag`](#block-palette-m11) and
the canvas owns the rest — ghost, snap highlight, and splice into the live data are
**unchanged** from M9. **No new opcode, no data-model change**, again.

The palette lists only **stackable** blocks (hats + statements + C-blocks); a reporter
pill has no valid drop target until dropping reporters into input *slots* exists (still
deferred). Each `BlockView._OPCODES` entry grew two fields — `kind` (so the palette can
filter) and `defaults` (a fresh block's starting inputs) — keeping the "add a block = one
table entry" story.

Edits still **persist for the session** (M10): switching sprites or RUN saves the canvas's
work — now including newly-added blocks — back into the editor's living project. (There
is no reset-to-pristine button yet, and editing a literal's *value* and dragging
reporters into slots are still ahead — see [Deliberately deferred](#deliberately-deferred-to-a-later-milestone).)

The editor remains the project's **front door**: F5 launches the editor (`editor.tscn`),
not the game; **RUN** switches to `main.tscn` (the Stage). **Editor chrome uses Godot's
built-in UI font, not the bitmap `PixelFont`**:
block labels need lowercase + punctuation (`move_steps`, `touching_edge?`, `>`), which
the atlas deliberately lacks. The "defer new glyphs" rule governs *in-game* rendered
text (sprite costumes via `say`), so editor tooling text is a separate layer that sits
outside it. See [Deliberately deferred](#deliberately-deferred-to-a-later-milestone).

## How to run

1. Open the **Godot 4.6** editor (this project uses the GL Compatibility
   renderer, so it runs on most hardware).
2. `Import` / open this folder (it already contains `project.godot`).
3. Press **F5** (Run Project). The main scene is now `editor.tscn`: the **block
   editor** opens, showing a **palette of new blocks** down the left, a sprite selector,
   and one sprite's script rendered as a stack of visual blocks (pick another sprite
   from the dropdown to load it).
   **Drag a block from the palette** (M11) to add a fresh one; it rides the cursor and
   snaps just like an existing block. **Drag a block already on the canvas** to pull it
   (and the blocks below it) out of its stack. Either way a yellow bar marks where it
   will snap, and dropping over that bar splices it into the stack (or into a C-block's
   body). Drop on empty canvas to leave it as a free-floating stack. Grab a hat (or the
   first block of a stack) to slide the whole stack around.
   Edits **persist** as you switch sprites (the session's project accumulates them);
   there's no reset-to-pristine yet, so relaunch the editor to start clean.
4. Click **RUN** in the editor's top bar to launch the game (`main.tscn`, the
   `Stage`). **RUN now plays your edited scripts** (M10) — each sprite runs your
   version, or the stock script if you didn't touch it. With no edits it plays the M7
   Pong exactly as before:
   A yellow ball serves from the center at a **randomized angle** and bounces off
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
1×1 placeholder, like the Announcer); `say` supplies one each tick, in white.

Like the Announcer's banner, the HUD draws at the `"large"` face, **scale 1** — no node
scaling, following M6's no-scaling rule. The digit is small at native size, but the
480×360 window is upscaled to fullscreen by a whole-number factor (`scale_mode="integer"`),
so every source pixel maps to an N×N block and the native glyph reads cleanly; `say`
forces nearest-neighbor filtering so it stays crisp. (An earlier pass scaled the HUD
nodes up to fight thin strokes vanishing; that was a non-integer-stretch artifact and
the integer-scaled 480×360 viewport makes it unnecessary — the digit is plenty visible
at native scale.)

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

### Block renderer (M8)

The first piece of the **editor**. [scripts/block_view.gd](scripts/block_view.gd) is
the **drawing counterpart to the interpreter**: where `interpreter.gd` tree-walks a
script (an `Array` of `{opcode, inputs}` dicts, substacks nested under `"inputs"`) to
*execute* it, `BlockView` walks the **same data** to render it as a tree of Godot
`Control` nodes. No data-model change was needed — the blocks were already "exactly
the shape a visual editor would emit", so this milestone is purely additive.

The renderer is **table-driven, mirroring the interpreter's dispatch table**.
`interpreter.gd` registers `opcode → handler Callable`; `BlockView._OPCODES` registers
`opcode → {category, template}`, where `template` is a label string with
`{input_name}` placeholders (`"move {steps} steps"`, `"{a} > {b}"`). Adding a block to
the editor is one `_OPCODES` entry — the same one-line extension story the runtime
has. `_CATEGORY_COLORS` gives each category Scratch's palette colour (motion blue,
control gold, sensing cyan, operators green, variables orange, looks purple, events
yellow).

The recursion mirrors the interpreter's, too:

- a stack (`Array`) → `build_stack` (cf. `_run_stack`) → a `VBoxContainer`;
- a statement → `build_block` → a category-coloured `PanelContainer`; for the
  C-blocks `forever`/`if`, the `body` is rendered as an **indented nested stack**
  inside the same panel so the "C" wrap reads, while a **hat's** body flows directly
  beneath its header at the same indent (hats are stack roots, not C-blocks);
- a reporter input (a dict with `"opcode"`) → `build_reporter` → an inline rounded
  pill that **recurses into its own inputs to any depth** (cf. `_evaluate`), so the
  ball's serve angle `90 + (pick random -45 to 45)` draws as nested pills;
- a literal input → `build_input` → a small white field (shared `_stringify` drops a
  whole-number float's `.0`, matching the interpreter).

A C-block body is **not** a placeholder in the template — it is rendered separately
and indented; only value/condition inputs are placeholders. Block shapes are
approximated with `StyleBoxFlat` corner radii (pill = reporter, light corners =
statement); true Scratch notch/hexagon geometry is cosmetic and deferred.

[scripts/editor.gd](scripts/editor.gd) is the scene root (the `editor.tscn` front
door), parallel to `stage.gd`: it builds its UI **in code** (a bare root `Control` +
script, like `main.tscn` is a bare `Node2D` + `stage.gd`). It holds a name→script
list (a small duplicate of the wiring in `stage.gd._ready`; a later milestone where
the editor *owns* the project model would unify them), a sprite-selector
`OptionButton` that loads the chosen script into the canvas, and a **RUN** button that
hands off to the game via `get_tree().change_scene_to_file("res://main.tscn")`. A small
theme `default_font_size` keeps the chunky blocks legible inside the integer-stretched
480×360 viewport. As of M9 the canvas itself is a [`BlockCanvas`](#block-canvas-m9)
(inside a `ScrollContainer` so a tall script is reachable), not a one-shot
`BlockView` render.

### Block canvas (M9)

[scripts/block_canvas.gd](scripts/block_canvas.gd) is the **interactive drawing
surface** — the editor going from read-only to hands-on. It owns the dragging; M8's
`BlockView` stays the pure renderer it feeds.

**Data is still the source of truth.** A drag never reparents `Control` nodes; it
**mutates the block data and re-renders**, the editor-side echo of the interpreter
mutating the same arrays as it runs. This works because `BlockView` now stamps `meta`
on what it draws (the M9 addition): each statement panel carries `blk_array` (the live
`Array` it lives in) + `blk_index`, and each stack column carries `body_array`. Since
GDScript arrays are references, that meta **is** the data:

- **Pick up** (`_begin_drag`): the deepest block under the cursor is `slice`d — *with
  its successors*, Scratch's "the rest of the stack comes with you" rule — out of its
  `blk_array`. The detached blocks ride the cursor as a translucent **ghost**.
- **Snap** (`_nearest_gap`): every `body_array` column yields insertion gaps (before
  each block, after the last, and the interior of an empty C-block body — which
  `BlockView` now draws as a small slot so it has area). The nearest gap within
  `SNAP_DISTANCE` is marked with a yellow bar.
- **Drop** (`_drop`): over a gap, the ghost's blocks `insert` into that gap's live
  array; on empty canvas, they become a new free-floating top-level stack. Then
  `_render()` rebuilds from the (now-mutated) data.

A block's **position** is the editor's own UI state — a `Vector2` per top-level stack,
held in `BlockCanvas`, kept *out* of the block dictionaries so the data stays exactly
the runtime's shape. `load_script` deep-duplicates the chosen script, so the canvas
edits its own working copy; the editor persists that copy back per sprite (M10, below).

Two input subtleties: dragging is driven from `_input` (which runs before GUI input)
with manual global-coordinate hit-testing, and rendered blocks are set to
`MOUSE_FILTER_IGNORE`, so nested panels never intercept the press and the mouse wheel
still reaches the `ScrollContainer`. A 4px threshold distinguishes a drag from a click.
Only statement blocks snap; a **hat-led** grab (or grabbing a stack's first block)
carries the whole stack and only repositions — a hat can't sit mid-stack.

### Running the edited script (M10)

The editor's first six milestones drew/edited blocks but RUN always launched the
hardcoded game. M10 makes RUN play the **edited** project, and it is small precisely
because M9 kept the data canonical:

- [`BlockCanvas.export_script()`](scripts/block_canvas.gd) flattens the working stacks
  back into a flat `Array` of top-level block dictionaries — the same shape
  `interpreter.run` consumes — dropping the editor-only `(x, y)` position. (A hat-led
  stack contributes its hat, whose body already nests the run; a loose stack
  contributes its blocks as top-level siblings.)
- [scripts/editor.gd](scripts/editor.gd) treats its `_scripts` list as the **living
  project**: `_persist_current()` exports the canvas back into the selected entry
  before each sprite switch and before RUN, so edits accumulate for the session.
- RUN deep-duplicates the project into **`Stage.project_scripts`**, a `static var`
  (a plain value can't cross `change_scene_to_file`), then switches scenes.
- [scripts/stage.gd](scripts/stage.gd)'s `_script_for(name, default)` reads that dict
  per sprite, **falling back to `PongScripts`** when the editor supplied nothing — so
  running `main.tscn` directly (no editor) still plays stock Pong, and a sprite you
  never opened runs its original script. The static outlives any one Stage instance,
  exactly like the scripts it carries.

The Stage still builds the same sprites (names, positions, seeded variables) — only the
*scripts* swap — so edited blocks resolve the same sprite names and variables they did
in the editor.

### Block palette (M11)

The last piece of the editor's core loop: a **source of new blocks**. M9 made existing
blocks draggable and M10 ran the result, but you could still only rearrange what a sprite
already had. M11 adds a palette down the left side and is small because it **reuses M9's
drag machinery whole** — it is a chooser + a hand-off, not a second drag implementation.

- **The factory.** [`BlockView.make_block(opcode)`](scripts/block_view.gd) returns a fresh
  `{opcode, inputs}` dict in exactly the runtime shape, its `inputs` deep-copied from the
  opcode's `defaults` (so every spawn owns its own inputs dict / `body` array — no shared
  references). This is the one genuinely new thing M11 needed.
- **Two new `_OPCODES` fields.** Each entry grew `kind` (`"hat"`/`"statement"`/
  `"reporter"`) and `defaults` (the starting inputs). `kind` lets the palette list only
  **stackable** blocks — `palette_groups()` filters out reporters, since a reporter pill
  has no drop target until slot-dropping exists (deferred). Rendering still ignores `kind`
  (HAT_OPCODES/C_OPCODES drive shape); it exists for the palette. Adding a block is still
  one table entry — now carrying its palette metadata too.
- **The hand-off.** [block_palette.gd](scripts/block_palette.gd) (`BlockPalette`, parallel
  to `BlockCanvas`) renders one chip per stackable opcode via the normal `build_block`, so
  a chip looks exactly like what lands on the canvas. It drives from `_input` with the same
  PENDING→threshold state machine and global hit-testing as the canvas; when a press on a
  chip becomes a drag it mints a fresh block and calls
  [`BlockCanvas.begin_spawn_drag(blocks, pos)`](scripts/block_canvas.gd). From there the
  **canvas owns the drag** — ghost, snap highlight (`_nearest_gap`), and the splice in
  `_drop` are unchanged from M9. A spawned hat becomes a free-floating stack; a spawned
  statement/C-block snaps. The palette consumes events only during its own PENDING window,
  so after the hand-off it never competes with the canvas for the drag's motion/release
  (correct whatever the sibling tree order).

[editor.gd](scripts/editor.gd) lays the workspace out as `palette | canvas`, each in its
own `ScrollContainer`, and wires `palette._canvas = canvas`. Persistence (M10) is
untouched: added blocks already live in the canvas data, so they ride `export_script()` →
`Stage.project_scripts` into RUN with no extra plumbing.

## Opcodes implemented

**M11 added no opcodes** (nor did M8/M9/M10) — the editor is a pure *view + interaction*
over the existing language. Every opcode below has a `BlockView._OPCODES` entry so it
draws; M9 makes every drawn block draggable; M11 lets you drag a fresh one in from the
palette (stackable kinds only); and M10 runs whatever you assemble from them.


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
project.godot              Godot project config; main scene = editor.tscn (M8); 480x360 window
editor.tscn                Main scene (M8): a bare root Control running editor.gd — the editor front door
main.tscn                  The *game* scene: a single Node2D "Stage" running stage.gd (launched by the editor's RUN button)
icon.svg                   Default project icon (skeleton)
font.png                   3x5-pixel bitmap font atlas (A-Z, 0-9); baked into a PixelFont
scripts/
  editor.gd                Editor root (M8): sprite selector + RUN; lays out palette | canvas, persists edits + hands them to the Stage on RUN (M10)
  block_canvas.gd          Interactive canvas (M9): drag/snap/detach — mutates block data + re-renders; begin_spawn_drag() accepts palette blocks (M11); export_script() serializes edits back (M10)
  block_palette.gd         Block palette (M11): lists stackable opcodes as chips; on drag, mints a fresh block and hands it to the canvas
  block_view.gd            Block renderer (M8): tree-walks block data into a Control tree; opcode->{category,template,kind,defaults} table; make_block() factory (M11); tags it for M9 dragging
  stage.gd                 Runtime root: builds sprites, owns the name->Target registry + shared font, runs scripts (edited via project_scripts, else PongScripts — M10)
  interpreter.gd           Tree-walking, coroutine-driven block interpreter + dispatch tables
  target.gd                Wraps the controlled node + its direction and name
  font.gd                  PixelFont: bakes font.png into rendered text costumes (the `say` block)
  pong_scripts.gd          The hardcoded Pong block scripts (two paddles, ball, two numeric HUDs, announcer), as data
CLAUDE.md                  This file
```

## Conventions for extending

- New block? Add a handler method and one entry in `_register_handlers()` in
  [scripts/interpreter.gd](scripts/interpreter.gd). Statements go in
  `_statement_handlers`; reporters/conditions go in `_reporter_handlers`. **Also add
  one `_OPCODES` entry** in [scripts/block_view.gd](scripts/block_view.gd) so the editor
  can draw it — the symmetric one-line step. That entry carries `category` + label
  `template` (drawing) plus `kind` and `defaults` (M11): set `kind` to `"hat"`/
  `"statement"` and give sensible `defaults` for it to appear in the palette as a fresh
  draggable block; a `"reporter"` is drawn but stays out of the palette (no slot-drop
  yet). An opcode with no entry still renders, as a grey box.
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

- **Editing a literal's *value* (the natural M12)** — typing into a white input field
  (`move {5}` → `move {8}`) isn't wired; the runtime runs the blocks as-drawn, so values
  are whatever the loaded script or a palette block's `defaults` provided. Needs an
  in-place text field on the literal widget. This is the obvious next step now that M11
  lets you add a block but only with its default inputs.
- **Reset edits to pristine** — edits persist for the session and there's no per-sprite
  "revert" or whole-project reset; relaunching the editor reloads the stock scripts.
- **Dragging reporters / blocks into input slots** — M9 snaps *statement* blocks into
  stacks only. Dropping a reporter pill into a value/condition slot (e.g. changing
  `move {speed}` to `move {speed + 1}`) needs slot hit-testing and the hexagon/round
  shape geometry below. Reporter pills are drawn but not yet grabbable.
- **Canvas panning / auto-scroll while dragging** — the canvas sits in a
  `ScrollContainer` (wheel/scrollbar scroll a tall script), but there's no click-drag
  panning of empty canvas and no auto-scroll when a drag reaches the viewport edge.
- **True Scratch block geometry** — the editor approximates block/reporter/boolean
  shapes with `StyleBoxFlat` corner radii; real connector notches and hexagonal
  booleans are cosmetic. M9's snapping uses gap *proximity* (a yellow bar), not precise
  notch connection points, so this can keep waiting.
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
