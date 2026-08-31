import Foundation
import MediaPlayer

@MainActor
final class RemoteCommandController: RemoteCommandManaging {
    var onPlay: (() -> Bool)?
    var onPause: (() -> Bool)?
    var onStop: (() -> Bool)?

    private let commandCenter: MPRemoteCommandCenter
    private let infoCenter: MPNowPlayingInfoCenter
    private var playTarget: Any?
    private var pauseTarget: Any?
    private var toggleTarget: Any?
    private var stopTarget: Any?

    init(
        commandCenter: MPRemoteCommandCenter = .shared(),
        infoCenter: MPNowPlayingInfoCenter = .default()
    ) {
        self.commandCenter = commandCenter
        self.infoCenter = infoCenter
    }

    deinit {
        if let playTarget { commandCenter.playCommand.removeTarget(playTarget) }
        if let pauseTarget { commandCenter.pauseCommand.removeTarget(pauseTarget) }
        if let toggleTarget { commandCenter.togglePlayPauseCommand.removeTarget(toggleTarget) }
        if let stopTarget { commandCenter.stopCommand.removeTarget(stopTarget) }
    }

    func installHandlers() {
        removeHandlers()

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.stopCommand.isEnabled = true

        // Seeking and track navigation would break authored musical boundaries.
        commandCenter.changePlaybackPositionCommand.isEnabled = false
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false

        playTarget = commandCenter.playCommand.addTarget { [weak self] _ in
            self?.status(for: self?.onPlay?() ?? false) ?? .commandFailed
        }
        pauseTarget = commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.status(for: self?.onPause?() ?? false) ?? .commandFailed
        }
        toggleTarget = commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            // The coordinator swaps play and pause availability as state changes.
            if self.commandCenter.pauseCommand.isEnabled, self.onPause?() == true {
                return .success
            }
            return self.status(for: self.onPlay?() ?? false)
        }
        stopTarget = commandCenter.stopCommand.addTarget { [weak self] _ in
            // Stop requests the authored outro and persistence path. It never drops
            // the active session as an immediate destructive reset.
            self?.status(for: self?.onStop?() ?? false) ?? .commandFailed
        }
    }

    func removeHandlers() {
        if let playTarget { commandCenter.playCommand.removeTarget(playTarget) }
        if let pauseTarget { commandCenter.pauseCommand.removeTarget(pauseTarget) }
        if let toggleTarget { commandCenter.togglePlayPauseCommand.removeTarget(toggleTarget) }
        if let stopTarget { commandCenter.stopCommand.removeTarget(stopTarget) }
        playTarget = nil
        pauseTarget = nil
        toggleTarget = nil
        stopTarget = nil
    }

    func update(
        title: String,
        subtitle: String,
        elapsed: TimeInterval,
        isPlaying: Bool
    ) {
        infoCenter.nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyAlbumTitle: subtitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]

        commandCenter.playCommand.isEnabled = !isPlaying
        commandCenter.pauseCommand.isEnabled = isPlaying
    }

    func clearNowPlaying() {
        infoCenter.nowPlayingInfo = nil
    }

    private func status(for succeeded: Bool) -> MPRemoteCommandHandlerStatus {
        succeeded ? .success : .commandFailed
    }
}
