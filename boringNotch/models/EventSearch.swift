//
//  EventSearch.swift
//  boringNotch
//
//  Which events match a search: every word has to appear in the title,
//  location or description. Upcoming ones first, soonest first, then past
//  ones, latest first, like Google Calendar's search.
//

import Foundation

enum EventSearch {
    static let limit = 50

    /// Every match, split in two: upcoming soonest first, past latest first.
    static func sections(for query: String, in events: [EventModel], now: Date = .now) -> (upcoming: [EventModel], past: [EventModel]) {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return ([], []) }
        let matches = events.filter { event in
            let text = [event.title, event.location ?? "", event.notes ?? ""].joined(separator: " ")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        let upcoming = matches.filter { $0.end >= now }.sorted { $0.start < $1.start }
        let past = matches.filter { $0.end < now }.sorted { $0.start > $1.start }
        return (upcoming, past)
    }

    static func results(for query: String, in events: [EventModel], now: Date = .now) -> [EventModel] {
        let found = sections(for: query, in: events, now: now)
        return Array((found.upcoming + found.past).prefix(limit))
    }
}
