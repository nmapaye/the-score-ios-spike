import Foundation
@testable import ScoreCore

final class TestClock: @unchecked Sendable {
    var now: Date

    init(now: Date = Date(timeIntervalSince1970: 1_000)) {
        self.now = now
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

extension TestClock: ScoreClock {}

enum TestFixtures {
    static let sampleRate: Int64 = 48_000
    static let barFrames: Int64 = 96_000
    static let loopFrames: Int64 = 1_536_000

    static func grid() -> MusicalGrid {
        try! MusicalGrid(
            sampleRate: sampleRate,
            beatsPerMinute: Rational(numerator: 120, denominator: 1),
            beatsPerBar: 4,
            barsPerPhrase: 4,
            exactLoopFrames: loopFrames
        )
    }

    static func pack() -> ScorePack {
        let stems = ["pad", "pulse", "percussion", "motif"].map { id in
            ScoreStem(
                id: id,
                role: id.capitalized,
                asset: ScoreAsset(
                    resourceName: "core_\(id).wav",
                    exactFrameCount: loopFrames
                )
            )
        }
        let mixes = EnergyTier.allCases.map { energy in
            IntensityMix(
                energy: energy,
                stemGains: Dictionary(uniqueKeysWithValues: stems.map { ($0.id, -6.0) })
            )
        }
        return ScorePack(
            id: "engineering.walk.1",
            displayName: "Engineering Walk",
            composerName: "Test Oscillators",
            contentVersion: 1,
            grid: grid(),
            stems: stems,
            sections: [
                ScoreSection(
                    id: "calm",
                    displayName: "Calm",
                    startBar: 0,
                    barCount: 8,
                    loops: true
                ),
                ScoreSection(
                    id: "lift",
                    displayName: "Lift",
                    startBar: 8,
                    barCount: 8,
                    loops: true
                ),
            ],
            intensityMixes: mixes,
            energySectionMap: [
                "still": "calm",
                "easy": "calm",
                "steady": "calm",
                "brisk": "lift",
                "surge": "lift",
            ],
            legalTransitions: [
                LegalSectionTransition(fromSectionID: "calm", toSectionID: "lift"),
                LegalSectionTransition(fromSectionID: "lift", toSectionID: "calm"),
            ],
            intro: ScoreAsset(
                resourceName: "intro.wav",
                exactFrameCount: barFrames * 4
            ),
            outro: ScoreAsset(resourceName: "outro.wav", exactFrameCount: barFrames),
            entitlement: ScoreEntitlement(kind: .free),
            provenance: ScoreProvenance(
                sourceDescription: "Generated test tones",
                composerCredit: "Engineering fixture",
                rightsStatus: .engineeringOnly,
                notes: "Not production music"
            )
        )
    }

    static var resourceNames: Set<String> {
        Set([
            "core_pad.wav",
            "core_pulse.wav",
            "core_percussion.wav",
            "core_motif.wav",
            "intro.wav",
            "outro.wav",
        ])
    }

    static func observation(
        cadence: Double?,
        activity: MotionActivityClassification = .walking,
        confidence: MotionConfidence = .high,
        at date: Date,
        freshness: MotionFreshness = .fresh
    ) -> MotionObservation {
        MotionObservation(
            cadenceStepsPerMinute: cadence,
            activity: activity,
            confidence: confidence,
            timestamp: date,
            source: .combined,
            freshness: freshness
        )
    }
}
