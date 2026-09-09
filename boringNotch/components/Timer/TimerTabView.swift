//
//  TimerTabView.swift
//  boringNotch
//
//  A stopwatch and a countdown timer sharing one tab. Unlike the other
//  tabs, running state isn't reset by switching away — the whole point is
//  that it keeps going (and shows up in the closed notch) regardless of
//  what's currently open.
//

import SwiftUI

private let presetMinutes = [1, 5, 10, 25]

struct TimerTabView: View {
    @ObservedObject private var timer = TimerManager.shared
    @State private var customMinutes: Int = 5
    @State private var finishedPulse = false

    var body: some View {
        VStack(spacing: 10) {
            modePicker

            ZStack {
                if timer.mode == .countdown {
                    CircularProgressView(progress: ringProgress, color: ringColor)
                        .frame(width: 84, height: 84)
                }

                Text(TimerManager.clockString(from: displayedSeconds))
                    .font(.system(size: timer.mode == .countdown ? 20 : 28, weight: .semibold, design: .monospaced))
                    .foregroundStyle(timer.justFinished != nil ? .red : .white)
                    .contentTransition(.numericText())
            }
            .scaleEffect(finishedPulse ? 1.08 : 1.0)
            .padding(.top, 2)

            if timer.mode == .countdown && !timer.isRunning {
                presetRow
            }

            controls
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - Mode picker

    private var modePicker: some View {
        HStack(spacing: 4) {
            modeButton(title: "Stopwatch", mode: .stopwatch)
            modeButton(title: "Timer", mode: .countdown)
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
            Stepper(value: $customMinutes, in: 1...180) {
                Text("\(customMinutes)m")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.gray)
            }
            .fixedSize()
            .onChange(of: customMinutes) { _, minutes in
                timer.setTargetDuration(TimeInterval(minutes * 60))
            }
        }
        .onAppear {
            customMinutes = max(1, Int(timer.targetDuration / 60))
        }
    }

    private func presetChip(minutes: Int) -> some View {
        let isSelected = timer.targetDuration == TimeInterval(minutes * 60)
        return Button {
            timer.setTargetDuration(TimeInterval(minutes * 60))
        } label: {
            Text("\(minutes)m")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? .white : .gray)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(isSelected
                        ? Color.effectiveAccent.opacity(0.35)
                        : Color(nsColor: .secondarySystemFill).opacity(0.5))
                )
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

            Button(action: toggleRunning) {
                Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.effectiveAccent))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    private func toggleRunning() {
        if timer.isRunning {
            timer.pause()
        } else {
            timer.start()
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
            ? timer.remaining(at: timer.now)
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
}

#Preview {
    TimerTabView()
        .frame(width: 360, height: 220)
        .background(.black)
}
