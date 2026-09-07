//
//  PanGesture.swift
//  boringNotch
//
//  Created by Richard Kunkli on 21/08/2024.
//

import AppKit
import SwiftUI

enum PanDirection {
    case left, right, up, down

    var isHorizontal: Bool { self == .left || self == .right }
    var sign: CGFloat { (self == .right || self == .down) ? 1 : -1 }

    func signed(from translation: CGSize) -> CGFloat { (isHorizontal ? translation.width : translation.height) * sign }
    func signed(deltaX: CGFloat, deltaY: CGFloat) -> CGFloat { (isHorizontal ? deltaX : deltaY) * sign }
}

extension View {
    /// - Parameter usesDragGesture: Adds a mouse-drag recognizer alongside the
    ///   scroll monitor. Turn it off where the same area already owns a drag of
    ///   its own — a `DragGesture(minimumDistance: 0)` on a parent will
    ///   otherwise compete with it.
    func panGesture(
        direction: PanDirection,
        threshold: CGFloat = 4,
        usesDragGesture: Bool = true,
        action: @escaping (CGFloat, NSEvent.Phase) -> Void
    ) -> some View {
        self
            .conditionalModifier(usesDragGesture) { view in
                view.gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let s = direction.signed(from: value.translation)
                            guard s > 0, s.magnitude >= threshold else { return }
                            action(s.magnitude, .changed)
                        }
                        .onEnded { _ in action(0, .ended) }
                )
            }
            .background(ScrollMonitor(direction: direction, threshold: threshold, action: action))
    }
}

/// Grants one scroll gesture to a single direction at a time.
///
/// Monitors are installed per direction and cannot see each other, so a
/// diagonal two-finger swipe can pass the horizontal dominance test on one
/// event and the vertical one on the next — switching tabs and opening or
/// closing the notch from a single swipe. Whichever direction crosses its
/// threshold first owns the gesture until it ends.
@MainActor
private final class ScrollGestureArbiter {
    static let shared = ScrollGestureArbiter()

    private var owner: ObjectIdentifier?

    func claim(_ claimant: AnyObject) -> Bool {
        let id = ObjectIdentifier(claimant)
        guard let owner else {
            self.owner = id
            return true
        }
        return owner == id
    }

    func release(_ claimant: AnyObject) {
        if owner == ObjectIdentifier(claimant) {
            owner = nil
        }
    }
}

private struct ScrollMonitor: NSViewRepresentable {
    let direction: PanDirection
    let threshold: CGFloat
    let action: (CGFloat, NSEvent.Phase) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.installMonitor(on: view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.removeMonitor() }

    func makeCoordinator() -> Coordinator { 
        Coordinator(direction: direction, threshold: threshold, action: action) 
    }

    @MainActor final class Coordinator: NSObject {
        private let direction: PanDirection
        private let threshold: CGFloat
        private let action: (CGFloat, NSEvent.Phase) -> Void
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var active = false
            private var endTask: Task<Void, Never>?
        private let noiseThreshold: CGFloat = 0.2

        init(direction: PanDirection, threshold: CGFloat, action: @escaping (CGFloat, NSEvent.Phase) -> Void) {
            self.direction = direction
            self.threshold = threshold
            self.action = action
        }

        private func scheduleEndTimeout() {
            // Cancel any existing scheduled end and schedule a new one.
            endTask?.cancel()
            endTask = Task { @MainActor in
                // If no new scroll event arrives within this window, consider the gesture ended.
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                if active {
                    action(accumulated.magnitude, .ended)
                } else {
                    action(0, .ended)
                }
                active = false
                accumulated = 0
                ScrollGestureArbiter.shared.release(self)
            }
        }

        func installMonitor(on view: NSView) {
            removeMonitor()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self, weak view] event in
                guard let self = self, event.window === view?.window else { return event }
                self.handleScroll(event)
                return event
            }
        }

        func removeMonitor() {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            accumulated = 0
            active = false
            endTask?.cancel()
            endTask = nil
            ScrollGestureArbiter.shared.release(self)
        }

        private func handleScroll(_ event: NSEvent) {
            if event.phase == .ended || event.momentumPhase == .ended {
                if active {
                    action(accumulated.magnitude, .ended)
                } else {
                    action(0, .ended)
                }
                active = false
                accumulated = 0
                ScrollGestureArbiter.shared.release(self)
                return
            }

            // Only consider scroll events that are primarily along the configured axis.
            let absDX = abs(event.scrollingDeltaX)
            let absDY = abs(event.scrollingDeltaY)
            // Require the movement along the gesture axis to be at least 1.5x the orthogonal axis.
            let axisDominanceFactor: CGFloat = 1.5
            let isAxisDominant: Bool = direction.isHorizontal ? (absDX >= axisDominanceFactor * absDY) : (absDY >= axisDominanceFactor * absDX)
            guard isAxisDominant else { return }

            // Scale non-precise (mouse wheel) scrolling deltas so they feel similar to
            // trackpad gestures.
            let raw = direction.signed(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            let s = raw * scale
            guard s.magnitude > noiseThreshold else { return }
            accumulated = s > 0 ? accumulated + s : 0

            if !active && accumulated >= threshold {
                // Another direction already owns this swipe.
                guard ScrollGestureArbiter.shared.claim(self) else {
                    accumulated = 0
                    return
                }
                active = true
                action(accumulated.magnitude, .began)
            } else if active {
                action(accumulated.magnitude, .changed)
            }
            // Schedule a timeout to end the gesture if no further scroll events arrive.
            scheduleEndTimeout()
        }
    }
}
