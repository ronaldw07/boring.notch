//
//  GoogleCalendarManager.swift
//  boringNotch
//
//  The parts of Google Calendar the Mac's calendar can't do: answering an
//  invite, a new event with guests or a Meet link, and event colors. Uses
//  the Google sign-in from Settings. Events are found on Google by their
//  iCalendar UID, which the Mac's copy of a Google event shares.
//

import Foundation

@MainActor
final class GoogleCalendarManager: ObservableObject {
    static let shared = GoogleCalendarManager()

    /// Colors set on events in the range last loaded, by
    /// `GoogleCalendarFormat.key(uid:start:)`.
    @Published private(set) var colors: [String: GoogleEventColor] = [:]

    private struct Entry {
        let id: String
        let names: Set<String>
    }

    /// The account's calendars, fetched once.
    private var calendarList: [Entry]?
    private let google = GoogleTasksManager.shared
    private static let base = "https://www.googleapis.com/calendar/v3"

    private init() {}

    var isAvailable: Bool { google.isSignedIn && google.hasCalendarAccess }

    // MARK: - Calendars

    private func calendars() async throws -> [Entry] {
        if let calendarList { return calendarList }
        let reply = try await request("GET", "/users/me/calendarList?maxResults=250")
        let entries = (reply["items"] as? [[String: Any]] ?? []).compactMap { item -> Entry? in
            guard let id = item["id"] as? String else { return nil }
            let names = [id, item["summary"] as? String, item["summaryOverride"] as? String].compactMap { $0 }
            return Entry(id: id, names: Set(names))
        }
        calendarList = entries
        return entries
    }

    /// The Google calendar a Mac calendar mirrors: matched by name, which is
    /// the address for the main calendar. Nil for iCloud and the like.
    func googleCalendarID(for model: CalendarModel) async -> String? {
        guard isAvailable else { return nil }
        return try? await calendars().first { $0.names.contains(model.title) }?.id
    }

    /// The occurrence on Google and the calendar it's in.
    private func find(_ event: EventModel) async throws -> (calendarID: String, item: [String: Any])? {
        guard let uid = event.externalID,
              let calendarID = await googleCalendarID(for: event.calendar) else { return nil }
        var query = URLComponents()
        query.queryItems = [
            .init(name: "iCalUID", value: uid),
            .init(name: "singleEvents", value: "true"),
            .init(name: "timeMin", value: GoogleCalendarFormat.timestamp(event.start.addingTimeInterval(-60))),
            .init(name: "timeMax", value: GoogleCalendarFormat.timestamp(event.start.addingTimeInterval(60))),
        ]
        let reply = try await request("GET", "/calendars/\(Self.escaped(calendarID))/events?\(query.percentEncodedQuery ?? "")")
        let items = reply["items"] as? [[String: Any]] ?? []
        let match = items.first { GoogleCalendarFormat.start(of: $0) == event.start } ?? items.first
        return match.map { (calendarID, $0) }
    }

    // MARK: - Changes

    /// Answers an invite for this occurrence.
    func respond(to event: EventModel, with status: AttendanceStatus) async -> Bool {
        do {
            guard let (calendarID, item) = try await find(event), let id = item["id"] as? String,
                  let attendees = GoogleCalendarFormat.attendees(item["attendees"] as? [[String: Any]] ?? [], answering: status)
            else { return false }
            _ = try await request("PATCH", "/calendars/\(Self.escaped(calendarID))/events/\(Self.escaped(id))",
                                  body: ["attendees": attendees])
            return true
        } catch {
            NSLog("GoogleCalendar: couldn't RSVP: \(error)")
            return false
        }
    }

    /// Sets this occurrence's color; nil goes back to the calendar's.
    func setColor(_ color: GoogleEventColor?, of event: EventModel) async -> Bool {
        do {
            guard let (calendarID, item) = try await find(event), let id = item["id"] as? String else { return false }
            _ = try await request("PATCH", "/calendars/\(Self.escaped(calendarID))/events/\(Self.escaped(id))",
                                  body: ["colorId": color.map { String($0.rawValue) } ?? NSNull()])
            if let uid = event.externalID {
                colors[GoogleCalendarFormat.key(uid: uid, start: event.start)] = color
            }
            return true
        } catch {
            NSLog("GoogleCalendar: couldn't set color: \(error)")
            return false
        }
    }

    /// Adds an event with guests or a Meet link; invites go out by email.
    func create(in calendarID: String, body: [String: Any], addsMeet: Bool) async -> Bool {
        do {
            let path = "/calendars/\(Self.escaped(calendarID))/events?sendUpdates=all"
                + (addsMeet ? "&conferenceDataVersion=1" : "")
            _ = try await request("POST", path, body: body)
            return true
        } catch {
            NSLog("GoogleCalendar: couldn't create event: \(error)")
            return false
        }
    }

    /// Fetches event colors for the days shown, in the given calendars.
    /// Called when the shown days change, not on every refresh.
    func loadColors(from start: Date, to end: Date, calendars models: [CalendarModel]) async {
        guard isAvailable else {
            if !colors.isEmpty { colors = [:] }
            return
        }
        var found: [String: GoogleEventColor] = [:]
        for model in models {
            guard let calendarID = await googleCalendarID(for: model) else { continue }
            var query = URLComponents()
            query.queryItems = [
                .init(name: "singleEvents", value: "true"),
                .init(name: "timeMin", value: GoogleCalendarFormat.timestamp(start)),
                .init(name: "timeMax", value: GoogleCalendarFormat.timestamp(end)),
                .init(name: "maxResults", value: "2500"),
                .init(name: "fields", value: "items(iCalUID,start,colorId)"),
            ]
            do {
                let reply = try await request("GET", "/calendars/\(Self.escaped(calendarID))/events?\(query.percentEncodedQuery ?? "")")
                found.merge(GoogleCalendarFormat.colors(in: reply["items"] as? [[String: Any]] ?? [])) { $1 }
            } catch {
                NSLog("GoogleCalendar: couldn't load colors: \(error)")
            }
        }
        if found != colors { colors = found }
    }

    // MARK: - Requests

    private static func escaped(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/@"))) ?? id
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let url = URL(string: Self.base + path) else { throw GoogleTasksError.server("Bad request.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await google.validAccessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200 ..< 300).contains(status) else {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "Google Calendar request failed."
            throw GoogleTasksError.server(message)
        }
        return json
    }
}
