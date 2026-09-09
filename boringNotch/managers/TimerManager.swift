//
//  TimerManager.swift
//  boringNotch
//
//  A stopwatch and a countdown timer sharing one anchor-based engine, the
//  same idiom MusicManager already uses for playback position: a start
//  date plus banked elapsed time, extrapolated against `now` rather than
//  incremented tick by tick. That's what lets it survive sleep/wake and an
//  app relaunch without a special case for either.
//

import AppKit
import Combine
import Defaults

@MainActor
final class TimerManager: ObservableObject {
    static let shared = TimerManager()

    @Published private(set) var mode: TimerMode
    @Published private(set) var isRunning: Bool
    @Published private(set) var targetDuration: TimeInterval

    /// Ticks once a second while running, purely to drive UI redraws.
    /// Nothing derives from the tick count itself — `elapsed(at:)` and
    /// `remaining(at:)` always recompute from `anchorDate`, so a missed or
    /// delayed tick can never cause drift.
    @Published private(set) var now: Date = .now

    /// A timestamp rather than a `Bool` so that finishing a second time
    /// after a reset is still a change `.onChange` can observe.
    @Published private(set) var justFinished: Date?

    private var anchorDate: Date?
    private var accumulated: TimeInterval
    private var tickTask: Task<Void, Never>?

    private init() {
        mode = Defaults[.timerMode]
        targetDuration = Defaults[.timerTargetDuration]
        accumulated = Defaults[.timerAccumulated]
        anchorDate = Defaults[.timerAnchorDate]
        isRunning = Defaults[.timerIsRunning] && anchorDate != nil

        if isRunning {
            startTicking()
            checkCountdownCompletion(at: .now)
        }
    }

    deinit {
        tickTask?.cancel()
    }

    // MARK: - Reading

    func elapsed(at date: Date) -> TimeInterval {
        accumulated + (anchorDate.map { date.timeIntervalSince($0) } ?? 0)
    }

    /// Countdown only — meaningless for a stopwatch, which has no target.
    func remaining(at date: Date) -> TimeInterval {
        max(0, targetDuration - elapsed(at: date))
    }

    // MARK: - Controls

    func setMode(_ newMode: TimerMode) {
        guard newMode != mode else { return }
        reset()
        mode = newMode
        Defaults[.timerMode] = newMode
    }

    func setTargetDuration(_ duration: TimeInterval) {
        guard !isRunning else { return }
        targetDuration = duration
        Defaults[.timerTargetDuration] = duration
    }

    func start() {
        guard !isRunning else { return }
        anchorDate = .now
        now = anchorDate!
        isRunning = true
        justFinished = nil
        persist()
        startTicking()
    }

    func pause() {
        guard isRunning, let anchorDate else { return }
        accumulated += Date.now.timeIntervalSince(anchorDate)
        self.anchorDate = nil
        isRunning = false
        persist()
        tickTask?.cancel()
    }

    func reset() {
        anchorDate = nil
        accumulated = 0
        isRunning = false
        justFinished = nil
        persist()
        tickTask?.cancel()
        now = .now
    }

    // MARK: - Ticking

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.now = .now
                self.checkCountdownCompletion(at: self.now)
            }
        }
    }

    private func checkCountdownCompletion(at date: Date) {
        guard mode == .countdown, isRunning, remaining(at: date) <= 0 else { return }
        justFinished = date
        NSSound(named: "Glass")?.play()
        pause()
    }

    private func persist() {
        Defaults[.timerIsRunning] = isRunning
        Defaults[.timerAnchorDate] = anchorDate
        Defaults[.timerAccumulated] = accumulated
    }

    /// Shared by the closed-notch live activity and the tab's own readout,
    /// so the two can never format the same value differently.
    static func clockString(from seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let totalMinutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            return String(format: "%d:%02d", minutes, remainingSeconds)
        }
    }
}
