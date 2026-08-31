import AVFAudio
import Foundation

@MainActor
final class AudioSessionController: AudioSessionManaging {
    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: ((Bool) -> Void)?
    var onPersonalAudioRouteRemoved: (() -> Void)?
    var onMediaServicesReset: (() -> Void)?
    var onEngineConfigurationChange: (() -> Void)?

    private let session: AVAudioSession
    private var observerTokens: [NSObjectProtocol] = []

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
        installObservers()
    }

    deinit {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func activate() throws {
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
    }

    func deactivate() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func installObservers() {
        let center = NotificationCenter.default

        observerTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleInterruption(notification)
                }
            }
        )

        observerTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleRouteChange(notification)
                }
            }
        )

        observerTokens.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.onMediaServicesReset?()
                }
            }
        )

        observerTokens.append(
            center.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.onEngineConfigurationChange?()
                }
            }
        )
    }

    private func handleInterruption(_ notification: Notification) {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else {
            return
        }

        switch type {
        case .began:
            onInterruptionBegan?()
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            onInterruptionEnded?(options.contains(.shouldResume))
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable,
            let previousRoute = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
                as? AVAudioSessionRouteDescription
        else {
            return
        }

        let removedPersonalRoute = previousRoute.outputs.contains { output in
            switch output.portType {
            case .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
                return true
            default:
                return false
            }
        }

        if removedPersonalRoute {
            onPersonalAudioRouteRemoved?()
        }
    }
}
