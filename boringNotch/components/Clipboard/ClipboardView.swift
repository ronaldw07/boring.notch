//
//  ClipboardView.swift
//  boringNotch
//
//  Recently copied items, newest first. Clicking one puts it back on the
//  pasteboard.
//

import SwiftUI

/// Row height shrinks toward this as the bottom handle is pulled down, so
/// more history fits in the same panel. The notch's open height is a fixed
/// window size (see `openNotchSize`), not something this view can grow —
/// pulling down densifies the existing space rather than expanding it.
private let normalRowHeight: CGFloat = 38
private let compactRowHeight: CGFloat = 24
private let densityDragTravel: CGFloat = 70

private struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ClipboardView: View {
    @ObservedObject private var clipboard = ClipboardManager.shared
    @State private var justCopiedID: UUID?

    @State private var scrollOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var scrollTarget: CGFloat?

    @State private var density: CGFloat = 0
    @State private var densityAtDragStart: CGFloat = 0

    private var rowHeight: CGFloat {
        normalRowHeight - (normalRowHeight - compactRowHeight) * density
    }

    var body: some View {
        Group {
            if clipboard.items.isEmpty {
                emptyState
            } else {
                ZStack(alignment: .trailing) {
                    GeometryReader { viewport in
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: false) {
                                LazyVStack(spacing: 2) {
                                    ForEach(clipboard.items) { item in
                                        ClipboardRow(item: item, height: rowHeight,
                                                     isConfirming: justCopiedID == item.id)
                                            .id(item.id)
                                            .contentShape(Rectangle())
                                            .onTapGesture { copy(item) }
                                    }
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
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
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { viewportHeight = $0 }

                    if contentHeight > viewportHeight {
                        scrollThumb
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { densityHandle }
    }

    // MARK: - Scroll thumb

    /// Scrubs the whole list from a pill on the trailing edge, the same
    /// gesture as iOS's fast-scroll index.
    private var scrollThumb: some View {
        GeometryReader { geo in
            let trackHeight = geo.size.height
            let thumbHeight = max(24, trackHeight * (viewportHeight / max(contentHeight, viewportHeight)))
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

    // MARK: - Density handle

    /// Pulling down packs rows tighter so more of the history is visible at
    /// once; pushing back up returns to the normal, easier-to-hit row size.
    private var densityHandle: some View {
        Capsule()
            .fill(.white.opacity(0.25))
            .frame(width: 32, height: 4)
            .padding(.vertical, 5)
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let delta = value.translation.height / densityDragTravel
                        density = min(max(densityAtDragStart + delta, 0), 1)
                    }
                    .onEnded { _ in
                        densityAtDragStart = density
                    }
            )
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
    let height: CGFloat
    let isConfirming: Bool

    @State private var isHovering = false

    private var isCompact: Bool { height < 32 }

    var body: some View {
        HStack(spacing: 10) {
            thumbnail

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !isCompact {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }
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
            }
        }
        .padding(.horizontal, 8)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? Color(nsColor: .secondarySystemFill) : .clear)
        )
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var thumbnail: some View {
        let side = min(height - 8, 26)
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
