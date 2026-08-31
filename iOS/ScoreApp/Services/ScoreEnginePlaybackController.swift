import Foundation
import ScoreAudioEngine
import ScoreCore

/// Keeps all assumptions about the package audio API at the app boundary.
/// Core Motion and SwiftUI do not cross into either Swift package target.
@MainActor
final class ScoreEnginePlaybackController: ScorePlaybackControlling {
    var onEnergyChange: ((PresentedEnergy) -> Void)?
    var onPlaybackFailure: ((String) -> Void)?

    private let transport: any AudioTransport
    private var loadedPack: LoadedScorePack?
    private var arrangement: ArrangementController?
    private var lastQueuedTransition: QueuedTransition?
    private var transitionInFlight: QueuedTransition?
    private var deferredManualEnergy: EnergyTier?
    private var advancementTask: Task<Void, Never>?
    private var isPaused = false
    private var sessionGeneration: UInt64 = 0

    init(transport: any AudioTransport = AVAudioEngineTransport()) {
        self.transport = transport
    }

    func startPreview(at energy: PresentedEnergy) async throws {
        try await prepareAndStart(
            initialEnergy: energy.coreValue,
            adaptationMode: .manual
        )
    }

    func setPreviewEnergy(_ energy: PresentedEnergy) async {
        await setManualEnergy(energy)
    }

    func stopPreview() async {
        await stopImmediately()
    }

    func startWalk(
        at energy: PresentedEnergy,
        adaptationMode: PresentedAdaptationMode
    ) async throws {
        try await prepareAndStart(
            initialEnergy: energy.coreValue,
            adaptationMode: adaptationMode.coreValue
        )
    }

    func submitMotion(_ observation: PresentedMotionObservation) async {
        let frame = await transport.currentTransportFrame()
        guard transitionInFlight == nil else { return }
        guard var controller = arrangement else { return }

        do {
            let state = try controller.observe(
                observation.coreValue,
                atTransportFrame: frame
            )
            arrangement = controller
            try await synchronize(with: state)
        } catch {
            onPlaybackFailure?("Movement could not update the score: \(error.localizedDescription)")
        }
    }

    func setManualEnergy(_ energy: PresentedEnergy) async {
        let target = energy.coreValue
        guard target == .easy || target == .steady || target == .brisk else { return }

        let frame = await transport.currentTransportFrame()
        guard var controller = arrangement else { return }

        // AVAudioEngineTransport owns one scheduled boundary at a time. Remember
        // the latest tap instead of invalidating an already scheduled musical edit.
        if transitionInFlight != nil || controller.state.queuedTransition != nil {
            deferredManualEnergy = target
            return
        }

        do {
            let state = try controller.selectManualEnergy(target, atTransportFrame: frame)
            arrangement = controller
            try await synchronize(with: state)
        } catch {
            onPlaybackFailure?("The manual intensity could not be queued: \(error.localizedDescription)")
        }
    }

    func pause() async {
        await transport.pause()
        isPaused = true
    }

    func resume() async throws {
        try await transport.resume()
        isPaused = false
    }

    func finishWithOutro() async throws {
        advancementTask?.cancel()
        advancementTask = nil
        deferredManualEnergy = nil
        sessionGeneration &+= 1
        transitionInFlight = nil

        do {
            if isPaused {
                try await transport.resume()
                isPaused = false
            }

            // The engine owns outro scheduling so it can start on a musical boundary
            // without building a second AVAudioEngine graph in the app target.
            try await transport.playOutroAndStop()
            arrangement = nil
            loadedPack = nil
            lastQueuedTransition = nil
        } catch {
            await stopImmediately()
            throw error
        }
    }

    func rebuildAfterMediaServicesReset() async throws {
        try await transport.rebuildAfterConfigurationChange()
    }

    private func prepareAndStart(
        initialEnergy: EnergyTier,
        adaptationMode: AdaptationMode
    ) async throws {
        await stopImmediately()

        let loaded = try EngineeringScoreFixture.load()
        var controller = try ArrangementController(
            pack: loaded.pack,
            initialEnergy: .steady
        )

        switch adaptationMode {
        case .automatic:
            _ = try controller.enableAutomatic(atTransportFrame: 0)
        case .manual:
            _ = try controller.selectManualEnergy(initialEnergy, atTransportFrame: 0)
        }

        try await transport.prepare(pack: loaded.pack, resourceRoot: loaded.resourceRoot)
        do {
            try await transport.start()

            loadedPack = loaded
            arrangement = controller
            isPaused = false
            lastQueuedTransition = nil
            transitionInFlight = nil
            deferredManualEnergy = nil
            onEnergyChange?(EnergyTier.steady.presentedValue)
            try await synchronize(with: controller.state)
            startAdvancementLoop()
        } catch {
            await stopImmediately()
            throw error
        }
    }

    private func startAdvancementLoop() {
        advancementTask?.cancel()
        advancementTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.advanceArrangement()
            }
        }
    }

    private func advanceArrangement() async {
        let frame = await transport.currentTransportFrame()
        guard transitionInFlight == nil else { return }
        guard var controller = arrangement else { return }

        do {
            let previousEnergy = controller.state.currentEnergy
            let state = try controller.advance(toTransportFrame: frame)
            arrangement = controller

            if state.currentEnergy != previousEnergy {
                onEnergyChange?(state.currentEnergy.presentedValue)
            }
            try await synchronize(with: state)

            if state.queuedTransition == nil, let deferredManualEnergy {
                self.deferredManualEnergy = nil
                await setManualEnergy(deferredManualEnergy.presentedValue)
            }
        } catch {
            onPlaybackFailure?("The score transport lost its musical position: \(error.localizedDescription)")
        }
    }

    private func synchronize(with state: ArrangementState) async throws {
        guard let transition = state.queuedTransition else {
            lastQueuedTransition = nil
            return
        }
        guard transition != lastQueuedTransition else { return }
        guard transitionInFlight == nil else { return }

        let generation = sessionGeneration
        transitionInFlight = transition
        do {
            let accepted = try await transport.queue(transition)
            guard generation == sessionGeneration,
                  transitionInFlight == transition,
                  var controller = arrangement else {
                return
            }
            do {
                _ = try controller.adoptAcceptedTransition(
                    expected: transition,
                    accepted: accepted
                )
            } catch {
                await stopImmediately()
                throw error
            }
            arrangement = controller
            lastQueuedTransition = accepted
            transitionInFlight = nil
        } catch {
            if generation == sessionGeneration {
                transitionInFlight = nil
                lastQueuedTransition = nil
            }
            throw error
        }
    }

    private func stopImmediately() async {
        sessionGeneration &+= 1
        advancementTask?.cancel()
        advancementTask = nil
        loadedPack = nil
        arrangement = nil
        lastQueuedTransition = nil
        transitionInFlight = nil
        deferredManualEnergy = nil
        isPaused = false
        await transport.stopImmediately()
    }
}

private extension PresentedEnergy {
    var coreValue: EnergyTier {
        switch self {
        case .still:
            .still
        case .easy:
            .easy
        case .steady:
            .steady
        case .brisk:
            .brisk
        case .surge:
            .surge
        }
    }
}

private extension EnergyTier {
    var presentedValue: PresentedEnergy {
        switch self {
        case .still:
            .still
        case .easy:
            .easy
        case .steady:
            .steady
        case .brisk:
            .brisk
        case .surge:
            .surge
        }
    }
}

private extension PresentedAdaptationMode {
    var coreValue: AdaptationMode {
        self == .automatic ? .automatic : .manual
    }
}

private extension PresentedMotionObservation {
    var coreValue: MotionObservation {
        MotionObservation(
            cadenceStepsPerMinute: cadenceStepsPerMinute,
            activity: activity.coreValue,
            confidence: confidence.coreValue,
            timestamp: timestamp,
            source: cadenceStepsPerMinute == nil ? .motionActivity : .combined,
            freshness: isStale ? .stale : .fresh
        )
    }
}

private extension PresentedActivity {
    var coreValue: MotionActivityClassification {
        switch self {
        case .stationary:
            .stationary
        case .walking:
            .walking
        case .running:
            .running
        case .automotive:
            .automotive
        case .cycling:
            .cycling
        case .unknown:
            .unknown
        }
    }
}

private extension PresentedMotionConfidence {
    var coreValue: MotionConfidence {
        switch self {
        case .low:
            .low
        case .medium:
            .medium
        case .high:
            .high
        }
    }
}
