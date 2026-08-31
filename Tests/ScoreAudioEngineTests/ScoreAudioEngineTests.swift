import Foundation
import ScoreCore
import Testing
@testable import ScoreAudioEngine

@Suite("ScoreAudioEngine")
struct ScoreAudioEngineTests {
    @Test("The bundled engineering fixture validates and matches its hashes")
    func engineeringFixtureIntegrity() throws {
        let loaded = try EngineeringScoreFixture.load()
        let inspections = try AudioAssetInspector.inspect(
            pack: loaded.pack,
            resourceRoot: loaded.resourceRoot
        )

        #expect(loaded.pack.provenance.rightsStatus == .engineeringOnly)
        #expect(loaded.pack.stems.count == 4)
        #expect(inspections.count == 6)
        #expect(inspections.allSatisfy { $0.sampleRate == 48_000 })
        #expect(inspections.allSatisfy { $0.sha256.count == 64 })
        #expect(Set(inspections.map(\.resourceName)) == loaded.pack.allResourceNames)
    }

    @Test("Resource resolution cannot leave the pack directory")
    func resourceTraversalIsRejected() throws {
        let loaded = try EngineeringScoreFixture.load()
        do {
            _ = try AudioAssetInspector.resolvedURL(
                for: "../pack.json",
                beneath: loaded.resourceRoot
            )
            Issue.record("Expected path traversal to be rejected")
        } catch let error as ScoreAudioEngineError {
            #expect(error == .resourceEscapesRoot("../pack.json"))
        }
    }

    @Test("The declared asset-set integrity hash is enforced")
    func assetSetIntegrityIsEnforced() throws {
        var loaded = try EngineeringScoreFixture.load()
        loaded.pack.integrityHash = String(repeating: "0", count: 64)

        do {
            _ = try AudioAssetInspector.inspect(
                pack: loaded.pack,
                resourceRoot: loaded.resourceRoot
            )
            Issue.record("Expected the asset-set integrity mismatch to be rejected")
        } catch let error as ScoreAudioEngineError {
            #expect(error == .integrityMismatch(resource: "pack.integrityHash"))
        }
    }

    @Test("Late transition acceptance returns the later exact boundary")
    func lateTransitionAcceptanceIsExplicit() throws {
        let loaded = try EngineeringScoreFixture.load()
        let requested = QueuedTransition(
            target: .energy(.brisk),
            boundary: .bar,
            executeAtFrame: 96_000,
            reason: .manualSelection
        )

        let onTime = try AVAudioEngineTransport.acceptedTransition(
            requested,
            currentFrame: 0,
            grid: loaded.pack.grid
        )
        let late = try AVAudioEngineTransport.acceptedTransition(
            requested,
            currentFrame: 90_000,
            grid: loaded.pack.grid
        )

        #expect(onTime == requested)
        #expect(late.executeAtFrame == 192_000)
        #expect(late.target == requested.target)
        #expect(late.boundary == requested.boundary)
        #expect(late.reason == requested.reason)
    }

    @Test("Offline rendering rejects nonfinite duration before audio setup")
    func nonfiniteOfflineDurationIsRejected() throws {
        let loaded = try EngineeringScoreFixture.load()
        do {
            _ = try OfflineRenderVerifier.render(
                pack: loaded.pack,
                resourceRoot: loaded.resourceRoot,
                duration: .infinity
            )
            Issue.record("Expected an infinite duration to be rejected")
        } catch let error as ScoreAudioEngineError {
            guard case .offlineRenderFailed = error else {
                Issue.record("Expected offlineRenderFailed, received \(error)")
                return
            }
        }
    }

    @Test(
        "A short offline render produces finite audio for every requested frame",
        .enabled(if: AudioRuntimeCapabilities.supportsScheduledSoundPlayer)
    )
    func shortOfflineRender() throws {
        let loaded = try EngineeringScoreFixture.load()
        let report = try OfflineRenderVerifier.render(
            pack: loaded.pack,
            resourceRoot: loaded.resourceRoot,
            duration: 0.25
        )

        #expect(report.completedRequestedDuration)
        #expect(report.renderedFrames == 12_000)
        #expect(report.nonFiniteSampleCount == 0)
        #expect(report.peakMagnitude > 0)
        #expect(report.peakMagnitude <= 1)
        #expect(report.stemFrameCountsMatch)
        #expect(report.phaseAlignmentFailures == 0)
    }

    @Test(
        "The offline harness applies bar and phrase events without losing stem phase",
        .enabled(if: AudioRuntimeCapabilities.supportsScheduledSoundPlayer)
    )
    func transitionOfflineRender() throws {
        let loaded = try EngineeringScoreFixture.load()
        let report = try OfflineRenderVerifier.render(
            pack: loaded.pack,
            resourceRoot: loaded.resourceRoot,
            duration: 16.25
        )

        #expect(report.completedRequestedDuration)
        #expect(report.scheduledEnergyTransitions > 0)
        #expect(report.scheduledSectionTransitions > 0)
        #expect(report.transitionsWereBoundaryAligned)
        #expect(report.stemsRemainedPhaseAligned)
        #expect(report.nonFiniteSampleCount == 0)
    }

    @Test(
        "The transport prepares without opening an output route",
        .enabled(if: AudioRuntimeCapabilities.supportsScheduledSoundPlayer)
    )
    func transportPreparation() async throws {
        let loaded = try EngineeringScoreFixture.load()
        let transport = AVAudioEngineTransport()
        try await transport.prepare(
            pack: loaded.pack,
            resourceRoot: loaded.resourceRoot
        )

        #expect(await transport.currentTransportFrame() == 0)
        await transport.stopImmediately()
    }

    @Test(
        "A failed reprepare invalidates the prior pack",
        .enabled(if: AudioRuntimeCapabilities.supportsScheduledSoundPlayer)
    )
    func failedReprepareInvalidatesPriorPack() async throws {
        let loaded = try EngineeringScoreFixture.load()
        let transport = AVAudioEngineTransport()
        try await transport.prepare(pack: loaded.pack, resourceRoot: loaded.resourceRoot)

        var invalidPack = loaded.pack
        invalidPack.sections = []
        do {
            try await transport.prepare(pack: invalidPack, resourceRoot: loaded.resourceRoot)
            Issue.record("Expected invalid reprepare to fail")
        } catch {
            // The failed replacement must leave no startable prior pack behind.
        }

        do {
            try await transport.start()
            Issue.record("Expected the failed reprepare to invalidate the transport")
        } catch let error as ScoreAudioEngineError {
            #expect(error == .notPrepared)
        }
    }

    @Test(
        "One-hour offline phase stress harness",
        .enabled(
            if: AudioRuntimeCapabilities.supportsScheduledSoundPlayer
                && ProcessInfo.processInfo.environment["SCORE_RUN_AUDIO_STRESS"] == "1"
        )
    )
    func oneHourOfflineStress() throws {
        let loaded = try EngineeringScoreFixture.load()
        let report = try OfflineRenderVerifier.render(
            pack: loaded.pack,
            resourceRoot: loaded.resourceRoot,
            duration: 3_600
        )

        #expect(report.completedRequestedDuration)
        #expect(report.nonFiniteSampleCount == 0)
        #expect(report.stemFrameCountsMatch)
        #expect(report.scheduledEnergyTransitions > 0)
        #expect(report.scheduledSectionTransitions > 0)
        #expect(report.transitionsWereBoundaryAligned)
        #expect(report.stemsRemainedPhaseAligned)
    }
}
