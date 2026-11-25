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
    /// Answers given here, by the same key, shown before the Mac's calendar
    /// catches up with Google.
    @Published private(set) var answers: [String: AttendanceStatus] = [:]

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
        guard let uid = event.externalID else { return nil }
        return try await find(uid: uid, start: event.start, in: event.calendar)
    }

    private func find(uid: String, start: Date, in model: CalendarModel) async throws -> (calendarID: String, item: [String: Any])? {
        guard let calendarID = await googleCalendarID(for: model) else { return nil }
        var query = URLComponents()
        query.queryItems = [
            .init(name: "iCalUID", value: uid),
            .init(name: "singleEvents", value: "true"),
            .init(name: "timeMin", value: GoogleCalendarFormat.timestamp(start.addingTimeInterval(-60))),
            .init(name: "timeMax", value: GoogleCalendarFormat.timestamp(start.addingTimeInterval(60))),
        ]
        let reply = try await request("GET", "/calendars/\(Self.escaped(calendarID))/events?\(query.percentEncodedQuery ?? "")")
        let items = reply["items"] as? [[String: Any]] ?? []
        let match = items.first { GoogleCalendarFormat.start(of: $0) == start } ?? items.first
        return match.map { (calendarID, $0) }
    }

    /// Like `find`, but waits for the Mac to hand a just-moved event over
    /// to Google: tries again every few seconds for up to a minute.
    private func findAfterSync(uid: String, start: Date, in model: CalendarModel) async throws -> (calendarID: String, item: [String: Any])? {
        for attempt in 0..<Self.syncAttempts {
            if attempt > 0 { try await Task.sleep(for: Self.syncRetryDelay) }
            if let found = try await find(uid: uid, start: start, in: model) { return found }
        }
        return nil
    }

    private static let syncAttempts = 20
    private static let syncRetryDelay: Duration = .seconds(3)

    // MARK: - Changes

    /// Answers an invite for this occurrence. Shown at once, put back if
    /// Google won't take it.
    func respond(to event: EventModel, with status: AttendanceStatus) async -> Bool {
        guard let uid = event.externalID else { return false }
        let key = GoogleCalendarFormat.key(uid: uid, start: event.start)
        let previous = answers[key]
        answers[key] = status
        do {
            guard let (calendarID, item) = try await find(event), let id = item["id"] as? String,
                  let attendees = GoogleCalendarFormat.attendees(item["attendees"] as? [[String: Any]] ?? [], answering: status)
            else {
                answers[key] = previous
                return false
            }
            _ = try await request("PATCH", "/calendars/\(Self.escaped(calendarID))/events/\(Self.escaped(id))",
                                  body: ["attendees": attendees])
            return true
        } catch {
            answers[key] = previous
            NSLog("GoogleCalendar: couldn't RSVP: \(error)")
            return false
        }
    }

    /// Sets this occurrence's color; nil goes back to the calendar's.
    func setColor(_ color: GoogleEventColor?, of event: EventModel) async -> Bool {
        guard let uid = event.externalID else { return false }
        return await setColor(color, uid: uid, start: event.start, in: event.calendar, waitsForSync: false)
    }

    /// Sets the color of the occurrence at `start` in `model`. Shown at once
    /// and put back if Google won't take it. `waitsForSync` is for an event
    /// the Mac has just moved or changed, which Google may not have yet.
    func setColor(_ color: GoogleEventColor?, uid: String, start: Date, in model: CalendarModel,
                  waitsForSync: Bool) async -> Bool {
        let key = GoogleCalendarFormat.key(uid: uid, start: start)
        let previous = colors[key]
        colors[key] = color
        do {
            let found = waitsForSync
                ? try await findAfterSync(uid: uid, start: start, in: model)
                : try await find(uid: uid, start: start, in: model)
            guard let (calendarID, item) = found, let id = item["id"] as? String else {
                colors[key] = previous
                return false
            }
            _ = try await request("PATCH", "/calendars/\(Self.escaped(calendarID))/events/\(Self.escaped(id))",
                                  body: ["colorId": color.map { String($0.rawValue) } ?? NSNull()])
            return true
        } catch {
            colors[key] = previous
            NSLog("GoogleCalendar: couldn't set color: \(error)")
            return false
        }
    }

    /// Adds an event with guests or a Meet link; invites go out by email.
    /// Returns its id, for undo.
    func create(in calendarID: String, body: [String: Any], addsMeet: Bool) async -> String? {
        do {
            let path = "/calendars/\(Self.escaped(calendarID))/events?sendUpdates=all"
                + (addsMeet ? "&conferenceDataVersion=1" : "")
            let item = try await request("POST", path, body: body)
            // Show its color now, before the shown days next change.
            colors.merge(GoogleCalendarFormat.colors(in: [item])) { $1 }
            return item["id"] as? String
        } catch {
            NSLog("GoogleCalendar: couldn't create event: \(error)")
            return nil
        }
    }

    /// Deletes an event made here, for undo; guests get Google's cancellation.
    func delete(eventID: String, in calendarID: String) async -> Bool {
        do {
            _ = try await request("DELETE", "/calendars/\(Self.escaped(calendarID))/events/\(Self.escaped(eventID))?sendUpdates=all")
            return true
        } catch {
            NSLog("GoogleCalendar: couldn't delete event: \(error)")
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
