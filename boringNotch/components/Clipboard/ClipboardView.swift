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
                                .padding(.vertical, listVerticalPadding)
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
        .overlay(alignment: .bottomTrailing) {
            // Nothing to expand into when there's no history.
            if !clipboard.items.isEmpty {
                expandButton
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
        .padding(6)
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
            + listVerticalPadding * 2
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
                if let data = item.imageData, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: item.isImage ? "photo" : "doc.text")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                }
            }
    }

    private var title: String {
        guard let text = item.text else { return "Image" }
        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }

    private var subtitle: String {
        "\(item.isImage ? "Image" : "Text") · Copied \(Self.copiedDescription(item.copiedAt))"
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
