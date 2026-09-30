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

struct TimerTabView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var timer = TimerManager.shared
    @Default(.timerCustomMinutes) private var customMinutes
    @State private var finishedPulse = false
    @State private var isEditingCustom = false
    @State private var customText = ""
    @FocusState private var customFieldFocused: Bool

    /// The readout's slot, ring or no ring. Fixed so switching modes can't
    /// change the row's height, and sized so the tab as a whole fits the
    /// same space Home, Shelf and Clipboard are given.
    private static let readoutSlotHeight: CGFloat = 88
    /// Fits "180m", so the custom chip is the same width showing or editing.
    private static let customChipContentWidth: CGFloat = 26

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
                ZStack {
                    if timer.mode == .countdown {
                        CircularProgressView(progress: ringProgress, color: ringColor)
                            .frame(width: Self.readoutSlotHeight, height: Self.readoutSlotHeight)
                    }

                    readout
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

    private var readout: some View {
        HStack(alignment: .lastTextBaseline, spacing: 1) {
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
                presetChip(minutes: minutes)
            }
            HStack(spacing: 2) {
                customLabel
                Stepper("", value: stepperMinutes, in: 1...180)
                    .labelsHidden()
                    .fixedSize()
            }
            .onChange(of: customMinutes) { _, minutes in
                if isEditingCustom { customText = "\(minutes)" }
            }
        }
        .onDisappear {
            if isEditingCustom { commitCustomEdit() }
        }
    }

    @ViewBuilder
    private var customLabel: some View {
        let isSelected = timer.targetDuration == TimeInterval(customMinutes * 60)
            && !presetMinutes.contains(customMinutes)
        Group {
            if isEditingCustom {
                HStack(spacing: 0) {
                    TextField("", text: $customText)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 22)
                        .focused($customFieldFocused)
                        .onSubmit(commitCustomEdit)
                        .onExitCommand(perform: endCustomEdit)
                        .onChange(of: customText) { _, text in
                            let digits = String(text.filter(\.isNumber).prefix(3))
                            if digits != text { customText = digits }
                        }
                        .onChange(of: customFieldFocused) { _, focused in
                            if !focused && isEditingCustom { commitCustomEdit() }
                        }
                    Text("m")
                }
                .frame(width: Self.customChipContentWidth)
                .foregroundStyle(.white)
            } else {
                // First tap picks it like any preset; a tap while it's
                // already picked opens it for typing.
                Button {
                    if isSelected {
                        beginCustomEdit()
                    } else {
                        timer.setTargetDuration(TimeInterval(customMinutes * 60))
                    }
                } label: {
                    Text("\(customMinutes)m")
                        .foregroundStyle(isSelected ? .white : .gray)
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
    private var stepperMinutes: Binding<Int> {
        Binding(
            get: { max(1, Int(timer.targetDuration / 60)) },
            set: { minutes in
                customMinutes = minutes
                timer.setTargetDuration(TimeInterval(minutes * 60))
            }
        )
    }

    private func beginCustomEdit() {
        customText = "\(customMinutes)"
        NotchKeyboardFocus.begin()
        isEditingCustom = true
        DispatchQueue.main.async { customFieldFocused = true }
    }

    private func commitCustomEdit() {
        if let value = Int(customText) {
            customMinutes = min(max(value, 1), 180)
            // Same value as before still counts as picking it.
            timer.setTargetDuration(TimeInterval(customMinutes * 60))
        }
        endCustomEdit()
    }

    private func endCustomEdit() {
        isEditingCustom = false
        customFieldFocused = false
        NotchKeyboardFocus.end()
    }

    private func presetChip(minutes: Int) -> some View {
        let isSelected = timer.targetDuration == TimeInterval(minutes * 60)
        return Button {
            timer.setTargetDuration(TimeInterval(minutes * 60))
        } label: {
            Text("\(minutes)m")
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

            Button(action: timer.start) {
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

    private func reset() {
        withAnimation(.smooth) {
            timer.reset()
        }
    }

    // MARK: - Derived display state

    private var displayedSeconds: TimeInterval {
        timer.mode == .countdown
            ? timer.remainingForDisplay(at: timer.now)
            : timer.elapsed(at: timer.now)
    }

    private var ringProgress: Double {
        guard timer.targetDuration > 0 else { return 0 }
        return max(0, min(1, timer.remaining(at: timer.now) / timer.targetDuration))
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
