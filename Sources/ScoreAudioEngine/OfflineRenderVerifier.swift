import AVFoundation
import Foundation
import ScoreCore

public struct OfflineRenderReport: Codable, Sendable, Equatable {
    public var requestedFrames: Int64
    public var renderedFrames: Int64
    public var peakMagnitude: Float
    public var largestSampleDelta: Float
    public var nonFiniteSampleCount: Int
    public var recoverableRenderRetries: Int
    public var stemFrameCountsMatch: Bool
    public var scheduledEnergyTransitions: Int
    public var scheduledSectionTransitions: Int
    public var boundaryCheckCount: Int
    public var boundaryAlignmentFailures: Int
    public var phaseCheckCount: Int
    public var phaseAlignmentFailures: Int

    public init(
        requestedFrames: Int64,
        renderedFrames: Int64,
        peakMagnitude: Float,
        largestSampleDelta: Float,
        nonFiniteSampleCount: Int,
        recoverableRenderRetries: Int,
        stemFrameCountsMatch: Bool,
        scheduledEnergyTransitions: Int = 0,
        scheduledSectionTransitions: Int = 0,
        boundaryCheckCount: Int = 0,
        boundaryAlignmentFailures: Int = 0,
        phaseCheckCount: Int = 0,
        phaseAlignmentFailures: Int = 0
    ) {
        self.requestedFrames = requestedFrames
        self.renderedFrames = renderedFrames
        self.peakMagnitude = peakMagnitude
        self.largestSampleDelta = largestSampleDelta
        self.nonFiniteSampleCount = nonFiniteSampleCount
        self.recoverableRenderRetries = recoverableRenderRetries
        self.stemFrameCountsMatch = stemFrameCountsMatch
        self.scheduledEnergyTransitions = scheduledEnergyTransitions
        self.scheduledSectionTransitions = scheduledSectionTransitions
        self.boundaryCheckCount = boundaryCheckCount
        self.boundaryAlignmentFailures = boundaryAlignmentFailures
        self.phaseCheckCount = phaseCheckCount
        self.phaseAlignmentFailures = phaseAlignmentFailures
    }

    public var completedRequestedDuration: Bool {
        renderedFrames == requestedFrames
    }

    public var transitionsWereBoundaryAligned: Bool {
        boundaryCheckCount > 0 && boundaryAlignmentFailures == 0
    }

    public var stemsRemainedPhaseAligned: Bool {
        phaseCheckCount > 0 && phaseAlignmentFailures == 0
    }
}

public enum OfflineRenderVerifier {
    public static func render(
        pack: ScorePack,
        resourceRoot: URL,
        duration: TimeInterval,
        energy: EnergyTier = .steady,
        maximumFrameCount: AVAudioFrameCount = 4_096
    ) throws -> OfflineRenderReport {
        guard duration.isFinite, duration > 0 else {
            throw ScoreAudioEngineError.offlineRenderFailed(
                "Duration must be finite and positive."
            )
        }
        guard maximumFrameCount > 0 else {
            throw ScoreAudioEngineError.offlineRenderFailed(
                "The maximum render frame count must be positive."
            )
        }
        let requestedFramesValue = duration * Double(pack.grid.sampleRate)
        guard requestedFramesValue.isFinite,
              requestedFramesValue >= 1,
              requestedFramesValue <= Double(Int64.max) else {
            throw ScoreAudioEngineError.offlineRenderFailed(
                "The requested duration exceeds the renderable frame range."
            )
        }
        let requestedFrames = Int64(requestedFramesValue.rounded(.toNearestOrAwayFromZero))

        guard AudioRuntimeCapabilities.supportsScheduledSoundPlayer else {
            throw ScoreAudioEngineError.audioComponentUnavailable
        }

        let inspections = try AudioAssetInspector.inspect(
            pack: pack,
            resourceRoot: resourceRoot,
            verifyHashes: true
        )
        let stemNames = Set(pack.stems.map(\.asset.resourceName))
        let stemInspections = inspections.filter { stemNames.contains($0.resourceName) }
        let stemFrameCountsMatch = Set(stemInspections.map(\.frameCount)).count == 1
            && stemInspections.first?.frameCount == pack.grid.exactLoopFrames

        var fullStemBuffers: [String: AVAudioPCMBuffer] = [:]
        var commonFormat: AVAudioFormat?
        for stem in pack.stems {
            let url = try AudioAssetInspector.resolvedURL(
                for: stem.asset.resourceName,
                beneath: resourceRoot
            )
            let buffer = try loadPCMBuffer(from: url)
            if let commonFormat {
                guard formatsMatch(commonFormat, buffer.format) else {
                    throw ScoreAudioEngineError.incompatibleAsset(stem.asset.resourceName)
                }
            } else {
                commonFormat = buffer.format
            }
            fullStemBuffers[stem.id] = buffer
        }

        guard let commonFormat,
              let renderingFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Double(pack.grid.sampleRate),
                  channels: commonFormat.channelCount,
                  interleaved: false
              ),
              let initialSectionID = pack.initialSectionID else {
            throw ScoreAudioEngineError.offlineRenderFailed("No renderable stems were loaded.")
        }

        let sectionBuffers = try cacheSectionBuffers(
            pack: pack,
            fullStemBuffers: fullStemBuffers
        )
        let engine = AVAudioEngine()
        let deckA = OfflineStemDeck(stemIDs: pack.stems.map(\.id))
        let deckB = OfflineStemDeck(stemIDs: pack.stems.map(\.id))
        for player in Array(deckA.players.values) + Array(deckB.players.values) {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: commonFormat)
        }

        try engine.enableManualRenderingMode(
            .offline,
            format: renderingFormat,
            maximumFrameCount: maximumFrameCount
        )
        engine.prepare()

        var activeDeck = deckA
        var inactiveDeck = deckB
        var currentEnergy = energy
        try scheduleSection(
            initialSectionID,
            on: activeDeck,
            pack: pack,
            sectionBuffers: sectionBuffers,
            energy: currentEnergy
        )
        try engine.start()

        guard let renderBuffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: maximumFrameCount
        ) else {
            throw ScoreAudioEngineError.offlineRenderFailed("Could not allocate a render buffer.")
        }

        let events = try renderEvents(
            pack: pack,
            throughFrame: requestedFrames,
            initialSectionID: initialSectionID,
            initialEnergy: energy
        )
        var eventIndex = 0
        var renderedFrames: Int64 = 0
        var peakMagnitude: Float = 0
        var largestSampleDelta: Float = 0
        var nonFiniteSampleCount = 0
        var recoverableRenderRetries = 0
        var consecutiveNoProgressRetries = 0
        var scheduledEnergyTransitions = 0
        var scheduledSectionTransitions = 0
        var boundaryCheckCount = 0
        var boundaryAlignmentFailures = 0
        var phaseCheckCount = 0
        var phaseAlignmentFailures = 0
        var previousSamples = Array(
            repeating: Float.zero,
            count: Int(engine.manualRenderingFormat.channelCount)
        )

        while renderedFrames < requestedFrames {
            if eventIndex < events.count, events[eventIndex].frame == renderedFrames {
                phaseCheckCount += 1
                if !playersArePhaseAligned(activeDeck.players.values, engine: engine) {
                    phaseAlignmentFailures += 1
                }
            }
            while eventIndex < events.count, events[eventIndex].frame == renderedFrames {
                let event = events[eventIndex]
                boundaryCheckCount += 1
                let boundaryFrame = try pack.grid.previousBoundary(
                    atOrBeforeFrame: event.frame,
                    boundary: event.boundary
                )
                if boundaryFrame != event.frame {
                    boundaryAlignmentFailures += 1
                }

                switch event.target {
                case let .energy(nextEnergy):
                    currentEnergy = nextEnergy
                    applyMix(nextEnergy, to: activeDeck, pack: pack)
                    scheduledEnergyTransitions += 1
                case let .section(sectionID):
                    inactiveDeck.stop()
                    try scheduleSection(
                        sectionID,
                        on: inactiveDeck,
                        pack: pack,
                        sectionBuffers: sectionBuffers,
                        energy: currentEnergy
                    )
                    activeDeck.stop()
                    swap(&activeDeck, &inactiveDeck)
                    scheduledSectionTransitions += 1
                }
                eventIndex += 1
            }

            let nextEventFrame = eventIndex < events.count
                ? events[eventIndex].frame
                : requestedFrames
            let framesUntilEvent = max(0, nextEventFrame - renderedFrames)
            let remaining = requestedFrames - renderedFrames
            let requestedSliceValue = min(
                Int64(maximumFrameCount),
                min(remaining, framesUntilEvent == 0 ? remaining : framesUntilEvent)
            )
            guard requestedSliceValue > 0 else {
                throw ScoreAudioEngineError.offlineRenderFailed(
                    "The render event plan made no forward progress."
                )
            }

            let status = try engine.renderOffline(
                AVAudioFrameCount(requestedSliceValue),
                to: renderBuffer
            )
            switch status {
            case .success where renderBuffer.frameLength > 0:
                analyze(
                    renderBuffer,
                    peakMagnitude: &peakMagnitude,
                    largestSampleDelta: &largestSampleDelta,
                    nonFiniteSampleCount: &nonFiniteSampleCount,
                    previousSamples: &previousSamples
                )
                renderedFrames += Int64(renderBuffer.frameLength)
                consecutiveNoProgressRetries = 0
            case .success, .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                recoverableRenderRetries += 1
                consecutiveNoProgressRetries += 1
                if consecutiveNoProgressRetries > 1_000 {
                    throw ScoreAudioEngineError.offlineRenderFailed(
                        "The renderer made no progress after 1,000 consecutive retries."
                    )
                }
            case .error:
                throw ScoreAudioEngineError.offlineRenderFailed(
                    "AVAudioEngine returned the error render status."
                )
            @unknown default:
                throw ScoreAudioEngineError.offlineRenderFailed(
                    "AVAudioEngine returned an unknown render status."
                )
            }
        }

        phaseCheckCount += 1
        if !playersArePhaseAligned(activeDeck.players.values, engine: engine) {
            phaseAlignmentFailures += 1
        }
        engine.stop()
        return OfflineRenderReport(
            requestedFrames: requestedFrames,
            renderedFrames: renderedFrames,
            peakMagnitude: peakMagnitude,
            largestSampleDelta: largestSampleDelta,
            nonFiniteSampleCount: nonFiniteSampleCount,
            recoverableRenderRetries: recoverableRenderRetries,
            stemFrameCountsMatch: stemFrameCountsMatch,
            scheduledEnergyTransitions: scheduledEnergyTransitions,
            scheduledSectionTransitions: scheduledSectionTransitions,
            boundaryCheckCount: boundaryCheckCount,
            boundaryAlignmentFailures: boundaryAlignmentFailures,
            phaseCheckCount: phaseCheckCount,
            phaseAlignmentFailures: phaseAlignmentFailures
        )
    }

    private static func renderEvents(
        pack: ScorePack,
        throughFrame endFrame: Int64,
        initialSectionID: String,
        initialEnergy: EnergyTier
    ) throws -> [OfflineRenderEvent] {
        var events: [OfflineRenderEvent] = []
        let energyCycle: [EnergyTier] = [.easy, .steady, .brisk, .surge, .steady]
        var barIndex: Int64 = 1
        var energyIndex = energyCycle.firstIndex(of: initialEnergy).map { $0 + 1 } ?? 0
        while true {
            let frame = try pack.grid.frame(atBar: barIndex)
            guard frame < endFrame else { break }
            events.append(
                OfflineRenderEvent(
                    frame: frame,
                    boundary: .bar,
                    target: .energy(energyCycle[energyIndex % energyCycle.count])
                )
            )
            energyIndex += 1
            barIndex += 1
        }

        var sectionID = initialSectionID
        var sectionCursor: Int64 = 0
        while let transition = pack.legalTransitions.first(where: {
            $0.fromSectionID == sectionID
        }) {
            let frame = try pack.grid.nextBoundary(
                afterFrame: sectionCursor,
                boundary: transition.boundary
            )
            guard frame < endFrame else { break }
            events.append(
                OfflineRenderEvent(
                    frame: frame,
                    boundary: transition.boundary,
                    target: .section(transition.toSectionID)
                )
            )
            sectionID = transition.toSectionID
            sectionCursor = frame
        }

        return events.sorted {
            if $0.frame != $1.frame { return $0.frame < $1.frame }
            return $0.target.sortPriority < $1.target.sortPriority
        }
    }

    private static func cacheSectionBuffers(
        pack: ScorePack,
        fullStemBuffers: [String: AVAudioPCMBuffer]
    ) throws -> [String: [String: AVAudioPCMBuffer]] {
        var result: [String: [String: AVAudioPCMBuffer]] = [:]
        for section in pack.sections {
            let start = try pack.grid.frame(atBar: section.startBar)
            let end = try pack.grid.frame(atBar: section.startBar + section.barCount)
            var stems: [String: AVAudioPCMBuffer] = [:]
            for stem in pack.stems {
                guard let source = fullStemBuffers[stem.id] else {
                    throw ScoreAudioEngineError.missingResource(stem.asset.resourceName)
                }
                stems[stem.id] = try slice(
                    source,
                    startFrame: start,
                    frameCount: end - start
                )
            }
            result[section.id] = stems
        }
        return result
    }

    private static func scheduleSection(
        _ sectionID: String,
        on deck: OfflineStemDeck,
        pack: ScorePack,
        sectionBuffers: [String: [String: AVAudioPCMBuffer]],
        energy: EnergyTier
    ) throws {
        guard let section = pack.sections.first(where: { $0.id == sectionID }),
              let buffers = sectionBuffers[sectionID] else {
            throw ScoreAudioEngineError.unknownSection(sectionID)
        }
        deck.stop()
        for stem in pack.stems {
            guard let player = deck.players[stem.id], let buffer = buffers[stem.id] else {
                throw ScoreAudioEngineError.missingResource(stem.asset.resourceName)
            }
            deck.retainedBuffers.append(buffer)
            player.scheduleBuffer(
                buffer,
                at: nil,
                options: section.loops ? .loops : [],
                completionHandler: nil
            )
            player.play()
        }
        applyMix(energy, to: deck, pack: pack)
    }

    private static func applyMix(
        _ energy: EnergyTier,
        to deck: OfflineStemDeck,
        pack: ScorePack
    ) {
        let gains = pack.intensityMixes.first(where: { $0.energy == energy })?.stemGains ?? [:]
        for stem in pack.stems {
            let decibels = gains[stem.id] ?? -96
            deck.players[stem.id]?.volume = decibels <= -96
                ? 0
                : Float(pow(10, decibels / 20))
        }
    }

    private static func playersArePhaseAligned<S: Sequence>(
        _ players: S,
        engine: AVAudioEngine
    ) -> Bool where S.Element == AVAudioPlayerNode {
        let playerList = Array(players)
        let positions = playerList.compactMap { player -> AVAudioFramePosition? in
            // Offline rendering can expose a node time without either validity flag.
            // Use the engine's documented sample timeline before asking AVFAudio to convert it.
            let renderTime: AVAudioTime
            if let lastRenderTime = player.lastRenderTime,
               lastRenderTime.isSampleTimeValid || lastRenderTime.isHostTimeValid {
                renderTime = lastRenderTime
            } else {
                renderTime = AVAudioTime(
                    sampleTime: engine.manualRenderingSampleTime,
                    atRate: engine.manualRenderingFormat.sampleRate
                )
            }
            guard let playerTime = player.playerTime(forNodeTime: renderTime),
                  playerTime.isSampleTimeValid else {
                return nil
            }
            return playerTime.sampleTime
        }
        guard !positions.isEmpty, positions.count == playerList.count else { return false }
        return Set(positions).count == 1
    }

    private static func loadPCMBuffer(from url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard file.length > 0,
              file.length <= Int64(UInt32.max),
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
        let end = startFrame.addingReportingOverflow(frameCount)
        guard startFrame >= 0,
              frameCount > 0,
              !end.overflow,
              end.partialValue <= Int64(source.frameLength),
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

    private static func analyze(
        _ buffer: AVAudioPCMBuffer,
        peakMagnitude: inout Float,
        largestSampleDelta: inout Float,
        nonFiniteSampleCount: inout Int,
        previousSamples: inout [Float]
    ) {
        guard let channels = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        for channel in 0..<channelCount {
            var previous = previousSamples[channel]
            for frame in 0..<frameCount {
                let sample = channels[channel][frame]
                guard sample.isFinite else {
                    nonFiniteSampleCount += 1
                    continue
                }
                peakMagnitude = max(peakMagnitude, abs(sample))
                largestSampleDelta = max(largestSampleDelta, abs(sample - previous))
                previous = sample
            }
            previousSamples[channel] = previous
        }
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }
}

private final class OfflineStemDeck {
    var players: [String: AVAudioPlayerNode]
    var retainedBuffers: [AVAudioPCMBuffer] = []

    init(stemIDs: [String]) {
        players = Dictionary(uniqueKeysWithValues: stemIDs.map { ($0, AVAudioPlayerNode()) })
    }

    func stop() {
        for player in players.values {
            player.stop()
        }
        retainedBuffers.removeAll(keepingCapacity: true)
    }
}

private struct OfflineRenderEvent {
    var frame: Int64
    var boundary: MusicalBoundary
    var target: OfflineRenderTarget
}

private enum OfflineRenderTarget {
    case energy(EnergyTier)
    case section(String)

    var sortPriority: Int {
        switch self {
        case .section:
            return 0
        case .energy:
            return 1
        }
    }
}
