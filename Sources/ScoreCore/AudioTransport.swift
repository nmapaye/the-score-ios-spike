import Foundation

public protocol AudioTransport: Sendable {
    func prepare(pack: ScorePack, resourceRoot: URL) async throws
    func start() async throws
    func pause() async
    func resume() async throws
    /// Returns the exact transition accepted by the runtime. The transport may
    /// move a request to a later legal boundary to preserve its scheduling lead.
    func queue(_ transition: QueuedTransition) async throws -> QueuedTransition
    func playOutroAndStop() async throws
    func stopImmediately() async
    func currentTransportFrame() async -> Int64
    func rebuildAfterConfigurationChange() async throws
}
