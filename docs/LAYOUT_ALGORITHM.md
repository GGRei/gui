# Layout Algorithm Documentation

## Overview

The v-gui layout system is a constraint-based immediate-mode layout
engine inspired by the
[Clay UI library](https://www.youtube.com/watch?v=by9lQvpvMIc&t=1272s).
It uses a multi-pass pipeline to calculate widget positions and sizes.

Each frame, the view tree is converted to a layout tree, the pipeline
runs, and the resulting shapes are sent to the renderer.

## Data Flow

```
View Tree → Layout Tree → Renderer List → GPU Draw Calls
   ↓            ↓              ↓              ↓
Declarative  Calculated    Drawing      Hardware
 Structure   Positions    Commands     Rendering
```

1. **View Tree**: Declarative UI structure
   (`column`, `row`, `button`, etc.)
2. **Layout Tree**: Calculated positions and sizes for each element
3. **Renderer List**: Flat list of draw commands
   (rectangles, text, images)
4. **GPU Draw Calls**: Hardware-accelerated rendering via sokol/vglyph

## Core Concepts

### Axis

Every container has an `Axis` that controls child arrangement:

| Axis              | Description                        |
|-------------------|------------------------------------|
| `.left_to_right`  | Children laid out horizontally     |
| `.top_to_bottom`  | Children laid out vertically       |
| `.none`           | No automatic arrangement           |

### Sizing Modes

Each axis (width/height) uses one of three `SizingType` values:

| Mode      | Description                                     |
|-----------|-------------------------------------------------|
| `.fit`    | Shrink-wrap to content size                     |
| `.fill`   | Grow or shrink to fill remaining parent space   |
| `.fixed`  | Explicit pixel value; min and max set to value  |

The `Sizing` struct pairs a width and height `SizingType`. Nine
predefined constants cover all combinations: `fit_fit`, `fit_fill`,
`fit_fixed`, `fixed_fit`, `fixed_fill`, `fixed_fixed`, `fill_fit`,
`fill_fill`, `fill_fixed`.

### Alignment

| H-Align   | Behavior                                   |
|-----------|--------------------------------------------|
| `.left`   | No offset (default)                        |
| `.center` | Offset by half the remaining space         |
| `.right`  | Offset by all remaining space              |
| `.start`  | Culture-dependent (currently `.left`)      |
| `.end`    | Culture-dependent (currently `.right`)     |

| V-Align   | Behavior                                   |
|-----------|--------------------------------------------|
| `.top`    | No offset (default)                        |
| `.middle` | Offset by half the remaining space         |
| `.bottom` | Offset by all remaining space              |

Alignment is applied in two directions:

- **Along the axis**: shifts all children as a group within the
  container (e.g., centering a row's children horizontally).
- **Across the axis**: shifts each child individually within the
  cross-axis space (e.g., vertically centering each child in a row).

### Padding and Spacing

- **Padding**: insets the container's content area on all four sides.
- **Spacing**: gap inserted between consecutive children
  (fence-post: `(n-1) * spacing`).

### Constraints (min/max)

Each shape can carry `min_width`, `max_width`, `min_height`,
`max_height`. These are enforced after intrinsic sizing and after
fill distribution. When `sizing` is `.fixed`, min and max are both
set equal to the explicit size.

### over_draw

A shape with `over_draw = true` is allowed to draw into its parent's
padding area. It is excluded from spacing calculations and from
content-size measurements, so it does not affect the layout of
siblings. Used for elements like scrollbars that overlay content.

## Layout Pipeline

Before the pipeline runs, two preparation steps execute:

- **Set parents**: walk the tree, set each node's `.parent` pointer.
- **Extract floats**: remove floating layouts from the tree into a
  separate list, replacing them with empty placeholders.

The pipeline then runs on the main layout. Afterward, it runs again
on each extracted floating layout independently.

### Pipeline Steps

| #    | Function                       | Purpose                         |
|------|--------------------------------|---------------------------------|
| 1    | `layout_widths`                | Intrinsic widths                |
| 2    | `layout_fill_widths`           | Fill/weighted width distribution|
| 3    | `layout_wrap_containers`       | Wrap container line breaking    |
| 4    | `layout_overflow`              | Overflow item visibility        |
| 5    | `layout_wrap_text`             | Text wrapping                   |
| 6    | `layout_heights`               | Intrinsic heights               |
| 7    | `layout_fill_heights`          | Fill/weighted height distribution|
| 8    | `layout_adjust_scroll_offsets` | Clamp scroll offsets            |
| 9    | `layout_positions`             | X, Y positioning                |
| 10   | `layout_disables`              | Propagate disabled state        |
| 11   | `layout_scroll_containers`     | Tag text scroll parents         |
| 12   | `layout_amend`                 | Post-layout callbacks           |
| 13a  | `apply_layout_transition`      | Animate layout changes          |
| 13b  | `apply_hero_transition`        | Animate hero elements           |
| 14   | `layout_set_shape_clips`       | Compute clipping rectangles     |

`layout_hover` is not part of the numbered `layout_pipeline` steps. After
`layout_pipeline` has completed for the main tree and every floating layer,
`layout_arrange` calls `layout_hover` in reverse layer order. The topmost layer
therefore receives hover first, and a floating layer under the pointer blocks
hover processing for layers beneath it.

### Why Multiple Passes?

Each pass has dependencies on previous passes:

- **Width before height**: text wrapping depends on available width.
- **Intrinsic before fill**: minimum sizes must be known before
  distributing remaining space.
- **Size before position**: elements cannot be positioned without
  knowing their dimensions.
- **Position before clips**: clipping rectangles require final
  positions.
- **Clips before hover**: hit testing needs clipping info.

This separation avoids circular dependencies and keeps each pass
simple.

### Step-by-Step Description

**Step 1 — Intrinsic Widths** (`layout_widths`).
Walk the tree bottom-up. For each container:

- If sizing is `.fixed`, the width is already set; just recurse into
  children.
- If the axis is `.left_to_right` (along-axis): sum all children's
  widths plus spacing plus padding.
- If the axis is `.top_to_bottom` (cross-axis): take the widest
  child plus padding.
- Clamp to min/max constraints.

**Step 2 — Fill/Weighted Width Distribution** (`layout_fill_widths`).
Walk top-down. For each container whose axis is `.left_to_right`:

1. If at least one child has an explicit weight, distribute final widths
   proportionally among weighted children and implicit-weight `.fill`
   children. (See "Weighted Main-Axis Distribution" below.)
2. Otherwise, compute remaining width = container width − padding − spacing
   − sum of children widths. Grow or shrink `.fill` children using the legacy
   path. (See "Legacy Fill Distribution" below.)

For `.top_to_bottom` containers: each `.fill` child gets the
container's content width (minus padding), clamped to min/max.

**Step 3 — Wrap Containers** (`layout_wrap_containers`).
Wrap-enabled rows are split into lines after their widths are known. A weighted
group directly managed by a wrap container is rejected before distribution;
a wrap container may still be weighted as a child of another parent.

**Step 4 — Overflow Visibility** (`layout_overflow`).
Overflow panels determine which items fit after width sizing. A weighted group
directly managed by an overflow parent is rejected before distribution; the
overflow container itself may be weighted by an outer compatible parent.

**Step 5 — Text Wrapping** (`layout_wrap_text`).
Walk the tree. For each text shape, wrap its content to fit the
now-known width. Wrapping changes the shape's minimum height, which
is why this runs between width and height passes.

**Step 6 — Intrinsic Heights** (`layout_heights`).
Same logic as Step 1 but on the vertical axis:

- `.top_to_bottom` (along-axis): sum children heights + spacing +
  padding.
- `.left_to_right` (cross-axis): tallest child + padding.
- Special case: a `.fill`-height scroll container gets a small
  minimum height so it can shrink freely.

**Step 7 — Fill/Weighted Height Distribution** (`layout_fill_heights`).
Same logic as Step 2 but on the vertical axis. Weighted distribution applies
to `.top_to_bottom` parents; the cross axis continues to use existing sizing.

**Step 8 — Adjust Scroll Offsets** (`layout_adjust_scroll_offsets`).
For each scroll container, clamp scroll offsets so they stay within
the valid range (0 to content overflow). This handles cases where
a window resize makes the current offset invalid.

**Step 9 — Positions** (`layout_positions`).
Walk top-down. For each child:

1. Start at parent position + padding.
2. Add scroll offsets if inside a scroll container.
3. Compute along-axis alignment offset (shift the group of children
   if center/right/bottom aligned).
4. Compute cross-axis alignment offset per child (center or align
   each child individually).
5. Recurse, advancing the cursor by child size + spacing.

Floating layouts get their starting position from
`float_attach_layout`, which computes coordinates from the parent's
anchor point and the float's tie-off point, plus any offset.

**Step 10 — Disable Propagation** (`layout_disables`).
Walk the tree. If a parent is disabled, mark all descendants
disabled.

**Step 11 — Scroll Container Tags** (`layout_scroll_containers`).
Walk the tree. For each text shape, record the nearest ancestor
scroll container's `id_scroll`. This allows text selection to
auto-scroll the correct parent.

**Step 12 — Layout Amendments** (`layout_amend`).
Walk bottom-up. Call each shape's `amend_layout` callback if set.
These callbacks can adjust appearance after final positions are
known (e.g., showing hover highlights). They should not change
sizes.

**Step 13a — Layout Transitions** (`apply_layout_transition`).
If a layout transition animation is active, interpolate each
shape's position/size between its previous and current values.

**Step 13b — Hero Transitions** (`apply_hero_transition`).
If a hero transition animation is active, interpolate matching
hero-tagged shapes between their old and new positions.

**Step 14 — Clipping Rectangles** (`layout_set_shape_clips`).
Walk top-down. Each shape's clip rectangle is the intersection of
its own bounds with its parent's clip. This produces the visible
region used for hit testing and draw culling.

**Post-pipeline hover phase** (`layout_hover`).
As part of `layout_arrange`, walk layers from topmost to bottommost and children
first within each layer. For each shape with an `on_hover` handler, call the
handler when the mouse is inside its clip rectangle. Stop within a tree after
the first shape handles the event, and do not visit lower layers when a floating
layout contains the pointer.

### Legacy Fill Distribution Strategy

The `distribute_space` function handles both growing and shrinking
of `.fill`-sized children. The approach equalizes children
incrementally. This path is unchanged and is used when the parent has no
explicitly weighted child:

**Growing** (remaining space > 0):

1. Find the smallest `.fill` child and the next-smallest.
2. Grow all smallest children toward the next-smallest size,
   splitting the available space evenly among them.
3. If a child hits its `max_width`/`max_height`, lock it and
   remove it from candidates.
4. Repeat until no space remains or no candidates remain.

**Shrinking** (remaining space < 0):

1. Find the largest child (including `.fixed` siblings as
   reference points) and the next-largest.
2. Shrink all largest `.fill` children toward the next-largest,
   splitting the deficit evenly.
3. If a child hits its `min_width`/`min_height`, lock it and
   remove it from candidates.
4. Repeat until the deficit is resolved or no candidates remain.

This strategy prevents any single child from becoming much larger
or smaller than its siblings, producing visually balanced layouts.

### Weighted Main-Axis Distribution

`gui.weighted(weight:, view:)` transparently annotates the root `Shape`
generated by a child view. It does not add a `Layout` node. During view
generation, the wrapper delegates root generation to the decorated view,
transfers that view's possibly updated `content`, zeros its temporary interface
slot with `array_clear`, and lets the outer generic traversal generate those
children exactly once. Existing children already injected into the delegated
root are preserved.

A parent enters the weighted path only when at least one direct child has an
explicit main-axis weight. Candidates are explicitly weighted `.fit` or `.fill`
children plus undecorated `.fill` children with an implicit weight of `1`.
Undecorated `.fit` and `.fixed` children are non-participants whose constrained
sizes are reserved in the budget.

For each candidate, the final main-axis size is:

```text
size_i = clamp(lambda * weight_i, min_i, max_i)
```

A maximum of zero means unbounded. The solver computes the parent content
budget after padding, spacing, and non-participant sizes, then repeatedly:

1. computes `lambda` from the remaining budget and active weight sum;
2. sums the signed violations `clamp(target_i) - target_i`;
3. freezes minimum violators when that sum is positive, or maximum violators
   when it is negative; a near-zero sum means the clamped targets already
   preserve the budget within tolerance;
4. removes frozen candidates, recomputes the active weight sum, and repeats
   until stable.

If the minima exceed the budget, candidates retain their minima and overflow
geometrically; clipping or scrolling is never enabled implicitly. If every
maximum is reached, unused space is left to parent alignment. Calculations use
`f64` and final dimensions use `f32`. Conversion residue is corrected in reverse
declaration order among candidates that remain active and unclamped; candidates
frozen at a minimum or maximum are never moved. If the residue is smaller than
the ULP of every active candidate, it remains as representation error rather
than breaking a bound or a clamped solution. RTL changes positions, not that
order or the resulting sizes. Candidate and constraint buffers live in
`DistributeScratch`, so distribution allocates no per-frame memory after scratch
growth.

Validation occurs before distribution. An explicit weight must be positive and
finite and cannot be applied twice. A weighted root, a weighted child under an
`.none`-axis parent, and a weighted group directly under wrap or overflow are
invalid. A decorated root cannot be floating, `.none`, or `over_draw`, and a
participant cannot be `.fixed` on the parent's main axis. These cases panic
instead of ignoring the weight. In the absence of explicit weights, all legacy
sizing behavior and ordering remain unchanged.

## Floating Layouts

Floating layouts (tooltips, dropdowns, dialogs) are removed from
the main tree before the pipeline runs. Each floater is processed
independently through the full pipeline.

Positioning uses two anchor points:

- **`float_anchor`**: a point on the parent (e.g., `.bottom_left`).
- **`float_tie_off`**: a point on the float itself
  (e.g., `.top_left`).

The float is placed so that its tie-off point coincides with the
parent's anchor point, then shifted by `float_offset_x/y`.
Nine anchor positions are available via the `FloatAttach` enum
(combinations of top/middle/bottom × left/center/right).

Floating layouts render after the main layout, so they appear on
top. Dialogs are added last to ensure they are always topmost.

## Scroll Containers

A container becomes scrollable by setting `id_scroll` to a nonzero
value. Scroll state is stored in the window's `ViewState`:

- `scroll_x[id_scroll]` — horizontal offset
- `scroll_y[id_scroll]` — vertical offset

The scroll offset shifts child positions (Step 9) but does not
change the container's own size. Step 8 clamps offsets to prevent
scrolling past content bounds. Scroll containers automatically
enable clipping so children outside the viewport are not drawn.

## Layout Amendments

The `amend_layout` callback on a shape runs in Step 12, after all
positions and sizes are final. It receives the layout and window,
and can modify appearance properties (color, visibility,
decorations). It should not change sizes, as the size passes have
already completed.

Common uses: hover highlights, dynamic styling based on position,
tooltip placement adjustments.

## Related Files

- `layout.v` — `layout_arrange`, `layout_pipeline`,
  parent/float extraction
- `layout_sizing.v` — `layout_widths`, `layout_heights`,
  `layout_fill_widths`, `layout_fill_heights`, `distribute_space`
- `view_weighted.v` — transparent child weighting decorator
- `layout_position.v` — `layout_positions`, `layout_disables`,
  `layout_scroll_containers`, `layout_amend`, `layout_hover`,
  `layout_set_shape_clips`, `layout_wrap_text`,
  `layout_adjust_scroll_offsets`
- `layout_float.v` — `FloatAttach`, `float_attach_layout`
- `layout_query.v` — `spacing()`, `content_width`,
  `content_height`, query helpers
- `sizing.v` — `SizingType`, `Sizing`, constants
- `alignment.v` — `Axis`, `HorizontalAlign`, `VerticalAlign`
- `animation_layout.v` — `apply_layout_transition`
- `animation_hero.v` — `apply_hero_transition`
