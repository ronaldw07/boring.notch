//
//  MusicManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 03/08/24.
//
import AppKit
import Combine
import Defaults
import SwiftUI

let defaultImage: NSImage = .init(
    systemSymbolName: "heart.fill",
    accessibilityDescription: "Album Art"
)!

class MusicManager: ObservableObject {
    // MARK: - Properties
    static let shared = MusicManager()
    private var cancellables = Set<AnyCancellable>()
    private var controllerCancellables = Set<AnyCancellable>()
    private var debounceIdleTask: Task<Void, Never>?

    // Helper to check if macOS has removed support for NowPlayingController
    public private(set) var isNowPlayingDeprecated: Bool = false
    private let mediaChecker = MediaChecker()

    // Active controller
    private var activeController: (any MediaControllerProtocol)?

    // Published properties for UI
    @Published var songTitle: String = "I'm Handsome"
    @Published var artistName: String = "Me"
    @Published var albumArt: NSImage = defaultImage
    @Published var isPlaying = false
    @Published var album: String = "Self Love"
    @Published var isPlayerIdle: Bool = true
    @Published var animations: BoringAnimations = .init()
    @Published var avgColor: NSColor = .white
    @Published var bundleIdentifier: String? = nil
    @Published var songDuration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var timestampDate: Date = .init()
    @Published var playbackRate: Double = 1
    @Published var isShuffled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Double = 0.5
    @Published var volumeControlSupported: Bool = true
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Published var usingAppIconForArtwork: Bool = false
    @Published var currentLyrics: String = ""
    @Published var isFetchingLyrics: Bool = false
    @Published var syncedLyrics: [(time: Double, text: String)] = []
    @Published var canFavoriteTrack: Bool = false
    @Published var isFavoriteTrack: Bool = false

    private var artworkData: Data? = nil

    // Store last values at the time artwork was changed
    private var lastArtworkTitle: String = "I'm Handsome"
    private var lastArtworkArtist: String = "Me"
    private var lastArtworkAlbum: String = "Self Love"
    private var lastArtworkBundleIdentifier: String? = nil

    @Published var isFlipping: Bool = false
    private var flipWorkItem: DispatchWorkItem?

    @Published var isTransitioning: Bool = false
    private var transitionWorkItem: DispatchWorkItem?

    /// Backing state for `displayedPlaybackPosition`, which runs on its own
    /// clock and converges on the estimate rather than stepping onto it. Nil
    /// until the first read.
    private var shownPosition: TimeInterval?
    private var shownPositionReadAt: Date = .init()

    /// A reported position large enough from the estimate to be a seek,
    /// waiting on a second report before it's trusted. See
    /// `resolvedReportedPosition`.
    private var pendingOutlierReport: (value: TimeInterval, receivedAt: Date)?

    /// The instant playback was last seen to stop, which is the moment the
    /// frozen readout describes. Reports stamped before it are describing a
    /// moment that freeze already accounts for. Nil while playing.
    private var playbackStoppedAt: Date?

    /// The last number handed to the display, held so the next one can be
    /// checked against it. See `displayedPlaybackPosition`.
    private var lastDisplayed: TimeInterval?

    /// Set when something happens that genuinely moves playback backwards —
    /// a seek, or a new track. Until it passes, the readout is allowed to go
    /// back; outside it, going back is always a mistake upstream.
    private var backwardMoveAllowedUntil: Date?

    // MARK: - Initialization
    init() {
        // Listen for changes to the default controller preference
        NotificationCenter.default.publisher(for: Notification.Name.mediaControllerChanged)
            .sink { [weak self] _ in
                self?.setActiveControllerBasedOnPreference()
            }
            .store(in: &cancellables)

        // Initialize deprecation check asynchronously
        Task { @MainActor in
            do {
                self.isNowPlayingDeprecated = try await self.mediaChecker.checkDeprecationStatus()
                print("Deprecation check completed: \(self.isNowPlayingDeprecated)")
            } catch {
                print("Failed to check deprecation status: \(error). Defaulting to false.")
                self.isNowPlayingDeprecated = false
            }
            
            // Initialize the active controller after deprecation check
            self.setActiveControllerBasedOnPreference()
        }
    }

    deinit {
        destroy()
    }
    
    public func destroy() {
        debounceIdleTask?.cancel()
        cancellables.removeAll()
        controllerCancellables.removeAll()
        flipWorkItem?.cancel()
        transitionWorkItem?.cancel()

        // Release active controller
        activeController = nil
    }

    // MARK: - Setup Methods
    private func createController(for type: MediaControllerType) -> (any MediaControllerProtocol)? {
        // Cleanup previous controller
        if activeController != nil {
            controllerCancellables.removeAll()
            activeController = nil
        }

        let newController: (any MediaControllerProtocol)?

        switch type {
        case .nowPlaying:
            // Only create NowPlayingController if not deprecated on this macOS version
            if !self.isNowPlayingDeprecated {
                newController = NowPlayingController()
            } else {
                return nil
            }
        case .appleMusic:
            newController = AppleMusicController()
        case .spotify:
            newController = SpotifyController()
        case .youtubeMusic:
            newController = YouTubeMusicController()
        }

        // Set up state observation for the new controller
        if let controller = newController {
            controller.playbackStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self = self,
                          self.activeController === controller else { return }
                    self.updateFromPlaybackState(state)
                }
                .store(in: &controllerCancellables)
        }

        return newController
    }

    private func setActiveControllerBasedOnPreference() {
        let preferredType = Defaults[.mediaController]
        print("Preferred Media Controller: \(preferredType)")

        // If NowPlaying is deprecated but that's the preference, use Apple Music instead
        let controllerType = (self.isNowPlayingDeprecated && preferredType == .nowPlaying)
            ? .appleMusic
            : preferredType

        if let controller = createController(for: controllerType) {
            setActiveController(controller)
        } else if controllerType != .appleMusic, let fallbackController = createController(for: .appleMusic) {
            // Fallback to Apple Music if preferred controller couldn't be created
            setActiveController(fallbackController)
        }
    }

    private func setActiveController(_ controller: any MediaControllerProtocol) {
        // Cancel any existing flip animation
        flipWorkItem?.cancel()

        // Set new active controller
        activeController = controller
        
        self.canFavoriteTrack = controller.supportsFavorite

        // Get current state from active controller
        forceUpdate()
    }

    // MARK: - Update Methods
    @MainActor
    private func updateFromPlaybackState(_ state: PlaybackState) {
        // Captured before isPlaying and playbackRate flip, while the
        // extrapolation still describes the number actually on screen.
        let estimateBeforeUpdate = estimatedPlaybackPosition()
        let wasPlaying = self.isPlaying
        let didResume = !wasPlaying && state.isPlaying
        let didPause = wasPlaying && !state.isPlaying
        // A track change resets the position to zero, so it has to mean a
        // different track — never a frame that simply failed to name one.
        let trackChanged = !state.title.isEmpty
            && (state.title != self.songTitle || state.artist != self.artistName)

        // Check for playback state changes (playing/paused)
        if state.isPlaying != self.isPlaying {
            NSLog("Playback state changed: \(state.isPlaying ? "Playing" : "Paused")")
            withAnimation(.smooth) {
                self.isPlaying = state.isPlaying
                self.updateIdleState(state: state.isPlaying)
            }

            if state.isPlaying && !state.title.isEmpty && !state.artist.isEmpty {
                self.updateSneakPeek()
            }
        }

        // Check for changes in track metadata using last artwork change values
        let titleChanged = state.title != self.lastArtworkTitle
        let artistChanged = state.artist != self.lastArtworkArtist
        let albumChanged = state.album != self.lastArtworkAlbum
        let bundleChanged = state.bundleIdentifier != self.lastArtworkBundleIdentifier

        // Check for artwork changes
        let artworkChanged = state.artwork != nil && state.artwork != self.artworkData
        let hasContentChange = titleChanged || artistChanged || albumChanged || artworkChanged || bundleChanged

        // Handle artwork and visual transitions for changed content
        if hasContentChange {
            self.triggerFlipAnimation()

            if artworkChanged, let artwork = state.artwork {
                self.updateArtwork(artwork)
            } else if state.artwork == nil {
                // Try to use app icon if no artwork but track changed
                if let appIconImage = AppIconAsNSImage(for: state.bundleIdentifier) {
                    self.usingAppIconForArtwork = true
                    self.updateAlbumArt(newAlbumArt: appIconImage)
                }
            }
            self.artworkData = state.artwork

            if artworkChanged || state.artwork == nil {
                // Update last artwork change values
                self.lastArtworkTitle = state.title
                self.lastArtworkArtist = state.artist
                self.lastArtworkAlbum = state.album
                self.lastArtworkBundleIdentifier = state.bundleIdentifier
            }

            // Only update sneak peek if there's actual content and something changed
            if !state.title.isEmpty && !state.artist.isEmpty && state.isPlaying {
                self.updateSneakPeek()
            }

            // Fetch lyrics on content change
            self.fetchLyricsIfAvailable(bundleIdentifier: state.bundleIdentifier, title: state.title, artist: state.artist)
        }

        let timeChanged = state.currentTime != self.elapsedTime
        let durationChanged = state.duration != self.songDuration
        let playbackRateChanged = state.playbackRate != self.playbackRate
        let shuffleChanged = state.isShuffled != self.isShuffled
        let repeatModeChanged = state.repeatMode != self.repeatMode
        let volumeChanged = state.volume != self.volume
        
        if state.title != self.songTitle {
            self.songTitle = state.title
        }

        if state.artist != self.artistName {
            self.artistName = state.artist
        }

        if state.album != self.album {
            self.album = state.album
        }

        // elapsedTime and timestampDate are a single anchor — a position and
        // the moment it was true. Everything on screen is extrapolated from
        // the pair, so they have to move together or the readout shifts by
        // whatever gap opens between them.
        if trackChanged {
            // A different song is a hard reset — nothing about the old
            // position carries over. An update arriving without a position on
            // a track change means the new one hasn't started yet.
            self.elapsedTime = state.isCurrentTimeAuthoritative ? state.currentTime : 0
            self.timestampDate = state.isCurrentTimeAuthoritative ? sanitizedStamp(state.lastUpdated) : Date()
            self.pendingOutlierReport = nil
            self.allowBackwardMove()
            self.lastDisplayed = nil
        } else if state.isPositionLive {
            // Read from the player this instant, so there is nothing to
            // second-guess: no corroboration, no staleness rules, no holding
            // it back. A difference big enough to be a seek is a seek, and
            // the readout follows it wherever it goes, including backwards.
            // Any backward disagreement with a live reading is the player
            // having moved, not noise to be smoothed away, so the readout is
            // freed to follow it rather than being held by the no-going-back
            // rule that exists for the streamed source.
            if state.currentTime < estimateBeforeUpdate - 0.25 {
                allowBackwardMove()
            }
            self.elapsedTime = state.currentTime
            self.timestampDate = state.lastUpdated
            self.pendingOutlierReport = nil
        } else if state.isCurrentTimeAuthoritative,
                  let resolved = resolvedReportedPosition(
                    state.currentTime,
                    reportedAt: sanitizedStamp(state.lastUpdated),
                    estimate: estimateBeforeUpdate
                  ) {
            self.elapsedTime = resolved
            self.timestampDate = sanitizedStamp(state.lastUpdated)
        } else if didResume || didPause {
            // Play and pause arrive carrying no position of their own, so the
            // anchor has to be rebuilt — and it is rebuilt from the number on
            // screen, never from the last report, which by then is seconds
            // old. Anchoring anywhere else is what made the readout step at
            // the exact moment the key was pressed: the estimate stops
            // extrapolating the instant playback does, so it collapses onto a
            // stale anchor, and the display gets dragged there with it.
            //
            // Nothing is invented here. Spotify's next real report still
            // corrects this, while playing, where a correction can be
            // absorbed without being seen.
            // Only while it really is the number on screen. Reads happen just
            // for an open notch, so a stale one is whatever was last shown
            // before it closed — minutes ago and no longer true of anything.
            let onScreen = Date().timeIntervalSince(shownPositionReadAt) <= Self.maxSmoothingStep
                ? shownPosition
                : nil
            self.elapsedTime = onScreen ?? estimateBeforeUpdate
            self.timestampDate = Date()
        }



        if didPause {
            // The freeze above is what the readout now shows, and it is true
            // as of this instant. Anything the player says about an earlier
            // one is news we already have.
            playbackStoppedAt = Date()
            pendingOutlierReport = nil
        } else if didResume || trackChanged {
            playbackStoppedAt = nil
        }


        if durationChanged {
            self.songDuration = state.duration
        }

        if playbackRateChanged {
            self.playbackRate = state.playbackRate
        }
        
        if shuffleChanged {
            self.isShuffled = state.isShuffled
        }

        if state.bundleIdentifier != self.bundleIdentifier {
            self.bundleIdentifier = state.bundleIdentifier
            // Update volume control support from active controller
            self.volumeControlSupported = activeController?.supportsVolumeControl ?? false
        }

        if repeatModeChanged {
            self.repeatMode = state.repeatMode
        }
        if state.isFavorite != self.isFavoriteTrack {
            self.isFavoriteTrack = state.isFavorite
        }
        
        if volumeChanged {
            self.volume = state.volume
        }
    }

    func toggleFavoriteTrack() {
        guard canFavoriteTrack else { return }
        // Toggle based on current state
        setFavorite(!isFavoriteTrack)
    }

    @MainActor
    private func toggleAppleMusicFavorite() async {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
        guard !runningApps.isEmpty else { return }

        let script = """
        tell application \"Music\"
            if it is running then
                try
                    set loved of current track to (not loved of current track)
                    return loved of current track
                on error
                    return false
                end try
            else
                return false
            end if
        end tell
        """

        if let result = try? await AppleScriptHelper.execute(script) {
            let loved = result.booleanValue
            self.isFavoriteTrack = loved
            self.forceUpdate()
        }
    }

    func setFavorite(_ favorite: Bool) {
        guard canFavoriteTrack else { return }
        guard let controller = activeController else { return }

        Task { @MainActor in
            await controller.setFavorite(favorite)
            try? await Task.sleep(for: .milliseconds(150))
            await controller.updatePlaybackInfo()
        }
    }

    /// Placeholder dislike function
    func dislikeCurrentTrack() {
        setFavorite(false)
    }

    // MARK: - Lyrics
    private func fetchLyricsIfAvailable(bundleIdentifier: String?, title: String, artist: String) {
        guard Defaults[.enableLyrics], !title.isEmpty else {
            DispatchQueue.main.async {
                self.isFetchingLyrics = false
                self.currentLyrics = ""
            }
            return
        }

        // Prefer native Apple Music lyrics when available
        if let bundleIdentifier = bundleIdentifier, bundleIdentifier.contains("com.apple.Music") {
            Task { @MainActor in
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
                guard !runningApps.isEmpty else {
                    await self.fetchLyricsFromWeb(title: title, artist: artist)
                    return
                }

                self.isFetchingLyrics = true
                self.currentLyrics = ""
                do {
                    let script = """
                    tell application \"Music\"
                        if it is running then
                            if player state is playing or player state is paused then
                                try
                                    set l to lyrics of current track
                                    if l is missing value then
                                        return \"\"
                                    else
                                        return l
                                    end if
                                on error
                                    return \"\"
                                end try
                            else
                                return \"\"
                            end if
                        else
                            return \"\"
                        end if
                    end tell
                    """
                    if let result = try await AppleScriptHelper.execute(script), let lyricsString = result.stringValue, !lyricsString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.currentLyrics = lyricsString.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.isFetchingLyrics = false
                        self.syncedLyrics = []
                        return
                    }
                } catch {
                    // fall through to web lookup
                }
                await self.fetchLyricsFromWeb(title: title, artist: artist)
            }
        } else {
            Task { @MainActor in
                self.isFetchingLyrics = true
                self.currentLyrics = ""
                await self.fetchLyricsFromWeb(title: title, artist: artist)
            }
        }
    }

    private func normalizedQuery(_ string: String) -> String {
        string
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "\u{FFFD}", with: "")
    }

    @MainActor
    private func fetchLyricsFromWeb(title: String, artist: String) async {
        let cleanTitle = normalizedQuery(title)
        let cleanArtist = normalizedQuery(artist)
        guard let encodedTitle = cleanTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedArtist = cleanArtist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            self.currentLyrics = ""
            self.isFetchingLyrics = false
            return
        }

        // LRCLIB simple search (no auth): https://lrclib.net/api/search?track_name=...&artist_name=...
        let urlString = "https://lrclib.net/api/search?track_name=\(encodedTitle)&artist_name=\(encodedArtist)"
        guard let url = URL(string: urlString) else {
            self.currentLyrics = ""
            self.isFetchingLyrics = false
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                self.currentLyrics = ""
                self.isFetchingLyrics = false
                return
            }
            if let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = jsonArray.first {
                // Prefer plain lyrics (syncedLyrics may also be present)
                let plain = (first["plainLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let synced = (first["syncedLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let resolved = plain.isEmpty ? synced : plain
                self.currentLyrics = resolved
                self.isFetchingLyrics = false
                if !synced.isEmpty {
                    self.syncedLyrics = self.parseLRC(synced)
                } else {
                    self.syncedLyrics = []
                }
            } else {
                self.currentLyrics = ""
                self.isFetchingLyrics = false
                self.syncedLyrics = []
            }
        } catch {
            self.currentLyrics = ""
            self.isFetchingLyrics = false
            self.syncedLyrics = []
        }
    }

    // MARK: - Synced lyrics helpers
    private func parseLRC(_ lrc: String) -> [(time: Double, text: String)] {
        var result: [(Double, String)] = []
        lrc.split(separator: "\n").forEach { lineSub in
            let line = String(lineSub)
            // Match [mm:ss.xx] or [m:ss]
            let pattern = #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,2}))?\]"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let nsLine = line as NSString
            if let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) {
                let minStr = nsLine.substring(with: match.range(at: 1))
                let secStr = nsLine.substring(with: match.range(at: 2))
                let csRange = match.range(at: 3)
                let centiStr = csRange.location != NSNotFound ? nsLine.substring(with: csRange) : "0"
                let minutes = Double(minStr) ?? 0
                let seconds = Double(secStr) ?? 0
                let centis = Double(centiStr) ?? 0
                let time = minutes * 60 + seconds + centis / 100.0
                let textStart = match.range.location + match.range.length
                let text = nsLine.substring(from: textStart).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    result.append((time, text))
                }
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }

    func lyricLine(at elapsed: Double) -> String {
        guard !syncedLyrics.isEmpty else { return currentLyrics }
        // Binary search for last line with time <= elapsed
        var low = 0
        var high = syncedLyrics.count - 1
        var idx = 0
        while low <= high {
            let mid = (low + high) / 2
            if syncedLyrics[mid].time <= elapsed {
                idx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return syncedLyrics[idx].text
    }

    private func triggerFlipAnimation() {
        // Cancel any existing animation
        flipWorkItem?.cancel()

        // Create a new animation
        let workItem = DispatchWorkItem { [weak self] in
            self?.isFlipping = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.isFlipping = false
            }
        }

        flipWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func updateArtwork(_ artworkData: Data) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if let artworkImage = NSImage(data: artworkData) {
                DispatchQueue.main.async { [weak self] in
                    self?.usingAppIconForArtwork = false
                    self?.updateAlbumArt(newAlbumArt: artworkImage)
                }
            }
        }
    }

    private func updateIdleState(state: Bool) {
        if state {
            isPlayerIdle = false
            debounceIdleTask?.cancel()
        } else {
            debounceIdleTask?.cancel()
            debounceIdleTask = Task { [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(for: .seconds(Defaults[.waitInterval]))
                withAnimation {
                    self.isPlayerIdle = !self.isPlaying
                }
            }
        }
    }

    private var workItem: DispatchWorkItem?

    func updateAlbumArt(newAlbumArt: NSImage) {
        workItem?.cancel()
        withAnimation(.smooth) {
            self.albumArt = newAlbumArt
            if Defaults[.coloredSpectrogram] {
                self.calculateAverageColor()
            }
        }
    }

    /// How far the readout has to be from the estimate before the difference
    /// is treated as a seek and landed on rather than absorbed. Sits above the
    /// drift actually measured between the two, around three quarters of a
    /// second, since mistaking drift for a seek is what puts a visible step on
    /// screen.
    private static let seekThreshold: TimeInterval = 1.5

    /// The same bar while paused, where a correction cannot be absorbed and
    /// so has to be refused outright. Sits above a poll interval, which is
    /// the most our own position can be wrong by once playback has stopped.
    private static let pausedSeekThreshold: TimeInterval = 3.0

    /// How close a second report has to land to the first outlier before two
    /// glitches are believed to actually be one real seek settling.
    private static let corroborationTolerance: TimeInterval = 0.75

    /// How long a lone outlier is kept waiting for a confirming second
    /// report before it's dropped as stale.
    private static let corroborationWindow: TimeInterval = 3.0

    /// How long after a pause the player's own position frames are treated as
    /// the stale tail of that pause rather than news. Measured at under a
    /// second between the pause and the frame that used to undo it.
    private static let pauseSettlingWindow: TimeInterval = 3.0

    /// How far past the pause a report has to be stamped before it's read as
    /// something that happened after playback stopped. Clears the whole
    /// second the adapter's timestamps are truncated to.
    private static let postPauseStampTolerance: TimeInterval = 1.5

    /// Timestamps this far from now are the adapter's framing rather than a
    /// real moment — an empty opening frame decodes to the epoch — and would
    /// otherwise anchor the readout to an absurd point in time.
    private static let maxStampAge: TimeInterval = 3600

    /// How long the readout is allowed to follow playback backwards after
    /// something that genuinely moves it there.
    private static let backwardMoveGrace: TimeInterval = 1.0

    private func allowBackwardMove() {
        backwardMoveAllowedUntil = Date().addingTimeInterval(Self.backwardMoveGrace)
    }

    /// Falls back to now for a stamp that can't be a real report time.
    private func sanitizedStamp(_ stamp: Date) -> Date {
        let age = Date().timeIntervalSince(stamp)
        return (age > Self.maxStampAge || age < -Self.maxStampAge) ? Date() : stamp
    }

    /// The player is the authority on where playback is, so a report close
    /// to our own estimate is taken immediately — refusing genuine drift
    /// corrections is what let the readout run a second ahead, since our own
    /// extrapolation runs on past the moment playback really stopped and
    /// nothing came back to correct it.
    ///
    /// But a report far from the estimate is taken on faith by nothing else:
    /// the adapter has been seen to emit exactly one stale or zeroed report —
    /// right as playback resumes, or the first poll after the notch has sat
    /// closed a while — immediately followed by a correct one. Landing the
    /// first of those on screen is the drop the next report then undoes, so
    /// a jump this size only gets adopted once a second report lands within
    /// `corroborationTolerance` of the first, meaning the player really did
    /// move there rather than glitching once. Keeping the anchor honest is
    /// this function's job; keeping an adopted jump from visibly stepping is
    /// `displayedPlaybackPosition`'s.
    private func resolvedReportedPosition(
        _ reported: TimeInterval,
        reportedAt: Date,
        estimate: TimeInterval
    ) -> TimeInterval? {
        // A pause's position frame arrives a beat after the flag that caused
        // it, and the position it carries is the player's last internal
        // sample rather than where it actually stopped — Spotify's runs over
        // a second behind, sometimes four. While playing that lag is
        // invisible, because the anchor is extrapolated forward from its own
        // timestamp and the two cancel out. The moment playback stops the
        // extrapolation stops with it, and the lag that was being cancelled
        // lands on screen as a step backwards.
        //
        // Magnitude can't tell that report apart from a real backward seek —
        // four seconds looks like four seconds either way. Its timestamp can:
        // a stale report describes a moment before playback stopped, which is
        // a moment the freeze already accounts for, while a seek made after
        // pausing is stamped later. Reports are stamped to the whole second,
        // so a report has to be clearly past the pause to count as news.
        if !isPlaying, let stoppedAt = playbackStoppedAt {
            let sincePause = Date().timeIntervalSince(stoppedAt)

            // The stale frame lands within a second of the pause, measured.
            // Nothing that arrives in that window and points backwards is
            // news: the freeze already covers every moment up to the pause,
            // and a backward seek cannot happen in the same breath as the
            // pause that preceded it. Forward moves still pass, so a seek
            // made from the player shows up immediately.
            if sincePause < Self.pauseSettlingWindow, reported < estimate {
                return nil
            }

            // Past the window, a report stamped before playback stopped is
            // still describing a moment the freeze accounts for.
            if reportedAt.timeIntervalSince(stoppedAt) < Self.postPauseStampTolerance {
                return nil
            }
        }

        guard abs(reported - estimate) > Self.seekThreshold else {
            pendingOutlierReport = nil
            return reported
        }

        let now = Date()
        if let pending = pendingOutlierReport,
           now.timeIntervalSince(pending.receivedAt) <= Self.corroborationWindow,
           abs(pending.value - reported) <= Self.corroborationTolerance {
            pendingOutlierReport = nil
            // Two reports agreeing on a position this far from our own is the
            // player telling us it really did move — the one case where the
            // readout is meant to follow it backwards.
            if reported < estimate { allowBackwardMove() }
            return reported
        }

        pendingOutlierReport = (reported, now)
        return nil
    }

    /// How much faster or slower than real time the readout runs while it's
    /// closing a gap. A quarter is too small a rate change to see and still
    /// absorbs the drift actually measured here, around half a second, in
    /// roughly two seconds.
    private static let catchUpBias: Double = 0.25

    /// The longest gap between reads that still counts as consecutive frames.
    /// The timeline drives these every 0.1s playing and 0.5s paused, so this
    /// clears both with room to spare while still catching the case that
    /// matters: the notch having been closed.
    private static let maxSmoothingStep: TimeInterval = 1.0

    /// The number actually shown, as opposed to the raw estimate.
    ///
    /// The estimate steps whenever the player reports a position, because the
    /// two clocks always disagree slightly: its reports are stamped a moment
    /// in the past, and ours keeps running while an event is in flight. That
    /// gap is a fraction of a second — invisible mid-second, a whole displayed
    /// second when it lands near a boundary.
    ///
    /// So the readout never steps onto a correction, and never ignores one
    /// either. It runs on its own clock, slightly fast while it's behind and
    /// slightly slow while it's ahead, and converges without being seen to
    /// move. Only a gap too large to be the two clocks disagreeing — a seek,
    /// or a new track — is landed on directly.
    /// Playback within a track only ever moves forward. Everything upstream
    /// of this — the player's own lagging reports, an anchor rebuilt at each
    /// pause, a smoothed value converging at a quarter of real time — can put
    /// the two out of step by seconds, and every attempt to close that gap
    /// arrives as a step backwards on screen.
    ///
    /// So the invariant is enforced here, once, at the end: the number does
    /// not go back. A real seek and a new track do move playback backwards,
    /// and both say so explicitly by opening `backwardMoveAllowedUntil`.
    @MainActor
    func displayedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        let candidate = smoothedPlaybackPosition(at: date)

        if let last = lastDisplayed, candidate < last {
            let mayGoBack = backwardMoveAllowedUntil.map { date < $0 } ?? false
            guard mayGoBack else { return last }
        }

        lastDisplayed = candidate
        return candidate
    }

    @MainActor
    private func smoothedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        let estimate = clampedToTrack(estimatedPlaybackPosition(at: date))
        let sinceLastRead = max(0, date.timeIntervalSince(shownPositionReadAt))
        shownPositionReadAt = date

        // Smoothing only makes sense between consecutive frames. Reads happen
        // solely while the notch is on screen, so a longer gap than that means
        // it was closed — and a closed notch has no number anybody watched get
        // where it is, so there is nothing to converge from. Carrying the gap
        // into the step is what sent the readout ten seconds past the truth on
        // reopening, and the snap back from there is the jump.
        guard sinceLastRead <= Self.maxSmoothingStep else {
            shownPosition = estimate
            return estimate
        }

        // A stationary readout has nowhere to hide a correction: every one of
        // them is a visible step, so while paused the number is held and the
        // disagreement is carried into the next playing stretch instead. Our
        // own error while paused is bounded by how stale the last report was,
        // about a poll interval, so a wider bar here still lets a real seek
        // through while refusing everything that is merely drift.
        let bar = isPlaying ? Self.seekThreshold : Self.pausedSeekThreshold

        // Whatever the anchor does, the number on screen does not walk
        // backwards in the moment after a pause. This is the last line
        // between a stale report and the user seeing 2:02 become 1:58.
        if !isPlaying, let stoppedAt = playbackStoppedAt, let shown = shownPosition,
           date.timeIntervalSince(stoppedAt) < Self.pauseSettlingWindow, estimate < shown {
            return shown
        }

        guard let shown = shownPosition, abs(estimate - shown) < bar else {
            shownPosition = estimate
            return estimate
        }

        guard isPlaying else { return shown }

        let rate = (playbackRate > 0 ? playbackRate : 1)
            * (estimate > shown ? 1 + Self.catchUpBias : 1 - Self.catchUpBias)
        let advanced = shown + sinceLastRead * rate

        // Converge onto the estimate rather than sailing past it.
        let next = estimate > shown ? min(advanced, estimate) : max(advanced, estimate)
        shownPosition = next
        return next
    }

    /// A duration of zero means it hasn't been reported yet, not that the
    /// track has no length, so it can't be used as a ceiling — doing that
    /// pinned the readout to 0:00 for as long as the duration was missing.
    private func clampedToTrack(_ position: TimeInterval) -> TimeInterval {
        songDuration > 0 ? min(max(0, position), songDuration) : max(0, position)
    }

    // MARK: - Playback Position Estimation
    public func estimatedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        guard isPlaying else { return clampedToTrack(elapsedTime) }

        let timeDifference = date.timeIntervalSince(timestampDate)
        return clampedToTrack(elapsedTime + (timeDifference * playbackRate))
    }

    func calculateAverageColor() {
        albumArt.averageColor { [weak self] color in
            DispatchQueue.main.async {
                withAnimation(.smooth) {
                    self?.avgColor = color ?? .white
                }
            }
        }
    }

    private func updateSneakPeek() {
        if isPlaying && Defaults[.enableSneakPeek] {
            if Defaults[.sneakPeekStyles] == .standard {
                coordinator.toggleSneakPeek(status: true, type: .music)
            } else {
                coordinator.toggleExpandingView(status: true, type: .music)
            }
        }
    }

    // MARK: - Public Methods for controlling playback
    func playPause() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func play() {
        Task {
            await activeController?.play()
        }
    }

    func pause() {
        Task {
            await activeController?.pause()
        }
    }

    func toggleShuffle() {
        Task {
            await activeController?.toggleShuffle()
        }
    }

    func toggleRepeat() {
        Task {
            await activeController?.toggleRepeat()
        }
    }
    
    func togglePlay() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func nextTrack() {
        Task {
            await activeController?.nextTrack()
        }
    }

    func previousTrack() {
        Task {
            await activeController?.previousTrack()
        }
    }

    func seek(to position: TimeInterval) {
        // Dragging the slider back is the user moving playback backwards, so
        // the readout has to be free to follow rather than hold.
        allowBackwardMove()

        // The player takes a moment to accept a seek and a moment more to
        // report it back, and until then every layer here still describes
        // where the track used to be — which is the readout flicking back to
        // the old position before the new one arrives. Nothing is being
        // guessed: this is the position playback was just sent to, and the
        // player's own reading replaces it as soon as it lands.
        elapsedTime = position
        timestampDate = Date()
        shownPosition = position
        shownPositionReadAt = Date()
        lastDisplayed = position
        pendingOutlierReport = nil

        Task {
            await activeController?.seek(to: position)
        }
    }
    func skip(seconds: TimeInterval) {
        let newPos = min(max(0, elapsedTime + seconds), songDuration)
        seek(to: newPos)
    }
    
    func setVolume(to level: Double) {
        if let controller = activeController {
            Task {
                await controller.setVolume(level)
            }
        }
    }
    func openMusicApp() {
        guard let bundleID = bundleIdentifier else {
            print("Error: appBundleIdentifier is nil")
            return
        }

        let workspace = NSWorkspace.shared
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.openApplication(at: appURL, configuration: configuration) { (app, error) in
                if let error = error {
                    print("Failed to launch app with bundle ID: \(bundleID), error: \(error)")
                } else {
                    print("Launched app with bundle ID: \(bundleID)")
                }
            }
        } else {
            print("Failed to find app with bundle ID: \(bundleID)")
        }
    }

    func forceUpdate() {
        // Request immediate update from the active controller
        Task { [weak self] in
            if self?.activeController?.isActive() == true {
                if let youtubeController = self?.activeController as? YouTubeMusicController {
                    await youtubeController.pollPlaybackState()
                } else {
                    await self?.activeController?.updatePlaybackInfo()
                }
            }
        }
    }
    
    
    func syncVolumeFromActiveApp() async {
        // Check if bundle identifier is valid and if the app is actually running
        guard let bundleID = bundleIdentifier, !bundleID.isEmpty,
              NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) else { return }
        
        var script: String?
        if bundleID == "com.apple.Music" {
            script = """
            tell application "Music"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else if bundleID == "com.spotify.client" {
            script = """
            tell application "Spotify"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else {
            // For unsupported apps, don't sync volume
            return
        }
        
        if let volumeScript = script,
           let result = try? await AppleScriptHelper.execute(volumeScript) {
            let volumeValue = result.int32Value
            let currentVolume = Double(volumeValue) / 100.0
            
            await MainActor.run {
                if abs(currentVolume - self.volume) > 0.01 {
                    self.volume = currentVolume
                }
            }
        }
    }
}
