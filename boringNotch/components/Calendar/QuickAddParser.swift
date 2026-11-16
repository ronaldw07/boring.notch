//
//  QuickAddParser.swift
//  boringNotch
//
//  Created by Ronald Wen on 2026-11-16.
//
//  Turns "Lunch with Sam 1pm" or "Gym tomorrow 6-7pm" into a title and a
//  time, for adding an event by typing in the Calendar tab.
//

import Foundation

enum QuickAddParser {
    struct Result: Equatable {
        let title: String
        let start: Date
        let end: Date
    }

    /// How long an event lasts when only a start time is typed.
    static let defaultLength: TimeInterval = 60 * 60
    /// Shown when the text has a time but nothing else.
    static let untitled = "New event"

    /// Words left hanging once the time is taken out ("Lunch at", "Call from").
    private static let connectors: Set<String> = ["at", "on", "from", "for", "@", "-", "–", ",", "by"]
    /// Words that pin the event to today even while another day is showing.
    private static let todayWords = ["today", "tonight", "this morning", "this afternoon", "this evening"]

    /// Nil until the text includes a time. A time without a day lands on
    /// `day`, the day the calendar is showing.
    static func parse(_ text: String, day: Date, now: Date = .now, calendar: Calendar = .current) -> Result? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              var start = match.date,
              let range = Range(match.range, in: text) else { return nil }

        let phrase = text[range].lowercased()
        guard hasTime(phrase) else { return nil }

        // The detector reads a bare "1pm" as today. Move it to the day on
        // screen unless the text said today itself.
        if calendar.isDate(start, inSameDayAs: now),
           !calendar.isDate(day, inSameDayAs: now),
           !todayWords.contains(where: { phrase.contains($0) }) {
            let time = calendar.dateComponents([.hour, .minute], from: start)
            start = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day) ?? start
        }

        let length = match.duration > 0 ? match.duration : defaultLength
        return Result(title: title(removing: range, from: text), start: start, end: start.addingTimeInterval(length))
    }

    /// "tomorrow" alone is a day, not a time; a digit, noon or midnight makes it one.
    private static func hasTime(_ phrase: String) -> Bool {
        phrase.contains(where: \.isNumber) || phrase.contains("noon") || phrase.contains("midnight")
    }

    private static func title(removing range: Range<String.Index>, from text: String) -> String {
        let rest = text[..<range.lowerBound] + " " + text[range.upperBound...]
        var words = rest.split(whereSeparator: \.isWhitespace).map(String.init)
        while let last = words.last, connectors.contains(last.lowercased()) { words.removeLast() }
        while let first = words.first, connectors.contains(first.lowercased()) { words.removeFirst() }
        let title = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",-– "))
        return title.isEmpty ? untitled : title
    }
}
