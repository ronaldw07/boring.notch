//
//  VolumePanelView.swift
//  boringNotch
//
//  A big master volume slider, and a slider for each app that's making sound.
//  Sits in the slot beside the music player.
//

import SwiftUI

/// Same box as the mirror, lyrics and calendar, so swapping causes no
/// layout jump.
private let volumeSlotSize = CGSize(width: 215, height: 130)

struct VolumePanelView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var system = VolumeManager.shared
    @ObservedObject private var apps = AppVolumeManager.shared

    /// Held while dragging so the slider follows the pointer instead of
    /// the value the system reports back a moment later.
    @State private var draggedMaster: Double?

    private var masterValue: Double {
        draggedMaster ?? (system.isMuted ? 0 : Double(system.rawVolume))
    }

    var body: some View {
        VStack(spacing: 6) {
            masterSlider
            appList
        }
        .frame(width: volumeSlotSize.width, height: volumeSlotSize.height, alignment: .top)
        // A vertical swipe or sideways drag here is for the sliders and the
        // lists, not for closing the notch or switching tabs.
        .onHover { vm.isHoveringCalendar = $0 }
        // The volume manager only hears changes on the output device it
        // started with, so after the output switches (AirPods, a monitor)
        // its reading goes stale. Read it fresh on open and while showing.
        .task {
            while !Task.isCancelled {
                system.refresh()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onAppear {
            apps.beginPolling()
        }
        .onDisappear {
            apps.endPolling()
            vm.isHoveringCalendar = false
        }
    }

    // MARK: - Master

    private var masterSlider: some View {
        HStack(spacing: 8) {
            Button {
                system.toggleMuteAction()
            } label: {
                Image(systemName: speakerSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VolumeSlider(
                value: Binding(
                    get: { masterValue },
                    set: { newValue in
                        draggedMaster = newValue
                        system.setAbsolute(Float(newValue))
                    }
                ),
                trackHeight: 5,
                knobSize: CGSize(width: 30, height: 20),
                onEnd: { draggedMaster = nil }
            )

            Text("\(Int((masterValue * 100).rounded()))")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 26, alignment: .trailing)
        }
    }

    private var speakerSymbol: String {
        if masterValue <= 0 { return "speaker.slash.fill" }
        if masterValue < 0.34 { return "speaker.wave.1.fill" }
        if masterValue < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    // MARK: - Apps

    @ViewBuilder
    private var appList: some View {
        if apps.apps.isEmpty {
            Text("No apps with audio are open")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(apps.apps) { entry in
                        AppVolumeRow(entry: entry)
                    }
                }
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.88),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(alignment: .bottom) {
                if let name = apps.failedAppName {
                    Text("Couldn't control \(name). Allow audio capture in System Settings.")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(4)
                        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}

// MARK: - App rows

private struct AppVolumeRow: View {
    let entry: AppVolumeManager.Entry
    @ObservedObject private var apps = AppVolumeManager.shared

    var body: some View {
        let level = apps.level(for: entry)
        HStack(spacing: 6) {
            Group {
                if let icon = entry.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.gray)
                }
            }
            .frame(width: 16, height: 16)

            Text(entry.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: 58, alignment: .leading)

            VolumeSlider(
                value: Binding(
                    get: { level },
                    set: { apps.setLevel($0, for: entry) }
                ),
                trackHeight: 3,
                knobSize: CGSize(width: 18, height: 11)
            )

            Text("\(Int((level * 100).rounded()))")
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.gray)
                .frame(width: 22, alignment: .trailing)
        }
        .frame(height: 20)
        // Open but silent apps sit back until they play.
        .opacity(entry.isPlaying || level < 1 ? 1 : 0.5)
    }
}

/// Apple's Sound slider: a slim track filled with the accent colour and a
/// wide white pill for a knob. Pick the pill up and, on macOS 26 and later,
/// it turns into interactive Liquid Glass and swells; before that it just
/// swells. The whole row height is draggable, so the thin app sliders aren't
/// hard to grab.
private struct VolumeSlider: View {
    @Binding var value: Double
    let trackHeight: CGFloat
    let knobSize: CGSize
    var onEnd: () -> Void = {}

    @State private var isPressed = false

    private static let swell = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)

    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - knobSize.width)
            let knobX = travel * min(max(value, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.2))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Color.effectiveAccent)
                    .frame(width: knobX + knobSize.width / 2, height: trackHeight)
                knob
                    .frame(width: knobSize.width, height: knobSize.height)
                    .scaleEffect(isPressed ? 1.18 : 1)
                    .offset(x: knobX)
            }
            .animation(Self.swell, value: isPressed)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isPressed = true
                        value = min(max((drag.location.x - knobSize.width / 2) / travel, 0), 1)
                    }
                    .onEnded { _ in
                        isPressed = false
                        onEnd()
                    }
            )
        }
        .frame(height: max(knobSize.height, 20))
    }

    @ViewBuilder
    private var knob: some View {
        if #available(macOS 26.0, *) {
            if isPressed {
                // Clear glass: the track and fill show through, bent by it.
                Capsule()
                    .fill(.clear)
                    .glassEffect(.clear.interactive(), in: .capsule)
                    .transition(.opacity)
            } else {
                Capsule()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .transition(.opacity)
            }
        } else {
            Capsule()
                .fill(.white)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }
    }
}
