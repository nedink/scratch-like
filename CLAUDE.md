# scratch-like — a Scratch-style game engine in Godot 4

A small visual-programming game engine, built in stages. The end goal is a
drag-and-drop block editor where you snap blocks onto sprites to script them.
We are building it runtime-first so the execution model is solid before any UI
exists.

## Current state: Milestone 25 — rename a sprite (the cross-script cascade)

**Goal of this milestone:** let you **rename a sprite from the editor**, the last piece of making the
M24 sprite model fully editable (M24 added / deleted sprites but couldn't rename one). It is the
**sprite analog of M21's variable rename**: a single name change has to **cascade** through everything
that refers to the sprite by name. As part of the same cascade it also pays off M24's standing
deferral — **stripping dangling `touching_sprite?` references** to a *deleted* sprite. **No new opcode,
no block-data-shape change, no runtime change** — the cascade is an editor-side rewrite of the same
block data the runtime reads, exactly as M21 was for variables.

A sprite name is referred to in **three** places, and a rename must touch all three (where a variable's
name in M21 was touched in only the scripts that referenced it):

- **The selector + the model entry.** [`editor._on_rename_sprite_confirmed`](scripts/editor.gd) updates
  the sprite's `_scripts` entry `name` and the [`OptionButton`](editor.tscn) item text in place.
- **Every `touching_sprite?` reference, across *all* scripts.** Unlike a variable (whose rename is
  *scoped* — a local renames only its own sprite, a global skips a shadowing sprite, M21's
  `_is_referent_for`), a **sprite name is globally unique**, so the cascade is **unscoped**: any sprite
  may touch any other, so *every* script is rewritten. The current sprite is rewritten **in place** via
  [`BlockCanvas.rename_sprite`](scripts/block_canvas.gd) (so canvas positions survive, the M21
  reasoning); the rest via [`BlockView.rewrite_sprite_refs`](scripts/block_view.gd) on `_scripts[i]`.
- **Every variable `scope` field equal to the sprite.** A sprite's **locals** are scoped *by its name*
  (M18's `{name, value, scope}`), so they must follow the rename or they'd dangle, scoped to a sprite
  that no longer exists. The confirm rewrites each `_variables` entry whose `scope` matches.

After the cascade the editor re-points [`BlockView.project_sprites`](scripts/block_view.gd) (the
`touching` dropdown options) and the re-scoped [`project_variables`](scripts/block_view.gd) (the renamed
sprite's locals are still in scope under the new name), rebuilds the palette, and refreshes the canvas —
all **in place**, no full reload, so positions hold (the M21 trio). Blank / unchanged / duplicate names
are rejected silently (names are the project's target registry, so they must stay unique).

- **The cascade walkers, on `BlockView`.** Three statics mirror M21's variable walkers, sharing the same
  one tree-recursion shape (a block dict; nested reporter inputs; `body` substacks):
  [`count_sprite_refs`](scripts/block_view.gd) (tally), [`rewrite_sprite_refs`](scripts/block_view.gd)
  (rename), [`strip_sprite_refs`](scripts/block_view.gd) (remove). The opcode set is
  [`_SPRITE_OPCODES`](scripts/block_view.gd) `== ["touching_sprite?"]` — the only block that names
  another sprite. Because `touching_sprite?` is **always a reporter** (never a statement), `strip` never
  *drops* a block; it reverts the `touching {name}?` reporter to its **host opcode's default** literal
  for that slot (M15's `slot_default` rule), so `if (touching Ghost?)` becomes `if true` once `Ghost` is
  gone.
- **Delete now strips, not dangles.** [`_on_del_sprite_confirmed`](scripts/editor.gd) runs
  `strip_sprite_refs` over every surviving script after dropping the sprite (and its locals), so no
  block names a sprite that's gone — Scratch's behaviour, and M24's explicit deferral, now paid off.
  The confirm dialog ([`_del_sprite_pressed`](scripts/editor.gd)) reports the `touching` reference count
  it will clear (over the *surviving* scripts) alongside the local-variable count, the M21
  delete-with-a-count pattern. (The deleted sprite's own self-references aren't counted — its whole
  script goes wholesale.)

What this leaves deferred: **editing a sprite's starting geometry from the UI** (position / size /
colour) — a sprite is still placed by a `go_to` block in its script (behaviour is blocks), so there is
no on-stage drag or inspector. The **stock project data** still lives in `PongScripts` (both ends read
`sprites()` / `variables()`), the same shared-seed arrangement as since M18.

---

For context, the M24 mechanics this builds on:

- **Sprites are a data-owned, editable model (M24).** The sprite set is one model
  ([`PongScripts.sprites()`](scripts/pong_scripts.gd) — `{name, x, y, w, h, color, script}` per sprite)
  that both the runtime and the editor read; the editor's `_scripts` *is* that model, and **+ Sprite /
  − Sprite** add and delete sprites. M25 makes that model's last operation — **rename** — editable too,
  and turns M24's dangling-`touching`-reference deferral into a strip; see [Sprites are a data-owned,
  editable model (M24)](#sprites-are-a-data-owned-editable-model-m24).

For context, the M23 mechanics this builds on:

- **Boolean-vs-value slot typing (M23).** The editor refuses a mismatched reporter drop — a `boolean`
  reporter into a value slot or vice-versa — via an `output` / `bool_inputs` pair on each `_OPCODES`
  entry and a `slot_type` filter in [`_nearest_slot`](scripts/block_canvas.gd). M24 adds no slots or
  reporters, so the typing is unaffected; see [Boolean-vs-value slot typing
  (M23)](#boolean-vs-value-slot-typing-m23).

For context, the M22 mechanics this builds on:

- **Save & open (M22).** The editor owns the whole project model (`_scripts`/`_variables`) and writes it
  to disk as JSON via a `FileDialog` ([`_write_project`](scripts/editor.gd) / [`_read_project`](scripts/editor.gd)),
  with the in-code **demo** ([`_seed_demo`](scripts/editor.gd)) as the always-available default that NEW
  returns to. M23 doesn't touch persistence — a type-checked drop is the same block data, saved the same
  way.

For context, the M19 + M18 + M17 mechanics this builds on:

- **Scoped dropdowns (M19).** [`_variables_in_scope(sprite_name)`](scripts/editor.gd) keeps a
  variable when its `scope` is `"global"` **or** equals the sprite — so M20's new local shows only
  under the sprite it was made for. The renderer is unchanged; scoping is the editor choosing which
  names to hand [`BlockView.project_variables`](scripts/block_view.gd).
- **One project model (M18).** [`PongScripts.variables()`](scripts/pong_scripts.gd) returns an
  `Array` of `{name, value, scope}` dicts (`scope` ∈ {`"global"`, a sprite name}) — the single
  source both the Stage seeds from and the editor lists. M19 reads the `scope` field M18 added.
- **Data-scoped dropdowns (M17).** An optional **`data_enums` field** on an `_OPCODES` entry maps
  `input_key -> source` (source ∈ {`"variables"`, `"sprites"`}); the `{name}` slots of
  `variable`/`set_var`/`change_var` map to `"variables"`, `touching_sprite?`'s to `"sprites"`.
  [`BlockView._options_for`](scripts/block_view.gd) resolves a slot's options (a fixed `enums` list
  wins, else a `data_enums` source → the matching project list, else `[]`) and feeds them to
  [`build_input`](scripts/block_view.gd), which builds the **same `_enum_field` dropdown** M13's
  fixed-choice slots use. The static [`BlockView.project_variables`](scripts/block_view.gd) /
  `project_sprites` hold the lists; M19 changed *which variables that list holds* (scoped to the
  sprite, not all of them), not how the slot renders it.
- **Graceful fallback.** When the model is empty (the palette built before the editor sets it, or
  any non-editor caller), `_options_for` yields `[]` and the slot falls back to the M12 text field.
  A current value not among the options is appended + selected, so nothing snaps away silently.

---

For context, the M13 mechanics this builds on — both live in `BlockView`'s table:

- **Enum slots** are declared by one optional `enums` field per `_OPCODES` entry —
  `input_key -> [allowed values]` (`stop {mode}` → `["all", "this script"]`, `say … in
  {size}` → `["small", "large"]`, `create clone of {target}` → `["myself"]`, `touching
  {side} edge?` → `["any", …]`). [`BlockView.build_input`](#enum-dropdowns-and-typed-slot-shapes-m13)
  renders such a slot as an `OptionButton` ([`_enum_field`](#enum-dropdowns-and-typed-slot-shapes-m13))
  instead of a `LineEdit`; the canvas wires its `item_selected` to write the chosen text
  back into the same live `inputs` dict, exactly as it wires a literal field's commit. An
  opcode with no `enums` keeps the M12 text field. A value not in the list (from a
  hand-written script) is appended + selected so it stays visible rather than snapping away.
- **Typed shapes**: [`BlockView._literal_field`](#enum-dropdowns-and-typed-slot-shapes-m13)
  now takes the slot's value type and picks its corner radius — a fat radius (oval) for
  `int`/`float`, a slight one (rectangle) for everything else. The signal is the slot's
  *current* value type, the same thing `coerce_literal` keys off, so a numeric slot holding
  the `"bounce"` sentinel (a String) reads as text — consistent with how that value coerces.

**No new opcode, no data-model change** — again. The dropdown stores a plain string and the
shape is pure cosmetics, so persistence (M10) and RUN carry M13's edits with no extra
plumbing. Coercion ([`BlockView.coerce_literal`](#editing-literal-values-m12)) is unchanged
and still governs the free-text fields; enum values need none (they're always strings).

(M14 above made the slot accept a *dropped reporter*; the field/dropdown still edits a literal
in place.) Edits still **persist for the session** (M10). See
[Deliberately deferred](#deliberately-deferred-to-a-later-milestone).

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
   **Add or remove a sprite** (M24) with the **+ Sprite** / **− Sprite** buttons beside the selector:
   *+ Sprite* names a new sprite (it starts as a grey square at the stage centre with an empty script —
   give it a `when_flag_clicked` and blocks, and a `go_to` to place it); *− Sprite* deletes the selected
   one along with its local variables (the last sprite can't be deleted). New sprites and deletions are
   part of the project, so RUN reflects them and **SAVE** keeps them across relaunch.
   **Rename a sprite** (M25) with the **Rename Sprite** button beside those: type a new name and the
   change cascades everywhere the sprite is referred to — the selector, every `touching {name}?` block
   across *all* sprites' scripts (a sprite name is global, so the whole project updates), and the
   `scope` of every variable local to that sprite (its locals follow it). A name already in use is
   refused (sprite names must stay unique). Deleting a sprite now also **clears any `touching` references**
   to it (the dialog says how many) — `if (touching Gone?)` reverts to `if true` — so no block names a
   sprite that's gone.
   **Drag a block from the palette** (M11) to add a fresh one; it rides the cursor and
   snaps just like an existing block. **Drag a block already on the canvas** to pull it
   (and the blocks below it) out of its stack. Either way a yellow bar marks where it
   will snap, and dropping over that bar splices it into the stack (or into a C-block's
   body). Drop on empty canvas to leave it as a free-floating stack. Grab a hat (or the
   first block of a stack) to slide the whole stack around.
   **Click a white input field** (M12) to edit its value — type a new number/word and
   press Enter (or click away) to commit it into the block; e.g. change `move {10}` to
   `move {8}`. (Clicking the field edits it; grab the coloured part of a block to drag it.)
   **Numeric slots are oval, text slots rectangular** (M13), so a number field and a word
   field read apart at a glance. A slot that is really a **fixed choice** (`stop {mode}`,
   `say … in {size}`, `create clone of {target}`, `touching {side} edge?`) is a **dropdown**
   (M13) — click it and pick a value instead of typing one. The **`{name}` slots** of
   `set`/`change`/`variable` and `touching {name}?` are dropdowns too (M17), but listing the
   project's **actual** variables / sprites — so you pick a real `p1_score` or `Ball` rather than
   risk a typo that only fails at RUN. The variable menus are **scoped to the sprite you're
   editing** (M19): globals plus that sprite's own locals, so the Ball's `speed` shows only while
   editing the Ball and is hidden from the paddles — switch sprites and the menus (and the palette's
   variable chips) re-scope to match.
   **Make a new variable** (M20) with the **Make a Variable** button at the top of the palette's
   VARIABLES group: click it, type a name, choose *For all sprites* (a global) or *For this sprite
   only* (a local of the sprite you're editing), and confirm. The new name appears immediately in
   every `{name}` dropdown (scoped like the rest) and is **seeded to 0** when you RUN.
   **Rename or delete a variable** (M21) from its row in that same VARIABLES group: beneath the button
   each in-scope variable is listed as a button — click it and pick **Rename** (type a new name; it
   updates everywhere it's used, your canvas layout unchanged) or **Delete** (a dialog reports how
   many references it has; confirming removes the variable *and* its references — `set`/`change` blocks
   go, and a `(variable)` reporter reverts its slot to a default, so `move (speed)` becomes `move 10`).
   Delete is permanent — there's no undo (relaunch reloads the stock set). The rows re-scope per sprite
   like the dropdowns. (A variable's *initial value* is always 0 — Scratch's model; a non-zero start is
   a `set` block in the script, which you can edit on the canvas.)
   **Drag a reporter from the palette into a slot** (M14) to drop an *expression* in — the
   palette now lists reporters (`+`, `score`, `touching … edge?`, …) as pills; drag one over
   a value/condition slot (a highlight marks the slot it will land in) and release to make,
   e.g., `move {10}` into `move {score}`. The slot's old value is replaced; a reporter
   dropped anywhere but a slot is discarded.
   **Slots are typed** (M23): a **boolean** reporter (the rounded-off, angular pills — `>`, `touching
   edge?`, `and`) drops only into a **boolean** slot (an `if` condition, an `and`/`or`/`not` operand),
   and a **value** reporter (the round pills — `+`, `score`) only into a **value** slot (`move`'s steps,
   `set`'s value). Drag one over a slot of the wrong kind and **no slot highlights** — Scratch's
   hexagon-vs-round refusal — and releasing there discards the pill (like releasing off any slot). The
   pill's shape tells you which slots will take it.
   **Grab a reporter that's already in a slot** (M15) to pull it back out — press the
   coloured body of a pill and drag; the slot reverts to its default value (`move {score}`
   back to `move {10}`), and you can drop the pill into another slot or release it over empty
   canvas to throw it away. (A bare `score`/`variable` pill is almost all input field, so grab
   it by its thin coloured border; wider pills like `+` grab anywhere on the body. Pressing a
   pill's white field still edits that field.)
   **Delete a block** (M16) by dragging it **back onto the palette** and releasing — the same
   region you drag new blocks *from* doubles as the trash. Grab a statement block (it carries
   the blocks below it) or a reporter pill, drag it left over the palette — the ghost turns
   **red** to show it will be deleted (no snap bar / slot highlight) — and let go. Drop anywhere
   *off* the palette instead to place it as usual. (There's no undo; relaunch to reload a
   sprite's stock script.)
   Edits **persist** as you switch sprites (the session's project accumulates them).
   **Save your project** (M22) with **SAVE** in the top bar: pick a name and **location** in the file
   browser (it opens at the project folder by default, but you can save anywhere) and it writes a
   `.json` file, so your work survives relaunch. **OPEN** browses to reload a saved project; **NEW**
   returns to the stock **demo** (the in-code Pong) — the demo is never a file, so it is always there
   and your saved projects are never overwritten by it (or it by them). The title bar shows the open project's name (`(demo)` when unsaved). NEW/OPEN replace the
   working project, discarding unsaved canvas edits (there's no undo — SAVE first); launch always lands
   on the demo. (Canvas *layout* isn't saved — a reopened project re-flows its stacks to default
   positions, as a sprite switch already does.)
4. Click **RUN** in the editor's top bar to launch the game (`main.tscn`, the
   `Stage`). **RUN now plays your edited scripts** (M10) — each sprite runs your
   version, or the stock script if you didn't touch it. Press **ESC** in-game to
   return to the editor (the inverse of RUN's editor→game hand-off). With no edits it
   plays the M7 Pong exactly as before:
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
door), parallel to `stage.gd`. Its **fixed-shape chrome** — the backdrop, the top bar, the
`palette | canvas` workspace, and the three variable dialogs (Make / Rename / Delete) — is
**declared in `editor.tscn`** (it was built in code through an earlier pass; nothing about that
layout is data-driven, so it moved to the scene editor). The script reaches those nodes by
unique name (`%Canvas`, `%VarDialog`, …) and supplies only the dynamic parts: the selector's
items (from the script list), the signal wiring, and the dialog logic. The *contents* of the
palette and canvas — generated from block data — stay in code, as does `stage.gd`'s sprite set
(that set is headed for the data-owned project model, not the scene editor). It holds a name→script
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

### Editing literal values (M12)

The core authoring loop's last gap: M11 let you *add* a block but only with its `defaults`
inputs. M12 makes those inputs editable, and is small because M9 already made the block data
canonical — editing a value is just another mutation of the same arrays the runtime reads.

- **The field becomes editable.** [`BlockView._literal_field`](scripts/block_view.gd) — a
  static `Label` through M11 — is now a `LineEdit` (white, grows to its text, small minimum
  width). `build_input(inputs, key)` (its signature widened from a bare value) stamps the
  field with the **live `inputs` dict + `key`** as meta, so whoever wires it can write the
  typed value straight back into that dict. Reporter inputs still render as pills, so nested
  literals (e.g. the ball's `pick random {-45} to {45}`) are editable too.
- **The canvas owns the mutation** (mirroring M9's "the canvas splices into the data"). After
  each `_render`, [`BlockCanvas._wire_literals`](scripts/block_canvas.gd) connects every
  field's `text_submitted`/`focus_exited` to `_commit_literal`, which coerces the text and
  assigns `inputs[key]`. Since `inputs` is the same reference held in the canvas's working
  stacks, the edit rides `export_script()` → persistence/RUN for free. The **palette leaves
  its chip fields inert** (`editable = false`, mouse-ignored) — a chip is a throwaway
  template; editing happens only once a block lands on the canvas.
- **Coercion matches the interpreter.** [`BlockView.coerce_literal(text, prev)`](scripts/block_view.gd)
  is directed by the slot's previous type: a numeric slot keeps a number (int when whole —
  the interpreter `float()`s it regardless), a bool slot maps `true`/`false`, and anything
  else stays a `String`. Non-numeric text in a numeric slot also stays a string, which keeps
  the `point_in_direction` `"bounce"` sentinel expressible. After commit the field is
  re-`_stringify`'d so `"8.0"`/`" 8 "` settle to `"8"`.
- **Edit vs. drag.** Rendered blocks are mouse-ignored so `_input` can hit-test presses, but
  the literal field is left `MOUSE_FILTER_STOP` (via a `keep_literals` flag on
  `_passthrough`) so it can take focus and clicks. On press, the canvas checks `_over_literal`
  first: a hit there falls through to the field (GUI focus + typing); a press anywhere else on
  the block grabs it to drag and first calls `gui_release_focus()` to commit any active edit.
  This is Scratch's own split — the input slot captures clicks, the body is the drag handle.

Enum-ish slots (`stop {mode}`, `say … in {size}`) were plain text fields in M12, not
dropdowns — **M13 gives them dropdowns** (below). The field still edits a value in place; it
doesn't yet accept a *dropped* reporter pill (deferred). See
[Deliberately deferred](#deliberately-deferred-to-a-later-milestone).

### Enum dropdowns and typed slot shapes (M13)

The two halves of M12's "make every literal as free text" deferral, paid off together. Both
are table-driven additions to `BlockView` — no opcode, no data-model change — so they ride
M9's data-is-canonical spine and M12's wire-the-widget-back-to-the-data machinery untouched.

- **Enum dropdowns.** An optional **`enums` field** on an `_OPCODES` entry maps
  `input_key -> [allowed values]` for slots that are a fixed choice: `stop {mode}` ∈
  {`all`, `this script`}, `say … in {size}` ∈ {`small`, `large`}, `create clone of {target}` =
  {`myself`}, `touching {side} edge?` ∈ {`any`, `top`, `bottom`, `left`, `right`}.
  [`BlockView._header_from_template`](scripts/block_view.gd) looks the entry's `enums` up and
  passes the key's options into [`build_input`](scripts/block_view.gd), which — when the
  options are non-empty — builds an `OptionButton`
  ([`_enum_field`](scripts/block_view.gd)) instead of the M12 `LineEdit`. The dropdown carries
  the **same `lit_inputs`/`lit_key` meta** a literal field does, so the canvas treats it the
  same: [`BlockCanvas._wire_literals`](scripts/block_canvas.gd) connects its `item_selected`
  to `_on_enum_selected`, which writes the chosen option text straight into the live `inputs`
  dict (no coercion — enum values are always strings). A current value **not among the
  options** (an odd hand-written script) is appended and selected, so it stays visible and
  editable rather than silently snapping to option 0.
- **Typed slot shapes.** [`BlockView._literal_field`](scripts/block_view.gd) now takes the
  slot's **value type** and picks its corner radius: a fat radius (oval) for `int`/`float`, a
  slight radius (rectangle) for string/bool — Scratch's visual shorthand for number vs. text
  slots. The type read is the slot's *current* value type, the same signal `coerce_literal`
  is directed by, so the shape and the coercion always agree (a numeric slot holding the
  `"bounce"` String sentinel reads — and coerces — as text).

**Edit vs. drag and the palette are unchanged in spirit.** The dropdown is just another
widget stamped with `lit_key`, so it is already covered everywhere a literal field is:
[`BlockCanvas._over_literal`](scripts/block_canvas.gd) (now matching any `lit_key` Control,
not just `LineEdit`) defers a press on it to the GUI — so the dropdown opens / the field
focuses — instead of grabbing the block to drag; [`_passthrough`](scripts/block_canvas.gd)
keeps any `lit_key` node interactive; and the palette
([`BlockPalette._passthrough`](scripts/block_palette.gd)) leaves a chip's dropdown inert by
mouse-ignoring it (the literal field additionally gets `editable = false`).

M14 (below) pays off the first of these deferrals — a slot now accepts a dropped reporter.

### Reporter into slot (M14)

The editor's **second drop kind**, and the last piece of the core authoring loop (add →
arrange → edit → *compose*). M9 snapped statement blocks into stacks; M14 drops a reporter
into a value/condition slot, so a slot can hold an expression (`move {speed + 1}`), not only
a literal. It is small because it is a near-pure reuse of M11's pipeline (palette mints a
fresh block → `begin_spawn_drag` → the canvas owns ghost/highlight/drop) with a different
*target*, and **no runtime change** — the interpreter already evaluates nested reporter dicts.

- **Slots are uniform drop targets.** [`BlockView.build_input`](scripts/block_view.gd) now
  stamps `slot_inputs`/`slot_key` — the live `inputs` dict + key — on *every* widget it
  builds: the literal field, the enum dropdown, and (newly) the reporter pill. So
  [`BlockCanvas._slots`](scripts/block_canvas.gd) can collect any of them as a target, and a
  drop writes `inputs[key] = reporter` straight into the data (`inputs` is a reference — that
  write *is* the edit, the M9/M12 idiom). The editable `lit_inputs`/`lit_key` meta stays only
  on the field/dropdown: a reporter pill is a slot you can drop *onto*, but not a literal you
  type into, so the two metas are kept distinct.
- **The palette offers reporters.** [`BlockView.palette_groups`](scripts/block_view.gd)
  stops filtering out `kind == "reporter"` (it did so through M13 only because a reporter had
  nowhere to drop). [`BlockPalette`](scripts/block_palette.gd) renders a reporter chip as a
  pill (`build_reporter`, gated on [`BlockView.is_reporter`](scripts/block_view.gd)) so it
  matches what lands in a slot; the hand-off to `begin_spawn_drag` is otherwise identical.
- **The canvas branches on a reporter flag.**
  [`BlockCanvas.begin_spawn_drag`](scripts/block_canvas.gd) sets `_dragging_reporter` when the
  spawned block is a reporter (and ghosts it as a pill, not a stack). While set,
  [`_update_drag`](scripts/block_canvas.gd) finds the nearest *slot*
  ([`_nearest_slot`](scripts/block_canvas.gd), proximity via
  [`_dist_to_rect`](scripts/block_canvas.gd) — the same approximate hit-test M9 used for gaps,
  so true connector geometry stays deferred) and highlights its whole rect;
  [`_drop`](scripts/block_canvas.gd) writes the reporter into that slot. A reporter released
  **off every slot is discarded** — it has no top-level home the interpreter could run
  (unlike a statement stack, which lands on empty canvas as a free-floating stack); for the
  same reason [`_cancel_drag`](scripts/block_canvas.gd) discards a reporter rather than
  re-homing it.

Whatever the dropped reporter displaces is **discarded** (no eject/wrap), and any reporter
may drop into any slot (no boolean-vs-value typing — shape geometry is deferred). Grabbing a
reporter pill *already on the canvas* was deferred at M14 (the pills in existing scripts were
inert, so a press over one fell through to [`_block_at`](scripts/block_canvas.gd) and grabbed
the **statement** it sat in) — **M15 below pays that off**.

Deferred at M14 but **paid off in M17**: **dropdowns scoped to live data** — the `{name}` slots of
`variable`/`set`/`change` and `touching {name}?`, free text through M16, became dropdowns of the
project's actual variables/sprites once the editor took ownership of that model (see
[Data-scoped dropdowns (M17)](#data-scoped-dropdowns--the-editor-owns-the-project-model-m17)).

### Reporter out of slot (M15)

The mirror of M14, and the close of the reporter authoring loop: M14 *dropped* a fresh
reporter into a slot; M15 lets you **grab a reporter pill that's already in a slot** and pull
it out, to relocate or discard it. It is near-free because the entire `_dragging_reporter`
drag (ghost pill → highlight nearest slot → write/discard on drop) already exists from M14 —
M15 only adds the *pickup* that feeds it, the same way M9 added "pick up an existing statement"
on top of M8's renderer. **No new opcode, no data-model change.**

- **Pickup hit-test.** [`BlockCanvas._reporter_at`](scripts/block_canvas.gd) is the
  reporter-pill counterpart to [`_block_at`](scripts/block_canvas.gd): it walks the
  `slot_*`-tagged widgets (M14) and keeps only the slots whose `inputs[key]` is **currently a
  reporter dict** (literal fields / dropdowns hold plain values and are skipped), returning the
  **smallest-area** one. The press handler runs it **before** `_block_at`, so a pill is grabbed
  in preference to the statement it sits in, and a nested pill (`score` inside `add {score} {1}`)
  in preference to its wrapper. A press on a pill's *inner literal field* is still claimed by
  [`_over_literal`](scripts/block_canvas.gd) first (M12's edit-vs-drag split), so the field
  edits; only the pill's own body/border reaches `_reporter_at`.
- **Detach + restore.** A press that crosses the drag threshold with `_pending_reporter` set
  routes [`_begin_drag`](scripts/block_canvas.gd) into
  [`_begin_reporter_drag`](scripts/block_canvas.gd): it lifts the reporter dict out of the slot
  and writes the slot's **default literal** back into `inputs[key]`, then re-renders and falls
  into the shared drag. The default is a new third slot meta — `slot_default`, stamped by
  [`BlockView.build_input`](scripts/block_view.gd) from each opcode's `defaults` — so pulling a
  reporter out of `move {score}` leaves `move {10}`. (We never kept the literal the reporter
  *displaced* on the way in — M14 discarded it — so the opcode default is the principled stand-in.)
- **Drop / discard, reused whole.** From there nothing is new: [`_update_drag`](scripts/block_canvas.gd)
  and [`_drop`](scripts/block_canvas.gd) treat a grabbed-from-canvas reporter exactly like a
  palette spawn — re-drop into any slot (overwriting it, M14's rule), or release off every slot
  and it is **discarded** (a useful "drag to trash"; `_drop`'s off-slot branch is a no-op and
  the detached dict is simply not re-homed, the same as [`_cancel_drag`](scripts/block_canvas.gd)).

Still deferred (see [Deliberately deferred](#deliberately-deferred-to-a-later-milestone)): a
pill that is *all input field* — a bare `variable` — can only be grabbed by its thin coloured
border, since the slot widget takes the clicks over its area. (M17 turned that slot into a
data-scoped `OptionButton`, but it captures clicks just as the M12 `LineEdit` did, so the
full-body grab is **not** freed by that change after all — see the deferred list.)
**Ejecting/wrapping** the displaced reporter, and **boolean-vs-value slot typing**, remain
deferred as in M14.

### Delete a block (M16)

The last asymmetry in the core editing loop. Through M15 you could add blocks (palette → M11,
reporter into slot → M14), rearrange them (M9), and edit/compose them (M12–M15) — but a
statement block, once on the canvas, could never **leave** it; dragging it off only re-homed it
as a free-floating stack. A reporter, by contrast, had a trash from M14 (released off every slot
→ discarded). M16 gives statements the same and unifies the gesture: **drag a block back over
the palette and release to delete it** — exactly how Scratch deletes. **No new opcode, no
data-model change** — pickup already detached the blocks from the data, so a delete is `_drop`
*not re-homing* them, and the deletion rides `export_script()` → persistence/RUN like any edit.

- **The palette doubles as the trash.** [editor.gd](scripts/editor.gd) sets the canvas's new
  `_trash` field to the palette's `ScrollContainer` (beside the existing `_palette._canvas`
  hand-off). The region you drag *new* blocks **from** is the region you drag unwanted ones
  **onto** — no new chrome, and discoverable because the palette is always present, as in Scratch.
- **Hit-test + cue.** [`BlockCanvas._over_trash`](scripts/block_canvas.gd) is true when the
  cursor is inside `_trash`'s global rect (the same global space as the event positions used
  throughout — cf. [`_block_at`](scripts/block_canvas.gd) / [`_over_literal`](scripts/block_canvas.gd)).
  [`_update_drag`](scripts/block_canvas.gd) recomputes `_trashing` each frame: over the palette it
  **suppresses the snap** (so no gap bar / slot highlight competes) and tints the ghost **red** to
  signal a delete-on-release rather than a placement.
- **The delete.** [`_drop`](scripts/block_canvas.gd) gains a leading `if _trashing: pass` branch:
  the grabbed blocks are already off the data, so doing nothing *is* the delete, and the re-render
  reflects their absence. One branch covers both kinds — a statement stack (the new capability)
  and a reporter pill (already discarded off-slot; the palette is just off-slot, now with the red
  cue and an explicit landing zone). [`_cancel_drag`](scripts/block_canvas.gd) is untouched — an
  *abandoned* drag (only on a sprite switch, M9) still re-homes its stack, since abandoning isn't
  choosing to trash.

Still deferred (see [Deliberately deferred](#deliberately-deferred-to-a-later-milestone)): **undo**
(a deleted stack is gone until relaunch, as with any session edit — M10) and a **dedicated trash
affordance** (the palette serves as one).

### Data-scoped dropdowns — the editor owns the project model (M17)

M13 gave the *fixed-choice* slots dropdowns from a static `enums` list, but left the `{name}`
slots of `variable`/`set_var`/`change_var` and `touching {name}?` as **free text** — the doc's
most-referenced deferral, because a real menu there must list the project's *actual* variables /
sprites, and those lived only in the Stage. M17 gives the **editor its own project model** and
renders those slots as **data-scoped dropdowns** sourced from it. It is the *data-scoped sibling*
of M13: same [`_enum_field`](#enum-dropdowns-and-typed-slot-shapes-m13) widget, same `lit_*`
write-back — only the *options* now come from project data. **No new opcode, no data-model
change**: the dropdown stores the same plain string the field did, so persistence (M10) and RUN
carry it untouched.

- **The model, editor-owned.** [editor.gd](scripts/editor.gd) declares the project's variable
  names (`_PROJECT_VARIABLES`, mirroring the seeds in [`stage.gd`](scripts/stage.gd)`._ready` —
  the same small duplication as its `_scripts` list) and derives the sprite names from `_scripts`
  (`_sprite_names`). In `_ready`, **before** the palette builds or the canvas first renders, it
  sets the new static vars [`BlockView.project_variables`](scripts/block_view.gd) /
  `project_sprites` — static (like `Stage.project_scripts`) so the *static* render path reaches
  the value from one place.
- **One new `_OPCODES` field: `data_enums`.** `input_key -> source`, source ∈
  {`"variables"`, `"sprites"`} — the data-scoped twin of M13's literal `enums`.
  [`BlockView._options_for`](scripts/block_view.gd) resolves a slot's options (fixed `enums` wins;
  else a `data_enums` source → the matching project list; else `[]`) and
  [`_header_from_template`](scripts/block_view.gd) feeds it into
  [`build_input`](scripts/block_view.gd), which builds the **same dropdown** M13 already did — so
  the canvas's [`_on_enum_selected`](scripts/block_canvas.gd) write-back is **unchanged**. The
  matching `defaults` were repointed at real names (`"p1_score"`; `touching` → `"Ball"`) so a
  freshly-spawned block lands on a valid menu item, not a phantom appended value.
- **Graceful fallback, by construction.** An empty model (the palette built before the editor
  sets it, or any non-editor caller) makes `_options_for` yield `[]`, and the slot falls back to
  the M12 text field exactly as before M17. A current value **not** among the options (a
  hand-written name) is still appended + selected by `_enum_field` (M13's rule), so a stock script
  referencing only real names (`p1_score`, `round`, …) renders clean dropdowns while an odd name
  stays visible rather than snapping away.

Still deferred *at M17* (see [Deliberately deferred](#deliberately-deferred-to-a-later-milestone)):
the model is **flat** (no global-vs-local scoping — every variable shows for every sprite) and
**read-only** (no "make a variable" entry — you pick existing names, you can't mint new ones).
**M19 fixed the flatness (scoping) and M20 the read-only-ness (Make a Variable)**, both below. The
`_PROJECT_VARIABLES` const above was M17's; **M18 (below) unified it** with the Stage's seeds, so
the editor no longer declares variable names separately. And the data-scoped menu did **not** free
the full-body grab of a bare `variable` pill — an `OptionButton` captures clicks just as the
`LineEdit` did, so that pill is still grabbed by its thin coloured border (M15).

### One project model feeds both the editor and the runtime (M18)

M17's data-scoped dropdowns needed a list of the project's variable names, and the editor declared
one (`_PROJECT_VARIABLES`) — but the runtime *also* declared the variables, separately, when
`stage.gd._ready` seeded them. Two hardcoded copies, and they had **drifted in shape**: `round`
was seeded at `1` in the Stage but carried no value in the editor's list, and `speed` was a flat
name in the editor but a **Ball local** in the Stage. M18 collapses both into one declaration. It
is small because `PongScripts` is already the project-data file both ends read (both call
`PongScripts.left_paddle()` etc.), so the variables belong there beside the scripts. **No new
opcode, no data-model change, no UI change** — the dropdowns offer the same names, the runtime
seeds the same variables; only the *source* is unified.

- **One model declaration.** [`PongScripts.variables()`](scripts/pong_scripts.gd) returns an
  `Array` of `{name, value, scope}` dicts; `scope` is `"global"` or a **sprite name** (a
  per-sprite local). The single source of truth, replacing the two that disagreed.
- **The runtime seeds from it.** [stage.gd](scripts/stage.gd)`._ready` loops the model: a
  `"global"` entry → `set_var(name, value)`; a sprite-scoped one →
  `find_target(scope).variables[name] = value` (e.g. the ball's `speed`). An entry scoped to an
  unknown sprite `push_warning`s rather than crashing. The explicit `set_var(...)` /
  `ball.variables["speed"] = …` lines M3–M7 hardcoded here are gone.
- **The editor derives names from it.** [editor.gd](scripts/editor.gd) maps the model to its names
  for [`BlockView.project_variables`](scripts/block_view.gd); the `_PROJECT_VARIABLES` const is gone.
  The M17 dropdown machinery (`data_enums`, `_options_for`, `_enum_field`) is **untouched** — it
  just reads a list sourced from the unified model now. (As of M19 that mapping is
  [`_variables_in_scope(sprite_name)`](scripts/editor.gd), filtering by `scope`; through M18 it was
  the argument-free, flat `_variable_names`.)

What M18 unblocks but does **not** deliver: carrying **scope in the data** is the prerequisite for a
later **"make a variable"** entry (mint a name the runtime will seed) and **local-vs-global scoping**
(hide a sprite's locals from other sprites). **M19 delivered the scoping half and M20 the "make a
variable" half** (both below); what stays is the **scripts** still being duplicated in spirit (both
editor and Stage call the `PongScripts` builders) — M18 unified the *variables*, not that.

### Variable dropdowns scoped to the selected sprite (M19)

M18 put `scope` in the variable model (`{name, value, scope}`) explicitly as the prerequisite for
two unlocks; M19 cashes in the **scoping** one. Through M18 the `{name}` dropdowns were **flat** —
every variable for every sprite — so editing the LeftPaddle offered the Ball's `speed` (a Ball
*local*), which Scratch never does: a sprite can't see a sibling's local. M19 scopes the dropdowns
to the sprite being edited. It is small because M18 left the model carrying the `scope` field and
M17 left the renderer listing whatever names it's handed — so M19 only changes *which* names the
editor hands it, per sprite. **No new opcode, no data-model change, no runtime change** (the runtime
already stores locals per-target, so they were never visible there — this is the *editor* choosing
which names to offer).

- **The editor scopes the list per sprite.** [editor.gd](scripts/editor.gd)'s
  [`_variables_in_scope(sprite_name)`](scripts/editor.gd) (was the flat, argument-free
  `_variable_names`) keeps a variable when its `scope` is `"global"` **or** equals `sprite_name`,
  dropping other sprites' locals. [`_show`](scripts/editor.gd) re-points
  [`BlockView.project_variables`](scripts/block_view.gd) to this scoped list on **every** sprite
  switch, *before* the canvas renders, so the menus always match the sprite on screen. `_ready`
  seeds it for the first sprite (index 0) so the palette's first build is already scoped.
- **The palette re-scopes too.** The palette's `variable`/`set_var`/`change_var` chips draw the same
  `{name}` dropdown, so [`BlockPalette.rebuild()`](scripts/block_palette.gd) (new — frees the chip
  children synchronously and re-runs `_build`) re-renders the chip list whenever the editor
  re-scopes. So the *whole* UI, palette included, hides a sprite's siblings' locals — not just the
  canvas. Spawned blocks default to a global (`p1_score`), so a freshly dragged block always lands
  on an in-scope name whatever the sprite.
- **The renderer is untouched.** [`BlockView`](scripts/block_view.gd) still just lists whatever
  `project_variables` holds; scoping is a property of the *list the editor builds*, not of how a
  slot renders it. `project_sprites` is **not** scoped — every sprite is a valid `touching` target.
  An out-of-scope name in a hand-written script still renders visibly (M13's append-the-unknown
  rule survives), so scoping *hides* options, it never silently drops a value already in use.

Still deferred (see [Deliberately deferred](#deliberately-deferred-to-a-later-milestone)): the model
stays **read-only** — you pick from the now-scoped existing names, with no "make a variable" entry to
mint a new local or global from the UI. That was M18's *other* unlock, and it waits. **M20 (below)
delivered it.**

### Make a variable (M20)

M18 carried `scope` in the data as the prerequisite for **two** unlocks; M19 spent the scoping half,
and M20 spends the other — **minting a variable from the editor**. Through M19 the `{name}` dropdowns
listed the project's real, scoped variables but the model was **read-only**: creating one meant
editing [`PongScripts.variables()`](scripts/pong_scripts.gd) by hand. M20 adds Scratch's **"Make a
Variable"** affordance. Unlike M17–M19 it *does* touch the runtime — but only the **seeding source**,
not any opcode or block-data shape.

The load-bearing change is that the variable model becomes an **editor-owned mutable store carried
into the runtime**, mirroring M10's `Stage.project_scripts` exactly — because
[`PongScripts.variables()`](scripts/pong_scripts.gd) returns a *fresh array each call*, there was no
store to append to:

- **The editor owns a mutable copy.** [editor.gd](scripts/editor.gd) seeds `_variables` from
  `PongScripts.variables().duplicate(true)` in `_ready` (M19 and earlier read it live each call —
  fine while read-only). [`_variables_in_scope`](scripts/editor.gd) now filters *this* per sprite.
- **The button + dialog.** [`BlockPalette._build`](scripts/block_palette.gd) draws a real `Button`
  atop the variables group — a normal GUI button, **not** a draggable chip: it carries no
  `palette_opcode`, so the palette's `_input`/`_chip_at` hit-test skips it and never starts a drag,
  and its click reaches GUI as usual. It is wired (via `_palette._on_make_variable`, an editor-set
  `Callable`; unset → no button, so non-editor callers stay buttonless) to
  [`editor._make_variable`](scripts/editor.gd), which pops a `ConfirmationDialog` with a name
  `LineEdit` and a scope `OptionButton` (*For all sprites* → `"global"` / *For this sprite only* →
  the edited sprite's name). On confirm, [`_on_new_variable_confirmed`](scripts/editor.gd) appends
  `{name, value: 0, scope}` (Scratch starts a variable at 0), then re-points
  [`BlockView.project_variables`](scripts/block_view.gd), rebuilds the palette
  ([`BlockPalette.rebuild`](scripts/block_palette.gd), M19) and re-renders the canvas
  ([`BlockCanvas.refresh`](scripts/block_canvas.gd), new — `_render()` without touching the data, so
  positions hold and any open `{name}` dropdown picks up the new option). A blank name, or one
  **already in scope** for this sprite, is rejected silently: the in-scope check forbids shadowing a
  name the sprite can already see; a *sibling's* local (which it can't see) is fine to reuse, as in
  Scratch.
- **The runtime seeds the made variable.** [`editor._on_run`](scripts/editor.gd) hands `_variables`
  to the new static [`Stage.project_variables`](scripts/stage.gd) (deep-duplicated, like the
  scripts). [stage.gd](scripts/stage.gd)`._ready` seeds from
  [`_variable_model()`](scripts/stage.gd) — that carried model when present, else
  `PongScripts.variables()` — the variables counterpart of M10's `_script_for`/`project_scripts`, so
  launching `main.tscn` directly (no editor) still seeds stock Pong.

Still deferred at M20 (see [Deliberately deferred](#deliberately-deferred-to-a-later-milestone)):
**renaming or deleting** a variable from the UI (M20 mints, it can't yet edit-or-remove) — **M21
(below) delivered both** — and persistence past the session — `_variables` resets to stock on
relaunch, like every session edit (M10). With both of M18's unlocks now spent, the remaining
duplication is the **scripts** (editor and Stage both call the `PongScripts` builders), which M18
explicitly did not address.

### Rename / delete a variable (M21)

M20 made the variable model **mint-only**: you could append a name but never **rename or remove** one
without editing [`PongScripts.variables()`](scripts/pong_scripts.gd) by hand. M21 makes it fully
editable — the palette's VARIABLES group lists each **in-scope** variable as a manageable row offering
**Rename** / **Delete**. It is small because it reuses M20's mutable `_variables`, the M19 scoped
list, and the rebuild/refresh trio. Like M19, and unlike M20, it **does not touch the runtime**:
rename feeds the seed model *and* the blocks new names; delete drops the seed entry *and* strips the
blocks' references (Scratch's behavior — no dangling name is left). **No new opcode, no
block-data-shape change.**

- **The palette rows + menu.** Beneath the M20 "Make a Variable" button,
  [`BlockPalette._build`](scripts/block_palette.gd) adds one
  [`_make_variable_row`](scripts/block_palette.gd) per name in
  [`BlockView.project_variables`](scripts/block_view.gd) (the M19 per-sprite scoped list) — a
  `MenuButton` (so the popup positions itself) labelled with the variable's name, its menu offering
  Rename (id 0) / Delete (id 1). Like the make button it carries **no** `palette_opcode`, so the drag
  hit-test ([`_chip_at`](scripts/block_palette.gd)) skips it and GUI handles the click. The choice
  routes through [`_on_variable_menu`](scripts/block_palette.gd) to two editor-set callbacks
  (`_palette._on_rename_variable` / `_on_delete_variable`); both unset → no rows, so non-editor
  callers are unaffected. [`BlockPalette.rebuild`](scripts/block_palette.gd) (M19) already re-renders
  the rows on every sprite switch, so they re-scope for free.
- **One block-tree walk, factored onto `BlockView`.** The cascade is a single recursion over the
  `{opcode, inputs}` tree (a block dict; its `inputs` values may be nested reporter dicts; `body` is a
  nested array — the same shape `build_stack`/`build_block`/`build_input` already walk).
  [`BlockView.count_variable_refs`](scripts/block_view.gd) tallies,
  [`BlockView.rewrite_variable_refs`](scripts/block_view.gd) renames, and
  [`BlockView.strip_variable_refs`](scripts/block_view.gd) removes every
  `variable`/`set_var`/`change_var` (the `_VARIABLE_OPCODES`) whose `inputs.name` matches. Both
  callers — the canvas and the editor — share these.
- **Rename: scoped, and position-preserving.** [`editor._on_rename_confirmed`](scripts/editor.gd)
  validates (blank / unchanged / already-in-scope rejected silently, mirroring the make guard),
  updates the model entry's `name`, then rewrites every script where this variable is the in-scope
  *referent*. The **current** sprite goes through
  [`BlockCanvas.rename_variable`](scripts/block_canvas.gd), which rewrites the working `_stacks`
  **in place** and re-renders — so canvas positions survive, unlike a `load_script` reload (the M20
  `refresh()` reasoning). Every other affected script is rewritten directly via
  `BlockView.rewrite_variable_refs` on `_scripts[i]`. The scope test
  ([`_is_referent_for`](scripts/editor.gd)): a **local** renames only its own sprite; a **global**
  renames everywhere *except* a sprite that shadows the name with its own local (there the name means
  the local — [`_sprite_has_local`](scripts/editor.gd)). Then the M20 trio (re-point
  `project_variables`, `rebuild()`, `refresh()`) so every menu, chip, and dropdown shows the new name.
- **Delete: confirm with a count, strip the references.**
  [`editor._delete_variable`](scripts/editor.gd) persists the canvas, sums
  `count_variable_refs` over the same scoped scripts, and pops a `ConfirmationDialog` reporting the
  count. On confirm, [`_on_delete_confirmed`](scripts/editor.gd) strips the references where this
  variable is the in-scope referent (same `_is_referent_for` scoping as rename) — the current sprite
  in place via [`BlockCanvas.delete_variable_refs`](scripts/block_canvas.gd) (positions preserved),
  the rest via `BlockView.strip_variable_refs` — then removes the `_variables` entry.
  `set_var`/`change_var` statements are dropped from their stack; a `variable` reporter reverts its
  slot to the host opcode's default literal (so `move (speed)` → `move 10`), leaving the host block.
  No dangling name remains (Scratch's behavior). Delete is **destructive** — there is no undo stack
  (M16), so the dialog states the count first; relaunch reloads the stock set.

Still deferred (see [Deliberately deferred](#deliberately-deferred-to-a-later-milestone)): **editing a
stock variable's initial value** (still a `PongScripts.variables()` edit), the **full-body grab** of a
bare `variable` pill (M21's menu sits on the *palette rows*, not a canvas-pill right-click — so that
pill is still grabbed by its thin border, M15). **Persistence past the session** was M21's standing
deferral; **M22 (below) delivered it.** The **scripts** remain duplicated in spirit (editor and Stage
both call the `PongScripts` builders), as since M18.

### Save & open named projects (M22)

Persistence, deferred since M10: through M21 every edit reset to stock on relaunch. The editor already
**owned the whole project model** (`_scripts` from M10, `_variables` from M20), and the block model was
**already serializable** ("exactly the shape a visual editor would emit"), so M22 just writes that model
to disk as JSON and reads it back — a **file browser** for **named project files**, with the in-code demo
kept as the always-available default. **No new opcode, no block-data-shape change, no runtime change**:
the Stage's M10/M20 static hand-off (`project_scripts` / `project_variables`) is untouched — persistence
is an editor-side disk ⇄ model concern that feeds the same RUN path.

- **The chrome.** [editor.tscn](editor.tscn) adds three top-bar buttons — **NEW** / **OPEN** / **SAVE**
  — beside RUN, one shared `%FileDialog`, and a unique name on `%Title` so it can show the bound
  project's name. [editor.gd](scripts/editor.gd) wires them in `_ready` (once, like the other signals)
  and configures the dialog: `access = ACCESS_FILESYSTEM` (browse the whole disk — the user picks where
  a project lives), a `*.json` filter, non-native (renders in the engine window like the M20/M21 dialogs).
- **The demo is in-code, never a file.** [`_seed_demo`](scripts/editor.gd) — the stock-project seeding
  extracted from the original `_ready` — loads PongScripts into `_scripts` / `_variables`. `_ready`
  lands on it each launch; [`_on_new`](scripts/editor.gd) returns to it (clearing `_current_path`)
  without touching disk. So the demo can't be overwritten and saved `.json` files are left untouched —
  the answer to "preserve the demo *and* accumulate saved work."
- **One dialog, two actions** (the rename/delete state-var idiom). [`_on_save`](scripts/editor.gd) and
  [`_on_open`](scripts/editor.gd) set the dialog's `file_mode`, record `_file_action`, and pop it at the
  bound file's folder (else the project-dir default, [`_default_browse_dir`](scripts/editor.gd) —
  runtime FileDialog has no remembered default, so we set one explicitly); SAVE pre-fills `_current_path`
  so re-saving is SAVE → confirm-overwrite. [`_on_file_selected`](scripts/editor.gd) routes the pick to
  write or read. Paths are absolute OS paths under filesystem access; `FileAccess`/`JSON` handle them the
  same as a `res://` path would.
- **Write / read, validated.** [`_write_project`](scripts/editor.gd) calls `_persist_current()` first,
  then `JSON.stringify({"scripts": _scripts, "variables": _variables}, "\t")` (tab-indented, human-
  readable) to the path and binds it. [`_read_project`](scripts/editor.gd) parses and **guards** — a
  non-dictionary, or a missing / non-array `scripts` or `variables`, is `push_warning`'d and ignored, so
  a corrupt or hand-edited file keeps the current project rather than crashing — then swaps in the model
  and rebuilds the UI.
- **One bring-up path.** [`_load_project_into_ui`](scripts/editor.gd) (shared by launch, NEW, OPEN)
  repopulates the sprite selector, re-points `BlockView.project_sprites`, updates the title, and shows
  sprite 0 — first setting `_current = -1` so `_show`'s leading `_persist_current()` can't write the
  *outgoing* canvas into the freshly loaded `_scripts` (`_show` then re-scopes the variables, rebuilds
  the palette, and loads the canvas, M19's path).

Still deferred (see [Deliberately deferred](#deliberately-deferred-to-a-later-milestone)): **canvas
layout** isn't persisted — `export_script` drops each stack's `(x, y)` (editor-only UI state the runtime
shape never carried), so a reopened project re-flows to default positions, exactly as a sprite switch
already does; **delete / rename of a saved file** from the browser, **autosave**, and **opening the last
project on launch** (launch always lands on the demo) are unbuilt. JSON's single number type means a
saved `10` reads back `10.0` — harmless, as above. The **scripts** stay duplicated in spirit (editor and
Stage both call the `PongScripts` builders), as since M18.

### Boolean-vs-value slot typing (M23)

The deferral M14 opened: it let *any* reporter drop into *any* slot (a number into an `if` condition, a
boolean into `move`'s `steps`) because, as M14 noted, refusing mismatches "needs the true connector
geometry" and the runtime coped regardless. M23 pays off the **refusal** without the geometry — Scratch
distinguishes hexagonal boolean slots from round value slots, and now so does the editor. It is small
because M14/M15 already made every input slot a tagged drop target (`slot_*` meta) and the canvas already
selects the nearest one — M23 only assigns each slot and each reporter a **type** and filters by it.
**No new opcode, no block-data-shape change, no runtime change** — the type lives in the editor's
`_OPCODES` table and gates only what a drop *lands in*; the interpreter still evaluates any reporter in
any position (so a hand-written / loaded script with a "wrong" reporter still runs, it just couldn't be
*assembled* that way in the editor now).

- **The model: two optional `_OPCODES` fields** ([block_view.gd](scripts/block_view.gd)), the
  slot-typing pair, declared the same one-line way as M13's `enums` / M17's `data_enums`:
  - `output` — a reporter's value kind. `"boolean"` for the `?`-suffixed sensing reporters
	(`touching_edge?`, `touching_sprite?`, `key_pressed?`) and the comparison/boolean operators
	(`equals`, `greater_than`, `less_than`, `and`, `or`, `not`); default `"value"` for arithmetic,
	`random`, and `variable`. ([`reporter_output_type`](scripts/block_view.gd) reads it.)
  - `bool_inputs` — the input keys whose slots *expect* a boolean: `if` → `condition`, `and`/`or` →
	`a`,`b`, `not` → `a`. Every other slot is a value slot. (Note `and`/`or`/`not` are both boolean
	*outputs* and boolean *inputs*, so the booleans compose only with booleans, as in Scratch.)
- **Stamp + expose.** [`build_input`](scripts/block_view.gd) stamps each widget's expected kind as a
  `slot_type` meta — computed in [`_header_from_template`](scripts/block_view.gd) from the host opcode's
  `bool_inputs` (so the meta is a property of the *containing slot*, independent of what currently fills
  it: replacing a comparison inside an `if` still requires a boolean). It joins the `slot_inputs`/
  `slot_key`/`slot_default` metas M14/M15 already stamp.
- **Enforce.** [`BlockCanvas._nearest_slot`](scripts/block_canvas.gd) skips any slot whose `slot_type`
  ≠ the dragged reporter's `output` before the existing proximity / smallest-area selection — so a
  boolean reporter highlights and lands only in boolean slots, a value reporter only in value slots. A
  mismatched hover finds no slot, so no highlight appears and a release there **discards** the reporter,
  reusing M14's off-slot path verbatim (no new drop outcome). Pickup ([`_reporter_at`](scripts/block_canvas.gd))
  is untouched — pulling a reporter *out* is type-agnostic; the check governs only where it goes back in.
- **The shape cue.** [`build_reporter`](scripts/block_view.gd) gives a **boolean** pill a tight
  (angular) corner radius where a **value** pill stays round — the same corner-radius shorthand M13 used
  for number (oval) vs text (rectangle) literal fields. So which slots will accept a dragged pill reads
  at a glance: only the like-shaped ones highlight. True hexagon/notch geometry, and the precise
  connection points, stay deferred (the match is still rectangular *proximity*).

Still deferred (see [Deliberately deferred](#deliberately-deferred-to-a-later-milestone)): **true Scratch
block geometry** (corner-radius approximations, proximity snapping); **ejecting / wrapping** a displaced
reporter (a matching drop onto an occupied slot still discards the old, M14); and the **full-body grab**
of an all-field pill (M15). The **scripts** remain duplicated in spirit, as since M18.

### Sprites are a data-owned, editable model (M24)

The last hardcoded pillar of the project model, made data. The editor owned the **scripts** (M10),
**variables** (M18/M20), and **persistence** (M22), but the sprite set — names, starting positions,
sizes, colours — lived only in [`stage.gd`](scripts/stage.gd)`._ready` as six literal `_add_sprite`
calls, with the editor merely *deriving the names* from its script list. M24 is the **sprite counterpart
of M18**: one model both the runtime and editor read, plus Add / Delete from the UI. **No new opcode, no
block-data-shape change, no interpreter change.**

- **The model.** [`PongScripts.sprites()`](scripts/pong_scripts.gd) returns an `Array` of
  `{name, x, y, w, h, color, script}` — placeholder geometry + script per sprite (a sprite owns its
  scripts). `color` is a **hex string** so the model is JSON-clean for SAVE/OPEN (M22); `stage.gd`
  parses it with `Color(hex)`. The geometry is exactly what M2–M7 hardcoded. This is the single
  declaration both ends read — the sibling of `variables()` (M18).
- **The runtime builds from it.** [stage.gd](scripts/stage.gd)`._ready` loops
  [`_sprite_model()`](scripts/stage.gd) (the editor's `Stage.project_sprites` when handed one, else
  `PongScripts.sprites()` — the M10/M20 fallback, so a direct `main.tscn` launch still builds stock
  Pong): **pass 1** builds every placeholder *before* the variable seed (a sprite-scoped local needs
  its target to exist); **pass 2** (after the viewport-ready frame) runs each entry's script. M10's
  `project_scripts` / `_script_for` are **retired** — the script lives inside each sprite entry now.
- **The editor owns it, mutably.** [editor.gd](scripts/editor.gd)'s `_scripts` *is* this model
  (`_seed_demo` seeds it from `PongScripts.sprites().duplicate(true)`); [`_persist_current`](scripts/editor.gd)
  overwrites only `["script"]`, so geometry survives a switch / RUN, and [`_on_run`](scripts/editor.gd)
  hands the whole model over as `Stage.project_sprites` (deep-copied, like the variable model).
- **Add / Delete (the payoff).** Top-bar **+ Sprite** / **− Sprite** buttons pop dialogs:
  [`_on_new_sprite_confirmed`](scripts/editor.gd) appends `{name, default geometry, script: []}` (a
  grey square at centre with no script — Scratch's new sprite) and lands the selector on it (via
  [`_load_project_into_ui(select_index)`](scripts/editor.gd), its new optional arg);
  [`_on_del_sprite_confirmed`](scripts/editor.gd) removes the entry **and** every variable scoped to it
  (its locals), refusing the last sprite. Names must stay unique (they are the target registry). A new
  sprite positions itself with a `go_to` block (behaviour is blocks), so no in-UI move/resize yet.
- **Persistence is unchanged in shape.** Save still writes `{scripts, variables}` (M22); the `scripts`
  entries simply carry geometry now. [`_read_project`](scripts/editor.gd) runs
  [`_normalize_sprite`](scripts/editor.gd) to default any missing geometry, so a **pre-M24** saved file
  still opens.

Still deferred at M24 (see [Deliberately deferred](#deliberately-deferred-to-a-later-milestone)):
**renaming a sprite** (a cross-script cascade — selector + every `touching_sprite?` ref + every variable
`scope` — the sprite analog of M21's variable rename) and **stripping dangling `touching` refs** to a
deleted sprite (part of that cascade) — **both delivered by M25 (below)**; and **editing a sprite's
starting geometry from the UI** (set position with a `go_to` block instead), which stays deferred. The
stock data still lives in `PongScripts`, the shared-seed arrangement since M18 — now through one
`sprites()` call.

### Rename a sprite (M25)

M24 made the sprite set add/deletable but **mint-or-remove only** — you could not **rename** a sprite
without editing [`PongScripts.sprites()`](scripts/pong_scripts.gd) by hand, and a deleted sprite left
**dangling `touching_sprite?` references** behind. M25 makes the sprite model fully editable, the
**sprite analog of M21's variable rename**: a top-bar **Rename Sprite** button cascades a new name
across everything that names the sprite, and sprite *delete* now strips the references it leaves. It is
small because it reuses M21's machinery wholesale — the shared block-tree walk factored onto `BlockView`,
the current-sprite-in-place-via-the-canvas rule, the rebuild/refresh trio. Like M21, it **does not touch
the runtime**. **No new opcode, no block-data-shape change.**

- **The cascade walkers, on `BlockView`.** Three statics mirror M21's `count`/`rewrite`/`strip` over the
  one `{opcode, inputs}` tree (nested reporter inputs; `body` substacks):
  [`count_sprite_refs`](scripts/block_view.gd), [`rewrite_sprite_refs`](scripts/block_view.gd), and
  [`strip_sprite_refs`](scripts/block_view.gd) (with helper
  [`_strip_sprite_input_refs`](scripts/block_view.gd)). The opcode set
  [`_SPRITE_OPCODES`](scripts/block_view.gd) is just `["touching_sprite?"]` — the only block naming a
  sprite (its `data_enums` maps `name -> "sprites"`). Because `touching_sprite?` is **always a reporter**
  (never a statement, unlike `set_var`/`change_var`), `strip` never *drops* a block; it reverts the
  reporter to its host opcode's **default** literal for that slot (M15's `slot_default`), so
  `if (touching Ghost?)` becomes `if true`. Both callers — the canvas and the editor — share these.
- **Rename: globally unscoped, position-preserving.** [`editor._on_rename_sprite_confirmed`](scripts/editor.gd)
  validates (blank / unchanged / already-a-sprite-name rejected silently, mirroring M24's add guard),
  updates the model entry's `name`, **re-scopes every variable local to the sprite** (a local's `scope`
  *is* the sprite name — M18 — so it must follow the rename), then rewrites every script. Where M21
  scoped the cascade per referent (`_is_referent_for` — a local renames only its sprite, a global skips a
  shadowing sprite), a **sprite name is globally unique**, so M25 rewrites **every** script unconditionally
  (any sprite can touch any other). The **current** sprite goes through
  [`BlockCanvas.rename_sprite`](scripts/block_canvas.gd) (rewrites the working `_stacks` **in place** and
  re-renders, so canvas positions survive — the M21 reasoning); every other script via
  `BlockView.rewrite_sprite_refs` on `_scripts[i]["script"]`. Then the chrome + menus update **in place**
  — the selector item text ([`OptionButton.set_item_text`](editor.tscn)), `BlockView.project_sprites`,
  the re-scoped `project_variables` (the renamed sprite's locals are still in scope, now under the new
  name), [`BlockPalette.rebuild`](scripts/block_palette.gd), and [`BlockCanvas.refresh`](scripts/block_canvas.gd)
  — so no full reload, no layout reshuffle.
- **Delete: strip the dangling references.** [`editor._on_del_sprite_confirmed`](scripts/editor.gd) now,
  after dropping the sprite entry and its locals, runs `BlockView.strip_sprite_refs` over **every
  surviving script** — so no `touching_sprite?` names a sprite that's gone (M24 left these dangling, to
  resolve null → false at RUN; M25 reverts them, Scratch's behaviour). It strips directly on each
  `_scripts` entry rather than in place on the canvas, because a delete always navigates to a surviving
  neighbour whose canvas reloads from scratch anyway. The confirm dialog
  ([`_del_sprite_pressed`](scripts/editor.gd)) now reports the `touching` reference count it will clear
  (over the *surviving* scripts — the deleted sprite's own self-references vanish with its script, so
  they aren't counted) alongside M24's local-variable count, the M21 delete-with-a-count pattern.
- **The chrome.** [editor.tscn](editor.tscn) adds a **Rename Sprite** top-bar button beside + / − Sprite
  and a `RenameSpriteDialog` (a name `LineEdit`), declared and reused like the New/Delete sprite dialogs;
  [editor.gd](scripts/editor.gd) wires them in `_ready`, pre-fills the dialog with the selected sprite's
  name on [`_rename_sprite_pressed`](scripts/editor.gd), and stashes it in `_renaming_sprite` (the
  confirmed signal carries no payload — the same state-var idiom the variable rename and sprite delete
  dialogs use).

Still deferred (see [Deliberately deferred](#deliberately-deferred-to-a-later-milestone)): **editing a
sprite's starting geometry from the UI** (position / size / colour) — a sprite is still placed by a
`go_to` block in its script (behaviour is blocks), so there is no on-stage drag or inspector. The
**scripts** (now sprite entries) remain shared-seed in spirit (editor and Stage both read
`PongScripts.sprites()`), as since M18/M24.

## Opcodes implemented

**M25 added no opcodes** (nor did M8/M9/M10/M11/M12/M13/M14/M15/M16/M17/M18/M19/M20/M21/M22/M23/M24) — the editor is a
pure *view + interaction* over the existing language, and M25 makes the **sprite name** editable
(rename a sprite, cascading the change across scripts; strip a deleted sprite's references) without
touching the block language. Every opcode below has a
`BlockView._OPCODES` entry so it draws; M9 makes every drawn block draggable; M11 lets you drag a fresh
one in from the palette (M14 extends the palette to **reporters** too); M12 lets you edit any literal
input's value (M13 shapes the field by type and turns the fixed-choice slots into dropdowns, M17 the
`{name}` slots into dropdowns of the project's real variables/sprites, M19 **scoping** those
variable menus to the selected sprite, M20 letting you **make a new variable** from the palette and
M21 **rename or delete** one from its palette row);
M14 lets you **drop a reporter into a value/condition slot** and M15 lets you **grab one back
out** (M23 making that drop **type-aware** — a boolean reporter only into a boolean slot, a value only
into a value slot); M16 lets you **delete a block by dragging it onto the palette**; and M10 runs whatever
you assemble from them (M24: across whatever sprites the project now has — M25: which you can also rename).


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
editor.tscn                Main scene (M8): the editor front door, running editor.gd. Declares the editor's fixed chrome — backdrop, top bar (title + sprite selector + Add/Del/Rename sprite buttons (M24/M25) + NEW/OPEN/SAVE + RUN, M22), the palette | canvas workspace (each in a ScrollContainer), the Make/Rename/Delete variable dialogs and the New/Delete/Rename sprite dialogs (M24/M25), and the project-file browser (a FileDialog, M22) — which editor.gd reaches by unique name. (The palette/canvas *contents* are still generated in code.)
main.tscn                  The *game* scene: a single Node2D "Stage" running stage.gd (launched by the editor's RUN button)
icon.svg                   Default project icon (skeleton)
font.png                   3x5-pixel bitmap font atlas (A-Z, 0-9); baked into a PixelFont
scripts/
  editor.gd                Editor root (M8): wires the scene-declared chrome (editor.tscn) — fills the sprite selector, connects RUN, grabs palette/canvas/dialogs by unique name; wires the palette as the canvas's trash (M16); owns the mutable variable model (M20, seeded from PongScripts.variables()), scoping it to the selected sprite — globals + that sprite's locals — for BlockView's data-scoped dropdowns (M17/M19) and rebuilding the palette on each switch; "Make a Variable" dialog appends to that model (M20); rename/delete dialogs edit it (M21) — rename cascades the new name across the in-scope scripts (_is_referent_for), delete strips its references (drop set/change, revert variable-reporter slots) and removes the entry; owns the mutable **sprite** model too (M24) — _scripts is now [{name,x,y,w,h,color,script}] seeded from PongScripts.sprites(); +Sprite/-Sprite buttons add (default placeholder + empty script) / delete (entry + its locals + dangling touching refs, M25) a sprite (_on_new_sprite_confirmed/_on_del_sprite_confirmed); a Rename Sprite button (M25, _on_rename_sprite_confirmed) cascades a new sprite name across every script's touching_sprite? refs and every variable scoped to it (globally — a sprite name is unique, so no per-scope filter); persists script edits + hands the whole sprite model and the variable model to the Stage on RUN (M24/M20, project_sprites/project_variables); saves/opens named project files via a FileDialog (full filesystem access — the user picks the location, defaulting to the project folder) and reloads the in-code demo with NEW (M22, _write_project/_read_project/_seed_demo; _normalize_sprite back-fills geometry on a pre-M24 file), keeping the demo and saved projects from clobbering each other
  block_canvas.gd          Interactive canvas (M9): drag/snap/detach — mutates block data + re-renders; begin_spawn_drag() accepts palette blocks (M11); wires editable literal fields + enum dropdowns back to the data (M12/M13); drops a dragged reporter into a value/condition slot (M14, _nearest_slot — type-filtered to matching boolean/value slots in M23) and grabs one back out of its slot (M15, _reporter_at/_begin_reporter_drag); deletes a block dragged onto the palette (M16, _over_trash/_trashing); refresh() re-renders so a newly-made variable shows in open dropdowns (M20); rename_variable()/delete_variable_refs() rewrite/strip the working stacks in place on a UI rename/delete, preserving positions (M21); rename_sprite() does the same for a sprite rename (M25); export_script() serializes edits back (M10)
  block_palette.gd         Block palette (M11): lists opcodes as chips (reporters too, as pills — M14); on drag, mints a fresh block and hands it to the canvas; rebuild() re-renders the chips when the editor re-scopes the variable dropdowns on a sprite switch (M19); draws a "Make a Variable" button atop the variables group (M20) and, beneath it, a Rename/Delete MenuButton row per in-scope variable (M21), all calling back to the editor
  block_view.gd            Block renderer (M8): tree-walks block data into a Control tree; opcode->{category,template,kind,defaults,enums,data_enums,output,bool_inputs} table; make_block() factory (M11); editable LineEdit literal fields + coerce_literal (M12); enum-slot OptionButtons + type-shaped fields (M13); data-scoped {name} dropdowns from the editor's project_variables/project_sprites (M17, _options_for) — the variable list scoped per sprite by the editor (M19), extended by Make a Variable (M20); count_variable_refs/rewrite_variable_refs/strip_variable_refs walk the block tree for the rename/delete cascade (M21), with count_sprite_refs/rewrite_sprite_refs/strip_sprite_refs the touching_sprite? counterparts for a sprite rename/delete (M25); slot-typing (M23) — reporter_output_type() + a slot_type meta per widget, and an angular boolean pill vs a round value pill — so the canvas can refuse a mismatched reporter drop; this renderer just lists what it's handed; stamps every input widget as a slot drop target with its default literal (M14/M15); tags it for M9 dragging
  stage.gd                 Runtime root: builds sprites + runs their scripts from the one sprite model (the editor's via static project_sprites — which may include UI-added sprites — else PongScripts.sprites(), M24; each entry carries geometry + script, so M10's separate project_scripts/_script_for are retired), owns the name->Target registry + shared font, seeds variables from the project variable model (the editor's via static project_variables — which may include UI-made variables — else PongScripts.variables(), M18/M20); ESC returns to the editor (the inverse of editor.gd's RUN)
  interpreter.gd           Tree-walking, coroutine-driven block interpreter + dispatch tables
  target.gd                Wraps the controlled node + its direction and name
  font.gd                  PixelFont: bakes font.png into rendered text costumes (the `say` block)
  pong_scripts.gd          The hardcoded Pong block scripts (two paddles, ball, two numeric HUDs, announcer), as data; also the seed sprite model — sprites() (M24) declares each sprite's name + placeholder geometry (x/y/w/h/color, color a hex string) + script, the editor's starting set and the Stage's fallback; and the seed variable model — variables() declares each variable's name/value/scope, likewise the editor's starting set and the Stage's fallback (M18; the editor extends its own copies via Make a Variable / +Sprite, M20/M24). Every variable declares to 0; non-zero starts come from `set` blocks in the scripts (the ball's `set speed to BALL_SPEED`), Scratch-style — the starting value lives in the editable program, not a hidden seed
CLAUDE.md                  This file
```

> Saved projects (M22) are plain `.json` files written/read by the editor's SAVE/OPEN, placed
> *wherever the user chooses* (full filesystem access; the browser defaults to this project folder).
> There is no dedicated saves directory — location is the user's call — so saved files are not part of
> the repo unless the user deliberately saves one inside it.

## Conventions for extending

- New block? Add a handler method and one entry in `_register_handlers()` in
  [scripts/interpreter.gd](scripts/interpreter.gd). Statements go in
  `_statement_handlers`; reporters/conditions go in `_reporter_handlers`. **Also add
  one `_OPCODES` entry** in [scripts/block_view.gd](scripts/block_view.gd) so the editor
  can draw it — the symmetric one-line step. That entry carries `category` + label
  `template` (drawing) plus `kind` and `defaults` (M11): set `kind` to `"hat"`/
  `"statement"` and give sensible `defaults` for it to appear in the palette as a fresh
  draggable block; a `"reporter"` (M14) appears in the palette as a pill that drags into a
  value/condition slot. If an input is a fixed choice, also give the entry an `enums` field (M13) —
  `input_key -> [allowed values]` — and that slot renders as a dropdown instead of a
  free-text field. If instead the choice is **project data** — a variable or sprite name — give the
  entry a `data_enums` field (M17), `input_key -> "variables"`/`"sprites"`, and the slot becomes a
  dropdown of the editor's live `project_variables`/`project_sprites`. If the block is a **boolean**
  reporter (a condition), give it `output: "boolean"` (M23) so it draws as an angular pill and may drop
  only into boolean slots; if it *has* a boolean input slot, list that key in `bool_inputs` so only
  boolean reporters may drop there (default: a value reporter / value slot). An opcode with no entry
  still renders, as a grey box.
- New variable? Two ways. **From the UI** (M20): click **Make a Variable** atop the palette's
  variables group, name it, pick global/local — it is appended to the editor's working model and
  seeded at RUN. It survives relaunch only if you **SAVE** the project (M22); otherwise it resets to
  stock, like every unsaved edit. You can also **rename or
  delete** it from its row's menu (M21) — rename cascades across the scripts that reference it; delete
  strips its references (drops `set`/`change` blocks, reverts `variable`-reporter slots to defaults)
  and removes the entry. **In the stock
  project**: add one `{name, value, scope}` entry to
  [`PongScripts.variables()`](scripts/pong_scripts.gd) (M18) — the seed model the editor starts from
  and the Stage falls back to. `scope` is `"global"` or a sprite name (a per-sprite local). Don't seed
  a variable inline in `stage.gd` or name it in the editor separately; that is exactly the duplication
  M18 removed.
- New sprite? Two ways, mirroring variables. **From the UI** (M24): **+ Sprite** in the top bar names
  a new sprite (a grey placeholder at centre with an empty script); **− Sprite** deletes the selected
  one (and its locals, and any `touching` references to it — M25); **Rename Sprite** (M25) renames it,
  cascading the new name across every script's `touching_sprite?` references and the `scope` of its
  locals. A UI-added/renamed sprite is seeded/built at RUN and survives relaunch only if you
  **SAVE** the project. **In the stock project**: add one `{name, x, y, w, h, color, script}` entry to
  [`PongScripts.sprites()`](scripts/pong_scripts.gd) (M24) — the seed sprite model the editor starts
  from and the Stage falls back to (`color` a hex string; `script` from a builder). Don't build a
  sprite inline in `stage.gd`; that is exactly the duplication M24 removed (the sprite sibling of M18).
  A sprite's starting position here is just the placeholder — real positioning is a `go_to` block in
  its script (behaviour is blocks); editing a sprite's starting geometry from the UI is not built yet
  (deferred).
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

- **Editing a variable's model entry from the UI** — **M20 delivered "make a variable"** and **M21
  delivered rename + delete** (each in-scope variable's palette row carries a Rename/Delete menu), so
  the model is fully editable: you can mint, rename, and remove a global or sprite-local from the
  editor. A variable's **initial value is always 0** — that is Scratch's model, and it is *not* a
  deferral: a non-zero starting value is expressed by a `set` block in the script (the Ball's
  `set speed to BALL_SPEED`), which **is** editable in the canvas (click the literal). What still
  lives only in [`PongScripts.variables()`](scripts/pong_scripts.gd) is the *declaration* (a stock
  variable's name + scope). (M21 put rename/delete on the *palette rows*, not a canvas-pill
  right-click menu, so it did **not** free the full-body pill grab below — see that bullet.)
- **Reset edits to pristine** — **M22's NEW button** is the whole-project reset: it reloads the stock
  demo (the in-code PongScripts) without touching any saved file. What's still unbuilt is a **per-sprite
  "revert"** (re-load one sprite's stock script, leaving the others edited). Note M22 changed the
  relaunch behavior: launch still lands on the demo, but a project now only survives relaunch if you
  **SAVE** it — unsaved edits are still discarded on relaunch (and by NEW/OPEN), there being no undo.
- **Full-body grab of an all-field pill, and ejecting/wrapping** — M15 made on-canvas
  reporter pills grabbable, but a pill whose interior is *entirely* one widget — a bare
  `variable`, whose only content is its name slot — can be grabbed only by its thin coloured
  border, since the slot widget takes the clicks over its area. M17 turned that slot from a
  `LineEdit` into a data-scoped `OptionButton`, but an `OptionButton` captures clicks just the
  same (to open its menu), so this did **not** free the full-body grab as an earlier note
  predicted — it still waits on something else (e.g. a modifier-key or click-vs-drag disambiguation
  on the widget itself). M21's rename/delete menu lives on the *palette* variable rows, not a
  right-click on the canvas pill, so it didn't free this either. Still unsupported either way:
  **ejecting / wrapping** the reporter a drop
  displaces — dropping a reporter onto a slot that already holds one discards the old (M14), rather
  than ejecting it to the cursor or wrapping it as an input of the new.
- **Boolean-vs-value slot typing** — **M23 delivered this.** Each reporter declares an `output`
  (`"boolean"`/`"value"`) and each boolean slot is named in its opcode's `bool_inputs`; the canvas's
  `_nearest_slot` offers a dragged reporter only the matching slots, so a number can't land in an `if`
  condition nor a boolean in `move`'s `steps` — Scratch's refusal — and boolean pills draw angular vs
  value pills round to cue it. It did **not** need the true connector geometry below: the match is still
  rectangular *proximity* (a highlighted slot rect), now gated by type. What's *still* deferred is
  **ejecting/wrapping** a displaced reporter (a matching drop onto an occupied slot discards the old, M14)
  — see the full-body-grab bullet above.
- **Data-owned sprite set** — **M24 delivered the model + add/delete; M25 the rename + dangling-ref
  strip.** The sprite set is one model
  ([`PongScripts.sprites()`](scripts/pong_scripts.gd) — `{name, x, y, w, h, color, script}` per
  sprite) that both the runtime and the editor read, retiring the six hardcoded `_add_sprite` calls in
  `stage.gd` and the editor's name-only mirror; **+ Sprite / − Sprite** add and delete sprites and
  **Rename Sprite** (M25) renames one — cascading the new name across the selector, every
  `touching_sprite?` reference across all scripts, and every variable `scope` field (the sprite analog
  of M21's variable rename), with sprite *delete* now **stripping dangling `touching_sprite?`
  references** to the gone sprite (reverting them to the host slot's default — `if (touching Gone?)` →
  `if true`) rather than leaving them to resolve null → false at RUN. What's *still* deferred: **editing
  a sprite's starting geometry from the UI** (position/size/colour) — a new sprite starts as a grey
  centre placeholder and is repositioned by a `go_to` block in its script (behaviour is blocks), so
  there is no on-stage drag or inspector yet.
- **Canvas panning / auto-scroll while dragging** — the canvas sits in a
  `ScrollContainer` (wheel/scrollbar scroll a tall script), but there's no click-drag
  panning of empty canvas and no auto-scroll when a drag reaches the viewport edge.
- **True Scratch block geometry** — the editor approximates block/reporter/boolean
  shapes with `StyleBoxFlat` corner radii; real connector notches and hexagonal
  booleans are cosmetic. M9's stack snapping and M14's slot drop both use rectangular
  *proximity* (a yellow bar / a highlighted slot rect), not precise notch/hexagon
  connection points, so this can keep waiting.
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
