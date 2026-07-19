import Foundation

public enum TimeMachineRcloneError: Error, Equatable, LocalizedError {
    case unsupportedBackend(RepositoryBackendKind)
    case missingExecutable(String)
    case invalidObjectPath(String)
    case commandFailed(exitCode: Int32, message: String)
    case outputLimitExceeded(Int)
    case stagingMetadataLimitExceeded(requiredBytes: Int, limitBytes: Int)
    case invalidListResponse

    public var errorDescription: String? {
        switch self {
        case let .unsupportedBackend(kind):
            "\(kind.displayName) cannot be used as a Time Machine object store."
        case let .missingExecutable(path):
            "Delta's cloud transfer tool is missing or not executable at \(path)."
        case let .invalidObjectPath(path):
            "The Time Machine object path is invalid: \(path)."
        case let .commandFailed(exitCode, message):
            "The remote Time Machine operation failed (exit \(exitCode)): \(message)"
        case let .outputLimitExceeded(limit):
            "The remote Time Machine operation returned more than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) of data."
        case let .stagingMetadataLimitExceeded(requiredBytes, limitBytes):
            "Time Machine transport metadata needs \(ByteCountFormatter.string(fromByteCount: Int64(requiredBytes), countStyle: .file)), exceeding Delta's \(ByteCountFormatter.string(fromByteCount: Int64(limitBytes), countStyle: .file)) bounded staging allowance."
        case .invalidListResponse:
            "The remote Time Machine object listing was not valid."
        }
    }
}

public enum TimeMachineBinaryProcessError: Error, Equatable, LocalizedError {
    case timedOut(executable: String, seconds: Int)

    public var errorDescription: String? {
        switch self {
        case let .timedOut(executable, seconds):
            "\(executable) did not finish within \(seconds) seconds and was stopped."
        }
    }
}

public struct TimeMachineRcloneConfiguration: Equatable, Sendable {
    public var executableURL: URL
    public var remoteRoot: String
    public var environment: [String: String]
    public var stagingDirectoryURL: URL?

    public init(
        executableURL: URL,
        remoteRoot: String,
        environment: [String: String],
        stagingDirectoryURL: URL? = nil
    ) {
        self.executableURL = executableURL
        self.remoteRoot = remoteRoot
        self.environment = environment
        self.stagingDirectoryURL = stagingDirectoryURL
    }
}

public struct TimeMachineRcloneConfigurationBuilder: Sendable {
    public var rcloneExecutableURL: URL
    public var credentialResolver: RepositoryCredentialResolver
    public var baseEnvironment: [String: String]

    public init(
        rcloneExecutableURL: URL,
        credentialResolver: RepositoryCredentialResolver = RepositoryCredentialResolver(),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.rcloneExecutableURL = rcloneExecutableURL
        self.credentialResolver = credentialResolver
        self.baseEnvironment = baseEnvironment
    }

    public func configuration(for repository: BackupRepository) throws -> TimeMachineRcloneConfiguration {
        guard repository.format == .timeMachine else {
            throw TimeMachineRcloneError.unsupportedBackend(repository.backend.kind)
        }
        guard FileManager.default.isExecutableFile(atPath: rcloneExecutableURL.path) else {
            throw TimeMachineRcloneError.missingExecutable(rcloneExecutableURL.path)
        }
        var environment = curatedEnvironment()
        let credentials = try credentialResolver.environment(for: repository)
        credentials.forEach { environment[$0.key] = $0.value }

        let root: String
        switch repository.backend {
        case let .sftp(host, path, username, port, identityFilePath):
            environment["RCLONE_CONFIG_DELTA_TYPE"] = "sftp"
            environment["RCLONE_CONFIG_DELTA_HOST"] = host
            if let username { environment["RCLONE_CONFIG_DELTA_USER"] = username }
            if let port { environment["RCLONE_CONFIG_DELTA_PORT"] = String(port) }
            if let identityFilePath { environment["RCLONE_CONFIG_DELTA_KEY_FILE"] = identityFilePath }
            environment["RCLONE_CONFIG_DELTA_USE_INSECURE_CIPHER"] = "false"
            if let knownHosts = baseEnvironment["DELTA_SFTP_KNOWN_HOSTS_FILE"], !knownHosts.isEmpty {
                environment["RCLONE_CONFIG_DELTA_KNOWN_HOSTS_FILE"] = knownHosts
            }
            root = Self.remote(name: "delta", path: path)

        case let .s3(endpoint, bucket, path, region):
            environment["RCLONE_CONFIG_DELTA_TYPE"] = "s3"
            environment["RCLONE_CONFIG_DELTA_PROVIDER"] = endpoint == nil ? "AWS" : "Other"
            environment["RCLONE_CONFIG_DELTA_ENV_AUTH"] = "true"
            if let endpoint { environment["RCLONE_CONFIG_DELTA_ENDPOINT"] = endpoint }
            if let region { environment["RCLONE_CONFIG_DELTA_REGION"] = region }
            root = Self.remote(name: "delta", path: Self.join(bucket, path))

        case let .backblazeB2(bucket, path):
            environment["RCLONE_CONFIG_DELTA_TYPE"] = "b2"
            if let value = credentials["B2_ACCOUNT_ID"] {
                environment["RCLONE_CONFIG_DELTA_ACCOUNT"] = value
            }
            if let value = credentials["B2_ACCOUNT_KEY"] {
                environment["RCLONE_CONFIG_DELTA_KEY"] = value
            }
            root = Self.remote(name: "delta", path: Self.join(bucket, path))

        case let .azureBlob(container, path):
            environment["RCLONE_CONFIG_DELTA_TYPE"] = "azureblob"
            if let account = credentials["AZURE_ACCOUNT_NAME"] {
                environment["RCLONE_CONFIG_DELTA_ACCOUNT"] = account
            }
            if let key = credentials["AZURE_ACCOUNT_KEY"], !key.isEmpty {
                environment["RCLONE_CONFIG_DELTA_KEY"] = key
            } else if
                let account = credentials["AZURE_ACCOUNT_NAME"],
                let token = credentials["AZURE_ACCOUNT_SAS"],
                !token.isEmpty
            {
                let suffix = credentials["AZURE_ENDPOINT_SUFFIX"] ?? "core.windows.net"
                let query = token.hasPrefix("?") ? String(token.dropFirst()) : token
                environment["RCLONE_CONFIG_DELTA_SAS_URL"] = "https://\(account).blob.\(suffix)/\(container)?\(query)"
            } else {
                environment["RCLONE_CONFIG_DELTA_ENV_AUTH"] = "true"
            }
            root = Self.remote(name: "delta", path: Self.join(container, path))

        case let .googleCloudStorage(bucket, path):
            environment["RCLONE_CONFIG_DELTA_TYPE"] = "google cloud storage"
            environment["RCLONE_CONFIG_DELTA_ENV_AUTH"] = "true"
            if let project = credentials["GOOGLE_PROJECT_ID"] {
                environment["RCLONE_CONFIG_DELTA_PROJECT_NUMBER"] = project
            }
            if let file = credentials["GOOGLE_APPLICATION_CREDENTIALS"] {
                environment["RCLONE_CONFIG_DELTA_SERVICE_ACCOUNT_FILE"] = file
            }
            if let token = credentials["GOOGLE_ACCESS_TOKEN"] {
                environment["RCLONE_CONFIG_DELTA_ACCESS_TOKEN"] = token
            }
            root = Self.remote(name: "delta", path: Self.join(bucket, path))

        case let .swiftObjectStorage(container, path):
            environment["RCLONE_CONFIG_DELTA_TYPE"] = "swift"
            environment["RCLONE_CONFIG_DELTA_ENV_AUTH"] = "true"
            root = Self.remote(name: "delta", path: Self.join(container, path))

        case let .rclone(remote, path):
            root = Self.remote(name: remote, path: path)

        case .local, .rest, .custom:
            throw TimeMachineRcloneError.unsupportedBackend(repository.backend.kind)
        }

        return TimeMachineRcloneConfiguration(
            executableURL: rcloneExecutableURL,
            remoteRoot: root,
            environment: environment,
            stagingDirectoryURL: try TimeMachineRuntimePaths.repositoryDirectory(
                repositoryID: repository.id
            ).appendingPathComponent("transport-staging", isDirectory: true)
        )
    }

    private func curatedEnvironment() -> [String: String] {
        let toolDirectory = rcloneExecutableURL.deletingLastPathComponent().path
        let inheritedPath = baseEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var environment = [
            "PATH": "\(toolDirectory):\(inheritedPath)",
            "HOME": baseEnvironment["HOME"] ?? NSHomeDirectory(),
            "TMPDIR": baseEnvironment["TMPDIR"] ?? NSTemporaryDirectory()
        ]
        for key in ["LANG", "LOGNAME", "SSH_AUTH_SOCK", "USER"] {
            if let value = baseEnvironment[key], !value.isEmpty {
                environment[key] = value
            }
        }
        for (key, value) in baseEnvironment where key.hasPrefix("LC_") && !value.isEmpty {
            environment[key] = value
        }
        return environment
    }

    private static func remote(name: String, path: String) -> String {
        "\(name):\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
    }

    private static func join(_ first: String, _ second: String?) -> String {
        [first, second]
            .compactMap { $0?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }
}

public protocol TimeMachineBinaryProcessRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        maximumOutputBytes: Int,
        maximumRuntime: TimeInterval
    ) throws -> TimeMachineBinaryProcessResult

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        maximumOutputBytes: Int,
        maximumRuntime: TimeInterval,
        reusingStandardOutput: inout Data
    ) throws -> TimeMachineBinaryProcessResult
}

public extension TimeMachineBinaryProcessRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        maximumOutputBytes: Int,
        maximumRuntime: TimeInterval,
        reusingStandardOutput: inout Data
    ) throws -> TimeMachineBinaryProcessResult {
        let result = try run(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            standardInput: standardInput,
            maximumOutputBytes: maximumOutputBytes,
            maximumRuntime: maximumRuntime
        )
        reusingStandardOutput = result.standardOutput
        return result
    }
}

public struct TimeMachineBinaryProcessResult: Equatable, Sendable {
    public var exitCode: Int32
    public var standardOutput: Data
    public var standardError: String

    public init(exitCode: Int32, standardOutput: Data, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public final class TimeMachineBinaryProcessRunner: TimeMachineBinaryProcessRunning, @unchecked Sendable {
    private let terminationGracePeriod: TimeInterval

    public init(terminationGracePeriod: TimeInterval = 2) {
        self.terminationGracePeriod = max(terminationGracePeriod, 0.01)
    }

    public func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        maximumOutputBytes: Int,
        maximumRuntime: TimeInterval
    ) throws -> TimeMachineBinaryProcessResult {
        let output = TimeMachinePipeCapture(limit: maximumOutputBytes)
        return try run(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            standardInput: standardInput,
            maximumOutputBytes: maximumOutputBytes,
            maximumRuntime: maximumRuntime,
            output: output
        )
    }

    public func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        maximumOutputBytes: Int,
        maximumRuntime: TimeInterval,
        reusingStandardOutput: inout Data
    ) throws -> TimeMachineBinaryProcessResult {
        let output = TimeMachinePipeCapture(
            limit: maximumOutputBytes,
            reusing: &reusingStandardOutput
        )
        let result = try run(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            standardInput: standardInput,
            maximumOutputBytes: maximumOutputBytes,
            maximumRuntime: maximumRuntime,
            output: output
        )
        reusingStandardOutput = result.standardOutput
        return result
    }

    private func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        maximumOutputBytes: Int,
        maximumRuntime: TimeInterval,
        output: TimeMachinePipeCapture
    ) throws -> TimeMachineBinaryProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = standardInput == nil ? nil : Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe

        let errorOutput = TimeMachinePipeCapture(limit: 1_048_576, keepsTail: true)
        output.start(reading: outputPipe.fileHandleForReading)
        errorOutput.start(reading: errorPipe.fileHandleForReading)
        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }
        let inputWrite = DispatchGroup()

        do {
            try process.run()
            if let standardInput, let inputPipe {
                inputWrite.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer {
                        try? inputPipe.fileHandleForWriting.close()
                        inputWrite.leave()
                    }
                    try? inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
                }
            }
        } catch {
            try? inputPipe?.fileHandleForWriting.close()
            output.stop(reading: outputPipe.fileHandleForReading, waitForEnd: false)
            errorOutput.stop(reading: errorPipe.fileHandleForReading, waitForEnd: false)
            throw error
        }

        let runtime = max(maximumRuntime, 0.01)
        let didTimeOut = termination.wait(timeout: .now() + runtime) == .timedOut
        if didTimeOut, process.isRunning {
            process.terminate()
            if termination.wait(timeout: .now() + terminationGracePeriod) == .timedOut,
               process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(timeout: .now() + terminationGracePeriod)
            }
        }
        if inputWrite.wait(timeout: .now() + terminationGracePeriod) == .timedOut {
            try? inputPipe?.fileHandleForWriting.close()
            _ = inputWrite.wait(timeout: .now() + terminationGracePeriod)
        }
        output.stop(reading: outputPipe.fileHandleForReading, waitForEnd: true)
        errorOutput.stop(reading: errorPipe.fileHandleForReading, waitForEnd: true)

        if didTimeOut {
            throw TimeMachineBinaryProcessError.timedOut(
                executable: executableURL.lastPathComponent,
                seconds: max(1, Int(runtime.rounded(.up)))
            )
        }

        guard !output.didExceedLimit else {
            throw TimeMachineRcloneError.outputLimitExceeded(maximumOutputBytes)
        }
        let standardOutput = output.takeValue()
        return TimeMachineBinaryProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: standardOutput,
            standardError: String(decoding: errorOutput.value, as: UTF8.self)
        )
    }
}

public struct TimeMachineRcloneObjectTransport: TimeMachineRemoteObjectTransport, Sendable {
    private struct ListItem: Decodable {
        var path: String
        var size: Int64
        var isDir: Bool

        enum CodingKeys: String, CodingKey {
            case path = "Path"
            case size = "Size"
            case isDir = "IsDir"
        }
    }

    public var configuration: TimeMachineRcloneConfiguration
    public var runner: any TimeMachineBinaryProcessRunning

    public init(
        configuration: TimeMachineRcloneConfiguration,
        runner: any TimeMachineBinaryProcessRunning = TimeMachineBinaryProcessRunner()
    ) {
        self.configuration = configuration
        self.runner = runner
    }

    public func readObject(at path: String) throws -> Data {
        var result = Data()
        try readObject(at: path, into: &result)
        return result
    }

    public func readObject(at path: String, into buffer: inout Data) throws {
        let path = try Self.validated(path)
        // A production content object is one native 8 MiB sparsebundle band.
        // Exact-size output is accepted; one additional byte fails closed.
        let result = try command(
            ["cat", remotePath(path)],
            maximumOutputBytes: TimeMachineRepositorySettings.chunkSizeBytes,
            reusingOutput: &buffer
        )
        guard result.exitCode == 0 else {
            if Self.isMissing(result.standardError) {
                throw TimeMachineObjectStoreError.objectNotFound(path)
            }
            throw Self.commandError(result)
        }
        buffer = result.standardOutput
    }

    public func readObjects(at paths: [String]) throws -> [String: Data] {
        guard !paths.isEmpty else { return [:] }
        let validatedPaths = try paths.map { try Self.validated($0) }
        guard Set(validatedPaths).count == validatedPaths.count else {
            throw TimeMachineRcloneError.invalidObjectPath("duplicate batch path")
        }
        let stagingRoot = try makeReadStagingRoot()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let fileList = Data((validatedPaths.joined(separator: "\n") + "\n").utf8)
        let result = try command(
            [
                "copy", "--files-from-raw", "-", "--no-traverse",
                "--transfers", "4", "--checkers", "8",
                "--max-transfer", "64Mi", "--cutoff-mode", "HARD",
                configuration.remoteRoot, stagingRoot.path
            ],
            input: fileList,
            maximumOutputBytes: 1_048_576
        )
        guard result.exitCode == 0 else {
            if Self.isMissing(result.standardError) {
                throw TimeMachineObjectStoreError.objectNotFound(validatedPaths[0])
            }
            throw Self.commandError(result)
        }
        return try Dictionary(uniqueKeysWithValues: validatedPaths.map { path in
            let url = path.split(separator: "/").reduce(stagingRoot) {
                $0.appendingPathComponent(String($1), isDirectory: false)
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw TimeMachineObjectStoreError.objectNotFound(path)
            }
            return (path, try TimeMachineBoundedRegularFile.read(at: url))
        })
    }

    public func writeObjectIfAbsent(_ data: Data, at path: String) throws {
        guard data.count <= TimeMachineRepositorySettings.chunkSizeBytes else {
            throw TimeMachineObjectStoreError.objectSizeLimitExceeded(
                TimeMachineRepositorySettings.chunkSizeBytes
            )
        }
        let path = try Self.validated(path)
        let result = try command(
            ["rcat", "--immutable", "--size", String(data.count), remotePath(path)],
            input: data,
            maximumOutputBytes: 65_536
        )
        guard result.exitCode == 0 else {
            if result.standardError.localizedCaseInsensitiveContains("immutable")
                || result.standardError.localizedCaseInsensitiveContains("already exists") {
                throw TimeMachineObjectStoreError.objectAlreadyExists(path)
            }
            throw Self.commandError(result)
        }
    }

    public func writeObjectsIfAbsent(_ objects: [TimeMachineRemoteObjectWrite]) throws {
        guard !objects.isEmpty else { return }
        let validatedObjects = try objects.map { object in
            guard try object.payload.byteCount() <= TimeMachineRepositorySettings.chunkSizeBytes else {
                throw TimeMachineObjectStoreError.objectSizeLimitExceeded(
                    TimeMachineRepositorySettings.chunkSizeBytes
                )
            }
            return TimeMachineRemoteObjectWrite(
                path: try Self.validated(object.path),
                payload: object.payload
            )
        }
        guard Set(validatedObjects.map(\.path)).count == validatedObjects.count else {
            throw TimeMachineRcloneError.invalidObjectPath("duplicate batch path")
        }
        let metadataBytes = validatedObjects.reduce(0) { partial, object in
            guard case let .data(data) = object.payload else { return partial }
            return partial + data.count
        }
        let metadataLimit = 64 * 1_048_576
        guard metadataBytes <= metadataLimit else {
            throw TimeMachineRcloneError.stagingMetadataLimitExceeded(
                requiredBytes: metadataBytes,
                limitBytes: metadataLimit
            )
        }

        let stagingParent = validatedObjects.compactMap { object -> URL? in
            guard case let .file(url) = object.payload else { return nil }
            return url.deletingLastPathComponent()
        }.first ?? FileManager.default.temporaryDirectory
        let stagingRoot = stagingParent.appendingPathComponent(
            ".delta-rclone-stage-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        for object in validatedObjects {
            let destination = object.path.split(separator: "/").reduce(stagingRoot) {
                $0.appendingPathComponent(String($1), isDirectory: false)
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            switch object.payload {
            case let .data(data):
                try data.write(to: destination, options: .atomic)
            case let .file(source):
                // Hard links stage cache payloads without allocating a second copy.
                // Failing closed here preserves the configured local-space bound.
                try FileManager.default.linkItem(at: source, to: destination)
            }
        }

        let copy = try command(
            [
                "copy", "--immutable", "--checksum", "--no-traverse",
                "--transfers", "4", "--checkers", "8",
                stagingRoot.path, configuration.remoteRoot
            ],
            maximumOutputBytes: 1_048_576
        )
        guard copy.exitCode == 0 else {
            throw Self.commandError(copy)
        }

        // The download comparison covers providers without native hashes and is
        // the durability boundary before an authenticated generation publishes.
        let check = try command(
            [
                "check", "--download", "--one-way", "--checkers", "8",
                stagingRoot.path, configuration.remoteRoot
            ],
            maximumOutputBytes: 1_048_576
        )
        guard check.exitCode == 0 else {
            throw Self.commandError(check)
        }
    }

    public func listObjects(withPrefix prefix: String) throws -> [TimeMachineRemoteObjectMetadata] {
        let normalizedPrefix = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        let validatedPrefix = try Self.validated(normalizedPrefix, allowEmpty: true)
        let result = try command(
            ["lsjson", "--recursive", "--files-only", remotePath(validatedPrefix)],
            maximumOutputBytes: 16 * 1_048_576
        )
        guard result.exitCode == 0 else {
            if Self.isMissing(result.standardError) { return [] }
            throw Self.commandError(result)
        }
        guard let items = try? JSONDecoder().decode([ListItem].self, from: result.standardOutput) else {
            throw TimeMachineRcloneError.invalidListResponse
        }
        return items.compactMap { item in
            guard !item.isDir else { return nil }
            let path = [validatedPrefix, item.path]
                .filter { !$0.isEmpty }
                .joined(separator: "/")
            return TimeMachineRemoteObjectMetadata(path: path, size: item.size)
        }.sorted { $0.path < $1.path }
    }

    public func deleteObject(at path: String) throws {
        let path = try Self.validated(path)
        let result = try command(["deletefile", remotePath(path)], maximumOutputBytes: 65_536)
        guard result.exitCode == 0 || Self.isMissing(result.standardError) else {
            throw Self.commandError(result)
        }
    }

    private func command(
        _ arguments: [String],
        input: Data? = nil,
        maximumOutputBytes: Int
    ) throws -> TimeMachineBinaryProcessResult {
        var globalArguments = ["--log-format", "", "--retries", "3"]
        if let configPath = configuration.environment["RCLONE_CONFIG"], !configPath.isEmpty {
            globalArguments += ["--config", configPath]
        }
        return try runner.run(
            executableURL: configuration.executableURL,
            arguments: globalArguments + arguments,
            environment: configuration.environment,
            standardInput: input,
            maximumOutputBytes: maximumOutputBytes,
            maximumRuntime: 30 * 60
        )
    }

    private func command(
        _ arguments: [String],
        input: Data? = nil,
        maximumOutputBytes: Int,
        reusingOutput: inout Data
    ) throws -> TimeMachineBinaryProcessResult {
        var globalArguments = ["--log-format", "", "--retries", "3"]
        if let configPath = configuration.environment["RCLONE_CONFIG"], !configPath.isEmpty {
            globalArguments += ["--config", configPath]
        }
        return try runner.run(
            executableURL: configuration.executableURL,
            arguments: globalArguments + arguments,
            environment: configuration.environment,
            standardInput: input,
            maximumOutputBytes: maximumOutputBytes,
            maximumRuntime: 30 * 60,
            reusingStandardOutput: &reusingOutput
        )
    }

    private func remotePath(_ path: String) -> String {
        guard !path.isEmpty else { return configuration.remoteRoot }
        let separator = configuration.remoteRoot.hasSuffix(":") ? "" : "/"
        return "\(configuration.remoteRoot)\(separator)\(path)"
    }

    private func makeReadStagingRoot() throws -> URL {
        guard let configuredParent = configuration.stagingDirectoryURL else {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                ".delta-rclone-read-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            return root
        }

        let parent = configuredParent.standardizedFileURL
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let parentDescriptor = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parentDescriptor >= 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(parentDescriptor) }
        var parentAttributes = stat()
        guard
            Darwin.fstat(parentDescriptor, &parentAttributes) == 0,
            (parentAttributes.st_mode & S_IFMT) == S_IFDIR,
            parentAttributes.st_uid == Darwin.geteuid(),
            Darwin.fchmod(parentDescriptor, S_IRWXU) == 0
        else {
            throw POSIXError(.EPERM)
        }

        let root = parent.appendingPathComponent("read", isDirectory: true)
        var staleAttributes = stat()
        if Darwin.fstatat(
            parentDescriptor,
            "read",
            &staleAttributes,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            guard
                (staleAttributes.st_mode & S_IFMT) == S_IFDIR,
                staleAttributes.st_uid == Darwin.geteuid(),
                (staleAttributes.st_mode & 0o022) == 0
            else {
                throw POSIXError(.EPERM)
            }
            // The per-repository destination lock serializes production batch
            // reads. Reusing one stable leaf means a process crash can strand
            // at most one 64 MiB filtered download, reclaimed on the next read.
            try FileManager.default.removeItem(at: root)
        } else if errno != ENOENT {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private static func validated(_ path: String, allowEmpty: Bool = false) throws -> String {
        if path.isEmpty, allowEmpty { return "" }
        guard TimeMachineRemotePathPolicy.isValid(path) else {
            throw TimeMachineRcloneError.invalidObjectPath(path)
        }
        return path
    }

    private static func isMissing(_ message: String) -> Bool {
        ["not found", "object not found", "directory not found", "doesn't exist", "does not exist"]
            .contains { message.localizedCaseInsensitiveContains($0) }
    }

    private static func commandError(_ result: TimeMachineBinaryProcessResult) -> TimeMachineRcloneError {
        .commandFailed(
            exitCode: result.exitCode,
            message: SensitiveLogRedactor.redact(result.standardError).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

}

private final class TimeMachinePipeCapture: @unchecked Sendable {
    private let storage: TimeMachineBoundedData
    private let lock = NSLock()
    private let reachedEnd = DispatchSemaphore(value: 0)
    private var didReachEnd = false

    init(limit: Int, keepsTail: Bool = false) {
        storage = TimeMachineBoundedData(limit: limit, keepsTail: keepsTail)
    }

    init(limit: Int, reusing data: inout Data) {
        storage = TimeMachineBoundedData(limit: limit, reusing: &data)
    }

    var value: Data { storage.value }
    func takeValue() -> Data { storage.takeValue() }
    var didExceedLimit: Bool { storage.didExceedLimit }

    func start(reading handle: FileHandle) {
        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                finish()
            } else {
                storage.append(data)
            }
        }
    }

    func stop(reading handle: FileHandle, waitForEnd: Bool) {
        if waitForEnd {
            _ = reachedEnd.wait(timeout: .now() + 2)
        }
        handle.readabilityHandler = nil
        try? handle.close()
    }

    private func finish() {
        lock.lock()
        guard !didReachEnd else {
            lock.unlock()
            return
        }
        didReachEnd = true
        lock.unlock()
        reachedEnd.signal()
    }
}

private final class TimeMachineBoundedData: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let keepsTail: Bool
    private let reusesStorage: Bool
    private var data = Data()
    private var validCount = 0
    private var exceeded = false

    init(limit: Int, keepsTail: Bool = false) {
        self.limit = max(limit, 1)
        self.keepsTail = keepsTail
        self.reusesStorage = false
    }

    init(limit: Int, reusing reusableData: inout Data) {
        self.limit = max(limit, 1)
        self.keepsTail = false
        self.reusesStorage = true
        swap(&data, &reusableData)
        TimeMachineReusableDataBuffer.prepare(&data, count: self.limit)
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        if reusesStorage {
            return Data(data.prefix(validCount))
        }
        return data
    }

    func takeValue() -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard reusesStorage else { return data }
        if validCount < data.count {
            data.removeSubrange(validCount..<data.count)
        }
        var result = Data()
        swap(&result, &data)
        validCount = 0
        return result
    }

    var didExceedLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exceeded
    }

    func append(_ value: Data) {
        guard !value.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if reusesStorage {
            let remaining = max(0, limit - validCount)
            let accepted = min(value.count, remaining)
            if accepted > 0 {
                data.replaceSubrange(
                    validCount..<(validCount + accepted),
                    with: value.prefix(accepted)
                )
                validCount += accepted
            }
            if value.count > accepted {
                exceeded = true
            }
            return
        }
        if keepsTail {
            data.append(value)
            if data.count > limit {
                data.removeFirst(data.count - limit)
                exceeded = true
            }
            return
        }
        let remaining = max(0, limit - data.count)
        data.append(value.prefix(remaining))
        if value.count > remaining {
            exceeded = true
        }
    }
}
