import Testing
@testable import ScoreCore

@Suite("Transition planning")
struct TransitionPlanningTests {
    @Test
    func authoredSectionTransitionUsesItsPhraseBoundary() throws {
        let planner = LegalTransitionPlanner(pack: TestFixtures.pack())
        let transition = try planner.planSectionTransition(
            from: "calm",
            to: "lift",
            afterFrame: 1
        )

        #expect(transition.target == .section("lift"))
        #expect(transition.boundary == .phrase)
        #expect(transition.executeAtFrame == TestFixtures.barFrames * 4)
        #expect(transition.reason == .authoredSectionChange)
    }

    @Test
    func unauthoredTransitionIsRejected() throws {
        var pack = TestFixtures.pack()
        pack.sections.append(
            ScoreSection(
                id: "coda",
                displayName: "Coda",
                startBar: 16,
                barCount: 1,
                loops: true
            )
        )
        let planner = LegalTransitionPlanner(pack: pack)

        do {
            _ = try planner.planSectionTransition(from: "calm", to: "coda", afterFrame: 0)
            Issue.record("Expected an unauthored section transition to fail.")
        } catch {
            #expect(
                error as? ScoreCoreError
                    == .illegalSectionTransition(from: "calm", to: "coda")
            )
        }
    }

    @Test
    func energyTransitionUsesNextBar() throws {
        let planner = LegalTransitionPlanner(pack: TestFixtures.pack())
        let transition = try planner.planEnergyTransition(
            to: .brisk,
            afterFrame: TestFixtures.barFrames,
            reason: .manualSelection
        )

        #expect(transition.executeAtFrame == TestFixtures.barFrames * 2)
        #expect(transition.boundary == .bar)
    }
}
