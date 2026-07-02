import Foundation

public enum DeltaAgentCommand: Equatable, Sendable {
    case runDueBackups
    case status
    case dryRun
}

public enum DeltaAgentArgumentError: Error, Equatable, LocalizedError {
    case unsupportedArguments([String])

    public var errorDescription: String? {
        switch self {
        case let .unsupportedArguments(arguments):
            return "unsupported \(arguments.count == 1 ? "argument" : "arguments") '\(arguments.joined(separator: " "))'."
        }
    }
}

public enum DeltaAgentInvocation {
    public static func command(arguments: [String]) throws -> DeltaAgentCommand {
        switch arguments {
        case []:
            return .runDueBackups
        case ["--status"]:
            return .status
        case ["--dry-run"]:
            return .dryRun
        default:
            throw DeltaAgentArgumentError.unsupportedArguments(arguments)
        }
    }
}
