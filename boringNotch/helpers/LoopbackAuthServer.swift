//
//  LoopbackAuthServer.swift
//  boringNotch
//
//  The browser half of a desktop sign-in (Google Tasks, Spotify): the
//  provider redirects back to a one-shot listener on 127.0.0.1, which hands
//  the code to the caller. PKCE helpers live here too, since every flow that
//  uses the listener needs them.
//

import CryptoKit
import Foundation
import Network

enum LoopbackAuthError: LocalizedError {
    case timedOut

    var errorDescription: String? { "Sign-in timed out. Try again." }
}

enum PKCE {
    static func randomString(length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0 ..< length).map { _ in alphabet.randomElement()! })
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Listens on a loopback port for the single redirect sent after sign-in,
/// and hands back its query parameters.
final class LoopbackAuthServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.boringNotch.loopbackAuth")
    private let callbacks: AsyncStream<[String: String]>
    private let continuation: AsyncStream<[String: String]>.Continuation

    /// `port` is for providers that only accept a redirect address registered
    /// in advance. Without it the system picks a free one.
    init(port: UInt16? = nil) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        if let port, let fixed = NWEndpoint.Port(rawValue: port) {
            listener = try NWListener(using: parameters, on: fixed)
        } else {
            listener = try NWListener(using: parameters)
        }
        (callbacks, continuation) = AsyncStream.makeStream(of: [String: String].self)
    }

    deinit {
        listener.cancel()
    }

    /// Resolves with the port once the listener is up.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [listener] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    ready.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    ready.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    func waitForCallback(timeout: Duration) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask { [callbacks] in
                for await parameters in callbacks { return parameters }
                throw LoopbackAuthError.timedOut
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LoopbackAuthError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? [:]
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let data, let request = String(data: data, encoding: .utf8),
                  let line = request.split(separator: "\r\n").first else {
                connection.cancel()
                return
            }

            // "GET /?code=...&state=... HTTP/1.1"
            let pieces = line.split(separator: " ")
            guard pieces.count >= 2, let url = URLComponents(string: "http://127.0.0.1" + pieces[1]) else {
                connection.cancel()
                return
            }
            let parameters = Dictionary(
                (url.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
                uniquingKeysWith: { first, _ in first }
            )
            // The browser also asks for /favicon.ico; only the real
            // redirect carries a code or an error.
            guard parameters["code"] != nil || parameters["error"] != nil else {
                connection.cancel()
                return
            }

            let page = "<html><body style=\"font-family:-apple-system;text-align:center;padding-top:80px\">"
                + "<h2>You're signed in.</h2><p>You can close this tab and go back to the notch.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            self?.continuation.yield(parameters)
            self?.continuation.finish()
        }
    }
}
