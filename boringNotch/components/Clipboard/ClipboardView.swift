//
//  ClipboardView.swift
//  boringNotch
//
//  Recently copied items, newest first. Clicking one puts it back on the
//  pasteboard.
//

import SwiftUI

private let rowHeight: CGFloat = 38
private let rowSpacing: CGFloat = 2
private let listVerticalPadding: CGFloat = 8
/// Rows visible when the expand button is on. The window is grown to fit
/// exactly this many, so it's a real target height, not a minimum.
private let expandedRowCount = 10
/// Ease-out quint. Decelerating suits a panel unfolding; a spring would
/// overshoot and momentarily push the notch's bottom radius past its rest
/// position.
private let expandCurve = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.35)
/// Footprint of the expand button at the top-trailing corner: a 22pt button
/// plus its 2pt padding. The scroll thumb's track starts below this so the
/// two never fight for the same hit area.
private let expandButtonInset: CGFloat = 24
/// Clears the button's footprint plus a small gap, so the first row starts
/// below it instead of directly under it.
private let listTopInset: CGFloat = expandButtonInset + 4

private struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ClipboardView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var clipboard = ClipboardManager.shared
    @State private var justCopiedID: UUID?

    @State private var scrollOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    /// The viewport as it is at rest. Expanding measures against this rather
    /// than the live height, so a second press mid-animation can't compound
    /// the growth it already applied.
    @State private var collapsedViewportHeight: CGFloat = 0
    @State private var scrollTarget: CGFloat?

    @State private var isExpanded = false

    @State private var isConfirmingClearAll = false
    @State private var clearAllResetTask: Task<Void, Never>?

    var body: some View {
        Group {
            if clipboard.items.isEmpty {
                emptyState
            } else {
                ZStack(alignment: .trailing) {
                    GeometryReader { viewport in
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: false) {
                                LazyVStack(spacing: rowSpacing) {
                                    ForEach(clipboard.items) { item in
                                        ClipboardRow(item: item, isConfirming: justCopiedID == item.id) {
                                            clipboard.delete(item)
                                        }
                                        .id(item.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture { copy(item) }
                                    }
                                }
                                .padding(.horizontal, 6)
                                .padding(.top, listTopInset)
                                .padding(.bottom, listVerticalPadding)
                                .background(
                                    GeometryReader { content in
                                        Color.clear
                                            .preference(key: ContentHeightKey.self, value: content.size.height)
                                            .preference(key: ScrollOffsetKey.self,
                                                        value: content.frame(in: .named("clipboardScroll")).minY)
                                    }
                                )
                            }
                            .coordinateSpace(name: "clipboardScroll")
                            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
                            .onPreferenceChange(ScrollOffsetKey.self) { scrollOffset = $0 }
                            .onChange(of: scrollTarget) { _, target in
                                guard let target, let id = itemID(atFraction: target) else { return }
                                proxy.scrollTo(id, anchor: .top)
                            }
                        }
                    }

                    if contentHeight > viewportHeight {
                        scrollThumb
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Measured out here rather than on the populated branch's ZStack, so
        // the height is known even while the list is empty — otherwise the
        // first expand after a fresh launch has nothing to measure against.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            viewportHeight = height
            if !isExpanded {
                collapsedViewportHeight = height
            }
        }
        .overlay(alignment: .topTrailing) {
            // Undo can still be relevant right after a clear, when items is
            // already empty — so it's gated on its own state, not folded
            // into the items check below.
            if !clipboard.items.isEmpty || clipboard.canUndo {
                HStack(spacing: 8) {
                    if clipboard.canUndo {
                        undoButton
                    }
                    if !clipboard.items.isEmpty {
                        clearAllButton
                        expandButton
                    }
                }
                // Tucked close to the corner, right under where the battery
                // indicator sits in the header above, rather than the
                // header's usual 6pt content padding — that gap read as
                // floating in the clipboard's own space rather than
                // continuing the header's row.
                .padding(.top, 2)
                .padding(.trailing, 6)
            }
        }
        .onAppear {
            // Forces the tab to always open at the exact same size as Home
            // or Shelf, no matter what state a previous visit left behind.
            // Growth only ever happens from an explicit press of the expand
            // button below, never as a side effect of switching tabs.
            isExpanded = false
            vm.extraContentHeight = 0
            vm.windowExtraHeight = 0
        }
        .onDisappear {
            // Leaving the tab collapses the window back down; nothing else
            // resets these, and they would otherwise stay tall while showing
            // Home or Shelf. No animation — the tab is already gone.
            if isExpanded {
                isExpanded = false
                vm.extraContentHeight = 0
                vm.windowExtraHeight = 0
            }
            clearAllResetTask?.cancel()
            isConfirmingClearAll = false
        }
    }

    // MARK: - Expand

    private var expandButton: some View {
        Button(action: toggleExpanded) {
            // Two distinct symbols rather than one rotated 180° — SF Symbols
            // already has an outward pair for "expand" and an inward pair for
            // "collapse", so the icon reads correctly instead of ambiguously
            // spinning in place.
            Image(systemName: isExpanded
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color(nsColor: .secondarySystemFill)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Clear all

    /// Requires a second tap within a couple seconds to actually clear —
    /// same red the whole time, only the label swaps, so the ask reads as
    /// "are you sure" rather than a different action appearing.
    private var clearAllButton: some View {
        Button(action: tapClearAll) {
            Text(isConfirmingClearAll ? "Confirm" : "Delete All")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func tapClearAll() {
        guard !clipboard.items.isEmpty else { return }

        guard isConfirmingClearAll else {
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)) {
                isConfirmingClearAll = true
            }
            clearAllResetTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)) {
                    isConfirmingClearAll = false
                }
            }
            return
        }

        clearAllResetTask?.cancel()
        isConfirmingClearAll = false
        clipboard.clear()

        // Collapse the window back down the same animated way the expand
        // button's own collapse does — otherwise it's left tall behind the
        // now-empty state.
        if isExpanded {
            toggleExpanded()
        }
    }

    // MARK: - Undo

    private var undoButton: some View {
        Button(action: clipboard.undo) {
            Text("Undo")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func toggleExpanded() {
        isExpanded.toggle()

        guard isExpanded else {
            // Shrink the window only once the panel has finished animating
            // closed. The window is the content's clip bounds, so resizing it
            // up front slices the bottom off the panel for the whole
            // animation.
            withAnimation(expandCurve, completionCriteria: .removed) {
                vm.extraContentHeight = 0
            } completion: {
                vm.windowExtraHeight = 0
            }
            return
        }

        // Grow the window first: it's transparent, so an instant resize is
        // invisible, and the panel needs somewhere to animate into.
        let shortfall = expandShortfall()
        vm.windowExtraHeight = shortfall
        withAnimation(expandCurve) {
            vm.extraContentHeight = shortfall
        }
    }

    /// Only the shortfall needs to come from the window — whatever already
    /// fits on screen is free. Capped against the screen so the layout can
    /// never ask for a height the window is then clamped out of giving it,
    /// which would put the two out of sync and overflow the panel again.
    @MainActor
    private func expandShortfall() -> CGFloat {
        let targetContentHeight = CGFloat(expandedRowCount) * rowHeight
            + CGFloat(expandedRowCount - 1) * rowSpacing
            + listTopInset + listVerticalPadding
        let shortfall = max(0, targetContentHeight - collapsedViewportHeight)

        guard let screenHeight = getScreenFrame(vm.screenUUID)?.height else { return shortfall }
        return min(shortfall, max(0, screenHeight - windowSize.height))
    }

    // MARK: - Scroll thumb

    /// Scrubs the whole list from a pill on the trailing edge, the same
    /// gesture as iOS's fast-scroll index. Sized to the actual visible
    /// fraction with only a small floor, so it visibly shrinks as more items
    /// pile up rather than staying a fixed size regardless of history length.
    private var scrollThumb: some View {
        GeometryReader { geo in
            let trackHeight = geo.size.height
            let thumbHeight = max(8, trackHeight * (viewportHeight / max(contentHeight, viewportHeight)))
            let maxTravel = trackHeight - thumbHeight
            let scrollableHeight = max(contentHeight - viewportHeight, 1)
            let progress = min(max(-scrollOffset / scrollableHeight, 0), 1)

            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: 3, height: thumbHeight)
                .position(x: geo.size.width - 3, y: thumbHeight / 2 + progress * maxTravel)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = min(max(value.location.y / trackHeight, 0), 1)
                            scrollTarget = fraction
                        }
                )
        }
        .frame(width: 10)
        // Insets the track itself rather than offsetting the math below, so
        // trackHeight, maxTravel and progress all read the already-inset
        // geometry and can't drift out of sync with where the thumb is
        // actually drawn.
        .padding(.top, expandButtonInset)
        .padding(.trailing, 2)
    }

    private func itemID(atFraction fraction: CGFloat) -> UUID? {
        guard !clipboard.items.isEmpty else { return nil }
        let index = min(Int(fraction * CGFloat(clipboard.items.count)), clipboard.items.count - 1)
        return clipboard.items[index].id
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clipboard")
                .font(.system(size: 26))
                .foregroundStyle(.gray)
            Text("Nothing copied yet")
                .font(.caption)
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copy(_ item: ClipboardItem) {
        clipboard.copy(item)
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)) {
            justCopiedID = item.id
        }
        Task {
            try? await Task.sleep(for: .seconds(1))
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)) {
                justCopiedID = nil
            }
        }
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let isConfirming: Bool
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            thumbnail

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isConfirming {
                HStack(spacing: 3) {
                    Text("Copied")
                        .font(.system(size: 9, weight: .semibold))
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.green.opacity(0.15))
                )
                .transition(.opacity)
            } else if isHovering {
                Button(action: onDelete) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.red.opacity(0.15))
                        )
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? Color(nsColor: .secondarySystemFill) : .clear)
        )
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var thumbnail: some View {
        let side: CGFloat = 26
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(red: 28/255, green: 28/255, blue: 30/255))
            .frame(width: side * 1.3, height: side)
            .overlay {
                switch item.kind {
                case .file(let url):
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                case .link:
                    Image(systemName: "link")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                case .image(let filename):
                    if let url = ClipboardManager.shared.imageURL(forFilename: filename),
                       let image = NSImage(contentsOf: url) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 11))
                            .foregroundStyle(.gray)
                    }
                case .text:
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                }
            }
    }

    private var title: String {
        switch item.kind {
        case .file(let url):
            return url.lastPathComponent
        case .link(let url):
            return url.host ?? url.absoluteString
        case .text(let text):
            return text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
        case .image:
            return "Image"
        }
    }

    private var subtitle: String {
        let kindName: String
        switch item.kind {
        case .file: kindName = "File"
        case .link: kindName = "Link"
        case .image: kindName = "Image"
        case .text: kindName = "Text"
        }
        return "\(kindName) · Copied \(Self.copiedDescription(item.copiedAt))"
    }

    /// Times today, "yesterday" for the day before, dates beyond that — the
    /// shortest phrasing that is still unambiguous.
    private static func copiedDescription(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "yesterday"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

#Preview {
    ClipboardView()
        .frame(width: 400, height: 180)
        .background(.black)
}
