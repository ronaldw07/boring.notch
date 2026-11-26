//
//  TimerManager.swift
//  boringNotch
//
//  A stopwatch and any number of countdowns (up to `maxCountdowns`), all on
//  the same anchor-based idiom MusicManager already uses for playback
//  position: a start date plus banked elapsed time, extrapolated against
//  `now` rather than incremented tick by tick. That's what lets them survive
//  sleep/wake and an app relaunch without a special case for either.
//  Modified by Ronald Wen — fixed the countdown skipping 4:59 and restarting a finished countdown
//

import AppKit
import Combine
import Defaults

// MARK: - Countdown

/// One countdown. A value type: every change makes a new copy.
struct Countdown: Codable, Equatable, Identifiable, Defaults.Serializable {
    let id: UUID
    let length: TimeInterval
    let anchorDate: Date?
    let accumulated: TimeInterval
    let finishedAt: Date?

    init(id: UUID = UUID(), length: TimeInterval, anchorDate: Date? = nil,
         accumulated: TimeInterval = 0, finishedAt: Date? = nil) {
        self.id = id
        self.length = length
        self.anchorDate = anchorDate
        self.accumulated = accumulated
        self.finishedAt = finishedAt
    }

    var isRunning: Bool { anchorDate != nil }
    var isFinished: Bool { finishedAt != nil }

    func elapsed(at date: Date) -> TimeInterval {
        accumulated + (anchorDate.map { date.timeIntervalSince($0) } ?? 0)
    }

    func remaining(at date: Date) -> TimeInterval {
        max(0, length - elapsed(at: date))
    }

    /// Rounded up, because a 5:00 timer holds exactly 300.000s only at the
    /// instant it starts: every tick after that lands a hair past its second
    /// boundary, so flooring showed 298.99 as "4:58" and 4:59 looked skipped.
    /// Rounding up gives every value its own full second on screen, and still
    /// lands on "0:00" exactly when the time is actually up.
    func remainingForDisplay(at date: Date) -> TimeInterval {
        ceil(remaining(at: date))
    }

    /// A spent countdown starts over rather than finishing again at once.
    func started(at date: Date) -> Countdown {
        let banked = remaining(at: date) <= 0 ? 0 : accumulated
        return Countdown(id: id, length: length, anchorDate: date, accumulated: banked)
    }

    func paused(at date: Date) -> Countdown {
        Countdown(id: id, length: length, accumulated: elapsed(at: date), finishedAt: finishedAt)
    }

    func finished(at date: Date) -> Countdown {
        Countdown(id: id, length: length, accumulated: length, finishedAt: date)
    }

    /// Back to the full length, still running if it was.
    func restarted(at date: Date) -> Countdown {
        Countdown(id: id, length: length, anchorDate: isRunning ? date : nil)
    }

    /// Puts back time a reset threw away.
    func restored(elapsed: TimeInterval, running: Bool, at date: Date) -> Countdown {
        Countdown(id: id, length: length, anchorDate: running ? date : nil, accumulated: elapsed)
    }
}

// MARK: - Manager

@MainActor
final class TimerManager: ObservableObject {
    static let shared = TimerManager()

    static let maxCountdowns = 5

    @Published private(set) var mode: TimerMode
    /// The length the next countdown will have, or the selected one's.
    @Published private(set) var targetDuration: TimeInterval
    @Published private(set) var countdowns: [Countdown]
    /// The countdown the tab's ring shows. Nil while picking a new one.
    @Published private(set) var selectedCountdownID: UUID?

    /// Ticks while anything runs, purely to drive UI redraws. Nothing derives
    /// from the tick count itself — elapsed and remaining time always
    /// recompute from anchors, so a missed or delayed tick can never drift.
    @Published private(set) var now: Date = .now

    /// A timestamp rather than a `Bool` so that finishing a second time
    /// after a reset is still a change `.onChange` can observe.
    @Published private(set) var justFinished: Date?

    /// True for a few seconds after a reset or removal, while `undoReset()`
    /// can still put it back.
    @Published private(set) var canUndoReset = false

    /// Stopwatch elapsed time at each lap, oldest first.
    @Published private(set) var laps: [TimeInterval]

    @Published private var stopwatchAnchor: Date?
    @Published private var stopwatchAccumulated: TimeInterval

    private var tickTask: Task<Void, Never>?

    /// What a reset, restart or removal threw away.
    private enum ResetUndo {
        case stopwatch(elapsed: TimeInterval, wasRunning: Bool, laps: [TimeInterval])
        case countdown(Countdown, elapsed: TimeInterval, wasRunning: Bool, index: Int, wasSelected: Bool)
    }

    private var resetUndo: ResetUndo?
    private var undoExpiry: Task<Void, Never>?
    private static let undoWindow: Duration = .seconds(8)
    private static let stopwatchTick: Duration = .milliseconds(30)

    private init() {
        let savedMode = Defaults[.timerMode]
        let savedTarget = Defaults[.timerTargetDuration]
        let savedCountdowns = Defaults[.timerCountdowns]
        let anchor = Defaults[.timerIsRunning] ? Defaults[.timerAnchorDate] : nil
        let accumulated = Defaults[.timerAccumulated]

        mode = savedMode
        targetDuration = savedTarget
        laps = Defaults[.timerLaps]

        // Before there could be several countdowns, the one countdown lived
        // in the same keys the stopwatch uses now. Carry it over once.
        if savedMode == .countdown, savedCountdowns.isEmpty, anchor != nil || accumulated > 0 {
            let carried = Countdown(length: savedTarget, anchorDate: anchor, accumulated: accumulated)
            countdowns = [carried]
            selectedCountdownID = carried.id
            stopwatchAnchor = nil
            stopwatchAccumulated = 0
        } else {
            countdowns = savedCountdowns
            selectedCountdownID = Defaults[.timerSelectedCountdown].flatMap(UUID.init(uuidString:))
            stopwatchAnchor = anchor
            stopwatchAccumulated = accumulated
        }
        persist()

        if isAnythingRunning {
            startTicking()
            checkCountdownCompletion(at: .now)
        }
    }

    deinit {
        tickTask?.cancel()
    }

    // MARK: - Reading (the current mode's timer)

    var selectedCountdown: Countdown? {
        countdowns.first { $0.id == selectedCountdownID }
    }

    var isRunning: Bool {
        mode == .stopwatch ? stopwatchAnchor != nil : selectedCountdown?.isRunning ?? false
    }

    /// The selected countdown has run out.
    var isFinished: Bool {
        mode == .countdown && selectedCountdown?.isFinished == true
    }

    func elapsed(at date: Date) -> TimeInterval {
        mode == .stopwatch
            ? stopwatchElapsed(at: date)
            : selectedCountdown?.elapsed(at: date) ?? 0
    }

    /// Countdown only — meaningless for a stopwatch, which has no target.
    func remaining(at date: Date) -> TimeInterval {
        selectedCountdown?.remaining(at: date) ?? targetDuration
    }

    /// The length of what the ring shows: the selected countdown, or the
    /// one about to be started.
    var currentLength: TimeInterval {
        selectedCountdown?.length ?? targetDuration
    }

    /// Play resumes a paused selected countdown of the picked length, or
    /// starts a new one if there's room.
    var canStart: Bool {
        guard mode == .countdown else { return stopwatchAnchor == nil }
        return resumable != nil || countdowns.count < Self.maxCountdowns
    }

    var isAnythingRunning: Bool {
        stopwatchAnchor != nil || countdowns.contains(where: \.isRunning)
    }

    /// What the closed notch shows: the countdown ending soonest, else the
    /// stopwatch, plus how many others are running.
    func closedReadout(at date: Date) -> (isStopwatch: Bool, seconds: TimeInterval, othersRunning: Int) {
        let running = countdowns.filter(\.isRunning).sorted { $0.remaining(at: date) < $1.remaining(at: date) }
        let stopwatchRunning = stopwatchAnchor != nil
        guard let soonest = running.first else {
            return (true, stopwatchElapsed(at: date), 0)
        }
        return (false, soonest.remainingForDisplay(at: date), running.count - 1 + (stopwatchRunning ? 1 : 0))
    }

    private func stopwatchElapsed(at date: Date) -> TimeInterval {
        stopwatchAccumulated + (stopwatchAnchor.map { date.timeIntervalSince($0) } ?? 0)
    }

    private var resumable: Countdown? {
        guard let selected = selectedCountdown, !selected.isRunning,
              selected.length == targetDuration else { return nil }
        return selected
    }

    // MARK: - Controls

    func setMode(_ newMode: TimerMode) {
        guard newMode != mode else { return }
        clearUndo()
        mode = newMode
        Defaults[.timerMode] = newMode
    }

    /// A length chip, the custom length or the arrows. Picking the length of
    /// a paused or finished selected countdown again starts it over; anything
    /// else sets up a new countdown, leaving the others where they are.
    func pickLength(_ duration: TimeInterval) {
        if let selected = selectedCountdown, !selected.isRunning, selected.length == duration {
            if selected.elapsed(at: .now) > 0 || selected.isFinished { restartCountdown() }
            return
        }
        if selectedCountdown != nil { selectedCountdownID = nil }
        targetDuration = duration
        Defaults[.timerTargetDuration] = duration
        justFinished = nil
        clearUndo()
        persist()
    }

    func selectCountdown(_ id: UUID) {
        guard let countdown = countdowns.first(where: { $0.id == id }) else { return }
        selectedCountdownID = id
        targetDuration = countdown.length
        Defaults[.timerTargetDuration] = countdown.length
        persist()
    }

    func start() {
        let date = Date.now
        clearUndo()
        justFinished = nil
        if mode == .stopwatch {
            guard stopwatchAnchor == nil else { return }
            stopwatchAnchor = date
        } else if let countdown = resumable {
            replace(countdown.started(at: date))
        } else {
            guard countdowns.count < Self.maxCountdowns else { return }
            let countdown = Countdown(length: targetDuration, anchorDate: date)
            countdowns = countdowns + [countdown]
            selectedCountdownID = countdown.id
        }
        now = date
        persist()
        startTicking()
    }

    func pause() {
        let date = Date.now
        clearUndo()
        if mode == .stopwatch {
            guard let anchor = stopwatchAnchor else { return }
            stopwatchAccumulated += date.timeIntervalSince(anchor)
            stopwatchAnchor = nil
        } else {
            guard let selected = selectedCountdown, selected.isRunning else { return }
            replace(selected.paused(at: date))
        }
        persist()
    }

    /// Stopwatch only: marks the time so far as a lap.
    func lap() {
        guard mode == .stopwatch, stopwatchAnchor != nil else { return }
        laps = laps + [stopwatchElapsed(at: .now)]
        persist()
    }

    /// The stopwatch time since the last lap.
    func currentLapElapsed(at date: Date) -> TimeInterval {
        max(0, stopwatchElapsed(at: date) - (laps.last ?? 0))
    }

    /// Each lap's own length, newest first.
    static func lapDurations(_ laps: [TimeInterval]) -> [TimeInterval] {
        zip(laps, [0] + laps).map { $0 - $1 }.reversed()
    }

    /// Back to zero (stopwatch) or the full length (selected countdown).
    func reset() {
        let date = Date.now
        justFinished = nil
        if mode == .stopwatch {
            rememberForUndo(.stopwatch(elapsed: stopwatchElapsed(at: date),
                                       wasRunning: stopwatchAnchor != nil, laps: laps))
            stopwatchAnchor = nil
            stopwatchAccumulated = 0
            laps = []
        } else {
            guard let selected = selectedCountdown else { return }
            rememberCountdownForUndo(selected, at: date)
            replace(Countdown(id: selected.id, length: selected.length))
        }
        persist()
    }

    /// The selected countdown back to its full length. A running one starts
    /// over and keeps running.
    func restartCountdown() {
        let date = Date.now
        guard let selected = selectedCountdown,
              selected.elapsed(at: date) > 0 || selected.isFinished else { return }
        rememberCountdownForUndo(selected, at: date)
        justFinished = nil
        replace(selected.restarted(at: date))
        now = date
        persist()
    }

    func removeCountdown(_ id: UUID) {
        guard let countdown = countdowns.first(where: { $0.id == id }) else { return }
        rememberCountdownForUndo(countdown, at: .now)
        countdowns = countdowns.filter { $0.id != id }
        if selectedCountdownID == id { selectedCountdownID = nil }
        if countdown.isFinished { justFinished = nil }
        persist()
    }

    /// Puts back what the last reset, restart or removal threw away.
    func undoReset() {
        guard let undo = resetUndo else { return }
        clearUndo()
        let date = Date.now
        switch undo {
        case let .stopwatch(elapsed, wasRunning, savedLaps):
            stopwatchAccumulated = elapsed
            stopwatchAnchor = wasRunning ? date : nil
            laps = savedLaps
        case let .countdown(countdown, elapsed, wasRunning, index, wasSelected):
            let restored = countdown.restored(elapsed: elapsed, running: wasRunning, at: date)
            if countdowns.contains(where: { $0.id == countdown.id }) {
                replace(restored)
            } else {
                var list = countdowns
                list.insert(restored, at: min(index, list.count))
                countdowns = list
            }
            if wasSelected { selectedCountdownID = countdown.id }
        }
        now = date
        persist()
        if isAnythingRunning { startTicking() }
    }

    private func replace(_ countdown: Countdown) {
        countdowns = countdowns.map { $0.id == countdown.id ? countdown : $0 }
    }

    private func rememberCountdownForUndo(_ countdown: Countdown, at date: Date) {
        rememberForUndo(.countdown(countdown,
                                   elapsed: countdown.elapsed(at: date),
                                   wasRunning: countdown.isRunning,
                                   index: countdowns.firstIndex(where: { $0.id == countdown.id }) ?? 0,
                                   wasSelected: selectedCountdownID == countdown.id))
    }

    private func rememberForUndo(_ undo: ResetUndo) {
        resetUndo = undo
        canUndoReset = true
        undoExpiry?.cancel()
        undoExpiry = Task { [weak self] in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            self?.clearUndo()
        }
    }

    private func clearUndo() {
        undoExpiry?.cancel()
        undoExpiry = nil
        resetUndo = nil
        if canUndoReset { canUndoReset = false }
    }

    // MARK: - Ticking

    /// A running stopwatch shows hundredths, which needs a fast cadence. A
    /// countdown ticks just after its displayed second changes, worked out
    /// from its anchor every time instead of a fixed second after the last
    /// tick — those drift later and later, leaving the display up to a second
    /// behind and the finish late. With several, the soonest change wins.
    private func nextTickDelay() -> Duration {
        if stopwatchAnchor != nil { return Self.stopwatchTick }
        let date = Date.now
        let waits = countdowns.filter(\.isRunning).map { countdown -> TimeInterval in
            let left = countdown.remaining(at: date)
            return left - max(0, ceil(left) - 1)
        }
        guard let soonest = waits.min() else { return .seconds(1) }
        return .seconds(max(0.001, soonest) + 0.002)
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isAnythingRunning else { return }
                try? await Task.sleep(for: self.nextTickDelay())
                guard !Task.isCancelled else { return }
                self.now = .now
                self.checkCountdownCompletion(at: self.now)
            }
        }
    }

    private func checkCountdownCompletion(at date: Date) {
        let done = countdowns.filter { $0.isRunning && $0.remaining(at: date) <= 0 }
        guard let last = done.last else { return }
        let doneIDs = Set(done.map(\.id))
        countdowns = countdowns.map { doneIDs.contains($0.id) ? $0.finished(at: date) : $0 }
        selectedCountdownID = last.id
        targetDuration = last.length
        Defaults[.timerTargetDuration] = last.length
        mode = .countdown
        Defaults[.timerMode] = .countdown
        justFinished = date
        clearUndo()
        NSSound(named: "Glass")?.play()
        persist()
    }

    private func persist() {
        Defaults[.timerIsRunning] = stopwatchAnchor != nil
        Defaults[.timerAnchorDate] = stopwatchAnchor
        Defaults[.timerAccumulated] = stopwatchAccumulated
        Defaults[.timerLaps] = laps
        Defaults[.timerCountdowns] = countdowns
        Defaults[.timerSelectedCountdown] = selectedCountdownID?.uuidString
    }

    // MARK: - Formatting

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
