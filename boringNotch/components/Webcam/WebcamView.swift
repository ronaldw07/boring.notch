//
//  WebcamView.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 19/08/24.
//

import AVFoundation
import Defaults
import SwiftUI

private let minimumZoom: CGFloat = 0.5
private let maximumZoom: CGFloat = 4
/// Horizontal travel, in points, that covers the whole zoom range.
private let zoomDragTravel: CGFloat = 150
/// Resistance applied to drag past either end of the range, so the gesture
/// slows to a stop instead of hitting an invisible wall.
private let zoomOvershootResistance: CGFloat = 0.2
private let zoomIndicatorLinger: Duration = .milliseconds(900)

struct CameraPreviewView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager: WebcamManager

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var zoom: CGFloat = 1
    @State private var zoomAtDragStart: CGFloat = 1
    @State private var isShowingZoomIndicator: Bool = false
    @State private var isHoveringPreview: Bool = false
    @State private var isDraggingZoom: Bool = false
    @State private var zoomIndicatorTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let previewLayer = webcamManager.previewLayer {
                    CameraPreviewLayerView(previewLayer: previewLayer)
                        .scaleEffect(x: -zoom, y: zoom)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .opacity(webcamManager.isSessionRunning ? 1 : 0)
                }

                if !webcamManager.isSessionRunning {
                    ZStack {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(Color(red: 20/255, green: 20/255, blue: 20/255))
                            .strokeBorder(.white.opacity(0.04), lineWidth: 1)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                        VStack(spacing: 8) {
                            Image(systemName: webcamManager.authorizationStatus == .denied ? "exclamationmark.triangle" : "web.camera")
                                .foregroundStyle(.gray)
                                .font(.system(size: min(geometry.size.width, geometry.size.height) / 3.5))
                            Text(webcamManager.authorizationStatus == .denied ? "Access Denied" : "Mirror")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                }
                if webcamManager.isSessionRunning {
                    ZoomIndicator(zoom: zoom, minimumZoom: minimumUsableZoom)
                        .padding(.bottom, geometry.size.height * 0.08)
                        .frame(width: geometry.size.width, height: geometry.size.height,
                               alignment: .bottom)
                        .opacity(isShowingZoomIndicator ? 1 : 0)
                        .scaleEffect(isShowingZoomIndicator || reduceMotion ? 1 : 0.95)
                        .allowsHitTesting(false)
                }
            }
            .onTapGesture {
                handleCameraTap()
            }
            // Only attached once there is a picture to zoom, so it can never
            // swallow the click that turns the mirror on.
            .simultaneousGesture(zoomDrag, isEnabled: webcamManager.isSessionRunning)
            .onHover { isHovering in
                isHoveringPreview = isHovering
                guard webcamManager.isSessionRunning else { return }
                // Surfaced on hover so the drag affordance is discoverable.
                if isHovering {
                    revealZoomIndicator()
                } else if !isDraggingZoom {
                    scheduleZoomIndicatorHide()
                }
            }
            .onChange(of: minimumUsableZoom) { _, floor in
                // A camera with a different aspect ratio can raise the floor.
                if zoom < floor {
                    zoom = floor
                    zoomAtDragStart = floor
                }
            }
            .onDisappear {
                zoomIndicatorTask?.cancel()
                webcamManager.stopSession()
            }
        }
        .aspectRatio(mirrorAspectRatio, contentMode: .fit)
    }

    /// Rectangular mirrors are sized to the camera's own aspect ratio, the
    /// same way Photo Booth shows its preview undistorted and uncropped.
    /// Circular mirrors stay square, since a circle needs one.
    private var mirrorAspectRatio: CGFloat {
        Defaults[.mirrorShape] == .rectangle ? webcamManager.videoAspectRatio : 1
    }

    private var cornerRadius: CGFloat {
        Defaults[.mirrorShape] == .rectangle
            ? (!Defaults[.cornerRadiusScaling] ? MusicPlayerImageSizes.cornerRadiusInset.closed : MusicPlayerImageSizes.cornerRadiusInset.opened)
            : 100
    }

    /// The rectangular mirror's frame already matches the camera's aspect
    /// ratio, so at zoom 1 the picture fills it with no crop and zooming out
    /// just letterboxes symmetrically — no floor needed beyond the global
    /// minimum. The circular mirror stays square while the camera usually
    /// isn't, so its fill crops one axis at zoom 1; zooming out from there
    /// is capped at the point where that axis reaches its own edge, past
    /// which the picture would no longer reach two sides of the circle.
    private var minimumUsableZoom: CGFloat {
        guard Defaults[.mirrorShape] != .rectangle else { return minimumZoom }
        let aspect = webcamManager.videoAspectRatio
        guard aspect > 0 else { return 1 }
        let longOverShort = max(aspect, 1 / aspect)
        return max(minimumZoom, 1 / longOverShort)
    }

    /// Zoom tracks the pointer one-to-one while dragging, so it is deliberately
    /// not animated. Only the settle back into range is.
    private var zoomDrag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard webcamManager.isSessionRunning else { return }

                isDraggingZoom = true
                let range = maximumZoom - minimumUsableZoom
                // Inverted: dragging left pulls the ruler's marker to the
                // right (zooms in), like pinching the image toward you.
                zoom = resisted(zoomAtDragStart - value.translation.width / zoomDragTravel * range)
                revealZoomIndicator()
            }
            .onEnded { _ in
                isDraggingZoom = false
                guard webcamManager.isSessionRunning else { return }

                zoomAtDragStart = min(max(zoom, minimumUsableZoom), maximumZoom)
                if zoom != zoomAtDragStart {
                    withAnimation(.spring(duration: 0.3, bounce: 0.12)) {
                        zoom = zoomAtDragStart
                    }
                }
                // Stays up while the pointer is still over the preview.
                if !isHoveringPreview {
                    scheduleZoomIndicatorHide()
                }
            }
    }

    private func resisted(_ value: CGFloat) -> CGFloat {
        let floor = minimumUsableZoom
        if value > maximumZoom {
            return maximumZoom + (value - maximumZoom) * zoomOvershootResistance
        }
        if value < floor {
            return floor - (floor - value) * zoomOvershootResistance
        }
        return value
    }

    private func revealZoomIndicator() {
        zoomIndicatorTask?.cancel()
        zoomIndicatorTask = nil
        guard !isShowingZoomIndicator else { return }
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)) {
            isShowingZoomIndicator = true
        }
    }

    private func scheduleZoomIndicatorHide() {
        zoomIndicatorTask?.cancel()
        zoomIndicatorTask = Task { @MainActor in
            try? await Task.sleep(for: zoomIndicatorLinger)
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)) {
                isShowingZoomIndicator = false
            }
        }
    }


    private func handleCameraTap() {
        webcamManager.toggleSession {
            let alert = NSAlert()
            alert.messageText = "Camera Access Required"
            alert.informativeText = "Please allow camera access in System Settings to use the mirror feature."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() == .alertFirstButtonReturn {
                if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(settingsURL)
                }
            }
        }
    }
}

/// Zoom factor pill over a tick ruler, echoing the Continuity Camera control.
/// The ruler slides under a fixed centre marker as the zoom changes.
private struct ZoomIndicator: View {
    let zoom: CGFloat
    let minimumZoom: CGFloat

    private static let tickCount = 41
    private static let tickSpacing: CGFloat = 5
    private static let rulerHeight: CGFloat = 10

    private static var contentWidth: CGFloat {
        CGFloat(tickCount - 1) * tickSpacing
    }

    private var progress: CGFloat {
        let range = maximumZoom - minimumZoom
        guard range > 0 else { return 0 }
        return min(max((zoom - minimumZoom) / range, 0), 1)
    }

    private var label: String {
        let rounded = (zoom * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? "\(Int(rounded))×"
            : String(format: "%.1f×", rounded)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.yellow)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())

            ZStack {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ForEach(0 ..< Self.tickCount, id: \.self) { index in
                            let isMajor = index % 4 == 0
                            Capsule()
                                .fill(.white.opacity(isMajor ? 0.9 : 0.45))
                                .frame(width: 1, height: isMajor ? 8 : 5)
                                .frame(width: Self.tickSpacing, height: Self.rulerHeight)
                        }
                    }
                    .offset(x: geometry.size.width / 2
                        - progress * Self.contentWidth
                        - Self.tickSpacing / 2)
                }
                .frame(height: Self.rulerHeight)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white, location: 0.28),
                            .init(color: .white, location: 0.72),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

                Capsule()
                    .fill(.yellow)
                    .frame(width: 1.5, height: Self.rulerHeight)
            }
            .frame(height: Self.rulerHeight)
        }
        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
    }
}

struct CameraPreviewLayerView: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer = previewLayer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = nsView.bounds
        CATransaction.commit()
    }
}

#Preview {
    CameraPreviewView(webcamManager: .shared)
}
