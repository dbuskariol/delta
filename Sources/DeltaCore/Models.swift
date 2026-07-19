import Foundation

public enum BackupSourceMode: String, Codable, CaseIterable, Sendable {
    case fullVolume
    case customFolders

    public var displayName: String {
        switch self {
        case .fullVolume: "Full volume"
        case .customFolders: "Custom folders"
        }
    }

}

public enum BackupFormat: String, Codable, CaseIterable, Sendable {
    case delta
    case timeMachine

    public var displayName: String {
        switch self {
        case .delta: "Delta encrypted backup"
        case .timeMachine: "Time Machine"
        }
    }

    public var detail: String {
        switch self {
        case .delta:
            "Encrypted, deduplicated restore points managed by Delta."
        case .timeMachine:
            "A native Time Machine disk stored remotely through Delta."
        }
    }

}

public enum RepositoryBackendKind: String, Codable, CaseIterable, Sendable {
    case local
    case sftp
    case rest
    case s3
    case backblazeB2
    case azureBlob
    case googleCloudStorage
    case swiftObjectStorage
    case rclone
    case custom

    public var displayName: String {
        switch self {
        case .local: "Local or mounted drive"
        case .sftp: "SFTP"
        case .rest: "REST server"
        case .s3: "S3-compatible"
        case .backblazeB2: "Backblaze B2"
        case .azureBlob: "Azure Blob"
        case .googleCloudStorage: "Google Cloud Storage"
        case .swiftObjectStorage: "OpenStack Swift"
        case .rclone: "Cloud remote"
        case .custom: "Custom backup URL"
        }
    }

    public var supportsTimeMachineObjectStorage: Bool {
        switch self {
        case .local, .sftp, .s3, .backblazeB2, .azureBlob, .googleCloudStorage, .swiftObjectStorage, .rclone:
            true
        case .rest, .custom:
            false
        }
    }
}

public struct TimeMachineRepositorySettings: Codable, Equatable, Sendable {
    public static let defaultImageCapacityBytes: Int64 = 1_099_511_627_776
    public static let defaultCacheLimitBytes: Int64 = 1_073_741_824
    public static let minimumImageCapacityBytes: Int64 = 268_435_456
    public static let maximumImageCapacityBytes: Int64 = 70_368_744_177_664
    public static let sparsebundleBandSizeBytes = 8_388_608
    /// One authenticated remote object matches one native sparsebundle band.
    /// This keeps large-disk manifests bounded without changing the bytes that
    /// Apple's DiskImages implementation reads and writes.
    public static let chunkSizeBytes = sparsebundleBandSizeBytes
    /// Pressure uploads stay fixed-size even when the user selects a larger
    /// performance cache, so cache configuration cannot create an unbounded
    /// transport command or alter correctness.
    public static let remoteSpillBatchBytes: Int64 = 8 * Int64(chunkSizeBytes)
    public static let minimumCacheLimitBytes = remoteSpillBatchBytes
    public static let sparsebundleFileSystemName = "Case-sensitive APFS"
    public static let maximumDiskPasswordBytes = 4_096

    public var storeID: UUID
    public var volumeName: String
    public var imageCapacityBytes: Int64
    public var cacheLimitBytes: Int64
    public var manifestKeychainAccount: String

    public init(
        storeID: UUID = UUID(),
        volumeName: String = "Delta Time Machine",
        imageCapacityBytes: Int64 = Self.defaultImageCapacityBytes,
        cacheLimitBytes: Int64 = Self.defaultCacheLimitBytes,
        manifestKeychainAccount: String? = nil
    ) {
        self.storeID = storeID
        self.volumeName = volumeName
        self.imageCapacityBytes = imageCapacityBytes
        self.cacheLimitBytes = cacheLimitBytes
        self.manifestKeychainAccount = manifestKeychainAccount
            ?? "time-machine-manifest-\(storeID.uuidString)"
    }

    public var remoteNamespace: String {
        "delta-time-machine/v1/\(storeID.uuidString.lowercased())"
    }

    public var diskPasswordKeychainAccount: String {
        "time-machine-password-\(storeID.uuidString)"
    }

    public static func normalizedVolumeName(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !normalized.isEmpty,
            normalized != ".",
            normalized != "..",
            normalized.count <= 63,
            !normalized.contains("/"),
            !normalized.contains(":"),
            normalized.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else {
            return nil
        }
        return normalized
    }
}

public enum TimeMachineRemotePathPolicy {
    public static let maximumPathBytes = 4_096
    public static let maximumComponentBytes = 255

    public static func isValid(_ path: String) -> Bool {
        guard
            !path.isEmpty,
            path.utf8.count <= maximumPathBytes,
            !path.hasPrefix("/"),
            !path.contains("\\"),
            !path.utf8.contains(0)
        else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty
                && $0.utf8.count <= maximumComponentBytes
                && $0 != "."
                && $0 != ".."
                && !$0.hasPrefix(".delta-")
        }
    }
}

public enum TimeMachineDestinationLifecycle: String, Codable, CaseIterable, Sendable {
    case waitingForPermissions
    case preparing
    case disconnecting
    case ready
    case mounted
    case disconnected
    case needsRepair
    case failed

    public var displayName: String {
        switch self {
        case .waitingForPermissions: "Needs Permission"
        case .preparing: "Preparing"
        case .disconnecting: "Disconnecting"
        case .ready: "Ready"
        case .mounted: "Connected"
        case .disconnected: "Disconnected"
        case .needsRepair: "Needs Repair"
        case .failed: "Failed"
        }
    }

}

public enum TimeMachineDestinationFailureContext: String, Codable, Sendable {
    case remotePreparation
    case remoteVerification
    case remoteAvailability
    case systemConnection
    case systemDisconnection
    case systemStatePersistence
    case systemDestinationCleanup
    case remoteSynchronization
    case storageService
}

public struct TimeMachineDestinationState: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID { repositoryID }
    public var repositoryID: UUID
    public var storeID: UUID
    public var lifecycle: TimeMachineDestinationLifecycle
    public var mountSessionID: UUID?
    public var mountPoint: String?
    public var diskImagePath: String?
    public var deviceIdentifier: String?
    public var timeMachineDestinationID: String?
    public var committedGeneration: UInt64
    /// Authenticated digest for `committedGeneration`. Older saved states do
    /// not contain this optional rollback witness and establish it during the
    /// next successful remote verification.
    public var committedManifestDigest: String?
    public var cleanCacheBytes: Int64
    public var dirtyCacheBytes: Int64
    public var lastError: String?
    public var lastFailureContext: TimeMachineDestinationFailureContext?
    public var updatedAt: Date

    public init(
        repositoryID: UUID,
        storeID: UUID,
        lifecycle: TimeMachineDestinationLifecycle = .waitingForPermissions,
        mountSessionID: UUID? = nil,
        mountPoint: String? = nil,
        diskImagePath: String? = nil,
        deviceIdentifier: String? = nil,
        timeMachineDestinationID: String? = nil,
        committedGeneration: UInt64 = 0,
        committedManifestDigest: String? = nil,
        cleanCacheBytes: Int64 = 0,
        dirtyCacheBytes: Int64 = 0,
        lastError: String? = nil,
        lastFailureContext: TimeMachineDestinationFailureContext? = nil,
        updatedAt: Date = Date()
    ) {
        self.repositoryID = repositoryID
        self.storeID = storeID
        self.lifecycle = lifecycle
        self.mountSessionID = mountSessionID
        self.mountPoint = mountPoint
        self.diskImagePath = diskImagePath
        self.deviceIdentifier = deviceIdentifier
        self.timeMachineDestinationID = timeMachineDestinationID
        self.committedGeneration = committedGeneration
        self.committedManifestDigest = committedManifestDigest
        self.cleanCacheBytes = cleanCacheBytes
        self.dirtyCacheBytes = dirtyCacheBytes
        self.lastError = lastError
        self.lastFailureContext = lastFailureContext
        self.updatedAt = updatedAt
    }

    public var allowsSystemConnection: Bool {
        switch lifecycle {
        case .waitingForPermissions, .ready, .disconnected:
            true
        case .failed:
            lastFailureContext == .systemConnection
                || lastFailureContext == .systemDestinationCleanup
                || lastFailureContext == .storageService
        case .preparing, .disconnecting, .mounted, .needsRepair:
            false
        }
    }

    /// A mounted FSKit/APFS stack is necessary but is not, by itself, a
    /// usable Time Machine destination. Starting a backup also requires the
    /// exact mount instance and the canonical destination identity returned by
    /// macOS, with no unresolved system or storage failure. Keeping this as a
    /// domain invariant prevents presentation and alternate command surfaces
    /// from mistaking a cleanup-only residual mount for a connected disk.
    public var isReadyForBackup: Bool {
        guard
            lifecycle == .mounted,
            mountSessionID != nil,
            let mountPoint,
            !mountPoint.isEmpty,
            let diskImagePath,
            !diskImagePath.isEmpty,
            let deviceIdentifier,
            !deviceIdentifier.isEmpty,
            let timeMachineDestinationID,
            UUID(uuidString: timeMachineDestinationID) != nil,
            lastError == nil,
            lastFailureContext == nil
        else {
            return false
        }
        return true
    }

    public var blocksConfigurationChanges: Bool {
        lifecycle == .preparing || lifecycle == .disconnecting || lifecycle == .mounted
    }
}

public enum RepositoryBackend: Codable, Equatable, Sendable {
    case local(path: String)
    case sftp(host: String, path: String, username: String?, port: Int?, identityFilePath: String?)
    case rest(url: String)
    case s3(endpoint: String?, bucket: String, path: String?, region: String?)
    case backblazeB2(bucket: String, path: String?)
    case azureBlob(container: String, path: String?)
    case googleCloudStorage(bucket: String, path: String?)
    case swiftObjectStorage(container: String, path: String?)
    case rclone(remote: String, path: String)
    case custom(repository: String)

    public var kind: RepositoryBackendKind {
        switch self {
        case .local: .local
        case .sftp: .sftp
        case .rest: .rest
        case .s3: .s3
        case .backblazeB2: .backblazeB2
        case .azureBlob: .azureBlob
        case .googleCloudStorage: .googleCloudStorage
        case .swiftObjectStorage: .swiftObjectStorage
        case .rclone: .rclone
        case .custom: .custom
        }
    }
}

public enum SecretStorageMode: String, Codable, CaseIterable, Sendable {
    case appManagedKeychain
    case userManagedPassphrase

    public var displayName: String {
        switch self {
        case .appManagedKeychain: "App-managed Keychain"
        case .userManagedPassphrase: "User-managed passphrase"
        }
    }
}

public extension JobKind {
    var displayName: String {
        switch self {
        case .initializeRepository: "Prepare destination"
        case .backup: "Backup"
        case .restore: "Restore"
        case .check: "Check destination"
        case .prune: "Clean up old restore points"
        }
    }
}

public struct RepositoryCredentialReference: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var environmentKey: String
    public var keychainAccount: String

    public init(id: UUID = UUID(), environmentKey: String, keychainAccount: String) {
        self.id = id
        self.environmentKey = environmentKey
        self.keychainAccount = keychainAccount
    }
}

public enum ScheduleKind: Codable, Equatable, Sendable {
    case hourly(minute: Int)
    case daily(hour: Int, minute: Int)
    case weekly(weekday: Int, hour: Int, minute: Int)
    case monthly(day: Int, hour: Int, minute: Int)
    case customInterval(seconds: TimeInterval)
}

public enum JobKind: String, Codable, CaseIterable, Sendable {
    case initializeRepository
    case backup
    case restore
    case check
    case prune
}

public enum JobStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case succeeded
    case warning
    case failed
    case cancelled

    public var displayName: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .succeeded: "Completed"
        case .warning: "Completed with warnings"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        }
    }
}

public enum RestoreScope: Codable, Equatable, Sendable {
    case fullSnapshot
    case selectedPaths([String])
}

public enum RestoreDestination: Codable, Equatable, Sendable {
    case chosenFolder(String)
    case originalPaths
}

public enum RestoreConflictPolicy: String, Codable, CaseIterable, Sendable {
    case always
    case ifChanged
    case ifNewer
    case never

    public var resticValue: String {
        switch self {
        case .always: "always"
        case .ifChanged: "if-changed"
        case .ifNewer: "if-newer"
        case .never: "never"
        }
    }

    public var displayName: String {
        switch self {
        case .always: "Replace all"
        case .ifChanged: "Replace changed"
        case .ifNewer: "Replace older"
        case .never: "Keep existing"
        }
    }
}

public enum LogLevel: String, Codable, CaseIterable, Sendable {
    case info
    case warning
    case error
    case debug
}

public struct BackupSource: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var bookmarkData: Data?
    public var includeSubvolumes: Bool

    public init(id: UUID = UUID(), path: String, bookmarkData: Data? = nil, includeSubvolumes: Bool = false) {
        self.id = id
        self.path = path
        self.bookmarkData = bookmarkData
        self.includeSubvolumes = includeSubvolumes
    }
}

public struct RetentionMaintenanceSchedule: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var intervalDays: Int
    public var hour: Int
    public var minute: Int

    public init(
        isEnabled: Bool = true,
        intervalDays: Int = 7,
        hour: Int = 2,
        minute: Int = 0
    ) {
        self.isEnabled = isEnabled
        self.intervalDays = intervalDays
        self.hour = hour
        self.minute = minute
    }
}

public struct RetentionPolicy: Codable, Equatable, Sendable {
    public var keepHourly: Int
    public var keepDaily: Int
    public var keepWeekly: Int
    public var keepMonthly: Int
    public var keepYearly: Int
    public var pruneAfterForget: Bool
    public var checkAfterPrune: Bool
    public var maintenanceSchedule: RetentionMaintenanceSchedule

    public init(
        keepHourly: Int = 24,
        keepDaily: Int = 30,
        keepWeekly: Int = 12,
        keepMonthly: Int = 12,
        keepYearly: Int = 0,
        pruneAfterForget: Bool = true,
        checkAfterPrune: Bool = true,
        maintenanceSchedule: RetentionMaintenanceSchedule = RetentionMaintenanceSchedule()
    ) {
        self.keepHourly = keepHourly
        self.keepDaily = keepDaily
        self.keepWeekly = keepWeekly
        self.keepMonthly = keepMonthly
        self.keepYearly = keepYearly
        self.pruneAfterForget = pruneAfterForget
        self.checkAfterPrune = checkAfterPrune
        self.maintenanceSchedule = maintenanceSchedule
    }

    public var hasKeepRules: Bool {
        keepHourly > 0 || keepDaily > 0 || keepWeekly > 0 || keepMonthly > 0 || keepYearly > 0
    }

    enum CodingKeys: String, CodingKey {
        case keepHourly
        case keepDaily
        case keepWeekly
        case keepMonthly
        case keepYearly
        case pruneAfterForget
        case checkAfterPrune
        case maintenanceSchedule
    }
}

public struct BackupRepository: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var backend: RepositoryBackend
    public var format: BackupFormat
    public var timeMachineSettings: TimeMachineRepositorySettings?
    public var secretStorageMode: SecretStorageMode
    public var keychainAccount: String
    public var credentialReferences: [RepositoryCredentialReference]
    public var createdAt: Date
    public var lastVerifiedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        backend: RepositoryBackend,
        format: BackupFormat = .delta,
        timeMachineSettings: TimeMachineRepositorySettings? = nil,
        secretStorageMode: SecretStorageMode = .appManagedKeychain,
        keychainAccount: String? = nil,
        credentialReferences: [RepositoryCredentialReference] = [],
        createdAt: Date = Date(),
        lastVerifiedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.backend = backend
        self.format = format
        self.timeMachineSettings = format == .timeMachine
            ? (timeMachineSettings ?? TimeMachineRepositorySettings(volumeName: name))
            : nil
        self.secretStorageMode = secretStorageMode
        self.keychainAccount = keychainAccount
            ?? self.timeMachineSettings?.diskPasswordKeychainAccount
            ?? "repository-\(id.uuidString)"
        self.credentialReferences = credentialReferences
        self.createdAt = createdAt
        self.lastVerifiedAt = lastVerifiedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case backend
        case format
        case timeMachineSettings
        case secretStorageMode
        case keychainAccount
        case credentialReferences
        case createdAt
        case lastVerifiedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        backend = try container.decode(RepositoryBackend.self, forKey: .backend)
        format = try container.decodeIfPresent(BackupFormat.self, forKey: .format) ?? .delta
        timeMachineSettings = try container.decodeIfPresent(TimeMachineRepositorySettings.self, forKey: .timeMachineSettings)
        if format == .timeMachine, timeMachineSettings == nil {
            timeMachineSettings = TimeMachineRepositorySettings(volumeName: name)
        }
        secretStorageMode = try container.decodeIfPresent(SecretStorageMode.self, forKey: .secretStorageMode) ?? .appManagedKeychain
        keychainAccount = try container.decodeIfPresent(String.self, forKey: .keychainAccount)
            ?? "repository-\(id.uuidString)"
        credentialReferences = try container.decodeIfPresent([RepositoryCredentialReference].self, forKey: .credentialReferences) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastVerifiedAt = try container.decodeIfPresent(Date.self, forKey: .lastVerifiedAt)
    }
}

public struct BackupSchedule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: ScheduleKind
    public var isEnabled: Bool
    public var catchUpMissedRuns: Bool
    public var runOnBattery: Bool
    public var runInLowPowerMode: Bool
    public var uploadLimitKiB: Int?
    public var downloadLimitKiB: Int?

    public init(
        id: UUID = UUID(),
        kind: ScheduleKind = .daily(hour: 20, minute: 0),
        isEnabled: Bool = true,
        catchUpMissedRuns: Bool = true,
        runOnBattery: Bool = true,
        runInLowPowerMode: Bool = false,
        uploadLimitKiB: Int? = nil,
        downloadLimitKiB: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.isEnabled = isEnabled
        self.catchUpMissedRuns = catchUpMissedRuns
        self.runOnBattery = runOnBattery
        self.runInLowPowerMode = runInLowPowerMode
        self.uploadLimitKiB = uploadLimitKiB
        self.downloadLimitKiB = downloadLimitKiB
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case isEnabled
        case catchUpMissedRuns
        case runOnBattery
        case runInLowPowerMode
        case uploadLimitKiB
        case downloadLimitKiB
    }
}

public struct BackupProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var sourceMode: BackupSourceMode
    public var sources: [BackupSource]
    public var repositoryID: UUID
    public var schedule: BackupSchedule
    public var retention: RetentionPolicy
    public var excludePatterns: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        sourceMode: BackupSourceMode,
        sources: [BackupSource],
        repositoryID: UUID,
        schedule: BackupSchedule = BackupSchedule(),
        retention: RetentionPolicy = RetentionPolicy(),
        excludePatterns: [String] = BackupExcludePolicy.defaultMacOSExcludes,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sourceMode = sourceMode
        self.sources = sources
        self.repositoryID = repositoryID
        self.schedule = schedule
        self.retention = retention
        self.excludePatterns = excludePatterns
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sourceMode
        case sources
        case repositoryID
        case schedule
        case retention
        case excludePatterns
        case createdAt
        case updatedAt
    }
}

public struct JobRun: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var profileID: UUID?
    public var repositoryID: UUID
    public var kind: JobKind
    public var status: JobStatus
    public var startedAt: Date
    public var finishedAt: Date?
    public var exitCode: Int32?
    public var message: String?
    public var backupSummary: ResticBackupSummary?
    public var stopReason: ResticRunStopReason?
    public var progressSnapshot: ResticProgressSnapshot?

    public init(
        id: UUID = UUID(),
        profileID: UUID? = nil,
        repositoryID: UUID,
        kind: JobKind,
        status: JobStatus = .queued,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        exitCode: Int32? = nil,
        message: String? = nil,
        backupSummary: ResticBackupSummary? = nil,
        stopReason: ResticRunStopReason? = nil,
        progressSnapshot: ResticProgressSnapshot? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.repositoryID = repositoryID
        self.kind = kind
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.message = message
        self.backupSummary = backupSummary
        self.stopReason = stopReason
        self.progressSnapshot = progressSnapshot
    }

    enum CodingKeys: String, CodingKey {
        case id
        case profileID
        case repositoryID
        case kind
        case status
        case startedAt
        case finishedAt
        case exitCode
        case message
        case backupSummary
        case stopReason
        case progressSnapshot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        profileID = try container.decodeIfPresent(UUID.self, forKey: .profileID)
        repositoryID = try container.decode(UUID.self, forKey: .repositoryID)
        kind = try container.decode(JobKind.self, forKey: .kind)
        status = try container.decode(JobStatus.self, forKey: .status)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        backupSummary = try container.decodeIfPresent(ResticBackupSummary.self, forKey: .backupSummary)
        stopReason = try container.decodeIfPresent(ResticRunStopReason.self, forKey: .stopReason)
        progressSnapshot = try container.decodeIfPresent(ResticProgressSnapshot.self, forKey: .progressSnapshot)
    }

    public var isPausedBackup: Bool {
        kind == .backup && status == .cancelled && stopReason == .pause
    }
}

public struct JobLogEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var jobID: UUID
    public var profileID: UUID?
    public var repositoryID: UUID
    public var date: Date
    public var stream: ResticOutputStream
    public var message: String
    public var backupIssue: BackupIssue?

    public init(
        id: UUID = UUID(),
        jobID: UUID,
        profileID: UUID? = nil,
        repositoryID: UUID,
        date: Date = Date(),
        stream: ResticOutputStream,
        message: String,
        backupIssue: BackupIssue? = nil
    ) {
        self.id = id
        self.jobID = jobID
        self.profileID = profileID
        self.repositoryID = repositoryID
        self.date = date
        self.stream = stream
        self.message = message
        self.backupIssue = backupIssue
    }
}

public struct ResticSnapshot: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var time: Date
    public var tree: String?
    public var paths: [String]
    public var hostname: String?
    public var username: String?
    public var tags: [String]

    public init(
        id: String,
        time: Date,
        tree: String? = nil,
        paths: [String],
        hostname: String? = nil,
        username: String? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.time = time
        self.tree = tree
        self.paths = paths
        self.hostname = hostname
        self.username = username
        self.tags = tags
    }
}

public enum ResticSnapshotEntryType: String, Codable, Equatable, Sendable {
    case directory = "dir"
    case file
    case symlink
    case other

    public init(resticType: String) {
        self = Self(rawValue: resticType) ?? .other
    }

    public var isDirectory: Bool {
        self == .directory
    }
}

public struct ResticSnapshotEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var type: ResticSnapshotEntryType
    public var size: Int64?
    public var modifiedAt: Date?

    public init(
        name: String,
        path: String,
        type: ResticSnapshotEntryType,
        size: Int64? = nil,
        modifiedAt: Date? = nil
    ) {
        self.name = name
        self.path = path
        self.type = type
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

public struct RestoreRequest: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var repositoryID: UUID
    public var snapshotID: String
    public var scope: RestoreScope
    public var destination: RestoreDestination
    public var conflictPolicy: RestoreConflictPolicy
    public var verifyRestoredFiles: Bool
    public var dryRun: Bool
    public var confirmedOriginalPathRestore: Bool
    public var preRestoreBackupProfileID: UUID?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        repositoryID: UUID,
        snapshotID: String,
        scope: RestoreScope = .fullSnapshot,
        destination: RestoreDestination,
        conflictPolicy: RestoreConflictPolicy = .ifChanged,
        verifyRestoredFiles: Bool = true,
        dryRun: Bool = false,
        confirmedOriginalPathRestore: Bool = false,
        preRestoreBackupProfileID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.snapshotID = snapshotID
        self.scope = scope
        self.destination = destination
        self.conflictPolicy = conflictPolicy
        self.verifyRestoredFiles = verifyRestoredFiles
        self.dryRun = dryRun
        self.confirmedOriginalPathRestore = confirmedOriginalPathRestore
        self.preRestoreBackupProfileID = preRestoreBackupProfileID
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case repositoryID
        case snapshotID
        case scope
        case destination
        case conflictPolicy
        case verifyRestoredFiles
        case dryRun
        case confirmedOriginalPathRestore
        case preRestoreBackupProfileID
        case createdAt
    }
}

public struct EventLog: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var level: LogLevel
    public var message: String
    public var createdAt: Date

    public init(id: UUID = UUID(), level: LogLevel, message: String, createdAt: Date = Date()) {
        self.id = id
        self.level = level
        self.message = message
        self.createdAt = createdAt
    }
}
