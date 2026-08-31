import Foundation

@MainActor
protocol MotionObserving: AnyObject {
    var permission: MotionPermission { get }
    var onPermissionChange: ((MotionPermission) -> Void)? { get set }
    var onObservation: ((PresentedMotionObservation) -> Void)? { get set }

    func requestAuthorizationAndStart()
    func startIfAuthorized()
    func stop()
}

@MainActor
protocol ScorePlaybackControlling: AnyObject {
    var onEnergyChange: ((PresentedEnergy) -> Void)? { get set }
    var onPlaybackFailure: ((String) -> Void)? { get set }

    func startPreview(at energy: PresentedEnergy) async throws
    func setPreviewEnergy(_ energy: PresentedEnergy) async
    func stopPreview() async
    func startWalk(
        at energy: PresentedEnergy,
        adaptationMode: PresentedAdaptationMode
    ) async throws
    func submitMotion(_ observation: PresentedMotionObservation) async
    func setManualEnergy(_ energy: PresentedEnergy) async
    func pause() async
    func resume() async throws
    func finishWithOutro() async throws
    func rebuildAfterMediaServicesReset() async throws
}

@MainActor
protocol AudioSessionManaging: AnyObject {
    var onInterruptionBegan: (() -> Void)? { get set }
    var onInterruptionEnded: ((Bool) -> Void)? { get set }
    var onPersonalAudioRouteRemoved: (() -> Void)? { get set }
    var onMediaServicesReset: (() -> Void)? { get set }
    var onEngineConfigurationChange: (() -> Void)? { get set }

    func activate() throws
    func deactivate()
}

@MainActor
protocol RemoteCommandManaging: AnyObject {
    var onPlay: (() -> Bool)? { get set }
    var onPause: (() -> Bool)? { get set }
    var onStop: (() -> Bool)? { get set }

    func installHandlers()
    func removeHandlers()
    func update(title: String, subtitle: String, elapsed: TimeInterval, isPlaying: Bool)
    func clearNowPlaying()
}

protocol SessionSummaryPersisting: Sendable {
    func append(packID: String, date: Date, duration: TimeInterval, adaptationMode: PresentedAdaptationMode) async throws
}

@MainActor
protocol PreferencePersisting: AnyObject {
    var completedOnboarding: Bool { get set }
    var adaptationMode: PresentedAdaptationMode { get set }
    var manualEnergy: PresentedEnergy { get set }
}
