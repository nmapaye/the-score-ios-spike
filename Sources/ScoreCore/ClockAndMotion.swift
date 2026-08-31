import Foundation

public protocol ScoreClock: Sendable {
    var now: Date { get }
}

public struct SystemScoreClock: ScoreClock, Sendable {
    public init() {}

    public var now: Date {
        Date()
    }
}

public enum MotionAuthorizationStatus: String, Codable, Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable
}

public protocol MotionSource: Sendable {
    func authorizationStatus() async -> MotionAuthorizationStatus
    func requestAuthorization() async -> MotionAuthorizationStatus
    func observations() async -> AsyncStream<MotionObservation>
    func stop() async
}
