//
//  WebcamView.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 19/08/24.
//

import AVFoundation
import Defaults
import SwiftUI

private let minimumZoom: CGFloat = 1
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
    @State private var zoom: CGFloat = minimumZoom
    @State private var zoomAtDragStart: CGFloat = minimumZoom
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
                        .clipShape(RoundedRectangle(cornerRadius: Defaults[.mirrorShape] == .rectangle ? !Defaults[.cornerRadiusScaling] ? MusicPlayerImageSizes.cornerRadiusInset.closed : MusicPlayerImageSizes.cornerRadiusInset.opened : 100))
                        .frame(width: geometry.size.width, height: geometry.size.width)
                        .opacity(webcamManager.isSessionRunning ? 1 : 0)
                }

                if !webcamManager.isSessionRunning {
                    ZStack {
                        RoundedRectangle(cornerRadius: Defaults[.mirrorShape] == .rectangle ? !Defaults[.cornerRadiusScaling] ? MusicPlayerImageSizes.cornerRadiusInset.closed : 12 : 100)
                            .fill(Color(red: 20/255, green: 20/255, blue: 20/255))
                            .strokeBorder(.white.opacity(0.04), lineWidth: 1)
                            .frame(width: geometry.size.width, height: geometry.size.width)
                        VStack(spacing: 8) {
                            Image(systemName: webcamManager.authorizationStatus == .denied ? "exclamationmark.triangle" : "web.camera")
                                .foregroundStyle(.gray)
                                .font(.system(size: geometry.size.width/3.5))
                            Text(webcamManager.authorizationStatus == .denied ? "Access Denied" : "Mirror")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                }
                if webcamManager.isSessionRunning {
                    ZoomIndicator(zoom: zoom)
                        .padding(.bottom, geometry.size.width * 0.08)
                        .frame(width: geometry.size.width, height: geometry.size.width,
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
            .onDisappear {
                zoomIndicatorTask?.cancel()
                webcamManager.stopSession()
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// Zoom tracks the pointer one-to-one while dragging, so it is deliberately
    /// not animated. Only the settle back into range is.
    private var zoomDrag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard webcamManager.isSessionRunning else { return }

                isDraggingZoom = true
                let range = maximumZoom - minimumZoom
                zoom = resisted(zoomAtDragStart + value.translation.width / zoomDragTravel * range)
                revealZoomIndicator()
            }
            .onEnded { _ in
                isDraggingZoom = false
                guard webcamManager.isSessionRunning else { return }

                zoomAtDragStart = min(max(zoom, minimumZoom), maximumZoom)
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
        if value > maximumZoom {
            return maximumZoom + (value - maximumZoom) * zoomOvershootResistance
        }
        if value < minimumZoom {
            return minimumZoom - (minimumZoom - value) * zoomOvershootResistance
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
private struct ZoomIndicator: View {
    let zoom: CGFloat

    private static let tickCount = 21

    private var progress: CGFloat {
        let range = maximumZoom - minimumZoom
        return min(max((zoom - minimumZoom) / range, 0), 1)
    }

    private var label: String {
        let rounded = (zoom * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? "\(Int(rounded))×"
            : String(format: "%.1f×", rounded)
    }

    var body: some View {
        VStack(spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.yellow)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())

            HStack(spacing: 0) {
                ForEach(0 ..< Self.tickCount, id: \.self) { index in
                    let isMajor = index % 5 == 0
                    let isReached = CGFloat(index) / CGFloat(Self.tickCount - 1) <= progress
                    Capsule()
                        .fill(.white.opacity(isReached ? (isMajor ? 0.95 : 0.7) : 0.25))
                        .frame(width: 1, height: isMajor ? 7 : 4)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 7)
            .padding(.horizontal, 10)
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
