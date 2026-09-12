//
//  BoringViewModel.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Combine
import Defaults
import SwiftUI

class BoringViewModel: NSObject, ObservableObject {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var detector = FullscreenMediaDetector.shared

    let animationLibrary: BoringAnimations = .init()
    let animation: Animation?

    @Published var contentType: ContentType = .normal
    @Published private(set) var notchState: NotchState = .closed

    @Published var dragDetectorTargeting: Bool = false
    @Published var generalDropTargeting: Bool = false
    @Published var dropZoneTargeting: Bool = false
    @Published var dropEvent: Bool = false
    @Published var anyDropZoneTargeting: Bool = false
    var cancellables: Set<AnyCancellable> = []
    
    @Published var hideOnClosed: Bool = true

    @Published var edgeAutoOpenActive: Bool = false
    @Published var isHoveringCalendar: Bool = false
    /// Set while the cursor is over the shelf's row of items. Horizontal
    /// scrolling there belongs to the row, not to the notch's swipe-between-
    /// tabs gesture, which would otherwise fire on the same event and change
    /// tab out from under the scroll.
    @Published var isHoveringShelfRow: Bool = false
    @Published var isBatteryPopoverActive: Bool = false

    @Published var screenUUID: String?

    @Published var notchSize: CGSize = getClosedNotchSize()
    @Published var closedNotchSize: CGSize = getClosedNotchSize()

    /// Extra height a tab's content needs beyond the normal open size — e.g.
    /// the clipboard's expanded list. This is the animated one: the notch's
    /// black panel interpolates over it, so growth reads as extending
    /// downward.
    @Published var extraContentHeight: CGFloat = 0

    /// Extra height the *window* needs, kept separate from the content's so
    /// the two can be sequenced. The window is the content's clip bounds, so
    /// it has to be big before the panel grows into it and must stay big
    /// until the panel has finished shrinking — otherwise the bottom of the
    /// panel is cut off for the length of the collapse animation. AppDelegate
    /// observes this and resizes, pinning the top edge to the screen.
    @Published var windowExtraHeight: CGFloat = 0
    
    let webcamManager = WebcamManager.shared
    @Published var isCameraExpanded: Bool = false
    @Published var isRequestingAuthorization: Bool = false
    
    deinit {
        destroy()
    }

    func destroy() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    init(screenUUID: String? = nil) {
        animation = animationLibrary.animation

        super.init()
        
        self.screenUUID = screenUUID
        notchSize = getClosedNotchSize(screenUUID: screenUUID)
        closedNotchSize = notchSize

        Publishers.CombineLatest3($dropZoneTargeting, $dragDetectorTargeting, $generalDropTargeting)
            .map { shelf, drag, general in
                shelf || drag || general
            }
            .assign(to: \.anyDropZoneTargeting, on: self)
            .store(in: &cancellables)
        
        setupDetectorObserver()
    }
    
    private func setupDetectorObserver() {
        // Publisher for the user’s fullscreen detection setting
        let enabledPublisher = Defaults
            .publisher(.hideNotchOption)
            .map(\.newValue)
            .map { $0 != .never }
            .removeDuplicates()

        // Publisher for the current screen UUID (non-nil, distinct)
        let screenPublisher = $screenUUID
            .compactMap { $0 }
            .removeDuplicates()

        // Publisher for fullscreen status dictionary
        let fullscreenStatusPublisher = detector.$fullscreenStatus
            .removeDuplicates()

        // Combine all three: screen UUID, fullscreen status, and enabled setting
        Publishers.CombineLatest3(screenPublisher, fullscreenStatusPublisher, enabledPublisher)
            .map { screenUUID, fullscreenStatus, enabled in
                let isFullscreen = fullscreenStatus[screenUUID] ?? false
                return enabled && isFullscreen
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shouldHide in
                withAnimation(.smooth) {
                    self?.hideOnClosed = shouldHide
                }
            }
            .store(in: &cancellables)
    }

    // Computed property for effective notch height
    var effectiveClosedNotchHeight: CGFloat {
        let currentScreen = screenUUID.flatMap { NSScreen.screen(withUUID: $0) }
        let noNotchAndFullscreen = hideOnClosed && (currentScreen?.safeAreaInsets.top ?? 0 <= 0 || currentScreen == nil)
        return noNotchAndFullscreen ? 0 : closedNotchSize.height
    }

    var chinHeight: CGFloat {
        if !Defaults[.hideTitleBar] {
            return 0
        }

        guard let currentScreen = screenUUID.flatMap({ NSScreen.screen(withUUID: $0) }) else {
            return 0
        }

        if notchState == .open { return 0 }

        let menuBarHeight = currentScreen.frame.maxY - currentScreen.visibleFrame.maxY
        let currentHeight = effectiveClosedNotchHeight

        if currentHeight == 0 { return 0 }

        return max(0, menuBarHeight - currentHeight)
    }

    func toggleCameraPreview() {
        if isRequestingAuthorization {
            return
        }

        switch webcamManager.authorizationStatus {
        case .authorized:
            if webcamManager.isSessionRunning {
                webcamManager.stopSession()
                isCameraExpanded = false
            } else if webcamManager.cameraAvailable {
                webcamManager.startSession()
                isCameraExpanded = true
            }

        case .denied, .restricted:
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)

                let alert = NSAlert()
                alert.messageText = "Camera Access Required"
                alert.informativeText = "Please allow camera access in System Settings."
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Cancel")

                if alert.runModal() == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }

                NSApp.setActivationPolicy(.accessory)
                NSApp.deactivate()
            }

        case .notDetermined:
            isRequestingAuthorization = true
            webcamManager.checkAndRequestVideoAuthorization()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.isRequestingAuthorization = false
            }

        default:
            break
        }
    }
    
    func isMouseHovering(position: NSPoint = NSEvent.mouseLocation) -> Bool {
        let screenFrame = getScreenFrame(screenUUID)
        if let frame = screenFrame {
            // While open, a tab can grow the panel past the base notch size
            // (e.g. the clipboard's expanded list) — the real hoverable area
            // is that taller shape, not just notchSize's own height, or the
            // cursor reads as having "left" the instant a tab grows past it.
            //
            // The larger of the two extras, because they're deliberately out
            // of step mid-animation: extraContentHeight is the *target* and
            // drops to zero the moment a collapse starts, while the panel is
            // still visibly tall for the length of that collapse.
            // windowExtraHeight is what stays big until it's genuinely
            // finished, so the max of the pair is the shape actually on
            // screen — without it, a collapse reads as a mouse-exit from the
            // area it hasn't finished vacating and slams the whole notch shut
            // partway through.
            let extra = max(extraContentHeight, windowExtraHeight)
            let effectiveHeight = notchState == .open ? notchSize.height + extra : notchSize.height
            let baseY = frame.maxY - effectiveHeight
            let baseX = frame.midX - notchSize.width / 2

            return position.y >= baseY && position.x >= baseX && position.x <= baseX + notchSize.width
        }

        return false
    }

    func open() {
        withAnimation(animationLibrary.panelAnimation) {
            self.notchSize = openNotchSize
            self.notchState = .open
        }

        // Force music information update when notch is opened
        MusicManager.shared.forceUpdate()
    }

    /// Grows or shrinks the room a tab's content gets beyond the notch's own
    /// size — the clipboard's expanded list, the timer's taller countdown
    /// layout, or (via `close()`) collapsing either of those back to zero.
    /// Growing and shrinking aren't symmetric: the window is the content's
    /// clip bounds, so it has to be big *before* the content grows into it
    /// (grow window first, instantly — it's transparent, so that's
    /// invisible), but shrinking it before the content has finished
    /// animating down would chop the still-visible bottom off mid-animation
    /// (shrink content first, pull the window in only once that's done).
    @MainActor
    func setExtraContentHeight(_ shortfall: CGFloat) {
        guard shortfall != extraContentHeight else { return }

        if shortfall > extraContentHeight {
            windowExtraHeight = shortfall
            withAnimation(animationLibrary.collapseCurve) {
                extraContentHeight = shortfall
            }
        } else {
            withAnimation(animationLibrary.collapseCurve, completionCriteria: .removed) {
                extraContentHeight = shortfall
            } completion: { [weak self] in
                // `.removed` fires when the animation leaves the view for any
                // reason — including being *replaced*, not just finishing. So
                // an expand that interrupts a collapse still lets the
                // interrupted collapse's completion run, and it would yank
                // the window back down to the old target while the panel is
                // mid-way through growing into it — clipping the bottom off
                // for a frame or two. Only pull the window in if this is
                // still the height being animated toward.
                guard let self, self.extraContentHeight == shortfall else { return }
                self.windowExtraHeight = shortfall
            }
        }
    }

    func close() {
        // Do not close while a share picker or sharing service is active
        if SharingStateManager.shared.preventNotchClose {
            return
        }
        withAnimation(animationLibrary.panelAnimation) {
            self.notchSize = getClosedNotchSize(screenUUID: self.screenUUID)
            self.closedNotchSize = self.notchSize
            self.notchState = .closed
        }

        // Shrink any expanded tab content (e.g. the clipboard's expanded
        // list) in step with the notch's own close animation — see
        // setExtraContentHeight for why this can't just snap to zero.
        setExtraContentHeight(0)

        self.isBatteryPopoverActive = false
        self.coordinator.sneakPeek.show = false
        self.edgeAutoOpenActive = false

        // Set the current view to shelf if it contains files and the user enables openShelfByDefault
        // Otherwise, if the user has not enabled openLastShelfByDefault, set the view to home
    if !ShelfStateViewModel.shared.isEmpty && Defaults[.openShelfByDefault] {
            coordinator.currentView = .shelf
        } else if !coordinator.openLastTabByDefault {
            coordinator.currentView = .home
        }
    }

    func closeHello() {
        Task { @MainActor in
            withAnimation(animationLibrary.animation) {
                coordinator.helloAnimationRunning = false
                close()
            }
        }
    }
}
