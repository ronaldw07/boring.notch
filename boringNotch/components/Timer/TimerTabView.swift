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
                    presetRow
                        .opacity(showsPresetRow ? 1 : 0)
                        .allowsHitTesting(showsPresetRow)

                    controls
                }
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
        return HStack(alignment: .lastTextBaseline, spacing: 1) {
            Text(TimerManager.clockString(from: displayedSeconds))
                .font(.system(size: timer.mode == .countdown ? 20 : 28, weight: .semibold, design: .monospaced))

            if timer.mode == .stopwatch {
                Text(".\(TimerManager.centisecondsString(from: displayedSeconds))")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.gray)
            }
        }
        .foregroundStyle(timer.justFinished != nil ? .red : .white)
        .contentTransition(.numericText())
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

            if !recentSeconds.isEmpty {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.gray)
                    .padding(.leading, 4)
                ForEach(recentSeconds, id: \.self) { seconds in
                    durationChip(seconds: seconds)
                }
            }
        }
        .onDisappear {
            if isEditingCustom { commitCustomEdit() }
        }
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
                        timer.setTargetDuration(TimeInterval(customSeconds))
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
        timer.setTargetDuration(TimeInterval(next))
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
            timer.setTargetDuration(TimeInterval(customSeconds))
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
            timer.setTargetDuration(TimeInterval(seconds))
        } label: {
            Text(TimerLength.label(seconds))
                .foregroundStyle(isSelected ? .white : .gray)
                .modifier(ChipStyle(isSelected: isSelected))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 14) {
            Button(action: reset) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color(nsColor: .secondarySystemFill)))
            }
            .buttonStyle(.plain)
            .disabled(!canReset)
            .opacity(canReset ? 1 : 0.4)

            Button(action: startTimer) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.effectiveAccent))
            }
            .buttonStyle(.plain)
            .disabled(timer.isRunning)
            .opacity(timer.isRunning ? 0.4 : 1)

            Button(action: timer.pause) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.effectiveAccent))
            }
            .buttonStyle(.plain)
            .disabled(!timer.isRunning)
            .opacity(timer.isRunning ? 1 : 0.4)
        }
    }

    private func startTimer() {
        if timer.mode == .countdown { recordRecent() }
        timer.start()
    }

    /// Newest first, one entry per length, presets left out since they're
    /// already one tap away, and capped so the row never outgrows the tab.
    private func recordRecent() {
        guard !timer.isRunning else { return }
        let seconds = max(1, Int(timer.targetDuration))
        guard !TimerLength.isPreset(seconds) else { return }
        recentSeconds = Array(([seconds] + recentSeconds.filter { $0 != seconds }).prefix(4))
    }

    private func reset() {
        withAnimation(.smooth) {
            timer.reset()
        }
    }

    // MARK: - Derived display state

    /// A timeline date can land a hair before the anchor it's measured
    /// from, which would read as slightly more than the full length (a
    /// flash of "5:01" on a 5:00 timer) — hence the clamps.
    private func displayedSeconds(at date: Date) -> TimeInterval {
        timer.mode == .countdown
            ? ceil(min(timer.targetDuration, timer.remaining(at: date)))
            : max(0, timer.elapsed(at: date))
    }

    private func ringProgress(at date: Date) -> Double {
        guard timer.targetDuration > 0 else { return 0 }
        return max(0, min(1, timer.remaining(at: date) / timer.targetDuration))
    }

    private var ringColor: Color {
        timer.justFinished != nil ? .red : .effectiveAccent
    }

    private var canReset: Bool {
        !timer.isRunning && (timer.elapsed(at: timer.now) > 0 || timer.justFinished != nil)
    }

    private var showsPresetRow: Bool {
        timer.mode == .countdown && !timer.isRunning
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
