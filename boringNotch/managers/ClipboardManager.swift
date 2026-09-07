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

/// What a captured pasteboard entry actually was, so the row and the
/// re-copy logic can treat a file, a link, an image and plain text
/// differently instead of guessing from a string's shape.
enum ClipboardKind: Codable, Equatable {
    case text(String)
    case link(URL)
    case file(URL)
    case image(filename: String)
}

struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    let copiedAt: Date
    let kind: ClipboardKind
}

@MainActor
final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published private(set) var items: [ClipboardItem] = []

    private var lastChangeCount: Int
    private var pollTask: Task<Void, Never>?
    private let storeURL: URL?
    private let imagesDirectory: URL?

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
        storeURL = Self.makeStoreURL()
        imagesDirectory = Self.makeImagesDirectory()
        items = Self.load(from: storeURL)
        pruneOrphanedImages()
        startPolling()
    }

    deinit {
        pollTask?.cancel()
    }

    /// Puts an entry back on the pasteboard so the next paste uses it.
    func copy(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.kind {
        case .text(let text):
            pasteboard.setString(text, forType: .string)
        case .link(let url):
            // Written both ways: the URL type is what most apps expect to
            // paste back into a link field, but anything that only reads
            // plain text still needs the address to land somewhere.
            pasteboard.writeObjects([url as NSURL])
            pasteboard.setString(url.absoluteString, forType: .string)
        case .file(let url):
            // Must go back as an actual file URL — a text path pasted into
            // Finder doesn't behave like a file.
            pasteboard.writeObjects([url as NSURL])
        case .image(let filename):
            if let url = imageURL(forFilename: filename), let image = NSImage(contentsOf: url) {
                pasteboard.writeObjects([image])
            }
        }

        // Re-copying our own entry shouldn't read back as a new one.
        lastChangeCount = pasteboard.changeCount
    }

    func clear() {
        items.forEach { deleteImageFile(for: $0) }
        items = []
        save()
    }

    func delete(_ item: ClipboardItem) {
        deleteImageFile(for: item)
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

        guard let kind = captureKind(from: pasteboard) else { return }
        record(ClipboardItem(id: UUID(), copiedAt: .now, kind: kind))
    }

    /// Checked most specific first. A single copy often puts several
    /// representations on the pasteboard at once — a Finder file copy is
    /// also a plain-text path, an image can be both PNG and TIFF — so the
    /// generic string fallback would otherwise win every time.
    private func captureKind(from pasteboard: NSPasteboard) -> ClipboardKind? {
        if let url = fileURL(from: pasteboard) {
            return .file(url)
        }

        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            guard let filename = writeImage(data) else { return nil }
            return .image(filename: filename)
        }

        if let string = pasteboard.string(forType: .string) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if let url = URL(string: trimmed),
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                return .link(url)
            }
            return .text(string)
        }

        return nil
    }

    /// `.string(forType: .fileURL)` also matches a plain text path, so
    /// reading through `readObjects` with file-URL-only reading is what
    /// actually distinguishes a Finder copy from typed or pasted text.
    private func fileURL(from pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return nil
        }
        return urls.first
    }

    private func record(_ item: ClipboardItem) {
        // Copying the same thing twice in a row shouldn't stack up.
        if let newest = items.first, newest.kind == item.kind {
            return
        }

        items.insert(item, at: 0)

        let overflowCount = items.count - historyLimit
        if overflowCount > 0 {
            items.suffix(overflowCount).forEach { deleteImageFile(for: $0) }
            items.removeLast(overflowCount)
        }

        save()
    }

    // MARK: - Images

    /// Every stored image is re-encoded to PNG through NSBitmapImageRep,
    /// whether the pasteboard offered PNG or TIFF, so loading one back
    /// later never has to branch on which representation the source app
    /// happened to provide.
    private func writeImage(_ data: Data) -> String? {
        guard let imagesDirectory,
              let bitmap = NSBitmapImageRep(data: data),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return nil }

        let filename = "\(UUID().uuidString).png"
        guard (try? pngData.write(to: imagesDirectory.appendingPathComponent(filename), options: .atomic)) != nil
        else { return nil }
        return filename
    }

    /// Rows load an image back from disk by filename to render a thumbnail;
    /// the store only ever keeps the name, never the bytes.
    func imageURL(forFilename filename: String) -> URL? {
        imagesDirectory?.appendingPathComponent(filename)
    }

    private func deleteImageFile(for item: ClipboardItem) {
        guard case .image(let filename) = item.kind, let imagesDirectory else { return }
        try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(filename))
    }

    /// Runs once at launch. An image can end up with nothing pointing at it
    /// if its item fell off the end of the history, was deleted, or the app
    /// quit between writing the file and saving the item that references
    /// it — any of those would otherwise leave the file on disk forever.
    private func pruneOrphanedImages() {
        guard let imagesDirectory else { return }
        let referenced = Set(items.compactMap { item -> String? in
            guard case .image(let filename) = item.kind else { return nil }
            return filename
        })

        let files = (try? FileManager.default.contentsOfDirectory(
            at: imagesDirectory, includingPropertiesForKeys: nil
        )) ?? []

        for file in files where !referenced.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Store

    private static func applicationSupportDirectory() -> URL? {
        guard let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func makeStoreURL() -> URL? {
        applicationSupportDirectory()?.appendingPathComponent("clipboard-history.json")
    }

    private static func makeImagesDirectory() -> URL? {
        guard let directory = applicationSupportDirectory()?
            .appendingPathComponent("clipboard-images", isDirectory: true) else { return nil }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func load(from url: URL?) -> [ClipboardItem] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }

        // The common case: every entry still matches the current shape.
        if let items = try? JSONDecoder().decode([ClipboardItem].self, from: data) {
            return items
        }

        // A whole-array decode fails the moment a single entry doesn't match
        // — e.g. after an update changes a case's associated data. That used
        // to mean losing the entire history over one incompatible entry, the
        // very next time anything was copied or deleted triggered a save()
        // that overwrote the file with nothing. Decoding item by item keeps
        // everything that still parses and drops only what doesn't.
        guard let rawItems = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        let decoder = JSONDecoder()
        return rawItems.compactMap { raw in
            guard let itemData = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
            return try? decoder.decode(ClipboardItem.self, from: itemData)
        }
    }

    private func save() {
        guard let storeURL else { return }
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
