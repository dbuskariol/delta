import Foundation

public struct ResticCommand: Equatable, Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var environment: [String: String]

    public init(executableURL: URL, arguments: [String], environment: [String: String] = [:]) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
    }

    public var redactedDescription: String {
        var redacted = [ShellEscaper.singleQuoted(executableURL.path)]
        var shouldRedactNextArgument = false
        for argument in arguments {
            if shouldRedactNextArgument {
                redacted.append("<redacted>")
                shouldRedactNextArgument = false
                continue
            }

            if Self.sensitiveOptionsRequiringValueRedaction.contains(argument) {
                redacted.append(ShellEscaper.singleQuoted(argument))
                shouldRedactNextArgument = true
                continue
            }

            if Self.sensitiveInlineOptionPrefixes.contains(where: { argument.hasPrefix($0) }) {
                redacted.append("<redacted>")
                continue
            }

            redacted.append(ShellEscaper.singleQuoted(argument))
        }
        return redacted.joined(separator: " ")
    }

    private static let sensitiveOptionsRequiringValueRedaction: Set<String> = [
        "--password-command",
        "--password-file"
    ]

    private static let sensitiveInlineOptionPrefixes = [
        "--password-command=",
        "--password-file="
    ]
}

public enum ResticCommandValidationError: Error, Equatable, LocalizedError {
    case missingSnapshotID
    case missingRestoreTarget
    case invalidRestorePath(String)
    case invalidSnapshotBrowsePath(String)

    public var errorDescription: String? {
        switch self {
        case .missingSnapshotID:
            return "Choose a restore point before starting restore."
        case .missingRestoreTarget:
            return "Choose a destination folder or restore to original paths before starting restore."
        case let .invalidRestorePath(path):
            return "Restore path must be an absolute path inside the restore point: \(path)"
        case let .invalidSnapshotBrowsePath(path):
            return "Folder browser path must be an absolute path inside the restore point: \(path)"
        }
    }
}

public struct ResticExecutableLocator: Sendable {
    public var bundledExecutableName: String
    public var fallbackExecutableName: String

    public init(bundledExecutableName: String = "restic", fallbackExecutableName: String = "restic") {
        self.bundledExecutableName = bundledExecutableName
        self.fallbackExecutableName = fallbackExecutableName
    }

    public func locate(in bundle: Bundle = .main) -> URL {
        if let bundled = bundle.url(forAuxiliaryExecutable: bundledExecutableName) {
            return bundled
        }
        if let resource = bundle.url(forResource: bundledExecutableName, withExtension: nil) {
            return resource
        }
        if let executablePath = CommandLine.arguments.first {
            let sibling = URL(fileURLWithPath: executablePath)
                .deletingLastPathComponent()
                .appendingPathComponent(bundledExecutableName)
            if FileManager.default.isExecutableFile(atPath: sibling.path) {
                return sibling
            }
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    public func fallbackArguments(for command: ResticCommand) -> [String] {
        if command.executableURL.path == "/usr/bin/env" {
            return [fallbackExecutableName] + command.arguments
        }
        return command.arguments
    }
}

public struct ResticCommandBuilder: Sendable {
    public var resticExecutableURL: URL
    public var secretBridgeURL: URL
    public var backendURLBuilder: ResticBackendURLBuilder
    public var credentialResolver: RepositoryCredentialResolver
    public var baseEnvironment: [String: String]

    public init(
        resticExecutableURL: URL,
        secretBridgeURL: URL,
        backendURLBuilder: ResticBackendURLBuilder = ResticBackendURLBuilder(),
        credentialResolver: RepositoryCredentialResolver = RepositoryCredentialResolver(),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.resticExecutableURL = resticExecutableURL
        self.secretBridgeURL = secretBridgeURL
        self.backendURLBuilder = backendURLBuilder
        self.credentialResolver = credentialResolver
        self.baseEnvironment = baseEnvironment
    }

    public func initializeRepository(repository: BackupRepository) throws -> ResticCommand {
        try command(
            repository: repository,
            extraGlobalArguments: ["--json"],
            subcommand: ["init"]
        )
    }

    public func backup(profile: BackupProfile, repository: BackupRepository) throws -> ResticCommand {
        let sources = profile.sources.map(\.path)
        var subcommand = [
            "backup",
            "--json",
            "--compression", "auto",
            "--skip-if-unchanged",
            "--tag", "delta",
            "--tag", "profile:\(profile.id.uuidString)"
        ]

        if profile.sourceMode == .fullVolume || profile.sources.contains(where: { !$0.includeSubvolumes }) {
            subcommand.append("--one-file-system")
        }

        for pattern in BackupExcludePolicy.excludes(for: profile, repository: repository) {
            subcommand += ["--exclude", pattern]
        }

        subcommand += sources

        return try command(
            repository: repository,
            extraGlobalArguments: bandwidthArguments(from: profile.schedule),
            subcommand: subcommand
        )
    }

    public func snapshots(repository: BackupRepository) throws -> ResticCommand {
        try command(repository: repository, subcommand: ["snapshots", "--json"])
    }

    public func listSnapshotEntries(repository: BackupRepository, snapshotID: String, directoryPath: String? = nil) throws -> ResticCommand {
        let snapshotID = snapshotID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snapshotID.isEmpty else {
            throw ResticCommandValidationError.missingSnapshotID
        }

        var subcommand = ["ls", "--json", "--sort", "name", snapshotID]
        if let directoryPath = try Self.normalizedSnapshotBrowsePath(directoryPath) {
            subcommand.append(directoryPath)
        }
        return try command(repository: repository, subcommand: subcommand)
    }

    public func restore(request: RestoreRequest, repository: BackupRepository) throws -> ResticCommand {
        let snapshotID = request.snapshotID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snapshotID.isEmpty else {
            throw ResticCommandValidationError.missingSnapshotID
        }

        var snapshotArgument = snapshotID
        var subcommand = [
            "restore",
            "--json",
            "--overwrite", request.conflictPolicy.resticValue
        ]

        switch request.scope {
        case .fullSnapshot:
            break
        case let .selectedPaths(paths):
            let normalizedPaths = try Self.normalizedRestorePaths(paths)
            if normalizedPaths.count == 1, let first = normalizedPaths.first {
                snapshotArgument = "\(snapshotID):\(first)"
            } else {
                for path in normalizedPaths {
                    subcommand += ["--include", path]
                }
            }
        }

        if request.verifyRestoredFiles {
            subcommand.append("--verify")
        }
        if request.dryRun {
            subcommand.append("--dry-run")
            subcommand.append("--verbose=2")
        }

        switch request.destination {
        case let .chosenFolder(path):
            let target = Self.normalizedRestoreTarget(path)
            guard !target.isEmpty else {
                throw ResticCommandValidationError.missingRestoreTarget
            }
            subcommand += ["--target", target]
        case .originalPaths:
            subcommand += ["--target", "/"]
        }

        subcommand.append(snapshotArgument)
        return try command(repository: repository, subcommand: subcommand)
    }

    public func forgetAndPrune(profile: BackupProfile, repository: BackupRepository) throws -> ResticCommand {
        var subcommand = ["forget"]
        let policy = profile.retention
        if policy.keepHourly > 0 { subcommand += ["--keep-hourly", "\(policy.keepHourly)"] }
        if policy.keepDaily > 0 { subcommand += ["--keep-daily", "\(policy.keepDaily)"] }
        if policy.keepWeekly > 0 { subcommand += ["--keep-weekly", "\(policy.keepWeekly)"] }
        if policy.keepMonthly > 0 { subcommand += ["--keep-monthly", "\(policy.keepMonthly)"] }
        if policy.keepYearly > 0 { subcommand += ["--keep-yearly", "\(policy.keepYearly)"] }
        subcommand += ["--group-by", "host,paths,tags"]
        if policy.pruneAfterForget {
            subcommand.append("--prune")
        }
        return try command(repository: repository, extraGlobalArguments: ["--json"], subcommand: subcommand)
    }

    public func check(repository: BackupRepository, readDataSubset: String? = nil) throws -> ResticCommand {
        var subcommand = ["check", "--json"]
        if let readDataSubset, !readDataSubset.isEmpty {
            subcommand += ["--read-data-subset", readDataSubset]
        }
        return try command(repository: repository, subcommand: subcommand)
    }

    private func command(
        repository: BackupRepository,
        extraGlobalArguments: [String] = [],
        subcommand: [String]
    ) throws -> ResticCommand {
        let repositoryURL = try backendURLBuilder.repositoryURL(for: repository.backend)
        let passwordCommand = [
            ShellEscaper.singleQuoted(secretBridgeURL.path),
            ShellEscaper.singleQuoted(repository.keychainAccount)
        ].joined(separator: " ")

        var globalArguments = [
            "-r", repositoryURL,
            "--password-command", passwordCommand,
            "--cleanup-cache"
        ]
        globalArguments += backendOptionArguments(for: repository)
        globalArguments += extraGlobalArguments

        let toolDirectory = resticExecutableURL.deletingLastPathComponent().path
        var environment = resticEnvironment(toolDirectory: toolDirectory)
        try credentialResolver.environment(for: repository).forEach { key, value in
            environment[key] = value
        }

        return ResticCommand(
            executableURL: resticExecutableURL,
            arguments: globalArguments + subcommand,
            environment: environment
        )
    }

    private func bandwidthArguments(from schedule: BackupSchedule) -> [String] {
        var arguments: [String] = []
        if let uploadLimitKiB = schedule.uploadLimitKiB, uploadLimitKiB > 0 {
            arguments += ["--limit-upload", "\(uploadLimitKiB)"]
        }
        if let downloadLimitKiB = schedule.downloadLimitKiB, downloadLimitKiB > 0 {
            arguments += ["--limit-download", "\(downloadLimitKiB)"]
        }
        return arguments
    }

    private static func normalizedRestoreTarget(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        return (trimmed as NSString).expandingTildeInPath
    }

    private static func normalizedRestorePaths(_ paths: [String]) throws -> [String] {
        var normalized = Set<String>()
        for path in paths {
            let normalizedPath = normalizedRestorePath(path)
            guard !normalizedPath.isEmpty else {
                continue
            }
            guard normalizedPath.hasPrefix("/") else {
                throw ResticCommandValidationError.invalidRestorePath(path)
            }
            normalized.insert(normalizedPath)
        }

        return normalized
            .filter { path in
                !normalized.contains { candidate in
                    candidate != path && path.hasPrefix(candidate == "/" ? "/" : "\(candidate)/")
                }
            }
            .sorted()
    }

    private static func normalizedRestorePath(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func normalizedSnapshotBrowsePath(_ path: String?) throws -> String? {
        guard let path else {
            return nil
        }
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard trimmed.hasPrefix("/") else {
            throw ResticCommandValidationError.invalidSnapshotBrowsePath(path)
        }
        return trimmed
    }

    private func backendOptionArguments(for repository: BackupRepository) -> [String] {
        switch repository.backend {
        case let .sftp(_, _, _, _, identityFilePath):
            return sftpBackendOptionArguments(identityFilePath: identityFilePath)
        case let .s3(_, _, _, region):
            guard let region = region?.trimmingCharacters(in: .whitespacesAndNewlines), !region.isEmpty else {
                return []
            }
            return ["-o", "s3.region=\(region)"]
        case .rclone:
            let rcloneURL = resticExecutableURL.deletingLastPathComponent().appendingPathComponent("rclone")
            guard FileManager.default.isExecutableFile(atPath: rcloneURL.path) else {
                return []
            }
            return ["-o", "rclone.program=\(rcloneURL.path)"]
        default:
            return []
        }
    }

    private func sftpBackendOptionArguments(identityFilePath: String?) -> [String] {
        var arguments = [
            "-o", "BatchMode=yes",
            "-o", "ServerAliveInterval=60",
            "-o", "ServerAliveCountMax=240"
        ]

        if let identityFilePath = normalizedLocalPath(identityFilePath) {
            arguments += [
                "-i", identityFilePath,
                "-o", "IdentitiesOnly=yes"
            ]
        }

        return ["-o", "sftp.args=\(shellWords(arguments))"]
    }

    private func normalizedLocalPath(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return (path as NSString).expandingTildeInPath
    }

    private func shellWords(_ arguments: [String]) -> String {
        arguments.map { argument in
            if argument.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || argument.contains("'") {
                return ShellEscaper.singleQuoted(argument)
            }
            return argument
        }
        .joined(separator: " ")
    }

    private func resticEnvironment(toolDirectory: String) -> [String: String] {
        let existingPath = baseEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var environment: [String: String] = [
            "PATH": "\(toolDirectory):\(existingPath)",
            "HOME": baseEnvironment["HOME"] ?? NSHomeDirectory(),
            "TMPDIR": baseEnvironment["TMPDIR"] ?? NSTemporaryDirectory(),
            "RESTIC_PROGRESS_FPS": "1"
        ]

        for key in Self.forwardedEnvironmentKeys {
            if let value = baseEnvironment[key], !value.isEmpty {
                environment[key] = value
            }
        }
        for (key, value) in baseEnvironment where key.hasPrefix("LC_") && !value.isEmpty {
            environment[key] = value
        }
        return environment
    }

    private static let forwardedEnvironmentKeys: Set<String> = [
        "LANG",
        "LOGNAME",
        "SHELL",
        "SSH_AUTH_SOCK",
        "USER"
    ]
}
