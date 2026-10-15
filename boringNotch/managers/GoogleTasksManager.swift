//
//  GoogleTasksManager.swift
//  boringNotch
//
//  Google Tasks don't sync to the Mac's Calendar, so they're fetched from
//  Google directly. Sign-in is the standard desktop flow: the browser opens,
//  Google redirects back to a one-shot listener on 127.0.0.1, and the code
//  is traded for tokens. Needs a client ID created in Google Cloud Console
//  (Settings › Calendar explains how).
//

import AppKit
import Defaults
import Foundation

struct GoogleTask: Identifiable, Equatable {
    let id: String
    let listID: String
    let title: String
    var isCompleted: Bool
}

enum GoogleTasksError: LocalizedError {
    case notConfigured
    case denied(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add your Google client ID first."
        case .denied(let reason): return "Google said no: \(reason)"
        case .server(let message): return message
        }
    }
}

@MainActor
final class GoogleTasksManager: ObservableObject {
    static let shared = GoogleTasksManager()

    @Published private(set) var tasks: [GoogleTask] = []
    @Published private(set) var isSignedIn: Bool = !Defaults[.googleRefreshToken].isEmpty
    @Published private(set) var statusMessage: String?
    @Published private(set) var isSigningIn = false

    private static let scope = "https://www.googleapis.com/auth/tasks"
    private var accessToken: (value: String, expires: Date)?

    private init() {}

    var isConfigured: Bool { !Defaults[.googleClientID].trimmingCharacters(in: .whitespaces).isEmpty }

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
                .init(name: "client_id", value: Defaults[.googleClientID]),
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
            Defaults[.googleRefreshToken] = refresh
            store(token)
            isSignedIn = true
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func signOut() {
        Defaults[.googleRefreshToken] = ""
        accessToken = nil
        tasks = []
        isSignedIn = false
        statusMessage = nil
    }

    // MARK: - Tasks

    /// Tasks due on `day`. Google keeps a due *date*, no time, so these
    /// show as a strip rather than on the timeline.
    func reload(for day: Date) async {
        guard isSignedIn else {
            if !tasks.isEmpty { tasks = [] }
            return
        }
        do {
            let token = try await validAccessToken()
            let (min, max) = Self.dueRange(for: day)

            let lists = try await get("https://tasks.googleapis.com/tasks/v1/users/@me/lists?maxResults=100", token: token)
            var found: [GoogleTask] = []
            for list in lists["items"] as? [[String: Any]] ?? [] {
                guard let listID = list["id"] as? String else { continue }
                var query = URLComponents(string: "https://tasks.googleapis.com/tasks/v1/lists/\(listID)/tasks")!
                query.queryItems = [
                    .init(name: "showCompleted", value: "true"),
                    .init(name: "showHidden", value: "true"),
                    .init(name: "maxResults", value: "100"),
                    .init(name: "dueMin", value: min),
                    .init(name: "dueMax", value: max),
                ]
                let page = try await get(query.url!.absoluteString, token: token)
                for item in page["items"] as? [[String: Any]] ?? [] {
                    guard let id = item["id"] as? String,
                          let title = item["title"] as? String, !title.isEmpty else { continue }
                    found.append(GoogleTask(
                        id: id, listID: listID, title: title,
                        isCompleted: (item["status"] as? String) == "completed"
                    ))
                }
            }
            if Defaults[.hideCompletedReminders] {
                found.removeAll { $0.isCompleted }
            }
            if found != tasks { tasks = found }
        } catch {
            statusMessage = error.localizedDescription
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

    /// RFC 3339 bounds for tasks due on a local calendar date. Google stores
    /// a due date as midnight UTC of that date.
    private static func dueRange(for day: Date) -> (String, String) {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let date = String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
        return ("\(date)T00:00:00.000Z", "\(date)T23:59:59.000Z")
    }

    // MARK: - Tokens and requests

    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval
    }

    private func store(_ token: TokenResponse) {
        // A minute early, so a request never starts with a token about to expire.
        accessToken = (token.accessToken, Date().addingTimeInterval(token.expiresIn - 60))
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, accessToken.expires > Date() { return accessToken.value }
        let token = try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": Defaults[.googleRefreshToken],
        ])
        store(token)
        return token.accessToken
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
        var body = fields
        body["client_id"] = Defaults[.googleClientID]
        let secret = Defaults[.googleClientSecret]
        if !secret.isEmpty { body["client_secret"] = secret }

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
            expiresIn: (json["expires_in"] as? TimeInterval) ?? 3600
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
