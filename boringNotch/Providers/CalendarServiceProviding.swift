//
//  CalendarServiceProvider.swift
//  Calendr
//
//  Created by Paker on 31/12/20.
//  Original source: Original source: https://github.com/pakerwreah/Calendr
//  Modified by Alexander on 08/06/25
//

import Foundation
@preconcurrency import EventKit

protocol CalendarServiceProviding {
    func requestAccess(to type: EKEntityType) async throws -> Bool
    func calendars() async -> [CalendarModel]
    func events(from start: Date, to end: Date, calendars: [String]) async -> [EventModel]
    func pullRemoteChanges()
    func deleteEvent(id: String, originalStart: Date, scope: EventScope) async -> Bool
    func updateEvent(id: String, originalStart: Date, edit: EventEdit, scope: EventScope) async -> ChangedOccurrence?
    func createEvent(title: String, start: Date, end: Date, calendarID: String?, location: String?, notes: String?) async -> String?
    var newEventCalendarTitle: String? { get }
    var newEventCalendarID: String? { get }
    var editableEventCalendarIDs: Set<String> { get }
}

/// Which occurrences of a repeating event a delete or change applies to.
enum EventScope {
    case thisEvent
    case thisAndFollowing
    case allEvents
}

/// The occurrence a change was made from, as the calendar knows it now. A
/// "this and following" change splits the series, which gives it a new
/// identifier.
struct ChangedOccurrence: Equatable {
    let id: String
    let start: Date
}

/// A delete that's been asked for but not carried out yet, so it can still
/// be undone: the calendar only deletes once the undo window closes.
struct PendingDeletion: Equatable {
    let token: UUID
    let id: String
    let originalStart: Date
    let scope: EventScope

    /// Whether the occurrence with this identifier and start is one this
    /// delete takes. Occurrences of a repeating event share an identifier.
    func covers(id: String, start: Date) -> Bool {
        guard id == self.id else { return false }
        switch scope {
        case .thisEvent: return abs(start.timeIntervalSince(originalStart)) < 1
        case .thisAndFollowing: return start.timeIntervalSince(originalStart) > -1
        case .allEvents: return true
        }
    }
}

class CalendarService: CalendarServiceProviding {
    private let store = EKEventStore()
    
    @MainActor
    func requestAccess(to type: EKEntityType) async throws -> Bool {
        if #available(macOS 14.0, *) {
            switch type {
            case .event:
                return try await store.requestFullAccessToEvents()
            case .reminder:
                return try await store.requestFullAccessToReminders()
            @unknown default:
                return false
            }
        } else {
            return try await store.requestAccess(to: type)
        }
    }
    
    private func hasAccess(to entityType: EKEntityType) -> Bool {
        let status = EKEventStore.authorizationStatus(for: entityType)
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }
    
    func calendars() async -> [CalendarModel] {
        var calendars: [EKCalendar] = []
        
        for type in [EKEntityType.event, .reminder] where hasAccess(to: type) {
            calendars.append(contentsOf: store.calendars(for: type))
        }
        
        return calendars.map { CalendarModel(from: $0) }
    }
    
    /// Asks macOS to fetch from remote accounts (Google, iCloud...) now.
    /// macOS decides whether a fetch is actually needed.
    func pullRemoteChanges() {
        store.refreshSourcesIfNecessary()
    }

    /// A recurring event shares one identifier across occurrences, so the
    /// original start picks the right one. Nil if it's gone or its calendar
    /// is read-only (subscribed calendars, birthdays...).
    private func editableOccurrence(id: String, originalStart: Date) -> EKEvent? {
        guard hasAccess(to: .event) else { return nil }
        let window = store.predicateForEvents(
            withStart: originalStart.addingTimeInterval(-86_400),
            end: originalStart.addingTimeInterval(2 * 86_400),
            calendars: nil
        )
        return store.events(matching: window).first {
            $0.calendarItemIdentifier == id
                && abs($0.startDate.timeIntervalSince(originalStart)) < 1
                && $0.calendar.allowsContentModifications
        }
    }

    /// Whether the occurrence still exists and its calendar allows changes.
    func canEdit(id: String, originalStart: Date) -> Bool {
        editableOccurrence(id: id, originalStart: originalStart) != nil
    }

    func deleteEvent(id: String, originalStart: Date, scope: EventScope) async -> Bool {
        deleteEventNow(id: id, originalStart: originalStart, scope: scope)
    }

    /// The delete itself. Synchronous so it can still run while the app is
    /// quitting, when there's no time left to await anything.
    func deleteEventNow(id: String, originalStart: Date, scope: EventScope) -> Bool {
        guard let occurrence = editableOccurrence(id: id, originalStart: originalStart) else { return false }
        do {
            switch scope {
            case .thisEvent:
                try store.remove(occurrence, span: .thisEvent, commit: true)
            case .thisAndFollowing:
                try store.remove(occurrence, span: .futureEvents, commit: true)
            case .allEvents:
                // The identifier resolves to the series itself, so removing
                // from there onward takes every occurrence.
                let series = store.calendarItem(withIdentifier: id) as? EKEvent ?? occurrence
                try store.remove(series, span: .futureEvents, commit: true)
            }
            return true
        } catch {
            NSLog("CalendarService: couldn't delete event: \(error)")
            return false
        }
    }

    /// Where new events go: the calendar set as default in Calendar's settings.
    var newEventCalendarTitle: String? {
        store.defaultCalendarForNewEvents?.title
    }

    var newEventCalendarID: String? {
        store.defaultCalendarForNewEvents?.calendarIdentifier
    }

    /// Calendars that can take a new event (not subscribed or read-only).
    var editableEventCalendarIDs: Set<String> {
        guard hasAccess(to: .event) else { return [] }
        return Set(store.calendars(for: .event).filter(\.allowsContentModifications).map(\.calendarIdentifier))
    }

    /// Adds an event to the given calendar, or the default one. Returns its
    /// identifier, or nil if that calendar is missing or won't take changes.
    func createEvent(title: String, start: Date, end: Date, calendarID: String?, location: String?, notes: String?) async -> String? {
        let chosen = calendarID.flatMap { store.calendar(withIdentifier: $0) } ?? store.defaultCalendarForNewEvents
        guard let calendar = chosen, calendar.allowsContentModifications else { return nil }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.calendar = calendar
        event.location = location
        event.notes = notes
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return event.calendarItemIdentifier
        } catch {
            NSLog("CalendarService: couldn't create event: \(error)")
            return nil
        }
    }

    /// Saves an edit to one occurrence, or with a wider scope to the rest
    /// of its series. For the whole series the first occurrence moves by as
    /// much as this one did, so every occurrence keeps its own day.
    func updateEvent(id: String, originalStart: Date, edit: EventEdit, scope: EventScope) async -> ChangedOccurrence? {
        guard let occurrence = editableOccurrence(id: id, originalStart: originalStart) else { return nil }
        let target: EKEvent
        let span: EKSpan
        switch scope {
        case .thisEvent:
            target = occurrence
            span = .thisEvent
        case .thisAndFollowing:
            target = occurrence
            span = .futureEvents
        case .allEvents:
            target = store.calendarItem(withIdentifier: id) as? EKEvent ?? occurrence
            span = .futureEvents
        }
        let newStart = target.startDate.addingTimeInterval(edit.start.timeIntervalSince(originalStart))
        // Only what differs from this occurrence is carried over, so moving
        // a whole series doesn't copy one occurrence's own title onto it.
        if edit.title != occurrence.title { target.title = edit.title }
        if edit.location != occurrence.location { target.location = edit.location }
        if edit.notes != occurrence.notes { target.notes = edit.notes }
        target.isAllDay = edit.isAllDay
        target.startDate = newStart
        target.endDate = Self.storedEnd(start: newStart, length: edit.end.timeIntervalSince(edit.start), isAllDay: edit.isAllDay)
        do {
            try store.save(target, span: span, commit: true)
            return ChangedOccurrence(id: target.calendarItemIdentifier, start: edit.start)
        } catch {
            NSLog("CalendarService: couldn't edit event: \(error)")
            return nil
        }
    }

    /// An all-day event's end is the last moment of its last day: a
    /// midnight end would make Calendar count the next day too.
    private static func storedEnd(start: Date, length: TimeInterval, isAllDay: Bool) -> Date {
        let end = start.addingTimeInterval(length)
        guard isAllDay, Calendar.current.startOfDay(for: end) == end, end > start else { return end }
        return end.addingTimeInterval(-1)
    }

    func events(from start: Date, to end: Date, calendars ids: [String]) async -> [EventModel] {
        let allCalendars = await self.calendars()
        let filteredCalendars = allCalendars.filter { ids.isEmpty || ids.contains($0.id) }
        let ekCalendars = filteredCalendars.compactMap { calendarModel in
            store.calendars(for: .event).first { $0.calendarIdentifier == calendarModel.id } ??
            store.calendars(for: .reminder).first { $0.calendarIdentifier == calendarModel.id }
        }
        
        var events: [EventModel] = []
        
        // Fetch regular events
        if hasAccess(to: .event) {
            let eventCalendars = ekCalendars.filter { store.calendars(for: .event).contains($0) }
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: eventCalendars)
            let ekEvents = store.events(matching: predicate)
            events.append(contentsOf: ekEvents.compactMap { EventModel(from: $0) })
        }
        
        // Fetch reminders
        if hasAccess(to: .reminder) {
            let reminderCalendars = ekCalendars.filter { store.calendars(for: .reminder).contains($0) }
            events.append(contentsOf: await fetchReminders(from: start, to: end, calendars: reminderCalendars))
        }
        
        return events.sorted { $0.start < $1.start }
    }
    
    private func fetchReminders(from start: Date, to end: Date, calendars: [EKCalendar]) async -> [EventModel] {
        return await withCheckedContinuation { continuation in
            // Create predicate for reminders with due dates in the specified range
            let predicate = store.predicateForReminders(in: calendars)
            
            store.fetchReminders(matching: predicate) { reminders in
                
                let filteredReminders = (reminders ?? []).filter { reminder in
                    // Check if reminder has a due date within our range
                    guard let dueDate = reminder.dueDateComponents?.date else {
                        return false
                    }
                    
                    return dueDate >= start && dueDate <= end
                }
                
                // Convert to EventModel
                let eventModels = filteredReminders.compactMap { reminder in
                    EventModel(from: reminder)
                }
                
                continuation.resume(returning: eventModels)
            }
        }
    }
    
    func setReminderCompleted(reminderID: String, completed: Bool) async {
        guard let reminder = store.calendarItem(withIdentifier: reminderID) as? EKReminder else { return }
        reminder.isCompleted = completed
        do {
            try store.save(reminder, commit: true)
        } catch {
            print("Failed to update reminder completion: \(error)")
        }
    }
}

// MARK: - Model Extensions

extension CalendarModel {
    init(from calendar: EKCalendar) {
        self.init(
            id: calendar.calendarIdentifier,
            account: calendar.accountTitle,
            title: calendar.title,
            color: calendar.color,
            isSubscribed: calendar.isSubscribed || calendar.isDelegate,
            isReminder: calendar.allowedEntityTypes.contains(.reminder)
        )
    }
}

extension EventModel {
    init?(from event: EKEvent) {
        guard let calendar = event.calendar else { return nil }
        
        self.init(
            id: event.calendarItemIdentifier,
            start: event.startDate,
            end: event.endDate,
            title: event.title ?? "",
            location: event.location,
            notes: event.notes,
            url: event.url,
            isAllDay: event.shouldBeAllDay,
            type: .init(from: event),
            calendar: .init(from: calendar),
            participants: .init(from: event),
            timeZone: calendar.isSubscribed || calendar.isDelegate ? nil : event.timeZone,
            hasRecurrenceRules: event.hasRecurrenceRules || event.isDetached,
            priority: nil
        )
    }
    
    init?(from reminder: EKReminder) {
        guard let calendar = reminder.calendar,
              let dueDateComponents = reminder.dueDateComponents,
              let date = Calendar.current.date(from: dueDateComponents)
        else { return nil }
        
        self.init(
            id: reminder.calendarItemIdentifier,
            start: date,
            end: Calendar.current.endOfDay(for: date),
            title: reminder.title ?? "",
            location: reminder.location,
            notes: reminder.notes,
            url: reminder.url,
            isAllDay: dueDateComponents.hour == nil,
            type: .reminder(completed: reminder.isCompleted),
            calendar: .init(from: calendar),
            participants: [],
            timeZone: calendar.isSubscribed || calendar.isDelegate ? nil : reminder.timeZone,
            hasRecurrenceRules: reminder.hasRecurrenceRules,
            priority: .init(from: reminder.priority)
        )
    }
}

extension EventType {
    init(from event: EKEvent) {
        self = event.birthdayContactIdentifier != nil ? .birthday : .event(.init(from: event.currentUser?.participantStatus))
    }
}

extension AttendanceStatus {
    init(from status: EKParticipantStatus?) {
        switch status {
        case .accepted:
            self = .accepted
        case .tentative:
            self = .maybe
        case .declined:
            self = .declined
        case .pending:
            self = .pending
        default:
            self = .unknown
        }
    }
}

extension Array where Element == Participant {
    init(from event: EKEvent) {
        var participants = event.attendees ?? []
        if let organizer = event.organizer, !participants.contains(where: { $0.url == organizer.url }) {
            participants.append(organizer)
        }
        self.init(
            participants.map { .init(from: $0, isOrganizer: $0.url == event.organizer?.url) }
        )
    }
}

extension Participant {
    init(from participant: EKParticipant, isOrganizer: Bool) {
        self.init(
            name: participant.name ?? participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""),
            status: .init(from: participant.participantStatus),
            isOrganizer: isOrganizer,
            isCurrentUser: participant.isCurrentUser
        )
    }
}

extension Priority {
    init?(from p: Int) {
        switch p {
        case 1...4:
            self = .high
        case 5:
            self = .medium
        case 6...9:
            self = .low
        default:
            return nil
        }
    }
}

// MARK: - Helper Extensions

private extension EKCalendar {
    var accountTitle: String {
        switch source.sourceType {
        case .local, .subscribed, .birthdays:
            return "Other"
        default:
            return source.title
        }
    }
    
    var isDelegate: Bool {
        if #available(macOS 13.0, *) {
            return source.isDelegate
        } else {
            return false
        }
    }
}

private extension EKEvent {
    var currentUser: EKParticipant? {
        attendees?.first(where: \.isCurrentUser)
    }
    
    var shouldBeAllDay: Bool {
        guard !isAllDay else { return true }
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: startDate)
        let endOfDay = calendar.dateInterval(of: .day, for: endDate)?.end
        return startDate == startOfDay && endDate == endOfDay
    }
}

private extension Calendar {
    func endOfDay(for date: Date) -> Date {
        dateInterval(of: .day, for: date)?.end ?? date
    }
}
