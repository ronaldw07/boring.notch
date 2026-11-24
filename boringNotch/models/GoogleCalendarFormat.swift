//
//  GoogleCalendarFormat.swift
//  boringNotch
//
//  What Google Calendar's API expects and returns, kept apart from the
//  network code: event colors, repeat rules, a new event's body, an RSVP,
//  and matching Google's events to the Mac's.
//

import AppKit
import Foundation

/// Google Calendar's eleven event colors, by their colorId.
enum GoogleEventColor: Int, CaseIterable {
    case lavender = 1, sage, grape, flamingo, banana, tangerine, peacock, graphite, blueberry, basil, tomato

    var name: String {
        switch self {
        case .lavender: "Lavender"
        case .sage: "Sage"
        case .grape: "Grape"
        case .flamingo: "Flamingo"
        case .banana: "Banana"
        case .tangerine: "Tangerine"
        case .peacock: "Peacock"
        case .graphite: "Graphite"
        case .blueberry: "Blueberry"
        case .basil: "Basil"
        case .tomato: "Tomato"
        }
    }

    private var hex: Int {
        switch self {
        case .lavender: 0x7986CB
        case .sage: 0x33B679
        case .grape: 0x8E24AA
        case .flamingo: 0xE67C73
        case .banana: 0xF6BF26
        case .tangerine: 0xF4511E
        case .peacock: 0x039BE5
        case .graphite: 0x616161
        case .blueberry: 0x3F51B5
        case .basil: 0x0B8043
        case .tomato: 0xD50000
        }
    }

    var color: NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum GoogleCalendarFormat {
    /// The rule Google wants in a new event's `recurrence`.
    static func rrule(_ repeats: EventRepeat) -> String? {
        switch repeats {
        case .never: nil
        case .daily: "RRULE:FREQ=DAILY"
        case .weekdays: "RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
        case .weekly: "RRULE:FREQ=WEEKLY"
        case .monthly: "RRULE:FREQ=MONTHLY"
        case .yearly: "RRULE:FREQ=YEARLY"
        case .custom(let custom): custom.rrule()
        }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// "2026-11-17", for all-day events, in the given calendar's zone.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// Addresses typed into the guests field, split on commas, semicolons
    /// or spaces; anything that isn't an address is dropped.
    static func guestEmails(from text: String) -> [String] {
        var seen = Set<String>()
        return text
            .split(whereSeparator: { ",; \n\t".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { email in
                guard let at = email.firstIndex(of: "@"), at != email.startIndex else { return false }
                let domain = email[email.index(after: at)...]
                return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
            }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// A new event for `events.insert`. A Meet link needs
    /// `conferenceDataVersion=1` on the request too.
    static func newEvent(
        title: String, start: Date, end: Date, isAllDay: Bool,
        location: String?, notes: String?, guests: [String], addsMeet: Bool,
        repeats: EventRepeat, reminderMinutes: Int?, color: GoogleEventColor? = nil,
        timeZone: TimeZone = .current, requestID: String = UUID().uuidString,
        calendar: Calendar = .current
    ) -> [String: Any] {
        func time(_ date: Date, endOfAllDay: Bool) -> [String: Any] {
            if isAllDay {
                // Google's all-day end is the day after, exclusive.
                let day = endOfAllDay
                    ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date.addingTimeInterval(-1))) ?? date
                    : date
                return ["date": Self.day(day, calendar: calendar)]
            }
            // Repeating events need the zone to repeat in.
            return ["dateTime": timestamp(date), "timeZone": timeZone.identifier]
        }
        var body: [String: Any] = [
            "summary": title,
            "start": time(start, endOfAllDay: false),
            "end": time(end, endOfAllDay: true),
        ]
        if let location, !location.isEmpty { body["location"] = location }
        if let notes, !notes.isEmpty { body["description"] = notes }
        if !guests.isEmpty { body["attendees"] = guests.map { ["email": $0] } }
        if addsMeet {
            body["conferenceData"] = ["createRequest": [
                "requestId": requestID,
                "conferenceSolutionKey": ["type": "hangoutsMeet"],
            ]]
        }
        if let rule = rrule(repeats) { body["recurrence"] = [rule] }
        if let color { body["colorId"] = String(color.rawValue) }
        if let reminderMinutes {
            body["reminders"] = ["useDefault": false, "overrides": [["method": "popup", "minutes": reminderMinutes]]]
        }
        return body
    }

    /// Google's word for an answer.
    static func responseStatus(_ status: AttendanceStatus) -> String {
        switch status {
        case .accepted: "accepted"
        case .maybe: "tentative"
        case .declined: "declined"
        case .pending, .unknown: "needsAction"
        }
    }

    /// The event's guest list with your own answer changed, for a PATCH;
    /// Google replaces the whole list, so everyone else is sent back as is.
    /// Nil if you aren't on it.
    static func attendees(_ attendees: [[String: Any]], answering status: AttendanceStatus) -> [[String: Any]]? {
        guard attendees.contains(where: { $0["self"] as? Bool == true }) else { return nil }
        return attendees.map { attendee in
            guard attendee["self"] as? Bool == true else { return attendee }
            var mine = attendee
            mine["responseStatus"] = responseStatus(status)
            return mine
        }
    }

    /// Pairs a Google event with the Mac's copy: the iCalendar UID and the
    /// start, since a repeating event's occurrences share the UID.
    static func key(uid: String, start: Date) -> String {
        "\(uid)|\(Int(start.timeIntervalSince1970))"
    }

    /// The start of an event as Google lists it: a time, or a date for an
    /// all-day event, which starts at local midnight.
    static func start(of item: [String: Any], calendar: Calendar = .current) -> Date? {
        guard let start = item["start"] as? [String: Any] else { return nil }
        if let dateTime = start["dateTime"] as? String {
            return ISO8601DateFormatter().date(from: dateTime)
        }
        if let date = start["date"] as? String {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: date)
        }
        return nil
    }

    /// Colors set on events in a list reply, by `key(uid:start:)`.
    static func colors(in items: [[String: Any]], calendar: Calendar = .current) -> [String: GoogleEventColor] {
        var colors: [String: GoogleEventColor] = [:]
        for item in items {
            guard let uid = item["iCalUID"] as? String,
                  let start = start(of: item, calendar: calendar),
                  let id = (item["colorId"] as? String).flatMap(Int.init),
                  let color = GoogleEventColor(rawValue: id) else { continue }
            colors[key(uid: uid, start: start)] = color
        }
        return colors
    }
}
