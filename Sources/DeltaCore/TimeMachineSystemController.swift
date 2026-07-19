import Foundation

public enum TimeMachineSystemControllerError: Error, Equatable, LocalizedError {
    case invalidDestinationIdentifier
    case commandFailed(exitCode: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidDestinationIdentifier:
            return "macOS did not provide a valid Time Machine destination identifier. Disconnect and reconnect this disk."
        case let .commandFailed(exitCode, message):
            return message.isEmpty
                ? "Time Machine did not accept the request (exit \(exitCode))."
                : "Time Machine did not accept the request: \(message)"
        }
    }
}

public struct TimeMachineSystemController: Sendable {
    public var runner: any TimeMachineBinaryProcessRunning

    public init(
        runner: any TimeMachineBinaryProcessRunning = TimeMachineBinaryProcessRunner()
    ) {
        self.runner = runner
    }

    public func startBackup(destinationIdentifier: String) throws {
        guard UUID(uuidString: destinationIdentifier) != nil else {
            throw TimeMachineSystemControllerError.invalidDestinationIdentifier
        }
        let result = try runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/tmutil"),
            arguments: [
                "startbackup",
                "--auto",
                "--destination",
                destinationIdentifier
            ],
            environment: Self.environment,
            standardInput: nil,
            maximumOutputBytes: 1_048_576,
            maximumRuntime: 60
        )
        guard result.exitCode == 0 else {
            throw TimeMachineSystemControllerError.commandFailed(
                exitCode: result.exitCode,
                message: SensitiveLogRedactor.redact(result.standardError)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static let environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": NSHomeDirectory(),
        "TMPDIR": NSTemporaryDirectory()
    ]
}
