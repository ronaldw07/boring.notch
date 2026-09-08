//
//  SpotifyController.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import Foundation
import Combine
import SwiftUI

class SpotifyController: MediaControllerProtocol {
    func setFavorite(_ favorite: Bool) async {
        //Placeholder
    }
    
    // MARK: - Properties
    @Published private var playbackState: PlaybackState = PlaybackState(
        bundleIdentifier: "com.spotify.client"
    )
    
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        return true
    }

    var supportsFavorite: Bool { false }

    private var notificationTask: Task<Void, Never>?
    
    // Constant for time between command and update
    private let commandUpdateDelay: Duration = .milliseconds(25)

    private var lastArtworkURL: String?
    private var artworkFetchTask: Task<Void, Never>?
    
    /// How often Spotify's own position is re-read. Notifications only fire
    /// on play, pause and track changes, so between them nothing corrects a
    /// seek made in Spotify itself, or any drift against our own clock.
    private static let pollInterval: Duration = .milliseconds(500)

    private var pollTask: Task<Void, Never>?

    init() {
        setupPlaybackStateChangeObserver()
        Task {
            if isActive() {
                await updatePlaybackInfo()
            }
        }
        startPolling()
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, self.isActive() else { continue }
                await self.updatePlaybackInfo()
            }
        }
    }
    
    private func setupPlaybackStateChangeObserver() {
        notificationTask = Task { @Sendable [weak self] in
            let notifications = DistributedNotificationCenter.default().notifications(
                named: NSNotification.Name("com.spotify.client.PlaybackStateChanged")
            )
            
            for await _ in notifications {
                await self?.updatePlaybackInfo()
            }
        }
    }
    
    deinit {
        notificationTask?.cancel()
        artworkFetchTask?.cancel()
        pollTask?.cancel()
    }
    
    // MARK: - Protocol Implementation
    func play() async { await executeCommand("play") }
    func pause() async { await executeCommand("pause") }
    func togglePlay() async { await executeCommand("playpause") }
    func nextTrack() async { await executeCommand("next track") }
    func previousTrack() async {
        await executeAndRefresh("previous track")
    }
    
    func seek(to time: Double) async {
        await executeAndRefresh("set player position to \(time)")
    }
    
    func toggleShuffle() async {
        await executeAndRefresh("set shuffling to not shuffling")
    }
    
    func toggleRepeat() async {
        await executeAndRefresh("set repeating to not repeating")
    }
    
    func setVolume(_ level: Double) async {
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)
        await executeCommand("set sound volume to \(volumePercentage)")
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }
    
    func isActive() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == playbackState.bundleIdentifier }
    }
    
    /// True while a read is in flight. Polling and Spotify's own change
    /// notification both call this, so without a guard two reads overlap and
    /// the slower one lands last — applying a position from before the one
    /// already on screen. That is the flicker back and forth after a seek.
    private var isReadingPlaybackInfo = false

    /// When the most recently applied read was started, so a result that was
    /// overtaken can be recognised and dropped rather than applied late.
    private var latestAppliedRead: Date = .distantPast

    /// When we last told Spotify to do something. A read already in flight
    /// when a seek goes out samples the position from before it, and lands
    /// afterwards carrying the old number — which is the seek showing
    /// correctly for a moment and then being overwritten by where the track
    /// used to be. Anything begun before the command can only describe the
    /// world before it, so it is dropped.
    private var lastCommandAt: Date = .distantPast

    func updatePlaybackInfo() async {
        guard !isReadingPlaybackInfo else { return }
        isReadingPlaybackInfo = true
        let startedAt = Date()
        defer { isReadingPlaybackInfo = false }

        guard let descriptor = try? await fetchPlaybackInfoAsync() else { return }
        guard descriptor.numberOfItems >= 10 else { return }
        guard startedAt >= latestAppliedRead, startedAt >= lastCommandAt else { return }
        latestAppliedRead = startedAt
        
        let isPlaying = descriptor.atIndex(1)?.booleanValue ?? false
        let currentTrack = descriptor.atIndex(2)?.stringValue ?? "Unknown"
        let currentTrackArtist = descriptor.atIndex(3)?.stringValue ?? "Unknown"
        let currentTrackAlbum = descriptor.atIndex(4)?.stringValue ?? "Unknown"
        let currentTime = descriptor.atIndex(5)?.doubleValue ?? 0
        let duration = (descriptor.atIndex(6)?.doubleValue ?? 0)/1000
        let isShuffled = descriptor.atIndex(7)?.booleanValue ?? false
        let isRepeating = descriptor.atIndex(8)?.booleanValue ?? false
        let volumePercentage = descriptor.atIndex(9)?.int32Value ?? 50
        let artworkURL = descriptor.atIndex(10)?.stringValue ?? ""
        
        var state = PlaybackState(
            bundleIdentifier: "com.spotify.client",
            isPlaying: isPlaying,
            title: currentTrack,
            artist: currentTrackArtist,
            album: currentTrackAlbum,
            currentTime: currentTime,
            duration: duration,
            playbackRate: 1,
            isShuffled: isShuffled,
            repeatMode: isRepeating ? .all : .off,
            // Spotify read the position somewhere inside the script's run, not
            // at the moment it returned, so the midpoint is the closest we can
            // honestly place it. Stamping the return instead dated every
            // position slightly early and left the readout running ahead.
            lastUpdated: startedAt.addingTimeInterval(Date().timeIntervalSince(startedAt) / 2),
            artwork: nil,
            volume: Double(volumePercentage) / 100.0
        )
        // Read from Spotify just now, so it is the position, not a claim about it.
        state.isPositionLive = true

        if artworkURL == lastArtworkURL, let existingArtwork = self.playbackState.artwork {
            state.artwork = existingArtwork
        }

    playbackState = state

        if !artworkURL.isEmpty, let url = URL(string: artworkURL) {
            guard artworkURL != lastArtworkURL || state.artwork == nil else { return }
            artworkFetchTask?.cancel()

            let currentState = state

            artworkFetchTask = Task {
                do {
                    let data = try await ImageService.shared.fetchImageData(from: url)

                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        var updatedState = currentState
                        updatedState.artwork = data
                        self.playbackState = updatedState
                        self.lastArtworkURL = artworkURL
                        self.artworkFetchTask = nil
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.artworkFetchTask = nil
                    }
                }
            }
        }
    }
    
// MARK: - Private Methods
    
    private func executeCommand(_ command: String) async {
        // Stamped before the command goes out, so every read already running
        // is treated as describing the world before it.
        lastCommandAt = Date()
        let script = "tell application \"Spotify\" to \(command)"
        try? await AppleScriptHelper.executeVoid(script)
    }

    private func executeAndRefresh(_ command: String) async {
        await executeCommand(command)
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }
    
    private func fetchPlaybackInfoAsync() async throws -> NSAppleEventDescriptor? {
        let script = """
        tell application "Spotify"
            set isRunning to true
            try
                set playerState to player state is playing
                set currentTrackName to name of current track
                set currentTrackArtist to artist of current track
                set currentTrackAlbum to album of current track
                set trackPosition to player position
                set trackDuration to duration of current track
                set shuffleState to shuffling
                set repeatState to repeating
                set currentVolume to sound volume
                set artworkURL to artwork url of current track
                return {playerState, currentTrackName, currentTrackArtist, currentTrackAlbum, trackPosition, trackDuration, shuffleState, repeatState, currentVolume, artworkURL}
            on error
                return {false, "Unknown", "Unknown", "Unknown", 0, 0, false, false, 50, ""}
            end try
        end tell
        """
        
        return try await AppleScriptHelper.execute(script)
    }
    
}
