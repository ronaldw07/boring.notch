# Changelog

Fork of [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch), tracking upstream **2.7.3**.

Versions below number this fork's own line of work, independent of upstream's.
Newest first. Times are local (PDT).

---

## 0.3.4 — 2026-09-12 17:05

### Added

- **Shelf: a Select All / Deselect All button**, top-right, tucked under the
  battery indicator like the clipboard tab's own corner buttons. Selects
  every item on the shelf (not just visible stack tiles) so it lines up with
  what a drag-out actually carries, and doubles as the way to clear a
  selection now that a background tap no longer does that.

---

## 0.3.3 — 2026-09-12 16:18

### Fixed

- **Dragging several selected shelf items out together now actually carries
  all of them.** Pressing down on a card that's already selected fired the
  sticky-multi-select toggle immediately, before the drag-distance check ever
  ran — so starting a drag from one of several selected cards dropped it from
  the selection first, and the drag fell back to just that single card. The
  click is now held until mouseUp, and only applied if no drag happened.

---

## 0.3.2 — 2026-09-12 15:02

### Fixed

- **Clipboard history now captures from launch, not from first opening the
  tab.** `ClipboardManager` is a lazy singleton whose `init()` is what starts
  the pasteboard poll loop; the only thing touching it was `ClipboardView`
  itself, so nothing was recorded until that tab was opened once — and even
  the copy made right before that first visit was missed, since `init()`
  seeds its baseline from whatever's already on the pasteboard at that
  moment. Now touched once at launch instead.

---

## 0.3.1 — 2026-09-12 13:47

### Fixed

- **"Remember last tab" actually remembers the last tab.** On close, a
  shelf-has-files check ran before this setting was ever consulted, so having
  anything on the shelf — which is most of the time, once you've used it once
  — forced a jump to Shelf regardless. The setting is off by default; turn it
  on in Settings → General.

---

## 0.3.0 — 2026-09-12 11:19

### Added

- **Shelf: pinning.** Right-click an item to pin it. Pinned items sort to the
  left of the row and keep their order among themselves, so the ones worth
  keeping stay reachable instead of being pushed off the end by newer drops.
  A pinned item also survives "remove from shelf after dragging".
- **Shelf: stacks.** Dropping several files at once now lands as a single tile
  with a count badge instead of one card per file. Click to expand it in place,
  click the marker to collapse. Dragging a collapsed stack drags the whole
  group.
- **Shelf: sticky multi-select.** A plain left click adds to the selection
  rather than replacing it, so several items can be highlighted at once and
  dragged or shared together. Clicking an item again deselects it.

### Changed

- **Shelf: removed the AirDrop / quick-share tile**, along with its now-unused
  Quick Share provider picker in Settings. The row gets that width back, and
  sharing stays available through right-click and drag-out.
- **Shelf: contents are clipped to the panel**, with the dashed border drawn
  over the top, so a card scrolling toward either end passes under the boundary
  instead of across it. Both ends fade out over 24pt.

### Fixed

- **Shelf: the horizontal scroll bar works.** It was driving an `NSScrollView`
  looked up through `enclosingScrollView`, which came back empty, so every drag
  silently did nothing. The row now owns its scroll offset directly.
- **Shelf: the bar is sized from item count** rather than a measurement, so it
  is correct on the first frame and scales as items are added.
- **Shelf: a left click keeps its highlight.** A clear-on-tap gesture covered
  the whole panel, cards included, and wiped the selection immediately after
  each click.

---

## 0.2.0 — 2026-09-11

### Added

- **Shelf: remove buttons.** Hovering a card shows an X in its top-right
  corner; the circle turns red under the cursor. Both the click and the hover
  are handled in AppKit, since SwiftUI's hit-testing stops at the drag view
  covering each card.
- **Shelf: hover highlight.** A light-blue border and faint fill, ranked below
  drop-target and selection so it never paints over them.
- **Shelf: wheel and trackpad scrolling** over the row, which previously
  changed notch tab instead.

### Changed

- **Timer tab laid out as a row** — readout on the left, presets and controls
  beside it — instead of a column. It no longer grows the notch to fit itself,
  so it matches the height of every other tab rather than hanging below as its
  own box.
- **Timer/Stopwatch mode buttons swapped**, Timer first.
- **Running timer's readout nudged 8pt** toward the screen edge.
- **Closed notch narrowed by 2pt**, one point off each edge.

### Fixed

- **Countdown no longer skips 4:59.** Ticks land just past each second
  boundary, so flooring took 5:00 straight to 4:58. Countdown display now
  rounds up; the stopwatch still floors, to stay consistent with the hundredths
  beside it.
- **Play on a finished countdown reruns it** instead of instantly re-firing
  completion.

---

## 0.1.0 — 2026-09-10

### Fixed

- **Closing the notch animates instead of teleporting.** The panel's height
  tracked the window rather than its own animated value: expanding grew the
  window up front so there was something to animate into, but collapsing held
  the window open until the end, so nothing moved until it snapped shut.
- **Collapse no longer flickers.** Four separate races — a superseded
  collapse's completion handler yanking the window down, a resting-height
  baseline overwritten mid-animation, a tab switch zeroing both heights by
  hand, and a deferred `setFrame` compositing stale bits for a frame.
- **A collapsing panel no longer reads as a mouse-exit** and closes the whole
  notch part way through.
