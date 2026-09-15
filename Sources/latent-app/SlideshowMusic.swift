import Foundation
import AVFoundation
import os

/// The slideshow's music, from minivu's: the songs in Settings, in order
/// and round again, fading in as the show starts, pausing with it and
/// fading out when it ends.
///
/// Songs are bookmarks the user chose in Settings; each is resolved and
/// its security scope held only while it plays. Files are opened off the
/// main thread (reading an MP3 to find its frames can take a moment on a
/// sleeping disk); `generation` drops a song that finishes opening after
/// the music has moved on or stopped. AVFoundation decodes on its own
/// thread; between songs nothing runs.
@MainActor
final class SlideshowMusic: NSObject, AVAudioPlayerDelegate {
    static let fadeInDuration: TimeInterval = 1
    static let fadeOutDuration: TimeInterval = 1.5
    static let volume: Float = 0.8

    private let songs: [SlideshowSettings.Song]
    private var position = 0
    private var player: AVAudioPlayer?
    /// The song file whose security scope is held, while it plays.
    private var scoped: URL?
    private var generation = 0
    private var isPaused = false
    private var hasFinished = false
    /// Songs that wouldn't open in a row: once every one has failed, stop trying.
    private var failuresInARow = 0

    init(songs: [SlideshowSettings.Song]) {
        self.songs = songs
    }

    func start() {
        playCurrent()
    }

    func pause() {
        isPaused = true
        player?.pause()
    }

    func resume() {
        isPaused = false
        if let player {
            player.play()
            // A song that finished opening while paused never faded in and
            // is still silent; one paused mid-song is already at volume.
            player.setVolume(Self.volume, fadeDuration: Self.fadeInDuration)
        } else if !hasFinished {
            playCurrent()
        }
    }

    /// The song playing or paused now; for tests.
    var currentPlayer: AVAudioPlayer? { player }

    /// Fades out and lets go of the file.
    func finish() {
        guard !hasFinished else { return }
        hasFinished = true
        generation += 1
        guard let player else { releaseScope(); return }
        player.delegate = nil
        player.setVolume(0, fadeDuration: Self.fadeOutDuration)
        let scoped = self.scoped
        self.scoped = nil
        self.player = nil
        // The player is kept alive by this closure until the fade is done.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.fadeOutDuration))
            player.stop()
            scoped?.stopAccessingSecurityScopedResource()
        }
    }

    private struct Opened: @unchecked Sendable {
        let player: AVAudioPlayer
    }

    private func playCurrent() {
        guard !hasFinished, !isPaused, !songs.isEmpty, failuresInARow < songs.count else { return }
        let song = songs[position % songs.count]
        generation += 1
        let generation = self.generation
        releaseScope()
        guard let (url, _) = BookmarkStore.resolveQuietly(song.bookmark) else {
            skip(failed: true)
            return
        }
        if url.startAccessingSecurityScopedResource() { scoped = url }
        Task {
            let opened = await Task.detached(priority: .userInitiated) { () -> Opened? in
                guard let player = try? AVAudioPlayer(contentsOf: url), player.prepareToPlay() else { return nil }
                return Opened(player: player)
            }.value
            guard generation == self.generation, !hasFinished else { return }
            guard let player = opened?.player else {
                Log.slideshow.info("Slideshow music skips a song that won't open")
                skip(failed: true)
                return
            }
            failuresInARow = 0
            player.delegate = self
            player.volume = 0
            self.player = player
            guard !isPaused else { return }
            player.play()
            player.setVolume(Self.volume, fadeDuration: Self.fadeInDuration)
        }
    }

    private func skip(failed: Bool) {
        if failed { failuresInARow += 1 }
        player = nil
        position = (position + 1) % max(songs.count, 1)
        playCurrent()
    }

    private func releaseScope() {
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.finished(id) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.finished(id) }
    }

    private func finished(_ id: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == id else { return }
        skip(failed: false)
    }
}
