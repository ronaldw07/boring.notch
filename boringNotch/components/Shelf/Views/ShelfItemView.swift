//
//  ShelfItemView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import SwiftUI
import Defaults

import QuickLook

/// The hover treatment and the corner the remove button lives in. Shared
/// with `DraggableClickView` below, which has to punch a hit-testing hole
/// of exactly this size for the button to be clickable at all.
enum ShelfItemHover {
    static let accent = Color(red: 0.45, green: 0.75, blue: 1.0)
    /// Square corner the remove button occupies, button plus its inset.
    static let removeButtonHitSide: CGFloat = 26
}

struct ShelfItemView: View {
    let item: ShelfItem
    /// Horizontal scroll deltas from the trackpad or wheel, forwarded up to
    /// the shelf. The row owns its own offset now, so the card the cursor is
    /// over is the only thing positioned to see these.
    var onScroll: ((CGFloat) -> Void)?
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var selection = ShelfSelectionModel.shared
    @StateObject private var viewModel: ShelfItemViewModel
    @EnvironmentObject private var quickLookService: QuickLookService
    @State private var showStack = false
    @State private var cachedPreviewImage: NSImage?
    @State private var debouncedDropTarget = false
    @State private var isHovering = false
    @State private var isHoveringRemove = false

    private var isSelected: Bool { viewModel.isSelected }
    private var shouldHideDuringDrag: Bool { selection.isDragging && selection.isSelected(item.id) && false }
    
    init(item: ShelfItem, onScroll: ((CGFloat) -> Void)? = nil) {
        self.item = item
        self.onScroll = onScroll
        _viewModel = StateObject(wrappedValue: ShelfItemViewModel(item: item))
    }

    var body: some View {
        ZStack {
            if !shouldHideDuringDrag {
                VStack(alignment: .center, spacing: 2) {
                    iconView
                    textView
                }
                .frame(width: 105)
                .padding(.vertical, 10)
                .padding(.horizontal, 5)
                .background(backgroundView)
                .overlay(alignment: .topTrailing) {
                    if isHovering {
                        removeButton
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if item.isPinned {
                        pinBadge
                    }
                }
                // An overlay rather than the ZStack sibling this used to be,
                // so the AppKit view is exactly the card's size. As a sibling
                // it took the full height proposed to the row — a good 20pt
                // taller than the card, with the card centred inside it — and
                // since the remove button's rect is measured from this view's
                // own top-right corner, that corner sat above the circle and
                // only clipped its upper edge.
                .overlay(dragHandler)
                .contentShape(Rectangle())
                .animation(.easeInOut(duration: 0.1), value: debouncedDropTarget)
                .animation(.easeInOut(duration: 0.1), value: isSelected)
                .animation(.easeInOut(duration: 0.12), value: isHovering)
            } else {
                Color.clear
                    .frame(width: 105)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 5)
            }
        }
        // On the ZStack rather than the card: an NSTrackingArea fires on
        // geometry and isn't suppressed by the AppKit drag handler sitting
        // on top of it, so this still reports correctly even though that
        // view wins every actual mouse event.
        .onHover { hovering in
            isHovering = hovering
            // The button is removed on the way out, so it never gets its own
            // exit — without this it comes back still red next time.
            if !hovering { isHoveringRemove = false }
        }
        .onChange(of: viewModel.isDropTargeted) { _, targeted in
            vm.dragDetectorTargeting = targeted
            // Debounce drop target state changes
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                debouncedDropTarget = targeted
            }
        }
        .onAppear {
            Task { 
                await viewModel.loadThumbnail()
                // Pre-render drag preview once on appear
                if cachedPreviewImage == nil {
                    cachedPreviewImage = await renderDragPreview()
                }
            }
            viewModel.onQuickLookRequest = { urls in
                quickLookService.show(urls: urls, selectFirst: true)
            }
        }
        .onChange(of: viewModel.thumbnail) { _, _ in
            // Invalidate cached preview when thumbnail changes
            Task {
                cachedPreviewImage = await renderDragPreview()
            }
        }
        .quickLookPresenter(using: quickLookService)
    }

    // MARK: - View Components

    private var dragHandler: some View {
        DraggableClickHandler(
            item: item,
            viewModel: viewModel,
            showsRemoveButton: isHovering,
            onRemove: { ShelfStateViewModel.shared.remove(item) },
            onScroll: onScroll,
            onRemoveHoverChange: { isHoveringRemove = $0 },
            cachedPreviewImage: $cachedPreviewImage,
            dragPreviewContent: {
                DragPreviewView(thumbnail: viewModel.thumbnail ?? item.icon, displayName: item.displayName)
            },
            onRightClick: viewModel.handleRightClick,
            onClick: { event, nsview in
                viewModel.handleClick(event: event, view: nsview)
            }
        )
    }

    private var iconView: some View {
        Image(nsImage: viewModel.thumbnail ?? item.icon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
    }

    private var textView: some View {
        Text(item.displayName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .truncationMode(.middle)
            .multilineTextAlignment(.center)
            .frame(height: 30, alignment: .top)
    }

    /// Drawing only. Both the click *and* the hover come from
    /// `DraggableClickView`, which covers this — SwiftUI's hit-testing stops
    /// at that view for hover exactly as it does for clicks, so an `.onHover`
    /// here would never fire. (The card's own hover still works because the
    /// ZStack is an *ancestor* of that view rather than a sibling under it.)
    private var removeButton: some View {
        Image(systemName: "xmark")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(
                Circle()
                    .fill(isHoveringRemove ? Color.red : Color.black.opacity(0.55))
                    .overlay(
                        Circle().strokeBorder(
                            isHoveringRemove ? .white.opacity(0.5) : .white.opacity(0.25),
                            lineWidth: 0.5
                        )
                    )
            )
            .animation(.easeOut(duration: 0.12), value: isHoveringRemove)
            .padding(4)
    }

    /// Always visible rather than hover-gated like removeButton — this is
    /// telling you what the item *is* (pinned, so a drag-out won't remove
    /// it), not offering an action you have to be hovering to reach.
    private var pinBadge: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(
                Circle()
                    .fill(Color.black.opacity(0.55))
                    .overlay(
                        Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                    )
            )
            .padding(4)
            // Drawn under DraggableClickView like the rest of this ZStack —
            // see its comment on removeButton — so it never intercepts a hit.
            .allowsHitTesting(false)
    }

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(backgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        strokeColor,
                        lineWidth: strokeWidth
                    )
            )
    }

    // Hover sits below drop-target and selection: both of those say
    // something about what the item *is* right now, while hover only says
    // where the cursor happens to be, and it shouldn't paint over them.

    private var backgroundColor: Color {
        if debouncedDropTarget {
            return Color.accentColor.opacity(0.25)
        } else if isSelected {
            return Color.accentColor.opacity(0.15)
        } else if isHovering {
            return ShelfItemHover.accent.opacity(0.12)
        } else {
            return Color.clear
        }
    }

    private var strokeColor: Color {
        if debouncedDropTarget {
            return Color.accentColor.opacity(0.9)
        } else if isSelected {
            return Color.accentColor.opacity(0.8)
        } else if isHovering {
            return ShelfItemHover.accent.opacity(0.85)
        } else {
            return Color.clear
        }
    }

    private var strokeWidth: CGFloat {
        if debouncedDropTarget {
            return 3
        } else if isSelected {
            return 2
        } else if isHovering {
            return 1.5
        } else {
            return 1
        }
    }
    
    // MARK: - Drag Preview Rendering
    
    @MainActor
    private func renderDragPreview() async -> NSImage {
        let content = DragPreviewView(thumbnail: viewModel.thumbnail ?? item.icon, displayName: item.displayName)
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return renderer.nsImage ?? (viewModel.thumbnail ?? item.icon)
    }


}

// MARK: - Stack Tile

/// Stands in for 2+ items dropped together in one go — see
/// ShelfView.displayTiles — so the row gets one tile instead of one per
/// file. The same view also marks an expanded group in place of the
/// collapsed tile it replaced, just re-styled by `isExpanded`, so there's
/// always exactly one thing on screen to click to flip it back.
struct ShelfStackTileView: View {
    let items: [ShelfItem]
    let isExpanded: Bool
    var onScroll: ((CGFloat) -> Void)?
    let onToggle: () -> Void

    @State private var cachedPreviewImage: NSImage?

    var body: some View {
        ZStack {
            if !isExpanded {
                ghostCards
            }
            VStack(alignment: .center, spacing: 2) {
                Image(nsImage: items[0].icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
                Text(isExpanded ? "Collapse" : "\(items.count) items")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(height: 30, alignment: .top)
            }
            .frame(width: 105)
            .padding(.vertical, 10)
            .padding(.horizontal, 5)
            .background(cardBackground)
        }
        .frame(width: 105)
        .padding(.horizontal, 5)
        .overlay(alignment: .topTrailing) { badge }
        .contentShape(Rectangle())
        // Drawing only, same split as ShelfItemView: the actual click and
        // the multi-item drag both come from this AppKit overlay.
        .overlay(clickHandler)
    }

    private var ghostCards: some View {
        ZStack {
            cardBackground
                .rotationEffect(.degrees(-7))
                .offset(x: -7, y: 3)
                .opacity(0.55)
            cardBackground
                .rotationEffect(.degrees(5))
                .offset(x: 6, y: 2)
                .opacity(0.75)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            )
            .frame(width: 105, height: 98)
    }

    private var badge: some View {
        Group {
            if isExpanded {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            } else {
                Text("\(items.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Circle().fill(Color.accentColor))
            }
        }
        .padding(4)
        .allowsHitTesting(false)
    }

    private var clickHandler: some View {
        DraggableClickHandler(
            item: items[0],
            viewModel: nil,
            showsRemoveButton: false,
            onRemove: {},
            onScroll: onScroll,
            onRemoveHoverChange: { _ in },
            cachedPreviewImage: $cachedPreviewImage,
            dragPreviewContent: {
                DragPreviewView(thumbnail: items[0].icon, displayName: "\(items.count) items")
            },
            onRightClick: { _, _ in },
            onClick: { _, _ in onToggle() },
            groupItems: items
        )
    }
}

// MARK: - Draggable Click Handler with NSDraggingSource
private struct DraggableClickHandler<Content: View>: NSViewRepresentable {
    let item: ShelfItem
    let viewModel: ShelfItemViewModel?
    let showsRemoveButton: Bool
    let onRemove: () -> Void
    let onScroll: ((CGFloat) -> Void)?
    let onRemoveHoverChange: (Bool) -> Void
    @Binding var cachedPreviewImage: NSImage?
    @ViewBuilder let dragPreviewContent: () -> Content
    let onRightClick: (NSEvent, NSView) -> Void
    let onClick: (NSEvent, NSView) -> Void
    /// Non-nil only for a collapsed stack tile, where a drag has to carry
    /// every item the stack represents rather than just `item` — see
    /// startDragSession, which prefers this over the normal single-item/
    /// selection logic when it's set.
    var groupItems: [ShelfItem]? = nil

    func makeNSView(context: Context) -> DraggableClickView {
        let view = DraggableClickView()
        view.item = item
        view.viewModel = viewModel
        view.groupItems = groupItems
        view.showsRemoveButton = showsRemoveButton
        view.onRemove = onRemove
        view.onScroll = onScroll
        view.onRemoveHoverChange = onRemoveHoverChange
        view.dragPreviewImage = cachedPreviewImage ?? renderDragPreview()
        view.onRightClick = onRightClick
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: DraggableClickView, context: Context) {
        nsView.item = item
        nsView.viewModel = viewModel
        nsView.groupItems = groupItems
        nsView.showsRemoveButton = showsRemoveButton
        nsView.onRemove = onRemove
        nsView.onScroll = onScroll
        nsView.onRemoveHoverChange = onRemoveHoverChange
        // Only update preview if cached version is available
        if let cached = cachedPreviewImage {
            nsView.dragPreviewImage = cached
        }
        nsView.onRightClick = onRightClick
        nsView.onClick = onClick
    }

    private func renderDragPreview() -> NSImage {
        let content = dragPreviewContent()
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0

        if let nsImage = renderer.nsImage {
            return nsImage
        }

        // Fallback to icon if rendering fails
        return viewModel?.thumbnail ?? item.icon
    }
    
    final class DraggableClickView: NSView, NSDraggingSource {
        var item: ShelfItem!
        weak var viewModel: ShelfItemViewModel?
        /// See DraggableClickHandler.groupItems.
        var groupItems: [ShelfItem]?
        var dragPreviewImage: NSImage?
        var showsRemoveButton = false
        var onRemove: (() -> Void)?
        var onScroll: ((CGFloat) -> Void)?
        var onRemoveHoverChange: ((Bool) -> Void)?
        var onRightClick: ((NSEvent, NSView) -> Void)?
        var onClick: ((NSEvent, NSView) -> Void)?

        private var isOverRemoveButton = false
        private var mouseDownEvent: NSEvent?
        private let dragThreshold: CGFloat = 3.0
        private var draggedURLs: [URL] = []
        private var draggedItems: [ShelfItem] = []

        /// The remove button is SwiftUI, drawn *underneath* this view. An
        /// NSView wins hit-testing against SwiftUI content no matter where
        /// it sits in the ZStack, so reordering wouldn't help — the only way
        /// the button can be clicked is for this view to decline the hit and
        /// let it fall through. Only while the button is actually showing,
        /// so the corner stays draggable the rest of the time.
        /// Corner the remove button is drawn in, in this view's own
        /// coordinates. `isFlipped` is false on a plain NSView, so the
        /// button's top edge is `maxY` — but read it from the flag rather
        /// than assuming, since being wrong here is silent.
        private var removeButtonRect: NSRect {
            let side = ShelfItemHover.removeButtonHitSide
            return NSRect(
                x: bounds.maxX - side,
                y: isFlipped ? bounds.minY : bounds.maxY - side,
                width: side,
                height: side
            )
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?(event, self)
        }

        /// Only claims clearly-horizontal scrolls; a vertical one still
        /// belongs to the notch's own open/close gesture, so it goes back up
        /// the responder chain untouched.
        override func scrollWheel(with event: NSEvent) {
            guard let onScroll, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
                super.scrollWheel(with: event)
                return
            }

            // Wheels report in coarse notches rather than points, so they'd
            // barely register against a trackpad's precise deltas otherwise.
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            onScroll(event.scrollingDeltaX * scale)
        }
        
        // MARK: - Remove-button hover

        /// `.activeAlways` because the notch is a non-activating panel — the
        /// app is almost never frontmost while someone is using it, and the
        /// default modes would go quiet exactly then.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero,
                    options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                    owner: self
                )
            )
        }

        override func mouseEntered(with event: NSEvent) {
            updateRemoveHover(with: event)
        }

        override func mouseMoved(with event: NSEvent) {
            updateRemoveHover(with: event)
        }

        override func mouseExited(with event: NSEvent) {
            setRemoveHover(false)
        }

        private func updateRemoveHover(with event: NSEvent) {
            guard showsRemoveButton else {
                setRemoveHover(false)
                return
            }
            setRemoveHover(removeButtonRect.contains(convert(event.locationInWindow, from: nil)))
        }

        private func setRemoveHover(_ hovering: Bool) {
            guard hovering != isOverRemoveButton else { return }
            isOverRemoveButton = hovering
            onRemoveHoverChange?(hovering)
        }

        override func mouseDown(with event: NSEvent) {
            // The remove button is drawn by SwiftUI underneath this view, so
            // it can never receive this event itself — take the click here
            // and act on it directly. Guarded on the button actually being
            // visible, so the corner stays draggable otherwise.
            if showsRemoveButton {
                let local = convert(event.locationInWindow, from: nil)
                if removeButtonRect.contains(local) {
                    mouseDownEvent = nil
                    onRemove?()
                    return
                }
            }

            mouseDownEvent = event
            onClick?(event, self)
        }
        
        override func mouseDragged(with event: NSEvent) {
            guard let mouseDownEvent = mouseDownEvent else {
                super.mouseDragged(with: event)
                return
            }
            
            let dragDistance = hypot(
                event.locationInWindow.x - mouseDownEvent.locationInWindow.x,
                event.locationInWindow.y - mouseDownEvent.locationInWindow.y
            )
            
            if dragDistance > dragThreshold {
                startDragSession(with: event)
                self.mouseDownEvent = nil
            } else {
                super.mouseDragged(with: event)
            }
        }
        
        private func startDragSession(with event: NSEvent) {
            // Prepare dragging items
            let itemsToDrag: [ShelfItem]

            if let groupItems, groupItems.count > 1 {
                // A collapsed stack drags everything it represents,
                // regardless of what's separately selected elsewhere on the
                // shelf.
                itemsToDrag = groupItems
            } else {
                let selectedItems = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
                if selectedItems.count > 1 && selectedItems.contains(where: { $0.id == item.id }) {
                    itemsToDrag = selectedItems
                } else {
                    itemsToDrag = [item]
                }
            }

            // Store items being dragged for auto-remove feature
            draggedItems = itemsToDrag

            // Create dragging items for AppKit
            var draggingItems: [NSDraggingItem] = []

            for dragItem in itemsToDrag {
                if let pasteboardItem = createPasteboardItem(for: dragItem) {
                    let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)

                    // Use the drag preview image
                    let image = dragPreviewImage ?? dragItem.icon
                    let imageFrame = NSRect(
                        x: 0,
                        y: 0,
                        width: image.size.width,
                        height: image.size.height
                    )
                    draggingItem.setDraggingFrame(imageFrame, contents: image)

                    draggingItems.append(draggingItem)
                }
            }

            guard !draggingItems.isEmpty else { return }

            beginDraggingSession(with: draggingItems, event: event, source: self)
        }
        
        private func createPasteboardItem(for item: ShelfItem) -> NSPasteboardItem? {
            let pasteboardItem = NSPasteboardItem()

            switch item.kind {
            case .file:
                guard let url = ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: item) else {
                    pasteboardItem.setString(item.displayName, forType: .string)
                    return pasteboardItem
                }
                
                // Start accessing security-scoped resource and keep it active during drag
                if url.startAccessingSecurityScopedResource() {
                    draggedURLs.append(url)
                    NSLog("🔐 Started security-scoped access for drag: \(url.path)")
                }
                
                pasteboardItem.setString(url.absoluteString, forType: .fileURL)
                pasteboardItem.setString(url.path, forType: .string)
                return pasteboardItem

            case .text(let string):
                pasteboardItem.setString(string, forType: .string)
                return pasteboardItem

            case .link(let url):
                pasteboardItem.setString(url.absoluteString, forType: .URL)
                pasteboardItem.setString(url.absoluteString, forType: .string)
                return pasteboardItem
            }
        }
        
        // MARK: - NSDraggingSource
        
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            // When copyOnDrag is enabled, only allow copy operations
            if Defaults[.copyOnDrag] {
                return [.copy]
            }
            
            switch context {
            case .outsideApplication:
                return [.copy, .move]
            case .withinApplication:
                return [.copy, .move, .generic]
            @unknown default:
                return [.copy]
            }
        }
        
        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            ShelfSelectionModel.shared.beginDrag()
        }
        
        
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            ShelfSelectionModel.shared.endDrag()

            // Stop accessing security-scoped resources after drag completes
            for url in draggedURLs {
                url.stopAccessingSecurityScopedResource()
                NSLog("🔐 Stopped security-scoped access after drag: \(url.path)")
            }
            draggedURLs.removeAll()

            // Auto-remove items from shelf if enabled and drag succeeded.
            // Pinned items are exempt — pinning something is a promise it
            // survives a drag-out, so it can't also be the thing auto-remove
            // deletes the moment that drag succeeds.
            if Defaults[.autoRemoveShelfItems] && !operation.isEmpty {
                for item in draggedItems where !item.isPinned {
                    ShelfStateViewModel.shared.remove(item)
                }
            }
            draggedItems.removeAll()
        }
        
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
            return false
        }
    }
}
