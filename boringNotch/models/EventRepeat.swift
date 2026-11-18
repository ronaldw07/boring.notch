//
//  EventRepeat.swift
//  boringNotch
//
//  The repeat and reminder choices for a new event, worded the way Google
//  Calendar words them for the event's own day.
//

import EventKit
import Foundation

enum EventRepeat: CaseIterable, Equatable {
    case never, daily, weekdays, weekly, monthly, yearly

    private static let mondayToFriday: [EKWeekday] = [.monday, .tuesday, .wednesday, .thursday, .friday]

    /// "Weekly on Tuesday", "Monthly on day 17", "Annually on Nov 17".
    func label(for start: Date, calendar: Calendar = .current) -> String {
        switch self {
        case .never: "Does not repeat"
        case .daily: "Daily"
        case .weekdays: "Every weekday (Mon–Fri)"
        case .weekly: "Weekly on \(start.formatted(.dateTime.weekday(.wide)))"
        case .monthly: "Monthly on day \(calendar.component(.day, from: start))"
        case .yearly: "Annually on \(start.formatted(.dateTime.month(.abbreviated).day()))"
        }
    }

    /// The rule to save, or nil for a one-off event. Weekly, monthly and
    /// yearly repeat on the start's own weekday or date.
    var rule: EKRecurrenceRule? {
        switch self {
        case .never: nil
        case .daily: EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        case .weekdays: EKRecurrenceRule(
                recurrenceWith: .weekly, interval: 1,
                daysOfTheWeek: Self.mondayToFriday.map { EKRecurrenceDayOfWeek($0) },
                daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                daysOfTheYear: nil, setPositions: nil, end: nil
            )
        case .weekly: EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        case .monthly: EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        case .yearly: EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        }
    }
}

enum EventReminder {
    /// Minutes before the start; nil leaves the calendar's own default.
    static let choices: [Int?] = [nil, 0, 5, 10, 15, 30, 60, 1440]

    static func label(_ minutes: Int?) -> String {
        switch minutes {
        case nil: "Default reminder"
        case 0: "At start"
        case let minutes? where minutes % 1440 == 0: minutes == 1440 ? "1 day before" : "\(minutes / 1440) days before"
        case let minutes? where minutes % 60 == 0: minutes == 60 ? "1 hour before" : "\(minutes / 60) hours before"
        case let minutes?: "\(minutes) min before"
        }
    }

    static func alarm(_ minutes: Int?) -> EKAlarm? {
        minutes.map { EKAlarm(relativeOffset: -TimeInterval($0) * 60) }
    }
}
