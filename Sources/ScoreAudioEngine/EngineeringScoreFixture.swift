import Foundation
import ScoreCore

public struct LoadedScorePack: Sendable {
    public var pack: ScorePack
    public var resourceRoot: URL

    public init(pack: ScorePack, resourceRoot: URL) {
        self.pack = pack
        self.resourceRoot = resourceRoot
    }
}

public enum EngineeringScoreFixture {
    public static func load() throws -> LoadedScorePack {
        guard let manifestURL = bundledManifestURL() else {
            throw ScoreAudioEngineError.missingResource("EngineeringScore/pack.json")
        }
        return try load(manifestURL: manifestURL)
    }

    public static func load(manifestURL: URL) throws -> LoadedScorePack {
        do {
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let pack = try decoder.decode(ScorePack.self, from: data)
            let root = manifestURL.deletingLastPathComponent()
            let availableResources = Set(
                try FileManager.default.subpathsOfDirectory(atPath: root.path)
            )
            let issues = ScorePackValidator.validate(
                pack,
                availableResourceNames: availableResources
            )
            guard issues.isEmpty else {
                throw ScoreAudioEngineError.invalidPack(
                    issues.map { "\($0.path): \($0.message)" }
                )
            }
            _ = try AudioAssetInspector.inspect(
                pack: pack,
                resourceRoot: root,
                verifyHashes: true
            )
            return LoadedScorePack(pack: pack, resourceRoot: root)
        } catch let error as ScoreAudioEngineError {
            throw error
        } catch {
            throw ScoreAudioEngineError.unreadableManifest(error.localizedDescription)
        }
    }

    private static func bundledManifestURL() -> URL? {
        if let nested = Bundle.module.url(
            forResource: "pack",
            withExtension: "json",
            subdirectory: "EngineeringScore"
        ) {
            return nested
        }
        return Bundle.module.url(forResource: "pack", withExtension: "json")
    }
}
