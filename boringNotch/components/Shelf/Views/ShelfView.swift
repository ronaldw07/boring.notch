//
//  ShelfItemView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI
import AppKit

struct ShelfView: View {
    @EnvironmentObject var vm: BoringViewModel
    @StateObject var tvm = ShelfStateViewModel.shared
    @StateObject var selection = ShelfSelectionModel.shared
    @StateObject private var quickLookService = QuickLookService()
    private let spacing: CGFloat = 8

    /// One card's full width: the 105pt content plus the 5pt padding it
    /// carries on each side. Knowing this outright means the row's total
    /// width is arithmetic rather than something to measure and wait for —
    /// which is what lets the bar be sized correctly on the very first
    /// frame, and scale exactly with the number of items.
    private static let itemWidth: CGFloat = 115

    /// How far the row is scrolled, in points. Driven directly rather than
    /// read back out of a scroll view: the previous version asked AppKit for
    /// the `NSScrollView` behind SwiftUI's `ScrollView` and moved that, and
    /// when that lookup came back empty every drag silently did nothing.
    @State private var scrollX: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0

    /// Groups currently shown expanded (their items individually) rather
    /// than as a single collapsed stack tile. Keyed by ShelfItem.groupID.
    @State private var expandedGroups: Set<UUID> = []

    var body: some View {
        panel
            .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                handleDrop(providers: providers)
            }
            // Bind Quick Look to shelf selection
            .onChange(of: selection.selectedIDs) {
                updateQuickLookSelection()
            }
            .quickLookPresenter(using: quickLookService)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !selection.isDragging else { return false }
        vm.dropEvent = true
        ShelfStateViewModel.shared.load(providers)
        return true
    }

    private func updateQuickLookSelection() {
        guard quickLookService.isQuickLookOpen && !selection.selectedIDs.isEmpty else { return }

        let selectedItems = selection.selectedItems(in: tvm.items)
        let urls: [URL] = selectedItems.compactMap { item in
            if let fileURL = item.fileURL {
                return fileURL
            }
            if case .link(let url) = item.kind {
                return url
            }
            return nil
        }

        if !urls.isEmpty {
            quickLookService.updateSelection(urls: urls)
        }
    }

    // No clear-on-background tap here any more. It was a plain
    // `.onTapGesture` on this whole view, cards included, and in this window
    // a SwiftUI gesture still fires alongside the AppKit `mouseDown` that a
    // card handles — so every left click selected an item and then wiped the
    // selection a moment later, which is what stopped anything staying
    // highlighted. Clicking an item again toggles it back off, so nothing is
    // lost but the clear-everything shortcut.
    var panel: some View {
        content
            .padding()
            // Fills the panel in its own right now that it's the base view
            // rather than an overlay on the border shape — without this the
            // empty state would shrink the whole panel to the size of its
            // "Drop files here" label.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The border used to be the base and the content an overlay on
            // top of it, so a card scrolling toward either end crossed over
            // the dashed line and kept going into the gap outside. Reversed:
            // the content is clipped to the panel's own shape and the border
            // is drawn back over it, so the row passes *under* the boundary
            // and a card leaving the row disappears beneath the line instead
            // of in front of it.
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        vm.dragDetectorTargeting
                            ? Color.accentColor.opacity(0.9)
                            : Color.white.opacity(0.1),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
                    )
            }
            .overlay(alignment: .topTrailing) {
                if !tvm.isEmpty {
                    selectAllButton
                        // Tucked close to the corner, right under where the
                        // battery indicator sits in the header above — the
                        // same placement the clipboard tab's own corner
                        // buttons use, rather than the header's usual 6pt
                        // content padding, which reads as floating loose in
                        // the shelf's own space instead of continuing the
                        // header's row.
                        .padding(.top, 2)
                        .padding(.trailing, 6)
                }
            }
            .transaction { transaction in
                transaction.animation = vm.animation
            }
            .contentShape(Rectangle())
    }

    var content: some View {
        Group {
            if tvm.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .symbolVariant(.fill)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white, .gray)
                        .imageScale(.large)

                    Text("Drop files here")
                        .foregroundStyle(.gray)
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.medium)
                }
            } else {
                // One GeometryReader for both rows, so the row and the bar
                // beneath it are measured against exactly the same width and
                // can't disagree about how far there is to travel.
                GeometryReader { geo in
                    VStack(spacing: 6) {
                        itemRow
                        scrollBar(trackWidth: geo.size.width)
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    .onAppear { viewportWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, width in viewportWidth = width }
                }
            }
        }
        .onAppear {
            ShelfStateViewModel.shared.cleanupInvalidItems()
        }
    }

    // MARK: - Select all

    /// True once every item is selected, not just every displayed *tile* —
    /// a collapsed stack is one tile standing in for several real items, and
    /// selecting all has to mean all of those too, since that's what a
    /// drag-out actually carries.
    private var isEverythingSelected: Bool {
        !tvm.items.isEmpty && selection.selectedIDs.count == tvm.items.count
    }

    /// Doubles as its own undo: this is the only remaining way to clear a
    /// selection now that a background tap no longer does — see the note on
    /// `panel` above.
    private var selectAllButton: some View {
        Button {
            if isEverythingSelected {
                selection.clear()
            } else {
                selection.selectAll(tvm.items)
            }
        } label: {
            Text(isEverythingSelected ? "Deselect All" : "Select All")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Row

    private var itemRow: some View {
        HStack(spacing: spacing) {
            ForEach(displayTiles) { tile in
                tileView(for: tile)
                    .id(tile.id)
            }
        }
        .padding(.horizontal, Self.rowInset)
        .frame(width: contentWidth, alignment: .leading)
        .offset(x: -clampedScroll)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
        // Softens both ends into the black behind the panel instead of
        // slicing an item off mid-thumbnail against the dashed border. Only
        // the end you can actually scroll toward fades — at rest the first
        // item reads as a first item, not as something already cut off.
        .mask(edgeFade)
        // Horizontal scroll here is the row's, not the notch's swipe-between-
        // tabs gesture. Both see the same events, so without this a wheel
        // over the shelf changed tab instead of moving the row.
        .onHover { vm.isHoveringShelfRow = $0 }
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
            handleDrop(providers: providers)
        }
    }

    @ViewBuilder
    private func tileView(for tile: ShelfDisplayTile) -> some View {
        switch tile {
        case .single(let item):
            ShelfItemView(item: item) { delta in
                // Trackpad and wheel, forwarded up from the card the cursor
                // is actually over. There's no scroll view left to handle
                // this on its own now that the offset is ours.
                setScroll(scrollX - delta)
            }
            .environmentObject(quickLookService)
        case .stack(let groupID, let items):
            ShelfStackTileView(items: items, isExpanded: false, onScroll: { delta in setScroll(scrollX - delta) }) {
                toggleGroup(groupID)
            }
        case .expandedMarker(let groupID, let items):
            ShelfStackTileView(items: items, isExpanded: true, onScroll: { delta in setScroll(scrollX - delta) }) {
                toggleGroup(groupID)
            }
        }
    }

    private func toggleGroup(_ groupID: UUID) {
        if expandedGroups.contains(groupID) {
            expandedGroups.remove(groupID)
        } else {
            expandedGroups.insert(groupID)
        }
    }

    // MARK: - Stacking

    /// One entry per tile actually laid out in the row: an ungrouped item, a
    /// collapsed multi-file drop, or (once expanded) the marker that takes
    /// its place next to its now-individual items. All three are exactly
    /// `itemWidth` wide, which is what keeps `contentWidth` a straight count
    /// rather than something that has to know each tile's own shape.
    private enum ShelfDisplayTile: Identifiable {
        case single(ShelfItem)
        case stack(groupID: UUID, items: [ShelfItem])
        case expandedMarker(groupID: UUID, items: [ShelfItem])

        var id: String {
            switch self {
            case .single(let item): return "item-\(item.id)"
            case .stack(let groupID, _): return "stack-\(groupID)"
            case .expandedMarker(let groupID, _): return "expanded-\(groupID)"
            }
        }
    }

    /// Collapses consecutive items that share a groupID into one tile. A run
    /// down to a single surviving member (its siblings removed elsewhere)
    /// just renders as a plain item — there's nothing left to stack.
    private var displayTiles: [ShelfDisplayTile] {
        var tiles: [ShelfDisplayTile] = []
        let items = tvm.items
        var index = 0
        while index < items.count {
            let item = items[index]
            guard let groupID = item.groupID else {
                tiles.append(.single(item))
                index += 1
                continue
            }

            var run: [ShelfItem] = [item]
            var next = index + 1
            while next < items.count, items[next].groupID == groupID {
                run.append(items[next])
                next += 1
            }

            if run.count > 1 {
                if expandedGroups.contains(groupID) {
                    tiles.append(.expandedMarker(groupID: groupID, items: run))
                    for it in run { tiles.append(.single(it)) }
                } else {
                    tiles.append(.stack(groupID: groupID, items: run))
                }
            } else {
                tiles.append(.single(item))
            }
            index = next
        }
        return tiles
    }

    /// How far the row is held off each end, so the first card starts inside
    /// the dashed border rather than flush against it.
    private static let rowInset: CGFloat = 8

    /// How far the fade at each end reaches, in points.
    private static let fadeWidth: CGFloat = 24

    private var edgeFade: some View {
        let width = max(viewportWidth, 1)
        let fade = min(Self.fadeWidth / width, 0.35)
        // A one-point tolerance, so floating-point drift at either limit
        // can't leave a sliver of fade on an end there's nothing behind.
        let leadingEdge = clampedScroll > 1 ? fade : 0
        let trailingEdge = clampedScroll < maxScroll - 1 ? 1 - fade : 1

        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: leadingEdge),
                .init(color: .black, location: trailingEdge),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: - Geometry

    /// Arithmetic, not a measurement — see `itemWidth`. Counts displayed
    /// tiles, not raw items: a collapsed stack is one tile for N items, so
    /// counting items here would leave the bar (and the clipped/faded row)
    /// sized for a row that's wider than what's actually laid out.
    private var contentWidth: CGFloat {
        let count = CGFloat(displayTiles.count)
        guard count > 0 else { return 0 }
        return 2 * Self.rowInset + count * Self.itemWidth + (count - 1) * spacing
    }

    private var maxScroll: CGFloat {
        max(0, contentWidth - viewportWidth)
    }

    private var clampedScroll: CGFloat {
        min(max(scrollX, 0), maxScroll)
    }

    private func setScroll(_ x: CGFloat) {
        scrollX = min(max(x, 0), maxScroll)
    }

    // MARK: - Scroll bar

    private static let barThickness: CGFloat = 6
    private static let barRowHeight: CGFloat = 16

    private var showsScrollBar: Bool { maxScroll > 0 }

    /// The pill's width is the visible fraction of the row, so it shrinks as
    /// items are added and fills the track when they all fit. Both the track
    /// and the pill take the drag, so grabbing anywhere along the bar works,
    /// not just on the pill itself.
    private func scrollBar(trackWidth: CGFloat) -> some View {
        let visibleFraction = contentWidth > 0 ? min(viewportWidth / contentWidth, 1) : 1
        let thumbWidth = max(28, trackWidth * visibleFraction)
        let maxTravel = max(trackWidth - thumbWidth, 1)
        let progress = maxScroll > 0 ? clampedScroll / maxScroll : 0

        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.10))
                .frame(width: trackWidth, height: Self.barThickness)

            Capsule()
                .fill(Color.white.opacity(0.45))
                .frame(width: thumbWidth, height: Self.barThickness)
                .offset(x: progress * maxTravel)

            // Belt and braces: an AppKit view handling the mouse directly,
            // plus SwiftUI's own gesture on the same fixed frame. They read
            // the same x and compute the same result, so whichever of the two
            // this window actually delivers events to, the bar moves. Both
            // measure against a frame that never moves — attaching this to
            // the pill meant its reference frame shifted as a *result* of the
            // drag, and it could never travel more than a sliver.
            ScrollTrackView { x in
                setScroll(scrollFraction(atX: x, thumbWidth: thumbWidth, maxTravel: maxTravel) * maxScroll)
            }
        }
        .frame(width: trackWidth, height: Self.barRowHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    setScroll(scrollFraction(atX: value.location.x, thumbWidth: thumbWidth, maxTravel: maxTravel) * maxScroll)
                }
        )
        .opacity(showsScrollBar ? 1 : 0)
        .allowsHitTesting(showsScrollBar)
    }

    /// Centres the pill on the cursor, then clamps — so the point you grab is
    /// the point that ends up under you anywhere along the track.
    private func scrollFraction(atX x: CGFloat, thumbWidth: CGFloat, maxTravel: CGFloat) -> CGFloat {
        min(max((x - thumbWidth / 2) / maxTravel, 0), 1)
    }
}

/// Reports raw mouse-down/dragged positions straight from AppKit. Its view
/// draws nothing, so it has to sit on *top* of the bar it covers: an NSView's
/// hit testing is bounds-based and doesn't care what's rendered under it,
/// which is exactly why this is more dependable here than asking SwiftUI to
/// hit-test a transparent region.
private struct ScrollTrackView: NSViewRepresentable {
    let onDrag: (CGFloat) -> Void

    func makeNSView(context: Context) -> TrackView {
        let view = TrackView()
        view.onDrag = onDrag
        return view
    }

    func updateNSView(_ nsView: TrackView, context: Context) {
        nsView.onDrag = onDrag
    }

    final class TrackView: NSView {
        var onDrag: ((CGFloat) -> Void)?

        /// The notch panel never becomes key, so without this the first click
        /// on it would be swallowed as an activation click instead of being
        /// delivered here.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) { report(event) }
        override func mouseDragged(with event: NSEvent) { report(event) }

        private func report(_ event: NSEvent) {
            onDrag?(convert(event.locationInWindow, from: nil).x)
        }
    }
}
