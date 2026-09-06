//
//  MusicVisualizer.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//
import AppKit
import Cocoa
import SwiftUI

private let minimumBarScale: CGFloat = 0.35

class AudioSpectrum: NSView {
    private var barLayers: [CAShapeLayer] = []
    private var barScales: [CGFloat] = []
    private var isPlaying: Bool = true
    private var animationTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }

    private func setupBars() {
        let barWidth: CGFloat = 2
        let barCount = visualizerBandCount
        let spacing: CGFloat = barWidth
        let totalWidth = CGFloat(barCount) * (barWidth + spacing)
        let totalHeight: CGFloat = 14
        frame.size = CGSize(width: totalWidth, height: totalHeight)

        for i in 0 ..< barCount {
            let xPosition = CGFloat(i) * (barWidth + spacing)
            let barLayer = CAShapeLayer()
            barLayer.frame = CGRect(x: xPosition, y: 0, width: barWidth, height: totalHeight)
            barLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            barLayer.position = CGPoint(x: xPosition + barWidth / 2, y: totalHeight / 2)
            barLayer.fillColor = NSColor.white.cgColor
            barLayer.backgroundColor = NSColor.white.cgColor
            barLayer.allowsGroupOpacity = false
            barLayer.masksToBounds = true
            let path = NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: barWidth, height: totalHeight),
                                    xRadius: barWidth / 2,
                                    yRadius: barWidth / 2)
            barLayer.path = path.cgPath
            barLayers.append(barLayer)
            barScales.append(minimumBarScale)
            layer?.addSublayer(barLayer)
        }
    }

    /// Drives the bars from real spectrum levels. Levels already carry their own
    /// attack/release smoothing, so implicit layer animation is disabled here to
    /// avoid animating on top of a value that changes 30 times a second.
    func apply(levels: [CGFloat]) {
        stopAnimating()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, barLayer) in barLayers.enumerated() {
            let level = i < levels.count ? levels[i] : 0
            let scale = minimumBarScale + (1 - minimumBarScale) * level
            barLayer.transform = CATransform3DMakeScale(1, scale, 1)
            barScales[i] = scale
        }
        CATransaction.commit()
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.updateBars()
        }
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func updateBars() {
        for (i, barLayer) in barLayers.enumerated() {
            let currentScale = barScales[i]
            let targetScale = CGFloat.random(in: minimumBarScale ... 1.0)
            barScales[i] = targetScale
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = currentScale
            animation.toValue = targetScale
            animation.duration = 0.3
            animation.autoreverses = true
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            if #available(macOS 13.0, *) {
                animation.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 24, preferred: 24)
            }
            barLayer.add(animation, forKey: "scaleY")
        }
    }

    private func resetBars() {
        for (i, barLayer) in barLayers.enumerated() {
            barLayer.removeAllAnimations()
            barLayer.transform = CATransform3DMakeScale(1, minimumBarScale, 1)
            barScales[i] = minimumBarScale
        }
    }

    /// `isLive` is false when no process tap is running (permission denied, or
    /// macOS older than 14.2), in which case the bars fall back to the original
    /// synthetic animation rather than sitting frozen.
    func setPlaying(_ playing: Bool, isLive: Bool) {
        isPlaying = playing
        if playing, !isLive {
            startAnimating()
        } else {
            stopAnimating()
            if !playing { resetBars() }
        }
    }
}

struct AudioSpectrumView: NSViewRepresentable {
    @Binding var isPlaying: Bool
    var bundleIdentifier: String?

    @ObservedObject private var tap = AudioSpectrumTap.shared

    func makeNSView(context: Context) -> AudioSpectrum {
        let spectrum = AudioSpectrum()
        spectrum.setPlaying(isPlaying, isLive: tap.isLive)
        return spectrum
    }

    func updateNSView(_ nsView: AudioSpectrum, context: Context) {
        if isPlaying {
            tap.activate(for: bundleIdentifier)
        } else {
            tap.deactivate()
        }

        nsView.setPlaying(isPlaying, isLive: tap.isLive)
        if isPlaying, tap.isLive {
            nsView.apply(levels: tap.levels)
        }
    }
}

#Preview {
    AudioSpectrumView(isPlaying: .constant(true), bundleIdentifier: nil)
        .frame(width: 16, height: 20)
        .padding()
}
