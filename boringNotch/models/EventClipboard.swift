//
//  EventClipboard.swift
//  boringNotch
//
//  ⌘C on an open event keeps a copy here; ⌘V on the Calendar tab makes a
//  one-off event from it at the slot under the pointer, or at the same time
//  on the day being shown.
//

import Foundation

struct CopiedEvent: Equatable {
    let title: String
    let calendarID: String
    let location: String?
    let notes: String?
    let isAllDay: Bool
    /// Hour and minute it started, for a paste that isn't at the pointer.
    let startHour: Int
    let startMinute: Int
    /// Seconds for a timed event; whole days for an all-day one.
    let length: TimeInterval
    let days: Int

    init(_ event: EventModel, calendar: Calendar = .current) {
        title = event.title
        calendarID = event.calendar.id
        location = event.location
        notes = event.notes
        isAllDay = event.isAllDay
        startHour = calendar.component(.hour, from: event.start)
        startMinute = calendar.component(.minute, from: event.start)
        length = event.end.timeIntervalSince(event.start)
        let firstDay = calendar.startOfDay(for: event.start)
        let lastDay = calendar.startOfDay(for: event.end.addingTimeInterval(-1))
        days = max(1, (calendar.dateComponents([.day], from: firstDay, to: lastDay).day ?? 0) + 1)
    }

    /// Where a paste lands on `day`. `slot` is the time under the pointer,
    /// in seconds from the start of the day, rounded down to `snap`; with no
    /// slot it keeps the copy's own start time. All-day copies fill whole days.
    func pasteTimes(on day: Date, slot: TimeInterval?, snap: TimeInterval,
                    calendar: Calendar = .current) -> (start: Date, end: Date) {
        let dayStart = calendar.startOfDay(for: day)
        if isAllDay {
            let end = calendar.date(byAdding: .day, value: days, to: dayStart) ?? dayStart.addingTimeInterval(TimeInterval(days) * 86_400)
            return (dayStart, end)
        }
        let start: Date
        if let slot {
            start = dayStart.addingTimeInterval((slot / snap).rounded(.down) * snap)
        } else {
            start = calendar.date(bySettingHour: startHour, minute: startMinute, second: 0, of: dayStart) ?? dayStart
        }
        return (start, start.addingTimeInterval(length))
    }
}

@MainActor
enum EventClipboard {
    static var copied: CopiedEvent?
}
