//
//  EventRepeat.swift
//  boringNotch
//
//  The repeat and reminder choices for a new event, worded the way Google
//  Calendar words them for the event's own day.
//

import EventKit
import Foundation

enum EventRepeat: Hashable {
    case never, daily, weekdays, weekly, monthly, yearly
    /// Every N days/weeks/months/years, on chosen weekdays, until a date or
    /// a number of times.
    case custom(CustomRepeat)

    /// The ready-made choices in the Repeat menu, above "Custom…".
    static let presets: [EventRepeat] = [.never, .daily, .weekdays, .weekly, .monthly, .yearly]

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
        case .custom(let custom): custom.label(for: start, calendar: calendar)
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
        case .custom(let custom): custom.rule
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

/// Google Calendar's "Custom…" repeat: every N units, on chosen weekdays
/// (weeks only), ending never, on a day, or after a number of times.
struct CustomRepeat: Hashable {
    enum Unit: CaseIterable, Hashable {
        case day, week, month, year

        var frequency: EKRecurrenceFrequency {
            switch self {
            case .day: .daily
            case .week: .weekly
            case .month: .monthly
            case .year: .yearly
            }
        }

        var rruleName: String {
            switch self {
            case .day: "DAILY"
            case .week: "WEEKLY"
            case .month: "MONTHLY"
            case .year: "YEARLY"
            }
        }

        func name(plural: Bool) -> String {
            let base = switch self {
            case .day: "day"
            case .week: "week"
            case .month: "month"
            case .year: "year"
            }
            return plural ? base + "s" : base
        }
    }

    enum End: Hashable {
        case never
        /// Through the end of this day.
        case on(Date)
        case after(Int)
    }

    static let maxInterval = 99
    static let maxCount = 999

    var interval: Int
    var unit: Unit
    /// Calendar weekday numbers, 1 = Sunday … 7 = Saturday. Weeks only;
    /// empty repeats on the start's own weekday.
    var weekdays: Set<Int>
    var end: End

    /// Weekly on the start's weekday, forever: where "Custom…" begins.
    static func starting(on start: Date, calendar: Calendar = .current) -> CustomRepeat {
        CustomRepeat(interval: 1, unit: .week, weekdays: [calendar.component(.weekday, from: start)], end: .never)
    }

    private var clampedInterval: Int { min(max(interval, 1), Self.maxInterval) }
    private var sortedWeekdays: [Int] { unit == .week ? weekdays.sorted() : [] }

    /// "Every 2 weeks on Tue, Thu, until Dec 15", "Daily, 10 times".
    func label(for start: Date, calendar: Calendar = .current) -> String {
        let every: String
        if clampedInterval == 1 {
            every = switch unit {
            case .day: "Daily"
            case .week: "Weekly"
            case .month: "Monthly"
            case .year: "Annually"
            }
        } else {
            every = "Every \(clampedInterval) \(unit.name(plural: true))"
        }
        var text = every
        if unit == .week {
            let days = sortedWeekdays.isEmpty ? [calendar.component(.weekday, from: start)] : sortedWeekdays
            text += " on " + days.map { calendar.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
        }
        switch end {
        case .never: break
        case .on(let day): text += ", until \(day.formatted(.dateTime.month(.abbreviated).day()))"
        case .after(let count): text += count == 1 ? ", once" : ", \(count) times"
        }
        return text
    }

    /// The last moment the series may run: the end of the chosen day.
    private func lastMoment(_ day: Date, calendar: Calendar) -> Date {
        let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) ?? day
        return next.addingTimeInterval(-1)
    }

    var rule: EKRecurrenceRule {
        rule(calendar: .current)
    }

    func rule(calendar: Calendar) -> EKRecurrenceRule {
        let days = sortedWeekdays.compactMap { EKWeekday(rawValue: $0) }.map { EKRecurrenceDayOfWeek($0) }
        let ruleEnd: EKRecurrenceEnd? = switch end {
        case .never: nil
        case .on(let day): EKRecurrenceEnd(end: lastMoment(day, calendar: calendar))
        case .after(let count): EKRecurrenceEnd(occurrenceCount: min(max(count, 1), Self.maxCount))
        }
        return EKRecurrenceRule(
            recurrenceWith: unit.frequency, interval: clampedInterval,
            daysOfTheWeek: days.isEmpty ? nil : days,
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
            daysOfTheYear: nil, setPositions: nil, end: ruleEnd
        )
    }

    /// The same rule for Google: "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;UNTIL=…".
    func rrule(calendar: Calendar = .current) -> String {
        var parts = ["FREQ=\(unit.rruleName)"]
        if clampedInterval > 1 { parts.append("INTERVAL=\(clampedInterval)") }
        if !sortedWeekdays.isEmpty {
            let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
            parts.append("BYDAY=" + sortedWeekdays.map { codes[$0 - 1] }.joined(separator: ","))
        }
        switch end {
        case .never: break
        case .on(let day):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            parts.append("UNTIL=" + formatter.string(from: lastMoment(day, calendar: calendar)))
        case .after(let count):
            parts.append("COUNT=\(min(max(count, 1), Self.maxCount))")
        }
        return "RRULE:" + parts.joined(separator: ";")
    }
}
