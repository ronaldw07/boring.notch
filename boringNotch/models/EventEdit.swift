//
//  EventEdit.swift
//  boringNotch
//
//  What saving an event sets: its text, its time, and whether it's all day.
//  The time rules follow Google Calendar: moving the start keeps the length,
//  and the end can never come before the start.
//

import Foundation

struct EventEdit: Equatable {
    var title: String
    var location: String?
    var notes: String?
    var start: Date
    var end: Date
    var isAllDay: Bool

    /// The shortest an event can be made from the editor.
    static let minimumLength: TimeInterval = 15 * 60
    /// Turning "All day" off puts the event here on its day, like Google does.
    static let defaultStartHour = 9
    static let defaultLength: TimeInterval = 60 * 60

    init(title: String, location: String?, notes: String?, start: Date, end: Date, isAllDay: Bool) {
        self.title = title
        self.location = location
        self.notes = notes
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
    }

    init(_ event: EventModel) {
        self.init(title: event.title, location: event.location, notes: event.notes,
                  start: event.start, end: event.end, isAllDay: event.isAllDay)
    }

    /// A new start that keeps the event's length.
    func movingStart(to newStart: Date) -> EventEdit {
        var copy = self
        copy.end = newStart.addingTimeInterval(end.timeIntervalSince(start))
        copy.start = newStart
        return copy
    }

    /// A new end, pushed past the start if it would come before it.
    func movingEnd(to newEnd: Date) -> EventEdit {
        var copy = self
        copy.end = max(newEnd, start.addingTimeInterval(Self.minimumLength))
        return copy
    }

    /// The same times on another day.
    func movingDay(to day: Date, calendar: Calendar = .current) -> EventEdit {
        let shift = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: day)).day ?? 0
        guard shift != 0,
              let newStart = calendar.date(byAdding: .day, value: shift, to: start) else { return self }
        return movingStart(to: newStart)
    }

    /// All day covers whole days from the start's day to the end's; turning
    /// it off gives an hour at the default time on the first day.
    func settingAllDay(_ allDay: Bool, calendar: Calendar = .current) -> EventEdit {
        guard allDay != isAllDay else { return self }
        var copy = self
        copy.isAllDay = allDay
        let firstDay = calendar.startOfDay(for: start)
        if allDay {
            copy.start = firstDay
            // An end at midnight belongs to the day before it.
            let lastDay = calendar.startOfDay(for: max(start, end.addingTimeInterval(-1)))
            copy.end = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
        } else {
            copy.start = calendar.date(bySettingHour: Self.defaultStartHour, minute: 0, second: 0, of: firstDay) ?? firstDay
            copy.end = copy.start.addingTimeInterval(Self.defaultLength)
        }
        return copy
    }

    /// Only the time changed, so the undo message can say where it went.
    func differsOnlyInTime(from other: EventEdit) -> Bool {
        title == other.title && location == other.location && notes == other.notes
            && isAllDay == other.isAllDay && (start != other.start || end != other.end)
    }
}
