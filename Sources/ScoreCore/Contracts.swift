import Foundation

public enum EnergyTier: String, Codable, Sendable, Equatable, CaseIterable {
    case still
    case easy
    case steady
    case brisk
    case surge
}

public enum AdaptationMode: String, Codable, Sendable, Equatable {
    case automatic
    case manual
}

public struct AdaptationPolicy: Codable, Sendable, Equatable {
    public var stillCadenceUpperBound: Double
    public var steadyCadenceLowerBound: Double
    public var briskCadenceLowerBound: Double
    public var hysteresisStepsPerMinute: Double
    public var smoothingWindow: TimeInterval
    public var stabilizationDuration: TimeInterval
    public var minimumDwellDuration: TimeInterval
    public var staleAfter: TimeInterval
    public var surgeMaximumDuration: TimeInterval

    public init(
        stillCadenceUpperBound: Double = 20,
        steadyCadenceLowerBound: Double = 100,
        briskCadenceLowerBound: Double = 125,
        hysteresisStepsPerMinute: Double = 6,
        smoothingWindow: TimeInterval = 5,
        stabilizationDuration: TimeInterval = 5,
        minimumDwellDuration: TimeInterval = 12,
        staleAfter: TimeInterval = 10,
        surgeMaximumDuration: TimeInterval = 12
    ) {
        self.stillCadenceUpperBound = stillCadenceUpperBound
        self.steadyCadenceLowerBound = steadyCadenceLowerBound
        self.briskCadenceLowerBound = briskCadenceLowerBound
        self.hysteresisStepsPerMinute = hysteresisStepsPerMinute
        self.smoothingWindow = smoothingWindow
        self.stabilizationDuration = stabilizationDuration
        self.minimumDwellDuration = minimumDwellDuration
        self.staleAfter = staleAfter
        self.surgeMaximumDuration = surgeMaximumDuration
    }

    public static let standard = AdaptationPolicy()
}

public enum MotionObservationSource: String, Codable, Sendable, Equatable {
    case pedometer
    case motionActivity
    case combined
    case manual
    case unavailable
}

public enum MotionActivityClassification: String, Codable, Sendable, Equatable {
    case stationary
    case walking
    case running
    case cycling
    case automotive
    case unknown
}

public enum MotionConfidence: String, Codable, Sendable, Equatable {
    case low
    case medium
    case high
    case unknown
}

public enum MotionFreshness: String, Codable, Sendable, Equatable {
    case fresh
    case stale
}

public struct MotionObservation: Codable, Sendable, Equatable {
    public var cadenceStepsPerMinute: Double?
    public var activity: MotionActivityClassification
    public var confidence: MotionConfidence
    public var timestamp: Date
    public var source: MotionObservationSource
    public var freshness: MotionFreshness

    public init(
        cadenceStepsPerMinute: Double?,
        activity: MotionActivityClassification,
        confidence: MotionConfidence,
        timestamp: Date,
        source: MotionObservationSource,
        freshness: MotionFreshness = .fresh
    ) {
        self.cadenceStepsPerMinute = cadenceStepsPerMinute
        self.activity = activity
        self.confidence = confidence
        self.timestamp = timestamp
        self.source = source
        self.freshness = freshness
    }
}

public struct ScoreAsset: Codable, Sendable, Equatable {
    public var resourceName: String
    public var exactFrameCount: Int64
    public var sha256: String?

    public init(
        resourceName: String,
        exactFrameCount: Int64,
        sha256: String? = nil
    ) {
        self.resourceName = resourceName
        self.exactFrameCount = exactFrameCount
        self.sha256 = sha256
    }
}

public struct ScoreStem: Codable, Sendable, Equatable {
    public var id: String
    public var role: String
    public var asset: ScoreAsset

    public init(id: String, role: String, asset: ScoreAsset) {
        self.id = id
        self.role = role
        self.asset = asset
    }
}

public struct ScoreSection: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var startBar: Int64
    public var barCount: Int64
    public var loops: Bool

    public init(
        id: String,
        displayName: String,
        startBar: Int64,
        barCount: Int64,
        loops: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.startBar = startBar
        self.barCount = barCount
        self.loops = loops
    }
}

public struct IntensityMix: Codable, Sendable, Equatable {
    public var energy: EnergyTier
    public var stemGains: [String: Double]

    public init(energy: EnergyTier, stemGains: [String: Double]) {
        self.energy = energy
        self.stemGains = stemGains
    }
}

public enum MusicalBoundary: String, Codable, Sendable, Equatable {
    case bar
    case phrase
}

public struct LegalSectionTransition: Codable, Sendable, Equatable {
    public var fromSectionID: String
    public var toSectionID: String
    public var boundary: MusicalBoundary

    public init(
        fromSectionID: String,
        toSectionID: String,
        boundary: MusicalBoundary = .phrase
    ) {
        self.fromSectionID = fromSectionID
        self.toSectionID = toSectionID
        self.boundary = boundary
    }
}

public enum EntitlementKind: String, Codable, Sendable, Equatable {
    case free
    case nonConsumable
}

public struct ScoreEntitlement: Codable, Sendable, Equatable {
    public var kind: EntitlementKind
    public var productID: String?

    public init(kind: EntitlementKind, productID: String? = nil) {
        self.kind = kind
        self.productID = productID
    }
}

public enum RightsStatus: String, Codable, Sendable, Equatable {
    case engineeringOnly
    case contractCleared
}

public struct ScoreProvenance: Codable, Sendable, Equatable {
    public var sourceDescription: String
    public var composerCredit: String
    public var rightsStatus: RightsStatus
    public var notes: String?

    public init(
        sourceDescription: String,
        composerCredit: String,
        rightsStatus: RightsStatus,
        notes: String? = nil
    ) {
        self.sourceDescription = sourceDescription
        self.composerCredit = composerCredit
        self.rightsStatus = rightsStatus
        self.notes = notes
    }
}

public struct ScorePack: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var composerName: String
    public var contentVersion: Int
    public var grid: MusicalGrid
    public var stems: [ScoreStem]
    public var sections: [ScoreSection]
    public var intensityMixes: [IntensityMix]
    /// Optional composer-authored section choices for movement energy tiers.
    /// Packs without this map keep their current section until an explicit request.
    public var energySectionMap: [String: String]?
    public var legalTransitions: [LegalSectionTransition]
    public var intro: ScoreAsset?
    public var outro: ScoreAsset?
    public var entitlement: ScoreEntitlement
    public var provenance: ScoreProvenance
    public var integrityHash: String?

    public init(
        id: String,
        displayName: String,
        composerName: String,
        contentVersion: Int,
        grid: MusicalGrid,
        stems: [ScoreStem],
        sections: [ScoreSection],
        intensityMixes: [IntensityMix],
        energySectionMap: [String: String]? = nil,
        legalTransitions: [LegalSectionTransition],
        intro: ScoreAsset?,
        outro: ScoreAsset?,
        entitlement: ScoreEntitlement,
        provenance: ScoreProvenance,
        integrityHash: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.composerName = composerName
        self.contentVersion = contentVersion
        self.grid = grid
        self.stems = stems
        self.sections = sections
        self.intensityMixes = intensityMixes
        self.energySectionMap = energySectionMap
        self.legalTransitions = legalTransitions
        self.intro = intro
        self.outro = outro
        self.entitlement = entitlement
        self.provenance = provenance
        self.integrityHash = integrityHash
    }

    public var allResourceNames: Set<String> {
        var names = Set(stems.map(\.asset.resourceName))
        if let intro {
            names.insert(intro.resourceName)
        }
        if let outro {
            names.insert(outro.resourceName)
        }
        return names
    }

    /// The first authored section is determined by musical position rather than
    /// JSON array order, so every layer starts from the same section.
    public var initialSectionID: String? {
        sections.min {
            if $0.startBar == $1.startBar {
                return $0.id < $1.id
            }
            return $0.startBar < $1.startBar
        }?.id
    }

    public func sectionID(for energy: EnergyTier) -> String? {
        energySectionMap?[energy.rawValue]
    }
}

public struct MusicalBoundaryPoint: Codable, Sendable, Equatable {
    public var kind: MusicalBoundary
    public var frame: Int64

    public init(kind: MusicalBoundary, frame: Int64) {
        self.kind = kind
        self.frame = frame
    }
}

public enum ArrangementTransitionTarget: Codable, Sendable, Equatable {
    case energy(EnergyTier)
    case section(String)
}

public enum ArrangementTransitionReason: String, Codable, Sendable, Equatable {
    case adaptiveCadence
    case runningSurge
    case surgeExpired
    case manualSelection
    case motionPermissionDenied
    case authoredSectionChange
}

public struct QueuedTransition: Codable, Sendable, Equatable {
    public var target: ArrangementTransitionTarget
    public var boundary: MusicalBoundary
    public var executeAtFrame: Int64
    public var reason: ArrangementTransitionReason

    public init(
        target: ArrangementTransitionTarget,
        boundary: MusicalBoundary,
        executeAtFrame: Int64,
        reason: ArrangementTransitionReason
    ) {
        self.target = target
        self.boundary = boundary
        self.executeAtFrame = executeAtFrame
        self.reason = reason
    }
}

public struct ArrangementState: Codable, Sendable, Equatable {
    public var transportFrame: Int64
    public var sectionID: String
    public var currentEnergy: EnergyTier
    public var requestedEnergy: EnergyTier
    public var currentMusicalBoundary: MusicalBoundaryPoint
    public var queuedTransition: QueuedTransition?
    public var adaptationMode: AdaptationMode
    public var inputIsStale: Bool

    public init(
        transportFrame: Int64,
        sectionID: String,
        currentEnergy: EnergyTier,
        requestedEnergy: EnergyTier,
        currentMusicalBoundary: MusicalBoundaryPoint,
        queuedTransition: QueuedTransition?,
        adaptationMode: AdaptationMode,
        inputIsStale: Bool
    ) {
        self.transportFrame = transportFrame
        self.sectionID = sectionID
        self.currentEnergy = currentEnergy
        self.requestedEnergy = requestedEnergy
        self.currentMusicalBoundary = currentMusicalBoundary
        self.queuedTransition = queuedTransition
        self.adaptationMode = adaptationMode
        self.inputIsStale = inputIsStale
    }
}

public struct SessionSummary: Codable, Sendable, Equatable {
    public var packID: String
    public var duration: TimeInterval
    public var date: Date
    public var adaptationMode: AdaptationMode

    public init(
        packID: String,
        duration: TimeInterval,
        date: Date,
        adaptationMode: AdaptationMode
    ) {
        self.packID = packID
        self.duration = duration
        self.date = date
        self.adaptationMode = adaptationMode
    }
}
