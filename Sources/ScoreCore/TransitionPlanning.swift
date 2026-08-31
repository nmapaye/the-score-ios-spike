import Foundation

public struct LegalTransitionPlanner: Sendable {
    public let pack: ScorePack

    public init(pack: ScorePack) {
        self.pack = pack
    }

    public func planSectionTransition(
        from sourceSectionID: String,
        to destinationSectionID: String,
        afterFrame frame: Int64
    ) throws -> QueuedTransition {
        guard pack.sections.contains(where: { $0.id == sourceSectionID }) else {
            throw ScoreCoreError.unknownSection(sourceSectionID)
        }
        guard pack.sections.contains(where: { $0.id == destinationSectionID }) else {
            throw ScoreCoreError.unknownSection(destinationSectionID)
        }
        guard let authoredTransition = pack.legalTransitions.first(where: {
            $0.fromSectionID == sourceSectionID && $0.toSectionID == destinationSectionID
        }) else {
            throw ScoreCoreError.illegalSectionTransition(
                from: sourceSectionID,
                to: destinationSectionID
            )
        }

        let boundaryFrame = try pack.grid.nextBoundary(
            afterFrame: frame,
            boundary: authoredTransition.boundary
        )
        return QueuedTransition(
            target: .section(destinationSectionID),
            boundary: authoredTransition.boundary,
            executeAtFrame: boundaryFrame,
            reason: .authoredSectionChange
        )
    }

    public func planEnergyTransition(
        to energy: EnergyTier,
        afterFrame frame: Int64,
        reason: ArrangementTransitionReason
    ) throws -> QueuedTransition {
        QueuedTransition(
            target: .energy(energy),
            boundary: .bar,
            executeAtFrame: try pack.grid.nextBoundary(
                afterFrame: frame,
                boundary: .bar
            ),
            reason: reason
        )
    }

    public func boundaryPoint(atFrame frame: Int64) throws -> MusicalBoundaryPoint {
        let phraseFrame = try pack.grid.previousBoundary(
            atOrBeforeFrame: frame,
            boundary: .phrase
        )
        if phraseFrame == frame {
            return MusicalBoundaryPoint(kind: .phrase, frame: frame)
        }
        return MusicalBoundaryPoint(
            kind: .bar,
            frame: try pack.grid.previousBoundary(
                atOrBeforeFrame: frame,
                boundary: .bar
            )
        )
    }
}
