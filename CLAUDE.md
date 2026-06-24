# scratch-like — a Scratch-style game engine in Godot 4

A small visual-programming game engine, built in stages. The end goal is a
drag-and-drop block editor where you snap blocks onto sprites to script them.
We are building it runtime-first so the execution model is solid before any UI
exists.

## Current state: Milestone 47 — collapsable scripts in the editor canvas

**Goal of this milestone:** let you **collapse a top-level script** in the block editor to a compact
one-line bar, so a canvas full of long scripts stays navigable (Scratch's right-click *Collapse*). Like
every editor-side milestone since M27 it is a **pure editor-side interaction over the data-owned block
model** — **no new opcode, no block-data-shape change, no runtime change.** Collapse state is **editor-only
UI state** (the sibling of a stack's canvas position and the M46 selection): it lives in
[`BlockCanvas._stacks`](scripts/block_canvas.gd) as an optional `collapsed` flag per stack, and **never**
enters [`export_script()`](scripts/block_canvas.gd), persistence, or RUN. [`BlockView`](scripts/block_view.gd)
gains one renderer ([`build_collapsed_stack`](scripts/block_view.gd)); everything else is canvas-side.

### Collapse state — a per-stack flag beside `pos`

A top-level stack dict in [`_stacks`](scripts/block_canvas.gd) (`{blocks, pos}`) gains an optional
**`collapsed: bool`** (absent ⇒ expanded). It is read with `.get("collapsed", false)`, so existing
stacks and the drag/drop append sites need no migration. Because it lives on the **stack wrapper**, not
the block dicts, it rides nothing the runtime sees — `export_script()` still flattens only `blocks`.
`load_script` (a sprite switch) builds every stack expanded, so collapse — like selection (M46) and
canvas layout (M22) — is transient session UI state that resets on a sprite switch and is not saved.

### Rendering — a one-line summary bar, and a gutter chevron

[`_render`](scripts/block_canvas.gd) branches per stack: a collapsed stack draws
[`BlockView.build_collapsed_stack`](scripts/block_view.gd) — a compact bar in the first block's
**category colour** showing that block's [`_summary_text`](scripts/block_view.gd) (its label template
with each `{input}` flattened to text, a nested reporter shown as `( )`) plus a dim **`+N` badge** of the
blocks hidden beneath it ([`count_blocks`](scripts/block_view.gd), the recursive statement count − 1).
The bar carries **no editable widgets** (it's a summary, not the live header — so the whole bar is one
clean mouse target, rendered with `_passthrough(false)` and no `_wire_literals`), but it **is** stamped
`blk_array`/`blk_index 0`, so the canvas drags / selects / deletes the whole collapsed script as a unit
(the real blocks stay in `_stacks`, so RUN/SAVE are unaffected).

Every stack — collapsed or not — is wrapped by [`_wrap_with_gutter`](scripts/block_canvas.gd) in a row
with a fixed-width left gutter, so collapsible and non-collapsible stacks share one left edge. A stack
with **more than one block** (`count_blocks > 1` — something to hide) gets a **chevron** in that gutter
(`▼` expanded / `▶` collapsed), stamped with its owning stack dict as the `collapse_stack` meta. The
gutter shifts each block right by a constant, so a free-landing dragged stack stores its `pos` via
[`_land_pos`](scripts/block_canvas.gd) (ghost position minus the gutter width) — without that subtraction
a block would drift right by the gutter on every drop.

### Toggling — chevron click, or Cmd/Ctrl+E on the selection

Two ways in, matching the editor's existing idioms:

- **Click the chevron.** The press handler ([`_input`](scripts/block_canvas.gd)) checks
  [`_collapse_toggle_at`](scripts/block_canvas.gd) **before** `_front_stack_at` (the chevron sits in the
  gutter, outside every tagged block panel, so it would otherwise read as an empty-canvas press): a hit
  flips that stack's `collapsed` and re-renders, never selecting / dragging / clearing.
- **Cmd/Ctrl+E** ([`_handle_key`](scripts/block_canvas.gd) → [`_toggle_collapse_selection`](scripts/block_canvas.gd),
  beside M46's Delete / Cmd+D): collapse/expand every top-level script the selection touches
  ([`_stacks_with_selection`](scripts/block_canvas.gd)). Only collapsible stacks participate, and the
  toggle is **uniform** — if any touched script is expanded, collapse them all, else expand them all.

A collapsed script stays **fully draggable, selectable, deletable, and duplicable** as one unit
(`blk_index 0`); a drag that picks up a **whole collapsed stack** re-homes it still collapsed
([`_grabbed_collapsed`](scripts/block_canvas.gd), carried into the free-land `_drop` / `_cancel_drag`
append). Snapping a collapsed bar into another stack, or dropping a sub-run into a gap, behaves as before
(the gutter is uniform, so block-to-block distances are unchanged).

What this leaves deferred: **persisting collapse** with the project (it's transient like layout/selection
— a reopened/switched sprite re-expands every script); collapsing an **in-slot reporter** or a single
block (only multi-block top-level scripts are collapsible — a lone block has nothing to hide); and
**Scratch's right-click context menu** (this editor has none — the chevron and Cmd/Ctrl+E are the two
gestures).

---

## Earlier: Milestone 46 — multi-block selection in the editor canvas

**Goal of this milestone:** let you **select multiple blocks** in the block editor and act on them as a
group. Scratch has no such gesture, but it makes editing real scripts far less tedious. Three ways to
select and three things to do with a selection, all a **pure editor-side interaction over the
data-owned block model** (like every editor milestone since M27): **no new opcode, no block-data-shape
change, no runtime change.** Selection is editor-only UI state (the sibling of a stack's canvas
position) — it never enters `export_script()`, persistence, or RUN. It lives almost entirely in
[`BlockCanvas`](scripts/block_canvas.gd) (the selection outline is applied by duplicating each selected
panel's own stylebox); the one [`BlockView`](scripts/block_view.gd) change is that
[`build_stack`](scripts/block_view.gd) now draws a stack-level reporter as its pill, so a **free-floating
reporter** can live on the canvas (below).

Selection works on **statement blocks, in-slot reporter pills, and free-floating reporters**; double-click
selects a block **plus all of its nested children**; and a reporter can be dropped on the canvas to **live
free** (Scratch's loose reporter), where it is manipulated and selected like a statement.

### Selection — a set of block dicts (statements and reporter pills), tracked by identity

[`BlockCanvas._selected`](scripts/block_canvas.gd) holds references to the selected block dicts (identity
via `is_same`) — **statement blocks and reporter pills alike**. Because the block dicts in `_stacks`
persist across a `_render()` (only the Control tree is rebuilt), a rendered panel's `blk_array[blk_index]`
(a statement) or a slot's `inputs[key]` (a pill) resolves back to the same dict — so a selection
**survives a re-render**. [`_apply_selection_highlight`](scripts/block_canvas.gd) (called at the end of
`_render`) outlines each selected block — both via [`_tagged_panels`](scripts/block_canvas.gd) (statement
panels) and [`_slots`](scripts/block_canvas.gd) (a slot whose `inputs[key]` is a selected reporter dict) —
by duplicating its category stylebox and adding a white border ([`_outline_selected`](scripts/block_canvas.gd)),
no `BlockView` change. The **rubber-band stays statement-level** (it reselects only the statement panels it
covers).

### The three ways to select — repurposing two no-op gestures

A **plain click on a block** (previously a no-op that returned to `_IDLE`) and a **press on empty
canvas** (previously an early `return`) were free hooks. The press handler now captures the modifier
(`shift`/`meta`/`ctrl`) + `double_click` flags, and the `PENDING → IDLE` release routes through
[`_on_pending_click`](scripts/block_canvas.gd):

- **Click** a statement block **or a reporter pill** → select it alone; **Shift/Cmd-click** → toggle it
  in/out ([`_toggle_selected`](scripts/block_canvas.gd)). The block under the press is resolved by
  [`_pending_clicked_block`](scripts/block_canvas.gd) (the pill's `inputs[key]` dict for a reporter
  press, else the statement at `{array, index}`).
- **Double-click** a block → select it **and all of its nested children**
  ([`_select_subtree`](scripts/block_canvas.gd)): for a statement, the block **and all following siblings
  at that body level** (`array.slice(index)`), each *with its own subtree*; for a reporter pill, the pill
  itself. A subtree is the block's `body` statements **and** the reporter input pills in its slots,
  recursively (a plain input map like a `call`'s `args` is descended into for the reporter dicts it
  holds, but isn't itself selected). Additive with a modifier, else replacing the selection.
- **Click empty canvas** → clear the selection.
- **Rubber-band**: a press on empty canvas that moves becomes a marquee
  ([`_begin_marquee`](scripts/block_canvas.gd) / [`_update_marquee`](scripts/block_canvas.gd)) — a
  sky-blue overlay rect (a direct child of the canvas, **not** `_layer`, so `_render` never frees it);
  each motion reselects the statement panels whose global rect `intersects` it (union with the snapshot
  [`_begin_marquee`](scripts/block_canvas.gd) took when Shift began the drag). A press on the
  `ScrollContainer`'s scrollbar ([`_over_scrollbar`](scripts/block_canvas.gd)) is left to scroll.

### The three things you can do — reusing the drag/trash machinery

- **Move together** — dragging a block that **is** in a 2+ selection
  ([`_begin_multi_drag`](scripts/block_canvas.gd)) gathers the **topmost-selected** blocks in document
  order ([`_topmost_selected_in_order`](scripts/block_canvas.gd) — a selected C-block and a block inside
  it collapse to just the C-block, whose body travels with it), removes each from its array by identity,
  drops any emptied top-level stack, and floats them as **one ghost stack**. From there the existing
  [`_drop`](scripts/block_canvas.gd) snaps the run into a gap, lands it as a free stack, or — over the
  palette (the M16 trash) — deletes it. Dragging an *unselected* block is the unchanged single-block
  (block + successors) pickup, and clears the selection.
- **Delete** — Delete/Backspace ([`_delete_selection`](scripts/block_canvas.gd)) removes the
  topmost-selected blocks and drops emptied stacks; dragging the selection onto the palette is the other
  route (via the move path above).
- **Duplicate** — Cmd/Ctrl+D ([`_duplicate_selection`](scripts/block_canvas.gd)) deep-copies the
  topmost-selected run into a new free-floating stack and selects the copies.

These three ops act on the **top-level (stack-level) picks**:
[`_topmost_selected_in_order`](scripts/block_canvas.gd) walks the blocks in each top-level stack (and
their bodies), which are the statements **and the free-floating reporters** (see below — a loose reporter
is its own one-block stack). An **in-slot** reporter pill is *not* a stack block — it lives in another
block's `inputs[key]` — so it is still **ignored** by move / delete / duplicate (highlight-only); to act
on it you first pull it out into a slot or onto the canvas. (Deleting an in-slot pill in place would mean
reverting its slot to a default, which only its own pickup gesture does.)

### Reporters can live free on the canvas — like statements

A reporter is structurally a block dict like any other, so it can be a **free-floating top-level stack**
(`{blocks: [reporter], pos}`) — Scratch's "pull a reporter onto the workspace." This makes reporters
first-class for physical manipulation and selection:

- **Render** — [`BlockView.build_stack`](scripts/block_view.gd) draws a stack-level reporter as its
  **pill** ([`build_reporter`](scripts/block_view.gd), not the statement panel), but still stamps
  `blk_array`/`blk_index` on it, so the canvas drags / selects it like any top-level block.
- **Land free** — a reporter released **off every slot** (whether dragged from the palette, M14, or
  pulled out of a slot, M15) now lands as its own stack ([`_drop`](scripts/block_canvas.gd)) instead of
  being discarded. A confined `param` drag (M31, `_spawn_scope_body` set) is the exception — it has no
  home outside its define body, so it is still discarded.
- **Grab again** — pressing a free-floating reporter is found by [`_block_at`](scripts/block_canvas.gd)
  (not `_reporter_at`, which only sees in-slot pills); [`_hit_is_reporter`](scripts/block_canvas.gd)
  marks it so [`_begin_reporter_drag`](scripts/block_canvas.gd) lifts it (dropping its now-empty stack)
  and runs the ordinary reporter drag — re-drop into a slot, leave it floating, or trash it.
- **Inert at runtime** — `export_script` carries a loose reporter through persistence and RUN unchanged,
  but [`Interpreter.run`](scripts/interpreter.gd) starts only hat stacks, so a parked reporter never
  executes (Scratch's behaviour: it persists with the project but does nothing until wired into a script).
- **Selectable / movable / deletable** like a statement — it is a stack block, so click / double-click
  select it, and the group ops above pick it up (a single free reporter, or with a 2+ selection via
  [`_begin_multi_drag`](scripts/block_canvas.gd)).

Keyboard ops are handled by [`_handle_key`](scripts/block_canvas.gd) (the chrome-less modifier idiom,
like the Stage view's Alt/Shift): ignored while a `LineEdit` is focused (so typing — including Delete —
in a literal slot is unaffected) or nothing is selected; it only marks the event handled when it acts.
`load_script` clears the selection on a sprite switch.

What this leaves deferred: **undo** (a delete/duplicate is committed immediately, as with every session
edit since M16); **group operations on *in-slot* reporter pills** (a pill can be *selected* and
*highlighted* in place, but to move/delete it you pull it out first — only free-floating reporters and
statements are picked up by the group ops); a **copy/paste across sprites** clipboard (duplicate lands in
the same sprite); and a **marquee-vs-C-block** nicety (a rubber-band over a `forever` highlights both it
and the inner blocks it covers — the topmost filter collapses them for any operation, but both still draw
outlined). (The rubber-band *does* now sweep free-floating reporters, since they render as `blk_index`-
tagged panels like statements; only in-slot pills, which aren't stack-level panels, are outside it.)

---

## Earlier: Milestone 45 — pixel costume editor

**Goal of this milestone:** let you **paint a sprite's costume as pixel art** instead of the flat
placeholder colour every sprite drew through M44. It adds a **third editor mode — "Paint"** (beside
Blocks and Stage) with a pixel grid, a palette, and the usual tools, and a runtime that builds the
sprite's texture from the painted pixels. Like every editor-side milestone since M27 it is a **pure
view over the data-owned sprite model** — **no new opcode, no block-data-shape change** — plus one
optional `costume` key on a sprite dict that round-trips through SAVE/RUN and **falls back to the flat
`color`** when absent (so a pre-M45 project opens unchanged).

### The data — one optional `costume` key, the JSON-clean palette+index twin

A sprite dict (the `{name, x, y, w, h, color, script}` of [`PongScripts.sprites()`](scripts/pong_scripts.gd))
gains an optional **`costume`**:

```
"costume": { "cw": 16, "ch": 16, "palette": ["#000000", "#ffffff", …], "pixels": [-1, -1, 0, 1, …] }
```

`palette` is opaque `"#rrggbb"` hex (the existing `Color(String(hex))` parse); `pixels` is a row-major
`Array` of palette indices of length `cw*ch`, with **`-1` = transparent** (the reserved sentinel, so the
palette carries no transparency slot or alpha). It is **not** added to
[`_DEFAULT_SPRITE`](scripts/editor.gd) and [`_normalize_sprite`](scripts/editor.gd) is unchanged — so an
unpainted sprite and a pre-M45 save simply *lack* the key (the absence is meaningful: render falls back
to flat `color`; "empty costume" never needs disambiguating from "no costume"). JSON parses numbers as
floats, so the runtime builder and the editor both `int(...)`-coerce `cw`/`ch`/`pixels` on read (the same
discipline as the model geometry).

### Runtime — build the texture from the grid, no stretch

[`Stage._make_costume_texture`](scripts/stage.gd) (the costume sibling of `_make_placeholder_texture`)
fills an `Image` from the index grid — palette colour per pixel, transparent for `-1`/out-of-range —
and returns an `ImageTexture`. [`Stage._add_sprite`](scripts/stage.gd) gained an optional `costume` param
(the build loop passes `s.get("costume", {})`): when present it sets `TEXTURE_FILTER_NEAREST` (the `say`
idiom) and uses the costume texture, else the flat fill. Rendering is **no-stretch** — Sprite2D is
centred and draws the `cw×ch` texture at native size, so **1 costume-pixel = 1 model-pixel**, never
scaled to fit `w/h`. The costume's resolution therefore *is* the sprite's footprint: creating a costume
sets the entry's `w/h` to `cw/ch`, so collision (`touching_sprite?`), the inspector, and the stage
preview all agree with the pixels drawn. (The `say` block still overwrites the live texture at runtime
exactly as before — the painted costume stays in the data, only the live node's texture is replaced
while speaking.)

### The Paint view — a third surface mirroring StageView

[`PaintView`](scripts/paint_view.gd) (`paint_view.gd`, the costume counterpart of `stage_view.gd`) holds
a **reference** to `editor._scripts` (`set_model`) and mutates the selected entry's `costume.pixels`
**in place** — the M9 data-is-canonical idiom. It drives painting from `_input` with the StageView
`IDLE→PENDING→DRAGGING` machine and the `is_visible_in_tree()` guard, hit-testing the grid in global
coordinates (cursor → the grid layer's `global_position` → divide by the display cell size → floor). A
press paints immediately (a click = one pixel); the tools:

- **pencil / eraser** — paint along the drag (Bresenham-interpolated so a fast stroke leaves no gaps),
  writing the active palette index or `-1`.
- **fill** — flood-fill (4-connected, queue-based) the clicked cell's contiguous region.
- **eyedropper** — pick the clicked cell's index as the active colour (and switch to pencil).
- **clear-all** — set every pixel to `-1` (a no-op when the sprite has no costume yet).

The grid draws via an inner custom-`_draw` layer (`_PixelGrid`, like StageView's `_GridLayer`): a
checkerboard for transparent cells, the palette colour otherwise, thin grid lines, scaled so the costume
fits a target box. Unlike StageView's static inspector, the Paint view **builds its own tool/palette
chrome in code** (the palette swatches are dynamic — one button per colour), so [editor.tscn](editor.tscn)
carries only the one `PaintView` Control. A **ColorPickerButton recolours the active swatch** (every
pixel using that index updates live, since pixels reference the index). The costume is **created lazily
on first paint** ([`_ensure_costume`](scripts/paint_view.gd)) at the sprite's `w/h` clamped to a
paintable range — so merely *visiting* Paint mode mutates nothing; before the first stroke the grid shows
a transient all-transparent preview at that same resolution.

### Editor wiring — a third mode

[`editor.gd`](scripts/editor.gd) widened M27's `_stage_mode` bool to an `enum Mode { BLOCKS, STAGE, PAINT }`
+ [`_set_mode`](scripts/editor.gd) (one routine swapping the three workspace containers' `visible` — an
`HBoxContainer` skips hidden children — and the two toggle buttons' labels). A new top-bar **Paint**
button enters/leaves Paint mode beside the existing **Stage** toggle. Entering Paint folds the canvas
(`_persist_current`) and `set_model`s the paint view; the selection paths
([`_show`](scripts/editor.gd) / [`_load_project_into_ui`](scripts/editor.gd)) re-point it when Paint is
up, exactly as they do StageView for Stage. [`PaintView.on_costume_changed`](scripts/paint_view.gd) →
[`_on_costume_changed`](scripts/editor.gd) re-syncs the inspector after a paint (a costume create changes
`w/h`); [`_sync_inspector`](scripts/editor.gd) **disables the W/H spin boxes when a costume exists** and
[`StageView._render`](scripts/stage_view.gd) **suppresses its resize handle** for a costumed sprite —
both because `w/h` are slaved to `cw/ch` (resolution is changed in Paint, not by a stage resize; a
resize-canvas tool is deferred).

### Persistence + RUN

The `costume` key is a plain dict of ints/strings/arrays, so it serialises with `_scripts` in
[`_serialize_project`](scripts/editor.gd) and re-parses in [`_apply_project`](scripts/editor.gd) with **no
new code**; RUN's `Stage.project_sprites = _scripts.duplicate(true)` deep-copies it across the scene swap.
A pre-M45 file (no `costume`) opens and renders its flat `color`.

What this leaves deferred: **multiple costumes per sprite** + costume-switching blocks (`switch costume
to` / `next costume`) and **animation frames** (one costume per sprite for now); **undo/redo** (a stroke
is committed immediately); **PNG import/export**; a **shared project-level palette** (each costume owns
its palette); **costume rotation / custom anchor**; and a **resize-canvas tool** (cw/ch are fixed at
creation — which is why the stage resize handle and inspector W/H are suppressed when a costume exists).

---

## Earlier: Milestone 44 — lists (ordered collections), the variable twin

**Goal of this milestone:** add **lists** — Scratch's ordered, mutable collections — built as the
direct **structural twin of variables** (M18/M20/M21). A list is a named `Array` of items with a
**global / per-sprite-local scope**, made / renamed / deleted from the palette exactly like a
variable, seeded into the runtime the same way, and persisted in the project `.json`. It adds **nine
opcodes** (the full Scratch list block set) and one new `data_enums` source (`"lists"`), but — like
every milestone since M30 — **no block-data-shape change**: each block is a plain `{opcode, inputs}`
dict, so persistence (M22) and RUN (M10) carry it untouched, and a pre-M44 project still opens (the
`lists` key is optional → an empty list model). Per the milestone scope, lists are **data-only** —
created/edited from the palette, read in scripts via reporters; there is **no on-stage list monitor
widget** (a scrollable display is a deferred milestone of its own).

### The model — `{name, items, scope}`, the sibling of `variables()`

[`PongScripts.lists()`](scripts/pong_scripts.gd) declares the stock list model — an Array of
`{name, items, scope}` (`scope` ∈ {`"global"`, a sprite name}; `items` the starting Array) — the list
counterpart of `variables()`, read by **both** the runtime and the editor. The stock demo uses no
lists (the list blocks ship unexercised by Pong, like clones / `stop "this script"`), so it returns
`[]`; you make a list from the editor's **Make a List** button (or add a stock entry here). The editor
owns a mutable copy [`_lists`](scripts/editor.gd) (seeded from it, deep-copied) — the exact mirror of
`_variables`.

### Runtime — a list store on the Stage and on each Target

A list resolves **local-first, then global** (Scratch's shadowing order, like a variable):

- [`Target.lists`](scripts/target.gd) — per-sprite ("for this sprite only") lists. A clone inherits a
  **deep copy** (`source.lists.duplicate(true)`), so a clone's list edits don't bleed into the source
  (like locals / direction / velocity).
- [`Stage._lists`](scripts/stage.gd) — global ("for all sprites") lists, with
  [`get_list`](scripts/stage.gd) / [`has_list`](scripts/stage.gd) (the list twins of `get_var` /
  `has_var`). [`Stage._ready`](scripts/stage.gd) seeds every entry from
  [`_list_model()`](scripts/stage.gd) (the editor's `project_lists` when handed one, else
  `PongScripts.lists()`) **deep-copied**, so the runtime owns its own mutable containers — the list
  blocks mutate these Arrays **in place**.

The interpreter resolves a list to its **live Array** via [`_get_list`](scripts/interpreter.gd)
(returns `null` for an unknown name → the caller no-ops / returns a benign empty, since lists are made
up front in the UI), with two helpers: [`_resolve_index`](scripts/interpreter.gd) (1-based, also
accepts the index keywords `"last"` and `"random"`/`"any"`) and [`_items_equal`](scripts/interpreter.gd)
(Scratch's loose compare — numeric when both items read numeric, else case-insensitive string — for
`contains?` / `item #`).

### The nine blocks (all category `"lists"`, the full Scratch set)

Five **statements** (mutate the list in place) and four **reporters** (read it). `{list}` is a
data-scoped dropdown (`data_enums: {list: "lists"}` → [`BlockView.project_lists`](scripts/block_view.gd),
the list twin of the `"variables"` source — so it re-scopes per sprite for free); `{index}` is a 1-based
numeric slot; `{item}` an ordinary value slot (literal / arithmetic / dropped reporter). Out-of-range
indices are ignored (statements) or yield `""` (reads) — Scratch's behaviour, so a bad index can't
crash a script.

- **`add {item} to {list}`** (`list_add`) → append.
- **`delete {index} of {list}`** (`list_delete`) → remove the 1-based item.
- **`delete all of {list}`** (`list_delete_all`) → clear.
- **`insert {item} at {index} of {list}`** (`list_insert`) → insert, shifting the rest right (range 1..len+1).
- **`replace item {index} of {list} with {item}`** (`list_replace`) → overwrite.
- **`item {index} of {list}`** (`list_item`, value) → read, else `""`.
- **`item # of {item} in {list}`** (`list_item_index`, value) → 1-based index of the first match, else 0.
- **`length of {list}`** (`list_length`, value) → item count.
- **`{list} contains {item}?`** (`list_contains?`, **boolean**) → membership test.

### Editor — Make a List + rename/delete, mirroring variables

The palette's new **LISTS** group (after VARIABLES in `PALETTE_CATEGORY_ORDER`) renders specially like
the variables group ([`BlockPalette`](scripts/block_palette.gd)): a **Make a List** button atop, one
**Rename / Delete** `MenuButton` row per in-scope list, then the nine list chips. The editor side is a
near-verbatim copy of the variable code — [`_lists_in_scope`](scripts/editor.gd) (globals + this
sprite's locals, re-pointed into `project_lists` in [`_show`](scripts/editor.gd)),
[`_make_list`](scripts/editor.gd) / [`_on_new_list_confirmed`](scripts/editor.gd) (append
`{name, items: [], scope}`), and the rename/delete cascade
([`_on_list_rename_confirmed`](scripts/editor.gd) / [`_on_list_delete_confirmed`](scripts/editor.gd))
scoped per-referent ([`_is_list_referent_for`](scripts/editor.gd)). The cascade walkers live on
`BlockView` beside the variable ones: [`count_list_refs`](scripts/block_view.gd) /
[`rewrite_list_refs`](scripts/block_view.gd) / [`strip_list_refs`](scripts/block_view.gd) (keyed on the
`{list}` input; a delete **drops** a list statement and **reverts** a list reporter's slot to its
default — so `if (list contains x?)` becomes `if true` once the list is gone). The canvas's in-place
halves are [`rename_list`](scripts/block_canvas.gd) / [`delete_list_refs`](scripts/block_canvas.gd).
A **sprite** rename re-scopes its local lists and a **sprite delete** drops them (and reports them in
the count), exactly as for local variables (M25). Three new dialogs (`ListDialog` / `ListRenameDialog` /
`ListDeleteDialog`) are declared in [editor.tscn](editor.tscn).

### Persistence + RUN

The project `.json` gains a top-level **`lists`** key ([`_serialize_project`](scripts/editor.gd) /
[`_apply_project`](scripts/editor.gd) — absent ⇒ `[]`, so a pre-M44 save still opens), and RUN hands
`Stage.project_lists = _lists.duplicate(true)` over alongside the sprites/variables/background (stashed
in `_restore_lists` for the ESC round trip).

What this leaves deferred: an **on-stage list monitor** (the scrollable list display — lists are
data-only this milestone), the index keywords in the slot as a **dropdown** (`"last"`/`"random"` work if
*typed*, but the index is a plain numeric field, not Scratch's `1`/`last`/`random` menu), and a
**list-typed reporter / "for each" loop** (compose iteration with `length` + `item` + a counter + a
`while`).

---

## Earlier: Milestone 43 — cross-sprite position reporters + built-in velocity

**Goal of this milestone:** two related motion additions. (1) Replace the demo's **position-relay
globals** with real reporter blocks — read *another* sprite's x/y directly instead of having that
sprite publish its position into a custom variable. (2) Make **velocity a built-in property** that
the runtime applies every frame "behind the scenes," with blocks to set / change / read it. Both are
the project's usual symmetric extension (one `_OPCODES` entry + one interpreter handler each), **no
block-data-shape change, no editor change** — the renderer reuses the existing sprites dropdown and
plain numeric slots.

### Cross-sprite position reporters — `x/y position of {sprite}`

Through M42 the only position reporters were the input-less **`x position` / `y position`** (M35),
which read the **running** sprite. A sprite that needed *another* sprite's position — the Pong ball,
for its curved paddle bounce — couldn't ask for it, so the demo used a **relay global**: each paddle
ran `set {paddle}_y to (y position)` every tick and the ball read that variable (M36). M43 retires
that pattern with two reporters that read any sprite by name:

- **`x position of {name}` / `y position of {name}`** (`x_position_of` / `y_position_of`, motion
  reporters, value output) → [`_on_x_position_of`](scripts/interpreter.gd) /
  [`_on_y_position_of`](scripts/interpreter.gd): resolve the named sprite through the Stage registry
  (`find_target`, like `touching_sprite?`) and return its node centre; an unknown name warns and
  yields 0. `{name}` is the M17 `data_enums: {name: "sprites"}` dropdown — the same `touching_sprite?`
  / camera source, so it re-scopes per project with **no new resolver and no editor change**.

They join `_SPRITE_OPCODES` ([`block_view.gd`](scripts/block_view.gd)), so a sprite **rename/delete
cascade** (M25) rewrites/reverts them like `touching_sprite?` — `strip_sprite_refs` reverts a
`y position of (Gone)` to its slot default once the sprite is deleted (the strip helper now keys off
`in _SPRITE_OPCODES` instead of the single hardcoded `touching_sprite?`).

The demo rewrite ([`PongScripts`](scripts/pong_scripts.gd)): the `left_paddle_y` / `right_paddle_y`
globals and the paddles' `set ..._y to (y position)` relay lines are **gone**; the ball's
[`_paddle_bounce_dir`](scripts/pong_scripts.gd) now reads `y position of (LeftPaddle)` /
`y position of (RightPaddle)` directly (the node *is* the position, so there's nothing to keep in
step).

### Built-in velocity — applied each tick, with set / change / read blocks

Velocity becomes first-class motion state on the [`Target`](scripts/target.gd): a `velocity: Vector2`
in **px per physics tick** (the `move_steps` unit). The [`Stage`](scripts/stage.gd) applies it to
every live sprite once per **physics frame** in [`_physics_process`](scripts/stage.gd) —
`node.position += velocity` — so a sprite with a non-zero velocity drifts on its own with no
per-frame block. It is applied to a `_movables` list (every registered sprite **plus clones**, which
aren't in the name registry); clones inherit their source's velocity (like direction / locals). A
zero velocity is skipped, so **every existing project renders unchanged**.

Why physics frame, not render frame: the script coroutines already `await physics_frame`, and Godot
emits that signal **after** all `_physics_process` calls — so each tick velocity moves the sprite
first, then its script runs reading the moved position (a consistent order). Raw per-tick add, no
delta scaling, matching the fixed-tick model (`set velocity y: 6` covers the same ground as `move 6`
in a `forever`).

The blocks (all motion category, plain `{opcode, inputs}`):

- **`set velocity to x: {x} y: {y}`** (`set_velocity`) → [`_on_set_velocity`](scripts/interpreter.gd):
  assign the velocity vector. The continuous-motion counterpart of `go_to` (which sets position once).
- **`change velocity by x: {dx} y: {dy}`** (`change_velocity`) →
  [`_on_change_velocity`](scripts/interpreter.gd): add to it — accelerate / steer (a constant `dy` in
  a `forever` is gravity), the velocity twin of `change_var`.
- **`velocity x` / `velocity y`** (`velocity_x` / `velocity_y`, value reporters) →
  [`_on_velocity_x`](scripts/interpreter.gd) / [`_on_velocity_y`](scripts/interpreter.gd): read the
  running sprite's velocity components.

The demo exercises it: the **CPU right paddle** ([`right_paddle`](scripts/pong_scripts.gd)) is
rewritten from M41's `animate`-driven sweep to **velocity-driven** — it `set velocity to y:
CPU_PADDLE_SPEED`, the Stage drifts it down its rail, and its `forever` flips the velocity sign (and
snaps onto the rail) at the top/bottom edges. This both demonstrates velocity and removes the second
relay global (`right_paddle_y` was M41's `animate` target). The CPU paddle no longer eases at the
turns (constant speed); the `animate` block is untouched in the language, just unused by the demo.

What this leaves deferred: a **velocity *direction/speed* form** (today it's a raw `(vx, vy)` vector —
no "set speed" / "set heading" decomposition; compose with `direction` + trig), velocity that
**couples to `direction`** (move-along-facing is still `move_steps`), and any **drag / friction /
max-speed** built-ins (a `forever` with `change velocity` expresses them).

See [Cross-sprite position reporters + built-in velocity (M43)](#cross-sprite-position-reporters--built-in-velocity-m43).

---

## Earlier: Milestone 42 — sprite visual order (editor + blocks)

**Goal of this milestone:** let you **control which sprite draws in front of which** — Scratch's *go to
front / back layer, go forward / backward layers*. It has two halves:

1. **In the stage editor** — four **Layer** buttons reorder the selected sprite, a pure editor-side view
   change ([`editor.gd`](scripts/editor.gd) + [chrome](editor.tscn)); **no opcode, no data-shape, no
   runtime change**.
2. **In blocks** — two new LOOKS opcodes (`go_to_layer`, `change_layer`) restack a sprite at *play*
   time, the usual one-`_OPCODES`-entry + one-interpreter-handler each, **no block-data-shape change**.

The two halves use **different mechanisms for the same concept**, because z-order is expressed
differently at edit vs. play time. At edit/build time it is **sprite array order**: both the stage
view's [`_render`](scripts/stage_view.gd) (later entries drawn last, on top) and the runtime's
[`Stage._add_sprite`](scripts/stage.gd) build loop (a later child draws over an earlier one) walk
`_scripts` in order. At play time the nodes already exist, so the blocks restack via the node's
**`z_index`** ([`Stage.set_layer`](scripts/stage.gd) / [`change_layer`](scripts/stage.gd)) — every
sprite is built at `z_index 0` (so the editor's array order is the initial stack), and a layer block
overrides it. z_index decouples layer from tree position, so it composes with the camera / clones
without reparenting.

### The editor half — reorder the array

The inspector's Stage panel gains a **Layer** group — four buttons (**To Front / To Back / Forward /
Backward**) acting on the selected sprite ([`_reorder_selected`](scripts/editor.gd)). The reorder *is*
the edit (RUN reads array order, SAVE serialises it — the M9 data-is-canonical idiom at the project
level):

- **It reorders the array in place.** `remove_at` + `insert` on the same `Array` object (To Front →
  last slot, To Back → slot 0, Forward/Backward → ±1), so the stage view's `_sprites` **reference stays
  valid** — a `set_selected` re-render shows the new z-order *without* re-pointing the model, and the
  **pan survives** (unlike the full `_load_project_into_ui`, which recenters). The canvas is persisted
  first (`_current` is about to move), the selector is rebuilt in the new order and the moved sprite
  re-selected with a programmatic `select()` (which doesn't emit `item_selected`, so no `_show` / canvas
  reload fires — the same sprite stays loaded), and `BlockView.project_sprites` is re-pointed to keep the
  name list in step (order only; names unchanged, so no palette rebuild / canvas refresh is needed).
- **The buttons disable at the ends** ([`_sync_inspector`](scripts/editor.gd)): To Front / Forward grey
  out when the sprite is already frontmost (last slot), To Back / Backward when it's already backmost
  (slot 0) — so a no-op move reads as unavailable.

**Array order is the editor's single ordering**, so reordering z **also reorders the sprite selector**
(it lists `_scripts` in order) — the honest consequence of one ordering rather than a separate z field
(adding one would be a data-shape + persistence + runtime change the editor half deliberately avoids).

### The blocks half — restack at play time

Two LOOKS statements, the runtime counterpart of the editor buttons:

- **`go to {layer} layer`** (`go_to_layer`, `layer` ∈ {`front`, `back`}) → [`_on_go_to_layer`](scripts/interpreter.gd)
  → [`Stage.set_layer`](scripts/stage.gd): set the node's `z_index` just past the current extreme over
  all registered sprites, so it draws in front of / behind every other sprite.
- **`go {direction} {num} layers`** (`change_layer`, `direction` ∈ {`forward`, `backward`}, `num` a
  numeric slot) → [`_on_change_layer`](scripts/interpreter.gd) → [`Stage.change_layer`](scripts/stage.gd):
  shift the node's `z_index` by `num` (forward = toward the front, a `+` shift; backward = `−`), clamped
  to the engine's CanvasItem z range.

Both are plain `{opcode, inputs}` statements (so persistence/RUN carry them untouched) and need **no
editor change** beyond the two `_OPCODES` entries — `{layer}`/`{direction}` reuse the M13 fixed-choice
`enums` dropdown, `{num}` is an ordinary numeric slot. The Stage owns the mechanism (it must scan every
sprite to find the front/back extreme), the interpreter just names the intent — the camera-block
delegation pattern (M37).

The `go_to` caveat (M27) doesn't bite layers: a script may override a sprite's *position* at RUN, but
its *layer* is z_index, which only these blocks touch — so an editor layer edit (the initial build
order) holds at RUN until a layer block changes it.

See [Sprite visual order — editor + blocks (M42)](#sprite-visual-order--editor--blocks-m42).

---

## Earlier: Milestone 41 — animation blocks (tween a variable over time)

**Goal of this milestone:** add an **animation block** that takes a **variable** as its parameter and
**animates its value over time**, supporting **linear**, **ease-in**, and **ease-out** interpolation. It
is the usual symmetric extension the project is built around — **one opcode** (one `_OPCODES` entry +
one interpreter handler), **no block-data-shape change, no editor change** — the closest sibling so far
being the CAMERA blocks (M37), which were likewise pure `block_view.gd` + `interpreter.gd`.

The block is **`animate {name} to {value} over {seconds} secs {easing}`** (a single statement, new
slate-orchid `"animation"` category):

- **It reuses the existing slot machinery whole.** `{name}` is a **data-scoped dropdown** of the
  project's variables (`data_enums: {name: "variables"}` → `BlockView.project_variables`, the
  `set_var`/`variable` source — **no new resolver, no editor change**, the menu re-scopes per sprite for
  free), `{easing}` is a fixed-choice dropdown (`enums: {easing: ["linear", "ease in", "ease out"]}` —
  the M13 pattern), and `{value}`/`{seconds}` are ordinary numeric slots (so they accept literals,
  arithmetic — M29 — or dropped reporters). A plain `{opcode, inputs}` statement, so persistence (M22)
  and RUN (M10) carry it untouched.
- **The interpreter owns the tween** ([`_on_animate`](scripts/interpreter.gd)). Like `wait_seconds` (and
  Scratch's *glide*) it is a coroutine that **blocks the calling script for the duration** — the blocks
  after it run only once the animation finishes — yielding on the **fixed physics tick** the way
  `forever` does (so it never freezes the engine and the value advances at a constant real rate,
  `1.0 / Engine.physics_ticks_per_second` per step). It snapshots the **target** once at the start
  (evaluated in the current frame) and the **start** value as the variable's value at that moment, then
  each tick writes `lerpf(start, target, eased(t))` through [`_set_variable`](scripts/interpreter.gd) —
  so it lands wherever the name resolves (local-first, then global), exactly where a `set` block writes,
  and any script reading the variable (`go to x: (var)`) sees it move each frame. It polls the Stage /
  `_alive` flags, so `stop "all"` / `stop "this script"` mid-animation unwinds it within a frame
  (leaving the variable partway); it snaps exactly onto the target only when it runs to completion. A
  non-positive duration sets the variable straight to the target.
- **The easing curves** ([`_ease_fraction`](scripts/interpreter.gd)) map normalized time `t ∈ [0,1]` to
  an eased fraction: **linear** = `t` (constant rate), **ease in** = `t²` (slow start, accelerating),
  **ease out** = `1 − (1 − t)²` (decelerating to a slow stop) — the standard quadratic curves.

Animating a *variable* (rather than a sprite property directly) is the general primitive: wire the
variable into any block that reads it (`go to x: (x)`, `point in direction (angle)`, `say (n)`) and that
property tweens. What this leaves deferred: **other easing curves** (cubic, elastic, bounce — the
quadratic trio covers the milestone's linear/in/out ask), and a **direct "glide to x y"** convenience
block (you compose it from `animate` + `go to`). No camera/sprite-geometry tween shortcut.

See [Animation blocks (M41)](#animation-blocks-m41).

---

## Earlier: Milestone 40 — multiple-stage functionality removed

**Goal of this milestone:** **rip out the project-level scene (stage / level) layer** that M33/M34 added,
reverting to a **single flat project**. Multiple stages complicated persistence and cross-stage state we
weren't ready to tackle, and the top-bar scene chrome ate space we'd rather give to other controls — we
only need one stage right now. This is a **forward surgical removal**, not a `git revert`: M35–M39 were
all built on top of the scene model (M38's persistence was literally `{scenes, active}`, M37's runtime
read `project_scenes`), so the scene layer had to be collapsed out by hand while keeping everything
M35–M39 added.

What came out (the M33/M34 sections below are now **historical — the code they describe is removed**):

- **The editor's scene layer** ([`editor.gd`](scripts/editor.gd)). The `_scenes` list + `_scene` active
  index are gone; the editor again owns flat `_scripts` / `_variables` / `_background` / `_grid_settings`
  directly, seeded straight from `PongScripts.sprites()` / `variables()` / `background()` / `grid()` in
  [`_seed_demo`](scripts/editor.gd). The RUN→ESC restore statics went from `_restore_scenes`/`_restore_scene`
  to the four flat `_restore_scripts`/`_restore_variables`/`_restore_background`/`_restore_grid`. Deleted
  outright: `_load_scene_into_working`, `_persist_current_scene`, `_load_scene`, `_on_scene_selected`,
  the Add/Rename/Delete-scene handlers, `_scene_names`, and `_normalize_scene` (its sprite/background/grid
  back-fill folded inline into [`_apply_project`](scripts/editor.gd)).
- **The top-bar scene chrome** ([`editor.tscn`](editor.tscn)): the `SceneSelector`, `+ Scene` / `- Scene`
  / `Rename Scene` buttons, the separator, and the `SceneDialog` / `DelSceneDialog` are removed — the bar
  now goes Title → SpriteSelector directly.
- **The two scene-nav opcodes** `switch_scene` / `next_scene` ([`block_view.gd`](scripts/block_view.gd) +
  their [`interpreter.gd`](scripts/interpreter.gd) handlers), the slate-blue `"scenes"` category, and the
  `project_scene_names` static / `"scenes"` data-enum source.
- **The Stage's whole-scene-list hand-off** ([`stage.gd`](scripts/stage.gd)): `project_scenes` /
  `project_active` / `_active` and the runtime navigation methods (`go_to_scene_by_name` /
  `go_to_next_scene` / `_change_to_scene`, plus `_scene_list` / `_active_scene`) are replaced by the
  pre-M34 trio of statics `project_sprites` / `project_variables` / `project_background` with the
  `_sprite_model` / `_variable_model` / `_background_hex` fallback helpers (the editor's model when handed
  one, else PongScripts). `_GAME_SCENE` (only used by the removed `_change_to_scene`) is gone from the
  Stage.
- **The stock scene model** `PongScripts.scenes()` ([`pong_scripts.gd`](scripts/pong_scripts.gd)) — the
  four content builders it composed (`sprites` / `variables` / `background` / `grid`) stay.
- **Persistence** is back to a flat `{scripts, variables, background, grid}` JSON
  ([`_serialize_project`](scripts/editor.gd) / [`_apply_project`](scripts/editor.gd)). **No backward-compat
  in the loader** — it reads only the flat shape; a saved `{scenes, active}` file (or the stock
  `platformer.json`) must be migrated separately (a deliberate scope call — that's the next step).

What stayed: the RUN / ESC scene swap (`change_scene_to_file` between `editor.tscn` and `main.tscn`) — that
is the *Godot* scene mechanism, unrelated to the removed project-scene layer. No block-data-shape change,
no interpreter dispatch change beyond dropping two handlers; M35–M39's features are untouched. See
[Multiple-stage functionality removed (M40)](#multiple-stage-functionality-removed-m40).

---

## Earlier: Milestone 39 — stage-editor world grid

**Goal of this milestone:** make the stage editor's **alignment grid continue indefinitely** outside the
default screen, and turn the **screen-boundary indicator into a tiled grid of 480×352 screen cells in all
directions** (so adjacent screen spaces are visible) — **leaving the default (origin) screen highlighted**.
A pure editor-side view change in [`StageView`](scripts/stage_view.gd): M37's clipped, screen-only
`_screen_panel` (project-background fill + bright guide-line border + a child `_GridLayer` filling just the
screen) is replaced by **one full-view, pan-fixed `_GridLayer`** that redraws aligned to the pan
(`world_origin`) rather than moving. It paints, back-to-front: the **origin screen fill** (the project
background), the **fine alignment grid spanning the whole view** (`fposmod`-aligned to the world grid under
any pan, still toggled/recoloured by Show-grid / Grid colour / Grid step), the **screen-cell boundaries
tiled in all directions** (the same sky-blue hue, dimmed), and the **default screen's bright boundary
highlight** drawn last so it stands out from its neighbours. The layer is a direct child of `StageView`
(full rect, **not** in `_world`), so it always covers the visible area however far the world is panned;
`set_background` recolours the origin fill and `_apply_pan` feeds it the rounded pan so the grid stays
pixel-aligned with the panned sprites. No new opcode, no block-data-shape change, no runtime change. See
[Stage-editor world grid (M39)](#stage-editor-world-grid-m39).

---

## Earlier: Milestone 38 — web export save/open

**Goal of this milestone:** make SAVE / OPEN work on a **Web (WebAssembly) export** — where there is no
native `FileDialog` and no OS filesystem — by splitting M22's file methods into a transport-agnostic
*model* half ([`_serialize_project`](scripts/editor.gd) / [`_apply_project`](scripts/editor.gd)) and per-
transport shells: desktop keeps the `FileAccess` path, Web uses a browser download / `<input type=file>`
upload through `JavaScriptBridge`. Same `{scenes, active}` JSON either way; no block/runtime change. See
[Web export: browser save/open (M38)](#web-export-browser-saveopen-m38).

---

## Earlier: Milestone 37 — stage-editor world view, panning, and camera blocks

**Goal of this milestone:** make the **stage editor show the whole game world** (not just the 480×352
screen) so off-screen sprites are visible and editable, add **panning** + a **Recenter** button + a
**screen-boundary guide line** + **opaque panels** framing the chrome, and add a **camera block group**
(movement + tracking) so scripts can scroll the runtime view. Three layers:

1. **Stage editor becomes a pannable window onto the world** ([`StageView`](scripts/stage_view.gd)).
   Through M36 the stage view clipped everything to a centred 480×352 panel, so the Announcer (parked at
   -400,-400) and anything off-screen was invisible. M37 restructures it into a `_world` container
   (positioned at a `_pan` offset, **not clipped**) holding the **screen region** ([`_screen_panel`](scripts/stage_view.gd)
   — the project background fill + a bright **guide-line border** marking the playable 480×352) and the
   sprite `_layer` (sprites/overlay over the surrounding world). **Drag empty background to pan**
   (a new `{mode:"pan"}` branch in [`_input`](scripts/stage_view.gd), guarded to presses inside our own
   rect so the inspector still falls through; the `IDLE→PENDING→DRAGGING` spine and sprite drag/resize
   are unchanged), and a **Recenter view** button ([`recenter`](scripts/stage_view.gd)) re-frames on the
   screen. A dark `_backdrop` fills the out-of-bounds area. The pan is absorbed by `_world`'s position,
   so `_display_rect` and the child-rect hit-tests need no pan term — only [`_global_to_model`](scripts/stage_view.gd)
   gained it (via `_world.global_position`).

2. **A CAMERA block group** (4 new opcodes, [`block_view.gd`](scripts/block_view.gd)) — `set camera to
   x: {x} y: {y}`, `change camera by x: {dx} y: {dy}`, `camera follow {name}` (a sprites dropdown), and
   `camera stop following`. Each is the usual one-`_OPCODES`-entry + one-interpreter-handler step
   ([`_on_set_camera`](scripts/interpreter.gd) / [`_on_change_camera`](scripts/interpreter.gd) /
   [`_on_camera_follow`](scripts/interpreter.gd) / [`_on_camera_stop_following`](scripts/interpreter.gd)),
   all plain `{opcode, inputs}` statements — **no block-data-shape change**, so persistence (M22) carries
   them untouched. New slate-teal `"camera"` category.

3. **The runtime camera** ([`Stage`](scripts/stage.gd)). `_ready` adds a `Camera2D` (`_camera`) centred
   at (240,176) and `make_current()`s it — at that position the view is **identical** to the old
   no-camera transform, so a project with no camera blocks renders exactly as before. The background
   `ColorRect` moves onto a `CanvasLayer(layer -1)` so the backdrop stays **screen-fixed** while the
   camera pans (a `CanvasLayer` isn't transformed by a `Camera2D`). `_process` keeps the camera on the
   followed sprite each frame. The blocks call [`set_camera`](scripts/stage.gd) /
   [`move_camera`](scripts/stage.gd) / [`camera_follow`](scripts/stage.gd) /
   [`camera_stop_following`](scripts/stage.gd); manual set/move clears any follow (manual control wins).
   **Camera coordinates equal sprite coordinates** — the world point shown at the screen centre.

The chrome change is editor-only: [`editor.tscn`](editor.tscn) wraps the top **Bar** and the right
**Inspector** in opaque-stylebox `PanelContainer`s (`BarPanel` / `InspectorPanel`; all the inner
widgets keep `unique_name_in_owner`, so [`editor.gd`](scripts/editor.gd)'s `%Name` lookups are
unchanged) and adds a `%RecenterButton` wired in `_ready` to `_stage_view.recenter`. See
[Stage-editor world view + camera blocks (M37)](#stage-editor-world-view--camera-blocks-m37).

---

For context, the M36 mechanics this builds on:

**Curved (convex) paddle bounce in the demo (M36).** Made the Pong paddles deflect the ball as if they
were **convex** (bulging toward the centre): the rebound angle tracks *where* the ball strikes — centre
→ straight back, an end → steep deflection toward that end. A **demo-only**, existing-opcodes-only edit
to [`PongScripts`](scripts/pong_scripts.gd): each paddle **publishes its centre y into a global** every
tick (`set left_paddle_y / right_paddle_y to (y position)` in [`_paddle`](scripts/pong_scripts.gd) — two
new globals), and the ball offsets its own `y_position` from the paddle's relayed y and aims off
straight-back by `offset × PADDLE_BOUNCE_CURVE` ([`_paddle_bounce_dir`](scripts/pong_scripts.gd)):
**LEFT** → `(90 + offset×curve)`, **RIGHT** → `(270 − offset×curve)`. M35's sign-gate + `go_to` nudge
are kept; the gated angle range (`90/270 ± ~50°`) stays heading-away so the ball can't double-flip into
a stick. See [Curved (convex) paddle bounce (M36)](#curved-convex-paddle-bounce-m36).

---

For context, the M35 mechanics this builds on:

**Motion-state reporters; the demo's bounce as blocks (M35).** Paid off the deferral the `"bounce"` note carried for the project's whole
life — *expose the sprite's velocity/position as reporters* so a reflection can be expressed as **data**
instead of the `point_in_direction "bounce"` runtime sentinel. M35 adds three value reporters —
**`direction`**, **`x_position`**, **`y_position`** (motion category, no inputs; each reads the running
`Target`) — and **rewrites the Pong ball's bounce as blocks**: each of the four bounce `if`s reflects
the direction (`180 - direction` off the horizontal top/bottom edges, `360 - direction` off the vertical
paddles), **gated by an inner `if` on the motion's sign** so it only flips when heading *into* the
surface (reproducing [`_bounce()`](scripts/interpreter.gd)'s `absf` anti-stick steering), plus a `go_to`
**nudge** that snaps the centre clear (edge bounds = the 8px-inset viewport; paddle clear-x literals
`48`/`432` off the fixed rails).

**Three new opcodes; no block-data-shape change, no other runtime change.** Each is the usual
one-`_OPCODES`-entry ([`block_view.gd`](scripts/block_view.gd)) + one-interpreter-handler step
([`_on_direction`](scripts/interpreter.gd) / [`_on_x_position`](scripts/interpreter.gd) /
[`_on_y_position`](scripts/interpreter.gd)). The ball rewrite is a pure
[`PongScripts.ball()`](scripts/pong_scripts.gd) edit that rides `export_script()` → persistence/RUN
untouched. **`_bounce()` and the `"bounce"` sentinel stay in the runtime** as a supported opcode value
(any saved/hand-written script using it still runs) — the demo just no longer uses it.

**Faithful for Pong, not a general bounce.** The decomposition matches `_bounce`'s *observable* output
*because* every Pong surface is cleanly horizontal or vertical (so the runtime shallowest-overlap-axis
choice collapses to a known axis per-`if`) and the paddles ride fixed x-rails (so the push-out is a
constant). A general data-form bounce — arbitrary angles, dynamic overlap, moving/rotated obstacles —
would need trig reporters and cross-sprite geometry, which M35 does **not** add (and which is why
`_bounce()` is kept). See [Motion-state reporters — bounce as blocks (M35)](#motion-state-reporters--bounce-as-blocks-m35).

---

For context, the M34 mechanics this builds on:

**Runtime scene navigation (M34).** Paid off the half M33 deferred — **navigating between scenes at
*play* time**. M33 let a project hold multiple stages switchable in the *editor*, but RUN played only the
active one and no block could change scene mid-game. M34 adds the two blocks the user asked for —
**`switch to scene {name}`** (a data-scoped dropdown of the project's scenes — the "set the scene"
block) and **`next scene`** (advance, wrapping past the last to the first) — plus the runtime
machinery to carry *all* scenes into the game and rebuild for the target at play time.

**Two new opcodes (`switch_scene`, `next_scene`); no block-data-shape change.** Each is the usual
one-`_OPCODES`-entry ([`block_view.gd`](scripts/block_view.gd)) + one-interpreter-handler step
([`_on_switch_scene`](scripts/interpreter.gd) / [`_on_next_scene`](scripts/interpreter.gd)), both plain
`{opcode, inputs}` statements, so persistence (M22) carries them untouched. They get a new **`scenes`
category** (slate-blue) and `switch_scene`'s `{name}` is a data-scoped dropdown
(`data_enums: {name: "scenes"}` → the new static [`BlockView.project_scene_names`](scripts/block_view.gd),
the scene twin of `project_sprites`), so you pick a real scene rather than risk a typo.

**The mechanism reuses the project's existing scene-swap primitive.** A `switch_scene`/`next_scene`
doesn't tear sprites down by hand: the interpreter handler calls
[`Stage.go_to_scene_by_name`](scripts/stage.gd) / [`go_to_next_scene`](scripts/stage.gd), which
resolve a target index, point the new **static** [`Stage.project_active`](scripts/stage.gd) at it,
[`stop_all`](scripts/stage.gd) the current scripts (so every coroutine unwinds on its next poll), and
`get_tree().change_scene_to_file("res://main.tscn")` — exactly the swap RUN and ESC already use. The
new `Stage._ready` rebuilds from the new active scene with **no bespoke node/clone/coroutine teardown
code**, sharing the same coroutine-cleanup behaviour the working ESC return relies on.

**The structural change is *which* statics the editor hands the `Stage`.** Through M33 RUN handed one
scene's worth (`project_sprites`/`project_variables`/`project_background`); M34 **replaces those three
with one** [`Stage.project_scenes`](scripts/stage.gd) (the whole `{name, sprites, variables, background,
grid}` list) + `project_active` (the index to build first). The Stage still builds exactly **one** scene
at a time — it reads each per-scene field off the active scene dict
([`_active_scene`](scripts/stage.gd)) — so the build loops, [`BlockView`](scripts/block_view.gd),
[`BlockCanvas`](scripts/block_canvas.gd), and [`StageView`](scripts/stage_view.gd) are unchanged; only
the *source* moved up a level. A direct `main.tscn` launch still plays stock Pong via the
[`PongScripts.scenes()`](scripts/pong_scripts.gd) fallback ([`_scene_list`](scripts/stage.gd)). See
[Multiple stages — runtime scene navigation (M34)](#multiple-stages--runtime-scene-navigation-m34).

What this leaves deferred: a **scene-rename → `switch_scene` cascade** (renaming a scene doesn't rewrite
existing `switch to scene {name}` blocks naming the old name — they resolve to a runtime warning; the
live dropdown means freshly-dragged blocks are always correct — the same tradeoff M30 made before M32's
cascade), and **cross-scene shared state** (a scene change re-seeds variables to the new scene's
defaults — a "score" resets — since scenes own their variables; a project-global store carried across
scenes is a separate milestone).

---

For context, the M33 mechanics this builds on:

**Multiple stages (scenes / levels) (M33).** let a project hold **multiple stages (scenes / levels)** —
several independent stages you switch between at edit time, each with its **own sprites, variables,
backdrop, and grid**. Through M32 a project was a single flat scene: the editor owned one set of sprites
(`_scripts`), variables (`_variables`), a background (`_background`), and grid (`_grid_settings`);
persistence wrote `{scripts, variables, background, grid}`; RUN handed that one set to the `Stage`. M33
adds a **scene layer above all of that** — `_scenes` (the list) + `_scene` (the active index) — and a
top-bar **scene selector** + **Add / Delete / Rename Scene** buttons. **RUN plays the active scene.**

**No new opcode, no block-data-shape change, no runtime change.** A scene is just a new container dict
`{name, sprites, variables, background, grid}` — the M27/M24/M18 project pieces bundled and named — and
the `Stage` still receives exactly one scene's worth of data (`project_sprites`/`project_variables`/
`project_background`), so [`Stage`](scripts/stage.gd), [`BlockView`](scripts/block_view.gd),
[`BlockCanvas`](scripts/block_canvas.gd), and [`StageView`](scripts/stage_view.gd) are untouched — the
scene layer lives entirely in [`editor.gd`](scripts/editor.gd) (+ its [chrome](editor.tscn) and the
[`PongScripts.scenes()`](scripts/pong_scripts.gd) seed).

It is small and low-risk because the scene layer is a **structural mirror, one level up, of the
existing sprite-switch layer**. The editor's working vars (`_scripts`/`_variables`/`_background`/
`_grid_settings`) stay the **live editing surface for the active scene**
([`_load_scene_into_working`](scripts/editor.gd) points them at `_scenes[_scene]`'s fields), so every
existing per-sprite / per-variable code path is unchanged. Switching scenes persists the working vars
back into `_scenes[_scene]` ([`_persist_current_scene`](scripts/editor.gd) — the scene-level analog of
`_persist_current`), loads the chosen scene's into them, and rebuilds the UI
([`_load_scene`](scripts/editor.gd) → [`_load_project_into_ui`](scripts/editor.gd), the routine that
already "brings a sprite-set up," now reused per scene). Scenes are **fully self-contained** (each owns
its own variables — the answered design choice), so **sprite-name uniqueness is per-scene**: every name
check already runs against `_scripts` (the active scene), so two scenes may each have a "Sprite1" with
no change. Persistence reshaped to `{scenes, active}`, and a **pre-M33 `{scripts, variables, …}` file
is wrapped into one "Scene 1"** on OPEN so every existing save still opens. See
[Multiple stages (scenes) (M33)](#multiple-stages-scenes-m33).

What this leaves deferred: **runtime scene navigation** — a `switch_scene` / `next_scene`-style block
and the `Stage` teardown/rebuild to change scene *at play time* (RUN plays only the active scene) — and
**cross-scene shared state** (variables are per-scene; a project-global store carried across scenes,
e.g. a score across levels, is a separate milestone that pairs with runtime navigation).

---

For context, the M32 mechanics this builds on:

**Custom block rename cascade (M32).** It closed the loose end M30/M31 left — **renaming a custom block
cascades to its `call`s**. A `define`'s name is editable in place on the canvas (M30), but through M31 editing it left
every `call {name}` resolving the *old* name → a runtime warning. M32 makes the in-place rename rewrite
this sprite's calls, the custom-block analog of M21's variable rename and M25's sprite rename. It is the
*reachable* half of M31's deferred "rename/sync cascade": the **name** (the one thing the editor can
actually edit after creation). **Parameter** sync stays deferred for a principled reason — there is no UI
to edit a custom block's `params` after the Make-a-Block dialog, so no param-sync can be *triggered* yet;
adding param-editing is a milestone of its own (and `param` reporters key off the parameter name, not the
block name, so a *name* rename correctly leaves them alone).

**No new opcode, no block-data-shape change, no runtime change** — the cascade is a pure editor-side
rewrite of the same `{opcode, inputs}` dicts, riding `export_script()` → persistence/RUN like any edit.
Because custom blocks are **per-sprite** (a `define` lives in one sprite's script and `call` resolves it
there), the cascade runs over **the current canvas only** — smaller than M21/M25's cross-script walk.

The walk is one new static on [`BlockView`](scripts/block_view.gd):
[`rewrite_custom_block_refs`](scripts/block_view.gd) (the custom-block sibling of `rewrite_sprite_refs`)
reassigns the `inputs.name` of every `define`/`call` (`_CUSTOM_BLOCK_OPCODES`) matching the old name,
recursing into nested reporters / `body` substacks; a `call`'s `args` sub-dict and a `param`'s name are
left untouched (they bind to parameters, not the block). The trigger is **the in-place name commit**, no
new chrome: [`BlockView._define_header`](scripts/block_view.gd) stamps the define's name field with a
`define_name` meta, and [`BlockCanvas._commit_literal`](scripts/block_canvas.gd) recognises it — it
validates the new name (blank or one another `define` in the sprite already uses →
[`_other_define_named`](scripts/block_canvas.gd), revert the field, nothing cascades), then schedules
[`_rename_custom_block_deferred`](scripts/block_canvas.gd) via `call_deferred` (the cascade re-renders,
which frees the committing field — so it must not run inside the field's own commit signal). That
deferred step rewrites the calls and fires the editor hook
[`BlockCanvas.on_custom_block_renamed`](scripts/block_canvas.gd) →
[`editor._on_custom_block_renamed`](scripts/editor.gd), which re-derives this sprite's
`project_custom_blocks`/`project_custom_block_params` from the live canvas and rebuilds the palette +
refreshes the canvas (Make-a-Variable's refresh trio) — so the My-Blocks `call` chip relabels and every
`call {name}` dropdown lists the new name. With no editor hook set the canvas just re-renders itself.

What this leaves deferred: **parameter rename/add/remove sync** (needs a param-editing UI first — and a
rename-vs-add/remove heuristic, since params are name-keyed with no stable ids), plus M31's standing
deferrals — **boolean parameters** and a **return value**. **Deleting** a custom block from the UI (remove
the `define` + strip its `call`s, the My-Blocks twin of M21's variable delete) is also unbuilt.

---

For context, the M31 mechanics this builds on:

**Custom block parameters (M31).** give custom blocks **parameters** — pass arguments to a procedure. M30
added the custom block itself (`define {name}` + `call {name}`) but a procedure took no inputs; M31
lets a `define` declare named parameters, a `call` supply one argument value per parameter, and a new
**`param`** reporter read a parameter's value inside the body. Per the milestone's scope this is
**value (number/text) parameters only** (boolean params deferred), and a parameter is placed into the
body by **dragging a copy out of the define hat's prototype** — Scratch's "drag the argument
reporter out of the definition" gesture, reusing the palette's existing spawn-drag machinery.

This **adds one opcode** (`param`, the first since M30's two) and extends the *data shape* of
`define`/`call` — but the additions are the usual one-`_OPCODES`-entry + (for `param`) one-handler
step, and the shape extension is backward-compatible: a `define` gains an ordered `params: [names]`
list (absent ⇒ the M30 no-param define), a `call` gains an `args: {name: value}` dict (absent ⇒ the
M30 no-arg call), and `param` is a plain `{opcode, inputs:{name}}` reporter — so persistence (M22) and
RUN (M10) carry it untouched, and an M30 project still opens and runs.

The runtime change is a **parameter frame** in [`Interpreter`](scripts/interpreter.gd): a stack of
`{param: value}` dicts (`_frames`). [`_on_call`](scripts/interpreter.gd) evaluates a call's arguments
**in the caller's frame** (so a `param` used as an argument resolves to the caller's binding), pushes
a frame, `await`s the body, then pops it; [`_on_param`](scripts/interpreter.gd) reads the top frame
(0 + a warning if read outside any custom block). The stack supports nesting/recursion — an inner
call's frame shadows the outer for the duration of its body. Per-interpreter, so each sprite (and
clone) has its own frames.

The editor change is **data-driven rendering** of `define`/`call` (their shape now depends on the
data, which the static template couldn't express): [`BlockView._define_header`](scripts/block_view.gd)
draws "define" + the name field + one **spawnable parameter pill** per `params` entry (stamped
`spawn_opcode`/`spawn_name` so [`BlockCanvas._spawn_at`](scripts/block_canvas.gd) mints a fresh `param`
copy on drag — the prototype-to-body gesture), and [`_call_header`](scripts/block_view.gd) draws
"call" + the name dropdown + one argument slot per parameter, **built against the call's `args`
sub-dict** so the canvas's existing commit/drop/grab code writes straight into `args[param]` (it only
ever relies on a stamped dict reference + key). A `param` reporter renders as a read-only name pill
([`_param_pill`](scripts/block_view.gd)). A `param` drag is **confined to its own function's body**:
since a parameter is meaningful only inside the `define` that declares it,
[`BlockCanvas._nearest_slot`](scripts/block_canvas.gd) restricts a `param` drag (whether freshly
spawned from a prototype pill or an already-placed pill grabbed back out) to the slots inside that
define's body — [`_scoped_slots`](scripts/block_canvas.gd) keeps only the slots descending from the
body column whose `body_array` matches the stored define-body `Array`. That `Array` (the live data, so
stable across the re-render a pickup triggers) is captured by
[`_enclosing_define_body`](scripts/block_canvas.gd) at drag start; a `param` released anywhere outside
its body finds no legal slot and is discarded (reusing M14's off-slot path). The **"Make a Block"** dialog gains a parameters field
([`editor._parse_params`](scripts/editor.gd) splits it on commas/whitespace), and the palette's `call`
chips carry one `args` slot per the block's declared parameters (re-derived per sprite into the static
[`BlockView.project_custom_block_params`](scripts/block_view.gd), the params twin of
`project_custom_blocks`).

What this leaves deferred: **boolean parameters** (value-only this milestone — a boolean param would
need a boolean `param` output, a boolean arg slot, and a way to mark a param boolean in the dialog), a
**return value** (Scratch custom blocks are statements, as here), and the **rename/sync cascade** for a
custom block's name *and* its parameters (editing a `define`'s name or params doesn't rewrite the
`call`s/`param`s that target it — a newly-dragged `call` chip always reflects current params, but
existing calls keep their stale arg keys; M21/M25's cascades are the template). Binding is by **name**
(`args[param]`), so display order is cosmetic, a missing/stale arg evaluates to 0, and extra args not
in `params` are ignored.

---

For context, the M30 mechanics this builds on:

**Custom blocks — "My Blocks" (M30).** let you **create a custom function** — a named procedure of blocks you define
once and invoke many times. Through M29 the block language had no way to factor out a reusable routine;
M30 adds Scratch's "My Blocks": a **`define {name}`** hat (the procedure's definition — its body *is* the
function) and a **`call {name}`** statement (which runs that procedure). A `call` resolves its target by
name in the sprite's own script and `await`s the matching `define`'s body, so the blocks after the call
run only once the procedure returns (Scratch's sequential semantics). Custom blocks are **per-sprite**
(a `define` lives in one sprite's script; `call` resolves it there), like a sprite-local variable.

Unlike M13–M29 this **does add two opcodes** — but the additions are the usual one-`_OPCODES`-entry +
one-handler-each step, and there is **no block-data-shape change**: a `define`/`call` is a plain
`{opcode, inputs}` dict like every other block, so persistence (M22) and RUN (M10) carry it untouched.
The runtime change is small because the tree walker already had everything needed: `define` is a **hat**
(added to [`HAT_OPCODES`](scripts/block_view.gd)), so `run()`/`run_as_clone()` — which start only the
green-flag / clone hats — never auto-start it; it executes solely when
[`Interpreter._on_call`](scripts/interpreter.gd) finds it in the target's retained `_script` and runs its
body through the existing `_run_stack`. (A `call` whose body never returns — one containing `forever` —
never returns to the caller, by design; a recursion with no intervening `wait`/`forever` loops
synchronously, as in Scratch.)

The editor side mirrors the **"Make a Variable"** infrastructure exactly. A new **"My Blocks"** palette
group ([`BlockPalette`](scripts/block_palette.gd)) carries a **"Make a Block"** button (which pops a name
dialog — [`editor._make_block`](scripts/editor.gd) — and adds a fresh `define {name}` hat to the canvas
via [`BlockCanvas.add_definition`](scripts/block_canvas.gd)) plus one **pre-named `call` chip per defined
block**, the custom-block twin of the variables group's per-variable rows. The sprite's custom-block names
are **derived from its script** (the `define` hats — [`editor._custom_blocks_in`](scripts/editor.gd)),
not a separate model, and re-pointed into the static [`BlockView.project_custom_blocks`](scripts/block_view.gd)
per sprite (in [`_show`](scripts/editor.gd)) — so a `call {name}` slot is a **data-scoped dropdown** of
that sprite's real procedures (`data_enums: {name: "custom_blocks"}`), the exact pattern `touching_sprite?`
uses for sprite names. `define`/`call` carry a new `palette: false` flag so `palette_groups` never lists
them as generic chips; the My-Blocks group is the only place they enter the palette.

What this leaves deferred: **parameters** (a custom block takes no inputs yet — it is a name + a body, the
plain Scratch custom block; passing arguments needs a parameter frame in the interpreter and
procedure-scoped parameter reporters in the editor, a milestone of its own), a **return value** (Scratch
custom blocks are statements, not reporters — same as here), and a **rename/delete cascade** for a custom
block's name (editing a `define`'s name field doesn't yet rewrite the `call`s that target it — they
resolve to nothing → a runtime warning, until you fix them by hand; the sprite/variable rename cascades
of M21/M25 are the template for when this lands). Also still deferred from earlier: **embedding a live
*run*** of the game inside the editor (the M26 `SubViewport` restructure).

---

For context, the M29 mechanics this builds on:

**Arithmetic in a numeric slot (M29).** A numeric literal field evaluates an **arithmetic expression** on
commit. Through M28 a numeric slot took a single number and nothing else; M29 lets you type `2+3` / `90*2`
/ `(5-1)/2` and stores/shows the **result**. It is confined to literal coercion in
[`BlockView`](scripts/block_view.gd): [`coerce_literal`](scripts/block_view.gd)'s `TYPE_INT/TYPE_FLOAT`
branch keeps its `is_valid_float()` fast path, then tries [`_eval_arithmetic`](scripts/block_view.gd)
(which **whitelists** the text to digits/whitespace/operators *before* parsing, so Godot's `Expression`
can never resolve an identifier or call) and returns its finite numeric result, else falls through to the
existing string fallback (so `"bounce"` and other non-numeric sentinels are untouched). Only numeric slots
evaluate; Enter and focus-out behave identically (both route through `_commit_literal`). **No new opcode,
no block-data-shape change, no runtime change.**

---

For context, the M28 mechanics this builds on:

**Aspect-locked resize on the stage (M28).** Pay off M27's last deferral — **uniform / aspect-locked resize** in the
stage view. Through M27 a resize set `w` and `h` **independently** from the dragged corner (top-left-
anchored by default, centre-anchored with `Alt`), so you couldn't grow a sprite while keeping its shape.
M28 adds Scratch's/image-editors' aspect lock: **hold `Shift` while dragging a resize handle** and the
sprite scales to the **aspect ratio it had at the start of the drag**, so its proportions are preserved.
It is a tiny, self-contained follow-on — a pure **editor-side view** change in
[`StageView`](scripts/stage_view.gd) only: **no new opcode, no block-data-shape change, no
runtime-logic change, no new chrome.**

`Shift` follows the **same chrome-less, polled-each-frame modifier idiom as M27's `Alt`-for-centre** —
no UI toggle, no `editor.gd`/`editor.tscn` change — and the two **compose**: `Shift+Alt` is an
aspect-locked resize about the fixed centre. The implementation is small because M27 already routed both
resize branches through the model: M28 captures the sprite's starting `w/h` once at
[`_begin_drag`](scripts/stage_view.gd) (so int-rounding over the drag can't drift the ratio) and runs
both branches' proposed `(w, h)` through one new helper, [`_lock_aspect`](scripts/stage_view.gd), which —
while `Shift` is held — scales the captured `w0/h0` by whichever proposed axis grew more (the dragged
corner leads). The driving axis stays grid-snapped; the **derived** axis follows the ratio and so may
land off-grid — the aspect constraint deliberately wins over snap. The geometry write *is* the edit
(the M9 data-is-canonical idiom), so RUN/SAVE carry it untouched, exactly as a plain resize does.

What this leaves deferred: **embedding a live *run* of the game** inside the editor (a `SubViewport`
stage panel beside the canvas — the larger restructure M26 named, since the current RUN/ESC is a full
scene swap).

---

For context, the M27 mechanics this builds on:

**A static stage (scene) editor (M27).** A top-bar **Stage ⇄ Blocks toggle** swaps the workspace to a
**stage view** ([`StageView`](scripts/stage_view.gd)) that draws each sprite's placeholder rectangle at
its model `x/y/w/h/color` and lets you **select, drag, resize, and recolour** sprites directly, plus an
**inspector** (x/y/w/h spin boxes + a Colour picker, and the stage-level **Background** + alignment-grid
**show/snap/colour/step** settings) for exact values. It is the *scene* counterpart of the block canvas
(the canvas edits a sprite's *script*, the stage view its *geometry*) and a pure **editor-side view** over
the data-owned sprite model (M24), reusing [`BlockCanvas`](scripts/block_canvas.gd)'s `_input`-driven
hit-testing + `IDLE→PENDING→DRAGGING` spine. M28 changes only how a *resize* derives `w/h` — see
[The stage (scene) editor (M27)](#the-stage-scene-editor-m27).

---

For context, the M26 mechanics this builds on:

**Editor resolution decoupled from the fixed runtime viewport (M26).** Let the **block editor lay out at
a high resolution** while the **runtime stays locked to its fixed 480×360 logical viewport**. The editor had outgrown 480×360 — its chrome was
designed against that tiny logical space and upscaled wholesale, so blocks and text were chunky and the
workspace cramped — but the *game* genuinely needs 480×360: `go_to` coordinates, `touching_edge?` /
`_bounce` edge detection via `get_viewport_rect()`, and the integer-upscaled pixel-art `say` costumes
are all authored against it. M26 is a pure **display / content-scale** milestone — **no new opcode, no
block-data-shape change, no runtime-logic change** — that has each scene impose its own content-scale
policy on the shared window at launch.

The two scenes share one OS window but now stamp **opposite content-scale policies** on it in their
`_ready`:

- **The game re-imposes 480×360, integer-snapped.** [`Stage._apply_game_scaling`](scripts/stage.gd)
  (called first in `_ready`) sets `content_scale_size = _GAME_SIZE` (`480×360`, so `get_viewport_rect()`
  still reports 480×360 — *every bit of edge/position logic is untouched*), `CONTENT_SCALE_MODE_VIEWPORT`
  (the whole 2D world renders into that small viewport and blits up to fill the window),
  `CONTENT_SCALE_ASPECT_KEEP` (preserve 4:3, letterbox the slack), and **`CONTENT_SCALE_STRETCH_INTEGER`**
  — the whole-number-snap that keeps the `say` glyphs crisp. `content_scale_factor` stays `1.0`: it is an
  *extra* multiplier layered on top of the automatic fit, **not** the fit itself — a first cut set it to
  the computed integer factor and zoomed the view that many times too far (only a central slice showed).
- **The editor lays out at its own logical resolution.** [`BlockEditor._ready`](scripts/editor.gd) sets
  `content_scale_size = _EDITOR_SIZE` (`960×540` — the single zoom knob: larger → more room / smaller
  blocks, smaller → the reverse), keeps `CONTENT_SCALE_MODE_VIEWPORT` (the same stretch the M9
  [`BlockCanvas`](scripts/block_canvas.gd) manual global-coordinate hit-testing was written against, so
  dragging is unaffected), and uses `CONTENT_SCALE_ASPECT_EXPAND` (fill the window, no letterbox) +
  `CONTENT_SCALE_STRETCH_FRACTIONAL`. On a 1080p screen that is a clean 2× upscale — double the old
  480×360 workspace, blocks/text back to a readable size.

Because the editor and game **swap which policy the shared window carries**, each `_ready` re-asserts its
own on arrival — so the RUN→game→ESC→editor round trip (M10's RUN hand-off, M7's ESC return) restores the
editor's roomy layout every time. The project defaults ([project.godot](project.godot)) now only govern
the **initial window** before a scene's `_ready` runs (a 1280×720 starting size, fullscreen mode 3); the
per-scene overrides take it from there.

What this leaves deferred: **embedding the game inside the editor** (a live stage panel beside the
canvas) — that needs the runtime in a `SubViewport` rather than a full scene swap, a larger restructure;
and **finer editor zoom / font tuning** past the single `_EDITOR_SIZE` knob.

---

For context, the M25 mechanics this builds on:

- **Rename a sprite (M25).** A top-bar **Rename Sprite** button cascades a new sprite name across the
  selector, every `touching_sprite?` reference in *all* scripts (a sprite name is global, so the cascade
  is unscoped), and every variable `scope` field equal to the sprite; sprite *delete* now also strips the
  dangling `touching_sprite?` references it would leave. M26 changes none of this — it is a display-layer
  milestone over the same editor — see [Rename a sprite (M25)](#rename-a-sprite-m25).

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
   from the dropdown to load it). A project is a **single stage** — one set of sprites, variables,
   backdrop, and grid. (M33/M34 added multiple stages + `switch to scene` / `next scene` blocks; **M40
   removed all of that** — see the milestone note above.)
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
   **Type arithmetic into a numeric field** (M29) — `2+3`, `90*2`, `(5-1)/2` — and committing
   evaluates it to the result (`5`, `180`, `2`); a value that isn't a self-contained number/expression
   (e.g. `point_in_direction`'s `bounce`) is kept as typed.
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
   **Make a custom block** (M30) — a reusable function — with the **Make a Block** button at the top of
   the palette's MY BLOCKS group: click it, type a name (e.g. `jump`), confirm — a **`define jump`** hat
   appears on the canvas. Snap blocks into its body to define what `jump` does, then drag a **`call`** chip
   (one appears per custom block you've made) anywhere in a script to run it. A `call` runs the matching
   `define`'s body and continues once it returns. Custom blocks belong to **the sprite you're editing**
   (like a sprite-local variable), so the MY BLOCKS chips re-scope per sprite. Give it **parameters** (M31)
   by typing names in the dialog's parameters field; drag a parameter pill from the `define` hat into a
   slot to use that argument, and fill the matching slot on each `call`. **Rename** a custom block (M32) by
   editing the `define`'s name field on the canvas — every `call` of it in that sprite updates to match.
   **Drag a reporter from the palette into a slot** (M14) to drop an *expression* in — the
   palette now lists reporters (`+`, `score`, `touching … edge?`, …) as pills; drag one over
   a value/condition slot (a highlight marks the slot it will land in) and release to make,
   e.g., `move {10}` into `move {score}`. The slot's old value is replaced; a reporter
   dropped **off every slot now stays on the canvas as a free-floating block** (M46, Scratch's
   loose reporter) — drag it onto the palette to delete it.
   **Slots are typed** (M23): a **boolean** reporter (the rounded-off, angular pills — `>`, `touching
   edge?`, `and`) drops only into a **boolean** slot (an `if` condition, an `and`/`or`/`not` operand),
   and a **value** reporter (the round pills — `+`, `score`) only into a **value** slot (`move`'s steps,
   `set`'s value). Drag one over a slot of the wrong kind and **no slot highlights** — Scratch's
   hexagon-vs-round refusal — and releasing there leaves the pill free-floating on the canvas (M46,
   like any off-slot drop). The pill's shape tells you which slots will take it.
   **Grab a reporter that's already in a slot** (M15) to pull it back out — press the
   coloured body of a pill and drag; the slot reverts to its default value (`move {score}`
   back to `move {10}`), and you can drop the pill into another slot, **release it over empty canvas to
   leave it floating there** (M46), or drag it onto the palette to delete it. (A bare `score`/`variable`
   pill is almost all input field, so grab it by its thin coloured border; wider pills like `+` grab
   anywhere on the body. Pressing a pill's white field still edits that field.)
   **Reporters can live free on the canvas** (M46): a reporter dropped on empty space — whether dragged
   from the palette or pulled out of a slot — stays there as a free-floating pill, just like a statement
   stack. You can **grab it again** (drag it elsewhere, into a slot, or onto the palette to delete),
   **click** it to select it, **double-click** it to select it and its nested input pills, and
   **Delete/Backspace** or **Cmd/Ctrl+D** it as part of a selection. A free-floating reporter does
   nothing at RUN (it just parks on the canvas) but is saved with the project.
   **Delete a block** (M16) by dragging it **back onto the palette** and releasing — the same
   region you drag new blocks *from* doubles as the trash. Grab a statement block (it carries
   the blocks below it) or a reporter pill, drag it left over the palette — the ghost turns
   **red** to show it will be deleted (no snap bar / slot highlight) — and let go. Drop anywhere
   *off* the palette instead to place it as usual. (There's no undo; relaunch to reload a
   sprite's stock script.)
   **Select multiple blocks** (M46): **click** a block — a statement *or* a reporter pill — to select it
   (a white outline); **Shift/Cmd-click** to add or remove blocks one at a time; **double-click** a block
   to select it **and every block after it in that script, plus every block nested inside** (a C-block's
   body and any reporter pills in its inputs); or **drag a box over empty canvas** (rubber-band) to
   select everything it covers (Shift-drag adds to the current selection). Click empty canvas to clear.
   With a selection: **drag** any selected statement (or free-floating reporter) to **move them all
   together** (they gather into one run, snapping into a stack or landing free — drag them onto the
   palette to delete the lot), press **Delete/Backspace** to delete the selection, or **Cmd/Ctrl+D** to
   **duplicate** it as a new stack. (Move/delete/duplicate act on the selected statements and
   free-floating reporters — a pill *inside another block* is highlighted but those ops skip it; pull it
   out first. Selection is editor-only and not saved; switching sprites clears it. There's no undo.)
   **Collapse a script** (M47): click the **▼ chevron** at the left of any multi-block script to fold it
   into a one-line summary bar (the first block's label + a `+N` count of the blocks hidden), and the
   **▶ chevron** to expand it again — or select some blocks and press **Cmd/Ctrl+E** to collapse/expand
   their scripts at once. A collapsed script still drags, selects, deletes, and duplicates as one unit.
   Collapse is editor-only and not saved (a sprite switch re-expands everything), like the selection.
   Edits **persist** as you switch sprites (the session's project accumulates them).
   **Save your project** (M22) with **SAVE** in the top bar: pick a name and **location** in the file
   browser (it opens at the project folder by default, but you can save anywhere) and it writes a
   `.json` file, so your work survives relaunch. **OPEN** browses to reload a saved project; **NEW**
   returns to the stock **demo** (the in-code Pong) — the demo is never a file, so it is always there
   and your saved projects are never overwritten by it (or it by them). The title bar shows the open project's name (`(demo)` when unsaved). NEW/OPEN replace the
   working project, discarding unsaved canvas edits (there's no undo — SAVE first); launch always lands
   on the demo. (Canvas *layout* isn't saved — a reopened project re-flows its stacks to default
   positions, as a sprite switch already does.)
   **Edit the stage** (M27) with the **Stage** button in the top bar: it swaps the workspace from the
   block editor to a **stage view** showing every sprite as a rectangle at its position (the two paddles
   and the yellow ball; the tiny HUDs read as faint outlines, the Announcer is off-stage). **Click** a
   sprite to select it (the top-bar selector follows, and vice-versa); **drag** it to move it; drag the
   **bottom-right handle** to resize it — by default it grows rightward/downward (the top-left corner
   stays put), or **hold Alt** to resize about the centre, or **hold Shift** to keep the sprite's
   proportions (its aspect ratio is locked to where the drag started; Shift+Alt does both); and use the
   **inspector** on the right — x /
   y / w / h spin boxes and a **Colour** picker — for exact values. The inspector also holds the
   **stage-level settings**: a **Background** colour, and the alignment grid's **Show grid** / **Snap to
   grid** toggles, **Grid colour**, and **Grid step** (spacing, in stage pixels — default 8). Edits write
   straight into the project, so RUN reflects them and **SAVE** keeps them — **including the background
   and all grid settings**, which are reloaded with the project on OPEN. Click **Blocks** to return to
   the script editor. Note: a sprite
   whose script contains a `go_to` (the ball, the paddles) is repositioned by that block at RUN, so moving
   it on the stage won't change where it ends up in the demo — the block wins, as in Scratch; the stage
   position is the sprite's **starting** spot, which visibly matters for a fresh **+ Sprite** that has no
   `go_to`. (No on-stage move/resize is saved as *layout* — it's the model geometry, which RUN/SAVE carry.)
   **The stage view now shows the whole game world** (M37), not just the screen: a sprite parked
   off-screen (the Announcer) is visible and selectable, and the playable **480×352 screen is outlined
   with a bright guide line** (filled with the background colour, grid inside it). **Drag the empty
   background to pan** the world around (sprite drag/resize are unchanged — only empty space pans), and
   click **Recenter view** in the inspector to re-frame on the screen. The top bar and the right
   inspector sit on **opaque panels** so they read as distinct from the stage.
   **Reorder which sprite draws on top** (M42) with the inspector's **Layer** buttons — **To Front** /
   **To Back** / **Forward** / **Backward** act on the selected sprite (the buttons grey out at the
   ends). This reorders the sprite array, which is the z-order — so it also reorders the sprite selector,
   and RUN/SAVE keep it. To restack **at play time**, the palette's **LOOKS** group has the layer blocks
   **`go to {front/back} layer`** and **`go {forward/backward} {num} layers`** (e.g.
   `when_flag_clicked → go to front layer`), which move the running sprite's draw order via its z_index.
   **Scroll the runtime view with camera blocks** (M37) in the palette's **CAMERA** group: **`set camera
   to x: y:`** centres the view on a world point (camera coordinates are the same as sprite coordinates),
   **`change camera by x: y:`** scrolls it relative to where it is, **`camera follow {sprite}`** keeps the
   view centred on a sprite each frame, and **`camera stop following`** releases it. Wire e.g.
   `when_flag_clicked → forever → camera follow {Ball}` and at RUN the view scrolls to track the ball. A
   project that uses no camera blocks plays exactly as before (the camera sits at the default centre).
   **Animate a variable over time** (M41) in the palette's **ANIMATION** group: **`animate {name} to
   {value} over {seconds} secs {easing}`** smoothly tweens the chosen variable from its current value to
   `{value}` across `{seconds}`, with `{easing}` = **linear** / **ease in** / **ease out**. It blocks
   the script for the duration (like `wait`), so blocks after it run when the tween finishes. Pick a real
   variable from the `{name}` dropdown, then read it where you want the motion — e.g. a sprite with
   `when_flag_clicked → animate x to 400 over 2 secs ease out`, and a `forever → go to x: (x) y: 100`,
   glides across and eases to a stop. (Animating a variable is the general primitive — wire it into
   `go to`, `point in direction`, `say`, …)
   **Paint a sprite's costume** (M45) with the **Paint** button in the top bar (beside **Stage**): it
   swaps the workspace to a **pixel grid** with a tools panel. Pick a colour from the **palette**
   swatches, choose **Pencil** / **Eraser** / **Fill** / **Eyedropper**, and **click or drag on the
   grid** to draw (eraser paints transparent — shown as a checkerboard; fill flood-fills a region;
   eyedropper picks a pixel's colour). **Edit colour** recolours the selected swatch (every pixel using
   it updates live), and **Clear all** empties the costume. The sprite now renders that pixel art at
   RUN — **crisp and never stretched** (1 costume pixel = 1 stage pixel) — and **SAVE** keeps it. A
   sprite you never paint stays its flat **Colour** (Stage view), and a costume's resolution is fixed
   when you first paint it (so the Stage view's resize handle and the inspector's w/h are disabled for a
   painted sprite — resize the canvas is deferred).
4. Click **RUN** in the editor's top bar to launch the game (`main.tscn`, the
   `Stage`). **RUN now plays your edited scripts** (M10) — each sprite runs your
   version, or the stock script if you didn't touch it. Press **ESC** in-game to
   return to the editor (the inverse of RUN's editor→game hand-off). With no edits it
   plays the M7 Pong exactly as before:
   A yellow ball serves from the center at a **randomized angle** and bounces off
   the top/bottom walls and both paddles. The paddles are **convex (curved toward the
   centre)** (M36): hit the ball with the middle of a paddle and it goes nearly straight
   back, hit it with an end and it deflects steeply toward that end — so you aim by
   positioning the paddle. The **left paddle is player-controlled — W/S *or* ↑/↓** (M41
   moved the arrow keys here). The **right paddle is now a CPU paddle (M41)**: it glides
   up and down its rail on its own, driven by the `animate` block tweening its position
   variable (`ease out`, so it decelerates into each turning point), rather than answering
   keys.
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

### Editor resolution decoupled from the runtime (M26)

The editor outgrew 480×360. Through M25 the *whole* project — editor chrome included — rendered into a
single 480×360 logical viewport (`window/stretch/mode="viewport"`, a **project-wide** setting) and was
upscaled to fill the window, so the palette, canvas, and dialogs were laid out against 480 logical pixels
and stretched: chunky and cramped. The runtime, though, *needs* 480×360 — `go_to` coordinates,
`touching_edge?` / `_bounce` edge detection (`get_viewport_rect()` in [interpreter.gd](scripts/interpreter.gd)),
and the integer-upscaled pixel-art `say` costumes are all authored against it. M26 lets the editor lay out
at a high resolution while the runtime stays pinned to 480×360, by having **each scene set the shared
window's content-scale policy in its own `_ready`** rather than relying on the one project-wide stretch.
**No new opcode, no block-data-shape change, no runtime-logic change** — only the window's *presentation*
differs per scene.

- **The lever: per-window content scale, set at runtime.** Godot's `Window.content_scale_*` properties
  decouple a window's **logical** resolution (what Controls / `get_viewport_rect()` see) from its
  **pixel** resolution. The project-wide `stretch/mode` is just the default before a scene's `_ready`
  runs; both scenes override it. [project.godot](project.godot)'s `[display]` now carries only the
  initial window (1280×720, fullscreen mode 3) and a comment pointing at the two `_ready` methods.
- **The game re-imposes 480×360, integer-snapped.** [`Stage._apply_game_scaling`](scripts/stage.gd)
  (called first thing in `_ready`, before sprites build) sets `content_scale_size = _GAME_SIZE` (`480×360`
  — so `get_viewport_rect()` still reports 480×360 and **no runtime logic changes**),
  `CONTENT_SCALE_MODE_VIEWPORT` (the 2D world renders into the small viewport and blits up),
  `CONTENT_SCALE_ASPECT_KEEP` (keep 4:3, letterbox the slack), and `CONTENT_SCALE_STRETCH_INTEGER` — the
  whole-number-snap (Godot 4.2+) that is the *correct* "strict integer" knob and keeps the bitmap glyphs
  crisp. `content_scale_factor` stays `1.0`: it multiplies *on top of* the automatic fit, so setting it to
  the computed integer factor (a first cut did) zooms the view that many times too far — the bug that
  showed only a central slice of the playfield.
- **The editor lays out at its own larger logical resolution.** [`BlockEditor._ready`](scripts/editor.gd)
  sets `content_scale_size = _EDITOR_SIZE` (`960×540` — the **single zoom knob**: bigger → more room /
  smaller blocks; smaller → the reverse), keeps `CONTENT_SCALE_MODE_VIEWPORT` (deliberately — the M9
  [`BlockCanvas`](scripts/block_canvas.gd) manual global-coordinate hit-testing was written against the
  viewport-stretch coordinate transform, so reusing it leaves dragging untouched),
  `CONTENT_SCALE_ASPECT_EXPAND` (fill the window, no letterbox), and `CONTENT_SCALE_STRETCH_FRACTIONAL`
  (smooth scaling to any screen; also *resets* the INTEGER snap the game left). On a 1080p screen that is
  a 2× upscale — double the old 480×360 workspace, blocks/text readable again.
- **Each scene re-asserts its own policy on arrival.** The editor and game swap which content-scale policy
  the one shared window carries, so the RUN→game (M10) and ESC→editor (M7) hand-offs each restore the
  arriving scene's layout — no separate teardown needed. A first cut reset the editor to
  `CONTENT_SCALE_MODE_DISABLED` (raw window pixels, factor 1), which made the chrome lay out at ~1920px
  with no upscale — minuscule; the `_EDITOR_SIZE` viewport is the fix.

Still deferred (see [Deliberately deferred](#deliberately-deferred-to-a-later-milestone)): **embedding the
game inside the editor** (a live stage panel beside the canvas) — that needs the runtime in a `SubViewport`
rather than a full scene swap; and **finer editor zoom / theme-font tuning** past the one `_EDITOR_SIZE`
knob. The **scripts** stay shared-seed in spirit (editor and Stage both read `PongScripts.sprites()` /
`variables()`), as since M18/M24.

### The stage (scene) editor (M27)

The deferral M24 opened and the docs kept naming: *editing a sprite's starting geometry from the UI*.
M24 made the sprite set data-owned (`{name, x, y, w, h, color, script}`) and M25 made its *name*
editable, but `x/y/w/h/color` were editable only by hand-editing [`PongScripts.sprites()`](scripts/pong_scripts.gd)
or a saved `.json`. M27 adds a **stage view** that makes that geometry directly manipulable. It is the
*scene* counterpart of the block canvas — and, like M24/M25, a pure editor-side view over the existing
model: **no new opcode, no block-data-shape change, no runtime-logic change.** RUN already builds each
sprite at its model geometry ([`Stage._add_sprite`](scripts/stage.gd)) and SAVE already serialises it
([`_write_project`](scripts/editor.gd)), so geometry edits ride those paths untouched.

- **The surface.** [`StageView`](scripts/stage_view.gd) (`stage_view.gd`, parallel to
  [`BlockCanvas`](scripts/block_canvas.gd)) holds a **reference to `editor._scripts`** — the same dicts
  RUN/SAVE read — and re-renders from it (`_render`, clear-and-rebuild, ~6 sprites so cheap): one styled
  `Panel` per sprite filled with its colour (a faint 1px border so a 1×1 transparent sprite — the HUDs,
  `#ffffff00` — is still visible/grabbable), and on the **selected** sprite a yellow outline plus four
  corner resize handles. A sprite is drawn **centred on its model position** (the convention the runtime's
  AABB collision uses), scaled by the single `_DISPLAY_SCALE` knob into a 480×360 bordered region that
  `clip_contents` (an off-stage sprite is clipped, not bled over the inspector).
- **The interaction, reused from M9.** It drives from `_input` with manual **global-coordinate
  hit-testing** (`_hit`: a resize handle first — the most specific target, cf. M15's `_reporter_at`
  before `_block_at` — then the topmost sprite body), an `IDLE → PENDING → DRAGGING` state machine with
  the same 4px `DRAG_THRESHOLD` (a press that doesn't move *selects*; one that crosses the threshold
  *drags*). A **move** writes the entry's `x/y` from the cursor (offset-anchored so the sprite doesn't
  snap its centre to the grab point); a **resize** **anchors the top-left corner** (growing right/down,
  recomputing the centre as `w/h` change) — or, with **Alt** held, keeps the **centre fixed** — clamped
  to a min. All written **rounded to int** (the model's shape, which
  `Stage` reads with `int(...)`). The geometry write *is* the edit — the M9 data-is-canonical idiom.
- **Wired to the editor like its siblings.** Selection routes back through the editor's normal
  selector/`_show` path via an injected `on_pick` callback (so `_current`, the selector, and the hidden
  canvas stay consistent — switching back to Blocks shows the right sprite), and a drag reports live
  geometry via `on_geometry_changed` so the inspector tracks. The **inspector**
  ([editor.tscn](editor.tscn): `%InspX/Y/W/H` `SpinBox`es + `%InspColor` `ColorPickerButton`) reads the
  selected sprite ([`_sync_inspector`](scripts/editor.gd), guarded by `_loading_inspector` so a read
  can't echo back) and writes geometry/colour back ([`_write_geom`](scripts/editor.gd) /
  [`_on_insp_color`](scripts/editor.gd), the latter storing `"#" + Color.to_html(true)` — M24's
  JSON-clean hex format). Both metas / both edit paths mutate the same model dicts and re-render.
- **The toggle.** A top-bar **Stage ⇄ Blocks** button ([`_toggle_view`](scripts/editor.gd)) flips
  `_stage_mode` and the three workspace children's `visible` (palette + canvas vs the stage container);
  an `HBoxContainer` skips `visible == false` children so each mode fills the width. The hidden surface
  still receives `_input`, so [`BlockCanvas`](scripts/block_canvas.gd) /
  [`BlockPalette`](scripts/block_palette.gd) `_input` now lead with an `is_visible_in_tree()` guard. The
  editor keeps the stage view in step on every path that changes the model: `_show` (sprite switch),
  `_load_project_into_ui` (NEW/OPEN/Add/Delete re-point the array via `set_model`), and the sprite rename.

The `go_to` caveat is real and Scratch-faithful: a sprite whose script repositions itself (the ball,
the paddles) ignores its model `x/y` at RUN — the block wins. The model position is the **starting**
state; it visibly drives a sprite with no `go_to`. Still deferred at M27: a **live embedded run** (a
`SubViewport` stage panel — the M26 restructure) and **uniform / aspect-locked resize** —
**M28 (above) delivered the latter** (`Shift` locks the resize to the sprite's starting proportions).

**Stage-view refinements (within M27).** Three follow-on tweaks to the stage editor, all editor-side
over the same model:

- **Editable stage background.** The backdrop colour is now a real **project property** — a
  [`PongScripts.background()`](scripts/pong_scripts.gd) hex string (the stage-level sibling of
  `variables()` / `sprites()`), held mutably by the editor as `_background`, edited via the inspector's
  **Background** [`ColorPickerButton`](editor.tscn) ([`_on_insp_bg_color`](scripts/editor.gd) /
  [`_sync_background`](scripts/editor.gd)), **saved** under a top-level `"background"` key in the
  `.json` ([`_write_project`](scripts/editor.gd) / [`_read_project`](scripts/editor.gd), which defaults
  it for a pre-M27 file), and **applied at RUN** — handed over as [`Stage.project_background`](scripts/stage.gd)
  and painted by a full-viewport `ColorRect` added behind every sprite in [`Stage._ready`](scripts/stage.gd)
  (falling back to `PongScripts.background()` on a direct launch, like `project_sprites`/`project_variables`).
  [`StageView.set_background`](scripts/stage_view.gd) recolours the stage region live.
- **One resize handle, top-left-anchored.** The selection overlay draws a **single bottom-right**
  handle ([`StageView._render`](scripts/stage_view.gd)). By default a resize **anchors the top-left
  corner** — only the right/bottom edges move, so the sprite grows rightward/downward — which the
  bottom-right handle reads naturally for; **holding Alt** ([`Input.is_key_pressed(KEY_ALT)`] in
  [`_update_drag`](scripts/stage_view.gd)) resizes about the **fixed centre** instead (the symmetric,
  grow-in-all-directions behaviour). Since the model stores `x/y` as the *centre*, the default path
  recomputes the centre as w/h change so the top-left stays put.
- **An alignment grid with show / snap / colour / step — all project properties.** A
  [`_GridLayer`](scripts/stage_view.gd) (a small custom-`_draw` child behind the sprites) paints a grid
  at `_grid_step` model-px (default 8). The inspector's **Show grid** / **Snap to grid** checkboxes,
  **Grid colour** picker, and **Grid step** spin box drive it via `StageView.set_grid_show` /
  `set_grid_snap` / `set_grid_color` / `set_grid_step`; both toggles default on. Unlike the original
  M27 cut (where these were session-only aids), the grid is now a **real project property** —
  [`PongScripts.grid()`](scripts/pong_scripts.gd) `{show, snap, color, step}` (the stage-level sibling
  of `background()`), held mutably by the editor as `_grid_settings`, edited via the
  [`_on_grid_*`](scripts/editor.gd) handlers, **saved** under a top-level `"grid"` key in the `.json`
  ([`_write_project`](scripts/editor.gd) / [`_read_project`](scripts/editor.gd), which overlays the
  saved values onto the stock defaults so a pre-grid file still opens), and **synced to the controls +
  stage view on every project load** ([`_sync_grid`](scripts/editor.gd), the mirror of `_sync_background`).
  It stays **editor-only** (not handed to the running game — the grid is an authoring aid, not part of
  the scene). Snapping is applied **only inside a drag** ([`_update_drag`](scripts/stage_view.gd) via
  [`_snap_model`](scripts/stage_view.gd)): a **move** snaps the sprite's centre to the grid, a **resize**
  snaps the dragged corner (the handle) — so flipping the Snap toggle never re-snaps the existing
  sprites, it only governs the user's next change.

### Aspect-locked resize (M28)

The deferral M27 left open and its docs named: *uniform / aspect-locked resize*. Through M27 a resize in
the stage view set `w` and `h` **independently** from the dragged corner, so there was no way to grow a
sprite while keeping its proportions. M28 adds it: **holding `Shift` while resizing locks the sprite to
the aspect ratio it had at the start of the drag.** Like M27 it is a pure editor-side view change — **no
new opcode, no block-data-shape change, no runtime-logic change** — and, like M24/M25, it only changes
how a drag *derives* the model geometry; the write *is* the edit, so RUN/SAVE carry it untouched.

- **The modifier idiom, reused.** `Shift` is polled each frame with
  [`Input.is_key_pressed(KEY_SHIFT)`](scripts/stage_view.gd) — the **same chrome-less convention as M27's
  `Alt`-for-centre**, so there is no UI toggle and no `editor.gd`/`editor.tscn` change (the change lives
  entirely in [`stage_view.gd`](scripts/stage_view.gd)). The two **compose**: `Alt` chooses the anchor
  (top-left vs centre), `Shift` constrains the proportions, so `Shift+Alt` is an aspect-locked resize
  about the fixed centre.
- **Capture the ratio once, at drag start.** [`_begin_drag`](scripts/stage_view.gd) now records the
  sprite's `w/h` into `_resize_w0` / `_resize_h0` for a resize (the move branch still records its grab
  offset). Capturing **once** is load-bearing: the model is mutated live each frame and rounded to int,
  so recomputing the ratio from the current entry would let it drift over a long drag — the start ratio
  is the stable reference. Guarded to `>= 1` so a 1×1 HUD still has a usable ratio.
- **One helper gates both branches.** [`_lock_aspect(w, h)`](scripts/stage_view.gd) passes the proposed
  `(w, h)` through unchanged unless `Shift` is held, in which case it scales the captured `w0/h0` by
  `max(w / w0, h / h0)` — whichever axis the cursor pushed proportionally further wins, so the **dragged
  corner leads** (the image-editor convention; the handle stays at-or-beyond the cursor). Both
  [`_update_drag`](scripts/stage_view.gd) resize branches — the default top-left-anchored one and the
  `Alt`-centre one — now route their proposed size through it before the existing `roundi` + `_MIN_DIM`
  clamp, so the lock applies identically to either anchor.
- **Snap interaction, stated.** The proposed size still comes from `_snap_model` (the M27 grid snap), so
  the **driving** axis stays grid-aligned; the **derived** axis is `w0/h0`-scaled and so may land
  off-grid. That is deliberate — when both Snap and aspect-lock are on, the aspect constraint wins, since
  a sprite can't satisfy a fixed ratio *and* land both corners on the grid in general.

What this leaves deferred (see [Deliberately deferred](#deliberately-deferred-to-a-later-milestone)): the
**live embedded *run*** of the game inside the editor (a `SubViewport` stage panel — the M26 restructure,
the current RUN/ESC being a full scene swap). The **scripts** remain shared-seed in spirit (editor and
Stage both read `PongScripts.sprites()` / `variables()`), as since M18/M24.

### Arithmetic in a numeric slot (M29)

A numeric literal field now evaluates an **arithmetic expression** on commit. Through M28 a numeric slot
took a single number and nothing else; M29 lets you type `2+3` / `90*2` / `(5-1)/2` and stores/shows the
**result**. It is small because M12's commit pipeline already writes-and-re-stringifies whatever
[`coerce_literal`](scripts/block_view.gd) returns — so the change is confined to that one function.
**No new opcode, no block-data-shape change, no runtime change.**

- **One coercion branch, extended.** [`coerce_literal`](scripts/block_view.gd)'s `TYPE_INT/TYPE_FLOAT`
  case keeps its `is_valid_float()` fast path, then — for text that isn't a plain number — tries
  [`_eval_arithmetic`](scripts/block_view.gd) and returns its finite numeric result, falling through to
  the **existing string fallback** otherwise (so `point_in_direction`'s `"bounce"` and any other
  non-numeric text stay strings, exactly as before). The int-when-whole normalization both paths share is
  factored into [`_as_number`](scripts/block_view.gd).
- **Safe evaluation.** [`_eval_arithmetic`](scripts/block_view.gd) **whitelists** the text against
  `_ARITHMETIC_RE` (digits, whitespace, and `+ - * / % ( )` only) *before* parsing, so Godot's
  `Expression` can never resolve an identifier or method call (`OS`, `randi`, …). It returns `null` on a
  whitelist miss, a parse error, a non-numeric result, or a non-finite one (a ÷0 → inf/nan) — in every
  such case `coerce_literal` keeps the raw text rather than inventing a number.
- **Numeric slots only; Enter == focus-out.** Coercion is keyed by the slot's previous type, so a
  **string** slot keeps `"2+3"` verbatim — only oval/numeric fields do math. Both
  [`text_submitted` and `focus_exited`](scripts/block_canvas.gd) route through
  [`_commit_literal`](scripts/block_canvas.gd), so pressing Enter and clicking away evaluate identically.

Still deferred: arithmetic referencing **variable reporters** inside a literal field — compose those with
operator blocks (`+`, `variable`); the field only evaluates a self-contained numeric string.

### Custom blocks — "My Blocks" (M30)

The first **new opcodes since M7**, and the first way to **factor out a reusable routine**: a custom block
(Scratch's "My Blocks"). A **`define {name}`** hat holds the procedure's body; a **`call {name}`**
statement runs it. Custom blocks are **per-sprite** — a `define` lives in one sprite's script and a `call`
resolves it there — like a sprite-local variable. It is the symmetric one-entry-per-block extension the
project is built around (one `_OPCODES` entry + one interpreter handler each), with **no
block-data-shape change**: a `define`/`call` is a plain `{opcode, inputs}` dict, so persistence (M22) and
RUN (M10) carry it for free.

- **Runtime.** [interpreter.gd](scripts/interpreter.gd) registers `define`/`call`.
  [`_on_define`](scripts/interpreter.gd) just runs its body as a nested stack — but a `define` is never
  *started*: `define` is in [`BlockView.HAT_OPCODES`](scripts/block_view.gd), and `run()`/`run_as_clone()`
  launch only the green-flag / clone hats, so a procedure executes solely when called.
  [`_on_call`](scripts/interpreter.gd) looks the name up among the target's retained `_script`
  (custom blocks are per-sprite, like locals) and `await`s the matching `define`'s body through the
  existing `_run_stack` — so the blocks after the call run only once the procedure returns (Scratch's
  sequential semantics). An unknown name warns and is a no-op. No parameter passing: the body sees the
  caller's variables directly (a custom block is a name + a body). A `call` whose body never returns (one
  containing `forever`) doesn't return to the caller, and an un-guarded recursion loops synchronously — as
  in Scratch.
- **The renderer.** [block_view.gd](scripts/block_view.gd) gets the two `_OPCODES` entries, a new
  **`custom`** category (Scratch's pink `#ff6680`), and a new optional field **`palette: false`** on both —
  so [`palette_groups`](scripts/block_view.gd) does *not* list them as generic chips (they enter the
  palette only through the My-Blocks group, below). `define`'s `{name}` is a free-text literal (editable in
  place); `call`'s `{name}` is a **data-scoped dropdown** (`data_enums: {name: "custom_blocks"}`) resolving
  to the new static [`project_custom_blocks`](scripts/block_view.gd) — the exact `touching_sprite?`
  pattern, now for procedure names ([`_options_for`](scripts/block_view.gd) gains the `"custom_blocks"`
  source).
- **The editor, mirroring "Make a Variable".** Custom-block names are **derived from the data** (the
  `define` hats in a sprite's script — [`editor._custom_blocks_in`](scripts/editor.gd)), not a separate
  model, the way `_sprite_names` derives sprite names. [`_show`](scripts/editor.gd) re-points
  `BlockView.project_custom_blocks` per sprite (beside `project_variables`), so a `call` slot lists this
  sprite's procedures. The palette's new **"My Blocks"** group ([`BlockPalette._build`](scripts/block_palette.gd),
  rendered specially like the variables group) draws a **"Make a Block"** button atop and one pre-named
  **`call` chip per defined block** beneath (each chip carries a `palette_name` meta so the drag mints a
  block that calls *that* procedure — [`_input`](scripts/block_palette.gd), via a `_chip_at` that now
  returns the chip Control so its name is reachable). "Make a Block" pops a name dialog
  ([`editor._make_block`](scripts/editor.gd) / the `BlockDialog` in [editor.tscn](editor.tscn)); on confirm
  [`_on_new_block_confirmed`](scripts/editor.gd) adds a `define {name}` hat to the canvas
  ([`BlockCanvas.add_definition`](scripts/block_canvas.gd) — a new top-level stack), re-derives
  `project_custom_blocks` from the live canvas, and rebuilds the palette + canvas — so the new procedure
  shows immediately as a chip and in every `call` dropdown (the Make-a-Variable refresh trio).

Still deferred (see [Deliberately deferred](#deliberately-deferred-to-a-later-milestone)): **parameters**
(arguments + procedure-scoped parameter reporters — a parameter-frame milestone of its own), a **return
value** (Scratch custom blocks are statements, as here), and a **rename/delete cascade** for a custom
block's name (renaming a `define` doesn't yet rewrite the `call`s that target it — M21/M25's cascades are
the template).

### Multiple stages (scenes) (M33)

A project goes from a single flat scene to a list of **independent stages (scenes / levels)**. Through
M32 the editor owned one set of sprites (`_scripts`), variables (`_variables`), a background, and a grid;
M33 bundles those four pieces into a **scene** dict `{name, sprites, variables, background, grid}` and
lets a project hold several, switchable from the top bar. It is the editor's last "one of these, made
many" step — the sprite-set counterpart of M24's "sprites are a list," lifted one level. **No new
opcode, no block-data-shape change, no runtime change**: a scene is plain dicts/arrays, and the `Stage`
still receives exactly one scene's worth of data at RUN, so [`stage.gd`](scripts/stage.gd),
[`block_view.gd`](scripts/block_view.gd), [`block_canvas.gd`](scripts/block_canvas.gd), and
[`stage_view.gd`](scripts/stage_view.gd) are untouched — the change lives in
[`editor.gd`](scripts/editor.gd), its [chrome](editor.tscn), and the
[`PongScripts.scenes()`](scripts/pong_scripts.gd) seed.

- **The model + the seed.** [`PongScripts.scenes()`](scripts/pong_scripts.gd) composes the existing
  per-scene content builders (`sprites()` / `variables()` / `background()` / `grid()`, all unchanged)
  into one stock scene "Scene 1" — the scene counterpart of `sprites()`/`variables()`. The editor seeds
  `_scenes` from it ([`_seed_demo`](scripts/editor.gd)) and tracks the active index in `_scene`.
- **Working vars are the active scene, by reference.** The editor's `_scripts` / `_variables` /
  `_grid_settings` are pointed at `_scenes[_scene]`'s arrays/dict
  ([`_load_scene_into_working`](scripts/editor.gd)), so they *are* the active scene's data and every
  M9–M32 per-sprite / per-variable path edits it in place. `_background` is a String (a value), so it
  is the one field written back explicitly. [`_persist_current_scene`](scripts/editor.gd) (the
  scene-level analog of `_persist_current`) folds the active sprite's canvas into `_scripts`, then
  rebinds `_scenes[_scene]` to the current working refs — called before every scene switch, SAVE, and
  RUN, the three moments the scene list must be current.
- **Switching scenes reuses the bring-up routine.**
  [`_load_scene(index)`](scripts/editor.gd) persists the outgoing scene, lifts the chosen one into the
  working vars, and calls [`_load_project_into_ui`](scripts/editor.gd) — the routine that already
  repopulates the sprite selector, re-points `BlockView.project_*`, syncs background/grid, and shows
  sprite 0 (now extended to repopulate the **scene selector** too). So a scene switch is exactly a
  whole-project reload onto a different sprite-set, and `_current = -1` (reset there) keeps the leading
  `_persist_current` from writing the outgoing scene's stale canvas anywhere.
- **Add / Delete / Rename Scene** mirror the M24/M25 sprite chrome:
  [`_add_scene_pressed`](scripts/editor.gd)/[`_rename_scene_pressed`](scripts/editor.gd) share one name
  dialog (a `_scene_dialog_mode` state var routes [`_on_scene_dialog_confirmed`](scripts/editor.gd) to
  add vs rename). A **new scene** starts with **one default placeholder sprite** (the +Sprite default,
  named `"Sprite1"`) — so the sprite selector is never empty and `_show(0)` stays safe — plus its own
  empty variable list and the stock background/grid (each scene self-contained). A **rename** is purely
  cosmetic (nothing references a scene by name — scenes are independent — so no cascade, unlike a sprite
  rename): set the model name + the selector item text in place.
  [`_del_scene_pressed`](scripts/editor.gd)/[`_on_del_scene_confirmed`](scripts/editor.gd) refuse the
  last scene and switch to a clamped neighbour, the M24 sprite-delete pattern.
- **Sprite-name uniqueness is now per-scene.** Every name guard
  ([`_sprite_names`](scripts/editor.gd), the +Sprite / rename checks) already ran against `_scripts`
  (the active scene), so two scenes may each have a "Sprite1" with **no code change** — the registry the
  `Stage` builds is one scene's at a time.
- **RUN plays the active scene.** [`_on_run`](scripts/editor.gd) calls `_persist_current_scene` then
  hands the working vars over as before (`Stage.project_sprites`/`project_variables`/
  `project_background`) — after the persist they *are* `_scenes[_scene]`'s fields, so the M24 hand-off is
  byte-for-byte unchanged.
- **Persistence reshaped, backward-compatible.** [`_write_project`](scripts/editor.gd) writes
  `{scenes, active}` (each scene carrying its own sprites/variables/background/grid).
  [`_read_project`](scripts/editor.gd) accepts the new shape **and** a pre-M33 `{scripts, variables,
  background, grid}` file — wrapping the latter into a single "Scene 1" — so every saved `.json` still
  opens; [`_normalize_scene`](scripts/editor.gd) back-fills each scene's name / per-sprite geometry /
  background / grid (the per-scene version of M24/M27's normalisation), validating all scenes before
  adopting any so a malformed file can't half-load.

Still deferred (delivered in M34, below): **runtime scene navigation**. And **cross-scene shared
state** — by design each scene owns its variables, so a project-global store carried across scenes (a
score across levels) is a separate milestone.

### Multiple stages — runtime scene navigation (M34)

M33 made a project hold several scenes switchable at *edit* time but RUN played only the active one;
M34 adds the two blocks that change scene **at play time** — **`switch to scene {name}`** and
**`next scene`** — the deferral M33 named. It is the first opcode addition since M30's custom blocks,
and the runtime half is small because it **reuses the existing scene-swap primitive** rather than
inventing a teardown: a scene change is a `change_scene_to_file` reload, exactly what RUN/ESC do.
**Two new opcodes, no block-data-shape change, no per-block runtime-logic change** — the only
structural change is that the editor now hands the `Stage` the *whole* scene list, not one scene's worth.

- **The runtime carries all scenes now.** The three M24/M20/M27 statics
  (`Stage.project_sprites`/`project_variables`/`project_background` — one scene's worth) are **replaced
  by one** [`Stage.project_scenes`](scripts/stage.gd) (the full `[{name, sprites, variables, background,
  grid}]` list) **+** [`project_active`](scripts/stage.gd) (the index to build first). The build is
  otherwise unchanged: [`Stage._ready`](scripts/stage.gd) reads the active scene dict once
  ([`_active_scene`](scripts/stage.gd) — clamps `project_active` into the tracked `_active`, the index
  `next_scene` advances from) and sources the background ColorRect, the sprite build/run loops, and the
  variable seed loop from its `background`/`sprites`/`variables` fields (`grid` stays editor-only,
  ignored). [`_scene_list`](scripts/stage.gd) falls back to
  [`PongScripts.scenes()`](scripts/pong_scripts.gd) when no editor handed a list over, so a direct
  `main.tscn` launch still plays stock Pong (a single "Scene 1") — the fallback the old
  `_sprite_model`/`_variable_model`/`_background_hex` each gave, now in one place since a scene bundles
  all three.
- **The navigation methods, on the `Stage`.** [`go_to_scene_by_name(name)`](scripts/stage.gd) scans the
  scene list for a matching `name` (unknown → `push_warning` + no-op — the dropdown lists real scenes,
  so this only bites a stale hand-edited name); [`go_to_next_scene`](scripts/stage.gd) advances
  `(_active + 1) % count` (wraps). Both funnel into [`_change_to_scene(index)`](scripts/stage.gd):
  point the **static** `project_active` at the target (so the new value survives the reload),
  [`stop_all`](scripts/stage.gd) the current scripts (every `forever`/`_run_stack` poll bails on the
  next frame — so blocks after `switch_scene` don't run; a scene change ends the scene), then
  `change_scene_to_file(_GAME_SCENE)`. The new Stage instance's `_ready` rebuilds fresh.
- **The interpreter handlers are one line each.** [`_on_switch_scene`](scripts/interpreter.gd) →
  `_stage.go_to_scene_by_name(String(_value(block, "name")))`;
  [`_on_next_scene`](scripts/interpreter.gd) → `_stage.go_to_next_scene()` — registered in
  `_statement_handlers` the usual way. The Stage owns the resolve + reload; the interpreter just names
  the intent.
- **The editor side.** [`block_view.gd`](scripts/block_view.gd) gets the two `_OPCODES` entries, a new
  `"scenes"` category in `_CATEGORY_COLORS` + `PALETTE_CATEGORY_ORDER`, and the static
  [`project_scene_names`](scripts/block_view.gd) ([`_options_for`](scripts/block_view.gd) resolves the
  `"scenes"` data source to it — the scene twin of `"sprites"`). [`editor.gd`](scripts/editor.gd)'s
  [`_on_run`](scripts/editor.gd) hands `Stage.project_scenes = _scenes.duplicate(true)` +
  `Stage.project_active = _scene` (after `_persist_current_scene`); [`_scene_names`](scripts/editor.gd)
  feeds `BlockView.project_scene_names`, re-pointed in
  [`_load_project_into_ui`](scripts/editor.gd) (so NEW / OPEN / scene-switch / add / delete refresh the
  dropdown) and on a scene rename (the in-place branch of
  [`_on_scene_dialog_confirmed`](scripts/editor.gd) now also re-points it + rebuilds palette + refreshes
  canvas, so an open `switch to scene` dropdown relabels live).

What this leaves deferred (see [Deliberately deferred](#deliberately-deferred-to-a-later-milestone)):
the **scene-rename → `switch_scene` cascade** — renaming a scene relabels the *dropdown* (so new blocks
are correct) but does not rewrite existing `switch to scene {name}` blocks that target the old name
(they resolve null → a runtime warning, no-op), the same tradeoff M30 made for custom-block calls before
M32's cascade; M25's `rewrite_sprite_refs` is the template, but here it would be a **cross-scene** walk
(a block in any scene can name any scene). And **cross-scene shared state** — a scene change re-seeds
variables to the new scene's defaults (each scene owns its variables — M33), so a value like a score
does **not** persist across a switch; a project-global variable store carried across scenes is a
separate milestone.

### Motion-state reporters — bounce as blocks (M35)

The deferral the `"bounce"` note named for the whole project's life: *expose the sprite's
velocity/position as reporters* so a reflection can be expressed as data instead of the
`point_in_direction "bounce"` runtime sentinel. M35 adds the three reporters and rewrites the Pong
ball's bounce as blocks. It is the usual symmetric extension — **three opcodes** (one `_OPCODES` entry
+ one interpreter handler each), **no block-data-shape change, no other runtime change** — plus a
demo-script rewrite that rides `export_script()` → persistence/RUN untouched.

- **The reporters.** [`block_view.gd`](scripts/block_view.gd) gets `direction`, `x_position`,
  `y_position` (motion category, `kind: "reporter"`, value output, no inputs — a plain pill).
  [`interpreter.gd`](scripts/interpreter.gd)'s [`_on_direction`](scripts/interpreter.gd) returns
  `_target.direction`; [`_on_x_position`](scripts/interpreter.gd) /
  [`_on_y_position`](scripts/interpreter.gd) return the node's centre (`Sprite2D` is centred). They are
  the data the deferral named — `direction` standing in for velocity (speed is a separate variable).
- **The decomposition, faithful to `_bounce`'s observable behaviour.** Each of the ball's four bounce
  `if`s ([`PongScripts.ball()`](scripts/pong_scripts.gd)) now:
  - **Reflects** — `point in direction (180 - direction)` off a **horizontal** surface (the top/bottom
	edges), `point in direction (360 - direction)` off a **vertical** one (the paddles).
	`point_in_direction` wraps the result, so a negative angle is fine.
  - **Gates the flip on the motion's sign** via an inner `if`, reproducing `_bounce()`'s `absf`
	steering (force the component *away* from the surface, don't blindly negate): top reflects only
	when heading up (`direction < 90 or direction > 270`), bottom only when heading down
	(`90 < direction < 270`), LeftPaddle only when heading left (`direction > 180`), RightPaddle only
	when heading right (`direction < 180`). So a re-trigger next frame can't double-flip the ball into
	a stick — the load-bearing property `_bounce` guaranteed.
  - **Nudges** with a `go_to` — snap the centre clear so the ball never lingers inside the surface.
	Edge bounds are the 8px-inset viewport (the ball's half-size; top `y = 8`, bottom `y = 344` for the
	480×352 viewport), preserving x via `x_position`. The paddle clear-x is a **literal** off the
	fixed rails (LeftPaddle right edge 40 + ball half 8 = `48`; RightPaddle left edge 440 − 8 = `432`),
	preserving y via `y_position`.
- **Why this is "faithful" but not a general reimplementation.** In Pong every surface is cleanly
  horizontal or vertical, so `_bounce`'s runtime shallowest-overlap-axis choice collapses to a *known*
  axis per-`if`, and the paddle push-out (which `_bounce` computes from the live overlap) is a constant
  because the paddles ride fixed x-rails. So the block version matches `_bounce`'s output for this demo.
  It is **not** a general bounce: a sprite at an arbitrary angle, with dynamic overlap or against a
  moving/rotated obstacle, would need trig reporters (sin/cos/atan2) and cross-sprite geometry
  (the other sprite's x/y/w/h) — neither of which M35 adds. That fuller version stays deferred, which
  is why `_bounce()` and the `"bounce"` sentinel **remain in the runtime** (still a supported opcode
  value for any script that uses it).

What this leaves deferred: a **general data-form bounce** (the trig + cross-sprite-geometry reporters
above) and exposing **velocity as a first-class vector** (today motion is `direction` + a `speed`
variable, not vx/vy).

### Stage-editor world grid (M39)

Made the stage editor's alignment grid **continue indefinitely** past the default screen and turned the
**screen-boundary indicator into a grid of 480×352 screen cells tiled in all directions** (so adjacent
screen spaces are visible), **leaving the default (origin) screen highlighted**. It is a pure editor-side
view change in [`stage_view.gd`](scripts/stage_view.gd) — **no new opcode, no block-data-shape change, no
runtime change** — building directly on M37's pannable world view.

Through M37 the stage view drew a centred 480×352 [`_screen_panel`](scripts/stage_view.gd) (the project
background fill + a bright sky-blue guide-line border) with a child [`_GridLayer`](scripts/stage_view.gd)
**filling only that screen region** — so the fine grid stopped at the screen edge and there was a single
screen outline. M39 replaces that with **one full-view, pan-fixed `_GridLayer`** that does all the
world drawing:

- **It is a direct child of `StageView`** (full rect, `PRESET_FULL_RECT`), **not** a child of `_world`,
  so it always covers the visible viewport however far the world is panned. Rather than *moving* with the
  pan (the `_world`/`_layer` strategy), it **redraws aligned to the pan**:
  [`_apply_pan`](scripts/stage_view.gd) feeds it `world_origin = _pan.round()` (the display-px position of
  world (0,0) within the layer — the same rounded pan `_world.position` uses, so the grid stays
  pixel-aligned with the panned sprites) and `queue_redraw`s it.
- **`_draw` paints back-to-front** ([the `_GridLayer` inner class](scripts/stage_view.gd)): ① the **origin
  screen fill** — `draw_rect(Rect2(world_origin, cell), bg_color)`, `cell` = `_STAGE_SIZE * _DISPLAY_SCALE`,
  so the default screen reads as the "live" screen against the dark backdrop; ② the **fine alignment grid
  across the whole view**, vertical/horizontal lines stepped by `step` from `fposmod(world_origin.{x,y},
  step)` (so the first line aligns to the world grid under any pan), gated on `show_grid`; ③ the
  **screen-cell boundaries tiled in all directions**, the same lines stepped by `cell.{x,y}` in a
  **dimmed** sky-blue (`_BOUNDARY_DIM`) — the adjacent screen spaces; ④ the **default screen's bright
  boundary** (`_BOUNDARY` = `#4ad0ff`, `draw_rect(..., false, 2.0)`) drawn **last** so the highlight
  stands out from its neighbours.
- **The setters retarget to the new layer.** [`set_background`](scripts/stage_view.gd) now updates the
  layer's `bg_color` (the origin fill) + `queue_redraw`s, in place of recolouring the removed
  `_screen_panel`'s `_stage_box`; `set_grid_show` / `set_grid_color` / `set_grid_step` are unchanged in
  spirit (they drive the fine grid). The dark `_backdrop` Panel and the `_world`/`_layer` sprite tree are
  unchanged; `_screen_panel` and its `_stage_box` are gone.

The fine alignment grid stays a **toggleable authoring aid** (Show grid / Grid colour / Grid step), while
the screen-cell tiling + the origin highlight are **always** drawn (they are the screen indicator, not the
grid). The `_GridLayer` sits in the z-order above `_backdrop` and below `_world`/`_layer`, so the grid and
screen tiling draw over the dark backdrop and the origin fill but **under** the sprites — the same visual
ordering M37 had (grid behind sprites), now spanning the whole world.

What this leaves deferred: a **finite/labelled world bounds** (the tiling is purely visual — it doesn't
bound where sprites may live, and the cells aren't labelled with screen coordinates), and any **camera
preview** in the editor (M37's standing deferral — the editor still draws only the default screen, not a
camera-block-scrolled view).

### Web export: browser save/open (M38)

Made SAVE / OPEN work on a **Web (WebAssembly) export**, where there is no native `FileDialog` and no
absolute OS path — `FileAccess` sees only the virtual FS (`user://` = IndexedDB, `res://` = read-only),
so the desktop M22 save/open path can't run. M38 swaps the **transport** while reusing the **model**
verbatim, so a project round-trips as the same `{scenes, active}` JSON in either build. **No new opcode,
no block-data-shape change, no runtime change** — purely an editor-side persistence/transport split.

The load-bearing refactor is splitting each of M22's two file methods into a transport-agnostic *model*
half and a transport *shell* ([editor.gd](scripts/editor.gd)):

- [`_serialize_project()`](scripts/editor.gd) returns the project as a JSON String (persisting the
  active scene first) — the model half of the old `_write_project`, which is now a thin OS-filesystem
  shell over it (and binds `_current_path`).
- [`_apply_project(text, source)`](scripts/editor.gd) adopts a project from a JSON String, returning a
  bool (rejecting malformed input with a `push_warning`, keeping the current project) — the model half
  of the old `_read_project`, which is now a thin file-read shell. It deliberately does **not** touch
  `_current_path` or rebuild the UI; the caller does, since the bound path differs per transport (a real
  file path on desktop, none for a browser upload).

The web shells, routed to from [`_on_save`](scripts/editor.gd) / [`_on_open`](scripts/editor.gd) behind
`OS.has_feature("web")`:

- [`_web_save()`](scripts/editor.gd) hands `_serialize_project().to_utf8_buffer()` to
  `JavaScriptBridge.download_buffer(...)` — the browser's "Save As" download. No bound path on Web, so
  the filename is the demo/default and the title stays unsaved.
- [`_web_open()`](scripts/editor.gd) builds a hidden `<input type="file">` via `JavaScriptBridge.eval`,
  clicks it to pop the browser picker, and reads the chosen file with a `FileReader`; its JS `onload`
  fires a GDScript callback [`_on_web_file_loaded`](scripts/editor.gd) (kept alive in
  `_web_file_callback` so it isn't GC'd mid-pick) with the file text, which flows into the same
  `_apply_project` the desktop read uses. The project comes in **unsaved** (no path on Web, as after NEW).

`_web_file_callback` is **untyped** on purpose: the `JavaScriptObject` class is registered only on web
exports, so a typed annotation would break the desktop parse. The web methods are no-ops off Web (the
desktop branch is taken), so the desktop M22 path is unchanged.

### Stage-editor world view + camera blocks (M37)

Three additions, all built the project's usual way (one `_OPCODES` entry + one handler per new block;
the stage view a pure editor-side change over the data-owned model):

**1. The stage editor shows the whole world and pans.** Through M36 [`StageView`](scripts/stage_view.gd)
drew a single centred 480×352 `Panel` (`_stage_area`) with `clip_contents = true`, so a sprite outside
the screen — the Announcer at -400,-400, anything a camera would reveal — was invisible and
unselectable. M37 restructures the node tree into a **pannable window onto the world**:

- A dark `_backdrop` Panel fills the whole control (the out-of-bounds area).
- A `_world` Control (no clip), positioned at `_pan` (display px), holds all world content. Because the
  pan lives on `_world`'s position, the world→display mapping ([`_display_rect`](scripts/stage_view.gd)
  = `world * _DISPLAY_SCALE`) and the child `get_global_rect()` hit-tests ([`_hit`](scripts/stage_view.gd))
  are **unchanged** — the node tree carries the pan. Only [`_global_to_model`](scripts/stage_view.gd)
  changed, to subtract `_world.global_position`.
- `_screen_panel` (a child of `_world` at world (0,0), size 480×352·scale) is the **screen region**: the
  project background fill plus a bright sky-blue **guide-line border** (the old `_stage_box`, re-pointed
  here, so [`set_background`](scripts/stage_view.gd) still recolours it). It does **not** clip — the grid
  ([`_GridLayer`](scripts/stage_view.gd)) is its child (a screen-space aid), while the sprite `_layer`
  is a sibling under `_world` and may extend past the screen edge (the point of the world view).
- **Pan by dragging empty background**: [`_input`](scripts/stage_view.gd)'s press handler, when `_hit`
  is empty **and** the press is inside `get_global_rect()` (so a press on the inspector still falls
  through), starts a `{mode:"pan"}` pending; past `DRAG_THRESHOLD` it becomes a `_drag_mode == "pan"`
  drag that offsets `_pan` by the cursor delta ([`_update_pan`](scripts/stage_view.gd)). A plain
  background click is a no-op. Sprite select / move / resize are untouched (they only start when `_hit`
  is non-empty).
- [`recenter`](scripts/stage_view.gd) sets `_pan` to centre the screen in the view — the initial framing
  (called from [`set_model`](scripts/stage_view.gd) on entering Stage mode, and on `resized`) and what
  the inspector's **Recenter view** button restores. `_render` re-asserts the current `_pan` after a
  rebuild but **never recomputes it**, so a user pan survives a selection / inspector-edit re-render.

**2. A CAMERA block group.** Four new statement opcodes in [`block_view.gd`](scripts/block_view.gd)'s
`_OPCODES`, a new slate-teal `"camera"` category (in `_CATEGORY_COLORS` + `PALETTE_CATEGORY_ORDER`):
`set_camera` (`set camera to x: {x} y: {y}`), `change_camera` (`change camera by x: {dx} y: {dy}`),
`camera_follow` (`camera follow {name}`, a `data_enums: {name:"sprites"}` dropdown — the
`touching_sprite?` "sprites" source, no new resolver needed), and `camera_stop_following`. The
interpreter handlers ([`interpreter.gd`](scripts/interpreter.gd)) are one line each, delegating to the
Stage exactly as `switch_scene` delegates to `go_to_scene_by_name`. Plain `{opcode, inputs}` dicts —
**no block-data-shape change**, so persistence (M22) and RUN (M10) carry them untouched, and a pre-M37
project still opens/runs.

**3. The runtime camera.** [`Stage._ready`](scripts/stage.gd) creates a `Camera2D` (`_camera`) at the
screen midpoint `Vector2(_GAME_SIZE) * 0.5` (240,176) and `make_current()`s it. At that position the
viewport transform is **identical** to the old no-camera identity view (the screen shows world
(0,0)-(480,352)), so a project with no camera blocks is visually unchanged. The background `ColorRect`
moved onto a `CanvasLayer` (layer `-1`): a `CanvasLayer` is **not** transformed by a `Camera2D`, so the
backdrop stays screen-fixed while the camera pans, and the negative layer keeps it behind the sprites.
[`_process`](scripts/stage.gd) sets `_camera.position = _camera_follow.node.position` each frame when a
follow target is set (instant tracking, on the render frame). The block-called methods —
[`set_camera`](scripts/stage.gd) / [`move_camera`](scripts/stage.gd) (both clear `_camera_follow`, so a
manual move takes control) / [`camera_follow`](scripts/stage.gd) (warn + no-op on an unknown name) /
[`camera_stop_following`](scripts/stage.gd) — own the resolve + reload pattern the Stage already uses
for scene navigation. **Camera coordinates equal sprite coordinates** (the world point shown at the
screen centre), so `camera follow {Ball}` centres the ball and `set camera to x:_ y:_` centres on that
world point.

The chrome is editor-only: [`editor.tscn`](editor.tscn) wraps the top **Bar** and the right
**Inspector** in opaque-stylebox `PanelContainer`s (`BarPanel` / `InspectorPanel`); every inner widget
keeps `unique_name_in_owner`, so [`editor.gd`](scripts/editor.gd)'s `%Name` lookups are unaffected by
the re-parent. The new `%RecenterButton` (in the inspector's Stage section) is wired in `_ready` to
`_stage_view.recenter`.

What this leaves deferred: a **camera in the editor's stage view** (the editor draws the *default*
camera view — its screen guide — but doesn't preview a camera-block-scrolled view or let you set a
camera start position; the camera is a pure runtime/blocks concept), **camera zoom** (movement +
tracking only, per the milestone scope), and **screen-fixed HUD sprites** (a followed camera scrolls
regular sprites including the HUDs; a "stick to screen" layer is a separate milestone).

### Curved (convex) paddle bounce (M36)

A **demo-only** follow-on to M35: the Pong paddles now deflect the ball as if they were **convex**
(bulging toward the centre of the playfield) — the arcade-Pong feel where the contact point sets the
rebound angle, not a flat mirror. It is a pure [`PongScripts`](scripts/pong_scripts.gd) edit using
**only existing opcodes** — **no new opcode, no block-data-shape change, no runtime change, no editor
change** — so it rides `export_script()` → persistence/RUN like M35's ball rewrite.

- **The physics.** A flat paddle (M35: `360 - direction`) mirrors the incoming angle. A convex paddle's
  surface normal tilts *away* from centre as you move toward an end, so the outgoing angle should depend
  on **where the ball struck**: centre → straight back (`90` right / `270` left), toward an end →
  steep deflection toward that end. So M36 sets the rebound direction **absolutely** from the contact
  offset, ignoring the incoming angle (the classic-Pong simplification — a true reflection off a curve
  would compose normal-angle with incoming, but the position-only rule is what players read as "curved").
- **Cross-sprite position via a global relay.** The angle needs the paddle's centre y, but M35's
  [`y_position`](scripts/interpreter.gd) reports the **running** sprite — the ball can't read another
  sprite's position, and M36 adds no cross-sprite reporter. So each paddle **publishes its own centre y
  into a global** every tick: [`PongScripts._paddle`](scripts/pong_scripts.gd) gained a `y_var` arg and a
  leading `set {y_var} to (y position)` in its `forever`, writing the two new globals `left_paddle_y` /
  `right_paddle_y` ([`variables()`](scripts/pong_scripts.gd)). A global is how one sprite tells another
  where it is — the same pattern a user would reach for in the editor.
- **The ball reads the offset.** [`_paddle_bounce_dir(paddle_y_var)`](scripts/pong_scripts.gd) is the
  deflection as an expression (like the serve angles): `(ball y_position − paddle's relayed y) ×
  PADDLE_BOUNCE_CURVE`. Screen y grows downward, so a hit **above** the paddle centre is a *negative*
  offset. The two paddle `if`s feed it to `point_in_direction`: **LEFT** → `90 + offset×curve` (negative
  offset → up-right, positive → down-right), **RIGHT** → `270 − offset×curve` (the mirror).
  `PADDLE_BOUNCE_CURVE = 0.9` (degrees per pixel) gives ~`±50°` at the extreme reach (paddle half-height
  48 + ball half 8 = 56px), so the ball never rebounds vertically.
- **Anti-stick preserved.** M35's inner sign-gate (`if direction > 180` left / `< 180` right — only flip
  when heading **into** the paddle) and the `go_to` nudge (snap the centre clear of the rail, `48` / `432`)
  are unchanged. The gated angle range stays strictly on the heading-*away* side (`90 ± ~50° ⊂ (0,180)`,
  `270 ± ~50° ⊂ (180,360)`), so a re-trigger next frame while still overlapping can't double-flip the
  ball into a stick — the load-bearing property M35 inherited from `_bounce`'s `absf` steering.

What this leaves deferred: the same **general data-form bounce** M35 named (trig + cross-sprite-geometry
reporters) — M36's relay is a hand-built, Pong-specific stand-in for a real "other sprite's position"
reporter, and the curve is position-only (no incoming-angle reflection off the curve).

### Animation blocks (M41)

A block that takes a **variable** as its parameter and **animates its value over time**, with
**linear / ease-in / ease-out** interpolation. It is the project's usual symmetric extension — **one
opcode** (one [`_OPCODES`](scripts/block_view.gd) entry + one [`interpreter.gd`](scripts/interpreter.gd)
handler), **no block-data-shape change, no editor change** — the closest precedent being M37's camera
blocks (also pure renderer + interpreter). The block is **`animate {name} to {value} over {seconds}
secs {easing}`**, a single statement in a new slate-orchid `"animation"` category (added to
`_CATEGORY_COLORS` + `PALETTE_CATEGORY_ORDER`, placed after motion).

- **Why animate a *variable*, not a sprite property.** A variable is the general lever: tween it, then
  wire it into whatever reads it (`go to x: (x)` for position, `point in direction (angle)` for
  rotation, `say (n)` for a counting readout). One block covers every animatable quantity the block set
  already exposes, rather than a block per property. It is the dynamic counterpart of `set_var` — where
  `set` writes once, `animate` writes a tweened sequence over a duration.
- **It reuses the existing slot machinery whole — that is why there's no editor change.** `{name}` is a
  **data-scoped dropdown** of the project's variables (`data_enums: {name: "variables"}` →
  [`BlockView.project_variables`](scripts/block_view.gd), the same source `set_var`/`variable` use, so
  it re-scopes per sprite for free and the editor needs no new wiring — the `touching_sprite?`/camera
  pattern). `{easing}` is a fixed-choice dropdown (`enums: {easing: ["linear", "ease in", "ease out"]}`
  — M13). `{value}` and `{seconds}` are ordinary numeric slots, so they take literals, arithmetic (M29),
  or dropped reporters (M14). A plain `{opcode, inputs}` statement → persistence (M22) / RUN (M10) carry
  it untouched, and the palette lists it automatically (it's a `kind: "statement"` with `defaults`).
- **The tween, in the interpreter** ([`_on_animate`](scripts/interpreter.gd)). A coroutine like
  `wait_seconds`: it reads `name`/`value`/`seconds`/`easing`, snapshots `start = _get_variable(name)`
  and `target = value` (both evaluated once, in the current frame — Scratch's "evaluate the inputs at
  the start" semantics), then loops yielding on `_tree.physics_frame`, advancing `elapsed` by the
  **fixed step** `1.0 / Engine.physics_ticks_per_second` each tick and writing
  `lerpf(start, target, _ease_fraction(easing, t))` (with `t = clampf(elapsed / duration, 0, 1)`)
  through [`_set_variable`](scripts/interpreter.gd). Yielding on the *physics* tick (not render) is the
  project's fixed-tick rule — the value advances at a constant real rate regardless of FPS, exactly
  like `move_steps` in a `forever`. It **blocks the calling script for the duration** (blocks after it
  run on completion, as a glide would), and it polls `_stage.is_running()` / `_alive` each tick so a
  `stop "all"` / `stop "this script"` mid-animation unwinds it within a frame (the variable is left
  partway); it snaps exactly onto `target` **only** when it runs to completion. A non-positive duration
  writes the target immediately and returns.
- **The easing curves** ([`_ease_fraction`](scripts/interpreter.gd)) map `t ∈ [0,1]` to an eased
  fraction ∈ [0,1]: **linear** `t` (constant rate), **ease in** `t²` (slow start, accelerating),
  **ease out** `1 − (1 − t)²` (decelerating to a slow stop) — the standard quadratic in/out. Anything
  other than the two eased names (incl. `"linear"`) falls through to the identity, so a stale value
  degrades to linear rather than erroring.

What this leaves deferred: **more easing curves** (cubic/elastic/bounce; ease-in-out — the quadratic
trio is exactly the milestone's linear/in/out ask), a **direct `glide to x y in secs` convenience
block** (compose it from `animate` + `go to`, or two `animate`s onto x/y vars), and animating a
**sprite property directly** without routing through a variable. Since the tween writes through
`_set_variable`, **two `animate`s on the same variable race** (last write per tick wins) — fire them in
sequence (they block) or on separate variables, as you would chain glides in Scratch.

**The demo exercises it: the right paddle is now a CPU paddle.** A pure
[`PongScripts`](scripts/pong_scripts.gd) change (like M36 was for M35), no block-language or runtime
edit. The right paddle gave up player control to **auto-animate**: one hat `set`s `right_paddle_y` to
the top then `forever` runs two `animate`s — down to `PADDLE_BOTTOM_Y` then back up to `PADDLE_TOP_Y`,
each over `PADDLE_SWEEP_SECS` with `ease out` (so it decelerates into each turning point and reverses
gracefully). Because `animate` **blocks its script for the sweep**, a *second* hat does the moving:
`forever → go to x: 456 y: (right_paddle_y)` keeps the paddle node sitting on the value each frame (the
tween writes the variable; the node only moves when a `go to` reads it — and the ball needs the
physical node present to register a `touching RightPaddle?`). Animating `right_paddle_y` *directly* is
the neat part: it is the very global the ball reads for the curved bounce (M36's relay), so the tween
both moves the paddle and keeps that relay correct for free. With the right paddle relinquishing the
arrows, the **left paddle now answers W/S *and* ↑/↓** — `_paddle` was generalized to take key *lists*
(`_keys_pressed` ORs them into one condition).

### Sprite visual order — editor + blocks (M42)

Lets you **control which sprite draws on top** — *To Front / To Back / Forward / Backward*, Scratch's
layer operations — two ways: **from the stage editor** (the inspector's Layer buttons, editor-side only)
and **from blocks** (two LOOKS layer opcodes, at play time). The two use different mechanisms because
z-order is expressed differently at edit vs. play time — array order at build, `z_index` at run.

#### The editor half — reorder the array (editor-side only)

A pure **editor-side view** change ([`editor.gd`](scripts/editor.gd) + its [chrome](editor.tscn)) — **no
opcode, no block-data-shape change, no runtime change** — because the project already **encodes z-order
as sprite array order**.

- **Why array order already *is* the z-order.** The stage view's [`_render`](scripts/stage_view.gd)
  draws one panel per `_scripts` entry in order, so a later entry is added to `_layer` last and sits on
  top (and [`_hit`](scripts/stage_view.gd) takes the last match as the topmost). At RUN,
  [`Stage._ready`](scripts/stage.gd) loops the sprite model and `_add_sprite`s each in order, so a later
  child `CanvasItem` draws over an earlier one. Both ends walk the same array the same way, so **index 0
  is backmost and the last index is frontmost** — there is no separate z field to add. Manipulating
  visual order is therefore just **reordering `_scripts`**, and the reorder *is* the edit (RUN reads the
  order, SAVE serialises it — the M9 data-is-canonical idiom, lifted to the project level).

- **The chrome.** [editor.tscn](editor.tscn) adds a **Layer** group to the inspector's Stage panel
  (between the per-sprite colour and the stage-level settings): a label plus a 2-column `GridContainer`
  of four buttons — `%ToFrontButton` / `%ToBackButton` / `%ForwardButton` / `%BackwardButton`
  (`unique_name_in_owner`, reached by `%` in `editor.gd`, like the rest of the inspector). They are only
  reachable in Stage mode (the inspector is hidden in Blocks mode), so no extra mode guard is needed.

- **The reorder, in place.** [`_reorder_selected(target)`](scripts/editor.gd) (wired in `_ready` via four
  tiny lambdas: To Front → `_scripts.size() - 1`, To Back → `0`, Forward → `_current + 1`, Backward →
  `_current - 1`) clamps `target`, no-ops if unchanged, then `_persist_current()`s the canvas (the
  selected sprite is about to move slots) and does `remove_at` + `insert` **on the same `_scripts` Array
  object**. Reordering in place (not reassigning the array) is load-bearing: the stage view's `_sprites`
  is the *same* reference (`set_model` aliased it on entering Stage mode), so a re-render reflects the new
  order **without** re-pointing the model — and the **pan survives**, unlike the full
  `_load_project_into_ui` (which calls `set_model` → `recenter`). It then rebuilds the selector items in
  the new order and re-selects the moved sprite with a programmatic `select()` (which does **not** emit
  `item_selected`, so no `_show` / canvas reload fires — the same sprite stays loaded), re-points
  `BlockView.project_sprites` (order only — names unchanged, so no palette rebuild / canvas refresh), and
  calls `_stage_view.set_selected(_current)` (re-render in the new z-order + keep the highlight) +
  `_sync_inspector()`.

- **End-state button disabling.** [`_sync_inspector`](scripts/editor.gd) greys out To Front / Forward
  when the sprite is already frontmost (`_current >= size - 1`) and To Back / Backward when already
  backmost (`_current <= 0`), so a move that would do nothing reads as unavailable.

**Array order is the editor's single ordering**, so a z reorder **also reorders the sprite selector**
(it lists `_scripts` in order) — the honest consequence of one ordering rather than two. An independent
z-index *model field* would mean a block-data-shape + persistence change, which the editor half avoids.

#### The blocks half — restack at play time (two LOOKS opcodes)

The runtime can't reorder the build-time array (the sprites are live nodes), so the layer blocks restack
via the node's **`z_index`** instead. Every sprite is built at `z_index 0` ([`Stage._add_sprite`](scripts/stage.gd)
sets none), so the editor's array order is the *initial* stack and a layer block overrides it; z_index
decouples draw order from tree position, so it composes with the camera / clones with no reparenting.
Two opcodes, the usual one-`_OPCODES`-entry + one-interpreter-handler each
([`block_view.gd`](scripts/block_view.gd) / [`interpreter.gd`](scripts/interpreter.gd)), **no
block-data-shape change**:

- **`go to {layer} layer`** (`go_to_layer`, `layer` ∈ {`front`, `back`}) → [`_on_go_to_layer`](scripts/interpreter.gd)
  → [`Stage.set_layer(node, to_front)`](scripts/stage.gd): scan the registry for the current z extreme
  over the *other* sprites and set this node just past it (`max + 1` for front, `min − 1` for back), so
  it draws over / under every other sprite. (Clones aren't individually addressable — the registry holds
  originals — so front/back is computed against those.)
- **`go {direction} {num} layers`** (`change_layer`, `direction` ∈ {`forward`, `backward`}, `num`
  numeric) → [`_on_change_layer`](scripts/interpreter.gd) → [`Stage.change_layer(node, by)`](scripts/stage.gd):
  shift `z_index` by `num` (`forward` = `+`, toward the front; `backward` = `−`), clamped to
  `RenderingServer.CANVAS_ITEM_Z_MIN/MAX` so a runaway loop can't push it out of range.

They need **no editor change** beyond the two entries: `{layer}`/`{direction}` reuse the M13 fixed-choice
`enums` dropdown and `{num}` is an ordinary numeric slot (literals, arithmetic — M29 — or a dropped
reporter). The Stage owns the mechanism (it must scan all sprites for the extreme); the interpreter just
names the intent — the camera-block delegation pattern (M37). The `go_to` caveat (M27) doesn't bite
layers: a script may override a sprite's *position*, but its *layer* is z_index, which only these blocks
touch.

What this leaves deferred: **reordering by dragging on the stage** (the inspector buttons are the
editor affordance; a drag-to-restack gesture would compete with the move/resize/pan drags already there),
a **separate sprite-pane vs. layer ordering** (Scratch keeps the two independent — the editor half makes
them one), and **a layer *reporter*** (Scratch has none either — layer is write-only here).

## Opcodes implemented

**M47 added no opcodes** — it is a pure **editor interaction** change (collapsable scripts: collapse a
top-level stack to a one-line summary bar via a gutter chevron or Cmd/Ctrl+E, expand it the same way).
Collapse is editor-only UI state — an optional `collapsed` flag per stack in
[`BlockCanvas._stacks`](scripts/block_canvas.gd), never serialized — plus one renderer
([`BlockView.build_collapsed_stack`](scripts/block_view.gd)); no block-data-shape change, no
interpreter/runtime change. The notes below are kept as written for earlier milestones.

**M46 added no opcodes** — it is a pure **editor interaction** change (multi-block selection: click /
Shift-click / double-click / rubber-band to select blocks in the canvas — statement blocks, in-slot
reporter pills, *and* free-floating reporters — double-click selecting a block plus all of its nested
children — then delete / move-together / duplicate the selected statement-level blocks; plus a reporter
can now be dropped on the canvas to **live free**, Scratch's loose reporter, rendered as a pill via the
one `BlockView.build_stack` change and inert at runtime). Selection is editor-only UI state in
[`BlockCanvas`](scripts/block_canvas.gd), never serialized; no block-data-shape change, no
interpreter/runtime change. The notes below are kept as written for earlier milestones.

**M45 added no opcodes** — it is a pure **editor + runtime-texture** change (a pixel costume editor: a
third "Paint" mode paints a sprite's costume on a pixel grid, and the runtime builds the sprite texture
from the painted `{cw, ch, palette, pixels}` instead of a flat colour fill). One optional `costume` key
on a sprite dict, no block-data-shape change, no interpreter change; an unpainted sprite / pre-M45 save
renders its flat `color`. The notes below are kept as written for earlier milestones.

**M44 added nine opcodes** — the **list** block set (Scratch's ordered collections): the statements
`list_add` / `list_delete` / `list_delete_all` / `list_insert` / `list_replace` and the reporters
`list_item` / `list_item_index` / `list_length` / `list_contains?` (the last a boolean). Each names a
list via the `{list}` data-scoped dropdown (the new `"lists"` source → `project_lists`, the list twin of
`"variables"`), and the runtime stores lists local-first-then-global on `Target.lists` / `Stage._lists`,
mutating the resolved `Array` in place. A list is the **structural twin of a variable** — same
`{name, items, scope}` model, Make/Rename/Delete UI, seeding, persistence (`lists` key), and rename/delete
cascade — so beyond the nine entries and the one data-enum source there is no new editor machinery. No
block-data-shape change; a pre-M44 project opens (the `lists` key defaults to empty).

**M43 added six opcodes** — the **cross-sprite position reporters** `x_position_of` / `y_position_of`
(read another sprite's centre by name, a sprites dropdown) and the **velocity** blocks `set_velocity`
/ `change_velocity` (statements) + `velocity_x` / `velocity_y` (reporters). The position reporters
retire the demo's relay-global pattern (the ball reads `y position of (paddle)` directly); velocity is
a built-in `Target` property the Stage applies each physics tick (`node.position += velocity`). Each is
the usual one-`_OPCODES`-entry + one-interpreter-handler step, no block-data-shape change and no editor
change. The CPU right paddle was rewritten from M41's `animate` sweep to velocity-driven.

**M42 added two opcodes** — `go_to_layer` (go to front / back layer) and `change_layer` (go forward /
backward N layers): the LOOKS *layer* blocks, which restack a sprite at play time via its node `z_index`
([`Stage.set_layer`](scripts/stage.gd) / [`change_layer`](scripts/stage.gd)). Each is the usual
one-`_OPCODES`-entry + one-interpreter-handler step, no block-data-shape change. The milestone's **editor
half** — four Layer buttons in the stage inspector that reorder a sprite within the project's sprite
array (the build-time z-order) — added no opcodes (a pure editor-side view change). The notes below are
kept as written for earlier milestones.


**M41 added one opcode** — `animate` (the animation block: tween a variable's value over a duration with
linear / ease-in / ease-out interpolation). The usual one-`_OPCODES`-entry + one-interpreter-handler
step, no block-data-shape change and no editor change (it reuses the `data_enums "variables"` dropdown
and an `enums` easing dropdown). `_on_animate` is a coroutine that yields on the fixed physics tick like
`wait_seconds`, blocking its script for the duration.

**M37 added four opcodes** — `set_camera`, `change_camera`, `camera_follow`, `camera_stop_following`
(the CAMERA block group: scroll the runtime view). Each is the usual one-`_OPCODES`-entry + one-handler
step, with no block-data-shape change; the Stage owns a `Camera2D` and carries them out. M37 also makes
the **stage editor a pannable world view** (off-screen sprites visible, a screen-boundary guide line,
drag-to-pan, a Recenter button) and frames the chrome in opaque panels — all pure editor/runtime view
changes, no block-language change beyond the four camera opcodes.

**M36 added no opcodes** — it is a pure **demo-script** change (the Pong paddles bounce the ball as a
convex curve: each paddle relays its centre y into a global, and the ball aims its rebound off
straight-back by its contact offset × `PADDLE_BOUNCE_CURVE`), built entirely from existing blocks in
[`PongScripts`](scripts/pong_scripts.gd) — touching neither the block language nor the runtime; the
notes below are kept as written for earlier milestones.

**M35 added three opcodes** — `direction`, `x_position`, `y_position` (motion-state reporters). Each is
the usual one-`_OPCODES`-entry + one-interpreter-handler step, with no block-data-shape change and no
other runtime change; they read the running `Target`'s facing/centre. They let the Pong ball's bounce be
expressed as blocks (sign-gated reflection + `go_to` nudge), retiring the `point_in_direction "bounce"`
sentinel *in the demo* — though `_bounce()` and the sentinel remain in the runtime as a supported opcode
value.

**M40 removed two opcodes** — `switch_scene` and `next_scene` were deleted along with the rest of the
multiple-stage layer (M33/M34), reverting to a single flat project. The M34 notes just below are
historical (the opcodes and the whole scene model they describe no longer exist).

**M34 added two opcodes** — `switch_scene` and `next_scene` (runtime scene navigation): the first opcode
additions since M30's custom blocks. Each is the usual one-`_OPCODES`-entry + one-interpreter-handler
step, with no block-data-shape change. The runtime change is structural but contained — the editor hands
the `Stage` the *whole* scene list (`project_scenes` + `project_active`, replacing M24/M20/M27's three
per-scene statics), and a scene change is a `change_scene_to_file` reload (the same swap RUN/ESC use), so
no per-block runtime logic changed. **(Removed in M40.)**

**M33 added no opcodes** — it is a pure **editor + model + persistence** change (a project holds
multiple scenes, each a `{name, sprites, variables, background, grid}` dict; RUN plays the active one),
touching neither the block language nor the runtime — the `Stage` received one scene's worth of data
(M34 lifts that to the whole list); the notes below are kept as written for earlier milestones.

**M32 added no opcodes** — it is a pure **editor-side cascade** (renaming a `define` in place rewrites
this sprite's `call`s, via the new `BlockView.rewrite_custom_block_refs` walk), touching neither the
block language nor the runtime; the notes below are kept as written for earlier milestones.

**M31 added one opcode** — `param` (the custom-block parameter reporter), and extended the data shape of
`define` (an ordered `params` list) and `call` (an `args` dict), backward-compatibly. The `param`
addition is the usual one-`_OPCODES`-entry + one-interpreter-handler step; the runtime gained a
parameter-frame stack (`_on_call` binds args → a frame, `_on_param` reads it).

**M30 added two opcodes** — `define` and `call` (custom blocks / "My Blocks"): the first opcode additions
since M7. Each is the usual one-`_OPCODES`-entry + one-interpreter-handler step, with no block-data-shape
change. (M8 through M29 added none — see the per-milestone notes below.)

**M29 added no opcodes** (nor did M8/M9/M10/M11/M12/M13/M14/M15/M16/M17/M18/M19/M20/M21/M22/M23/M24/M25/M26/M27/M28) —
M29 is a pure **editor-side coercion** change (a numeric literal field evaluates an arithmetic expression
on commit), touching neither the block language nor the runtime logic; the note below is kept as written
for earlier milestones.

**M28 added no opcodes** — M28
is a pure **editor-side view** change (aspect-locked resize on the stage: `Shift` constrains a resize to
the sprite's starting proportions), touching neither the block language nor the runtime logic; the note
below is kept as written for earlier milestones.

**M27 added no opcodes** — M27 is a
pure **editor-side view** change (a stage/scene editor that makes a sprite's existing `x/y/w/h/color`
geometry directly editable), touching neither the block language nor the runtime logic; the note below
is kept as written for earlier milestones.

**M26 added no opcodes** — M26 is a pure **display / content-scale** change (the editor lays out at a
high resolution while the runtime stays pinned to its fixed 480×360 viewport), touching neither the
block language nor the runtime logic; the note below is kept as written for M25.

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
M30 adds **custom blocks** (`define`/`call`): a "Make a Block" button mints a `define {name}` hat, and a
`call {name}` chip runs that procedure — Scratch's "My Blocks", the first opcode additions since M7.


| opcode | kind | inputs | notes |
| --- | --- | --- | --- |
| `when_flag_clicked` | hat | `body` | entry point; each hat's body starts on play |
| `when_i_start_as_a_clone` | hat | `body` | entry point for a freshly spawned clone |
| `forever` | control | `body` | runs its body, yields one frame per loop |
| `while` | control | `condition`, `body` | runs `body` while the condition reporter is true, re-checking each loop, yielding one frame per iteration; a condition that never goes false ≡ `forever` |
| `if` | control | `condition`, `body` | runs `body` when the condition reporter is true |
| `move_steps` | statement | `steps` | moves `steps` px along the facing direction |
| `turn_degrees` | statement | `degrees` | rotates facing direction clockwise |
| `point_in_direction` | statement | `direction` | number sets direction absolutely; `"bounce"` reflects off whatever is touched (see below) |
| `go_to` | statement | `x`, `y` | sets position (inputs may be expressions); resets the ball, clamps paddles, parks the announcer/HUD |
| `set_velocity` | statement | `x`, `y` | set the sprite's built-in velocity (M43), px/tick; the Stage drifts the node by it each physics frame (continuous motion — the `go_to` counterpart) |
| `change_velocity` | statement | `dx`, `dy` | add to the built-in velocity (M43) — accelerate / steer (constant `dy` in a forever ≈ gravity); the `change_var` twin |
| `wait_seconds` | statement | `seconds` | awaits a SceneTree timer; the serve delay |
| `touching_edge?` | reporter | `side` | true at a viewport edge; `side` ∈ {top,bottom,left,right,any}, default `any` |
| `touching_sprite?` | reporter | `name` | AABB overlap with the named sprite, resolved through the registry |
| `key_pressed?` | reporter | `key` | polls a key by name (`OS.find_keycode_from_string` → `Input.is_physical_key_pressed`). Use canonical names: `"W"`, `"S"`, `"Up"`, `"Down"` |
| `set_var` | statement | `name`, `value` | sets a variable (local-first, then global; unseeded → creates a global) |
| `change_var` | statement | `name`, `by` | adds `by` to a variable — the score increment |
| `animate` | statement | `name`, `value`, `seconds`, `easing` | tweens variable `name` from its current value to `value` over `seconds` (M41), one step per fixed physics tick; blocks the script for the duration (like `wait_seconds`). `easing` ∈ {`linear`, `ease in`, `ease out`} (quadratic in/out). `{name}` is a variables dropdown |
| `say` | statement | `text`, `size` | renders `text` (stringified) through the bitmap font in the `size` face (`"small"` default / `"large"`) and sets it as the sprite's costume; the winner banner |
| `stop` | statement | `mode` | `"all"` halts every script (the game-over freeze); `"this script"` unwinds only the calling coroutine (clears its `_alive` flag) |
| `create_clone` | statement | `target` | only `"myself"` is supported: spawns a clone that inherits locals and runs the clone hats |
| `delete_this_clone` | statement | — | removes the running clone (frees its node, releases its interpreter); a no-op on an original |
| `variable` | reporter | `name` | reads a variable, resolving local-first then global |
| `list_add` | statement | `item`, `list` | append `item` to the list (M44); `{list}` is a lists dropdown, resolved local-first then global |
| `list_delete` | statement | `index`, `list` | remove the 1-based `index`-th item (M44); `index` also accepts `"last"`/`"random"`; out-of-range ignored |
| `list_delete_all` | statement | `list` | empty the list (M44) |
| `list_insert` | statement | `item`, `index`, `list` | insert `item` so it becomes the 1-based `index`-th item (M44), shifting the rest right (range 1..len+1) |
| `list_replace` | statement | `index`, `list`, `item` | overwrite the 1-based `index`-th item with `item` (M44); out-of-range ignored |
| `list_item` | reporter | `index`, `list` | the 1-based `index`-th item (M44), or `""` if empty / out of range. Value output |
| `list_item_index` | reporter | `item`, `list` | the 1-based position of the first item equal to `item` (M44), or 0 if none (loose compare). Value output |
| `list_length` | reporter | `list` | the number of items (M44). Value output |
| `list_contains?` | reporter | `list`, `item` | true when some item equals `item` (M44, loose compare). Boolean output |
| `direction` | reporter | — | the running sprite's facing direction in degrees (M35); Scratch convention (90 = right, 0 = up). Value output |
| `x_position` / `y_position` | reporter | — | the running sprite's centre x / y (M35); Sprite2D is centred. Value output. Together with `direction` these expose the motion state a data-form bounce needs |
| `x_position_of` / `y_position_of` | reporter | `name` | another sprite's centre x / y (M43), resolved by name through the registry; `{name}` is a sprites dropdown, unknown → 0 + warning. Value output. Retires the demo's paddle-position relay globals |
| `velocity_x` / `velocity_y` | reporter | — | the running sprite's built-in velocity components (M43). Value output |
| `add` / `subtract` / `multiply` / `divide` / `mod` | reporter | `a`, `b` | arithmetic; `divide`/`mod` guard ÷0 → 0 |
| `equals` / `greater_than` / `less_than` | reporter | `a`, `b` | numeric comparison → bool |
| `and` / `or` / `not` | reporter | `a`, `b` (`not`: `a`) | boolean combinators → bool |
| `random` | reporter | `from`, `to` | uniform float in `[from, to]`; the varied serve angle |
| `define` | hat | `name`, `params`, `body` | custom-block definition (M30); never auto-started — its body runs only when a `call` of the same name invokes it. Per-sprite. `params` (M31) is the ordered parameter-name list; its prototype pills drag copies of `param` into the body |
| `call` | statement | `name`, `args` | run the custom block `name` defined in this sprite's script (M30); resolves the `define` and `await`s its body. Unknown name → warn + no-op. `args` (M31) is a `{param: value}` dict — one argument per parameter, bound into a frame for the body |
| `param` | reporter | `name` | read a custom-block parameter (M31), resolved against the active `call`'s frame; 0 + a warning if read outside a custom block. Value output |
| `set_camera` | statement | `x`, `y` | centre the runtime view on world point (x, y) (M37); camera coords are sprite coords. Clears any active follow |
| `change_camera` | statement | `dx`, `dy` | scroll the runtime view by (dx, dy) from its current centre (M37); clears any active follow |
| `camera_follow` | statement | `name` | track the named sprite — the camera re-centres on it each frame (M37). `{name}` is a sprites dropdown; unknown → warn + no-op |
| `camera_stop_following` | statement | — | release camera tracking (M37); the camera holds its current position |
| `go_to_layer` | statement | `layer` | restack the sprite (M42): `"front"` → draw over every other sprite, `"back"` → behind, via node `z_index` (just past the current extreme). `{layer}` is an enum dropdown |
| `change_layer` | statement | `direction`, `num` | shift the sprite `num` layers (M42): `"forward"` toward the front (z_index += num), `"backward"` toward the back (−num), clamped to the engine z range. `{direction}` is an enum dropdown |

> Note on `"bounce"`: the `point_in_direction "bounce"` sentinel and its `_bounce()`
> implementation **remain in the runtime** as a supported opcode value (any saved or
> hand-written script using it still runs). But **the Pong demo no longer uses it** —
> M35 added `direction`/`x_position`/`y_position` reporters and expressed the ball's
> bounce as blocks (see [Motion-state reporters — bounce as blocks (M35)](#motion-state-reporters--bounce-as-blocks-m35)).
> That decomposition is faithful to `_bounce()`'s observable behaviour *for Pong*
> (the walls reflect flat; the paddles became a **convex curved** bounce in M36 — the
> rebound angle tracks the contact point — plus the sign-gated anti-stick steering and a
> `go_to` nudge), where every surface is cleanly horizontal or vertical so the
> shallowest-overlap-axis logic collapses to a known axis per-`if`. A **general** data-form
> bounce (arbitrary angles, dynamic overlap, cross-sprite geometry) would still need trig
> and other-sprite geometry reporters, and stays deferred — which is why `_bounce()` is kept.

## File layout

```
project.godot              Godot project config; main scene = editor.tscn (M8); initial window 1280x720 fullscreen (M26) — the per-scene content-scale overrides in editor.gd/stage.gd take over from there (editor 960x540 logical, game a fixed 480x360 integer-snapped viewport)
editor.tscn                Main scene (M8): the editor front door, running editor.gd. Declares the editor's fixed chrome — backdrop, top bar (title + scene selector + Add/Del/Rename scene buttons (M33) + sprite selector + Add/Del/Rename sprite buttons (M24/M25) + NEW/OPEN/SAVE + RUN, M22), the palette | canvas workspace (each in a ScrollContainer), the Make/Rename/Delete variable dialogs and the New/Delete/Rename sprite dialogs (M24/M25) and the scene name + delete-scene dialogs (M33), the project-file browser (a FileDialog, M22), the Stage/Blocks toggle + stage-editor container (StageView + the x/y/w/h SpinBoxes and Colour picker inspector, M27), and the Make-a-Block name dialog (M30, with a parameters field added in M31) — which editor.gd reaches by unique name. (The palette/canvas/stage *contents* are still generated in code.) M37 wraps the top Bar and the right Inspector in opaque-stylebox PanelContainers (BarPanel/InspectorPanel — the inner widgets keep unique_name_in_owner, so editor.gd's %Name lookups are unchanged) and adds a RecenterButton in the inspector. M45 adds a PaintToggle button (the Paint mode) and a PaintContainer holding a PaintView (the pixel costume editor, which builds its own tool/palette chrome in code).
main.tscn                  The *game* scene: a single Node2D "Stage" running stage.gd (launched by the editor's RUN button)
icon.svg                   Default project icon (skeleton)
font.png                   3x5-pixel bitmap font atlas (A-Z, 0-9); baked into a PixelFont
scripts/
  editor.gd                Editor root (M8): wires the scene-declared chrome (editor.tscn) — fills the sprite selector, connects RUN, grabs palette/canvas/dialogs by unique name; wires the palette as the canvas's trash (M16); owns the mutable variable model (M20, seeded from PongScripts.variables()), scoping it to the selected sprite — globals + that sprite's locals — for BlockView's data-scoped dropdowns (M17/M19) and rebuilding the palette on each switch; "Make a Variable" dialog appends to that model (M20); rename/delete dialogs edit it (M21) — rename cascades the new name across the in-scope scripts (_is_referent_for), delete strips its references (drop set/change, revert variable-reporter slots) and removes the entry; owns the mutable **sprite** model too (M24) — _scripts is now [{name,x,y,w,h,color,script}] seeded from PongScripts.sprites(); +Sprite/-Sprite buttons add (default placeholder + empty script) / delete (entry + its locals + dangling touching refs, M25) a sprite (_on_new_sprite_confirmed/_on_del_sprite_confirmed); a Rename Sprite button (M25, _on_rename_sprite_confirmed) cascades a new sprite name across every script's touching_sprite? refs and every variable scoped to it (globally — a sprite name is unique, so no per-scope filter); persists script edits + hands the whole sprite model and the variable model to the Stage on RUN (M24/M20, project_sprites/project_variables); saves/opens named project files via a FileDialog (full filesystem access — the user picks the location, defaulting to the project folder) and reloads the in-code demo with NEW (M22, _write_project/_read_project/_seed_demo; _normalize_sprite back-fills geometry on a pre-M24 file), keeping the demo and saved projects from clobbering each other; on _ready sets the window's content scale to the editor's own logical resolution (_EDITOR_SIZE 960x540, VIEWPORT/EXPAND/FRACTIONAL) so the chrome lays out roomy and high-res, independent of the runtime's fixed 480x360 — also resetting whatever the game left on the shared window when ESC returns here (M26); a Stage/Blocks toggle swaps the workspace between the block editor and the stage view (M27, _toggle_view), wiring StageView's on_pick (route a stage click through the normal selector/_show selection) + on_geometry_changed (track a drag in the inspector), and reading/writing the inspector's x/y/w/h/colour into the selected sprite's model entry (_sync_inspector/_write_geom/_on_insp_color) — geometry edits the same _scripts the runtime builds from; also owns the stage-level project properties — the background colour (_background, handed to the Stage at RUN) and the grid settings (_grid_settings = {show,snap,color,step}, editor-only) — both seeded from PongScripts (background()/grid()), edited via the inspector's _on_insp_bg_color/_on_grid_* handlers, synced on every project load (_sync_background/_sync_grid), and saved under the "background"/"grid" keys (M27); a "Make a Block" name dialog mints a custom block (M30, _make_block/_on_new_block_confirmed) — it adds a define {name} hat to the canvas and re-derives the sprite's custom-block names (_custom_blocks_in, the define hats in its script) into BlockView.project_custom_blocks per sprite, so a call {name} slot lists this sprite's procedures; that dialog also takes **parameters** (M31, _parse_params splits on commas/whitespace → the define's params list), and _custom_block_params_in re-derives each sprite's block→params map into BlockView.project_custom_block_params, so a call chip gets one arg slot per parameter and a param reporter can be dragged out of the define hat's prototype; renaming a define in place cascades the new name to its calls (M32, _on_custom_block_renamed re-derives the sprite's custom-block names after BlockCanvas rewrites them); owns the **scene (stage/level) model** too (M33) — _scenes is a list of {name,sprites,variables,background,grid} dicts, _scene the active index, seeded from PongScripts.scenes(); the working vars (_scripts/_variables/_background/_grid_settings) are the live editing surface for the active scene (_load_scene_into_working points them at _scenes[_scene]), persisted back via _persist_current_scene before each scene switch / SAVE / RUN; a top-bar scene selector + Add/Del/Rename Scene buttons manage the list (_load_scene/_add_scene_pressed/_rename_scene_pressed/_del_scene_pressed — a new scene gets one default placeholder sprite, delete refuses the last); persistence reshaped to {scenes,active} (_write_project), with a pre-M33 {scripts,variables,…} file wrapped into one "Scene 1" on OPEN (_read_project/_normalize_scene); runtime scene navigation (M34) — RUN now hands the Stage the **whole** scene list (Stage.project_scenes = _scenes + project_active = _scene, replacing the per-scene hand-off) so a switch_scene/next_scene block can rebuild for a different scene at play time; _scene_names feeds BlockView.project_scene_names (the switch_scene dropdown's options), re-pointed in _load_project_into_ui and on a scene rename (which now also rebuilds palette + refreshes canvas so the dropdown relabels — but does not cascade to existing switch_scene blocks, deferred)
  stage_view.gd            Stage (scene) editor (M27): draws each sprite as a rectangle (centred on its model position, scaled by _DISPLAY_SCALE into a 480x360 clipped region) from a reference to editor._scripts; select/drag/resize via _input global hit-testing (the M9/BlockCanvas pattern — IDLE/PENDING/DRAGGING + 4px threshold, _hit checks resize handles then sprite bodies), writing x/y (move) or w/h (resize anchoring the top-left corner / growing right-down, or about the fixed centre with Alt held, rounded to int) straight into the model dict; holding Shift locks a resize to the sprite's starting aspect ratio (M28, _lock_aspect over the w/h captured at _begin_drag); an alignment grid (show/snap/colour/step) the editor drives via set_grid_*; calls back to the editor (on_pick/on_geometry_changed); the geometry write *is* the edit, so RUN/SAVE carry it. M37 restructures it into a **pannable world view**: a _world container (positioned at _pan, not clipped) holds the screen region (_screen_panel — background fill + a bright guide-line border marking the 480x352 screen, grid inside it) and the sprite _layer, so off-screen sprites are visible; dragging empty background pans (a {mode:"pan"} branch in _input, guarded inside our rect; sprite drag/resize unchanged), recenter() re-frames on the screen (set_model/resized/Recenter button), and _render re-asserts but never recomputes _pan (so a pan survives a re-render). M39 replaces the clipped screen-only _screen_panel with one full-view, pan-fixed _GridLayer (a direct child of StageView, not in _world) that redraws aligned to the pan (world_origin): the origin screen fill (set_background), the fine alignment grid spanning the whole view, the 480x352 screen cells tiled in all directions (dimmed), and the highlighted default screen's bright boundary drawn last — so the grid continues indefinitely and adjacent screen spaces are visible around the highlighted default one
  paint_view.gd            Pixel costume editor (M45): the third editor surface beside the block canvas and stage view (the M27 toggle widened to BLOCKS/STAGE/PAINT). Holds a reference to editor._scripts and edits the selected sprite's optional `costume` ({cw,ch,palette,pixels} — a palette of "#rrggbb" + a row-major index grid, -1 = transparent), mutating costume.pixels in place (the M9 data-is-canonical idiom). Paints from _input with the StageView IDLE/PENDING/DRAGGING machine + is_visible_in_tree guard, hit-testing a custom-_draw grid layer in global coords: pencil/eraser paint along a drag (Bresenham), fill flood-fills, eyedropper picks a colour, clear-all empties; a palette of swatch buttons + a ColorPickerButton recolours the active swatch (built in code since the swatches are dynamic). The costume is created lazily on first paint (_ensure_costume) at the sprite's w/h clamped to [4,64], setting the entry's w/h to cw/ch so the no-stretch render footprint, collision, and inspector agree. on_costume_changed calls back to the editor to re-sync the inspector
  block_canvas.gd          Interactive canvas (M9): drag/snap/detach — mutates block data + re-renders; begin_spawn_drag() accepts palette blocks (M11); wires editable literal fields + enum dropdowns back to the data (M12/M13); drops a dragged reporter into a value/condition slot (M14, _nearest_slot — type-filtered to matching boolean/value slots in M23) and grabs one back out of its slot (M15, _reporter_at/_begin_reporter_drag); deletes a block dragged onto the palette (M16, _over_trash/_trashing); refresh() re-renders so a newly-made variable shows in open dropdowns (M20); add_definition() appends a freshly-made define hat as a new stack (M30, "Make a Block"); _spawn_at/_pending_spawn spawn a fresh param-reporter copy when a define hat's prototype parameter pill is dragged (M31), confined to slots inside that function's body (_nearest_slot/_scoped_slots/_enclosing_define_body — also for an already-placed param grabbed out); rename_variable()/delete_variable_refs() rewrite/strip the working stacks in place on a UI rename/delete, preserving positions (M21); rename_sprite() does the same for a sprite rename (M25); an in-place define rename is detected in _commit_literal (the define_name-stamped field) and, after a uniqueness check (_other_define_named), deferred to _rename_custom_block_deferred which rewrites the sprite's calls + notifies the editor via on_custom_block_renamed (M32); multi-block selection (M46) — _selected holds the selected block dicts by identity (statement blocks, in-slot reporter pills, *and* free-floating reporters; editor-only UI state, never serialized; survives _render since the dicts persist), highlighted by _apply_selection_highlight (over _tagged_panels for statements/free reporters + _slots for in-slot pills, via _outline_selected); click / Shift-click / double-click select on the click-release path (_on_pending_click, resolving the clicked block via _pending_clicked_block), double-click selecting a block plus all its nested children (_select_subtree — body statements + reporter input pills, recursively); an empty-canvas drag rubber-bands (_begin_marquee/_update_marquee, guarded off the scrollbar by _over_scrollbar); dragging a 2+ selection moves it together (_begin_multi_drag gathers _topmost_selected_in_order into one ghost stack), and Delete/Backspace + Cmd/Ctrl+D delete/duplicate it (_handle_key/_delete_selection/_duplicate_selection) — these ops act on stack-level picks (statements + free reporters; an in-slot pill is highlight-only); a **free-floating reporter** (M46) is a top-level stack whose block is a reporter — build_stack renders it as a pill but stamps blk_array/blk_index, so it drags/selects like a statement (_block_at/_hit_is_reporter route its pickup to _begin_reporter_drag); a reporter released off every slot lands free instead of being discarded (_drop), and is inert at runtime (run() starts only hats); collapsable scripts (M47) — an optional per-stack `collapsed` flag (editor-only UI state in _stacks, beside pos; never serialized, reset on a sprite switch) makes _render draw BlockView.build_collapsed_stack (a one-line summary bar) instead of the full tree; every stack is wrapped by _wrap_with_gutter in a row with a left gutter holding a collapse chevron (▼/▶) when it has more than one block, stamped with its stack dict as collapse_stack; a press on the chevron (_collapse_toggle_at, checked before _front_stack_at) or Cmd/Ctrl+E on the selection (_toggle_collapse_selection/_stacks_with_selection) toggles it; a collapsed bar drags/selects/deletes as one unit (blk_index 0) and a whole-collapsed-stack drag re-homes collapsed (_grabbed_collapsed); _land_pos offsets a free-landing drop by the gutter width so blocks don't drift; export_script() serializes edits back (M10)
  block_palette.gd         Block palette (M11): lists opcodes as chips (reporters too, as pills — M14); on drag, mints a fresh block and hands it to the canvas; rebuild() re-renders the chips when the editor re-scopes the variable dropdowns on a sprite switch (M19); draws a "Make a Variable" button atop the variables group (M20) and, beneath it, a Rename/Delete MenuButton row per in-scope variable (M21), all calling back to the editor; draws a "My Blocks" group (M30) — a "Make a Block" button plus one pre-named call chip per custom block the sprite defines (BlockView.project_custom_blocks); define/call carry palette:false so palette_groups skips them, so this is the only place they enter the palette; a call chip carries one args slot per the block's declared parameters (M31, project_custom_block_params), the drag re-minting the args dict from the chip's palette_params
  block_view.gd            Block renderer (M8): tree-walks block data into a Control tree; opcode->{category,template,kind,defaults,enums,data_enums,output,bool_inputs,palette} table; make_block() factory (M11); editable LineEdit literal fields + coerce_literal (M12); enum-slot OptionButtons + type-shaped fields (M13); data-scoped {name} dropdowns from the editor's project_variables/project_sprites/project_custom_blocks (M17/M30, _options_for) — the variable list scoped per sprite by the editor (M19), extended by Make a Variable (M20), the custom-block list likewise per sprite (M30); count_variable_refs/rewrite_variable_refs/strip_variable_refs walk the block tree for the rename/delete cascade (M21), with count_sprite_refs/rewrite_sprite_refs/strip_sprite_refs the touching_sprite? counterparts for a sprite rename/delete (M25), and rewrite_custom_block_refs the define/call counterpart for a custom-block rename (M32, _define_header stamps the name field define_name so the canvas can detect an in-place rename); slot-typing (M23) — reporter_output_type() + a slot_type meta per widget, and an angular boolean pill vs a round value pill — so the canvas can refuse a mismatched reporter drop; the define/call custom-block opcodes (M30) carry palette:false so palette_groups skips them; custom-block parameters (M31) — the param reporter opcode, _define_header/_call_header render define/call dynamically from their own data (a spawnable param pill per define param, an args slot per call param built against the call's args sub-dict), _param_pill draws the read-only name pill, project_custom_block_params holds each sprite's block→params map; runtime scene navigation (M34) — the switch_scene/next_scene opcodes in a new "scenes" category, switch_scene's {name} a data-scoped dropdown from project_scene_names (the editor's scene-name list, the scenes twin of project_sprites; _options_for resolves the "scenes" source); this renderer just lists what it's handed; the animation block (M41) — the `animate` opcode in a new "animation" category, its {name} a data-scoped "variables" dropdown and {easing} a fixed-choice enum (linear/ease in/ease out), {value}/{seconds} ordinary numeric slots — needs no renderer change beyond the one _OPCODES entry + category colour; stamps every input widget as a slot drop target with its default literal (M14/M15); tags it for M9 dragging; build_stack draws a stack-level reporter as its pill (M46, free-floating reporter) instead of a statement panel, still stamping blk_array/blk_index so the canvas drags/selects it; build_collapsed_stack + _summary_text + count_blocks render a collapsed top-level stack as a one-line summary bar (M47, the first block's flattened label + a +N hidden-block badge), stamped blk_index 0 so the canvas treats the bar as the whole script
  stage.gd                 Runtime root: builds one scene's sprites + runs their scripts from the active scene of the project's scene list (M34) — the editor's whole working project via static project_scenes (every stage it holds), else PongScripts.scenes() (a single "Scene 1"), with project_active picking which to build first (replaces M24/M20/M27's three per-scene statics project_sprites/_variables/_background — each per-scene field is read off the active scene dict now, _active_scene/_scene_list); owns the name->Target registry + shared font, seeds variables from the active scene's variable list (M18/M20); runtime scene navigation (M34) — switch_scene/next_scene call go_to_scene_by_name/go_to_next_scene, which re-point the static project_active, stop_all the current scripts, and change_scene_to_file back to this game scene so _ready rebuilds on the target scene (the same swap RUN/ESC use — no bespoke teardown); on _ready re-imposes the fixed 480x360 logical viewport on the shared window (_apply_game_scaling — content_scale_size 480x360 so get_viewport_rect() is unchanged, VIEWPORT/KEEP/STRETCH_INTEGER for a crisp whole-number upscale, M26); runtime camera (M37) — _ready adds a Camera2D centred at (240,176) (= the no-camera identity view, so a project without camera blocks is unchanged) and puts the background ColorRect on a CanvasLayer(-1) so it stays screen-fixed while the camera pans; set_camera/move_camera/camera_follow/camera_stop_following move or track it (_process re-centres on the followed sprite each frame), called by the camera blocks; pixel costumes (M45) — _add_sprite takes an optional costume dict and, when present, builds the sprite texture via _make_costume_texture (palette + index grid → an Image, -1/out-of-range transparent, TEXTURE_FILTER_NEAREST) instead of the flat _make_placeholder_texture, drawn at native cw×ch (no stretch); ESC returns to the editor (the inverse of editor.gd's RUN)
  interpreter.gd           Tree-walking, coroutine-driven block interpreter + dispatch tables; custom blocks (M30) — _on_call resolves a define hat by name in the target's retained _script and awaits its body (per-sprite procedures; define is a hat, so it's never auto-started); parameters (M31) — _on_call binds a call's args (evaluated in the caller's frame) into a {param: value} frame pushed on the _frames stack for the body, _on_param reads the top frame (the param reporter); runtime scene navigation (M34) — _on_switch_scene/_on_next_scene delegate to the Stage's go_to_scene_by_name/go_to_next_scene (the Stage owns the resolve + scene reload); camera (M37) — _on_set_camera/_on_change_camera/_on_camera_follow/_on_camera_stop_following delegate to the Stage's camera methods (the Stage owns the Camera2D); animation (M41) — _on_animate is a coroutine that tweens a variable from its current value to a target over a duration, one step per fixed physics tick (yielding on _tree.physics_frame like wait_seconds), via _ease_fraction (linear / ease in t² / ease out 1−(1−t)²); it writes through _set_variable and polls the Stage/_alive flags so a stop unwinds it mid-tween
  target.gd                Wraps the controlled node + its direction and name
  font.gd                  PixelFont: bakes font.png into rendered text costumes (the `say` block)
  pong_scripts.gd          The hardcoded Pong block scripts (two paddles, ball, two numeric HUDs, announcer), as data; also the seed sprite model — sprites() (M24) declares each sprite's name + placeholder geometry (x/y/w/h/color, color a hex string) + script, the editor's starting set and the Stage's fallback; and the seed variable model — variables() declares each variable's name/value/scope, likewise the editor's starting set and the Stage's fallback (M18; the editor extends its own copies via Make a Variable / +Sprite, M20/M24). Every variable declares to 0; non-zero starts come from `set` blocks in the scripts (the ball's `set speed to BALL_SPEED`), Scratch-style — the starting value lives in the editable program, not a hidden seed; and the seed stage-level settings — background() (the backdrop hex) and grid() ({show,snap,color,step}, the stage editor's alignment grid), each a project property the editor seeds from here and persists in the .json (M27); and the seed **scene model** — scenes() (M33) bundles sprites()/variables()/background()/grid() into one stock scene "Scene 1", the project's starting (single) stage and the shape the editor's _scenes list seeds from
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
  boolean reporters may drop there (default: a value reporter / value slot). If the block should *not*
  appear in the palette as a generic draggable chip (the custom-block `define`/`call`, M30, which the
  palette's My-Blocks group renders specially), give it `palette: false` so `palette_groups` skips it
  (`make_block` still mints it). An opcode with no entry still renders, as a grey box.
- New custom block (a function)? **From the UI** (M30/M31): click **Make a Block** atop the palette's My
  Blocks group, name it, and (M31) optionally type **parameters** (space/comma-separated) — a
  `define {name}` hat appears on the canvas with one draggable **parameter pill** per parameter. Build
  its body — drag a parameter pill into a value slot to use that argument (it mints a `param` reporter)
  — then drag a `call {name}` chip (which now shows one argument slot per parameter) wherever you want to
  run it, and fill its argument slots. Custom blocks are **per-sprite** (the `define` lives in that
  sprite's script). There's no separate model — the names + params are derived from the `define` hats —
  so a stock custom block is just a `define` hat (with a `params` list) in a sprite's script in
  [`PongScripts`](scripts/pong_scripts.gd). **Rename** it by editing the `define`'s name field on the
  canvas — its `call`s in that sprite cascade to match (M32). Value parameters only; boolean params, a
  return value, **parameter** rename/sync, and UI delete are still deferred (see Deliberately deferred).
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
- New list? Two ways, mirroring variables (M44). **From the UI**: click **Make a List** atop the
  palette's LISTS group, name it, pick global/local — appended to the editor's working model and seeded
  at RUN; **Rename / Delete** from its row's menu (rename cascades, delete strips its references). It
  survives relaunch only if you **SAVE**. **In the stock project**: add one `{name, items, scope}` entry
  to [`PongScripts.lists()`](scripts/pong_scripts.gd) — the seed model the editor starts from and the
  Stage falls back to (`items` the starting Array, `scope` `"global"` or a sprite name). A list resolves
  local-first then global at runtime (`Target.lists` / `Stage._lists`); the list blocks mutate the
  resolved `Array` in place. Don't seed a list inline in `stage.gd`.
- New sprite? Two ways, mirroring variables. **From the UI** (M24): **+ Sprite** in the top bar names
  a new sprite (a grey placeholder at centre with an empty script); **− Sprite** deletes the selected
  one (and its locals, and any `touching` references to it — M25); **Rename Sprite** (M25) renames it,
  cascading the new name across every script's `touching_sprite?` references and the `scope` of its
  locals. A UI-added/renamed sprite is seeded/built at RUN and survives relaunch only if you
  **SAVE** the project. **In the stock project**: add one `{name, x, y, w, h, color, script}` entry to
  [`PongScripts.sprites()`](scripts/pong_scripts.gd) (M24) — the seed sprite model the editor starts
  from and the Stage falls back to (`color` a hex string; `script` from a builder). Don't build a
  sprite inline in `stage.gd`; that is exactly the duplication M24 removed (the sprite sibling of M18).
  A sprite's geometry here is its **starting** placeholder — editable from the UI via the **Stage**
  view (M27: select / drag / resize — Alt about the centre, Shift to lock aspect (M28) — / recolour, or the inspector's x/y/w/h/colour fields) — but a
  `go_to` block in the script still wins at RUN (behaviour is blocks), so the model position matters
  most for a sprite with no `go_to`.
- New costume / pixel art? **From the UI** (M45): the top-bar **Paint** button opens the pixel costume
  editor — pencil/eraser/fill/eyedropper on a grid, a palette, clear-all. The painted costume is stored
  as an optional `costume` key on the sprite dict (`{cw, ch, palette: ["#rrggbb"…], pixels: [indices, −1
  = transparent]}`) and rides SAVE/RUN like the rest of the model. **In the stock project**: add a
  `costume` key to a [`PongScripts.sprites()`](scripts/pong_scripts.gd) entry (the runtime renders it via
  [`Stage._make_costume_texture`](scripts/stage.gd) at native `cw×ch`, no stretch). Don't add `costume`
  to `_DEFAULT_SPRITE` — its *absence* is what makes an unpainted sprite fall back to the flat `color`.
  Painting sets the sprite's `w/h` to `cw/ch` (the no-stretch footprint), so resolution is fixed at
  creation; changing it (a resize-canvas tool), **multiple costumes** + switching blocks, animation
  frames, undo, PNG import, and a shared palette are deferred (see Deliberately deferred).
- Multiple stages (scenes / levels)? **Removed in M40.** M33/M34 made a project hold several
  switchable scenes; that layer was ripped out — a project is now a single flat stage again (one set of
  sprites / variables / background / grid). Don't add a scene layer back without a deliberate milestone
  (and the cross-stage state / persistence work it implies — exactly what M40 deferred).
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

- **Camera: editor preview / start position, zoom, screen-fixed HUD** — **M37 delivered the camera**:
  a CAMERA block group (`set camera`, `change camera`, `camera follow {sprite}`, `camera stop
  following`) scrolls a runtime `Camera2D`, and the stage editor became a **pannable world view** (the
  whole world visible, a screen-boundary guide line, drag-to-pan, a Recenter button, opaque chrome
  panels). What's *still* deferred: the editor draws only the **default** camera view (its screen guide)
  — there is no in-editor preview of a camera-block-scrolled view, and no UI to set a camera *start*
  position (the camera is a pure runtime/blocks concept); **camera zoom** (movement + tracking only);
  and **screen-fixed sprites** (a followed camera scrolls regular sprites including the HUDs — a
  "stick to screen" layer is a separate milestone).
- **Multiple stages / runtime scene navigation** — **delivered in M33/M34, then removed in M40.** A
  project held several independent stages (scenes / levels), switchable at edit time, with `switch_scene`
  / `next_scene` blocks to navigate at play time. M40 ripped the whole layer out (it complicated
  persistence + cross-stage state, and the chrome ate top-bar space) — a project is a single flat stage
  again. Bringing multiple stages back is a deliberate future milestone that would also need to tackle
  what M33/M34 left deferred: **cross-scene shared state** (a project-global variable store surviving a
  scene change — variables were per-scene and re-seeded on every switch) and a **scene-rename →
  `switch_scene` cascade**. The removed code (the `_scenes`/`project_scenes` model, `go_to_scene_by_name`,
  etc.) is recoverable from history at `fc6bf91` (M39) and earlier.
- **Custom block parameters / return value / rename cascade** — **M30 delivered the custom block** and
  **M31 delivered parameters.** M30 added the procedure (`define {name}` + `call {name}`, Scratch's "My
  Blocks") — a per-sprite named routine you make from the palette's **Make a Block** button and invoke
  with a `call` chip. M31 added **value (number/text) parameters**: a `define` declares an ordered
  `params` list (its prototype shows draggable parameter pills), a `call` carries an `args` dict (one
  slot per parameter), and a new **`param`** reporter reads a parameter via a per-call **parameter
  frame** ([`_on_call`](scripts/interpreter.gd)/[`_on_param`](scripts/interpreter.gd) — the
  parameter-frame milestone the earlier note named). What's *still* deferred: **boolean parameters**
  (value-only — a boolean param needs a boolean `param` output, a boolean arg slot, and a dialog way to
  mark a param boolean); a **return value** (Scratch custom blocks are statements, not reporters — same
  here); and the **parameter** half of the rename/sync cascade. **M32 delivered the *name* cascade** —
  renaming a `define` in place now rewrites this sprite's `call`s ([`rewrite_custom_block_refs`](scripts/block_view.gd),
  triggered from the in-place name commit in [`BlockCanvas._commit_literal`](scripts/block_canvas.gd) →
  [`editor._on_custom_block_renamed`](scripts/editor.gd)), the custom-block analog of M21's variable
  rename / M25's sprite rename, scoped per-sprite. What's *still* deferred is **parameter** sync (editing
  a `define`'s `params` should rewrite its `call`s' `args` keys and its body's `param`s) — which has no
  trigger yet because there is **no UI to edit a custom block's params after the Make-a-Block dialog**;
  building that param-editing (plus a rename-vs-add/remove heuristic, since params are name-keyed with no
  stable ids) is a milestone of its own. Also unbuilt: **deleting** a custom block from the UI (remove the
  `define` + strip its `call`s — the My-Blocks twin of M21's variable delete).
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
  `if true`) rather than leaving them to resolve null → false at RUN.
- **Editing a sprite's starting geometry from the UI** — **M27 delivered this.** A top-bar **Stage**
  toggle swaps the workspace to a **stage view** ([`StageView`](scripts/stage_view.gd)) that draws each
  sprite at its model `x/y/w/h/color` and lets you **select, drag, resize** (top-left-anchored, growing
  right/down — or about the centre with **Alt** held, or locked to the sprite's starting aspect ratio
  with **Shift** held — **M28**), and **recolour** sprites directly, with an
  **inspector** (x/y/w/h spin boxes + a Colour picker, plus the stage-level **Background** and grid
  **show / snap / colour / step** settings) for exact values — all writing straight into the same
  `_scripts` model RUN/SAVE read, and the background + grid into the project's stage-level properties
  ([`PongScripts.background()`](scripts/pong_scripts.gd) / [`grid()`](scripts/pong_scripts.gd), both
  saved in the `.json`) — no new opcode, no block-data-shape change, no runtime change. A `go_to` in a
  sprite's script still wins at RUN (the model position is the *starting* state — Scratch's model).
- **Uniform / aspect-locked resize** — **M28 delivered this.** Holding **`Shift`** while dragging a
  resize handle in the stage view ([`StageView._lock_aspect`](scripts/stage_view.gd)) constrains the
  sprite to the **aspect ratio it had at the start of the drag**, scaling the captured `w0/h0` by
  whichever axis grew more — composing with `Alt` (so `Shift+Alt` locks the ratio about the centre).
  Editor-side only — no opcode, no data-shape, no runtime change. What's *still* deferred from the
  stage editor: a **live embedded *run*** of the game inside the editor (a `SubViewport`
  stage panel beside the canvas — the larger restructure M26 named, the current RUN/ESC being a full
  scene swap).
- **Canvas panning / auto-scroll while dragging** — the canvas sits in a
  `ScrollContainer` (wheel/scrollbar scroll a tall script), but there's no click-drag
  panning of empty canvas and no auto-scroll when a drag reaches the viewport edge.
- **Editor resolution decoupled from the runtime** — **M26 delivered this.** Each scene sets the
  shared window's content scale in `_ready`: the editor a 960×540 logical viewport (roomy, high-res
  chrome, `_EDITOR_SIZE` the one zoom knob), the game a fixed 480×360 integer-snapped one (pixel-perfect,
  runtime logic untouched since `get_viewport_rect()` still reads 480×360). What's *still* deferred:
  **embedding the game inside the editor** as a live stage panel — that needs the runtime in a
  `SubViewport` instead of the current full scene swap (RUN/ESC) — and **finer editor zoom / theme-font
  tuning** beyond the single `_EDITOR_SIZE` value.
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
