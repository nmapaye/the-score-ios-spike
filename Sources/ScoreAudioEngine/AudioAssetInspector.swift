import AVFoundation
import CryptoKit
import Foundation
import ScoreCore

public struct AudioAssetInspection: Codable, Sendable, Equatable {
    public var resourceName: String
    public var sampleRate: Double
    public var channelCount: UInt32
    public var frameCount: Int64
    public var sha256: String

    public init(
        resourceName: String,
        sampleRate: Double,
        channelCount: UInt32,
        frameCount: Int64,
        sha256: String
    ) {
        self.resourceName = resourceName
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.sha256 = sha256
    }
}

public enum AudioAssetInspector {
    public static func inspect(
        pack: ScorePack,
        resourceRoot: URL,
        verifyHashes: Bool = true
    ) throws -> [AudioAssetInspection] {
        let assets = allAssets(in: pack)
        var inspections: [AudioAssetInspection] = []
        inspections.reserveCapacity(assets.count)
        var expectedSampleRate: Double?
        var expectedChannelCount: UInt32?
        var expectedCommonFormat: AVAudioCommonFormat?
        var expectedInterleaving: Bool?

        for asset in assets {
            let url = try resolvedURL(for: asset.resourceName, beneath: resourceRoot)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ScoreAudioEngineError.missingResource(asset.resourceName)
            }

            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard format.sampleRate == Double(pack.grid.sampleRate),
                  format.channelCount > 0 else {
                throw ScoreAudioEngineError.incompatibleAsset(asset.resourceName)
            }

            if let expectedSampleRate,
               let expectedChannelCount,
               let expectedCommonFormat,
               let expectedInterleaving {
                guard format.sampleRate == expectedSampleRate,
                      format.channelCount == expectedChannelCount,
                      format.commonFormat == expectedCommonFormat,
                      format.isInterleaved == expectedInterleaving else {
                    throw ScoreAudioEngineError.incompatibleAsset(asset.resourceName)
                }
            } else {
                expectedSampleRate = format.sampleRate
                expectedChannelCount = format.channelCount
                expectedCommonFormat = format.commonFormat
                expectedInterleaving = format.isInterleaved
            }

            let inspection = AudioAssetInspection(
                resourceName: asset.resourceName,
                sampleRate: format.sampleRate,
                channelCount: format.channelCount,
                frameCount: file.length,
                sha256: try sha256(of: url)
            )

            guard file.length == asset.exactFrameCount else {
                throw ScoreAudioEngineError.frameCountMismatch(
                    resource: asset.resourceName,
                    expected: asset.exactFrameCount,
                    actual: file.length
                )
            }
            if verifyHashes, let expectedHash = asset.sha256?.lowercased(),
               expectedHash != inspection.sha256 {
                throw ScoreAudioEngineError.integrityMismatch(resource: asset.resourceName)
            }

            inspections.append(inspection)
        }

        if verifyHashes, let expectedIntegrityHash = pack.integrityHash?.lowercased() {
            let canonicalAssetSet = inspections
                .sorted { $0.resourceName < $1.resourceName }
                .map { "\($0.resourceName):\($0.sha256)\n" }
                .joined()
            let actualIntegrityHash = sha256(of: Data(canonicalAssetSet.utf8))
            guard actualIntegrityHash == expectedIntegrityHash else {
                throw ScoreAudioEngineError.integrityMismatch(resource: "pack.integrityHash")
            }
        }

        return inspections
    }

    public static func resolvedURL(for resourceName: String, beneath root: URL) throws -> URL {
        let standardizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = standardizedRoot
            .appendingPathComponent(resourceName)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPrefix = standardizedRoot.path.hasSuffix("/")
            ? standardizedRoot.path
            : standardizedRoot.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else {
            throw ScoreAudioEngineError.resourceEscapesRoot(resourceName)
        }
        return candidate
    }

    private static func allAssets(in pack: ScorePack) -> [ScoreAsset] {
        var assets = pack.stems.map(\.asset)
        if let intro = pack.intro {
            assets.append(intro)
        }
        if let outro = pack.outro {
            assets.append(outro)
        }
        return assets
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return sha256(of: data)
    }

    private static func sha256(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
