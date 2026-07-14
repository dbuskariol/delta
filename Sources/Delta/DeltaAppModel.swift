import AppKit
import DeltaCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private struct DeltaDatabaseSnapshot: Sendable {
    var repositories: [BackupRepository]
    var profiles: [BackupProfile]
    var jobs: [JobRun]
    var jobLogs: [JobLogEntry]
    var snapshots: [ResticSnapshot]
    var snapshotsByRepository: [UUID: [ResticSnapshot]]
    var events: [EventLog]
    var sourceHealthWarnings: [DashboardHealthWarning]
    var acknowledgedWarningIssueCounts: [UUID: Int]

    init(database: DeltaDatabase) throws {
        repositories = try database.fetchRepositories()
        profiles = try database.fetchProfiles()
        jobs = try database.fetchJobRuns(limit: 100)
        if let runningJob = jobs.first(where: { $0.status == .running }) {
            jobLogs = try database.fetchJobLogs(jobID: runningJob.id, limit: 200)
        } else {
            jobLogs = []
        }
        snapshots = try database.fetchSnapshots()
        snapshotsByRepository = try database.fetchSnapshotsByRepository()
        events = try database.fetchEvents(limit: 200)
        sourceHealthWarnings = DashboardHealthEvaluator().sourceWarnings(profiles: profiles)
        let warningJobs = jobs.filter {
            $0.kind == .backup && $0.status == .warning && $0.profileID != nil
        }
        let issuesByJobID = try database.fetchBackupIssues(jobIDs: warningJobs.map(\.id))
        let acknowledgmentStore = BackupIssueAcknowledgmentStore()
        acknowledgedWarningIssueCounts = Dictionary(uniqueKeysWithValues: warningJobs.compactMap { job in
            guard
                let profileID = job.profileID,
                let issues = issuesByJobID[job.id],
                acknowledgmentStore.allAcknowledged(issues, profileID: profileID)
            else {
                return nil
            }
            return (job.id, issues.count)
        })
    }
}

private struct DeltaSystemStateSnapshot: Sendable {
    var fullDiskAccessStatus: FullDiskAccessStatus
    var launchAgentStatus: LaunchAgentRegistrationStatus
    var appLoginItemStatus: LaunchAgentRegistrationStatus

    static func current() -> DeltaSystemStateSnapshot {
        DeltaSystemStateSnapshot(
            fullDiskAccessStatus: FullDiskAccessProbe().check(),
            launchAgentStatus: LaunchAgentController.status(),
            appLoginItemStatus: AppLoginItemController.status()
        )
    }
}

struct ActiveOperation: Identifiable, Equatable {
    var id = UUID()
    var kind: JobKind
    var profileID: UUID?
    var repositoryID: UUID?
    var title: String
    var detail: String
    var startedAt = Date()
}

@MainActor
final class DeltaAppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard"
        case backups = "Backups"
        case destinations = "Destinations"
        case restore = "Restore"
        case activity = "Activity"
        case settings = "Settings"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .dashboard: "rectangle.grid.2x2"
            case .backups: "externaldrive.badge.plus"
            case .destinations: "externaldrive.connected.to.line.below"
            case .restore: "arrow.uturn.backward.circle"
            case .activity: "waveform.path.ecg"
            case .settings: "gearshape"
            }
        }
    }

    @Published var selectedSection: Section = .dashboard
    @Published var repositories: [BackupRepository] = []
    @Published var profiles: [BackupProfile] = []
    @Published var jobs: [JobRun] = []
    @Published var jobLogs: [JobLogEntry] = []
    @Published var snapshots: [ResticSnapshot] = []
    @Published var snapshotsByRepository: [UUID: [ResticSnapshot]] = [:]
    @Published private(set) var snapshotEntryCache: [String: [ResticSnapshotEntry]] = [:]
    @Published private(set) var snapshotEntryLoadingKeys: Set<String> = []
    @Published var events: [EventLog] = []
    @Published private(set) var sourceHealthWarnings: [DashboardHealthWarning] = []
    @Published private(set) var backgroundSecretAccessReports: [RepositorySecretAccessReport] = []
    @Published var fullDiskAccessStatus = FullDiskAccessProbe().check()
    @Published var isWorking = false
    @Published var alertMessage: String?
    @Published var liveLogLines: [ResticOutputEvent] = []
    @Published var activeOperation: ActiveOperation?
    @Published var activeJobID: UUID?
    @Published var activeProgress: ResticProgressSnapshot?
    @Published var activeDisplayedProgressFraction: Double?
    @Published var activeStopRequest: ResticRunStopReason?
    @Published private(set) var persistentStoreErrorMessage: String?
    @Published private(set) var launchAgentStatus = LaunchAgentController.status()
    @Published private(set) var appLoginItemStatus = AppLoginItemController.status()
    @Published private(set) var scheduledBackupServiceError: String?
    @Published private(set) var backupIssueAcknowledgmentRevision = 0
    @Published private(set) var acknowledgedWarningIssueCounts: [UUID: Int] = [:]

    var isPersistentStoreAvailable: Bool {
        persistentStoreErrorMessage == nil
    }

    var scheduledBackupsNeedAgentSetup: Bool {
        profiles.contains { $0.schedule.isEnabled }
            && (launchAgentStatus.blocksScheduledBackups || scheduledBackupServiceError != nil)
    }

    private var database: DeltaDatabase?
    private let secretStore = KeychainSecretStore()
    private let credentialResolver = RepositoryCredentialResolver()
    private let bookmarkStore = SecurityScopedBookmarkStore()
    private let volumeSourceFactory = BackupVolumeSourceFactory()
    private let repositoryValidator = BackupRepositoryValidator()
    private let localRepositoryStateInspector = LocalResticRepositoryStateInspector()
    private let profileValidator = BackupProfileValidator()
    private let backupIssueAcknowledgmentStore = BackupIssueAcknowledgmentStore()
    private let runController = ResticRunController()
    private let runControlStore = ResticRunControlStore()
    private var localOperationIsRunning = false
    private var databaseRefreshTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var systemStateRefreshTask: Task<Void, Never>?
    private var backgroundSecretAccessTask: Task<Void, Never>?
    private var backgroundRegistrationTask: Task<Void, Never>?
    private var reloadWasRequested = false
    private var lastSystemStateRefreshAt: Date?
    private var lastLiveLogWasStatus = false
    private var lastOperationalHistoryPruneAt: Date?
    private var lastBackgroundSecretAccessCheckAt: Date?
    private var lastBackgroundSecretAccessSignature = ""

    init() {
        let result = Self.openDatabase()
        database = result.database
        persistentStoreErrorMessage = result.errorMessage
        alertMessage = result.errorMessage
        if result.errorMessage == nil {
            if let database {
                _ = try? makeCoordinator(database: database).recoverAbandonedRunningJobs()
                pruneOperationalHistoryIfNeeded()
            }
            reload()
            refreshSystemState(force: true)
            startDatabaseRefreshLoop()
        }
    }

    deinit {
        databaseRefreshTask?.cancel()
        reloadTask?.cancel()
        systemStateRefreshTask?.cancel()
        backgroundSecretAccessTask?.cancel()
        backgroundRegistrationTask?.cancel()
    }

    func reload() {
        guard reopenPersistentStoreIfNeeded(), let database else {
            publishIfChanged(&sourceHealthWarnings, [])
            publishIfChanged(&backgroundSecretAccessReports, [])
            refreshSystemState(force: true)
            return
        }

        guard reloadTask == nil else {
            reloadWasRequested = true
            return
        }

        reloadTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try DeltaDatabaseSnapshot(database: database) }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.reloadTask = nil
            switch result {
            case let .success(snapshot):
                self.apply(snapshot)
            case let .failure(error):
                self.alertMessage = error.localizedDescription
            }
            if self.reloadWasRequested {
                self.reloadWasRequested = false
                self.reload()
            }
        }
    }

    private func startDatabaseRefreshLoop() {
        databaseRefreshTask?.cancel()
        databaseRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval: UInt64 = self.isWorking ? 1_000_000_000 : 8_000_000_000
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                self.reload()
                self.refreshSystemState()
            }
        }
    }

    private func apply(_ snapshot: DeltaDatabaseSnapshot) {
        let jobsChanged = jobs != snapshot.jobs
        let logsChanged = jobLogs != snapshot.jobLogs

        publishIfChanged(&repositories, snapshot.repositories)
        publishIfChanged(&profiles, snapshot.profiles)
        publishIfChanged(&jobs, snapshot.jobs)
        publishIfChanged(&jobLogs, snapshot.jobLogs)
        publishIfChanged(&snapshots, snapshot.snapshots)
        publishIfChanged(&snapshotsByRepository, snapshot.snapshotsByRepository)
        publishIfChanged(&events, snapshot.events)
        publishIfChanged(&sourceHealthWarnings, snapshot.sourceHealthWarnings)
        publishIfChanged(&acknowledgedWarningIssueCounts, snapshot.acknowledgedWarningIssueCounts)

        refreshBackgroundSecretAccessStatusIfNeeded(repositories: snapshot.repositories)
        synchronizeScheduledBackupsRegistration()
        if jobsChanged || logsChanged {
            reconcileObservedActiveJob(
                jobs: snapshot.jobs,
                jobLogs: snapshot.jobLogs,
                profiles: snapshot.profiles,
                repositories: snapshot.repositories
            )
        }
    }

    private func publishIfChanged<Value: Equatable>(_ value: inout Value, _ replacement: Value) {
        if value != replacement {
            value = replacement
        }
    }

    func refreshSystemState(force: Bool = false) {
        let now = Date()
        if !force,
           let lastSystemStateRefreshAt,
           now.timeIntervalSince(lastSystemStateRefreshAt) < 60 {
            return
        }
        guard systemStateRefreshTask == nil else { return }
        lastSystemStateRefreshAt = now

        systemStateRefreshTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                DeltaSystemStateSnapshot.current()
            }.value
            guard let self, !Task.isCancelled else { return }
            self.systemStateRefreshTask = nil
            self.publishIfChanged(&self.fullDiskAccessStatus, snapshot.fullDiskAccessStatus)
            self.publishIfChanged(&self.launchAgentStatus, snapshot.launchAgentStatus)
            self.publishIfChanged(&self.appLoginItemStatus, snapshot.appLoginItemStatus)
            self.synchronizeScheduledBackupsRegistration()
        }
    }

    private func reconcileObservedActiveJob(
        jobs: [JobRun],
        jobLogs: [JobLogEntry],
        profiles: [BackupProfile],
        repositories: [BackupRepository]
    ) {
        guard !localOperationIsRunning else {
            return
        }

        guard let runningJob = jobs
            .filter({ $0.status == .running })
            .max(by: { $0.startedAt < $1.startedAt })
        else {
            isWorking = false
            activeOperation = nil
            activeJobID = nil
            activeProgress = nil
            activeDisplayedProgressFraction = nil
            activeStopRequest = nil
            liveLogLines.removeAll()
            lastLiveLogWasStatus = false
            return
        }

        isWorking = true
        activeJobID = runningJob.id
        activeOperation = observedOperation(
            for: runningJob,
            profiles: profiles,
            repositories: repositories
        )
        activeStopRequest = runControlStore.stopReason(for: runningJob.id)
        activeProgress = runningJob.progressSnapshot
        activeDisplayedProgressFraction = runningJob.progressSnapshot.flatMap {
            BackupProgressEstimator.displayedFraction(for: $0, previous: nil)
        }
        liveLogLines = jobLogs
            .filter { $0.jobID == runningJob.id }
            .sorted { $0.date < $1.date }
            .suffix(200)
            .map { ResticOutputEvent(id: $0.id, date: $0.date, stream: $0.stream, message: $0.message) }
        lastLiveLogWasStatus = false
    }

    private func observedOperation(
        for job: JobRun,
        profiles: [BackupProfile],
        repositories: [BackupRepository]
    ) -> ActiveOperation {
        let profile = job.profileID.flatMap { profileID in profiles.first { $0.id == profileID } }
        let repository = repositories.first { $0.id == job.repositoryID }
        let profileName = profile?.name ?? "scheduled backup"
        let repositoryName = repository?.name ?? "destination"

        let title: String
        let detail: String
        switch job.kind {
        case .initializeRepository:
            title = "Preparing \(repositoryName)"
            detail = "Creating encrypted destination metadata"
        case .backup:
            title = profile.map { "Backing up \($0.name)" } ?? "Running scheduled backups"
            detail = "Saving to \(repositoryName)"
        case .restore:
            title = "Restoring files"
            detail = "Reading from \(repositoryName)"
        case .check:
            title = "Checking \(repositoryName)"
            detail = "Verifying destination integrity"
        case .prune:
            title = "Cleaning up \(profileName)"
            detail = "Applying retention rules to \(repositoryName)"
        }

        return ActiveOperation(
            id: job.id,
            kind: job.kind,
            profileID: job.profileID,
            repositoryID: job.repositoryID,
            title: title,
            detail: detail,
            startedAt: job.startedAt
        )
    }

    func activityLogPage(
        for jobID: UUID,
        before cursor: JobLogCursor? = nil,
        limit: Int = 200,
        issuesOnly: Bool = false
    ) async throws -> JobLogPage {
        guard let database else {
            throw DeltaUIError.message(
                persistentStoreErrorMessage
                    ?? "Delta cannot access its local app data. Reopen Delta and try again."
            )
        }
        return try await Task.detached(priority: .userInitiated) {
            try database.fetchJobLogPage(
                jobID: jobID,
                before: cursor,
                limit: limit,
                issuesOnly: issuesOnly
            )
        }.value
    }

    @discardableResult
    func createRepository(
        name: String,
        backend: RepositoryBackend,
        storageMode: SecretStorageMode = .appManagedKeychain,
        passphrase: String? = nil,
        backendCredentials: [String: String] = [:]
    ) -> Bool {
        guard let database = requirePersistentDatabase() else { return false }
        var rollbackSecretAccounts = Set<String>()
        var persistedRepositoryID: UUID?
        let userManagedPassphrase = passphrase ?? ""
        do {
            let validated = try repositoryValidator.validate(name: name, backend: backend)
            let repositoryID = UUID()
            let localState = localRepositoryStateInspector.state(for: validated.backend)
            let reconnectsPreparedLocalDestination = localState?.isPrepared == true
            if storageMode == .userManagedPassphrase {
                guard !userManagedPassphrase.isEmpty else {
                    throw DeltaUIError.message("An encryption passphrase is required for user-managed destinations.")
                }
            } else if reconnectsPreparedLocalDestination {
                throw DeltaUIError.message(existingLocalDestinationRequiresPasswordMessage(path: localState?.path))
            }
            let credentialReferences = try credentialResolver.saveCredentials(backendCredentials, repositoryID: repositoryID)
            rollbackSecretAccounts.formUnion(credentialReferences.map(\.keychainAccount))
            let repository = BackupRepository(
                id: repositoryID,
                name: validated.name,
                backend: validated.backend,
                secretStorageMode: storageMode,
                credentialReferences: credentialReferences
            )
            switch storageMode {
            case .appManagedKeychain:
                _ = try secretStore.generateAndSave(account: repository.keychainAccount)
                rollbackSecretAccounts.insert(repository.keychainAccount)
            case .userManagedPassphrase:
                try secretStore.save(secret: userManagedPassphrase, account: repository.keychainAccount)
                rollbackSecretAccounts.insert(repository.keychainAccount)
            }
            try database.saveRepository(repository)
            persistedRepositoryID = repository.id
            if reconnectsPreparedLocalDestination {
                try validateExistingDestination(repository, database: database, path: localState?.path)
                try? database.appendEvent(EventLog(level: .info, message: "Destination '\(repository.name)' was connected to existing encrypted backup data."))
            } else {
                try? database.appendEvent(EventLog(level: .info, message: "Destination '\(repository.name)' was created."))
            }
            reload()
            if !reconnectsPreparedLocalDestination {
                initializeRepository(repository)
            }
            return true
        } catch {
            if let persistedRepositoryID {
                try? database.deleteRepository(id: persistedRepositoryID)
            }
            rollbackSecrets(accounts: rollbackSecretAccounts)
            alertMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func saveRepository(
        _ repository: BackupRepository,
        name: String,
        backend: RepositoryBackend,
        backendCredentials: [String: String] = [:]
    ) -> Bool {
        guard let database = requirePersistentDatabase() else { return false }
        var previousRepository = repository
        do {
            let validated = try repositoryValidator.validate(
                name: name,
                backend: backend,
                validateLocalAvailability: backend != repository.backend
            )
            var updatedRepository = repository
            updatedRepository.name = validated.name
            updatedRepository.backend = validated.backend
            let localState = localRepositoryStateInspector.state(for: validated.backend)
            let reconnectsPreparedLocalDestination = localState?.isPrepared == true
            if reconnectsPreparedLocalDestination, updatedRepository.backend != repository.backend {
                throw DeltaUIError.message(existingLocalDestinationRequiresPasswordMessage(path: localState?.path))
            }
            updatedRepository.credentialReferences = try credentialResolver.updateCredentials(
                backendCredentials,
                existingReferences: repository.credentialReferences,
                repositoryID: repository.id,
                allowedKeys: ResticBackendCredentialTemplates.keys(for: backend.kind)
            )
            if updatedRepository.backend != repository.backend || updatedRepository.credentialReferences != repository.credentialReferences {
                updatedRepository.lastVerifiedAt = nil
            }
            previousRepository = repository
            try database.saveRepository(updatedRepository)
            if reconnectsPreparedLocalDestination && updatedRepository.lastVerifiedAt == nil {
                try validateExistingDestination(updatedRepository, database: database, path: localState?.path)
            }
            try database.appendEvent(EventLog(level: .info, message: "Destination '\(updatedRepository.name)' was updated."))
            reload()
            return true
        } catch {
            try? database.saveRepository(previousRepository)
            alertMessage = error.localizedDescription
            return false
        }
    }

    func reconnectRepositoryPassword(_ repository: BackupRepository, originalPassword: String) async throws -> String? {
        guard let database else {
            throw DeltaUIError.message(
                persistentStoreErrorMessage
                    ?? "Delta cannot access its local app data. Reopen Delta and try again."
            )
        }
        guard !localOperationIsRunning else {
            throw DeltaUIError.message("Wait for the current Delta job to finish, then reconnect this destination.")
        }
        localOperationIsRunning = true
        isWorking = true
        activeOperation = ActiveOperation(
            kind: .check,
            repositoryID: repository.id,
            title: "Reconnecting \(repository.name)",
            detail: "Validating the original encryption password"
        )
        defer {
            localOperationIsRunning = false
            isWorking = false
            activeOperation = nil
        }
        let manager = makeRepositoryPasswordManager()
        let result = await Task.detached(priority: .userInitiated) {
            Result { try manager.reconnect(repository: repository, originalPassword: originalPassword) }
        }.value

        switch result {
        case .success:
            var updatedRepository = repository
            updatedRepository.secretStorageMode = .userManagedPassphrase
            updatedRepository.lastVerifiedAt = Date()
            do {
                try database.saveRepository(updatedRepository)
                try database.appendEvent(EventLog(level: .info, message: "Password access for destination '\(repository.name)' was reconnected and verified."))
            } catch {
                reload()
                return "The original password was verified and saved, but Delta could not update its local status: \(error.localizedDescription)"
            }
            reload()
            return nil
        case let .failure(error):
            throw error
        }
    }

    func rotateRepositoryPassword(_ repository: BackupRepository, newPassword: String) async throws -> String? {
        guard let database else {
            throw DeltaUIError.message(
                persistentStoreErrorMessage
                    ?? "Delta cannot access its local app data. Reopen Delta and try again."
            )
        }
        guard !localOperationIsRunning else {
            throw DeltaUIError.message("Wait for the current Delta job to finish, then change this password.")
        }
        localOperationIsRunning = true
        isWorking = true
        activeOperation = ActiveOperation(
            kind: .check,
            repositoryID: repository.id,
            title: "Changing password for \(repository.name)",
            detail: "Adding and verifying a new encryption key"
        )
        defer {
            localOperationIsRunning = false
            isWorking = false
            activeOperation = nil
        }
        let manager = makeRepositoryPasswordManager()
        let result = await Task.detached(priority: .userInitiated) {
            Result { try manager.rotate(repository: repository, newPassword: newPassword) }
        }.value

        switch result {
        case let .success(changeResult):
            var updatedRepository = repository
            updatedRepository.secretStorageMode = .userManagedPassphrase
            updatedRepository.lastVerifiedAt = Date()
            let retainedOldKey = changeResult == .completedWithOldKeyRetained
            var warnings: [String] = []
            if retainedOldKey {
                warnings.append("The new password is active and verified, but Delta could not retire the previous encryption key. Backups can continue; retry the password change after checking destination availability.")
            }
            do {
                try database.saveRepository(updatedRepository)
                try database.appendEvent(
                    EventLog(
                        level: retainedOldKey ? .warning : .info,
                        message: retainedOldKey
                            ? "The password for destination '\(repository.name)' was changed, but its previous encryption key could not be retired."
                            : "The password for destination '\(repository.name)' was changed and the previous encryption key was retired."
                    )
                )
            } catch {
                warnings.append("The password was changed and verified, but Delta could not update its local status: \(error.localizedDescription)")
            }
            reload()
            return warnings.isEmpty ? nil : warnings.joined(separator: " ")
        case let .failure(error):
            throw error
        }
    }

    private func rollbackSecrets(accounts: Set<String>) {
        for account in accounts {
            try? secretStore.delete(account: account)
        }
    }

    private func validateExistingDestination(_ repository: BackupRepository, database: DeltaDatabase, path: String?) throws {
        do {
            _ = try makeCoordinator(database: database).refreshSnapshots(repository: repository)
        } catch {
            throw DeltaUIError.message(existingLocalDestinationPasswordMismatchMessage(path: path, error: error))
        }
    }

    private func existingLocalDestinationRequiresPasswordMessage(path: String?) -> String {
        let location = path.map { " at '\($0)'" } ?? ""
        return "This destination\(location) already contains encrypted backup data. Enter the original encryption password with User-managed passphrase to reconnect it, or choose an empty folder to start fresh."
    }

    private func existingLocalDestinationPasswordMismatchMessage(path: String?, error: Error) -> String {
        let location = path.map { " at '\($0)'" } ?? ""
        let detail = error.localizedDescription
        if detail.localizedCaseInsensitiveContains("encryption password")
            || detail.localizedCaseInsensitiveContains("wrong password")
            || detail.localizedCaseInsensitiveContains("no key found") {
            return "This destination\(location) already contains encrypted backup data, but the saved password does not unlock it. Enter the original encryption password, or choose an empty folder to start fresh."
        }
        return "Delta could not connect to the existing encrypted backup data\(location): \(detail)"
    }

    func createProfile(
        name: String,
        mode: BackupSourceMode,
        sources: [BackupSource],
        repositoryID: UUID,
        schedule: BackupSchedule,
        retention: RetentionPolicy = RetentionPolicy(),
        excludePatterns: [String] = BackupExcludePolicy.defaultMacOSExcludes
    ) {
        guard let database = requirePersistentDatabase() else { return }
        do {
            let profile = BackupProfile(
                name: name,
                sourceMode: mode,
                sources: sources,
                repositoryID: repositoryID,
                schedule: schedule,
                retention: retention,
                excludePatterns: excludePatterns
            )
            let validatedProfile = try profileValidator.validate(
                profile,
                knownRepositoryIDs: knownRepositoryIDs()
            ).profile
            try database.saveProfile(validatedProfile)
            try database.appendEvent(EventLog(level: .info, message: "Backup profile '\(validatedProfile.name)' was created."))
            requestBackgroundBackupsIfNeeded(for: validatedProfile)
            reload()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func saveProfile(_ profile: BackupProfile) {
        guard let database = requirePersistentDatabase() else { return }
        do {
            var profile = profile
            profile.updatedAt = Date()
            let validatedProfile = try profileValidator.validate(
                profile,
                knownRepositoryIDs: knownRepositoryIDs()
            ).profile
            try database.saveProfile(validatedProfile)
            try database.appendEvent(EventLog(level: .info, message: "Backup profile '\(validatedProfile.name)' was updated."))
            requestBackgroundBackupsIfNeeded(for: validatedProfile)
            reload()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    @discardableResult
    func addBackupIssueExclusions(_ patterns: [String], profileID: UUID) -> Bool {
        guard let database = requirePersistentDatabase() else { return false }
        guard var profile = profiles.first(where: { $0.id == profileID }) else {
            alertMessage = "The backup profile for this issue no longer exists."
            return false
        }
        let requestedPatterns = Set(patterns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter { !$0.isEmpty }
        let newPatterns = requestedPatterns.subtracting(profile.excludePatterns)
        guard !newPatterns.isEmpty else { return true }

        do {
            profile.excludePatterns.append(contentsOf: newPatterns.sorted())
            profile.updatedAt = Date()
            let validatedProfile = try profileValidator.validate(
                profile,
                knownRepositoryIDs: knownRepositoryIDs()
            ).profile
            try database.saveProfile(validatedProfile)
            try database.appendEvent(
                EventLog(
                    level: .info,
                    message: "Added \(newPatterns.count) reviewed backup \(newPatterns.count == 1 ? "exclusion" : "exclusions") to '\(validatedProfile.name)'."
                )
            )
            requestBackgroundBackupsIfNeeded(for: validatedProfile)
            reload()
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    func isBackupIssueAcknowledged(_ issue: BackupIssue, profileID: UUID) -> Bool {
        _ = backupIssueAcknowledgmentRevision
        return backupIssueAcknowledgmentStore.isAcknowledged(issue, profileID: profileID)
    }

    func outcomePresentation(for job: JobRun) -> JobOutcomePresentation {
        JobOutcomePresentation(
            status: job.status,
            acknowledgedOmissionCount: acknowledgedWarningIssueCounts[job.id]
        )
    }

    func setBackupIssuesAcknowledged(_ acknowledged: Bool, issues: [BackupIssue], profileID: UUID) {
        guard !issues.isEmpty else { return }
        backupIssueAcknowledgmentStore.setAcknowledged(acknowledged, issues: issues, profileID: profileID)
        backupIssueAcknowledgmentRevision &+= 1
        if let database {
            let action = acknowledged ? "Acknowledged" : "Restored alerts for"
            let profileName = profiles.first(where: { $0.id == profileID })?.name ?? "backup profile"
            try? database.appendEvent(
                EventLog(
                    level: .info,
                    message: "\(action) \(issues.count) recurring backup \(issues.count == 1 ? "issue" : "issues") for '\(profileName)'."
                )
            )
        }
        reload()
    }

    func revealBackupIssue(_ issue: BackupIssue) {
        var url = URL(fileURLWithPath: issue.path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func deleteProfile(_ profile: BackupProfile) {
        guard let database = requirePersistentDatabase() else { return }
        do {
            try database.deleteProfile(id: profile.id)
            try database.appendEvent(EventLog(level: .info, message: "Backup profile '\(profile.name)' was removed."))
            reload()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func deleteRepository(_ repository: BackupRepository) {
        guard let database = requirePersistentDatabase() else { return }
        do {
            let currentProfiles = try database.fetchProfiles()
            let referencingProfileNames = currentProfiles
                .filter { $0.repositoryID == repository.id }
                .map(\.name)
                .sorted()
            guard referencingProfileNames.isEmpty else {
                throw DeltaUIError.message(destinationRemovalBlockedMessage(profileNames: referencingProfileNames))
            }

            try database.deleteRepository(id: repository.id)
            let cleanupReport = RepositorySecretCleaner(secretStore: secretStore).cleanup(repository: repository)
            if cleanupReport.isFullyCleaned {
                try? database.appendEvent(EventLog(level: .info, message: "Destination '\(repository.name)' was removed from Delta."))
            } else {
                let message = "Destination '\(repository.name)' was removed from Delta, but \(cleanupReport.failures.count) saved password \(cleanupReport.failures.count == 1 ? "item" : "items") could not be removed."
                try? database.appendEvent(EventLog(level: .warning, message: message))
                alertMessage = "\(message) The first failure was \(cleanupReport.failures[0].purpose): \(cleanupReport.failures[0].message)"
            }
            reload()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func destinationRemovalBlockedMessage(profileNames: [String]) -> String {
        let prefix = profileNames.prefix(3).joined(separator: ", ")
        let remainder = profileNames.count - min(profileNames.count, 3)
        let suffix = remainder > 0 ? " and \(remainder) more" : ""
        let noun = profileNames.count == 1 ? "backup profile" : "backup profiles"
        return "Move or delete the \(noun) using this destination before removing it: \(prefix)\(suffix)."
    }

    func runNow(profile: BackupProfile) {
        startBackup(profile: profile, isResume: false)
    }

    func resumeBackup(profile: BackupProfile) {
        startBackup(profile: profile, isResume: true)
    }

    private func startBackup(profile: BackupProfile, isResume: Bool) {
        guard let database = requirePersistentDatabase() else { return }
        guard let repository = repositories.first(where: { $0.id == profile.repositoryID }) else {
            alertMessage = "Destination for this profile no longer exists."
            return
        }
        let coordinator = makeCoordinator(database: database)
        performBackgroundJobWork(
            activeOperation: ActiveOperation(
                kind: .backup,
                profileID: profile.id,
                repositoryID: repository.id,
                title: "\(isResume ? "Resuming" : "Backing up") \(profile.name)",
                detail: "\(isResume ? "Continuing backup to" : "Saving to") \(repository.name)"
            )
        ) {
            [try coordinator.runBackup(profile: profile, repository: repository)]
        }
    }

    func pauseActiveBackup() {
        guard requirePersistentDatabase() != nil else { return }
        guard isWorking, activeOperation?.kind == .backup, activeStopRequest == nil else {
            return
        }
        requestActiveStop(.pause)
    }

    func cancelActiveJob() {
        guard requirePersistentDatabase() != nil else { return }
        guard isWorking, activeOperation != nil, activeStopRequest == nil else {
            return
        }
        requestActiveStop(.cancel)
    }

    func initializeRepository(_ repository: BackupRepository) {
        guard let database = requirePersistentDatabase() else { return }
        let coordinator = makeCoordinator(database: database)
        performBackgroundJobWork(
            activeOperation: ActiveOperation(
                kind: .initializeRepository,
                profileID: nil,
                repositoryID: repository.id,
                title: "Preparing \(repository.name)",
                detail: "Creating encrypted destination metadata"
            )
        ) {
            [try coordinator.initializeRepository(repository)]
        }
    }

    func checkRepository(_ repository: BackupRepository) {
        guard let database = requirePersistentDatabase() else { return }
        let coordinator = makeCoordinator(database: database)
        performBackgroundJobWork(
            activeOperation: ActiveOperation(
                kind: .check,
                profileID: nil,
                repositoryID: repository.id,
                title: "Checking \(repository.name)",
                detail: "Verifying destination integrity"
            )
        ) {
            [try coordinator.check(repository: repository, readDataSubset: "1/100")]
        }
    }

    func prune(profile: BackupProfile) {
        guard let database = requirePersistentDatabase() else { return }
        guard let repository = repositories.first(where: { $0.id == profile.repositoryID }) else {
            alertMessage = "Destination for this profile no longer exists."
            return
        }
        let coordinator = makeCoordinator(database: database)
        performBackgroundJobWork(
            activeOperation: ActiveOperation(
                kind: .prune,
                profileID: profile.id,
                repositoryID: repository.id,
                title: "Cleaning up \(profile.name)",
                detail: "Applying retention rules to \(repository.name)"
            )
        ) {
            [try coordinator.forgetAndPrune(profile: profile, repository: repository)]
        }
    }

    func runDueBackups() {
        guard let database = requirePersistentDatabase() else { return }
        guard !DeltaAppPreferences.bool(for: DeltaAppPreferenceKeys.pausesScheduledBackups, default: false) else {
            alertMessage = "Scheduled backups are paused. Resume scheduled backups in Settings or run a manual backup from a profile."
            return
        }
        let coordinator = makeCoordinator(database: database)
        performBackgroundJobWork(
            activeOperation: ActiveOperation(
                kind: .backup,
                profileID: nil,
                repositoryID: nil,
                title: "Running scheduled backups",
                detail: "Checking due profiles and available destinations"
            )
        ) {
            try coordinator.runDueBackups()
        }
    }

    func refreshSnapshots(repository: BackupRepository) {
        guard let database = requirePersistentDatabase() else { return }
        let coordinator = makeCoordinator(database: database)
        performBackgroundWork(
            activeOperation: ActiveOperation(
                kind: .check,
                profileID: nil,
                repositoryID: repository.id,
                title: "Refreshing restore points",
                detail: "Reading snapshots from \(repository.name)"
            )
        ) {
            _ = try coordinator.refreshSnapshots(repository: repository)
        }
    }

    func snapshotEntryCacheKey(repositoryID: UUID, snapshotID: String, directoryPath: String?) -> String {
        "\(repositoryID.uuidString)|\(snapshotID)|\(directoryPath ?? "")"
    }

    func snapshotEntries(repositoryID: UUID, snapshotID: String, directoryPath: String?) -> [ResticSnapshotEntry]? {
        snapshotEntryCache[snapshotEntryCacheKey(repositoryID: repositoryID, snapshotID: snapshotID, directoryPath: directoryPath)]
    }

    func isLoadingSnapshotEntries(repositoryID: UUID, snapshotID: String, directoryPath: String?) -> Bool {
        snapshotEntryLoadingKeys.contains(snapshotEntryCacheKey(repositoryID: repositoryID, snapshotID: snapshotID, directoryPath: directoryPath))
    }

    func loadSnapshotEntries(repository: BackupRepository, snapshotID: String, directoryPath: String?, force: Bool = false) {
        guard let database = requirePersistentDatabase() else { return }
        guard !snapshotID.isEmpty else {
            return
        }
        guard !isWorking else {
            alertMessage = "Wait for the current Delta job to finish before browsing restore point contents."
            return
        }
        let key = snapshotEntryCacheKey(repositoryID: repository.id, snapshotID: snapshotID, directoryPath: directoryPath)
        if !force, snapshotEntryCache[key] != nil {
            return
        }
        guard !snapshotEntryLoadingKeys.contains(key) else {
            return
        }
        snapshotEntryLoadingKeys.insert(key)
        let coordinator = makeCoordinator(database: database)
        Task.detached(priority: .userInitiated) {
            do {
                let entries = try coordinator.listSnapshotEntries(
                    repository: repository,
                    snapshotID: snapshotID,
                    directoryPath: directoryPath
                )
                await MainActor.run {
                    self.snapshotEntryCache[key] = entries
                    self.snapshotEntryLoadingKeys.remove(key)
                }
            } catch {
                await MainActor.run {
                    self.snapshotEntryLoadingKeys.remove(key)
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func runRestore(repository: BackupRepository, request: RestoreRequest) {
        guard let database = requirePersistentDatabase() else { return }
        let coordinator = makeCoordinator(database: database)
        performBackgroundJobWork(
            activeOperation: ActiveOperation(
                kind: .restore,
                profileID: request.preRestoreBackupProfileID,
                repositoryID: repository.id,
                title: request.dryRun ? "Previewing restore" : "Restoring files",
                detail: "Reading from \(repository.name)"
            )
        ) {
            [try coordinator.restore(request: request, repository: repository)]
        }
    }

    func registerAgent() {
        launchAgentStatus = LaunchAgentController.status()
        synchronizeScheduledBackupsRegistration(hasEnabledSchedules: true, showsResultAlert: true)
    }

    func unregisterAgent() {
        do {
            try LaunchAgentController.unregister()
            launchAgentStatus = LaunchAgentController.status()
            scheduledBackupServiceError = nil
            DeltaAppPreferences.sharedStore().removeObject(
                forKey: DeltaAppPreferenceKeys.scheduledBackupServiceFingerprint
            )
            alertMessage = "Scheduled Backups were turned off."
        } catch {
            launchAgentStatus = LaunchAgentController.status()
            alertMessage = error.localizedDescription
        }
    }

    func registerAppLoginItem() {
        do {
            try AppLoginItemController.register()
            appLoginItemStatus = AppLoginItemController.status()
            alertMessage = appLoginItemRegistrationMessage(for: appLoginItemStatus)
        } catch {
            appLoginItemStatus = AppLoginItemController.status()
            alertMessage = error.localizedDescription
        }
    }

    func unregisterAppLoginItem() {
        do {
            try AppLoginItemController.unregister()
            appLoginItemStatus = AppLoginItemController.status()
            alertMessage = "Delta will no longer open automatically when you sign in."
        } catch {
            appLoginItemStatus = AppLoginItemController.status()
            alertMessage = error.localizedDescription
        }
    }

    func repairBackgroundSecretAccess() {
        guard let database = requirePersistentDatabase() else { return }
        guard !isWorking else {
            alertMessage = "Wait for the current Delta job to finish before repairing password access."
            return
        }
        guard !repositories.isEmpty else {
            alertMessage = "There are no saved destinations to repair."
            return
        }

        let repairer = RepositorySecretAccessRepairer(secretStore: secretStore)
        let reports = repositories.map { repairer.repair(repository: $0) }
        let checkedAccounts = reports.reduce(0) { $0 + $1.checkedAccounts }
        let repairedAccounts = reports.reduce(0) { $0 + $1.repairedAccounts }
        let failures = reports.flatMap(\.failures)
        let failedRepositories = reports.filter { !$0.isFullyAccessible }.map(\.repositoryName)

        do {
            if failures.isEmpty {
                let message = "Password access was repaired for \(repairedAccounts) saved \(repairedAccounts == 1 ? "secret" : "secrets") across \(reports.count) \(reports.count == 1 ? "destination" : "destinations")."
                try database.appendEvent(EventLog(level: .info, message: message))
                alertMessage = "\(message) Scheduled backups can read these secrets without interactive Keychain prompts."
            } else {
                let message = "Password access repaired \(repairedAccounts) of \(checkedAccounts) saved secrets. Review \(failedRepositories.joined(separator: ", "))."
                try database.appendEvent(EventLog(level: .warning, message: message))
                alertMessage = "\(message) The first failure was \(failures[0].purpose): \(failures[0].message)"
            }
            lastBackgroundSecretAccessCheckAt = nil
            reload()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func requestBackgroundBackupsIfNeeded(for profile: BackupProfile) {
        guard profile.schedule.isEnabled else {
            return
        }

        launchAgentStatus = LaunchAgentController.status()
        synchronizeScheduledBackupsRegistration(hasEnabledSchedules: true)
        try? database?.appendEvent(EventLog(level: .info, message: "Scheduled Backups registration was checked for scheduled profile '\(profile.name)'."))
    }

    private func synchronizeScheduledBackupsRegistration(
        hasEnabledSchedules: Bool? = nil,
        showsResultAlert: Bool = false
    ) {
        guard backgroundRegistrationTask == nil else { return }
        let hasEnabledSchedules = hasEnabledSchedules ?? profiles.contains { $0.schedule.isEnabled }
        guard hasEnabledSchedules else { return }

        let currentFingerprint = LaunchAgentRegistrationFingerprint.current()
        let registeredFingerprint = DeltaAppPreferences.string(
            for: DeltaAppPreferenceKeys.scheduledBackupServiceFingerprint,
            default: ""
        )
        let action = LaunchAgentRegistrationPolicy.action(
            status: launchAgentStatus,
            hasEnabledSchedules: hasEnabledSchedules,
            registeredFingerprint: registeredFingerprint.isEmpty ? nil : registeredFingerprint,
            currentFingerprint: currentFingerprint
        )

        guard let currentFingerprint else {
            scheduledBackupServiceError = "Delta could not verify its scheduled-backup service. Reinstall the app before relying on automatic backups."
            if showsResultAlert {
                alertMessage = scheduledBackupServiceError
            }
            return
        }

        guard action != .none else {
            scheduledBackupServiceError = nil
            if showsResultAlert {
                alertMessage = backgroundBackupsRegistrationMessage(for: launchAgentStatus)
            }
            return
        }

        backgroundRegistrationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.backgroundRegistrationTask = nil }
            do {
                switch action {
                case .none:
                    break
                case .register:
                    try LaunchAgentController.register()
                case .reregister:
                    try await LaunchAgentController.reregister()
                }

                let status = LaunchAgentController.status()
                self.publishIfChanged(&self.launchAgentStatus, status)
                if status == .enabled || status == .requiresApproval {
                    DeltaAppPreferences.sharedStore().set(
                        currentFingerprint,
                        forKey: DeltaAppPreferenceKeys.scheduledBackupServiceFingerprint
                    )
                }
                self.scheduledBackupServiceError = nil
                try? self.database?.appendEvent(
                    EventLog(
                        level: .info,
                        message: action == .reregister
                            ? "Scheduled Backups registration was refreshed for the installed Delta version."
                            : "Scheduled Backups registration was enabled."
                    )
                )
                if showsResultAlert {
                    self.alertMessage = self.backgroundBackupsRegistrationMessage(for: status)
                }
            } catch {
                let status = LaunchAgentController.status()
                self.publishIfChanged(&self.launchAgentStatus, status)
                let message = "Scheduled backups could not be enabled: \(error.localizedDescription)"
                self.scheduledBackupServiceError = message
                try? self.database?.appendEvent(EventLog(level: .error, message: message))
                if showsResultAlert {
                    self.alertMessage = message
                }
            }
        }
    }

    private func backgroundBackupsRegistrationMessage(for status: LaunchAgentRegistrationStatus) -> String {
        switch status {
        case .enabled:
            return "Scheduled Backups are on."
        case .requiresApproval:
            return "Scheduled Backups were added. Approve Delta in Login Items so scheduled backups can run while the main window is closed."
        case .notRegistered:
            return "Scheduled Backups are not on yet. Turn them on again or approve Delta in Login Items if macOS is waiting for approval."
        case .notFound:
            return "Scheduled Backups could not start because the scheduler is missing from the app bundle."
        case .unavailable:
            return "Scheduled Backups are unavailable on this macOS version."
        case .unknown:
            return "Scheduled Backups returned an unknown macOS status. Refresh status or review Login Items if scheduled backups do not run."
        }
    }

    private func appLoginItemRegistrationMessage(for status: LaunchAgentRegistrationStatus) -> String {
        switch status {
        case .enabled:
            return "Delta will open automatically when you sign in."
        case .requiresApproval:
            return "Delta was added to Login Items. Approve it in macOS Settings if macOS asks."
        case .notRegistered:
            return "Delta is not set to open at login yet. Turn it on again or approve it in Login Items if macOS is waiting for approval."
        case .notFound:
            return "Delta could not be added to Login Items because macOS could not find the app bundle."
        case .unavailable:
            return "Start at login is unavailable on this macOS version."
        case .unknown:
            return "Start at login returned an unknown macOS status. Refresh status or review Login Items if Delta does not open at sign-in."
        }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccessGuide.settingsURL)
    }

    func openLoginItemsSettings() {
        NSWorkspace.shared.open(LoginItemsGuide.settingsURL)
    }

    func openNotificationSettings() {
        NSWorkspace.shared.open(NotificationSettingsGuide.settingsURL)
    }

    func revealInstalledAppInFinder() {
        let installedApp = URL(fileURLWithPath: "/Applications/Delta.app")
        NSWorkspace.shared.activateFileViewerSelecting([installedApp])
    }

    func revealApplicationSupportFolder() {
        revealDirectory {
            try AppDirectories.applicationSupportDirectory()
        }
    }

    func revealLogFolder() {
        revealDirectory {
            try AppDirectories.logDirectory()
        }
    }

    func revealBackupToolsFolder() {
        let resticURL = ResticExecutableLocator().locate(in: Bundle.main)
        let toolsURL = resticURL.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([toolsURL])
    }

    func copyDiagnosticReport() {
        let report = makeDiagnosticReport()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        alertMessage = "Diagnostic report copied."
    }

    func exportDiagnosticReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = diagnosticReportFilename()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try makeDiagnosticReport().write(to: url, atomically: true, encoding: .utf8)
            alertMessage = "Diagnostic report exported."
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func pruneOperationalHistoryNow() {
        guard let database = requirePersistentDatabase() else { return }
        guard !isWorking else {
            alertMessage = "Wait for the current Delta job to finish before cleaning up activity history."
            return
        }

        do {
            let result = try OperationalHistoryMaintenance.prune(database: database)
            if result.totalDeleted > 0 {
                try? database.appendEvent(EventLog(level: .info, message: operationalHistoryPruneMessage(result)))
                alertMessage = "Cleaned up \(result.totalDeleted) old activity \(result.totalDeleted == 1 ? "item" : "items")."
            } else {
                alertMessage = "No old activity history needed cleanup."
            }
            lastOperationalHistoryPruneAt = Date()
            reload()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func chooseFolder(allowsMultipleSelection: Bool = false) -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map(\.path)
    }

    func chooseFile(allowsMultipleSelection: Bool = false) -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map(\.path)
    }

    private func revealDirectory(_ resolve: () throws -> URL) {
        do {
            let url = try resolve()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func pruneOperationalHistoryIfNeeded(now: Date = Date()) {
        guard let database else {
            return
        }
        if let lastOperationalHistoryPruneAt, now.timeIntervalSince(lastOperationalHistoryPruneAt) < 3_600 {
            return
        }
        lastOperationalHistoryPruneAt = now
        do {
            let result = try OperationalHistoryMaintenance.prune(database: database, now: now)
            if result.totalDeleted > 0 {
                try? database.appendEvent(EventLog(level: .info, message: operationalHistoryPruneMessage(result)))
            }
        } catch {
            try? database.appendEvent(EventLog(level: .warning, message: "Could not clean up old activity history: \(error.localizedDescription)"))
        }
    }

    private func refreshBackgroundSecretAccessStatusIfNeeded(
        repositories: [BackupRepository],
        now: Date = Date()
    ) {
        guard !repositories.isEmpty else {
            backgroundSecretAccessTask?.cancel()
            backgroundSecretAccessTask = nil
            publishIfChanged(&backgroundSecretAccessReports, [])
            lastBackgroundSecretAccessCheckAt = nil
            lastBackgroundSecretAccessSignature = ""
            return
        }

        let signature: String = repositories
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { repository in
                let credentialSignature: String = repository.credentialReferences
                    .map { "\($0.environmentKey):\($0.keychainAccount)" }
                    .sorted()
                    .joined(separator: String(","))
                return "\(repository.id.uuidString):\(repository.keychainAccount):\(credentialSignature)"
            }
            .joined(separator: String("|"))

        if let lastBackgroundSecretAccessCheckAt,
           signature == lastBackgroundSecretAccessSignature,
           now.timeIntervalSince(lastBackgroundSecretAccessCheckAt) < 60 {
            return
        }

        let repairer = RepositorySecretAccessRepairer(secretStore: secretStore)
        lastBackgroundSecretAccessCheckAt = now
        lastBackgroundSecretAccessSignature = signature
        backgroundSecretAccessTask?.cancel()
        backgroundSecretAccessTask = Task { [weak self] in
            let reports = await Task.detached(priority: .utility) {
                repositories.map { repairer.verify(repository: $0) }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.backgroundSecretAccessTask = nil
            guard self.lastBackgroundSecretAccessSignature == signature else { return }
            self.publishIfChanged(&self.backgroundSecretAccessReports, reports)
        }
    }

    private func operationalHistoryPruneMessage(_ result: OperationalHistoryPruneResult) -> String {
        "Activity history cleanup removed \(result.totalDeleted) old \(result.totalDeleted == 1 ? "item" : "items") from Delta's local database."
    }

    private func makeDiagnosticReport() -> String {
        DiagnosticReportBuilder().makeReport(snapshot: diagnosticSnapshot())
    }

    private func diagnosticSnapshot() -> DiagnosticReportSnapshot {
        guard let database else {
            return unavailableDiagnosticSnapshot()
        }
        return DiagnosticSnapshotCollector(database: database, bundle: .main)
            .snapshot(activeOperation: activeOperation.map { "\($0.kind.displayName): \($0.title)" })
    }

    private func unavailableDiagnosticSnapshot() -> DiagnosticReportSnapshot {
        let bundle = Bundle.main
        let info = bundle.infoDictionary ?? [:]
        let resticURL = ResticExecutableLocator().locate(in: bundle)
        let rcloneURL = resticURL.deletingLastPathComponent().appendingPathComponent("rclone")
        let fullDiskAccess = FullDiskAccessProbe().check()
        return DiagnosticReportSnapshot(
            generatedAt: Date(),
            appVersion: info["CFBundleShortVersionString"] as? String ?? "Unknown",
            buildVersion: info["CFBundleVersion"] as? String ?? "Unknown",
            bundleIdentifier: bundle.bundleIdentifier ?? "Unknown",
            bundlePath: bundle.bundleURL.path,
            executablePath: bundle.executableURL?.path ?? "Unknown",
            applicationSupportPath: (try? AppDirectories.applicationSupportDirectory().path) ?? "Unavailable",
            databasePath: (try? AppDirectories.databaseURL().path) ?? "Unavailable",
            logPath: (try? AppDirectories.logDirectory().path) ?? "Unavailable",
            fullDiskAccessStatus: fullDiskAccess.hasLikelyFullDiskAccess ? "Ready" : "Needs Access",
            backgroundBackupsStatus: LaunchAgentController.status().displayName,
            scheduledAutomationStatus: DeltaAppPreferences.bool(for: DeltaAppPreferenceKeys.pausesScheduledBackups, default: false) ? "Paused" : "Running",
            backgroundPasswordAccessStatus: "Unavailable",
            appLoginItemStatus: AppLoginItemController.status().displayName,
            notificationStatus: DeltaAppPreferences.bool(for: DeltaAppPreferenceKeys.sendsJobNotifications, default: false) ? "Enabled" : "Disabled",
            menuBarStatus: DeltaAppPreferences.bool(for: DeltaAppPreferenceKeys.showsMenuBarExtra, default: true) ? "Shown" : "Hidden",
            idleSleepProtectionStatus: DeltaAppPreferences.bool(for: DeltaAppPreferenceKeys.preventsIdleSleepDuringJobs, default: true) ? "Enabled" : "Disabled",
            operationalHistoryRetentionStatus: OperationalHistoryRetention.current().summaryText,
            backupFreshnessStatus: BackupFreshnessWarningThreshold
                .normalized(DeltaAppPreferences.integer(for: DeltaAppPreferenceKeys.backupFreshnessWarningHours, default: BackupFreshnessWarningThreshold.threeDays.rawValue))
                .summaryText,
            destinationVerificationStatus: DestinationVerificationWarningThreshold
                .normalized(DeltaAppPreferences.integer(for: DeltaAppPreferenceKeys.destinationVerificationWarningHours, default: DestinationVerificationWarningThreshold.thirtyDays.rawValue))
                .summaryText,
            destinationFreeSpaceStatus: DestinationFreeSpaceWarningThreshold
                .normalized(DeltaAppPreferences.integer(for: DeltaAppPreferenceKeys.destinationFreeSpaceWarningGiB, default: DestinationFreeSpaceWarningThreshold.fiftyGiB.rawValue))
                .summaryText,
            restoreDefaultsStatus: RestoreDefaults.current().summaryText,
            activeOperation: activeOperation.map { "\($0.kind.displayName): \($0.title)" } ?? persistentStoreErrorMessage ?? "Local app data unavailable",
            profileCount: 0,
            destinationCount: 0,
            restorePointCount: 0,
            recentJobCount: 0,
            tools: [
                DiagnosticToolSummary(
                    name: "restic",
                    path: resticURL.path,
                    isExecutable: FileManager.default.isExecutableFile(atPath: resticURL.path)
                ),
                DiagnosticToolSummary(
                    name: "rclone",
                    path: rcloneURL.path,
                    isExecutable: FileManager.default.isExecutableFile(atPath: rcloneURL.path)
                )
            ],
            destinations: [],
            profiles: [],
            recentJobs: []
        )
    }

    private func diagnosticReportFilename() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        return "Delta-Diagnostics-\(timestamp).md"
    }

    func chooseBackupSources(allowsMultipleSelection: Bool = false, includeSubvolumes: Bool = false) -> [BackupSource] {
        guard requirePersistentDatabase() != nil else { return [] }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return [] }
        do {
            return try panel.urls.map {
                try bookmarkStore.makeSource(from: $0, includeSubvolumes: includeSubvolumes)
            }
        } catch {
            alertMessage = error.localizedDescription
            return []
        }
    }

    func startupVolumeSource() -> BackupSource {
        volumeSourceFactory.startupVolumeSource()
    }

    func chooseBackupVolumeSources(allowsMultipleSelection: Bool = true) -> [BackupSource] {
        guard requirePersistentDatabase() != nil else { return [] }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.prompt = "Choose Volume"
        panel.message = "Choose any folder on the volume you want Delta to protect. Delta will back up that volume root without crossing into other volumes."
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard panel.runModal() == .OK else { return [] }
        return uniqueBackupSources(
            panel.urls.map { volumeSourceFactory.selectedVolumeSource(from: $0) }
        )
    }

    private func uniqueBackupSources(_ sources: [BackupSource]) -> [BackupSource] {
        var seenPaths = Set<String>()
        return sources.filter { source in
            seenPaths.insert(source.path).inserted
        }
    }

    private func performBackgroundWork(activeOperation: ActiveOperation, _ operation: @escaping @Sendable () throws -> Void) {
        performBackgroundJobWork(activeOperation: activeOperation) {
            try operation()
            return []
        }
    }

    private func performBackgroundJobWork(activeOperation: ActiveOperation, _ operation: @escaping @Sendable () throws -> [JobRun]) {
        guard requirePersistentDatabase() != nil else { return }
        runController.reset()
        localOperationIsRunning = true
        isWorking = true
        self.activeOperation = activeOperation
        activeJobID = nil
        activeStopRequest = nil
        activeProgress = nil
        activeDisplayedProgressFraction = nil
        liveLogLines.removeAll()
        lastLiveLogWasStatus = false
        Task.detached(priority: .userInitiated) {
            do {
                let completedJobs = try operation()
                await MainActor.run {
                    self.localOperationIsRunning = false
                    self.isWorking = false
                    self.activeOperation = nil
                    self.activeJobID = nil
                    self.activeStopRequest = nil
                    self.activeProgress = nil
                    self.activeDisplayedProgressFraction = nil
                    self.runController.reset()
                    self.reload()
                    self.notifyCompletedJobs(completedJobs)
                }
            } catch {
                await MainActor.run {
                    self.localOperationIsRunning = false
                    self.isWorking = false
                    self.activeOperation = nil
                    self.activeJobID = nil
                    self.activeStopRequest = nil
                    self.activeProgress = nil
                    self.activeDisplayedProgressFraction = nil
                    self.runController.reset()
                    self.alertMessage = error.localizedDescription
                    self.reload()
                }
            }
        }
    }

    private func notifyCompletedJobs(_ completedJobs: [JobRun]) {
        let settings = JobNotificationSettings(
            isEnabled: DeltaAppPreferences.bool(
                for: DeltaAppPreferenceKeys.sendsJobNotifications,
                default: false
            ),
            includesSuccessfulBackups: DeltaAppPreferences.bool(
                for: DeltaAppPreferenceKeys.sendsSuccessfulBackupNotifications,
                default: false
            )
        )
        guard settings.isEnabled else {
            return
        }

        let profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.name) })
        let repositoriesByID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0.name) })
        for job in completedJobs {
            let issues = database.flatMap { try? $0.fetchBackupIssues(jobID: job.id) } ?? []
            let warningIssuesAreAcknowledged = job.profileID.map {
                backupIssueAcknowledgmentStore.allAcknowledged(issues, profileID: $0)
            } ?? false
            guard let content = JobNotificationPolicy.content(
                for: job,
                settings: settings,
                profileName: job.profileID.flatMap { profilesByID[$0] },
                repositoryName: repositoriesByID[job.repositoryID],
                warningIssuesAreAcknowledged: warningIssuesAreAcknowledged
            ) else {
                continue
            }
            DeltaUserNotifier.deliver(content)
        }
    }

    private func makeCoordinator(database: DeltaDatabase) -> BackupCoordinator {
        BackupCoordinator(
            database: database,
            commandBuilder: ResticCommandBuilder(
                resticExecutableURL: ResticExecutableLocator().locate(),
                secretBridgeURL: Self.secretBridgeURL(),
                secretBridgeArguments: ["--secret-bridge"]
            ),
            runner: ResticRunner(runController: runController),
            runControlStore: runControlStore,
            outputHandler: { [weak self] jobID, event in
                Task { @MainActor [weak self] in
                    self?.activeJobID = jobID
                    self?.appendLiveLog(event)
                }
            }
        )
    }

    private func makeRepositoryPasswordManager() -> RepositoryPasswordManager {
        let secretStore = secretStore
        return RepositoryPasswordManager(
            commandBuilder: ResticCommandBuilder(
                resticExecutableURL: ResticExecutableLocator().locate(),
                secretBridgeURL: Self.secretBridgeURL(),
                secretBridgeArguments: ["--secret-bridge"]
            ),
            runner: ResticRunner(),
            loadSavedPassword: { account in
                try secretStore.load(account: account, authenticationPolicy: .failIfInteractionNeeded)
            },
            savePassword: { password, account in
                try secretStore.save(
                    secret: password,
                    account: account,
                    authenticationPolicy: .failIfInteractionNeeded
                )
            }
        )
    }

    private func knownRepositoryIDs() throws -> Set<UUID> {
        guard let database else {
            return []
        }
        return Set(try database.fetchRepositories().map(\.id))
    }

    private func requirePersistentDatabase() -> DeltaDatabase? {
        if let persistentStoreErrorMessage {
            alertMessage = persistentStoreErrorMessage
            return nil
        }
        guard let database else {
            let message = "Delta could not open its local database. Backup, destination, and restore actions are disabled until app data opens successfully."
            persistentStoreErrorMessage = message
            alertMessage = message
            return nil
        }
        return database
    }

    private func reopenPersistentStoreIfNeeded() -> Bool {
        guard persistentStoreErrorMessage != nil else {
            return true
        }
        do {
            database = try DeltaDatabase.live()
            persistentStoreErrorMessage = nil
            alertMessage = nil
            startDatabaseRefreshLoop()
            return true
        } catch {
            persistentStoreErrorMessage = Self.persistentStoreUnavailableMessage(for: error)
            alertMessage = persistentStoreErrorMessage
            return false
        }
    }

    private func requestActiveStop(_ reason: ResticRunStopReason) {
        activeStopRequest = reason
        if let activeJobID {
            do {
                try runControlStore.requestStop(jobID: activeJobID, reason: reason)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
        let event = ResticOutputEvent(stream: .standardOutput, message: reason.requestMessage)
        appendLiveLog(event)
        runController.requestStop(reason)
    }

    private func appendLiveLog(_ event: ResticOutputEvent) {
        let trimmed = event.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        let displayMessage = ResticLogFormatter.displayMessage(for: trimmed)
        let isStatusMessage = ResticLogFormatter.isStatusMessage(trimmed)
        let liveEvent = ResticOutputEvent(date: event.date, stream: event.stream, message: String(displayMessage.prefix(2_000)))
        if isStatusMessage, lastLiveLogWasStatus, !liveLogLines.isEmpty {
            liveLogLines[liveLogLines.count - 1] = liveEvent
        } else {
            liveLogLines.append(liveEvent)
        }
        lastLiveLogWasStatus = isStatusMessage
        if let progress = ResticLogFormatter.progressSnapshot(for: trimmed) {
            activeProgress = progress
            activeDisplayedProgressFraction = BackupProgressEstimator.displayedFraction(
                for: progress,
                previous: activeDisplayedProgressFraction
            )
        }
        if liveLogLines.count > 500 {
            liveLogLines.removeFirst(liveLogLines.count - 500)
        }
    }

    private static func secretBridgeURL() -> URL {
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        return FileManager.default.isExecutableFile(atPath: executable.path)
            ? executable
            : URL(fileURLWithPath: "/usr/bin/false")
    }

    private static func openDatabase() -> (database: DeltaDatabase?, errorMessage: String?) {
        do {
            return (try DeltaDatabase.live(), nil)
        } catch {
            return (nil, persistentStoreUnavailableMessage(for: error))
        }
    }

    private static func persistentStoreUnavailableMessage(for error: Error) -> String {
        "Delta could not open its Application Support database. Backup, destination, and restore actions are disabled to avoid using temporary state. \(error.localizedDescription)"
    }
}

enum DeltaUIError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message): message
        }
    }
}
