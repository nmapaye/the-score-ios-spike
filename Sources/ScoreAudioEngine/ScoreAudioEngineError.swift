import Foundation

public enum ScoreAudioEngineError: Error, Sendable, Equatable {
    case notPrepared
    case alreadyRunning
    case resourceEscapesRoot(String)
    case missingResource(String)
    case unreadableManifest(String)
    case invalidPack([String])
    case incompatibleAsset(String)
    case frameCountMismatch(resource: String, expected: Int64, actual: Int64)
    case integrityMismatch(resource: String)
    case audioComponentUnavailable
    case unknownSection(String)
    case illegalSectionTransition(from: String, to: String)
    case transitionInPast
    case unsupportedPCMFormat(String)
    case offlineRenderFailed(String)
}

extension ScoreAudioEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notPrepared:
            return "The audio transport has not prepared a score pack."
        case .alreadyRunning:
            return "The audio transport is already running."
        case let .resourceEscapesRoot(name):
            return "The resource path leaves the score-pack directory: \(name)."
        case let .missingResource(name):
            return "The score-pack resource is missing: \(name)."
        case let .unreadableManifest(message):
            return "The score-pack manifest could not be read: \(message)"
        case let .invalidPack(issues):
            return "The score pack is invalid: \(issues.joined(separator: " | "))"
        case let .incompatibleAsset(name):
            return "The audio asset does not match the pack format: \(name)."
        case let .frameCountMismatch(resource, expected, actual):
            return "\(resource) contains \(actual) frames; the manifest declares \(expected)."
        case let .integrityMismatch(resource):
            return "The SHA-256 value does not match for \(resource)."
        case .audioComponentUnavailable:
            return "This host does not expose the Core Audio player component required by AVAudioPlayerNode."
        case let .unknownSection(id):
            return "The score pack has no section named \(id)."
        case let .illegalSectionTransition(from, to):
            return "The score pack does not allow a transition from \(from) to \(to)."
        case .transitionInPast:
            return "The requested musical transition is already in the past."
        case let .unsupportedPCMFormat(description):
            return "The transport requires noninterleaved Float32 PCM: \(description)."
        case let .offlineRenderFailed(message):
            return "Offline rendering failed: \(message)"
        }
    }
}
