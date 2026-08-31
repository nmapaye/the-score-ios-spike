import Darwin
import Foundation
import ScoreAudioEngine
import ScoreCore

private enum ScoreLab {
    static func main() {
        do {
            try run()
        } catch {
            let message = "ScoreLab error: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printUsage()
            return
        }

        switch command {
        case "validate-pack":
            let loaded = try loadPack(manifestArgument: arguments.dropFirst().first)
            let inspections = try AudioAssetInspector.inspect(
                pack: loaded.pack,
                resourceRoot: loaded.resourceRoot
            )
            print("VALID\t\(loaded.pack.id)\t\(inspections.count) assets")
            for inspection in inspections.sorted(by: { $0.resourceName < $1.resourceName }) {
                print(
                    "ASSET\t\(inspection.resourceName)\t\(inspection.frameCount) frames"
                        + "\t\(Int(inspection.sampleRate)) Hz\t\(inspection.sha256)"
                )
            }
        case "simulate":
            guard arguments.count >= 2 else {
                throw LabError.missingArgument("simulate requires a trace JSON path")
            }
            let manifest = arguments.count >= 3 ? arguments[2] : nil
            let loaded = try loadPack(manifestArgument: manifest)
            try simulate(traceURL: URL(fileURLWithPath: arguments[1]), loaded: loaded)
        case "offline-render":
            let seconds = arguments.count >= 2 ? TimeInterval(arguments[1]) : 10
            guard let seconds, seconds > 0 else {
                throw LabError.invalidDuration
            }
            let manifest = arguments.count >= 3 ? arguments[2] : nil
            let loaded = try loadPack(manifestArgument: manifest)
            let report = try OfflineRenderVerifier.render(
                pack: loaded.pack,
                resourceRoot: loaded.resourceRoot,
                duration: seconds
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        case "fixture-path":
            let fixture = try EngineeringScoreFixture.load()
            print(fixture.resourceRoot.path)
        case "self-test":
            let report = try ScoreLabSelfTest.run()
            print("PASS\t\(report.passedCount) compiled checks")
            for name in report.passedChecks {
                print("CHECK\t\(name)")
            }
        case "help", "--help", "-h":
            printUsage()
        default:
            throw LabError.unknownCommand(command)
        }
    }

    private static func loadPack(manifestArgument: String?) throws -> LoadedScorePack {
        if let manifestArgument {
            return try EngineeringScoreFixture.load(
                manifestURL: URL(fileURLWithPath: manifestArgument)
            )
        }
        return try EngineeringScoreFixture.load()
    }

    private static func simulate(traceURL: URL, loaded: LoadedScorePack) throws {
        let result = try MotionTraceRunner.run(traceURL: traceURL, pack: loaded.pack)
        print("TRACE\t\(result.name)\tPASS\t\(result.events.count) assertions")
        print("seconds\tcommand\tcurrent\trequested\tmode\tstale\tqueued\texecuteFrame")
        for eventResult in result.events {
            let event = eventResult.event
            let state = eventResult.state
            let queuedTarget: String
            switch state.queuedTransition?.target {
            case let .energy(energy):
                queuedTarget = "energy:\(energy.rawValue)"
            case let .section(sectionID):
                queuedTarget = "section:\(sectionID)"
            case nil:
                queuedTarget = "-"
            }
            let executeFrame = state.queuedTransition.map {
                String($0.executeAtFrame)
            } ?? "-"
            print(
                "\(event.atSeconds)\t\(event.command.rawValue)\t\(state.currentEnergy.rawValue)"
                    + "\t\(state.requestedEnergy.rawValue)\t\(state.adaptationMode.rawValue)"
                    + "\t\(state.inputIsStale)\t\(queuedTarget)\t\(executeFrame)"
            )
        }
    }

    private static func printUsage() {
        print(
            """
            ScoreLab commands:
              ScoreLab validate-pack [manifest.json]
              ScoreLab simulate <trace.json> [manifest.json]
              ScoreLab offline-render [seconds] [manifest.json]
              ScoreLab fixture-path
              ScoreLab self-test
            """
        )
    }
}

private enum LabError: Error, LocalizedError {
    case missingArgument(String)
    case invalidDuration
    case unknownCommand(String)

    var errorDescription: String? {
        switch self {
        case let .missingArgument(message):
            return message
        case .invalidDuration:
            return "The offline render duration must be a positive number of seconds."
        case let .unknownCommand(command):
            return "Unknown ScoreLab command: \(command)"
        }
    }
}

ScoreLab.main()
