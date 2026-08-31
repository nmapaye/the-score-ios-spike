import Foundation

public enum ScorePackValidationCode: String, Codable, Sendable, Equatable {
    case missingIdentity
    case invalidVersion
    case missingStem
    case invalidStem
    case duplicateStemID
    case duplicateSectionID
    case duplicateResourceName
    case invalidAssetFrameCount
    case stemLengthMismatch
    case missingResource
    case invalidIntegrityHash
    case invalidIntroAlignment
    case invalidSectionRange
    case loopLengthMismatch
    case missingIntensityMix
    case duplicateIntensityMix
    case unknownStemInMix
    case missingStemInMix
    case invalidStemGain
    case invalidTransitionReference
    case duplicateTransition
    case missingLegalSuccessor
    case unsupportedNonLoopingSection
    case invalidEnergySectionMap
    case invalidEntitlement
    case missingProvenance
}

public struct ScorePackValidationIssue: Codable, Sendable, Equatable {
    public var code: ScorePackValidationCode
    public var message: String
    public var path: String

    public init(code: ScorePackValidationCode, message: String, path: String) {
        self.code = code
        self.message = message
        self.path = path
    }
}

public struct ScorePackValidationFailure: Error, Sendable, Equatable {
    public var issues: [ScorePackValidationIssue]

    public init(issues: [ScorePackValidationIssue]) {
        self.issues = issues
    }
}

extension ScorePackValidationFailure: LocalizedError {
    public var errorDescription: String? {
        "The score pack has \(issues.count) validation issue(s)."
    }
}

public enum ScorePackValidator {
    public static func validate(
        _ pack: ScorePack,
        availableResourceNames: Set<String>? = nil
    ) -> [ScorePackValidationIssue] {
        var issues: [ScorePackValidationIssue] = []

        checkIdentity(pack, issues: &issues)
        checkAssets(pack, availableResourceNames: availableResourceNames, issues: &issues)
        checkSections(pack, issues: &issues)
        checkMixes(pack, issues: &issues)
        checkTransitions(pack, issues: &issues)
        checkEntitlement(pack, issues: &issues)
        checkProvenance(pack, issues: &issues)

        return issues
    }

    public static func validateOrThrow(
        _ pack: ScorePack,
        availableResourceNames: Set<String>? = nil
    ) throws {
        let issues = validate(pack, availableResourceNames: availableResourceNames)
        if !issues.isEmpty {
            throw ScorePackValidationFailure(issues: issues)
        }
    }

    private static func checkIdentity(
        _ pack: ScorePack,
        issues: inout [ScorePackValidationIssue]
    ) {
        for (path, value) in [
            ("id", pack.id),
            ("displayName", pack.displayName),
            ("composerName", pack.composerName),
        ] where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(
                code: .missingIdentity,
                message: "\(path) cannot be empty.",
                path: path
            ))
        }

        if pack.contentVersion <= 0 {
            issues.append(.init(
                code: .invalidVersion,
                message: "contentVersion must be positive.",
                path: "contentVersion"
            ))
        }
    }

    private static func checkAssets(
        _ pack: ScorePack,
        availableResourceNames: Set<String>?,
        issues: inout [ScorePackValidationIssue]
    ) {
        if pack.stems.isEmpty {
            issues.append(.init(
                code: .missingStem,
                message: "A score pack needs at least one phase-aligned stem.",
                path: "stems"
            ))
        }
        for (index, stem) in pack.stems.enumerated()
        where stem.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || stem.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(
                code: .invalidStem,
                message: "Each stem needs a nonempty ID and role.",
                path: "stems[\(index)]"
            ))
        }

        let duplicateStemIDs = duplicates(in: pack.stems.map(\.id))
        for id in duplicateStemIDs.sorted() {
            issues.append(.init(
                code: .duplicateStemID,
                message: "Stem ID \(id) is used more than once.",
                path: "stems"
            ))
        }

        var referencedAssets: [(path: String, asset: ScoreAsset)] = pack.stems.enumerated().map {
            ("stems[\($0.offset)].asset", $0.element.asset)
        }
        if let intro = pack.intro {
            referencedAssets.append(("intro", intro))
        }
        if let outro = pack.outro {
            referencedAssets.append(("outro", outro))
        }

        let duplicateResources = duplicates(in: referencedAssets.map { $0.asset.resourceName })
        for name in duplicateResources.sorted() {
            issues.append(.init(
                code: .duplicateResourceName,
                message: "Resource \(name) is assigned to more than one score asset.",
                path: "resources"
            ))
        }

        for reference in referencedAssets {
            if reference.asset.resourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(
                    code: .missingResource,
                    message: "An asset resource name cannot be empty.",
                    path: "\(reference.path).resourceName"
                ))
            }
            if reference.asset.exactFrameCount <= 0 {
                issues.append(.init(
                    code: .invalidAssetFrameCount,
                    message: "An asset frame count must be positive.",
                    path: "\(reference.path).exactFrameCount"
                ))
            }
            if let hash = reference.asset.sha256, !isSHA256(hash) {
                issues.append(.init(
                    code: .invalidIntegrityHash,
                    message: "An asset SHA-256 value must contain exactly 64 hexadecimal characters.",
                    path: "\(reference.path).sha256"
                ))
            }
            if let availableResourceNames,
               !availableResourceNames.contains(reference.asset.resourceName) {
                issues.append(.init(
                    code: .missingResource,
                    message: "Resource \(reference.asset.resourceName) was not found.",
                    path: "\(reference.path).resourceName"
                ))
            }
        }

        if let hash = pack.integrityHash, !isSHA256(hash) {
            issues.append(.init(
                code: .invalidIntegrityHash,
                message: "The pack integrity hash must contain exactly 64 hexadecimal characters.",
                path: "integrityHash"
            ))
        }

        if let intro = pack.intro {
            let alignedFrame = try? pack.grid.previousBoundary(
                atOrBeforeFrame: intro.exactFrameCount,
                boundary: .phrase
            )
            if alignedFrame != intro.exactFrameCount {
                issues.append(.init(
                    code: .invalidIntroAlignment,
                    message: "The intro length must end on a phrase boundary so the core grid remains aligned.",
                    path: "intro.exactFrameCount"
                ))
            }
        }

        for (index, stem) in pack.stems.enumerated()
        where stem.asset.exactFrameCount != pack.grid.exactLoopFrames {
            issues.append(.init(
                code: .stemLengthMismatch,
                message: "Every phase-aligned stem must match the grid loop length.",
                path: "stems[\(index)].asset.exactFrameCount"
            ))
        }
    }

    private static func checkSections(
        _ pack: ScorePack,
        issues: inout [ScorePackValidationIssue]
    ) {
        let duplicateSectionIDs = duplicates(in: pack.sections.map(\.id))
        for id in duplicateSectionIDs.sorted() {
            issues.append(.init(
                code: .duplicateSectionID,
                message: "Section ID \(id) is used more than once.",
                path: "sections"
            ))
        }

        var greatestEndBar: Int64 = 0
        for (index, section) in pack.sections.enumerated() {
            let path = "sections[\(index)]"
            guard !section.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  section.startBar >= 0,
                  section.barCount > 0 else {
                issues.append(.init(
                    code: .invalidSectionRange,
                    message: "A section needs an ID, a nonnegative start bar, and a positive length.",
                    path: path
                ))
                continue
            }

            let addition = section.startBar.addingReportingOverflow(section.barCount)
            guard !addition.overflow else {
                issues.append(.init(
                    code: .invalidSectionRange,
                    message: "The section range exceeds Int64 capacity.",
                    path: path
                ))
                continue
            }
            greatestEndBar = max(greatestEndBar, addition.partialValue)

            if let endFrame = try? pack.grid.frame(atBar: addition.partialValue),
               endFrame > pack.grid.exactLoopFrames {
                issues.append(.init(
                    code: .invalidSectionRange,
                    message: "The section extends beyond the authored loop.",
                    path: path
                ))
            }


            if !section.loops {
                issues.append(.init(
                    code: .unsupportedNonLoopingSection,
                    message: "This transport milestone supports looped sections only.",
                    path: "\(path).loops"
                ))
            }
        }

        if pack.sections.isEmpty {
            issues.append(.init(
                code: .invalidSectionRange,
                message: "A score pack needs at least one section.",
                path: "sections"
            ))
        } else if let expectedLoopFrames = try? pack.grid.frame(atBar: greatestEndBar),
                  expectedLoopFrames != pack.grid.exactLoopFrames {
            issues.append(.init(
                code: .loopLengthMismatch,
                message: "The last authored section must end at the exact loop frame count.",
                path: "grid.exactLoopFrames"
            ))
        }
    }

    private static func checkMixes(
        _ pack: ScorePack,
        issues: inout [ScorePackValidationIssue]
    ) {
        let stemIDs = Set(pack.stems.map(\.id))
        let mixesByEnergy = Dictionary(grouping: pack.intensityMixes, by: \.energy)

        for energy in EnergyTier.allCases {
            let mixes = mixesByEnergy[energy] ?? []
            if mixes.isEmpty {
                issues.append(.init(
                    code: .missingIntensityMix,
                    message: "The \(energy.rawValue) energy tier needs an authored mix.",
                    path: "intensityMixes"
                ))
            } else if mixes.count > 1 {
                issues.append(.init(
                    code: .duplicateIntensityMix,
                    message: "The \(energy.rawValue) energy tier has multiple mixes.",
                    path: "intensityMixes"
                ))
            }
        }

        for (index, mix) in pack.intensityMixes.enumerated() {
            let mixedStemIDs = Set(mix.stemGains.keys)
            for unknownID in mixedStemIDs.subtracting(stemIDs).sorted() {
                issues.append(.init(
                    code: .unknownStemInMix,
                    message: "Mix references unknown stem \(unknownID).",
                    path: "intensityMixes[\(index)].stemGains"
                ))
            }
            for missingID in stemIDs.subtracting(mixedStemIDs).sorted() {
                issues.append(.init(
                    code: .missingStemInMix,
                    message: "Mix omits stem \(missingID).",
                    path: "intensityMixes[\(index)].stemGains"
                ))
            }
            for (stemID, gain) in mix.stemGains
            where !gain.isFinite || gain < -96 || gain > 12 {
                issues.append(.init(
                    code: .invalidStemGain,
                    message: "Stem gain must be finite and between -96 and 12 dB.",
                    path: "intensityMixes[\(index)].stemGains.\(stemID)"
                ))
            }
        }
    }

    private static func checkTransitions(
        _ pack: ScorePack,
        issues: inout [ScorePackValidationIssue]
    ) {
        let sectionIDs = Set(pack.sections.map(\.id))
        if let energySectionMap = pack.energySectionMap {
            for energy in EnergyTier.allCases where energySectionMap[energy.rawValue] == nil {
                issues.append(.init(
                    code: .invalidEnergySectionMap,
                    message: "A composer-authored energy section map must cover \(energy.rawValue).",
                    path: "energySectionMap.\(energy.rawValue)"
                ))
            }
            for (energyName, sectionID) in energySectionMap
            where !sectionIDs.contains(sectionID) {
                issues.append(.init(
                    code: .invalidEnergySectionMap,
                    message: "The \(energyName) energy tier references unknown section \(sectionID).",
                    path: "energySectionMap.\(energyName)"
                ))
            }
            let knownEnergyNames = Set(EnergyTier.allCases.map(\.rawValue))
            for energyName in Set(energySectionMap.keys).subtracting(knownEnergyNames) {
                issues.append(.init(
                    code: .invalidEnergySectionMap,
                    message: "The energy section map contains unknown tier \(energyName).",
                    path: "energySectionMap.\(energyName)"
                ))
            }

            let mappedSections = Set(energySectionMap.values)
            for source in mappedSections {
                for destination in mappedSections where destination != source {
                    if !pack.legalTransitions.contains(where: {
                        $0.fromSectionID == source && $0.toSectionID == destination
                    }) {
                        issues.append(.init(
                            code: .invalidEnergySectionMap,
                            message: "The energy section map needs an authored transition from \(source) to \(destination).",
                            path: "energySectionMap"
                        ))
                    }
                }
            }
        }
        var seen = Set<String>()
        for (index, transition) in pack.legalTransitions.enumerated() {
            if !sectionIDs.contains(transition.fromSectionID)
                || !sectionIDs.contains(transition.toSectionID)
                || transition.fromSectionID == transition.toSectionID {
                issues.append(.init(
                    code: .invalidTransitionReference,
                    message: "A legal transition must connect two different known sections.",
                    path: "legalTransitions[\(index)]"
                ))
            }

            let identity = "\(transition.fromSectionID)|\(transition.toSectionID)|\(transition.boundary.rawValue)"
            if !seen.insert(identity).inserted {
                issues.append(.init(
                    code: .duplicateTransition,
                    message: "The same authored transition appears more than once.",
                    path: "legalTransitions[\(index)]"
                ))
            }
        }

        let sourceSectionIDs = Set(pack.legalTransitions.map(\.fromSectionID))
        for (index, section) in pack.sections.enumerated()
        where !section.loops && !sourceSectionIDs.contains(section.id) {
            issues.append(.init(
                code: .missingLegalSuccessor,
                message: "A non-looping section needs at least one authored successor.",
                path: "sections[\(index)]"
            ))
        }
    }

    private static func checkEntitlement(
        _ pack: ScorePack,
        issues: inout [ScorePackValidationIssue]
    ) {
        switch pack.entitlement.kind {
        case .free where pack.entitlement.productID != nil:
            issues.append(.init(
                code: .invalidEntitlement,
                message: "A free pack cannot have a StoreKit product ID.",
                path: "entitlement.productID"
            ))
        case .nonConsumable:
            if pack.entitlement.productID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                issues.append(.init(
                    code: .invalidEntitlement,
                    message: "A non-consumable pack needs a product ID.",
                    path: "entitlement.productID"
                ))
            }
        default:
            break
        }
    }

    private static func checkProvenance(
        _ pack: ScorePack,
        issues: inout [ScorePackValidationIssue]
    ) {
        if pack.provenance.sourceDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || pack.provenance.composerCredit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(
                code: .missingProvenance,
                message: "Source description and composer credit are required.",
                path: "provenance"
            ))
        }
    }

    private static func duplicates(in values: [String]) -> Set<String> {
        var seen = Set<String>()
        return Set(values.filter { !seen.insert($0).inserted })
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...70, 97...102:
                return true
            default:
                return false
            }
        }
    }
}
