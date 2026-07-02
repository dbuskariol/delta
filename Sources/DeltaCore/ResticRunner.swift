import Darwin
import Foundation

public enum ResticRunStopReason: String, Codable, Equatable, Sendable {
    case pause
    case cancel

    public var requestMessage: String {
        switch self {
        case .pause: "Pause requested. Stopping the current backup safely..."
        case .cancel: "Cancel requested. Stopping the current job safely..."
        }
    }

    public var userFacingMessage: String {
        switch self {
        case .pause: "Backup paused. Run it again to continue from already saved backup data."
        case .cancel: "Job cancelled. Any incomplete restic work is safe to retry on the next run."
        }
    }
}

public struct ResticRunResult: Equatable, Sendable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String
    public var status: JobStatus
    public var failureKind: ResticFailureKind?
    public var userFacingMessage: String

    public init(exitCode: Int32, standardOutput: String, standardError: String, stopReason: ResticRunStopReason? = nil) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        if let stopReason {
            self.status = .cancelled
            self.failureKind = .interrupted
            self.userFacingMessage = stopReason.userFacingMessage
        } else {
            self.status = ResticExitCodeMapper.status(for: exitCode, standardError: standardError)
            self.failureKind = ResticFailureClassifier.kind(exitCode: exitCode, standardOutput: standardOutput, standardError: standardError)
            self.userFacingMessage = ResticFailureClassifier.userFacingMessage(
                status: status,
                failureKind: failureKind,
                standardOutput: standardOutput,
                standardError: standardError
            )
        }
    }
}

public enum ResticOutputStream: String, Codable, Sendable {
    case standardOutput
    case standardError
}

public struct ResticOutputEvent: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var stream: ResticOutputStream
    public var message: String

    public init(id: UUID = UUID(), date: Date = Date(), stream: ResticOutputStream, message: String) {
        self.id = id
        self.date = date
        self.stream = stream
        self.message = message
    }
}

public enum ResticFailureKind: String, Codable, CaseIterable, Sendable {
    case repositoryMissing
    case lockedRepository
    case wrongPassword
    case missingBackendCredentials
    case networkUnavailable
    case unreadableSourceFiles
    case interrupted
    case unknown
}

public enum ResticExitCodeMapper {
    public static func status(for exitCode: Int32, standardError: String = "") -> JobStatus {
        switch exitCode {
        case 0:
            return .succeeded
        case 3:
            return .warning
        default:
            if standardError.localizedCaseInsensitiveContains("cancel")
                || standardError.localizedCaseInsensitiveContains("interrupt")
                || standardError.localizedCaseInsensitiveContains("signal: killed") {
                return .cancelled
            }
            return .failed
        }
    }
}

public enum ResticFailureClassifier {
    public static func kind(exitCode: Int32, standardOutput: String = "", standardError: String = "") -> ResticFailureKind? {
        guard exitCode != 0 else {
            return nil
        }

        switch exitCode {
        case 10:
            return .repositoryMissing
        case 11:
            return .lockedRepository
        case 12:
            return .wrongPassword
        default:
            break
        }

        let text = "\(standardOutput)\n\(standardError)"
        if containsAny(text, ["repository is already locked", "unable to create lock", "already locked"]) {
            return .lockedRepository
        }
        if containsAny(text, ["wrong password", "password is incorrect", "invalid password", "mac: authentication failed"]) {
            return .wrongPassword
        }
        if containsAny(text, ["nocredentialproviders", "no credentials", "missing credentials", "access key", "secret access key", "environment variable"]) {
            return .missingBackendCredentials
        }
        if containsAny(text, ["network is unreachable", "no route to host", "could not resolve", "connection refused", "connection reset", "timed out", "timeout"]) {
            return .networkUnavailable
        }
        if containsAny(text, ["permission denied", "operation not permitted", "failed to read", "unreadable"]) {
            return .unreadableSourceFiles
        }
        if containsAny(text, ["interrupt", "interrupted", "context canceled", "operation cancelled", "operation canceled", "signal: killed"]) {
            return .interrupted
        }
        return .unknown
    }

    public static func userFacingMessage(
        status: JobStatus,
        failureKind: ResticFailureKind?,
        standardOutput: String,
        standardError: String
    ) -> String {
        switch failureKind {
        case .repositoryMissing:
            return "The destination has not been prepared yet or cannot be found."
        case .lockedRepository:
            return "The destination is already in use by another backup or maintenance job. Try again after the current job finishes."
        case .wrongPassword:
            return "The encryption password for this destination is incorrect or unavailable."
        case .missingBackendCredentials:
            return "This destination is missing required sign-in credentials."
        case .networkUnavailable:
            return "The network destination is unavailable. Check the connection, server address, VPN, or mounted drive."
        case .unreadableSourceFiles:
            return status == .warning
                ? "Backup completed, but some files could not be read. Check Full Disk Access and source permissions."
                : "Some selected files could not be read. Check Full Disk Access and source permissions."
        case .interrupted:
            return "The job was interrupted. Delta can continue from existing backup data on the next run."
        case .unknown:
            let message = standardError.isEmpty ? standardOutput : standardError
            return message.isEmpty ? "The backup tool reported an unknown error." : message
        case .none:
            let message = standardError.isEmpty ? standardOutput : standardError
            return message.isEmpty ? status.rawValue.capitalized : message
        }
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.localizedCaseInsensitiveContains($0) }
    }
}

public protocol ResticRunning: Sendable {
    func run(_ command: ResticCommand) throws -> ResticRunResult
}

public protocol ResticStreamingRunning: ResticRunning {
    func run(_ command: ResticCommand, outputHandler: (@Sendable (ResticOutputEvent) -> Void)?) throws -> ResticRunResult
}

public protocol ResticControlledStreamingRunning: ResticStreamingRunning {
    func run(
        _ command: ResticCommand,
        outputHandler: (@Sendable (ResticOutputEvent) -> Void)?,
        stopReasonProvider: (@Sendable () -> ResticRunStopReason?)?
    ) throws -> ResticRunResult
}

public final class ResticRunController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopReason: ResticRunStopReason?

    public init() {}

    public var requestedStopReason: ResticRunStopReason? {
        lock.lock()
        defer { lock.unlock() }
        return stopReason
    }

    public func reset() {
        lock.lock()
        process = nil
        stopReason = nil
        lock.unlock()
    }

    public func attach(_ process: Process) {
        let reason: ResticRunStopReason?
        lock.lock()
        self.process = process
        reason = stopReason
        lock.unlock()
        if reason != nil {
            stop(process)
        }
    }

    public func detach(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    public func requestStop(_ reason: ResticRunStopReason) {
        let runningProcess: Process?
        lock.lock()
        if stopReason == nil {
            stopReason = reason
        }
        runningProcess = process
        lock.unlock()

        if let runningProcess {
            stop(runningProcess)
        }
    }

    private func stop(_ process: Process) {
        guard process.isRunning else {
            return
        }
        process.interrupt()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) { [weak process] in
            guard let process, process.isRunning else {
                return
            }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) { [weak process] in
                guard let process, process.isRunning else {
                    return
                }
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

public final class ResticRunner: ResticRunning, @unchecked Sendable {
    private let outputHandler: (@Sendable (ResticOutputEvent) -> Void)?
    private let runController: ResticRunController?

    public init(
        outputHandler: (@Sendable (ResticOutputEvent) -> Void)? = nil,
        runController: ResticRunController? = nil
    ) {
        self.outputHandler = outputHandler
        self.runController = runController
    }

    public func run(_ command: ResticCommand) throws -> ResticRunResult {
        try run(command, outputHandler: nil)
    }

    public func run(_ command: ResticCommand, outputHandler additionalOutputHandler: (@Sendable (ResticOutputEvent) -> Void)?) throws -> ResticRunResult {
        try run(command, outputHandler: additionalOutputHandler, stopReasonProvider: nil)
    }

    public func run(
        _ command: ResticCommand,
        outputHandler additionalOutputHandler: (@Sendable (ResticOutputEvent) -> Void)?,
        stopReasonProvider: (@Sendable () -> ResticRunStopReason?)?
    ) throws -> ResticRunResult {
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = normalizedArguments(for: command)
        process.environment = command.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let combinedOutputHandler: (@Sendable (ResticOutputEvent) -> Void)? = { [outputHandler] event in
            outputHandler?(event)
            additionalOutputHandler?(event)
        }
        let stdoutCollector = DataCollector()
        let stderrCollector = DataCollector()
        let stdoutLines = LineEmitter(stream: .standardOutput, outputHandler: combinedOutputHandler)
        let stderrLines = LineEmitter(stream: .standardError, outputHandler: combinedOutputHandler)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutCollector.append(data)
                stdoutLines.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrCollector.append(data)
                stderrLines.append(data)
            }
        }

        try process.run()
        let controller = runController ?? (stopReasonProvider == nil ? nil : ResticRunController())
        let stopMonitor = ResticStopRequestMonitor(
            controller: controller,
            stopReasonProvider: stopReasonProvider
        )
        controller?.attach(process)
        stopMonitor.start()
        process.waitUntilExit()
        stopMonitor.cancel()
        controller?.detach(process)

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutLines.flush()
        stderrLines.flush()

        return ResticRunResult(
            exitCode: process.terminationStatus,
            standardOutput: stdoutCollector.stringValue,
            standardError: stderrCollector.stringValue,
            stopReason: controller?.requestedStopReason
        )
    }

    private func normalizedArguments(for command: ResticCommand) -> [String] {
        if command.executableURL.path == "/usr/bin/env" {
            return ["restic"] + command.arguments
        }
        return command.arguments
    }
}

extension ResticRunner: ResticControlledStreamingRunning {}

private final class ResticStopRequestMonitor: @unchecked Sendable {
    private let controller: ResticRunController?
    private let stopReasonProvider: (@Sendable () -> ResticRunStopReason?)?
    private var timer: DispatchSourceTimer?

    init(
        controller: ResticRunController?,
        stopReasonProvider: (@Sendable () -> ResticRunStopReason?)?
    ) {
        self.controller = controller
        self.stopReasonProvider = stopReasonProvider
        guard controller != nil, stopReasonProvider != nil else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 0.25, repeating: 0.5)
        self.timer = timer
    }

    func start() {
        guard let timer else {
            return
        }
        timer.setEventHandler { [controller, stopReasonProvider] in
            guard
                controller?.requestedStopReason == nil,
                let reason = stopReasonProvider?()
            else {
                return
            }
            controller?.requestStop(reason)
        }
        timer.resume()
    }

    func cancel() {
        timer?.cancel()
        timer = nil
    }
}

private final class LineEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private let stream: ResticOutputStream
    private let outputHandler: (@Sendable (ResticOutputEvent) -> Void)?
    private var pending = ""

    init(stream: ResticOutputStream, outputHandler: (@Sendable (ResticOutputEvent) -> Void)?) {
        self.stream = stream
        self.outputHandler = outputHandler
    }

    func append(_ data: Data) {
        guard let string = String(data: data, encoding: .utf8), !string.isEmpty else {
            return
        }
        let lines = completeLines(afterAppending: string)
        emit(lines)
    }

    func flush() {
        let lines: [String]
        lock.lock()
        if pending.isEmpty {
            lines = []
        } else {
            lines = [pending]
            pending = ""
        }
        lock.unlock()
        emit(lines)
    }

    private func completeLines(afterAppending string: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending += string
        let parts = pending.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard pending.last?.isNewline == true else {
            pending = parts.last ?? ""
            return Array(parts.dropLast()).filter { !$0.isEmpty }
        }
        pending = ""
        return parts.filter { !$0.isEmpty }
    }

    private func emit(_ lines: [String]) {
        guard let outputHandler else {
            return
        }
        for line in lines {
            outputHandler(ResticOutputEvent(stream: stream, message: line))
        }
    }
}

private final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var stringValue: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }
}
