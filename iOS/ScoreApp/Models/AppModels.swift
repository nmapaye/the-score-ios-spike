import Foundation

enum AppScreen: Equatable {
    case onboarding
    case home
    case active
    case completion(CompletedWalk)
}

enum PresentedEnergy: String, CaseIterable, Codable, Equatable, Sendable {
    case still
    case easy
    case steady
    case brisk
    case surge

    var title: String {
        rawValue.capitalized
    }

    static var manualCases: [PresentedEnergy] {
        [.easy, .steady, .brisk]
    }
}

enum PresentedAdaptationMode: String, Codable, Equatable, Sendable {
    case automatic
    case manual

    var title: String {
        switch self {
        case .automatic:
            "Auto"
        case .manual:
            "Manual"
        }
    }
}

enum MotionPermission: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable

    var canUseAutomaticMode: Bool {
        self == .authorized
    }

    var explanation: String {
        switch self {
        case .notDetermined:
            "Motion access has not been requested."
        case .authorized:
            "Movement can shape the arrangement while this session is active."
        case .denied:
            "Motion access is off. Manual intensity remains available."
        case .restricted:
            "Motion access is restricted on this device. Manual intensity remains available."
        case .unavailable:
            "Cadence is unavailable on this device. Manual intensity remains available."
        }
    }
}

enum PresentedActivity: String, Codable, Equatable, Sendable {
    case stationary
    case walking
    case running
    case automotive
    case cycling
    case unknown
}

enum PresentedMotionConfidence: String, Codable, Equatable, Sendable {
    case low
    case medium
    case high
}

struct PresentedMotionObservation: Equatable, Sendable {
    let cadenceStepsPerMinute: Double?
    let activity: PresentedActivity
    let confidence: PresentedMotionConfidence
    let timestamp: Date
    let isStale: Bool
}

struct CompletedWalk: Equatable, Sendable {
    let packID: String
    let duration: TimeInterval
    let date: Date
    let adaptationMode: PresentedAdaptationMode
}

extension TimeInterval {
    var shortClockText: String {
        let seconds = max(0, Int(self.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
