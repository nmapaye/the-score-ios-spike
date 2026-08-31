import Foundation
import ScoreCore

actor SessionSummaryStore: SessionSummaryPersisting {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = baseURL
            .appendingPathComponent("ScorePrototype", isDirectory: true)
            .appendingPathComponent("session-summaries.json", isDirectory: false)
    }

    func append(
        packID: String,
        date: Date,
        duration: TimeInterval,
        adaptationMode: PresentedAdaptationMode
    ) async throws {
        var summaries = try readExistingSummaries()
        summaries.append(
            SessionSummary(
                packID: packID,
                duration: max(0, duration),
                date: date,
                adaptationMode: adaptationMode == .automatic ? .automatic : .manual
            )
        )

        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectoryURL = directoryURL
        try? mutableDirectoryURL.setResourceValues(resourceValues)

        let data = try encoder.encode(summaries)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func readExistingSummaries() throws -> [SessionSummary] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([SessionSummary].self, from: data)
    }
}
