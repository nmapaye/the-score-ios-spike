import Foundation

public enum ScoreCoreError: Error, Sendable, Equatable {
    case invalidRational
    case invalidMusicalGrid(String)
    case negativeFrameOrIndex
    case arithmeticOverflow
    case illegalSectionTransition(from: String, to: String)
    case unknownSection(String)
    case queuedTransitionAlreadyExists
    case invalidAcceptedTransition
}

extension ScoreCoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRational:
            return "A rational value needs a positive denominator and a nonnegative numerator."
        case let .invalidMusicalGrid(message):
            return message
        case .negativeFrameOrIndex:
            return "Musical frame and boundary indexes cannot be negative."
        case .arithmeticOverflow:
            return "The musical frame calculation exceeded Int64 capacity."
        case let .illegalSectionTransition(from, to):
            return "The score does not authorize a transition from \(from) to \(to)."
        case let .unknownSection(id):
            return "The score does not contain section \(id)."
        case .queuedTransitionAlreadyExists:
            return "An arrangement transition is already queued."
        case .invalidAcceptedTransition:
            return "The audio transport accepted a different or invalid arrangement transition."
        }
    }
}

public struct Rational: Codable, Sendable, Equatable {
    public let numerator: Int64
    public let denominator: Int64

    public init(numerator: Int64, denominator: Int64) throws {
        guard numerator >= 0, denominator > 0 else {
            throw ScoreCoreError.invalidRational
        }

        let divisor = Self.greatestCommonDivisor(numerator, denominator)
        self.numerator = numerator / divisor
        self.denominator = denominator / divisor
    }

    private enum CodingKeys: String, CodingKey {
        case numerator
        case denominator
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let numerator = try values.decode(Int64.self, forKey: .numerator)
        let denominator = try values.decode(Int64.self, forKey: .denominator)
        try self.init(numerator: numerator, denominator: denominator)
    }

    private static func greatestCommonDivisor(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        var a = lhs
        var b = rhs
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return max(a, 1)
    }
}

public enum FrameRounding: String, Codable, Sendable, Equatable {
    case down
    case nearest
    case up
}

public struct MusicalGrid: Codable, Sendable, Equatable {
    public let sampleRate: Int64
    public let beatsPerMinute: Rational
    public let beatsPerBar: Int64
    public let beatUnit: Int64
    public let barsPerPhrase: Int64
    public let exactLoopFrames: Int64

    public init(
        sampleRate: Int64,
        beatsPerMinute: Rational,
        beatsPerBar: Int64,
        barsPerPhrase: Int64,
        beatUnit: Int64 = 4,
        exactLoopFrames: Int64
    ) throws {
        guard sampleRate > 0 else {
            throw ScoreCoreError.invalidMusicalGrid("The sample rate must be positive.")
        }
        guard beatsPerMinute.numerator > 0 else {
            throw ScoreCoreError.invalidMusicalGrid("BPM must be greater than zero.")
        }
        guard beatsPerBar > 0, beatUnit > 0, barsPerPhrase > 0 else {
            throw ScoreCoreError.invalidMusicalGrid("Meter and phrase length must be positive.")
        }
        guard !beatsPerBar.multipliedReportingOverflow(by: barsPerPhrase).overflow else {
            throw ScoreCoreError.invalidMusicalGrid("The phrase length exceeds Int64 capacity.")
        }
        guard exactLoopFrames > 0 else {
            throw ScoreCoreError.invalidMusicalGrid("The exact loop frame count must be positive.")
        }

        self.sampleRate = sampleRate
        self.beatsPerMinute = beatsPerMinute
        self.beatsPerBar = beatsPerBar
        self.beatUnit = beatUnit
        self.barsPerPhrase = barsPerPhrase
        self.exactLoopFrames = exactLoopFrames
    }

    private enum CodingKeys: String, CodingKey {
        case sampleRate
        case beatsPerMinute
        case beatsPerBar
        case beatUnit
        case barsPerPhrase
        case exactLoopFrames
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sampleRate: values.decode(Int64.self, forKey: .sampleRate),
            beatsPerMinute: values.decode(Rational.self, forKey: .beatsPerMinute),
            beatsPerBar: values.decode(Int64.self, forKey: .beatsPerBar),
            barsPerPhrase: values.decode(Int64.self, forKey: .barsPerPhrase),
            beatUnit: values.decodeIfPresent(Int64.self, forKey: .beatUnit) ?? 4,
            exactLoopFrames: values.decode(Int64.self, forKey: .exactLoopFrames)
        )
    }

    public var beatsPerPhrase: Int64 {
        beatsPerBar * barsPerPhrase
    }

    public func frame(
        atBeat beat: Int64,
        rounding: FrameRounding = .nearest
    ) throws -> Int64 {
        guard beat >= 0 else {
            throw ScoreCoreError.negativeFrameOrIndex
        }

        let framesPerBeat = try exactFramesPerBeat()
        let product = framesPerBeat.numerator.multipliedReportingOverflow(by: beat)
        guard !product.overflow else {
            throw ScoreCoreError.arithmeticOverflow
        }
        return try Self.divide(
            product.partialValue,
            by: framesPerBeat.denominator,
            rounding: rounding
        )
    }

    public func frame(
        atBar bar: Int64,
        rounding: FrameRounding = .nearest
    ) throws -> Int64 {
        guard bar >= 0 else {
            throw ScoreCoreError.negativeFrameOrIndex
        }
        let beat = bar.multipliedReportingOverflow(by: beatsPerBar)
        guard !beat.overflow else {
            throw ScoreCoreError.arithmeticOverflow
        }
        return try frame(atBeat: beat.partialValue, rounding: rounding)
    }

    public func nextBoundary(
        afterFrame frame: Int64,
        boundary: MusicalBoundary,
        includeCurrent: Bool = false
    ) throws -> Int64 {
        guard frame >= 0 else {
            throw ScoreCoreError.negativeFrameOrIndex
        }

        let beatInterval = boundary == .bar ? beatsPerBar : beatsPerPhrase
        let interval = try exactFrames(forBeatCount: beatInterval)
        let scaledFrame = frame.multipliedReportingOverflow(by: interval.denominator)
        guard !scaledFrame.overflow else {
            throw ScoreCoreError.arithmeticOverflow
        }

        var boundaryIndex = scaledFrame.partialValue / interval.numerator
        var candidate = try frameForBoundaryIndex(
            boundaryIndex,
            beatInterval: beatInterval
        )

        let needsLaterBoundary = includeCurrent ? candidate < frame : candidate <= frame
        if needsLaterBoundary {
            let incremented = boundaryIndex.addingReportingOverflow(1)
            guard !incremented.overflow else {
                throw ScoreCoreError.arithmeticOverflow
            }
            boundaryIndex = incremented.partialValue
            candidate = try frameForBoundaryIndex(
                boundaryIndex,
                beatInterval: beatInterval
            )
        }

        while includeCurrent ? candidate < frame : candidate <= frame {
            let incremented = boundaryIndex.addingReportingOverflow(1)
            guard !incremented.overflow else {
                throw ScoreCoreError.arithmeticOverflow
            }
            boundaryIndex = incremented.partialValue
            candidate = try frameForBoundaryIndex(
                boundaryIndex,
                beatInterval: beatInterval
            )
        }
        return candidate
    }

    public func previousBoundary(
        atOrBeforeFrame frame: Int64,
        boundary: MusicalBoundary
    ) throws -> Int64 {
        guard frame >= 0 else {
            throw ScoreCoreError.negativeFrameOrIndex
        }

        let beatInterval = boundary == .bar ? beatsPerBar : beatsPerPhrase
        let interval = try exactFrames(forBeatCount: beatInterval)
        let scaledFrame = frame.multipliedReportingOverflow(by: interval.denominator)
        guard !scaledFrame.overflow else {
            throw ScoreCoreError.arithmeticOverflow
        }

        var boundaryIndex = scaledFrame.partialValue / interval.numerator
        var candidate = try frameForBoundaryIndex(
            boundaryIndex,
            beatInterval: beatInterval
        )
        let nextIndex = boundaryIndex.addingReportingOverflow(1)
        if !nextIndex.overflow {
            let nextCandidate = try frameForBoundaryIndex(
                nextIndex.partialValue,
                beatInterval: beatInterval
            )
            if nextCandidate <= frame {
                boundaryIndex = nextIndex.partialValue
                candidate = nextCandidate
            }
        }
        while candidate > frame, boundaryIndex > 0 {
            boundaryIndex -= 1
            candidate = try frameForBoundaryIndex(
                boundaryIndex,
                beatInterval: beatInterval
            )
        }
        return candidate
    }

    public func isBoundary(frame: Int64, boundary: MusicalBoundary) throws -> Bool {
        try previousBoundary(atOrBeforeFrame: frame, boundary: boundary) == frame
    }

    private func frameForBoundaryIndex(
        _ index: Int64,
        beatInterval: Int64
    ) throws -> Int64 {
        let beat = index.multipliedReportingOverflow(by: beatInterval)
        guard !beat.overflow else {
            throw ScoreCoreError.arithmeticOverflow
        }
        return try frame(atBeat: beat.partialValue)
    }

    private func exactFramesPerBeat() throws -> Rational {
        let secondsFactor = sampleRate.multipliedReportingOverflow(by: 60)
        guard !secondsFactor.overflow else {
            throw ScoreCoreError.arithmeticOverflow
        }
        let numerator = secondsFactor.partialValue.multipliedReportingOverflow(
            by: beatsPerMinute.denominator
        )
        guard !numerator.overflow else {
            throw ScoreCoreError.arithmeticOverflow
        }
        return try Rational(
            numerator: numerator.partialValue,
            denominator: beatsPerMinute.numerator
        )
    }

    private func exactFrames(forBeatCount beats: Int64) throws -> Rational {
        let framesPerBeat = try exactFramesPerBeat()
        let numerator = framesPerBeat.numerator.multipliedReportingOverflow(by: beats)
        guard !numerator.overflow else {
            throw ScoreCoreError.arithmeticOverflow
        }
        return try Rational(
            numerator: numerator.partialValue,
            denominator: framesPerBeat.denominator
        )
    }

    private static func divide(
        _ numerator: Int64,
        by denominator: Int64,
        rounding: FrameRounding
    ) throws -> Int64 {
        guard numerator >= 0, denominator > 0 else {
            throw ScoreCoreError.invalidRational
        }

        let quotient = numerator / denominator
        let remainder = numerator % denominator
        switch rounding {
        case .down:
            return quotient
        case .up:
            return remainder == 0 ? quotient : quotient + 1
        case .nearest:
            let doubledRemainder = remainder.multipliedReportingOverflow(by: 2)
            guard !doubledRemainder.overflow else {
                throw ScoreCoreError.arithmeticOverflow
            }
            return doubledRemainder.partialValue >= denominator ? quotient + 1 : quotient
        }
    }
}
