import AVFoundation
import Darwin
import Foundation
import ScoreCore

public actor AVAudioEngineTransport: AudioTransport {
    public static let schedulingLeadTime: TimeInterval = 0.25
    public static let gainRampDuration: TimeInterval = 0.20

    private enum DeckID {
        case a
        case b
    }

    private enum PlaybackPhase {
        case stopped
        case intro
        case core
        case outro
    }

    private final class StemDeck {
        var players: [String: AVAudioPlayerNode]
        var retainedBuffers: [AVAudioPCMBuffer] = []

        init(stemIDs: [String]) {
            players = Dictionary(
                uniqueKeysWithValues: stemIDs.map { ($0, AVAudioPlayerNode()) }
            )
        }

        func stop() {
            for player in players.values {
                player.stop()
            }
            retainedBuffers.removeAll(keepingCapacity: true)
        }

        func pause() {
            for player in players.values where player.isPlaying {
                player.pause()
            }
        }
    }

    private var engine = AVAudioEngine()
    private var deckA: StemDeck?
    private var deckB: StemDeck?
    private var introPlayer: AVAudioPlayerNode?
    private var outroPlayer: AVAudioPlayerNode?

    private var pack: ScorePack?
    private var sectionBuffers: [String: [String: AVAudioPCMBuffer]] = [:]
    private var sectionFrameCounts: [String: Int64] = [:]
    private var introBuffer: AVAudioPCMBuffer?
    private var outroBuffer: AVAudioPCMBuffer?
    private var processingFormat: AVAudioFormat?

    private var activeDeckID = DeckID.a
    private var currentSectionID: String?
    private var currentEnergy = EnergyTier.steady
    private var phase = PlaybackPhase.stopped
    private var isPrepared = false
    private var isRunning = false
    private var isPaused = false

    private var transportFrameAtLastResume: Int64 = 0
    private var lastResumeHostTime: UInt64?
    private var currentSectionStartedAtFrame: Int64 = 0
    private var outroStartedAtFrame: Int64?
    private var queuedTransition: QueuedTransition?
    private var transitionTask: Task<Void, Never>?
    private var phaseTask: Task<Void, Never>?
    private var outroFadeTask: Task<Void, Never>?
    private var transitionGeneration: UInt64 = 0
    private var graphGeneration: UInt64 = 0
    private var finishGeneration: UInt64 = 0

    public init() {}

    public func prepare(pack: ScorePack, resourceRoot: URL) async throws {
        await stopImmediately()
        invalidatePreparedContent()

        do {
            guard AudioRuntimeCapabilities.supportsScheduledSoundPlayer else {
                throw ScoreAudioEngineError.audioComponentUnavailable
            }

            let availableResources = Set(
                try FileManager.default.subpathsOfDirectory(atPath: resourceRoot.path)
            )
            let validationIssues = ScorePackValidator.validate(
                pack,
                availableResourceNames: availableResources
            )
            guard validationIssues.isEmpty else {
                throw ScoreAudioEngineError.invalidPack(
                    validationIssues.map { "\($0.path): \($0.message)" }
                )
            }

            _ = try AudioAssetInspector.inspect(
                pack: pack,
                resourceRoot: resourceRoot,
                verifyHashes: true
            )

            var loadedStems: [String: AVAudioPCMBuffer] = [:]
            var commonFormat: AVAudioFormat?
            for stem in pack.stems {
                let url = try AudioAssetInspector.resolvedURL(
                    for: stem.asset.resourceName,
                    beneath: resourceRoot
                )
                let buffer = try Self.loadPCMBuffer(from: url)
                if let commonFormat {
                    guard Self.formatsMatch(commonFormat, buffer.format) else {
                        throw ScoreAudioEngineError.incompatibleAsset(stem.asset.resourceName)
                    }
                } else {
                    commonFormat = buffer.format
                }
                loadedStems[stem.id] = buffer
            }

            guard let commonFormat else {
                throw ScoreAudioEngineError.invalidPack(["At least one stem is required."])
            }
            guard commonFormat.commonFormat == .pcmFormatFloat32,
                  !commonFormat.isInterleaved else {
                throw ScoreAudioEngineError.unsupportedPCMFormat(commonFormat.description)
            }

            let loadedIntro = try pack.intro.map { asset in
                let url = try AudioAssetInspector.resolvedURL(
                    for: asset.resourceName,
                    beneath: resourceRoot
                )
                let buffer = try Self.loadPCMBuffer(from: url)
                guard Self.formatsMatch(commonFormat, buffer.format) else {
                    throw ScoreAudioEngineError.incompatibleAsset(asset.resourceName)
                }
                return buffer
            }
            let loadedOutro = try pack.outro.map { asset in
                let url = try AudioAssetInspector.resolvedURL(
                    for: asset.resourceName,
                    beneath: resourceRoot
                )
                let buffer = try Self.loadPCMBuffer(from: url)
                guard Self.formatsMatch(commonFormat, buffer.format) else {
                    throw ScoreAudioEngineError.incompatibleAsset(asset.resourceName)
                }
                return buffer
            }

            var cachedSections: [String: [String: AVAudioPCMBuffer]] = [:]
            var cachedSectionFrameCounts: [String: Int64] = [:]
            for section in pack.sections {
                let sectionStart = try pack.grid.frame(atBar: section.startBar)
                let sectionEnd = try pack.grid.frame(
                    atBar: section.startBar + section.barCount
                )
                let sectionLength = sectionEnd - sectionStart
                var cachedStems: [String: AVAudioPCMBuffer] = [:]
                for stem in pack.stems {
                    guard let source = loadedStems[stem.id] else {
                        throw ScoreAudioEngineError.missingResource(stem.asset.resourceName)
                    }
                    cachedStems[stem.id] = try Self.slice(
                        source,
                        startFrame: sectionStart,
                        frameCount: sectionLength
                    )
                }
                cachedSections[section.id] = cachedStems
                cachedSectionFrameCounts[section.id] = sectionLength
            }

            self.pack = pack
            sectionBuffers = cachedSections
            sectionFrameCounts = cachedSectionFrameCounts
            introBuffer = loadedIntro
            outroBuffer = loadedOutro
            processingFormat = commonFormat
            currentSectionID = pack.initialSectionID
            currentEnergy = .steady
            activeDeckID = .a
            transportFrameAtLastResume = 0
            currentSectionStartedAtFrame = Int64(loadedIntro?.frameLength ?? 0)
            outroStartedAtFrame = nil
            queuedTransition = nil
            phase = .stopped

            try rebuildGraph()
            isPrepared = true
        } catch {
            invalidatePreparedContent()
            throw error
        }
    }

    public func start() async throws {
        guard isPrepared, let pack, let sectionID = currentSectionID else {
            throw ScoreAudioEngineError.notPrepared
        }
        guard !isRunning else {
            throw ScoreAudioEngineError.alreadyRunning
        }

        try startEngineIfNeeded()
        let startHostTime = mach_absolute_time()
            &+ AVAudioTime.hostTime(forSeconds: Self.schedulingLeadTime)
        let startTime = AVAudioTime(hostTime: startHostTime)

        if let introBuffer, let introPlayer {
            introPlayer.stop()
            introPlayer.volume = 1
            scheduleSynchronously(introBuffer, on: introPlayer, at: startTime)
            introPlayer.play(at: startTime)
            phase = .intro
        } else {
            phase = .core
        }

        let introFrames = Int64(introBuffer?.frameLength ?? 0)
        let coreStartHostTime = startHostTime &+ AVAudioTime.hostTime(
            forSeconds: Double(introFrames) / Double(pack.grid.sampleRate)
        )
        try scheduleSection(
            sectionID,
            on: .a,
            atHostTime: coreStartHostTime,
            offsetFrames: 0,
            startingVolumeScale: 1
        )

        activeDeckID = .a
        currentSectionStartedAtFrame = introFrames
        transportFrameAtLastResume = 0
        lastResumeHostTime = startHostTime
        isRunning = true
        isPaused = false

        if introFrames > 0 {
            scheduleCorePhaseMarker(afterFrames: introFrames)
        }
    }

    public func pause() async {
        guard isRunning, !isPaused else { return }
        transportFrameAtLastResume = transportFrameNow()
        lastResumeHostTime = nil
        deckA?.pause()
        deckB?.pause()
        if introPlayer?.isPlaying == true { introPlayer?.pause() }
        if outroPlayer?.isPlaying == true { outroPlayer?.pause() }
        cancelTransitionExecution(restoreActiveMix: false)
        phaseTask?.cancel()
        cancelOutroFade()
        isPaused = true
    }

    public func resume() async throws {
        guard isPrepared else {
            throw ScoreAudioEngineError.notPrepared
        }
        guard isRunning, isPaused else { return }

        let frame = transportFrameAtLastResume
        try rebuildGraph()
        try startEngineIfNeeded()
        applyQueuedTransitionIfDue(atTransportFrame: frame)
        try reschedulePlayback(atTransportFrame: frame)
        isPaused = false

        if let pending = queuedTransition, outroStartedAtFrame == nil {
            try scheduleAcceptedTransition(pending)
        }
    }

    public func queue(_ transition: QueuedTransition) async throws -> QueuedTransition {
        guard isPrepared, isRunning, let pack else {
            throw ScoreAudioEngineError.notPrepared
        }
        guard outroStartedAtFrame == nil else {
            throw ScoreAudioEngineError.transitionInPast
        }

        let currentFrame = transportFrameNow()
        let effective = try Self.acceptedTransition(
            transition,
            currentFrame: currentFrame,
            grid: pack.grid
        )

        if case let .section(targetSectionID) = effective.target {
            guard pack.sections.contains(where: { $0.id == targetSectionID }) else {
                throw ScoreAudioEngineError.unknownSection(targetSectionID)
            }
            guard let sourceSectionID = currentSectionID,
                  pack.legalTransitions.contains(where: {
                      $0.fromSectionID == sourceSectionID
                          && $0.toSectionID == targetSectionID
                          && $0.boundary == effective.boundary
                  }) else {
                throw ScoreAudioEngineError.illegalSectionTransition(
                    from: currentSectionID ?? "unknown",
                    to: targetSectionID
                )
            }
        }

        cancelTransitionExecution(restoreActiveMix: true)
        queuedTransition = effective
        guard !isPaused else { return effective }

        do {
            try scheduleAcceptedTransition(effective)
        } catch {
            queuedTransition = nil
            restoreActiveMixAndStopInactiveDeck()
            throw error
        }

        return effective
    }

    public func stopImmediately() async {
        cancelTransitionExecution(restoreActiveMix: false)
        phaseTask?.cancel()
        cancelOutroFade()
        finishGeneration &+= 1
        phaseTask = nil
        queuedTransition = nil
        deckA?.stop()
        deckB?.stop()
        introPlayer?.stop()
        outroPlayer?.stop()
        engine.stop()
        engine.reset()
        transportFrameAtLastResume = transportFrameNow()
        lastResumeHostTime = nil
        isRunning = false
        isPaused = false
        phase = .stopped
        outroStartedAtFrame = nil
    }

    public func currentTransportFrame() async -> Int64 {
        transportFrameNow()
    }

    public func rebuildAfterConfigurationChange() async throws {
        guard isPrepared else {
            throw ScoreAudioEngineError.notPrepared
        }
        let shouldResume = isRunning && !isPaused
        let frame = transportFrameNow()
        transportFrameAtLastResume = frame
        lastResumeHostTime = nil
        cancelTransitionExecution(restoreActiveMix: false)
        phaseTask?.cancel()
        cancelOutroFade()

        try rebuildGraph()
        guard shouldResume else { return }
        try startEngineIfNeeded()
        applyQueuedTransitionIfDue(atTransportFrame: frame)
        try reschedulePlayback(atTransportFrame: frame)
        if let pending = queuedTransition, outroStartedAtFrame == nil {
            try scheduleAcceptedTransition(pending)
        }
    }

    /// Schedules the authored outro at the next safe phrase and returns after it finishes.
    public func playOutroAndStop() async throws {
        guard isPrepared, isRunning, !isPaused, let pack else {
            throw ScoreAudioEngineError.notPrepared
        }
        let currentFrame = transportFrameNow()
        let leadFrames = Int64(
            (Double(pack.grid.sampleRate) * Self.schedulingLeadTime).rounded(.up)
        )
        let safeFrame = currentFrame.addingReportingOverflow(leadFrames)
        guard !safeFrame.overflow else {
            throw ScoreCoreError.arithmeticOverflow
        }
        let boundaryFrame = try pack.grid.nextBoundary(
            afterFrame: safeFrame.partialValue,
            boundary: .phrase
        )
        let hostTime = try hostTime(forTransportFrame: boundaryFrame)
        let fadeFrames = Int64(
            (Self.gainRampDuration * Double(pack.grid.sampleRate)).rounded(.up)
        )
        let finishLength = max(Int64(outroBuffer?.frameLength ?? 0), fadeFrames)
        let finishFrame = boundaryFrame.addingReportingOverflow(finishLength)
        guard !finishFrame.overflow else {
            throw ScoreCoreError.arithmeticOverflow
        }

        cancelTransitionExecution(restoreActiveMix: true)
        phaseTask?.cancel()
        queuedTransition = nil
        finishGeneration &+= 1
        let generation = finishGeneration
        outroStartedAtFrame = boundaryFrame

        if let outroBuffer {
            try scheduleOutro(outroBuffer, atHostTime: hostTime, offsetFrames: 0)
        }
        scheduleOutroFade(atHostTime: hostTime, finishGeneration: generation)

        do {
            while transportFrameNow() < finishFrame.partialValue {
                guard generation == finishGeneration else {
                    throw CancellationError()
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard generation == finishGeneration else {
                throw CancellationError()
            }
            await stopImmediately()
        } catch {
            if generation == finishGeneration {
                await stopImmediately()
            }
            throw error
        }
    }

    private var activeDeck: StemDeck? {
        activeDeckID == .a ? deckA : deckB
    }

    private var inactiveDeckID: DeckID {
        activeDeckID == .a ? .b : .a
    }

    private func deck(for id: DeckID) -> StemDeck? {
        id == .a ? deckA : deckB
    }

    private func rebuildGraph() throws {
        guard let processingFormat, let pack else {
            if isPrepared {
                throw ScoreAudioEngineError.notPrepared
            }
            return
        }

        graphGeneration &+= 1
        engine.stop()
        engine = AVAudioEngine()
        let newDeckA = StemDeck(stemIDs: pack.stems.map(\.id))
        let newDeckB = StemDeck(stemIDs: pack.stems.map(\.id))
        deckA = newDeckA
        deckB = newDeckB
        let newIntroPlayer = AVAudioPlayerNode()
        let newOutroPlayer = AVAudioPlayerNode()
        introPlayer = newIntroPlayer
        outroPlayer = newOutroPlayer

        for player in Array(newDeckA.players.values) + Array(newDeckB.players.values) {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: processingFormat)
        }
        engine.attach(newIntroPlayer)
        engine.attach(newOutroPlayer)
        engine.connect(newIntroPlayer, to: engine.mainMixerNode, format: processingFormat)
        engine.connect(newOutroPlayer, to: engine.mainMixerNode, format: processingFormat)
        engine.prepare()
    }

    private func startEngineIfNeeded() throws {
        if !engine.isRunning {
            try engine.start()
        }
    }

    private func scheduleSynchronously(
        _ buffer: AVAudioPCMBuffer,
        on player: AVAudioPlayerNode,
        at time: AVAudioTime?,
        options: AVAudioPlayerNodeBufferOptions = []
    ) {
        player.scheduleBuffer(
            buffer,
            at: time,
            options: options,
            completionHandler: nil
        )
    }

    private func scheduleSection(
        _ sectionID: String,
        on deckID: DeckID,
        atHostTime hostTime: UInt64,
        offsetFrames: Int64,
        startingVolumeScale: Float
    ) throws {
        guard let pack,
              let section = pack.sections.first(where: { $0.id == sectionID }),
              let deck = deck(for: deckID),
              let cachedBuffers = sectionBuffers[sectionID],
              let sectionLength = sectionFrameCounts[sectionID] else {
            throw ScoreAudioEngineError.unknownSection(sectionID)
        }

        deck.stop()
        let normalizedOffset = sectionLength > 0
            ? max(0, min(offsetFrames, sectionLength - 1))
            : 0
        let startTime = AVAudioTime(hostTime: hostTime)

        for stem in pack.stems {
            guard let fullSection = cachedBuffers[stem.id],
                  let player = deck.players[stem.id] else {
                throw ScoreAudioEngineError.missingResource(stem.asset.resourceName)
            }

            deck.retainedBuffers.append(fullSection)
            player.volume = linearGain(for: stem.id, energy: currentEnergy) * startingVolumeScale

            if normalizedOffset > 0 {
                let remainder = try Self.slice(
                    fullSection,
                    startFrame: normalizedOffset,
                    frameCount: sectionLength - normalizedOffset
                )
                deck.retainedBuffers.append(remainder)
                player.scheduleBuffer(remainder, at: startTime, completionHandler: nil)
                if section.loops {
                    player.scheduleBuffer(
                        fullSection,
                        at: nil,
                        options: .loops,
                        completionHandler: nil
                    )
                }
            } else {
                player.scheduleBuffer(
                    fullSection,
                    at: startTime,
                    options: section.loops ? .loops : [],
                    completionHandler: nil
                )
            }
            player.play(at: startTime)
        }
    }

    private func reschedulePlayback(atTransportFrame frame: Int64) throws {
        guard let pack, let sectionID = currentSectionID else {
            throw ScoreAudioEngineError.notPrepared
        }
        let startHostTime = mach_absolute_time()
            &+ AVAudioTime.hostTime(forSeconds: Self.schedulingLeadTime)
        transportFrameAtLastResume = frame
        lastResumeHostTime = startHostTime

        if let outroStart = outroStartedAtFrame, frame >= outroStart {
            phase = .outro
            if let outroBuffer, frame - outroStart < Int64(outroBuffer.frameLength) {
                try scheduleOutro(
                    outroBuffer,
                    atHostTime: startHostTime,
                    offsetFrames: frame - outroStart
                )
            }
            return
        }

        let introFrames = Int64(introBuffer?.frameLength ?? 0)
        if frame < introFrames, let introBuffer, let introPlayer {
            phase = .intro
            let remainder = try Self.slice(
                introBuffer,
                startFrame: frame,
                frameCount: introFrames - frame
            )
            introPlayer.scheduleBuffer(
                remainder,
                at: AVAudioTime(hostTime: startHostTime),
                completionHandler: nil
            )
            introPlayer.play(at: AVAudioTime(hostTime: startHostTime))
            let coreHostTime = startHostTime &+ AVAudioTime.hostTime(
                forSeconds: Double(introFrames - frame) / Double(pack.grid.sampleRate)
            )
            try scheduleSection(
                sectionID,
                on: activeDeckID,
                atHostTime: coreHostTime,
                offsetFrames: 0,
                startingVolumeScale: 1
            )
            scheduleCorePhaseMarker(afterFrames: introFrames - frame)
        } else {
            phase = .core
            let offset = max(0, frame - currentSectionStartedAtFrame)
            let section = pack.sections.first(where: { $0.id == sectionID })
            let sectionFrames = try section.map {
                try pack.grid.frame(atBar: $0.startBar + $0.barCount)
                    - pack.grid.frame(atBar: $0.startBar)
            } ?? 1
            try scheduleSection(
                sectionID,
                on: activeDeckID,
                atHostTime: startHostTime,
                offsetFrames: sectionFrames > 0 ? offset % sectionFrames : 0,
                startingVolumeScale: 1
            )
        }

        if let outroStart = outroStartedAtFrame, outroStart > frame {
            let outroHostTime = try hostTime(forTransportFrame: outroStart)
            if let outroBuffer {
                try scheduleOutro(outroBuffer, atHostTime: outroHostTime, offsetFrames: 0)
            }
            scheduleOutroFade(
                atHostTime: outroHostTime,
                finishGeneration: finishGeneration
            )
        }
    }

    private func scheduleTransitionExecution(
        _ transition: QueuedTransition,
        targetDeckID: DeckID,
        targetHostTime: UInt64
    ) {
        transitionGeneration &+= 1
        let generation = transitionGeneration
        let delay = secondsUntil(hostTime: targetHostTime)
        transitionTask = Task { [weak self] in
            do {
                if delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                }
                try Task.checkCancellation()
                guard let self else { return }
                try await self.executeTransition(
                    transition,
                    targetDeckID: targetDeckID,
                    generation: generation
                )
            } catch {
                return
            }
        }
    }

    /// Reschedules a transition whose exact boundary was already accepted by
    /// both ScoreCore and this transport. Resume and graph rebuild start the
    /// canonical clock after the 250 ms lead, so silently moving it again would
    /// desynchronize the two state machines.
    private func scheduleAcceptedTransition(_ transition: QueuedTransition) throws {
        let targetHostTime = try hostTime(forTransportFrame: transition.executeAtFrame)
        let targetDeckID = inactiveDeckID
        if case let .section(sectionID) = transition.target {
            try scheduleSection(
                sectionID,
                on: targetDeckID,
                atHostTime: targetHostTime,
                offsetFrames: 0,
                startingVolumeScale: 0
            )
        }
        scheduleTransitionExecution(
            transition,
            targetDeckID: targetDeckID,
            targetHostTime: targetHostTime
        )
    }

    private func executeTransition(
        _ transition: QueuedTransition,
        targetDeckID: DeckID,
        generation: UInt64
    ) async throws {
        guard generation == transitionGeneration,
              queuedTransition == transition else {
            throw CancellationError()
        }

        switch transition.target {
        case let .energy(energy):
            // Commit transport state at the musical boundary before the short
            // gain ramp suspends. A new request or graph rebuild during the ramp
            // must observe the same state that ScoreCore has already applied.
            currentEnergy = energy
            queuedTransition = nil
            try await rampTransitionDecks(
                first: activeDeck,
                firstScale: 1,
                second: nil,
                secondScale: 0,
                energy: energy,
                generation: generation
            )
            guard generation == transitionGeneration else {
                throw CancellationError()
            }
        case let .section(sectionID):
            let oldDeck = activeDeck
            let newDeck = deck(for: targetDeckID)
            activeDeckID = targetDeckID
            currentSectionID = sectionID
            currentSectionStartedAtFrame = transition.executeAtFrame
            phase = .core
            queuedTransition = nil
            try await rampTransitionDecks(
                first: oldDeck,
                firstScale: 0,
                second: newDeck,
                secondScale: 1,
                energy: currentEnergy,
                generation: generation
            )
            guard generation == transitionGeneration else {
                throw CancellationError()
            }
            oldDeck?.stop()
        }
        transitionTask = nil
    }

    private func rampTransitionDecks(
        first: StemDeck?,
        firstScale: Float,
        second: StemDeck?,
        secondScale: Float,
        energy: EnergyTier,
        generation: UInt64
    ) async throws {
        guard let pack else { return }
        let targets: [(deck: StemDeck, scale: Float)] = [
            first.map { ($0, firstScale) },
            second.map { ($0, secondScale) },
        ].compactMap { $0 }
        let startingVolumes = targets.map { $0.deck.players.mapValues(\.volume) }
        let steps = 10
        for step in 1...steps {
            guard generation == transitionGeneration else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            let progress = Float(step) / Float(steps)
            for (targetIndex, target) in targets.enumerated() {
                for stem in pack.stems {
                    guard let player = target.deck.players[stem.id] else { continue }
                    let start = startingVolumes[targetIndex][stem.id] ?? 0
                    let end = linearGain(for: stem.id, energy: energy) * target.scale
                    player.volume = start + (end - start) * progress
                }
            }
            if step < steps {
                try await Task.sleep(
                    for: .seconds(Self.gainRampDuration / Double(steps))
                )
            }
        }
    }

    private func cancelTransitionExecution(restoreActiveMix: Bool) {
        transitionGeneration &+= 1
        transitionTask?.cancel()
        transitionTask = nil
        if restoreActiveMix {
            restoreActiveMixAndStopInactiveDeck()
        }
    }

    private func applyQueuedTransitionIfDue(atTransportFrame frame: Int64) {
        guard let transition = queuedTransition,
              transition.executeAtFrame <= frame else { return }
        switch transition.target {
        case let .energy(energy):
            currentEnergy = energy
        case let .section(sectionID):
            currentSectionID = sectionID
            currentSectionStartedAtFrame = transition.executeAtFrame
        }
        queuedTransition = nil
    }

    private func restoreActiveMixAndStopInactiveDeck() {
        guard let pack else { return }
        deck(for: inactiveDeckID)?.stop()
        for stem in pack.stems {
            activeDeck?.players[stem.id]?.volume = linearGain(
                for: stem.id,
                energy: currentEnergy
            )
        }
    }

    private func scheduleOutro(
        _ buffer: AVAudioPCMBuffer,
        atHostTime hostTime: UInt64,
        offsetFrames: Int64
    ) throws {
        guard let outroPlayer else {
            throw ScoreAudioEngineError.notPrepared
        }
        outroPlayer.stop()
        outroPlayer.volume = 1
        let scheduledBuffer: AVAudioPCMBuffer
        if offsetFrames > 0 {
            scheduledBuffer = try Self.slice(
                buffer,
                startFrame: offsetFrames,
                frameCount: Int64(buffer.frameLength) - offsetFrames
            )
        } else {
            scheduledBuffer = buffer
        }
        let time = AVAudioTime(hostTime: hostTime)
        scheduleSynchronously(scheduledBuffer, on: outroPlayer, at: time)
        outroPlayer.play(at: time)
    }

    private func scheduleOutroFade(
        atHostTime hostTime: UInt64,
        finishGeneration: UInt64
    ) {
        cancelOutroFade()
        let graphGeneration = graphGeneration
        let delay = secondsUntil(hostTime: hostTime)
        outroFadeTask = Task { [weak self] in
            do {
                if delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                }
                try Task.checkCancellation()
                guard let self else { return }
                try await self.performOutroFade(
                    graphGeneration: graphGeneration,
                    finishGeneration: finishGeneration
                )
            } catch {
                return
            }
        }
    }

    private func performOutroFade(
        graphGeneration: UInt64,
        finishGeneration: UInt64
    ) async throws {
        guard graphGeneration == self.graphGeneration,
              finishGeneration == self.finishGeneration else {
            throw CancellationError()
        }
        phase = .outro
        guard let deck = activeDeck, let pack else { return }
        let startingVolumes = deck.players.mapValues(\.volume)
        let steps = 10
        for step in 1...steps {
            guard graphGeneration == self.graphGeneration,
                  finishGeneration == self.finishGeneration else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            let progress = Float(step) / Float(steps)
            for stem in pack.stems {
                guard let player = deck.players[stem.id] else { continue }
                let start = startingVolumes[stem.id] ?? 0
                player.volume = start * (1 - progress)
            }
            if step < steps {
                try await Task.sleep(
                    for: .seconds(Self.gainRampDuration / Double(steps))
                )
            }
        }
        guard graphGeneration == self.graphGeneration,
              finishGeneration == self.finishGeneration else { return }
        outroFadeTask = nil
    }

    private func cancelOutroFade() {
        outroFadeTask?.cancel()
        outroFadeTask = nil
    }

    private func scheduleCorePhaseMarker(afterFrames frames: Int64) {
        guard let pack else { return }
        phaseTask?.cancel()
        let delay = Double(frames) / Double(pack.grid.sampleRate)
        phaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.markCorePhase()
        }
    }

    private func markCorePhase() {
        guard phase == .intro else { return }
        phase = .core
        phaseTask = nil
    }

    private func hostTime(forTransportFrame frame: Int64) throws -> UInt64 {
        guard let lastResumeHostTime else {
            throw ScoreAudioEngineError.transitionInPast
        }
        let deltaFrames = frame - transportFrameAtLastResume
        guard deltaFrames >= 0, let pack else {
            throw ScoreAudioEngineError.transitionInPast
        }
        return lastResumeHostTime &+ AVAudioTime.hostTime(
            forSeconds: Double(deltaFrames) / Double(pack.grid.sampleRate)
        )
    }

    private func transportFrameNow() -> Int64 {
        guard isRunning, !isPaused, let lastResumeHostTime, let pack else {
            return transportFrameAtLastResume
        }
        let now = mach_absolute_time()
        guard now > lastResumeHostTime else {
            return transportFrameAtLastResume
        }
        let elapsed = AVAudioTime.seconds(forHostTime: now - lastResumeHostTime)
        let elapsedFrames = Int64((elapsed * Double(pack.grid.sampleRate)).rounded(.down))
        return transportFrameAtLastResume + max(0, elapsedFrames)
    }

    private func secondsUntil(hostTime: UInt64) -> TimeInterval {
        let now = mach_absolute_time()
        guard hostTime > now else { return 0 }
        return AVAudioTime.seconds(forHostTime: hostTime - now)
    }

    private func linearGain(for stemID: String, energy: EnergyTier) -> Float {
        guard let mix = pack?.intensityMixes.first(where: { $0.energy == energy }),
              let decibels = mix.stemGains[stemID] else {
            return 0
        }
        if decibels <= -96 { return 0 }
        return Float(pow(10, decibels / 20))
    }

    static func acceptedTransition(
        _ transition: QueuedTransition,
        currentFrame: Int64,
        grid: MusicalGrid
    ) throws -> QueuedTransition {
        guard transition.executeAtFrame >= 0,
              try grid.previousBoundary(
                  atOrBeforeFrame: transition.executeAtFrame,
                  boundary: transition.boundary
              ) == transition.executeAtFrame else {
            throw ScoreCoreError.invalidAcceptedTransition
        }
        let leadFrames = Int64(
            (Double(grid.sampleRate) * schedulingLeadTime).rounded(.up)
        )
        let earliestSafeFrame = currentFrame.addingReportingOverflow(leadFrames)
        guard !earliestSafeFrame.overflow else {
            throw ScoreCoreError.arithmeticOverflow
        }

        guard transition.executeAtFrame < earliestSafeFrame.partialValue else {
            return transition
        }
        var accepted = transition
        accepted.executeAtFrame = try grid.nextBoundary(
            afterFrame: earliestSafeFrame.partialValue,
            boundary: transition.boundary
        )
        return accepted
    }

    private func invalidatePreparedContent() {
        cancelTransitionExecution(restoreActiveMix: false)
        phaseTask?.cancel()
        phaseTask = nil
        cancelOutroFade()
        finishGeneration &+= 1
        deckA?.stop()
        deckB?.stop()
        introPlayer?.stop()
        outroPlayer?.stop()
        engine.stop()
        engine.reset()
        pack = nil
        sectionBuffers = [:]
        sectionFrameCounts = [:]
        introBuffer = nil
        outroBuffer = nil
        processingFormat = nil
        deckA = nil
        deckB = nil
        introPlayer = nil
        outroPlayer = nil
        currentSectionID = nil
        queuedTransition = nil
        outroStartedAtFrame = nil
        transportFrameAtLastResume = 0
        lastResumeHostTime = nil
        currentSectionStartedAtFrame = 0
        phase = .stopped
        isPrepared = false
        isRunning = false
        isPaused = false
    }

    private static func loadPCMBuffer(from url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard file.length > 0, file.length <= Int64(UInt32.max),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat,
                  frameCapacity: AVAudioFrameCount(file.length)
              ) else {
            throw ScoreAudioEngineError.incompatibleAsset(url.lastPathComponent)
        }
        try file.read(into: buffer)
        return buffer
    }

    private static func slice(
        _ source: AVAudioPCMBuffer,
        startFrame: Int64,
        frameCount: Int64
    ) throws -> AVAudioPCMBuffer {
        guard startFrame >= 0, frameCount > 0,
              startFrame + frameCount <= Int64(source.frameLength),
              frameCount <= Int64(UInt32.max),
              let sourceChannels = source.floatChannelData,
              let destination = AVAudioPCMBuffer(
                  pcmFormat: source.format,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let destinationChannels = destination.floatChannelData else {
            throw ScoreAudioEngineError.unsupportedPCMFormat(source.format.description)
        }

        destination.frameLength = AVAudioFrameCount(frameCount)
        for channel in 0..<Int(source.format.channelCount) {
            destinationChannels[channel].update(
                from: sourceChannels[channel].advanced(by: Int(startFrame)),
                count: Int(frameCount)
            )
        }
        return destination
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

}
