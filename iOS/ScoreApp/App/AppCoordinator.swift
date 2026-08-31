import Combine
import Foundation
import ScoreAudioEngine
import ScoreCore

@MainActor
final class AppCoordinator: ObservableObject {
    static let engineeringPackID = "engineering-score-v1"

    @Published private(set) var screen: AppScreen
    @Published private(set) var didHearPreview = false
    @Published private(set) var isPreviewPlaying = false
    @Published private(set) var previewEnergy = PresentedEnergy.easy
    @Published private(set) var motionPermission: MotionPermission
    @Published private(set) var adaptationMode: PresentedAdaptationMode
    @Published private(set) var manualEnergy: PresentedEnergy
    @Published private(set) var displayedEnergy = PresentedEnergy.steady
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isPaused = false
    @Published private(set) var isStarting = false
    @Published private(set) var isEnding = false
    @Published private(set) var sessionStatus = "Preparing the score"
    @Published private(set) var presentedError: String?

    private let motion: MotionObserving
    private let playback: ScorePlaybackControlling
    private let audioSession: AudioSessionManaging
    private let remoteCommands: RemoteCommandManaging
    private let summaries: SessionSummaryPersisting
    private let preferences: PreferencePersisting

    private var previewTask: Task<Void, Never>?
    private var previewRunID = UUID()
    private var elapsedTimer: Timer?
    private var shouldResumeAfterInterruption = false
    private var coreSession = SessionController()
    private var isRecoveringAudioGraph = false
    private var audioRecoveryCooldownUntil = Date.distantPast

    init(
        motion: MotionObserving,
        playback: ScorePlaybackControlling,
        audioSession: AudioSessionManaging,
        remoteCommands: RemoteCommandManaging,
        summaries: SessionSummaryPersisting,
        preferences: PreferencePersisting
    ) {
        self.motion = motion
        self.playback = playback
        self.audioSession = audioSession
        self.remoteCommands = remoteCommands
        self.summaries = summaries
        self.preferences = preferences

        screen = preferences.completedOnboarding ? .home : .onboarding
        motionPermission = motion.permission
        adaptationMode = preferences.adaptationMode
        manualEnergy = preferences.manualEnergy

        if !motion.permission.canUseAutomaticMode, motion.permission != .notDetermined {
            adaptationMode = .manual
            manualEnergy = .steady
        }

        bindDependencies()
    }

    static func live() -> AppCoordinator {
        AppCoordinator(
            motion: CoreMotionSource(),
            playback: ScoreEnginePlaybackController(),
            audioSession: AudioSessionController(),
            remoteCommands: RemoteCommandController(),
            summaries: SessionSummaryStore(),
            preferences: AppPreferences()
        )
    }

    static func preview() -> AppCoordinator {
        live()
    }

    func playAdaptivePreview() {
        previewTask?.cancel()
        let runID = UUID()
        previewRunID = runID
        previewTask = Task { [weak self] in
            await self?.runAdaptivePreview(runID: runID)
        }
    }

    func finishOnboardingWithAutomaticMode() {
        guard didHearPreview else { return }
        Task { await stopPreview() }
        adaptationMode = .automatic
        preferences.adaptationMode = .automatic
        preferences.completedOnboarding = true
        screen = .home
        motion.requestAuthorizationAndStart()
    }

    func finishOnboardingWithManualMode() {
        guard didHearPreview else { return }
        Task { await stopPreview() }
        adaptationMode = .manual
        manualEnergy = .steady
        preferences.adaptationMode = .manual
        preferences.manualEnergy = .steady
        preferences.completedOnboarding = true
        screen = .home
        motion.stop()
    }

    func selectAdaptationMode(_ selection: PresentedAdaptationMode) {
        guard screen == .home else { return }

        switch selection {
        case .manual:
            adaptationMode = .manual
            preferences.adaptationMode = .manual
            motion.stop()
        case .automatic:
            guard didHearPreview || preferences.completedOnboarding else { return }
            switch motionPermission {
            case .authorized:
                adaptationMode = .automatic
                preferences.adaptationMode = .automatic
            case .notDetermined:
                adaptationMode = .automatic
                preferences.adaptationMode = .automatic
                motion.requestAuthorizationAndStart()
            case .denied, .restricted, .unavailable:
                adaptationMode = .manual
                manualEnergy = .steady
                presentedError = motionPermission.explanation
            }
        }
    }

    func selectManualEnergy(_ energy: PresentedEnergy) {
        guard PresentedEnergy.manualCases.contains(energy) else { return }
        manualEnergy = energy
        preferences.manualEnergy = energy

        guard screen == .active, adaptationMode == .manual else { return }
        sessionStatus = "\(energy.title) is queued for the next bar"
        Task { [weak self] in
            await self?.playback.setManualEnergy(energy)
        }
    }

    func startWalk() {
        guard screen == .home, !isStarting else { return }
        isStarting = true
        Task { [weak self] in
            await self?.beginWalk()
        }
    }

    func togglePause() {
        guard screen == .active, !isEnding else { return }
        if isPaused {
            resumeSession()
        } else {
            pauseSession(message: "Paused")
        }
    }

    func finishWalk() {
        guard screen == .active, !isEnding else { return }
        isEnding = true
        sessionStatus = "Playing the authored outro"
        Task { [weak self] in
            await self?.completeActiveWalk()
        }
    }

    func returnHome() {
        guard case .completion = screen else { return }
        do {
            try coreSession.reset()
        } catch {
            coreSession = SessionController()
        }
        elapsed = 0
        displayedEnergy = .steady
        isPaused = false
        isEnding = false
        sessionStatus = "Ready"
        screen = .home
    }

    func dismissError() {
        presentedError = nil
    }

    private func bindDependencies() {
        motion.onPermissionChange = { [weak self] permission in
            guard let self else { return }
            self.motionPermission = permission

            if !permission.canUseAutomaticMode, permission != .notDetermined {
                self.useManualFallback(
                    message: "Motion is unavailable. Steady manual control is active.",
                    persistPreference: true
                )
            }

            if self.screen != .active {
                self.motion.stop()
            }
        }

        motion.onObservation = { [weak self] observation in
            guard let self, self.screen == .active, self.adaptationMode == .automatic else { return }
            Task { [weak self] in
                guard let self else { return }
                await self.playback.submitMotion(observation)
                if observation.isStale {
                    self.useManualFallback(
                        message: "Motion input became stale. Choose an intensity manually.",
                        persistPreference: false
                    )
                } else if let cadence = observation.cadenceStepsPerMinute {
                    self.sessionStatus = "Auto · \(Int(cadence.rounded())) steps per minute"
                } else {
                    self.sessionStatus = "Auto · reading movement"
                }
            }
        }

        playback.onEnergyChange = { [weak self] energy in
            self?.displayedEnergy = energy
        }
        playback.onPlaybackFailure = { [weak self] message in
            self?.presentedError = message
        }

        audioSession.onInterruptionBegan = { [weak self] in
            guard let self, self.screen == .active else { return }
            self.beginInterruption()
        }
        audioSession.onInterruptionEnded = { [weak self] systemAllowsResume in
            guard let self else { return }
            self.endInterruption(systemAllowsResume: systemAllowsResume)
        }
        audioSession.onPersonalAudioRouteRemoved = { [weak self] in
            guard let self, self.screen == .active, !self.isPaused else { return }
            self.shouldResumeAfterInterruption = false
            self.pauseSession(message: "Paused because headphones disconnected")
        }
        audioSession.onMediaServicesReset = { [weak self] in
            self?.recoverAudioGraph()
        }
        audioSession.onEngineConfigurationChange = { [weak self] in
            self?.recoverAudioGraph()
        }

        remoteCommands.onPlay = { [weak self] in
            guard let self, self.screen == .active, self.isPaused, !self.isEnding else { return false }
            self.resumeSession()
            return true
        }
        remoteCommands.onPause = { [weak self] in
            guard let self, self.screen == .active, !self.isPaused, !self.isEnding else { return false }
            self.pauseSession(message: "Paused from headphones")
            return true
        }
        remoteCommands.onStop = { [weak self] in
            guard let self, self.screen == .active, !self.isEnding else { return false }
            self.finishWalk()
            return true
        }
    }

    private func runAdaptivePreview(runID: UUID) async {
        isPreviewPlaying = true
        previewEnergy = .easy

        do {
            try audioSession.activate()
            try await playback.startPreview(at: .easy)

            // The engineering pack opens with an eight-second authored intro.
            // Let it resolve before demonstrating layer changes in the loop.
            try await Task.sleep(nanoseconds: 8_200_000_000)
            try Task.checkCancellation()
            previewEnergy = .steady
            await playback.setPreviewEnergy(.steady)

            try await Task.sleep(nanoseconds: 3_000_000_000)
            try Task.checkCancellation()
            didHearPreview = true
            previewEnergy = .brisk
            await playback.setPreviewEnergy(.brisk)

            try await Task.sleep(nanoseconds: 3_000_000_000)
        } catch is CancellationError {
            // A new preview or navigation owns the next playback action.
        } catch {
            presentedError = "The preview could not play: \(error.localizedDescription)"
        }

        if previewRunID == runID {
            await playback.stopPreview()
            audioSession.deactivate()
            isPreviewPlaying = false
            previewTask = nil
        }
    }

    private func stopPreview() async {
        previewRunID = UUID()
        previewTask?.cancel()
        previewTask = nil
        await playback.stopPreview()
        audioSession.deactivate()
        isPreviewPlaying = false
    }

    private func beginWalk() async {
        await stopPreview()

        if adaptationMode == .automatic {
            switch motionPermission {
            case .denied, .restricted, .unavailable:
                useManualFallback(
                    message: "Motion is unavailable. Steady manual control is active.",
                    persistPreference: true
                )
            case .notDetermined:
                motion.requestAuthorizationAndStart()
            case .authorized:
                break
            }
        }

        let initialEnergy = adaptationMode == .manual ? manualEnergy : .steady
        do {
            try coreSession.beginSession(
                packID: Self.engineeringPackID,
                adaptationMode: adaptationMode.coreValue
            )
            try audioSession.activate()
            try await playback.startWalk(at: initialEnergy, adaptationMode: adaptationMode)
            try coreSession.playbackDidStart()
        } catch {
            coreSession = SessionController()
            audioSession.deactivate()
            isStarting = false
            presentedError = "The walk could not start: \(error.localizedDescription)"
            return
        }

        elapsed = 0
        displayedEnergy = .steady
        isPaused = false
        isStarting = false
        isEnding = false
        sessionStatus = adaptationMode == .automatic ? "Auto · reading movement" : "Manual · \(initialEnergy.title)"
        screen = .active

        if adaptationMode == .automatic {
            motion.startIfAuthorized()
        } else {
            motion.stop()
        }

        remoteCommands.installHandlers()
        startElapsedTimer()
        updateNowPlaying()
    }

    private func pauseSession(message: String) {
        guard screen == .active, !isPaused, !isEnding else { return }
        do {
            try coreSession.pause()
        } catch {
            presentedError = "The session could not pause cleanly: \(error.localizedDescription)"
            return
        }
        isPaused = true
        sessionStatus = message
        Task { [weak self] in
            await self?.playback.pause()
        }
        updateNowPlaying()
    }

    private func resumeSession() {
        guard screen == .active, isPaused, !isEnding else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try self.audioSession.activate()
                try await self.playback.resume()
                try self.coreSession.resume()
                self.isPaused = false
                self.sessionStatus = self.adaptationMode == .automatic
                    ? "Auto · reading movement"
                    : "Manual · \(self.manualEnergy.title)"
                self.updateNowPlaying()
            } catch {
                self.presentedError = "Playback could not resume: \(error.localizedDescription)"
            }
        }
    }

    private func completeActiveWalk() async {
        refreshElapsed()
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        motion.stop()

        do {
            try coreSession.requestEnd()
        } catch {
            presentedError = "The session state could not begin its ending: \(error.localizedDescription)"
        }

        do {
            try audioSession.activate()
            try await playback.finishWithOutro()
        } catch {
            presentedError = "The authored outro could not finish: \(error.localizedDescription)"
        }

        let completed: CompletedWalk
        do {
            let summary = try coreSession.outroDidFinish()
            completed = CompletedWalk(
                packID: summary.packID,
                duration: summary.duration,
                date: summary.date,
                // A permission response or stale input can move an Auto session to
                // Manual after it starts. Persist the mode that governed the end of
                // the walk so the completion screen and local record agree.
                adaptationMode: adaptationMode
            )
        } catch {
            completed = CompletedWalk(
                packID: Self.engineeringPackID,
                duration: elapsed,
                date: Date(),
                adaptationMode: adaptationMode
            )
            presentedError = "The walk ended, but its session state was incomplete: \(error.localizedDescription)"
        }

        remoteCommands.clearNowPlaying()
        remoteCommands.removeHandlers()
        audioSession.deactivate()

        do {
            try await summaries.append(
                packID: completed.packID,
                date: completed.date,
                duration: completed.duration,
                adaptationMode: completed.adaptationMode
            )
        } catch {
            presentedError = "The walk finished, but its local summary could not be saved: \(error.localizedDescription)"
        }

        screen = .completion(completed)
    }

    private func useManualFallback(message: String, persistPreference: Bool) {
        adaptationMode = .manual
        manualEnergy = .steady
        displayedEnergy = displayedEnergy == .surge ? .steady : displayedEnergy
        sessionStatus = message
        if persistPreference {
            preferences.adaptationMode = .manual
            preferences.manualEnergy = .steady
        }
        motion.stop()

        if screen == .active {
            Task { [weak self] in
                await self?.playback.setManualEnergy(.steady)
            }
        }
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshElapsed()
                self?.updateNowPlaying()
            }
        }
    }

    private func refreshElapsed() {
        elapsed = coreSession.activeDuration
    }

    private func updateNowPlaying() {
        guard screen == .active else { return }
        remoteCommands.update(
            title: "Engineering Score",
            subtitle: "\(adaptationMode.title) · \(displayedEnergy.title)",
            elapsed: elapsed,
            isPlaying: !isPaused && !isEnding
        )
    }

    private func recoverAudioGraph() {
        let now = Date()
        guard
            screen == .active,
            !isEnding,
            !isRecoveringAudioGraph,
            now >= audioRecoveryCooldownUntil
        else {
            return
        }
        isRecoveringAudioGraph = true
        audioRecoveryCooldownUntil = now.addingTimeInterval(1)
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRecoveringAudioGraph = false }
            do {
                try self.audioSession.activate()
                try await self.playback.rebuildAfterMediaServicesReset()
            } catch {
                self.pauseSession(message: "Audio needs attention")
                self.presentedError = "The audio engine could not recover: \(error.localizedDescription)"
            }
        }
    }

    private func beginInterruption() {
        guard screen == .active, !isEnding else { return }
        shouldResumeAfterInterruption = coreSession.phase == .active
        do {
            try coreSession.interruptionBegan()
        } catch {
            presentedError = "The interruption could not be recorded: \(error.localizedDescription)"
            return
        }
        isPaused = true
        sessionStatus = "Paused for an interruption"
        Task { [weak self] in
            await self?.playback.pause()
        }
        updateNowPlaying()
    }

    private func endInterruption(systemAllowsResume: Bool) {
        guard screen == .active, coreSession.phase == .interrupted else { return }
        let shouldResume = shouldResumeAfterInterruption && systemAllowsResume
        shouldResumeAfterInterruption = false

        do {
            try coreSession.interruptionEnded(shouldResume: shouldResume)
        } catch {
            presentedError = "The interruption could not be resolved: \(error.localizedDescription)"
            return
        }

        guard shouldResume else {
            isPaused = true
            sessionStatus = "Paused after interruption"
            updateNowPlaying()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try self.audioSession.activate()
                try await self.playback.resume()
                self.isPaused = false
                self.sessionStatus = self.adaptationMode == .automatic
                    ? "Auto · reading movement"
                    : "Manual · \(self.manualEnergy.title)"
                self.updateNowPlaying()
            } catch {
                try? self.coreSession.pause()
                self.isPaused = true
                self.presentedError = "Playback could not resume after the interruption: \(error.localizedDescription)"
            }
        }
    }
}

private extension PresentedAdaptationMode {
    var coreValue: AdaptationMode {
        self == .automatic ? .automatic : .manual
    }
}
