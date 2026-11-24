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
    /// How many days from `currentWeekStartDate` are loaded: one for a day,
    /// seven for a week, a month's grid for a month.
    private var loadedDayCount = 1
    @Published var events: [EventModel] = []
    @Published var allCalendars: [CalendarModel] = []
    @Published var eventCalendars: [CalendarModel] = []
    @Published var reminderLists: [CalendarModel] = []
    @Published var selectedCalendarIDs: Set<String> = []
    @Published var calendarAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var reminderAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    private var selectedCalendars: [CalendarModel] = []
    /// The calendars whose events are shown.
    var shownCalendars: [CalendarModel] { selectedCalendars }
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
        /// Moved, resized or edited; holds what it was before, and which
        /// occurrences the change covered so undo covers the same ones.
        case changed(ChangedOccurrence, previous: EventEdit, scope: EventScope)
        /// Hidden from view, deleted from the calendar when the window closes.
        case deleted(PendingDeletion)
        /// Added by typing; undo deletes it again.
        case created(id: String, start: Date)
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
    /// What each waiting delete took off the screen, by its token.
    private var hiddenEvents: [UUID: [EventModel]] = [:]
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
                    to: loadedEnd,
                    calendars: selectedCalendars.map { $0.id }))
            }
        case .restricted, .denied:
            NSLog("Calendar access denied or restricted")
        case .fullAccess:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
            events = visible(await calendarService.events(
                from: currentWeekStartDate,
                to: loadedEnd,
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
    func moveEvent(_ event: EventModel, to start: Date, end: Date, scope: EventScope = .thisEvent) async -> Bool {
        var edit = EventEdit(event)
        edit.start = start
        edit.end = end
        return await updateEvent(event, edit: edit, scope: scope)
    }

    /// The calendar a typed event goes into, for the preview line.
    var newEventCalendarTitle: String? { calendarService.newEventCalendarTitle }

    /// Where a new event goes unless another calendar is picked.
    var newEventCalendarID: String? { calendarService.newEventCalendarID }

    /// The event calendars a new event can go into.
    var editableEventCalendars: [CalendarModel] {
        let editable = calendarService.editableEventCalendarIDs
        return eventCalendars.filter { editable.contains($0.id) }
    }

    /// Adds an event made in the Calendar tab, with undo. Empty location or
    /// notes are left off.
    func createEvent(title: String, start: Date, end: Date,
                     calendarID: String? = nil, location: String? = nil, notes: String? = nil,
                     repeats: EventRepeat = .never, reminderMinutes: Int? = nil) async -> Bool {
        let location = location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = await calendarService.createEvent(
            title: title, start: start, end: end, calendarID: calendarID,
            location: location?.isEmpty == false ? location : nil,
            notes: notes?.isEmpty == false ? notes : nil,
            repeats: repeats,
            reminderMinutes: reminderMinutes,
            isAllDay: false
        ) else { return false }
        remember(.created(id: id, start: start), message: "Added \(title)")
        await updateEvents()
        return true
    }

    /// A one-off copy at the same time in the same calendar, with undo.
    /// Returns the copy, so its details can open in place of the original's.
    func duplicateEvent(_ event: EventModel) async -> EventModel? {
        guard let id = await calendarService.createEvent(
            title: event.title, start: event.start, end: event.end, calendarID: event.calendar.id,
            location: event.location, notes: event.notes,
            repeats: .never, reminderMinutes: nil, isAllDay: event.isAllDay
        ) else { return nil }
        remember(.created(id: id, start: event.start), message: "Duplicated \(event.title)")
        await updateEvents()
        return events.first { $0.id == id }
    }

    /// A one-off event from a copied one, with undo.
    func pasteEvent(_ copied: CopiedEvent, start: Date, end: Date) async -> Bool {
        guard let id = await calendarService.createEvent(
            // A copy from a read-only calendar goes into the default one.
            title: copied.title, start: start, end: end,
            calendarID: calendarService.editableEventCalendarIDs.contains(copied.calendarID) ? copied.calendarID : nil,
            location: copied.location, notes: copied.notes,
            repeats: .never, reminderMinutes: nil, isAllDay: copied.isAllDay
        ) else { return false }
        remember(.created(id: id, start: start), message: "Pasted \(copied.title)")
        await updateEvents()
        return true
    }

    /// Saves an edit from the details box or a drag, with undo.
    func updateEvent(_ event: EventModel, edit: EventEdit, scope: EventScope) async -> Bool {
        let previous = EventEdit(event)
        let changed = await calendarService.updateEvent(id: event.id, originalStart: event.start, edit: edit, scope: scope)
        if let changed {
            let message = edit.differsOnlyInTime(from: previous)
                ? Self.describeMove(from: (previous.start, previous.end), to: (edit.start, edit.end))
                : "Edited \(edit.title)"
            remember(.changed(changed, previous: previous, scope: scope), message: message)
        }
        await updateEvents()
        return changed != nil
    }

    /// Takes the event off the timeline at once, but only deletes it from
    /// the calendar when the tab closes, so undo just cancels it.
    /// Re-creating a deleted event instead would lose its guests, its link
    /// to an invite, and its place in a repeating series.
    func deleteEvent(_ event: EventModel, scope: EventScope) async -> Bool {
        // Checked now, so a read-only calendar still says so on the spot
        // rather than the event quietly coming back eight seconds later.
        guard calendarService.canEdit(id: event.id, originalStart: event.start) else { return false }
        let pending = PendingDeletion(token: UUID(), id: event.id, originalStart: event.start, scope: scope)
        hiddenDeletions.append(pending)
        // Kept so an undo can put them back on screen at once.
        hiddenEvents[pending.token] = events.filter { pending.covers(id: $0.id, start: $0.start) }
        remember(.deleted(pending), message: "Deleted \(event.title)\(Self.scopeNote(scope, repeats: event.hasRecurrenceRules))")
        events = visible(events)
        return true
    }

    /// " · this event", " · this and following", " · all events"; nothing for a one-off.
    private static func scopeNote(_ scope: EventScope, repeats: Bool) -> String {
        guard repeats else { return "" }
        switch scope {
        case .thisEvent: return " · this event"
        case .thisAndFollowing: return " · this and following"
        case .allEvents: return " · all events"
        }
    }

    /// Takes back the newest change.
    func undoLastChange() async {
        guard let change = undoStack.popLast()?.change else { return }
        undoMessage = undoStack.last?.message
        switch change {
        case .changed(let occurrence, let previous, let scope):
            let restored = await calendarService.updateEvent(id: occurrence.id, originalStart: occurrence.start, edit: previous, scope: scope)
            if restored == nil { showUndoFailed() }
        case .deleted(let pending):
            hiddenDeletions.removeAll { $0.token == pending.token }
            // Back on screen this instant; the refresh below only confirms it.
            if let restored = hiddenEvents.removeValue(forKey: pending.token) {
                events = (events + restored.filter { r in !events.contains { $0.id == r.id && $0.start == r.start } })
                    .sorted { $0.start < $1.start }
            }
            Task { await updateEvents() }
            return
        case .created(let id, let start):
            // From the first occurrence on: the whole series, if it repeats.
            let removed = calendarService.deleteEventNow(id: id, originalStart: start, scope: .thisAndFollowing)
            if !removed { showUndoFailed() }
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
        hiddenEvents.removeAll()
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
        await load(from: date, days: 1)
    }

    /// Loads `days` days starting at `start`, for the week and month views.
    func load(from start: Date, days: Int) async {
        currentWeekStartDate = Calendar.current.startOfDay(for: start)
        loadedDayCount = max(1, days)
        await updateEvents()
    }

    /// Events in the shown calendars between two moments, for the heads-up.
    func events(from start: Date, to end: Date) async -> [EventModel] {
        if allCalendars.isEmpty {
            await reloadCalendarAndReminderLists()
        }
        return visible(await calendarService.events(from: start, to: end, calendars: selectedCalendars.map(\.id)))
    }

    /// Events from a year back to a year ahead in the shown calendars, for
    /// search. Fetched once per search, then filtered as you type.
    func searchableEvents() async -> [EventModel] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let from = calendar.date(byAdding: .year, value: -1, to: today),
              let to = calendar.date(byAdding: .year, value: 1, to: today) else { return [] }
        return visible(await calendarService.events(from: from, to: to, calendars: selectedCalendars.map(\.id)))
    }

    private var loadedEnd: Date {
        Calendar.current.date(byAdding: .day, value: loadedDayCount, to: currentWeekStartDate)!
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
            to: loadedEnd,
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
            to: loadedEnd,
            calendars: selectedCalendars.map { $0.id }))
    }
}
