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

    /// What a countdown should *show*, as opposed to what it is.
    ///
    /// Rounded up, because a 5:00 timer holds exactly 300.000s only at the
    /// instant it starts: every tick after that lands a hair *past* its
    /// second boundary, so the first one reads 298.99 and flooring took it
    /// straight to "4:58". 4:59 was real for well under a millisecond, which
    /// is why it looked skipped. Rounding up gives every value its own full
    /// second on screen, and still lands on "0:00" exactly when the time is
    /// actually up.
    ///
    /// The stopwatch deliberately doesn't use this — it floors, to stay
    /// consistent with the hundredths shown next to it.
    func remainingForDisplay(at date: Date) -> TimeInterval {
        ceil(remaining(at: date))
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

        // A spent countdown has banked its entire duration, so starting it
        // again as-is would leave nothing remaining and completion would
        // fire on the very next tick — sound and all — without a second of
        // it ever running. Play on a finished timer means run it again.
        if mode == .countdown && remaining(at: .now) <= 0 {
            accumulated = 0
        }

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

    /// Countdown and the closed-notch widget only ever show whole seconds,
    /// so a 1s cadence is plenty. A running stopwatch shows hundredths
    /// (`centisecondsString`), which needs a much faster cadence to read as
    /// live-updating rather than stepping.
    private var tickInterval: Duration {
        mode == .stopwatch ? .milliseconds(30) : .seconds(1)
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: self.tickInterval)
                guard !Task.isCancelled else { return }
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
    /// so the two can never format the same value differently. Floors
    /// rather than rounds — paired with `centisecondsString` on the same
    /// value, rounding here would occasionally show e.g. "1:24" while the
    /// hundredths still read something under ".995", which reads as the two
    /// disagreeing with each other.
    static func clockString(from seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
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

    /// Two digits, floored to match `clockString`'s whole-second part.
    static func centisecondsString(from seconds: TimeInterval) -> String {
        let hundredths = Int((max(0, seconds) * 100).truncatingRemainder(dividingBy: 100))
        return String(format: "%02d", hundredths)
    }
}
