import Foundation
import Testing
@testable import ScoreCore

@Suite("Core contracts")
struct ContractTests {
    @Test
    func scorePackRoundTripsThroughJSON() throws {
        let pack = TestFixtures.pack()
        let data = try JSONEncoder().encode(pack)
        let decoded = try JSONDecoder().decode(ScorePack.self, from: data)

        #expect(decoded == pack)
        #expect(decoded.allResourceNames == TestFixtures.resourceNames)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sectionMap = try #require(object["energySectionMap"] as? [String: String])
        #expect(sectionMap["brisk"] == "lift")
    }

    @Test
    func motionObservationRoundTripsThroughJSON() throws {
        let observation = TestFixtures.observation(
            cadence: 112.5,
            activity: .walking,
            confidence: .medium,
            at: Date(timeIntervalSince1970: 500)
        )

        let data = try JSONEncoder().encode(observation)
        #expect(try JSONDecoder().decode(MotionObservation.self, from: data) == observation)
    }

    @Test
    func sessionSummaryPersistsOnlyApprovedFields() throws {
        let summary = SessionSummary(
            packID: "engineering.walk.1",
            duration: 1_234,
            date: Date(timeIntervalSince1970: 10),
            adaptationMode: .automatic
        )

        let data = try JSONEncoder().encode(summary)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(Set(object.keys) == Set(["packID", "duration", "date", "adaptationMode"]))
        #expect(object["route"] == nil)
        #expect(object["cadence"] == nil)
        #expect(object["motion"] == nil)
        #expect(try JSONDecoder().decode(SessionSummary.self, from: data) == summary)
    }

    @Test
    func contractCasesRemainComplete() {
        #expect(EnergyTier.allCases == [.still, .easy, .steady, .brisk, .surge])
        #expect(SessionPhase.allCases.count == 8)
        #expect(AdaptationPolicy.standard.hysteresisStepsPerMinute == 6)
        #expect(AdaptationPolicy.standard.stabilizationDuration == 5)
        #expect(AdaptationPolicy.standard.minimumDwellDuration == 12)
        #expect(AdaptationPolicy.standard.staleAfter == 10)
        #expect(AdaptationPolicy.standard.surgeMaximumDuration == 12)
        #expect(TestFixtures.grid().beatUnit == 4)
    }

    @Test
    func invalidRationalCannotDecode() {
        let invalid = Data(#"{"numerator":120,"denominator":0}"#.utf8)
        #expect(throws: ScoreCoreError.self) {
            try JSONDecoder().decode(Rational.self, from: invalid)
        }
    }

    @Test
    func initialSectionUsesMusicalOrderInsteadOfManifestOrder() {
        var pack = TestFixtures.pack()
        pack.sections.reverse()

        #expect(pack.initialSectionID == "calm")
    }
}
