//
//  NotchHomeView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-18.
//  Modified by Harsh Vardhan Goswami & Richard Kunkli & Mustafa Ramadan
//  Modified by Ronald Wen — added the synced lyrics panel (shared slot with the mirror/calendar)
//

import Combine
import Defaults
import SwiftUI

// MARK: - Music Player Components

struct MusicPlayerView: View {
    @EnvironmentObject var vm: BoringViewModel
    let albumArtNamespace: Namespace.ID

    var body: some View {
        HStack {
            AlbumArtView(vm: vm, albumArtNamespace: albumArtNamespace).padding(.all, 5)
            MusicControlsView().drawingGroup().compositingGroup()
        }
    }
}

struct AlbumArtView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var vm: BoringViewModel
    let albumArtNamespace: Namespace.ID

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if Defaults[.lightingEffect] {
                albumArtBackground
            }
            albumArtButton
        }
    }

    private var albumArtBackground: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Defaults[.cornerRadiusScaling]
                        ? MusicPlayerImageSizes.cornerRadiusInset.opened
                        : MusicPlayerImageSizes.cornerRadiusInset.closed)
            )
            .aspectRatio(1, contentMode: .fit)
            .scaleEffect(x: 1.3, y: 1.4)
            .rotationEffect(.degrees(92))
            .blur(radius: 40)
            .opacity(musicManager.isPlaying ? 0.5 : 0)
    }

    private var albumArtButton: some View {
        ZStack {
            Button {
                musicManager.openMusicApp()
            } label: {
                ZStack(alignment:.bottomTrailing) {
                    albumArtImage
                    appIconOverlay
                }
            }
            .buttonStyle(PlainButtonStyle())
            .scaleEffect(musicManager.isPlaying ? 1 : 0.85)
            
            albumArtDarkOverlay
        }
    }

    private var albumArtDarkOverlay: some View {
        Rectangle()
            .aspectRatio(1, contentMode: .fit)
            .foregroundColor(Color.black)
            .opacity(musicManager.isPlaying ? 0 : 0.8)
            .blur(radius: 50)
    }
                

    private var albumArtImage: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Defaults[.cornerRadiusScaling]
                        ? MusicPlayerImageSizes.cornerRadiusInset.opened
                        : MusicPlayerImageSizes.cornerRadiusInset.closed)
            )
    }

    @ViewBuilder
    private var appIconOverlay: some View {
        if vm.notchState == .open && !musicManager.usingAppIconForArtwork {
            AppIcon(for: musicManager.bundleIdentifier ?? "com.apple.Music")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30)
                .offset(x: 10, y: 10)
                .transition(.scale.combined(with: .opacity))
                .zIndex(2)
        }
    }
}

struct MusicControlsView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast
    @Default(.musicControlSlots) private var slotConfig
    @Default(.musicControlSlotLimit) private var slotLimit

    var body: some View {
        VStack(alignment: .leading) {
            songInfoAndSlider
            slotToolbar
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var songInfoAndSlider: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 4) {
                songInfo(width: geo.size.width)
                musicSlider
            }
        }
        .padding(.top, 10)
        .padding(.leading, 5)
    }

    private func songInfo(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MarqueeText(
                $musicManager.songTitle, font: .headline, nsFont: .headline, textColor: .white,
                frameWidth: width)
            MarqueeText(
                $musicManager.artistName,
                font: .headline,
                nsFont: .headline,
                textColor: Defaults[.playerColorTinting]
                    ? Color(nsColor: musicManager.avgColor)
                        .ensureMinimumBrightness(factor: 0.6) : .gray,
                frameWidth: width
            )
            .fontWeight(.medium)
        }
    }

    private var musicSlider: some View {
        // `nil` for minimumInterval means unthrottled, not stopped — that
        // previously kicked in exactly when paused (playbackRate == 0),
        // ticking this at full frame rate right when the readout most needed
        // to hold still. Slowed rather than stopped while paused, so a seek
        // made from the player itself still shows up.
        TimelineView(.animation(minimumInterval: musicManager.isPlaying ? 0.1 : 0.5)) { timeline in
            MusicSliderView(
                sliderValue: $sliderValue,
                duration: $musicManager.songDuration,
                lastDragged: $lastDragged,
                color: musicManager.avgColor,
                dragging: $dragging,
                currentDate: timeline.date,
                timestampDate: musicManager.timestampDate,
                elapsedTime: musicManager.elapsedTime,
                playbackRate: musicManager.playbackRate,
                isPlaying: musicManager.isPlaying
            ) { newValue in
                MusicManager.shared.seek(to: newValue)
            }
            .padding(.top, 5)
            .frame(height: 36)
        }
    }

    private var slotToolbar: some View {
        let slots = activeSlots
        return HStack(spacing: 6) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                slotView(for: slot)
                    .frame(alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var activeSlots: [MusicControlButton] {
        let sanitizedLimit = min(
            max(slotLimit, MusicControlButton.minSlotCount),
            MusicControlButton.maxSlotCount
        )
        let padded = slotConfig.padded(to: sanitizedLimit, filler: .none)
        return Array(padded.prefix(sanitizedLimit))
    }

    @ViewBuilder
    private func slotView(for slot: MusicControlButton) -> some View {
        switch slot {
        case .shuffle:
            HoverButton(icon: "shuffle", iconColor: musicManager.isShuffled ? .red : .primary, scale: .medium) {
                MusicManager.shared.toggleShuffle()
            }
        case .previous:
            HoverButton(icon: "backward.fill", scale: .medium) {
                MusicManager.shared.previousTrack()
            }
        case .playPause:
            HoverButton(icon: musicManager.isPlaying ? "pause.fill" : "play.fill", scale: .large) {
                MusicManager.shared.togglePlay()
            }
        case .next:
            HoverButton(icon: "forward.fill", scale: .medium) {
                MusicManager.shared.nextTrack()
            }
        case .repeatMode:
            HoverButton(icon: repeatIcon, iconColor: repeatIconColor, scale: .medium) {
                MusicManager.shared.toggleRepeat()
            }
        case .volume:
            VolumeControlView()
        case .favorite:
            FavoriteControlButton()
        case .goBackward:
            HoverButton(icon: "gobackward.15", scale: .medium) {
                MusicManager.shared.skip(seconds: -15)
            }
        case .goForward:
            HoverButton(icon: "goforward.15", scale: .medium) {
                MusicManager.shared.skip(seconds: 15)
            }
        case .none:
            Color.clear.frame(height: 1)
        }
    }

    private var repeatIcon: String {
        switch musicManager.repeatMode {
        case .off:
            return "repeat"
        case .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }

    private var repeatIconColor: Color {
        switch musicManager.repeatMode {
        case .off:
            return .primary
        case .all, .one:
            return .red
        }
    }
}

struct FavoriteControlButton: View {
    @ObservedObject var musicManager = MusicManager.shared

    var body: some View {
        HoverButton(icon: iconName, iconColor: iconColor, scale: .medium) {
            MusicManager.shared.toggleFavoriteTrack()
        }
        .disabled(!musicManager.canFavoriteTrack)
        .opacity(musicManager.canFavoriteTrack ? 1 : 0.35)
    }

    private var iconName: String {
        musicManager.isFavoriteTrack ? "heart.fill" : "heart"
    }

    private var iconColor: Color {
        musicManager.isFavoriteTrack ? .red : .primary
    }
}

private extension Array where Element == MusicControlButton {
    func padded(to length: Int, filler: MusicControlButton) -> [MusicControlButton] {
        if count >= length { return self }
        return self + Array(repeating: filler, count: length - count)
    }
}

// MARK: - Volume Control View

struct VolumeControlView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @State private var volumeSliderValue: Double = 0.5
    @State private var dragging: Bool = false
    @State private var showVolumeSlider: Bool = false
    @State private var lastVolumeUpdateTime: Date = Date.distantPast
    private let volumeUpdateThrottle: TimeInterval = 0.1
    
    var body: some View {
        HStack(spacing: 4) {
            Button(action: {
                if musicManager.volumeControlSupported {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showVolumeSlider.toggle()
                    }
                }
            }) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(musicManager.volumeControlSupported ? .white : .gray)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!musicManager.volumeControlSupported)
            .frame(width: 24)

            if showVolumeSlider && musicManager.volumeControlSupported {
                CustomSlider(
                    value: $volumeSliderValue,
                    range: 0.0...1.0,
                    color: .white,
                    dragging: $dragging,
                    lastDragged: .constant(Date.distantPast),
                    onValueChange: { newValue in
                        MusicManager.shared.setVolume(to: newValue)
                    },
                    onDragChange: { newValue in
                        let now = Date()
                        if now.timeIntervalSince(lastVolumeUpdateTime) > volumeUpdateThrottle {
                            MusicManager.shared.setVolume(to: newValue)
                            lastVolumeUpdateTime = now
                        }
                    }
                )
                .frame(width: 48, height: 8)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .clipped()
        .onReceive(musicManager.$volume) { volume in
            if !dragging {
                volumeSliderValue = volume
            }
        }
        .onReceive(musicManager.$volumeControlSupported) { supported in
            if !supported {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showVolumeSlider = false
                }
            }
        }
        .onChange(of: showVolumeSlider) { _, isShowing in
            if isShowing {
                // Sync volume from app when slider appears
                Task {
                    await MusicManager.shared.syncVolumeFromActiveApp()
                }
            }
        }
        .onDisappear {
            // volumeUpdateTask?.cancel() // No longer needed
        }
    }
    
    
    private var volumeIcon: String {
        if !musicManager.volumeControlSupported {
            return "speaker.slash"
        } else if volumeSliderValue == 0 {
            return "speaker.slash.fill"
        } else if volumeSliderValue < 0.33 {
            return "speaker.1.fill"
        } else if volumeSliderValue < 0.66 {
            return "speaker.2.fill"
        } else {
            return "speaker.3.fill"
        }
    }
}

// MARK: - Synced Lyrics Panel

struct SyncedLyricsPanelView: View {
    @ObservedObject var musicManager = MusicManager.shared
    // Set while the user is dragging through lines by hand; nil means
    // "follow playback". Fractional, not snapped to a line, so scrolling
    // tracks the gesture continuously instead of hopping line to line.
    @State private var scrubPosition: Double? = nil
    private static let slotSize = CGSize(width: 215, height: 130)
    // Tall enough to fit a wrapped second line instead of truncating with
    // an ellipsis — every row is this height so the scroll math (each line
    // exactly lineStep apart) stays uniform regardless of wrapping.
    private static let lineStep: CGFloat = 34
    // Provider timestamps read a little late against the actual audio —
    // look this far ahead so a line lands when it's actually sung.
    private static let lyricLeadOffset: Double = 0.5

    var body: some View {
        content
            .frame(width: Self.slotSize.width, height: Self.slotSize.height)
            .clipped()
    }

    @ViewBuilder
    private var content: some View {
        if musicManager.isFetchingLyrics {
            placeholder("Loading lyrics…")
        } else if !musicManager.syncedLyrics.isEmpty {
            syncedView
        } else if !musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            plainScrollView
        } else {
            placeholder("No lyrics found")
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.gray)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func liveElapsed() -> Double {
        guard musicManager.isPlaying else { return musicManager.elapsedTime }
        let delta = Date().timeIntervalSince(musicManager.timestampDate)
        let progressed = musicManager.elapsedTime + (delta * musicManager.playbackRate)
        return min(max(progressed, 0), musicManager.songDuration)
    }

    private func clampedIndex(_ index: Int) -> Int {
        min(max(index, 0), max(musicManager.syncedLyrics.count - 1, 0))
    }

    private func clampedPosition(_ position: Double) -> Double {
        min(max(position, 0), Double(max(musicManager.syncedLyrics.count - 1, 0)))
    }

    private var syncedView: some View {
        ZStack(alignment: .bottom) {
            // Only the live-tracking path needs a running timer — scrubbing
            // and pausing both render a single static frame, no ticking.
            if let scrubPosition {
                // No bold while browsing by hand — a per-line font/weight
                // change while scrolling is what read as stutter. Still
                // fades toward whichever line is centered, just by opacity.
                // Not animated — the position already moves continuously
                // with the scroll gesture itself, so an eased transition on
                // top of that just reintroduces the lag it's meant to fix.
                scrollingStack(position: scrubPosition, emphasisIndex: Int(scrubPosition.rounded()), boldIndex: nil, animated: false)
            } else if musicManager.isPlaying {
                // Snaps per line rather than gliding across the whole gap
                // between two timestamps — that gap can be several seconds,
                // and drifting the entire time read as sluggish rather than
                // synced. A quick animated snap the moment the line changes
                // reads as "synced" the way Spotify's does.
                TimelineView(.animation(minimumInterval: 0.05)) { timeline in
                    let delta = timeline.date.timeIntervalSince(musicManager.timestampDate)
                    let progressed = musicManager.elapsedTime + (delta * musicManager.playbackRate)
                    let elapsed = min(max(progressed, 0), musicManager.songDuration)
                    let highlightIndex = musicManager.lyricLineIndex(at: elapsed + Self.lyricLeadOffset)
                    scrollingStack(position: Double(highlightIndex ?? 0), emphasisIndex: highlightIndex, boldIndex: highlightIndex, animated: true)
                }
            } else {
                let highlightIndex = musicManager.lyricLineIndex(at: liveElapsed() + Self.lyricLeadOffset)
                scrollingStack(position: Double(highlightIndex ?? 0), emphasisIndex: highlightIndex, boldIndex: highlightIndex, animated: true)
            }

            if scrubPosition != nil {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scrubPosition = nil
                    }
                } label: {
                    Label("Sync", systemImage: "waveform")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 2)
                .transition(.opacity)
                .zIndex(1)
            }

            // Scroll capture sits over the scrolling text only, not the
            // Sync pill's strip — an NSView here wins hit-testing against
            // any SwiftUI content underneath regardless of z-order, so
            // covering the button's area would swallow its clicks outright.
            LyricsScrollCapture(onScroll: handleScroll, onTap: handleLineTap)
                .padding(.bottom, 24)
        }
        .contentShape(Rectangle())
    }

    /// A click's y-distance from the panel's vertical center — where the
    /// live/centered line always sits — converts straight to a line offset,
    /// the same convention `handleScroll` uses. Seeking there also drops
    /// out of scrub mode, so tracking resumes from the new position.
    private func handleLineTap(atY y: CGFloat) {
        let lyrics = musicManager.syncedLyrics
        guard !lyrics.isEmpty else { return }
        let base = scrubPosition ?? Double(musicManager.lyricLineIndex(at: liveElapsed() + Self.lyricLeadOffset) ?? 0)
        let deltaLines = ((y - Self.slotSize.height / 2) / Self.lineStep).rounded()
        let target = clampedIndex(Int(base) + Int(deltaLines))
        musicManager.seek(to: lyrics[target].time)
        scrubPosition = nil
    }

    /// Two-finger trackpad scroll, or an external mouse wheel — moves
    /// `scrubPosition` by exactly the gesture's own distance, not in
    /// whole-line steps, so it tracks the input continuously instead of
    /// sticking from level to level.
    private func handleScroll(_ deltaY: CGFloat) {
        let base = scrubPosition ?? Double(musicManager.lyricLineIndex(at: liveElapsed()) ?? 0)
        scrubPosition = clampedPosition(base - deltaY / Self.lineStep)
    }

    /// Every line lives in one stack that slides as a whole, like Spotify's
    /// lyrics screen — not a fixed set of prev/current/next slots swapping
    /// content, which read as jumping between discrete levels rather than
    /// scrolling. `position` can be fractional so the glide between two
    /// lines is continuous rather than a discrete per-line hop.
    private func scrollingStack(position: Double, emphasisIndex: Int?, boldIndex: Int?, animated: Bool) -> some View {
        let lyrics = musicManager.syncedLyrics
        let clampedPosition = min(max(position, 0), Double(max(lyrics.count - 1, 0)))
        let center = Self.slotSize.height / 2 - Self.lineStep / 2

        return LazyVStack(spacing: 0) {
            ForEach(Array(lyrics.enumerated()), id: \.offset) { index, entry in
                Text(entry.text)
                    .font(.system(size: index == boldIndex ? 14 : 12, weight: index == boldIndex ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(lineOpacity(index: index, emphasisIndex: emphasisIndex)))
                    // No cap — a line that needs 3+ wrapped rows just takes
                    // the room it needs (pushing the next block down) rather
                    // than ever truncating with an ellipsis.
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .frame(width: Self.slotSize.width, alignment: .top)
                    .frame(minHeight: Self.lineStep, alignment: .top)
                    // `minHeight` only pads a row shorter than lineStep — a
                    // wrapped 2-line row already exceeds that on its own
                    // content, so without this it butts straight into the
                    // next line with no breathing room at all.
                    .padding(.bottom, 8)
            }
        }
        .offset(y: center - CGFloat(clampedPosition) * Self.lineStep)
        .animation(animated ? .easeOut(duration: 0.15) : nil, value: clampedPosition)
        .frame(width: Self.slotSize.width, height: Self.slotSize.height, alignment: .top)
        .clipped()
    }

    private func lineOpacity(index: Int, emphasisIndex: Int?) -> Double {
        // Nothing has genuinely started yet (before the first synced
        // timestamp) — keep everything at one dim, uncommitted level rather
        // than falsely emphasizing line 0.
        guard let emphasisIndex else { return 0.3 }
        switch abs(index - emphasisIndex) {
        case 0: return 1
        case 1: return 0.45
        case 2: return 0.25
        default: return 0.12
        }
    }

    private var plainScrollView: some View {
        ScrollView {
            Text(musicManager.currentLyrics)
                .font(.system(size: 12))
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
        }
    }
}

/// SwiftUI's own scroll/drag gestures are unreliable in this app's
/// non-key `NSPanel` (see the shelf's item view for the same workaround),
/// so trackpad scroll here is captured directly in AppKit.
private struct LyricsScrollCapture: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void
    // Top-down y of the click within this view, so SwiftUI can convert it
    // to a line index using the same geometry it lays lines out with.
    let onTap: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollCaptureView {
        let view = ScrollCaptureView()
        view.onScroll = onScroll
        view.onTap = onTap
        return view
    }

    func updateNSView(_ nsView: ScrollCaptureView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onTap = onTap
    }

    final class ScrollCaptureView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        var onTap: ((CGFloat) -> Void)?

        override var isFlipped: Bool { true }

        override func scrollWheel(with event: NSEvent) {
            // A physical mouse wheel reports coarse, unitless notches rather
            // than a trackpad's precise point deltas — scaled up so a
            // couple of clicks actually moves a line instead of barely
            // registering against `lineStep`.
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            onScroll?(event.scrollingDeltaY * scale)
        }

        override func mouseUp(with event: NSEvent) {
            let local = convert(event.locationInWindow, from: nil)
            onTap?(local.y)
        }
    }
}

// MARK: - Main View

struct NotchHomeView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager = WebcamManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    let albumArtNamespace: Namespace.ID

    var body: some View {
        Group {
            if !coordinator.firstLaunch {
                mainContent
            }
        }
        // simplified: use a straightforward opacity transition
        .transition(.opacity)
    }

    private var shouldShowCamera: Bool {
        Defaults[.showMirror] && webcamManager.cameraAvailable && vm.isCameraExpanded
    }

    private var shouldShowLyricsPanel: Bool {
        Defaults[.showLyricsButton] && Defaults[.enableLyrics] && vm.isLyricsExpanded
    }

    private var shouldShowCalendarPanel: Bool {
        Defaults[.showCalendar] && vm.isCalendarExpanded
    }

    private var mainContent: some View {
        HStack(alignment: .top, spacing: 15) {
            MusicPlayerView(albumArtNamespace: albumArtNamespace)

            // Mirror, lyrics, and calendar share one slot: whichever is
            // active takes over rather than squeezing the others down.
            if shouldShowCamera {
                CameraPreviewView(webcamManager: webcamManager)
                    .opacity(vm.notchState == .closed ? 0 : 1)
                    .blur(radius: vm.notchState == .closed ? 20 : 0)
                    .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.76, blendDuration: 0), value: shouldShowCamera)
                    .transition(.opacity)
            } else if shouldShowLyricsPanel {
                SyncedLyricsPanelView()
                    .opacity(vm.notchState == .closed ? 0 : 1)
                    .blur(radius: vm.notchState == .closed ? 20 : 0)
                    .transition(.opacity)
            } else if shouldShowCalendarPanel {
                CalendarView()
                    .frame(width: 215)
                    .onHover { isHovering in
                        vm.isHoveringCalendar = isHovering
                    }
                    .environmentObject(vm)
                    .transition(.opacity)
            }
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
        .blur(radius: vm.notchState == .closed ? 30 : 0)
    }
}

struct MusicSliderView: View {
    @Binding var sliderValue: Double
    @Binding var duration: Double
    @Binding var lastDragged: Date
    var color: NSColor
    @Binding var dragging: Bool
    let currentDate: Date
    let timestampDate: Date
    let elapsedTime: Double
    let playbackRate: Double
    let isPlaying: Bool
    var onValueChange: (Double) -> Void


    var body: some View {
        VStack {
            CustomSlider(
                value: $sliderValue,
                range: 0...duration,
                color: Defaults[.sliderColor] == SliderColorEnum.albumArt
                    ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.8)
                    : Defaults[.sliderColor] == SliderColorEnum.accent ? .effectiveAccent : .white,
                dragging: $dragging,
                lastDragged: $lastDragged,
                onValueChange: onValueChange
            )
            .frame(height: 10, alignment: .center)

            HStack {
                Text(timeString(from: sliderValue))
                Spacer()
                Text(timeString(from: duration))
            }
            .fontWeight(.medium)
            .foregroundColor(
                Defaults[.playerColorTinting]
                    ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.6) : .gray
            )
            .font(.caption)
        }
        // `initial` seeds the value as the view appears. This view is built
        // fresh every time the notch opens, and without it the readout renders
        // its default of zero until the next timeline tick — up to half a
        // second while paused, which is the drop to 0:00 and back on open.
        .onChange(of: currentDate, initial: true) {
           guard !dragging, timestampDate.timeIntervalSince(lastDragged) > -1 else { return }
            sliderValue = MusicManager.shared.displayedPlaybackPosition(at: currentDate)
        }
    }

    func timeString(from seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            return String(format: "%d:%02d", minutes, remainingSeconds)
        }
    }
}

struct CustomSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var color: Color = .white
    @Binding var dragging: Bool
    @Binding var lastDragged: Date
    var onValueChange: ((Double) -> Void)?
    var onDragChange: ((Double) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = CGFloat(dragging ? 9 : 5)
            let rangeSpan = range.upperBound - range.lowerBound

            let progress = rangeSpan == .zero ? 0 : (value - range.lowerBound) / rangeSpan
            let filledTrackWidth = min(max(progress, 0), 1) * width

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.gray.opacity(0.3))
                    .frame(height: height)

                Rectangle()
                    .fill(color)
                    .frame(width: filledTrackWidth, height: height)
            }
            .cornerRadius(height / 2)
            .frame(height: 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        withAnimation {
                            dragging = true
                        }
                        let newValue = range.lowerBound + Double(gesture.location.x / width) * rangeSpan
                        value = min(max(newValue, range.lowerBound), range.upperBound)
                        onDragChange?(value)
                    }
                    .onEnded { _ in
                        onValueChange?(value)
                        dragging = false
                        lastDragged = Date()
                    }
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: dragging)
        }
    }
}
