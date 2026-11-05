import ActorTransitionRehearsal
import Foundation
import Glibc

@main
struct CLI {
    @MainActor
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            var bytes = 0
            guard arguments.count <= 16 else { throw LabError.invalidArguments }
            for argument in arguments {
                let next = bytes.addingReportingOverflow(argument.utf8.count)
                guard !next.overflow, next.partialValue <= 262144 else { throw LabError.invalidArguments }
                bytes = next.partialValue
            }
            if arguments == ["--version"] {
                try output("Actor Transition Rehearsal 0.1.0 (development)\n")
                return
            }
            if arguments == ["--help"] {
                try output("Usage: actor-transition-rehearsal [--assert] [--json] [--language en|pt-BR]\nAll eight offline scenarios always assert their receipts. No stdin is read.\n")
                return
            }
            var json = false
            var language = "en"
            var seen: Set<String> = []
            var index = 0
            while index < arguments.count {
                let flag = arguments[index]
                guard seen.insert(flag).inserted else { throw LabError.invalidArguments }
                switch flag {
                case "--assert": break
                case "--json": json = true
                case "--language":
                    index += 1
                    guard index < arguments.count, ["en", "pt-BR"].contains(arguments[index]) else {
                        throw LabError.invalidArguments
                    }
                    language = arguments[index]
                default: throw LabError.invalidArguments
                }
                index += 1
            }
            let report = try await Rehearsals.runAll()
            if json {
                var data = try report.canonicalJSON()
                data.append(10)
                try FileHandle.standardOutput.write(contentsOf: data)
            } else {
                let development = language == "en" ? "development" : "desenvolvimento"
                let pass = language == "en" ? "PASS" : "OK"
                let reservations = language == "en" ? "reservations" : "reservas"
                var text = "Actor Transition Rehearsal 0.1.0 (\(development))\n"
                for scenario in report.scenarios {
                    let outcomes = scenario.snapshot.operations.compactMap { $0.receipt?.outcome.rawValue }.joined(separator: ",")
                    text += "\(pass) \(scenario.name): \(outcomes); \(reservations)=\(scenario.snapshot.reservedCapacity)\n"
                }
                try output(text)
            }
        } catch {
            let code = (error as? LabError)?.rawValue ?? "ioOrEncodingFailure"
            try? FileHandle.standardError.write(contentsOf: Data("error: \(code)\n".utf8))
            exit(1)
        }
    }
    private static func output(_ text: String) throws {
        try FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
    }
}
