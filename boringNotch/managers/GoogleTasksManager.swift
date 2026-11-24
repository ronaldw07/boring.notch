//
//  GoogleTasksManager.swift
//  boringNotch
//
//  Google Tasks don't sync to the Mac's Calendar, so they're fetched from
//  Google directly. Sign-in is the standard desktop flow: the browser opens,
//  Google redirects back to a one-shot listener on 127.0.0.1, and the code
//  is traded for tokens. Uses Chora's own Google client, built into release
//  copies (Settings › Connections).
//

import AppKit
import Defaults
import Foundation
import Security

struct GoogleTask: Identifiable, Equatable {
    let id: String
    let listID: String
    let title: String
    var isCompleted: Bool
    /// The start of the local day it's due.
    let due: Date
    var notes: String? = nil
    /// A time set in Chora, minutes after midnight; nil for a task with
    /// only a day. Google never sees it.
    var minutes: Int? = nil
    /// Google's page for the task, for Open in Google.
    var link: URL? = nil

    /// When it's due, at its Chora time; nil without one.
    var timedStart: Date? {
        minutes.map { due.addingTimeInterval(TimeInterval($0) * 60) }
    }

    /// The due date as Google wants it: the local date at midnight UTC.
    static func dueText(for day: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02dT00:00:00.000Z", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// Google keeps a due date as midnight UTC ("2026-11-23T00:00:00.000Z");
    /// the date part is the day, wherever you are.
    static func dueDay(from text: String, calendar: Calendar = .current) -> Date? {
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

enum GoogleTasksError: LocalizedError {
    case notConfigured
    case denied(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "This copy of Chora was built without Google sign-in."
        case .denied(let reason): return "Google said no: \(reason)"
        case .server(let message): return message
        }
    }
}

@MainActor
final class GoogleTasksManager: ObservableObject {
    static let shared = GoogleTasksManager()

    @Published private(set) var tasks: [GoogleTask] = []
    @Published private(set) var isSignedIn: Bool = !GoogleTasksManager.refreshToken.isEmpty
    @Published private(set) var statusMessage: String?
    @Published private(set) var isSigningIn = false
    /// Whether the sign-in also covers Google Calendar (RSVP, guests, Meet,
    /// colors). Known once a token has come back; signing in before this
    /// was added covered Tasks only.
    @Published private(set) var hasCalendarAccess = false

    private static let calendarScopes = [
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
    ]
    private static let scope = (["https://www.googleapis.com/auth/tasks"] + calendarScopes).joined(separator: " ")
    private var accessToken: (value: String, expires: Date)?

    private init() {}

    /// The refresh token lives in the Keychain. Versions before 0.9.1 kept it
    /// in preferences, so it moves over the first time it's read.
    private static var refreshToken: String {
        let legacy = Defaults[.googleRefreshToken]
        if !legacy.isEmpty, RefreshTokenKeychain.save(legacy) {
            Defaults[.googleRefreshToken] = ""
            return legacy
        }
        return RefreshTokenKeychain.load() ?? legacy
    }

    /// Chora's own Google client, put into Info.plist at release time (see
    /// scripts/release.sh). A client pasted into older versions still wins,
    /// so sign-ins made with it keep working.
    private static var client: (id: String, secret: String) {
        let pastedID = Defaults[.googleClientID].trimmingCharacters(in: .whitespaces)
        if !pastedID.isEmpty { return (pastedID, Defaults[.googleClientSecret]) }
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["GoogleClientID"] as? String ?? "", info["GoogleClientSecret"] as? String ?? "")
    }

    var isConfigured: Bool { !Self.client.id.isEmpty }

    // MARK: - Sign in

    func signIn() async {
        guard isConfigured else {
            statusMessage = GoogleTasksError.notConfigured.errorDescription
            return
        }
        isSigningIn = true
        statusMessage = "Finish signing in in your browser…"
        defer { isSigningIn = false }

        do {
            let verifier = PKCE.randomString(length: 64)
            let state = PKCE.randomString(length: 24)
            let server = try LoopbackAuthServer()
            let port = try await server.start()
            let redirect = "http://127.0.0.1:\(port)"

            var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = [
                .init(name: "client_id", value: Self.client.id),
                .init(name: "redirect_uri", value: redirect),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: Self.scope),
                .init(name: "state", value: state),
                .init(name: "code_challenge", value: PKCE.challenge(for: verifier)),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "access_type", value: "offline"),
                .init(name: "prompt", value: "consent"),
            ]
            NSWorkspace.shared.open(components.url!)

            let callback = try await server.waitForCallback(timeout: .seconds(180))
            if let error = callback["error"] { throw GoogleTasksError.denied(error) }
            guard callback["state"] == state, let code = callback["code"] else {
                throw GoogleTasksError.server("Sign-in response didn't match. Try again.")
            }

            let token = try await tokenRequest([
                "grant_type": "authorization_code",
                "code": code,
                "code_verifier": verifier,
                "redirect_uri": redirect,
            ])
            guard let refresh = token.refreshToken else {
                throw GoogleTasksError.server("Google didn't return a refresh token. Try again.")
            }
            guard RefreshTokenKeychain.save(refresh) else {
                throw GoogleTasksError.server("Couldn't save the sign-in to the Keychain. Try again.")
            }
            store(token)
            isSignedIn = true
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func signOut() {
        RefreshTokenKeychain.delete()
        Defaults[.googleRefreshToken] = ""
        accessToken = nil
        tasks = []
        isSignedIn = false
        hasCalendarAccess = false
        statusMessage = nil
    }

    // MARK: - Tasks

    /// Tasks due on any day from `first` through `last`. Google keeps a due
    /// *date*, no time, so these show beside a day rather than on the timeline.
    ///
    /// Every task with a due date is fetched and the days picked out here:
    /// Google's own due filter missed tasks that Google Calendar shows.
    func reload() async {
        guard isSignedIn else {
            if !tasks.isEmpty { tasks = [] }
            return
        }
        // A newer reload (another day or view) wins over one still running.
        reloadGeneration += 1
        let generation = reloadGeneration
        do {
            let token = try await validAccessToken()
            let lists = try await get("https://tasks.googleapis.com/tasks/v1/users/@me/lists?maxResults=100", token: token)
            var found: [GoogleTask] = []
            for list in lists["items"] as? [[String: Any]] ?? [] {
                guard let listID = list["id"] as? String else { continue }
                found += try await allTasks(in: listID, token: token)
            }
            // Done tasks stay, crossed out, the way Google Calendar shows them.
            guard generation == reloadGeneration else { return }
            if found != tasks { tasks = found }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private var reloadGeneration = 0
    private var refreshLoop: Task<Void, Never>?
    private static let refreshEvery: Duration = .seconds(30)

    /// Loads tasks at launch and keeps them fresh in the background, so the
    /// calendar shows them the moment it opens and on any day you go to.
    func startRefreshing() {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reload()
                try? await Task.sleep(for: Self.refreshEvery)
            }
        }
    }
    private static let pageLimit = 20

    /// Every task with a due date in one list, following Google's pages.
    private func allTasks(in listID: String, token: String) async throws -> [GoogleTask] {
        var found: [GoogleTask] = []
        var pageToken: String?
        for _ in 0..<Self.pageLimit {
            var query = URLComponents(string: "https://tasks.googleapis.com/tasks/v1/lists/\(listID)/tasks")!
            query.queryItems = [
                .init(name: "showCompleted", value: "true"),
                .init(name: "showHidden", value: "true"),
                .init(name: "maxResults", value: "100"),
            ]
            if let pageToken { query.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
            let page = try await get(query.url!.absoluteString, token: token)
            for item in page["items"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String,
                      let title = item["title"] as? String, !title.isEmpty,
                      let due = (item["due"] as? String).flatMap({ GoogleTask.dueDay(from: $0) }) else { continue }
                found.append(GoogleTask(
                    id: id, listID: listID, title: title,
                    isCompleted: (item["status"] as? String) == "completed",
                    due: due,
                    notes: (item["notes"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    minutes: Defaults[.googleTaskTimes][id],
                    link: (item["webViewLink"] as? String).flatMap(URL.init(string:))
                ))
            }
            pageToken = page["nextPageToken"] as? String
            if pageToken == nil { break }
        }
        return found
    }

    /// Saves a new title, due day, notes and done state; true if Google took it.
    func update(_ task: GoogleTask, title: String, due: Date, notes: String, isCompleted: Bool, minutes: Int?) async -> Bool {
        var times = Defaults[.googleTaskTimes]
        times[task.id] = minutes
        Defaults[.googleTaskTimes] = times
        var body: [String: Any] = [
            "title": title,
            "due": GoogleTask.dueText(for: due),
            "notes": notes,
            "status": isCompleted ? "completed" : "needsAction",
        ]
        if !isCompleted { body["completed"] = NSNull() }
        // Shown at once; Google confirms in the background and a failure
        // puts the old task back.
        let updated = GoogleTask(id: task.id, listID: task.listID, title: title, isCompleted: isCompleted,
                                 due: Calendar.current.startOfDay(for: due), notes: notes.isEmpty ? nil : notes,
                                 minutes: minutes, link: task.link)
        replace(task.id, with: updated)
        Task {
            do {
                try await send("PATCH", task, body: body)
            } catch {
                replace(task.id, with: task)
                var times = Defaults[.googleTaskTimes]
                times[task.id] = task.minutes
                Defaults[.googleTaskTimes] = times
                statusMessage = error.localizedDescription
            }
        }
        return true
    }

    private func replace(_ id: String, with task: GoogleTask) {
        if let index = tasks.firstIndex(where: { $0.id == id }) { tasks[index] = task }
    }

    /// Deletes the task on Google; true if it's gone.
    func delete(_ task: GoogleTask) async -> Bool {
        // Gone at once; back if Google refuses.
        tasks.removeAll { $0.id == task.id }
        Task {
            do {
                try await send("DELETE", task, body: nil)
            } catch {
                tasks.append(task)
                statusMessage = error.localizedDescription
            }
        }
        return true
    }

    private func send(_ method: String, _ task: GoogleTask, body: [String: Any]?) async throws {
        let token = try await validAccessToken()
        var request = URLRequest(url: URL(string: "https://tasks.googleapis.com/tasks/v1/lists/\(task.listID)/tasks/\(task.id)")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw GoogleTasksError.server("Couldn't save the task.")
        }
    }

    func setCompleted(_ task: GoogleTask, _ completed: Bool) async {
        // Shown at once; Google confirms in the background.
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index].isCompleted = completed
        }
        do {
            let token = try await validAccessToken()
            var request = URLRequest(url: URL(string: "https://tasks.googleapis.com/tasks/v1/lists/\(task.listID)/tasks/\(task.id)")!)
            request.httpMethod = "PATCH"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["status": completed ? "completed" : "needsAction"]
            if !completed { body["completed"] = NSNull() }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw GoogleTasksError.server("Couldn't update the task.")
            }
        } catch {
            // Put it back.
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index].isCompleted = !completed
            }
            statusMessage = error.localizedDescription
        }
    }

    /// Tasks due on `day`, from what's loaded.
    func tasks(on day: Date, calendar: Calendar = .current) -> [GoogleTask] {
        tasks.filter { calendar.isDate($0.due, inSameDayAs: day) }
    }

    // MARK: - Tokens and requests

    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval
        /// The scopes granted, space-separated.
        let scope: String?
    }

    private func store(_ token: TokenResponse) {
        // A minute early, so a request never starts with a token about to expire.
        accessToken = (token.accessToken, Date().addingTimeInterval(token.expiresIn - 60))
        if let granted = token.scope?.split(separator: " ").map(String.init) {
            hasCalendarAccess = Self.calendarScopes.allSatisfy(granted.contains)
        }
    }

    /// Shared with Google Calendar requests, which use the same sign-in.
    func validAccessToken() async throws -> String {
        if let accessToken, accessToken.expires > Date() { return accessToken.value }
        let token = try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": Self.refreshToken,
        ])
        store(token)
        return token.accessToken
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
        var body = fields
        let client = Self.client
        body["client_id"] = client.id
        if !client.secret.isEmpty { body["client_secret"] = client.secret }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let error = json["error"] as? String {
            // A refresh token that stopped working means signing in again.
            if error == "invalid_grant" { signOut() }
            throw GoogleTasksError.server((json["error_description"] as? String) ?? error)
        }
        guard let access = json["access_token"] as? String else {
            throw GoogleTasksError.server("Unexpected reply from Google.")
        }
        return TokenResponse(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String,
            expiresIn: (json["expires_in"] as? TimeInterval) ?? 3600,
            scope: json["scope"] as? String
        )
    }

    private func get(_ urlString: String, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: urlString)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if (response as? HTTPURLResponse)?.statusCode != 200 {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "Google Tasks request failed."
            throw GoogleTasksError.server(message)
        }
        return json
    }
}

/// Keeps the Google refresh token in the login Keychain, readable only by Chora.
private enum RefreshTokenKeychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Chora Google sign-in",
        kSecAttrAccount as String: "refresh-token",
    ]

    static func load() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ token: String) -> Bool {
        let data = Data(token.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}


