//
//  WebcamView.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 19/08/24.
//

import AVFoundation
import Defaults
import SwiftUI

/// Zoom factors shown on the ruler. These are labels, not scale multipliers:
/// 0.5x names the widest view the camera can give, the same way iPhone's 0.5x
/// names a lens rather than half of anything. See `previewScale`.
private let minimumZoom: CGFloat = 0.5
private let maximumZoom: CGFloat = 3
/// What the widest label actually scales the preview layer by. The layer is
/// already aspect-filling its box at 1.0, so this cannot go below 1 — there is
/// no more picture out there, only black.
private let minimumPreviewScale: CGFloat = 1
private let maximumPreviewScale: CGFloat = 3
/// The mirror's on-screen box, fixed regardless of zoom, mirror shape, or the
/// connected camera's own aspect ratio — like Photo Booth's window, which
/// never resizes itself; only the picture inside it moves and crops.
/// Matches CalendarView's own frame so swapping between the two causes no
/// layout jump.
private let mirrorSlotSize = CGSize(width: 215, height: 130)
/// Horizontal travel, in points, that covers the whole zoom range.
private let zoomDragTravel: CGFloat = 150
private let zoomIndicatorLinger: Duration = .milliseconds(900)

struct CameraPreviewView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager: WebcamManager

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var zoom: CGFloat = minimumZoom
    @State private var zoomAtDragStart: CGFloat = minimumZoom
    @State private var isShowingZoomIndicator: Bool = false
    @State private var isHoveringPreview: Bool = false
    @State private var isDraggingZoom: Bool = false
    @State private var zoomIndicatorTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if let previewLayer = webcamManager.previewLayer {
                CameraPreviewLayerView(previewLayer: previewLayer, scale: previewScale)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .frame(width: contentSize.width, height: contentSize.height)
                    .opacity(webcamManager.isSessionRunning ? 1 : 0)
            }

            if !webcamManager.isSessionRunning {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color(red: 20/255, green: 20/255, blue: 20/255))
                        .strokeBorder(.white.opacity(0.04), lineWidth: 1)
                        .frame(width: contentSize.width, height: contentSize.height)
                    VStack(spacing: 8) {
                        Image(systemName: webcamManager.authorizationStatus == .denied ? "exclamationmark.triangle" : "web.camera")
                            .foregroundStyle(.gray)
                            .font(.system(size: min(contentSize.width, contentSize.height) / 3.5))
                        Text(webcamManager.authorizationStatus == .denied ? "Access Denied" : "Mirror")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }
            }
            if webcamManager.isSessionRunning {
                ZoomIndicator(zoom: zoom, minimumZoom: minimumZoom)
                    .padding(.bottom, contentSize.height * 0.08)
                    .frame(width: contentSize.width, height: contentSize.height, alignment: .bottom)
                    .opacity(isShowingZoomIndicator ? 1 : 0)
                    .scaleEffect(isShowingZoomIndicator || reduceMotion ? 1 : 0.95)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: mirrorSlotSize.width, height: mirrorSlotSize.height)
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
        .onDisappear {
            zoomIndicatorTask?.cancel()
            webcamManager.stopSession()
        }
    }

    /// The rectangular mirror fills the whole slot. The circular one is
    /// squared off to the slot's shorter side and centered, so it reads as
    /// an actual circle rather than a stretched oval.
    private var contentSize: CGSize {
        guard Defaults[.mirrorShape] == .circle else { return mirrorSlotSize }
        let side = min(mirrorSlotSize.width, mirrorSlotSize.height)
        return CGSize(width: side, height: side)
    }

    /// Turns the ruler's label into the factor the video layer is actually
    /// cropped by. macOS exposes no `videoZoomFactor` on a capture device, and
    /// an aspect-filling layer is already showing everything the camera has at
    /// 1.0, so the widest label maps to 1.0 rather than to itself.
    private var previewScale: CGFloat {
        let span = maximumZoom - minimumZoom
        guard span > 0 else { return minimumPreviewScale }
        let position = (zoom - minimumZoom) / span
        return minimumPreviewScale + position * (maximumPreviewScale - minimumPreviewScale)
    }

    private var cornerRadius: CGFloat {
        Defaults[.mirrorShape] == .rectangle
            ? (!Defaults[.cornerRadiusScaling] ? MusicPlayerImageSizes.cornerRadiusInset.closed : MusicPlayerImageSizes.cornerRadiusInset.opened)
            : 100
    }

    /// Zoom tracks the pointer one-to-one while dragging, so it is deliberately
    /// not animated. Only the settle back into range is.
    private var zoomDrag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard webcamManager.isSessionRunning else { return }

                isDraggingZoom = true
                let range = maximumZoom - minimumZoom
                // Inverted: dragging left pulls the ruler's marker to the
                // right (zooms in), like pinching the image toward you.
                // Hard clamped, so the ruler cannot travel past either end.
                zoom = min(max(zoomAtDragStart - value.translation.width / zoomDragTravel * range,
                               minimumZoom), maximumZoom)
                revealZoomIndicator()
            }
            .onEnded { _ in
                isDraggingZoom = false
                guard webcamManager.isSessionRunning else { return }

                zoomAtDragStart = zoom
                // Stays up while the pointer is still over the preview.
                if !isHoveringPreview {
                    scheduleZoomIndicatorHide()
                }
            }
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
        // Start only. Closing the mirror belongs to the header button, so a
        // stray click on the picture can't kill the feed.
        guard !webcamManager.isSessionRunning else { return }

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

/// Hosts the capture preview as a sublayer of a clipping container rather than
/// as the view's own backing layer. Scaling a backing layer would scale the
/// whole view; scaling a clipped sublayer crops into the video instead, and the
/// compositor samples the full-resolution frame while doing it.
///
/// Sizing happens on every frame change rather than only when SwiftUI pushes
/// new state, because the first state update lands before the view has been
/// given a real size — leaving the layer at zero, and the mirror black, until
/// something else happened to trigger another update.
final class CameraPreviewContainerView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var scale: CGFloat = 1

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let container = CALayer()
        container.masksToBounds = true
        layer = container
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(previewLayer newLayer: AVCaptureVideoPreviewLayer, scale newScale: CGFloat) {
        if previewLayer !== newLayer {
            previewLayer?.removeFromSuperlayer()
            newLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(newLayer)
            previewLayer = newLayer
        }
        scale = newScale
        layOutPreviewLayer()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOutPreviewLayer()
    }

    override func layout() {
        super.layout()
        layOutPreviewLayer()
    }

    private func layOutPreviewLayer() {
        guard let previewLayer, bounds.width > 0, bounds.height > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // Negative x keeps the mirror flip that the view used to apply itself.
        previewLayer.transform = CATransform3DMakeScale(-scale, scale, 1)
        CATransaction.commit()
    }
}

struct CameraPreviewLayerView: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer
    var scale: CGFloat = 1

    func makeNSView(context: Context) -> CameraPreviewContainerView {
        let view = CameraPreviewContainerView()
        view.configure(previewLayer: previewLayer, scale: scale)
        return view
    }

    func updateNSView(_ nsView: CameraPreviewContainerView, context: Context) {
        nsView.configure(previewLayer: previewLayer, scale: scale)
    }
}

#Preview {
    CameraPreviewView(webcamManager: .shared)
}
