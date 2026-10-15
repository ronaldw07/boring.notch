//
//  AppVolumeManager.swift
//  boringNotch
//
//  Which apps are making sound, and a volume for each. An app is only
//  tapped while its slider is below 100%; at 100% the tap is torn down so
//  the app plays exactly as it would without us.
//

import AppKit
import AudioToolbox
import CoreAudio
import Foundation

@MainActor
final class AppVolumeManager: ObservableObject {
    static let shared = AppVolumeManager()

    struct Entry: Identifiable, Equatable {
        /// Owning app's bundle identifier (or the process's own, for things
        /// that aren't part of a running app).
        let id: String
        let name: String
        let icon: NSImage?
        let processObjectIDs: Set<AudioObjectID>
        /// Making sound right now, as opposed to just open.
        let isPlaying: Bool

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name && lhs.processObjectIDs == rhs.processObjectIDs
                && lhs.isPlaying == rhs.isPlaying
        }
    }

    @Published private(set) var apps: [Entry] = []
    /// Slider positions for apps that have been moved off 100%.
    @Published private(set) var levels: [String: Double] = [:]
    /// Set when a tap couldn't be started, cleared on the next success.
    @Published private(set) var failedAppName: String?

    private static let pollInterval: Duration = .seconds(1)
    private static let fullVolumeThreshold = 0.995

    private var taps: [String: Any] = [:]
    private var gains: [String: GainBox] = [:]
    private var lastEntries: [String: Entry] = [:]
    private var holders = 0
    private var pollTask: Task<Void, Never>?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    private init() {}

    // MARK: - Polling

    /// Each visible panel holds one; nothing polls with the notch closed.
    func beginPolling() {
        holders += 1
        guard pollTask == nil else { return }
        installDeviceListener()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func endPolling() {
        holders = max(0, holders - 1)
        guard holders == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    func level(for entry: Entry) -> Double {
        levels[entry.id] ?? 1
    }

    // MARK: - Volume

    /// Slider position 0...1. Squared into gain so the lower half of the
    /// slider isn't nearly all the range: 50% is a quarter of the amplitude
    /// (-12 dB), which is what half volume sounds like.
    func setLevel(_ value: Double, for entry: Entry) {
        let position = min(max(value, 0), 1)
        let isFull = position >= Self.fullVolumeThreshold

        if isFull {
            levels[entry.id] = nil
            stopTap(for: entry.id)
            gains[entry.id] = nil
            return
        }

        levels[entry.id] = position
        let gain = Float(position * position)

        if let box = gains[entry.id] {
            box.target = gain
        } else {
            let box = GainBox(gain)
            gains[entry.id] = box
            startTap(for: entry, gain: box)
        }
    }

    private func startTap(for entry: Entry, gain: GainBox) {
        guard #available(macOS 14.2, *) else { return }
        if let tap = AppVolumeTap(processObjectIDs: entry.processObjectIDs, name: entry.name, gain: gain) {
            taps[entry.id] = tap
            failedAppName = nil
        } else {
            // Leave the slider where the app really is.
            levels[entry.id] = nil
            gains[entry.id] = nil
            failedAppName = entry.name
        }
    }

    private func stopTap(for id: String) {
        guard #available(macOS 14.2, *) else { return }
        (taps[id] as? AppVolumeTap)?.stop()
        taps[id] = nil
    }

    /// The tap is built against one output device; when that changes it has
    /// to be rebuilt against the new one.
    private func rebuildAllTaps() {
        for id in Array(taps.keys) {
            guard let entry = lastEntries[id], let gain = gains[id] else { continue }
            stopTap(for: id)
            startTap(for: entry, gain: gain)
        }
    }

    private func installDeviceListener() {
        guard deviceListener == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.rebuildAllTaps() }
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    // MARK: - Discovery

    private func refresh() {
        let found = Self.currentEntries()
        var merged = found

        // An app with a volume set stays listed even while it's silent, and
        // its tap follows its processes: a browser opens a new audio helper
        // per tab, and one the tap doesn't know about plays at full volume.
        for id in Array(taps.keys) {
            if let fresh = found.first(where: { $0.id == id }) {
                if let old = lastEntries[id], old.processObjectIDs != fresh.processObjectIDs,
                   let gain = gains[id] {
                    stopTap(for: id)
                    startTap(for: fresh, gain: gain)
                }
            } else if let old = lastEntries[id] {
                if Self.isStillRunning(old) {
                    merged.append(old)
                } else {
                    stopTap(for: id)
                    gains[id] = nil
                    levels[id] = nil
                }
            }
        }

        // Playing apps first, so what you're hearing is at the top.
        merged.sort {
            $0.isPlaying != $1.isPlaying
                ? $0.isPlaying
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        for entry in merged { lastEntries[entry.id] = entry }
        if merged != apps {
            apps = merged
        }
    }

    private static func isStillRunning(_ entry: Entry) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: entry.id).isEmpty == false
    }

    private struct AudioProcess {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let isRunningOutput: Bool
    }

    /// Open media apps, plus anything playing right now, one entry per
    /// owning app — a browser's audio comes from helper processes, which
    /// belong under the browser rather than as rows of their own. A paused
    /// Spotify is listed; an idle Notion or a background service is not.
    private static func currentEntries() -> [Entry] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy != .prohibited && $0.bundleIdentifier != nil
        }

        var groups: [String: (name: String, icon: NSImage?, ids: Set<AudioObjectID>, playing: Bool, isOpenApp: Bool)] = [:]
        for process in audioProcesses() where process.pid != ownPID {
            let owner = owningApp(of: process, among: candidates)
            let key = owner?.bundleIdentifier ?? process.bundleID
            guard !key.isEmpty else { continue }
            var group = groups[key] ?? (
                owner?.localizedName ?? key.split(separator: ".").last.map(String.init) ?? key,
                owner?.icon,
                [],
                false,
                owner.map(isMediaApp) ?? false
            )
            group.ids.insert(process.objectID)
            group.playing = group.playing || process.isRunningOutput
            groups[key] = group
        }
        return groups
            .filter { $0.value.playing || $0.value.isOpenApp }
            .map { Entry(id: $0.key, name: $0.value.name, icon: $0.value.icon,
                         processObjectIDs: $0.value.ids, isPlaying: $0.value.playing) }
    }

    private static let mediaCategories: Set<String> = [
        "public.app-category.music",
        "public.app-category.video",
        "public.app-category.entertainment",
        "public.app-category.social-networking",
        "public.app-category.games",
    ]
    private static var mediaAppCache: [String: Bool] = [:]

    /// Worth listing while silent: declares itself a music, video, social
    /// or game app, or is a browser (it handles web links).
    private static func isMediaApp(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return false }
        if let cached = mediaAppCache[id] { return cached }

        let info = app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary } ?? [:]
        let category = info["LSApplicationCategoryType"] as? String ?? ""
        let schemes = (info["CFBundleURLTypes"] as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
            .map { $0.lowercased() }
        let result = mediaCategories.contains(category)
            || category.hasSuffix("-games")
            || schemes.contains("http") || schemes.contains("https")
        mediaAppCache[id] = result
        return result
    }

    private static func owningApp(of process: AudioProcess, among candidates: [NSRunningApplication]) -> NSRunningApplication? {
        if let own = candidates.first(where: { $0.processIdentifier == process.pid }) {
            return own
        }
        // Helpers are named after their app: com.google.Chrome.helper.Renderer
        // belongs to com.google.Chrome. Longest match wins.
        let byName = candidates
            .filter { app in
                guard let id = app.bundleIdentifier else { return false }
                return process.bundleID == id || process.bundleID.hasPrefix(id + ".")
            }
            .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
        if let byName { return byName }

        // Safari's audio comes from shared WebKit services, not helpers
        // named after it.
        if process.bundleID.hasPrefix("com.apple.WebKit.") {
            return candidates.first { $0.bundleIdentifier == "com.apple.Safari" }
        }

        var pid = process.pid
        for _ in 0 ..< 6 {
            guard let parent = parentPID(of: pid), parent > 1 else { return nil }
            if let app = candidates.first(where: { $0.processIdentifier == parent }) { return app }
            pid = parent
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static func audioProcesses() -> [AudioProcess] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }

        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        return objects.compactMap { object in
            guard let pid: pid_t = property(object, kAudioProcessPropertyPID) else { return nil }
            let running: UInt32 = property(object, kAudioProcessPropertyIsRunningOutput) ?? 0
            return AudioProcess(
                objectID: object,
                pid: pid,
                bundleID: stringProperty(object, kAudioProcessPropertyBundleID) ?? "",
                isRunningOutput: running != 0
            )
        }
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value as String?
    }
}
