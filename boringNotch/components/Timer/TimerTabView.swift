//
//  TimerTabView.swift
//  boringNotch
//
//  A stopwatch and a countdown timer sharing one tab. Unlike the other
//  tabs, running state isn't reset by switching away — the whole point is
//  that it keeps going (and shows up in the closed notch) regardless of
//  what's currently open.
//  Modified by Ronald Wen — changed the Timer tab to a row layout so it stops growing the notch
//

import Defaults
import SwiftUI

private let presetMinutes = [1, 5, 10, 25]
private let maxRecentCount = 5

private enum TimerLength {
    static let maxSeconds = 180 * 60

    static func isPreset(_ seconds: Int) -> Bool {
        seconds % 60 == 0 && presetMinutes.contains(seconds / 60)
    }

    /// "45s", "5m", "2:30" — whole minutes stay short, anything with
    /// leftover seconds is spelled out.
    static func label(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds % 60 == 0 { return "\(seconds / 60)m" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Typing works like a microwave: the last two digits are seconds, the
    /// rest minutes, so 45 is 0:45 and 230 is 2:30.
    static func typedText(fromDigits digits: String) -> String {
        guard let n = Int(digits) else { return "" }
        return String(format: "%d:%02d", n / 100, n % 100)
    }

    static func seconds(fromDigits digits: String) -> Int {
        guard let n = Int(digits) else { return 0 }
        return (n / 100) * 60 + n % 100
    }

    /// 5s steps under a minute, whole minutes above it.
    static func stepped(_ seconds: Int, up: Bool) -> Int {
        let s = max(1, seconds)
        if up {
            return s < 60 ? min(60, (s / 5 + 1) * 5) : min(maxSeconds, (s / 60 + 1) * 60)
        }
        return s <= 60 ? max(1, ((s - 1) / 5) * 5) : ((s - 1) / 60) * 60
    }
}

struct TimerTabView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var timer = TimerManager.shared
    @Default(.timerCustomSeconds) private var customSeconds
    @Default(.timerRecentSeconds) private var recentSeconds
    @State private var finishedPulse = false
    @State private var isEditingCustom = false
    @State private var customText = ""
    @FocusState private var customFieldFocused: Bool

    /// The readout's slot, ring or no ring. Fixed so switching modes can't
    /// change the row's height, and sized so the tab as a whole fits the
    /// same space Home, Shelf and Clipboard are given.
    private static let readoutSlotHeight: CGFloat = 88
    /// Fits "59:59", so the custom chip is the same width showing or editing.
    private static let customChipContentWidth: CGFloat = 34
    private static let chipRowSpacing: CGFloat = 6
    /// Two chip rows: presets and recents for the timer, laps for the stopwatch.
    private static let choicesHeight: CGFloat = 18 * 2 + chipRowSpacing
    /// The running-timers column; laid out in both modes so switching
    /// modes doesn't move the readout.
    private static let countdownListWidth: CGFloat = 92

    var body: some View {
        VStack(spacing: 8) {
            modePicker

            // Readout and controls side by side rather than stacked. A tab's
            // content area in the open notch is wide and short — roughly
            // 640 x 145 — and a column of readout → presets → controls wants
            // closer to 230, so this tab used to grow the whole panel to fit
            // itself. That extra height is what made it hang below the notch
            // as its own box instead of reading as part of it. Laid out
            // across the width it already has, it needs no extra height at
            // all, so the panel stays exactly the size every other tab is.
            HStack(spacing: 18) {
                // Ring and readout are both drawn from the timeline's own clock
                // rather than the manager's once-a-second tick, so the ring
                // glides instead of stepping and the two can never disagree.
                // Paused when nothing is running: neither value depends on
                // the date then.
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !timer.isRunning)) { timeline in
                    ZStack {
                        if timer.mode == .countdown {
                            TimerRing(progress: ringProgress(at: timeline.date), color: ringColor)
                                .frame(width: Self.readoutSlotHeight, height: Self.readoutSlotHeight)
                        }

                        readout(at: timeline.date)
                    }
                }
                // Height pinned, width left to the content: the stopwatch's
                // readout is wider than the ring it stands in for, and
                // pinning both would squeeze it.
                .frame(height: Self.readoutSlotHeight)
                .scaleEffect(finishedPulse ? 1.08 : 1.0)

                VStack(spacing: 10) {
                    // Always present rather than conditionally inserted, so
                    // stopwatch and countdown share one layout and switching
                    // between them only changes what's interactive.
                    VStack(spacing: Self.chipRowSpacing) {
                        presetRow
                        recentRow
                    }
                    .opacity(showsPresetRow ? 1 : 0)
                    .allowsHitTesting(showsPresetRow)
                    .frame(height: Self.choicesHeight)
                    // An overlay takes the preset rows' size: on its own, a
                    // sideways scroll view stretches to the full width and
                    // pushes the readout off to the side.
                    .overlay {
                        if timer.mode == .stopwatch {
                            lapRow
                        }
                    }

                    controls
                }

                countdownList
                    .opacity(timer.mode == .countdown ? 1 : 0)
                    .allowsHitTesting(timer.mode == .countdown)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            // This tab never asks for extra height of its own, but the one
            // before it might have (an expanded clipboard list), and that
            // would otherwise still be applied while this is on screen.
            vm.setExtraContentHeight(0)
        }
        .onChange(of: timer.justFinished) { _, finished in
            guard finished != nil else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.45)) {
                finishedPulse = true
            }
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    finishedPulse = false
                }
            }
        }
    }

    // MARK: - Readout

    private func readout(at date: Date) -> some View {
        let displayedSeconds = displayedSeconds(at: date)
        return VStack(spacing: 2) {
            HStack(alignment: .lastTextBaseline, spacing: 1) {
                Text(TimerManager.clockString(from: displayedSeconds))
                    .font(.system(size: timer.mode == .countdown ? 20 : 28, weight: .semibold, design: .monospaced))

                if timer.mode == .stopwatch {
                    Text(".\(TimerManager.centisecondsString(from: displayedSeconds))")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.gray)
                }
            }
            .foregroundStyle(timer.isFinished ? .red : .white)
            .contentTransition(.numericText())

            // The lap in progress, counting from the last flag. Before the
            // first lap it would just repeat the total, so it waits for one.
            if timer.mode == .stopwatch && !timer.laps.isEmpty {
                let lap = timer.currentLapElapsed(at: date)
                Text("Lap \(timer.laps.count + 1)  "
                     + TimerManager.clockString(from: lap) + "." + TimerManager.centisecondsString(from: lap))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.gray)
            }
        }
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        HStack(spacing: 4) {
            modeButton(title: "Timer", mode: .countdown)
            modeButton(title: "Stopwatch", mode: .stopwatch)
        }
        .padding(3)
        .background(Capsule().fill(Color(nsColor: .secondarySystemFill).opacity(0.5)))
    }

    private func modeButton(title: String, mode: TimerMode) -> some View {
        let isSelected = timer.mode == mode
        return Button {
            withAnimation(.smooth) {
                timer.setMode(mode)
            }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? .white : .gray)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background {
                    if isSelected {
                        Capsule().fill(Color.effectiveAccent.opacity(0.35))
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Presets

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(presetMinutes, id: \.self) { minutes in
                durationChip(seconds: minutes * 60)
            }
            HStack(spacing: 2) {
                customLabel
                Stepper("", onIncrement: { stepCustom(up: true) }, onDecrement: { stepCustom(up: false) })
                    .labelsHidden()
                    .fixedSize()
            }
        }
        .onDisappear {
            if isEditingCustom { commitCustomEdit() }
        }
    }

    /// Lengths started lately, newest first. Kept laid out while empty so
    /// the first one appearing doesn't move the presets.
    private var recentRow: some View {
        HStack(spacing: 6) {
            if !recentSeconds.isEmpty {
                Text("Recents:")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.gray)
                ForEach(recentSeconds, id: \.self) { seconds in
                    durationChip(seconds: seconds)
                }
            }
        }
        .frame(height: 18)
        .help("Recent timers")
    }

    // MARK: - Laps

    private var lapRow: some View {
        let durations = TimerManager.lapDurations(timer.laps)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(durations.enumerated()), id: \.offset) { index, duration in
                    HStack(spacing: 4) {
                        Text("Lap \(durations.count - index)")
                            .foregroundStyle(.gray)
                        Text(TimerManager.clockString(from: duration)
                             + "." + TimerManager.centisecondsString(from: duration))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                    }
                    .modifier(ChipStyle(isSelected: index == 0))
                }
            }
        }
        // A sideways scroll here is for the laps, not for switching tabs.
        .onHover { vm.isHoveringCalendar = $0 }
        .onDisappear { vm.isHoveringCalendar = false }
    }

    @ViewBuilder
    private var customLabel: some View {
        let atCustomValue = timer.targetDuration == TimeInterval(customSeconds)
        // Highlight stays off when the value is also a preset, so two chips
        // never light up at once — but that has no bearing on what a tap does.
        let isSelected = atCustomValue && !TimerLength.isPreset(customSeconds)
        Group {
            if isEditingCustom {
                // Starts empty with the current length as a placeholder, so
                // typing replaces it instead of appending to it.
                TextField("", text: $customText, prompt: Text(TimerManager.clockString(from: TimeInterval(customSeconds))))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .frame(width: Self.customChipContentWidth)
                    .foregroundStyle(.white)
                    .focused($customFieldFocused)
                    .onSubmit(commitCustomEdit)
                    .onExitCommand(perform: endCustomEdit)
                    .onChange(of: customText) { _, text in
                        let digits = String(text.filter(\.isNumber).drop(while: { $0 == "0" }).prefix(5))
                        let formatted = digits.isEmpty ? "" : TimerLength.typedText(fromDigits: digits)
                        if formatted != text { customText = formatted }
                    }
                    .onChange(of: customFieldFocused) { _, focused in
                        if !focused && isEditingCustom { commitCustomEdit() }
                    }
            } else {
                // First tap picks it like any preset; a tap while it's
                // already picked opens it for typing.
                Button {
                    if atCustomValue {
                        beginCustomEdit()
                    } else {
                        timer.pickLength(TimeInterval(customSeconds))
                    }
                } label: {
                    Text(TimerLength.label(customSeconds))
                        .foregroundStyle(isSelected ? .white : .gray)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(width: Self.customChipContentWidth)
                }
                .buttonStyle(.plain)
            }
        }
        .modifier(ChipStyle(isSelected: isSelected || isEditingCustom))
    }

    /// Steps from whatever is selected — a preset included — and the result
    /// becomes the custom value, so the custom slot keeps its own number
    /// until the arrows or typing actually change it.
    private func stepCustom(up: Bool) {
        let next = TimerLength.stepped(Int(timer.targetDuration), up: up)
        customSeconds = next
        timer.pickLength(TimeInterval(next))
    }

    private func beginCustomEdit() {
        customText = ""
        NotchKeyboardFocus.begin()
        isEditingCustom = true
        DispatchQueue.main.async { customFieldFocused = true }
    }

    private func commitCustomEdit() {
        let digits = customText.filter(\.isNumber)
        if !digits.isEmpty {
            customSeconds = min(max(TimerLength.seconds(fromDigits: digits), 1), TimerLength.maxSeconds)
            // Same value as before still counts as picking it.
            timer.pickLength(TimeInterval(customSeconds))
        }
        endCustomEdit()
    }

    private func endCustomEdit() {
        isEditingCustom = false
        customFieldFocused = false
        NotchKeyboardFocus.end()
    }

    private func durationChip(seconds: Int) -> some View {
        let isSelected = timer.targetDuration == TimeInterval(seconds)
        return Button {
            // Picking a paused or finished timer's length again starts it
            // over; otherwise it sets up a new timer of that length.
            withAnimation(.smooth) { timer.pickLength(TimeInterval(seconds)) }
        } label: {
            Text(TimerLength.label(seconds))
                .foregroundStyle(isSelected ? .white : .gray)
                .modifier(ChipStyle(isSelected: isSelected))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Running timers

    /// Every countdown, each with its time left. Clicking one shows it in
    /// the ring, where play, stop and reset act on it.
    private var countdownList: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !timer.isAnythingRunning)) { timeline in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(timer.countdowns) { countdown in
                        countdownRow(countdown, at: timeline.date)
                    }
                }
            }
        }
        .frame(width: Self.countdownListWidth, height: Self.readoutSlotHeight)
        // A vertical scroll here is for the list, not for closing the notch.
        .onHover { vm.isHoveringCalendar = $0 }
        .onDisappear { vm.isHoveringCalendar = false }
    }

    private func countdownRow(_ countdown: Countdown, at date: Date) -> some View {
        let isSelected = countdown.id == timer.selectedCountdownID
        let icon = countdown.isFinished ? "bell.fill" : countdown.isRunning ? "timer" : "pause.fill"
        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
            Text(TimerManager.clockString(from: countdown.remainingForDisplay(at: date)))
                .monospacedDigit()
            Spacer(minLength: 0)
            Button {
                withAnimation(.smooth) { timer.removeCountdown(countdown.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Remove timer")
        }
        .foregroundStyle(countdown.isFinished ? .red : isSelected ? .white : .gray)
        .modifier(ChipStyle(isSelected: isSelected))
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation(.smooth) { timer.selectCountdown(countdown.id) }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 14) {
            // A running stopwatch can't be cancelled, so the same spot laps it.
            if showsLapButton {
                Button(action: timer.lap) {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color(nsColor: .secondarySystemFill)))
                }
                .buttonStyle(.plain)
                .help("Lap")
            } else {
                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color(nsColor: .secondarySystemFill)))
                }
                .buttonStyle(.plain)
                .help("Cancel")
                .disabled(!canCancel)
                .opacity(canCancel ? 1 : 0.4)
            }

            // One button: pauses what's running, otherwise plays.
            Button(action: timer.isRunning ? timer.pause : startTimer) {
                Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.effectiveAccent))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(timer.isRunning ? "Pause" : "Play")
            .disabled(!canPlayOrPause)
            .opacity(canPlayOrPause ? 1 : 0.4)

            // Always laid out, so it appearing doesn't shift the buttons.
            Button {
                withAnimation(.smooth) { timer.undoReset() }
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color(nsColor: .secondarySystemFill)))
            }
            .buttonStyle(.plain)
            .help("Undo")
            .opacity(timer.canUndoReset ? 1 : 0)
            .allowsHitTesting(timer.canUndoReset)
            .animation(.smooth, value: timer.canUndoReset)
        }
    }

    private func startTimer() {
        // Otherwise a length still being typed is committed after the timer
        // is already running, and quietly dropped.
        if isEditingCustom { commitCustomEdit() }
        if timer.mode == .countdown { recordRecent() }
        timer.start()
    }

    /// Newest first, one entry per length, and capped so the row never
    /// outgrows the tab.
    private func recordRecent() {
        guard timer.canStart else { return }
        let seconds = max(1, Int(timer.targetDuration))
        recentSeconds = Array(([seconds] + recentSeconds.filter { $0 != seconds }).prefix(maxRecentCount))
    }

    /// A countdown is removed; the stopwatch goes back to zero. Undoable.
    private func cancel() {
        withAnimation(.smooth) {
            if timer.mode == .countdown, let selected = timer.selectedCountdown {
                timer.removeCountdown(selected.id)
            } else {
                timer.reset()
            }
        }
    }

    // MARK: - Derived display state

    /// A timeline date can land a hair before the anchor it's measured
    /// from, which would read as slightly more than the full length (a
    /// flash of "5:01" on a 5:00 timer) — hence the clamps.
    private func displayedSeconds(at date: Date) -> TimeInterval {
        timer.mode == .countdown
            ? ceil(min(timer.currentLength, timer.remaining(at: date)))
            : max(0, timer.elapsed(at: date))
    }

    private func ringProgress(at date: Date) -> Double {
        guard timer.currentLength > 0 else { return 0 }
        return max(0, min(1, timer.remaining(at: date) / timer.currentLength))
    }

    private var ringColor: Color {
        timer.isFinished ? .red : .effectiveAccent
    }

    private var canCancel: Bool {
        timer.mode == .countdown
            ? timer.selectedCountdown != nil
            : !timer.isRunning && timer.elapsed(at: timer.now) > 0
    }

    private var canPlayOrPause: Bool {
        timer.isRunning || timer.canStart
    }

    private var showsLapButton: Bool {
        timer.mode == .stopwatch && timer.isRunning
    }

    /// Stays up while timers run: picking a length then starts another.
    private var showsPresetRow: Bool {
        timer.mode == .countdown
    }
}

/// The countdown ring. A round cap overhangs the end of its arc by half the
/// line width on both ends, so a plain trim reads a few percent past its
/// real value (50% looks like ~52%). Pulling each end in by that overhang
/// makes the visible arc exactly `progress` of the circle.
private struct TimerRing: View {
    let progress: Double
    let color: Color
    private static let lineWidth: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let diameter = min(geo.size.width, geo.size.height)
            let overhang = Self.lineWidth / 2 / (.pi * diameter)
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: Self.lineWidth)
                if progress > 2 * overhang {
                    Circle()
                        .trim(from: overhang, to: progress - overhang)
                        .stroke(color, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
        }
    }
}

/// One size for every duration chip — presets and the custom one — whether
/// it holds a label or a text field.
private struct ChipStyle: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .frame(height: 18)
            .background(
                Capsule().fill(isSelected
                    ? Color.effectiveAccent.opacity(0.35)
                    : Color(nsColor: .secondarySystemFill).opacity(0.5))
            )
    }
}

#Preview {
    TimerTabView()
        .environmentObject(BoringViewModel())
        .frame(width: 360, height: 220)
        .background(.black)
}
