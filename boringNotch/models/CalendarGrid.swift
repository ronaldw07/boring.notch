//
//  CalendarGrid.swift
//  boringNotch
//
//  Which days the week and month views show, and which events land on a
//  day. Weeks start on whichever day the Mac is set to.
//

import Foundation

enum CalendarSpan: String, CaseIterable {
    case day, fourDays, week, month

    var label: String {
        switch self {
        case .day: "Day"
        case .fourDays: "4 Days"
        case .week: "Week"
        case .month: "Month"
        }
    }

    /// Shown as columns of days side by side.
    var isMultiDay: Bool {
        self == .fourDays || self == .week
    }
}

enum CalendarGrid {
    static let daysInWeek = 7
    static let fourDays = 4

    /// The first day of the week holding `date`.
    static func weekStart(of date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        let back = (calendar.component(.weekday, from: day) - calendar.firstWeekday + daysInWeek) % daysInWeek
        return calendar.date(byAdding: .day, value: -back, to: day) ?? day
    }

    /// The seven days of the week holding `date`.
    static func week(containing date: Date, calendar: Calendar = .current) -> [Date] {
        days(from: weekStart(of: date, calendar: calendar), count: daysInWeek, calendar: calendar)
    }

    /// Whole weeks covering the month holding `date`: starts on the first
    /// day of the week the 1st falls in, ends with the week of the last day.
    static func month(containing date: Date, calendar: Calendar = .current) -> [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return week(containing: date, calendar: calendar) }
        let first = weekStart(of: interval.start, calendar: calendar)
        let lastDay = calendar.startOfDay(for: interval.end.addingTimeInterval(-1))
        let lastWeek = weekStart(of: lastDay, calendar: calendar)
        let weeks = (calendar.dateComponents([.day], from: first, to: lastWeek).day ?? 0) / daysInWeek + 1
        return days(from: first, count: weeks * daysInWeek, calendar: calendar)
    }

    /// The days a span shows around `date`.
    static func days(for span: CalendarSpan, around date: Date, calendar: Calendar = .current) -> [Date] {
        switch span {
        case .day: [calendar.startOfDay(for: date)]
        case .fourDays: days(from: calendar.startOfDay(for: date), count: fourDays, calendar: calendar)
        case .week: week(containing: date, calendar: calendar)
        case .month: month(containing: date, calendar: calendar)
        }
    }

    /// The date one step back or forward: a day, four days, a week, or a month.
    static func step(_ date: Date, by count: Int, span: CalendarSpan, calendar: Calendar = .current) -> Date {
        let (component, size): (Calendar.Component, Int) = switch span {
        case .day: (.day, 1)
        case .fourDays: (.day, fourDays)
        case .week: (.weekOfYear, 1)
        case .month: (.month, 1)
        }
        return calendar.date(byAdding: component, value: count * size, to: date) ?? date
    }

    static func days(from start: Date, count: Int, calendar: Calendar = .current) -> [Date] {
        (0 ..< count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Events on a day: anything running during it, all-day first, then by
    /// start. One ending right at midnight belongs to the day before.
    static func events(on day: Date, from events: [EventModel], calendar: Calendar = .current) -> [EventModel] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return events
            .filter { $0.start < end && ($0.end > start || ($0.start >= start && $0.end <= $0.start)) }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }
}
