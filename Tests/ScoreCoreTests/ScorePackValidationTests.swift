import Testing
@testable import ScoreCore

@Suite("Score pack validation")
struct ScorePackValidationTests {
    @Test
    func engineeringPackAndResourcesAreValid() throws {
        let pack = TestFixtures.pack()

        #expect(
            ScorePackValidator.validate(
                pack,
                availableResourceNames: TestFixtures.resourceNames
            ).isEmpty
        )
        try ScorePackValidator.validateOrThrow(
            pack,
            availableResourceNames: TestFixtures.resourceNames
        )
    }

    @Test
    func validatorFindsMissingResourceAndStemLengthMismatch() {
        var pack = TestFixtures.pack()
        pack.stems[0].asset.resourceName = "missing.wav"
        pack.stems[0].asset.exactFrameCount -= 1

        let codes = Set(
            ScorePackValidator.validate(
                pack,
                availableResourceNames: TestFixtures.resourceNames
            ).map(\.code)
        )

        #expect(codes.contains(.missingResource))
        #expect(codes.contains(.stemLengthMismatch))
    }

    @Test
    func validatorFindsInvalidHashAndMixReferences() {
        var pack = TestFixtures.pack()
        pack.integrityHash = "not-a-hash"
        pack.stems[0].asset.sha256 = "1234"
        pack.intensityMixes[0].stemGains.removeValue(forKey: "pad")
        pack.intensityMixes[0].stemGains["ghost"] = .infinity

        let codes = Set(ScorePackValidator.validate(pack).map(\.code))

        #expect(codes.contains(.invalidIntegrityHash))
        #expect(codes.contains(.missingStemInMix))
        #expect(codes.contains(.unknownStemInMix))
        #expect(codes.contains(.invalidStemGain))
    }

    @Test
    func validatorRequiresEveryEnergyMix() {
        var pack = TestFixtures.pack()
        pack.intensityMixes.removeAll { $0.energy == .surge }

        #expect(
            ScorePackValidator.validate(pack).contains { issue in
                issue.code == .missingIntensityMix && issue.message.contains("surge")
            }
        )
    }

    @Test
    func validatorRequiresAtLeastOneStem() {
        var pack = TestFixtures.pack()
        pack.stems = []
        pack.intensityMixes = EnergyTier.allCases.map {
            IntensityMix(energy: $0, stemGains: [:])
        }

        #expect(
            ScorePackValidator.validate(pack).contains { $0.code == .missingStem }
        )
    }

    @Test
    func validatorRejectsUnknownTransitionReferences() {
        var pack = TestFixtures.pack()
        pack.legalTransitions.append(
            LegalSectionTransition(fromSectionID: "calm", toSectionID: "missing")
        )

        #expect(
            ScorePackValidator.validate(pack).contains {
                $0.code == .invalidTransitionReference
            }
        )
    }

    @Test
    func validatorRejectsOffPhraseIntroAndNonLoopingSections() {
        var pack = TestFixtures.pack()
        pack.intro?.exactFrameCount = TestFixtures.barFrames
        pack.sections[0].loops = false

        let codes = Set(ScorePackValidator.validate(pack).map(\.code))
        #expect(codes.contains(.invalidIntroAlignment))
        #expect(codes.contains(.unsupportedNonLoopingSection))
    }

    @Test
    func validatorChecksComposerEnergySectionMap() {
        var pack = TestFixtures.pack()
        pack.energySectionMap?["surge"] = nil
        pack.energySectionMap?["brisk"] = "missing"

        #expect(
            ScorePackValidator.validate(pack).contains {
                $0.code == .invalidEnergySectionMap
            }
        )
    }
}
