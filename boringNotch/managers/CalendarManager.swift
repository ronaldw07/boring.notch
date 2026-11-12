//
//  CalendarManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import AppKit
import Defaults
import EventKit
import SwiftUI

// MARK: - CalendarManager

@MainActor
class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published var currentWeekStartDate: Date
    @Published var events: [EventModel] = []
    @Published var allCalendars: [CalendarModel] = []
    @Published var eventCalendars: [CalendarModel] = []
    @Published var reminderLists: [CalendarModel] = []
    @Published var selectedCalendarIDs: Set<String> = []
    @Published var calendarAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var reminderAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    private var selectedCalendars: [CalendarModel] = []
    private let calendarService = CalendarService()

    private var eventStoreChangedObserver: NSObjectProtocol?

    /// How often the open notch asks macOS to pull from Google and re-reads.
    private static let liveRefreshInterval: Duration = .seconds(3)
    /// Each calendar view on screen holds one, so the loop runs only while
    /// at least one is visible — nothing polls with the notch closed.
    private var liveRefreshHolders = 0
    private var liveRefreshTask: Task<Void, Never>?

    // MARK: Undo

    /// A change made in the Calendar tab that can still be taken back.
    private enum Change {
        /// Moved or resized; `nowStart` is where the occurrence sits now.
        case moved(id: String, nowStart: Date, oldStart: Date, oldEnd: Date)
        /// Hidden from view, deleted from the calendar when the window closes.
        case deleted(PendingDeletion)
    }

    /// What the newest change did, e.g. "Moved to 4:00 PM", shown with an
    /// Undo button; nil when there's nothing to take back. Changes stay
    /// undoable, newest first, for as long as the Calendar tab stays open.
    @Published private(set) var undoMessage: String?
    /// Shown briefly when an undo couldn't be carried out.
    @Published private(set) var undoFailed = false
    private var undoStack: [(change: Change, message: String)] = []
    /// Deletes that aren't done yet; their events stay off the timeline.
    private var hiddenDeletions: [PendingDeletion] = []
    private var undoFailedReset: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?
    private static let undoFailedDisplay: Duration = .seconds(3)

    private init() {
        self.currentWeekStartDate = CalendarManager.startOfDay(Date())
        setupEventStoreChangedObserver()
        // Deletes still waiting on the undo window happen before Chora quits
        // (including an update relaunch), so a delete is never lost.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeUndoWindow() }
        }
        Task {
            await reloadCalendarAndReminderLists()
        }
    }

    deinit {
        if let observer = eventStoreChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = terminateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupEventStoreChangedObserver() {
        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.reloadCalendarAndReminderLists()
                // The notification means the store's contents changed, not
                // just which calendars exist. Without this the events on
                // screen stay stale until something else happens to refetch.
                await self.updateEvents()
            }
        }
    }

    @MainActor
    func reloadCalendarAndReminderLists() async {
        let all = await calendarService.calendars()
        self.eventCalendars = all.filter { !$0.isReminder }
        self.reminderLists = all.filter { $0.isReminder }
        self.allCalendars = all // for legacy compatibility, can be removed if not needed
        updateSelectedCalendars()
    }

    func checkCalendarAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        DispatchQueue.main.async {
            print("📅 Current calendar authorization status: \(status)")
            self.calendarAuthorizationStatus = status
        }

        switch status {
        case .notDetermined:
            guard let granted = try? await calendarService.requestAccess(to: .event) else {
                self.calendarAuthorizationStatus = .notDetermined
                return
            }
            self.calendarAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
                events = visible(await calendarService.events(
                    from: currentWeekStartDate,
                    to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
                    calendars: selectedCalendars.map { $0.id }))
            }
        case .restricted, .denied:
            NSLog("Calendar access denied or restricted")
        case .fullAccess:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
            events = visible(await calendarService.events(
                from: currentWeekStartDate,
                to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
                calendars: selectedCalendars.map { $0.id }))
        case .writeOnly:
            NSLog("Write only")
        @unknown default:
            print("Unknown authorization status")
        }
    }
    
    /// Run each time the Calendar tab opens. Asks for access while macOS
    /// still will (it shows its popup only until answered once); after a
    /// denial the popup can't come back, so point at System Settings instead.
    func requestAccessForTab() async {
        await checkCalendarAuthorization()
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .denied || status == .restricted else { return }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Calendar Access Required"
        alert.informativeText = "Allow Chora to read your calendars in System Settings to see your events."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }

        NSApp.setActivationPolicy(.accessory)
        NSApp.deactivate()
    }

    func checkReminderAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        DispatchQueue.main.async {
            print("📅 Current reminder authorization status: \(status)")
            self.reminderAuthorizationStatus = status
        }

        switch status {
        case .notDetermined:
            guard let granted = try? await calendarService.requestAccess(to: .reminder) else {
                self.reminderAuthorizationStatus = .notDetermined
                return
            }
            self.reminderAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
            }
        case .restricted, .denied:
            NSLog("Reminder access denied or restricted")
        case .fullAccess:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
        case .writeOnly:
            NSLog("Write only")
        @unknown default:
            print("Unknown authorization status")
        }
    }
        

    func updateSelectedCalendars() {
        // Populate selectedCalendarIDs based on Defaults calendar selection state
        switch Defaults[.calendarSelectionState] {
        case .all:
            selectedCalendarIDs = Set(allCalendars.map { $0.id })
        case .selected(let identifiers):
            selectedCalendarIDs = identifiers
        }

        // Update the local calendar objects that correspond to the selected ids
        selectedCalendars = allCalendars.filter { selectedCalendarIDs.contains($0.id) }
    }

    func getCalendarSelected(_ calendar: CalendarModel) -> Bool {
        return selectedCalendarIDs.contains(calendar.id)
    }

    func setCalendarSelected(_ calendar: CalendarModel, isSelected: Bool) async {
        var selectionState = Defaults[.calendarSelectionState]

        switch selectionState {
        case .all:
            if !isSelected {
                let identifiers = Set(allCalendars.map { $0.id }).subtracting([calendar.id])
                selectionState = .selected(identifiers)
            }

        case .selected(var identifiers):
            if isSelected {
                identifiers.insert(calendar.id)
            } else {
                identifiers.remove(calendar.id)
            }

            selectionState =
                identifiers.isEmpty
                ? .all : identifiers.count == allCalendars.count ? .all : .selected(identifiers)  // if empty, select all
        }

        Defaults[.calendarSelectionState] = selectionState
        updateSelectedCalendars()
        await updateEvents()
    }

    static func startOfDay(_ date: Date) -> Date {
        return Calendar.current.startOfDay(for: date)
    }

    func beginLiveRefresh() {
        liveRefreshHolders += 1
        guard liveRefreshTask == nil else { return }
        liveRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.calendarService.pullRemoteChanges()
                await self.updateEvents()
                try? await Task.sleep(for: Self.liveRefreshInterval)
            }
        }
    }

    func endLiveRefresh() {
        liveRefreshHolders = max(0, liveRefreshHolders - 1)
        guard liveRefreshHolders == 0 else { return }
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
    }

    /// Moves or resizes an event, then reloads so the screen shows what the
    /// calendar actually holds.
    func moveEvent(_ event: EventModel, to start: Date, end: Date) async -> Bool {
        let moved = await calendarService.moveEvent(id: event.id, originalStart: event.start, to: start, end: end)
        if moved {
            remember(.moved(id: event.id, nowStart: start, oldStart: event.start, oldEnd: event.end),
                     message: Self.describeMove(from: (event.start, event.end), to: (start, end)))
        }
        await updateEvents()
        return moved
    }

    /// Takes the event off the timeline at once, but only deletes it from
    /// the calendar when the tab closes, so undo just cancels it.
    /// Re-creating a deleted event instead would lose its guests, its link
    /// to an invite, and its place in a repeating series.
    func deleteEvent(_ event: EventModel, scope: EventDeletionScope) async -> Bool {
        // Checked now, so a read-only calendar still says so on the spot
        // rather than the event quietly coming back eight seconds later.
        guard calendarService.canEdit(id: event.id, originalStart: event.start) else { return false }
        let pending = PendingDeletion(token: UUID(), id: event.id, originalStart: event.start, scope: scope)
        hiddenDeletions.append(pending)
        remember(.deleted(pending), message: "Deleted \(event.title)")
        events = visible(events)
        return true
    }

    /// Takes back the newest change.
    func undoLastChange() async {
        guard let change = undoStack.popLast()?.change else { return }
        undoMessage = undoStack.last?.message
        switch change {
        case .moved(let id, let nowStart, let oldStart, let oldEnd):
            let restored = await calendarService.moveEvent(id: id, originalStart: nowStart, to: oldStart, end: oldEnd)
            if !restored { showUndoFailed() }
        case .deleted(let pending):
            hiddenDeletions.removeAll { $0.token == pending.token }
        }
        await updateEvents()
    }

    /// Ends the chance to undo: waiting deletes are carried out now and the
    /// list clears. Runs when the Calendar tab closes (leaving the tab or
    /// closing the notch) or Chora quits.
    func closeUndoWindow() {
        let pending = undoStack.compactMap { entry -> PendingDeletion? in
            if case .deleted(let deletion) = entry.change { return deletion }
            return nil
        }
        undoStack.removeAll()
        undoMessage = nil
        for deletion in pending where !calendarService.deleteEventNow(
            id: deletion.id, originalStart: deletion.originalStart, scope: deletion.scope
        ) {
            NSLog("CalendarManager: a delete couldn't be carried out; the event stays")
        }
        hiddenDeletions.removeAll()
        guard !pending.isEmpty else { return }
        Task { await updateEvents() }
    }

    private func remember(_ change: Change, message: String) {
        undoStack.append((change, message))
        undoMessage = message
    }

    /// "Moved to 4:00 PM" when the length stayed the same (a drag), else
    /// "Now 3:30 – 5:30 PM" (a resize).
    static func describeMove(from old: (start: Date, end: Date), to new: (start: Date, end: Date)) -> String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        let sameLength = abs(new.end.timeIntervalSince(new.start) - old.end.timeIntervalSince(old.start)) < 1
        if sameLength {
            return "Moved to \(new.start.formatted(time))"
        }
        return "Now \(new.start.formatted(time)) – \(new.end.formatted(time))"
    }

    private func showUndoFailed() {
        undoFailed = true
        undoFailedReset?.cancel()
        undoFailedReset = Task { [weak self] in
            try? await Task.sleep(for: Self.undoFailedDisplay)
            guard !Task.isCancelled else { return }
            self?.undoFailed = false
        }
    }

    /// Everything except occurrences a waiting delete is about to take.
    private func visible(_ list: [EventModel]) -> [EventModel] {
        guard !hiddenDeletions.isEmpty else { return list }
        return list.filter { event in
            !hiddenDeletions.contains { $0.covers(id: event.id, start: event.start) }
        }
    }

    func updateCurrentDate(_ date: Date) async {
        currentWeekStartDate = Calendar.current.startOfDay(for: date)
        await updateEvents()
    }

    private func updateEvents() async {
        // The calendar list loads asynchronously from init and can still be
        // in flight the first time this runs (e.g. the view appearing
        // before it resolves) — fetching against an empty list silently
        // returns no events. The old periodic poll used to paper over this
        // by retrying a few seconds later; fixing the actual race instead.
        if allCalendars.isEmpty {
            await reloadCalendarAndReminderLists()
        }
        let calendarIDs = selectedCalendars.map { $0.id }
        let eventsResult = await calendarService.events(
            from: currentWeekStartDate,
            to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
            calendars: calendarIDs
        )
        let shown = visible(eventsResult)
        if shown != events {
            events = shown
        }
    }
    
    func setReminderCompleted(reminderID: String, completed: Bool) async {
        await calendarService.setReminderCompleted(reminderID: reminderID, completed: completed)
        // Refresh events after updating
        events = visible(await calendarService.events(
            from: currentWeekStartDate,
            to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
            calendars: selectedCalendars.map { $0.id }))
    }
}
