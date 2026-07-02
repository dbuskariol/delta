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
}

public enum RepositoryBackend: Codable, Equatable, Sendable {
    case local(path: String)
    case sftp(host: String, path: String, username: String?, port: Int?)
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

public struct RetentionPolicy: Codable, Equatable, Sendable {
    public var keepHourly: Int
    public var keepDaily: Int
    public var keepWeekly: Int
    public var keepMonthly: Int
    public var keepYearly: Int
    public var pruneAfterForget: Bool
    public var checkAfterPrune: Bool

    public init(
        keepHourly: Int = 24,
        keepDaily: Int = 30,
        keepWeekly: Int = 12,
        keepMonthly: Int = 12,
        keepYearly: Int = 0,
        pruneAfterForget: Bool = true,
        checkAfterPrune: Bool = true
    ) {
        self.keepHourly = keepHourly
        self.keepDaily = keepDaily
        self.keepWeekly = keepWeekly
        self.keepMonthly = keepMonthly
        self.keepYearly = keepYearly
        self.pruneAfterForget = pruneAfterForget
        self.checkAfterPrune = checkAfterPrune
    }
}

public struct BackupRepository: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var backend: RepositoryBackend
    public var secretStorageMode: SecretStorageMode
    public var keychainAccount: String
    public var credentialReferences: [RepositoryCredentialReference]
    public var createdAt: Date
    public var lastVerifiedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        backend: RepositoryBackend,
        secretStorageMode: SecretStorageMode = .appManagedKeychain,
        keychainAccount: String? = nil,
        credentialReferences: [RepositoryCredentialReference] = [],
        createdAt: Date = Date(),
        lastVerifiedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.backend = backend
        self.secretStorageMode = secretStorageMode
        self.keychainAccount = keychainAccount ?? "repository-\(id.uuidString)"
        self.credentialReferences = credentialReferences
        self.createdAt = createdAt
        self.lastVerifiedAt = lastVerifiedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case backend
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
        secretStorageMode = try container.decode(SecretStorageMode.self, forKey: .secretStorageMode)
        keychainAccount = try container.decode(String.self, forKey: .keychainAccount)
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(ScheduleKind.self, forKey: .kind)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        catchUpMissedRuns = try container.decode(Bool.self, forKey: .catchUpMissedRuns)
        runOnBattery = try container.decode(Bool.self, forKey: .runOnBattery)
        runInLowPowerMode = try container.decodeIfPresent(Bool.self, forKey: .runInLowPowerMode) ?? false
        uploadLimitKiB = try container.decodeIfPresent(Int.self, forKey: .uploadLimitKiB)
        downloadLimitKiB = try container.decodeIfPresent(Int.self, forKey: .downloadLimitKiB)
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

    public init(
        id: UUID = UUID(),
        profileID: UUID? = nil,
        repositoryID: UUID,
        kind: JobKind,
        status: JobStatus = .queued,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        exitCode: Int32? = nil,
        message: String? = nil
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

public struct RestoreRequest: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var repositoryID: UUID
    public var snapshotID: String
    public var scope: RestoreScope
    public var destination: RestoreDestination
    public var conflictPolicy: RestoreConflictPolicy
    public var verifyRestoredFiles: Bool
    public var dryRun: Bool
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
        case preRestoreBackupProfileID
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        repositoryID = try container.decode(UUID.self, forKey: .repositoryID)
        snapshotID = try container.decode(String.self, forKey: .snapshotID)
        scope = try container.decode(RestoreScope.self, forKey: .scope)
        destination = try container.decode(RestoreDestination.self, forKey: .destination)
        conflictPolicy = try container.decode(RestoreConflictPolicy.self, forKey: .conflictPolicy)
        verifyRestoredFiles = try container.decode(Bool.self, forKey: .verifyRestoredFiles)
        dryRun = try container.decode(Bool.self, forKey: .dryRun)
        preRestoreBackupProfileID = try container.decodeIfPresent(UUID.self, forKey: .preRestoreBackupProfileID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
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
