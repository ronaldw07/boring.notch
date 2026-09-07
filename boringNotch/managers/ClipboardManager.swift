//
//  ClipboardManager.swift
//  boringNotch
//
//  Keeps a short history of what has been copied, so it can be pasted again
//  later from the notch.
//

import AppKit
import Foundation

private let historyLimit = 50
private let pollInterval: Duration = .milliseconds(500)

struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    let copiedAt: Date
    let text: String?
    /// Session only. Image payloads are deliberately left out of the store —
    /// they are large, and a history of them is worth far less than the text.
    var imageData: Data?

    enum CodingKeys: String, CodingKey {
        case id, copiedAt, text
    }

    var isImage: Bool { imageData != nil }
}

@MainActor
final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published private(set) var items: [ClipboardItem] = []

    private var lastChangeCount: Int
    private var pollTask: Task<Void, Never>?
    private let storeURL: URL?

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
        storeURL = Self.makeStoreURL()
        items = Self.load(from: storeURL)
        startPolling()
    }

    deinit {
        pollTask?.cancel()
    }

    /// Puts an entry back on the pasteboard so the next paste uses it.
    func copy(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if let text = item.text {
            pasteboard.setString(text, forType: .string)
        } else if let data = item.imageData, let image = NSImage(data: data) {
            pasteboard.writeObjects([image])
        }

        // Re-copying our own entry shouldn't read back as a new one.
        lastChangeCount = pasteboard.changeCount
    }

    func clear() {
        items = []
        save()
    }

    func delete(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    // MARK: - Capture

    /// AppKit has no change notification for the pasteboard, so polling its
    /// change counter is the only way to notice a copy.
    private func startPolling() {
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, let self else { return }
                self.captureIfChanged()
            }
        }
    }

    private func captureIfChanged() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            record(ClipboardItem(id: UUID(), copiedAt: .now, text: text, imageData: nil))
            return
        }

        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            record(ClipboardItem(id: UUID(), copiedAt: .now, text: nil, imageData: data))
        }
    }

    private func record(_ item: ClipboardItem) {
        // Copying the same thing twice in a row shouldn't stack up.
        if let newest = items.first,
           newest.text == item.text,
           newest.imageData == item.imageData {
            return
        }

        items.insert(item, at: 0)
        if items.count > historyLimit {
            items.removeLast(items.count - historyLimit)
        }
        save()
    }

    // MARK: - Store

    private static func makeStoreURL() -> URL? {
        guard let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("clipboard-history.json")
    }

    private static func load(from url: URL?) -> [ClipboardItem] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ClipboardItem].self, from: data)) ?? []
    }

    private func save() {
        guard let storeURL else { return }
        let persistable = items.filter { $0.text != nil }
        guard let data = try? JSONEncoder().encode(persistable) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
