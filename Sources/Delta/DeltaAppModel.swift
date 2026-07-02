import AppKit
import DeltaCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
        case repositories = "Destinations"
        case restore = "Restore"
        case activity = "Activity"
        case settings = "Settings"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .dashboard: "rectangle.grid.2x2"
            case .backups: "externaldrive.badge.plus"
            case .repositories: "externaldrive.connected.to.line.below"
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
    @Published private(set) var snapshotEntryLoadingKey: String?
    @Published var events: [EventLog] = []
    @Published var fullDiskAccessStatus = FullDiskAccessProbe().check()
    @Published var isWorking = false
    @Published var alertMessage: String?
    @Published var liveLogLines: [ResticOutputEvent] = []
    @Published var activeOperation: ActiveOperation?
    @Published var activeJobID: UUID?
    @Published var activeProgress: ResticProgressSnapshot?
    @Published var activeStopRequest: ResticRunStopReason?
    @Published private(set) var persistentStoreErrorMessage: String?
    @Published private(set) var launchAgentStatus = LaunchAgentController.status()

    var isPersistentStoreAvailable: Bool {
        persistentStoreErrorMessage == nil
    }

    var scheduledBackupsNeedAgentSetup: Bool {
        profiles.contains { $0.schedule.isEnabled } && launchAgentStatus.blocksScheduledBackups
    }

    private var database: DeltaDatabase
    private let secretStore = KeychainSecretStore()
    private let credentialResolver = RepositoryCredentialResolver()
    private let bookmarkStore = SecurityScopedBookmarkStore()
    private let volumeSourceFactory = BackupVolumeSourceFactory()
    private let repositoryValidator = BackupRepositoryValidator()
    private let profileValidator = BackupProfileValidator()
    private let runController = ResticRunController()
    private let runControlStore = ResticRunControlStore()
    private var localOperationIsRunning = false
    private var databaseRefreshTask: Task<Void, Never>?
    private var lastLiveLogWasStatus = false

    init() {
        let result = Self.openDatabase()
        database = result.database
        persistentStoreErrorMessage = result.errorMessage
        alertMessage = result.errorMessage
        if result.errorMessage == nil {
            reload()
            startDatabaseRefreshLoop()
        }
    }

    deinit {
        databaseRefreshTask?.cancel()
    }

    func reload() {
        guard reopenPersistentStoreIfNeeded() else {
            fullDiskAccessStatus = FullDiskAccessProbe().check()
            launchAgentStatus = LaunchAgentController.status()
            return
        }
        do {
            if !localOperationIsRunning {
                _ = try makeCoordinator().recoverAbandonedRunningJobs()
            }
            let storedRepositories = try database.fetchRepositories()
            let storedProfiles = try database.fetchProfiles()
            let storedJobs = try database.fetchJobRuns(limit: 100)
            let storedJobLogs = try database.fetchJobLogs(limit: 300)
            repositories = storedRepositories
            profiles = storedProfiles
            jobs = storedJobs
            jobLogs = storedJobLogs
            snapshots = try database.fetchSnapshots()
            snapshotsByRepository = try database.fetchSnapshotsByRepository()
            events = try database.fetchEvents(limit: 200)
            fullDiskAccessStatus = FullDiskAccessProbe().check()
            launchAgentStatus = LaunchAgentController.status()
            reconcileObservedActiveJob(
                jobs: storedJobs,
                jobLogs: storedJobLogs,
                profiles: storedProfiles,
                repositories: storedRepositories
            )
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func startDatabaseRefreshLoop() {
        databaseRefreshTask?.cancel()
        databaseRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    self?.reload()
                }
            }
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
        activeProgress = nil
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

    func savedLogs(for jobID: UUID, limit: Int = 10_000) -> [JobLogEntry] {
        guardPersistentStoreAvailable()
        guard isPersistentStoreAvailable else { return [] }
        do {
            return try database.fetchJobLogs(jobID: jobID, limit: limit)
        } catch {
            alertMessage = error.localizedDescription
            return []
        }
    }

    @discardableResult
    func createRepository(
        name: String,
        backend: RepositoryBackend,
        storageMode: SecretStorageMode = .appManagedKeychain,
        passphrase: String? = nil,
        backendCredentials: [String: String] = [:]
    ) -> Bool {
        guardPersistentStoreAvailable()
        guard isPersistentStoreAvailable else { return false }
        var rollbackSecretAccounts = Set<String>()
        var didPersistRepository = false
        let userManagedPassphrase = passphrase ?? ""
        do {
            let validated = try repositoryValidator.validate(name: name, backend: backend)
            let repositoryID = UUID()
            if storageMode == .userManagedPassphrase {
                guard !userManagedPassphrase.isEmpty else {
                    throw DeltaUIError.message("An encryption passphrase is required for user-managed destinations.")
                }
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
            didPersistRepository = true
            try? database.appendEvent(EventLog(level: .info, message: "Destination '\(repository.name)' was created."))
            reload()
            initializeRepository(repository)
            return true
        } catch {
            if !didPersistRepository {
                rollbackSecrets(accounts: rollbackSecretAccounts)
            }
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
        guardPersistentStoreAvailable()
        guard isPersistentStoreAvailable else { return false }
        do {
            let validated = try repositoryValidator.validate(
                name: name,
                backend: backend,
                validateLocalAvailability: backend != repository.backend
            )
            var updatedRepository = repository
            updatedRepository.name = validated.name
            updatedRepository.backend = validated.backend
            updatedRepository.credentialReferences = try credentialResolver.updateCredentials(
                backendCredentials,
                existingReferences: repository.credentialReferences,
                repositoryID: repository.id,
                allowedKeys: ResticBackendCredentialTemplates.keys(for: backend.kind)
            )
            if updatedRepository.backend != repository.backend || updatedRepository.credentialReferences != repository.credentialReferences {
                updatedRepository.lastVerifiedAt = nil
            }
            try database.saveRepository(updatedRepository)
            try database.appendEvent(EventLog(level: .info, message: "Destination '\(updatedRepository.name)' was updated."))
            reload()
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    private func rollbackSecrets(accounts: Set<String>) {
        for account in accounts {
            try? secretStore.delete(account: account)
        }
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
        guardPersistentStoreAvailable()
        guard isPersistentStoreAvailable else { return }
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
        guardPersistentStoreAvailable()
        guard isPersistentStoreAvailable else { return }
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

    func deleteProfile(_ profile: BackupProfile) {
        guardPersistentStoreAvailable()
        guard isPersistentStoreAvailable else { return }
        do {
            try database.deleteProfile(id: profile.id)
            try database.appendEvent(EventLog(level: .info, message: "Backup profile '\(profile.name)' was removed."))
            reload()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func deleteRepository(_ repository: BackupRepository) {
        guardPersistentStoreAvailable()
        guard isPersistentStoreAvailable else { return }
        do {
            let currentProfiles = try database.fetchProfiles()
            guard !currentProfiles.contains(where: { $0.repositoryID == repository.id }) else {
                throw DeltaUIError.message("This destination is still used by one or more backup profiles.")
            }
            try secretStore.delete(account: repository.keychainAccount)
            for reference in repository.credentialReferences {
                try secretStore.delete(account: reference.keychainAccount)
            }
            try database.deleteRepository(id: repository.id)
            try database.appendEvent(EventLog(level: .info, message: "Destination '\(repository.name)' was removed from Delta."))
            reload()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func runNow(profile: BackupProfile) {
        startBackup(profile: profile, isResume: false)
    }

    func resumeBackup(profile: BackupProfile) {
        startBackup(profile: profile, isResume: true)
    }

    private func startBackup(profile: BackupProfile, isResume: Bool) {
        guardPersistentStoreAvailable()
        guard isPersistentStoreAvailable else { return }
        guard let repository = repositories.first(where: { $0.id == profile.repositoryID }) else {
            alertMessage = "Destination for this profile no longer exists."
            return
        }
        let coordinator = makeCoordinator()
        performBackgroundWork(
            activeOperation: ActiveOperation(
                kind: .backup,
                profileID: profile.id,
                repositoryID: repository.id,
                title: "\(isResume ? "Resuming" : "Backing up") \(profile.name)",
                detail: "\(isResume ? "Continuing backup to" : "Saving to") \(repository.name)"
            )
        ) {
            _ = try coordinator.runBackup(profile: profile, repository: repository)
        }
    }

    func pauseActiveBackup() {
        guardPersistentStoreAvailable()
        guard isPersistentStoreAvailable else { return }
        guard isWorking, activeOperation?.kind == .backup, activeStopRequest == nil else {
            return
        }
        requestActiveStop(.pause)
    }

    func cancelActiveJob() {
        guardPersistentStoreAvailable()
        guard isPersistentStoreAvailable else { return }
        guard isWorking, activeOperation != nil, activeStopRequest == nil else {
            return
        }
        requestActiveStop(.cancel)
    }

    func initializeRepository(_ repository: BackupRepository) {
        guardPersistentStoreAvailable()
        guard isPersistentStoreAvailable else { return }
        let coordinator = makeCoordinator()
        performBackgroundWork(
            activeOperation: ActiveOperation(
                kind: .initializeRepository,
                profileID: nil,
                repositoryID: repository.id,
                title: "Preparing \(repository.name)",
                detail: "Creating encrypted destination metadata"
            )
        ) {
            _ = try coordinator.initializeRepository(repository)
        }
    }

    func checkRepository(_ repository: BackupRepository) {
        guardPersistentStoreAvailable()
        guard isPersistentStoreAvailable else { return }
        let coordinator = makeCoordinator()
        performBackgroundWork(
            activeOperation: ActiveOperation(
                kind: .check,
                profileID: nil,
                repositoryID: repository.id,
                title: "Checking \(repository.name)",
                detail: "Verifying destination integrity"
            )
        ) {
            _ = try coordinator.check(repository: repository, readDataSubset: "1/100")
        }
    }

    func prune(profile: BackupProfile) {
        guardPersistentStoreAvailable()
        guard isPersistentStoreAvailable else { return }
        guard let repository = repositories.first(where: { $0.id == profile.repositoryID }) else {
            alertMessage = "Destination for this profile no longer exists."
            return
        }
        let coordinator = makeCoordinator()
        performBackgroundWork(
            activeOperation: ActiveOperation(
                kind: .prune,
                profileID: profile.id,
                repositoryID: repository.id,
                title: "Cleaning up \(profile.name)",
                detail: "Applying retention rules to \(repository.name)"
            )
        ) {
            _ = try coordinator.forgetAndPrune(profile: profile, repository: repository)
        }
    }

    func runDueBackups() {
        guardPersistentStoreAvailable()
        guard isPersistentStoreAvailable else { return }
        let coordinator = makeCoordinator()
        performBackgroundWork(
            activeOperation: ActiveOperation(
                kind: .backup,
                profileID: nil,
                repositoryID: nil,
                title: "Running scheduled backups",
                detail: "Checking due profiles and available destinations"
            )
        ) {
            _ = try coordinator.runDueBackups()
        }
    }

    func refreshSnapshots(repository: BackupRepository) {
        guardPersistentStoreAvailable()
        guard isPersistentStoreAvailable else { return }
        let coordinator = makeCoordinator()
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
        snapshotEntryLoadingKey == snapshotEntryCacheKey(repositoryID: repositoryID, snapshotID: snapshotID, directoryPath: directoryPath)
    }

    func loadSnapshotEntries(repository: BackupRepository, snapshotID: String, directoryPath: String?, force: Bool = false) {
        guardPersistentStoreAvailable()
        guard isPersistentStoreAvailable else { return }
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
        snapshotEntryLoadingKey = key
        let coordinator = makeCoordinator()
        Task.detached(priority: .userInitiated) {
            do {
                let entries = try coordinator.listSnapshotEntries(
                    repository: repository,
                    snapshotID: snapshotID,
                    directoryPath: directoryPath
                )
                await MainActor.run {
                    guard self.snapshotEntryLoadingKey == key else {
                        return
                    }
                    self.snapshotEntryCache[key] = entries
                    self.snapshotEntryLoadingKey = nil
                }
            } catch {
                await MainActor.run {
                    guard self.snapshotEntryLoadingKey == key else {
                        return
                    }
                    self.snapshotEntryLoadingKey = nil
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func runRestore(repository: BackupRepository, request: RestoreRequest) {
        guardPersistentStoreAvailable()
        guard isPersistentStoreAvailable else { return }
        let coordinator = makeCoordinator()
        performBackgroundWork(
            activeOperation: ActiveOperation(
                kind: .restore,
                profileID: request.preRestoreBackupProfileID,
                repositoryID: repository.id,
                title: request.dryRun ? "Previewing restore" : "Restoring files",
                detail: "Reading from \(repository.name)"
            )
        ) {
            _ = try coordinator.restore(request: request, repository: repository)
        }
    }

    func registerAgent() {
        do {
            try LaunchAgentController.register()
            launchAgentStatus = LaunchAgentController.status()
            alertMessage = backgroundBackupsRegistrationMessage(for: launchAgentStatus)
        } catch {
            launchAgentStatus = LaunchAgentController.status()
            alertMessage = error.localizedDescription
        }
    }

    func unregisterAgent() {
        do {
            try LaunchAgentController.unregister()
            launchAgentStatus = LaunchAgentController.status()
            alertMessage = "Background Backups were turned off."
        } catch {
            launchAgentStatus = LaunchAgentController.status()
            alertMessage = error.localizedDescription
        }
    }

    func repairBackgroundSecretAccess() {
        guardPersistentStoreAvailable()
        guard isPersistentStoreAvailable else { return }
        guard !isWorking else {
            alertMessage = "Wait for the current Delta job to finish before repairing background secret access."
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
                let message = "Background secret access was repaired for \(repairedAccounts) saved \(repairedAccounts == 1 ? "secret" : "secrets") across \(reports.count) \(reports.count == 1 ? "destination" : "destinations")."
                try database.appendEvent(EventLog(level: .info, message: message))
                alertMessage = "\(message) Scheduled backups can read these secrets without interactive Keychain prompts."
            } else {
                let message = "Background secret access repaired \(repairedAccounts) of \(checkedAccounts) saved secrets. Review \(failedRepositories.joined(separator: ", "))."
                try database.appendEvent(EventLog(level: .warning, message: message))
                alertMessage = "\(message) The first failure was \(failures[0].purpose): \(failures[0].message)"
            }
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
        if launchAgentStatus == .notRegistered {
            do {
                try LaunchAgentController.register()
                launchAgentStatus = LaunchAgentController.status()
                try? database.appendEvent(EventLog(level: .info, message: "Background Backups registration was requested for scheduled profile '\(profile.name)'."))
            } catch {
                launchAgentStatus = LaunchAgentController.status()
                alertMessage = "Scheduled backups were saved, but Background Backups could not be requested: \(error.localizedDescription)"
                return
            }
        }

        if launchAgentStatus.blocksScheduledBackups {
            alertMessage = "Scheduled backups were saved. \(launchAgentStatus.detail)"
        }
    }

    private func backgroundBackupsRegistrationMessage(for status: LaunchAgentRegistrationStatus) -> String {
        switch status {
        case .enabled:
            return "Background Backups are on."
        case .requiresApproval:
            return "Background Backups were added. Approve Delta in Login Items so scheduled backups can run while the main window is closed."
        case .notRegistered:
            return "Background Backups are not on yet. Turn them on again or approve Delta in Login Items if macOS is waiting for approval."
        case .notFound:
            return "Background Backups could not start because the helper is missing from the app bundle."
        case .unavailable:
            return "Background Backups are unavailable on this macOS version."
        case let .unknown(rawValue):
            return "Background Backups returned an unknown macOS status: \(rawValue)"
        }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccessGuide.settingsURL)
    }

    func openLoginItemsSettings() {
        NSWorkspace.shared.open(LoginItemsGuide.settingsURL)
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

    func chooseFolder(allowsMultipleSelection: Bool = false) -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
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

    private func makeDiagnosticReport() -> String {
        DiagnosticReportBuilder().makeReport(snapshot: diagnosticSnapshot())
    }

    private func diagnosticSnapshot() -> DiagnosticReportSnapshot {
        let bundle = Bundle.main
        let info = bundle.infoDictionary ?? [:]
        let resticURL = ResticExecutableLocator().locate(in: bundle)
        let rcloneURL = resticURL.deletingLastPathComponent().appendingPathComponent("rclone")
        let recentJobs = jobs
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(10)
            .map {
                DiagnosticJobSummary(
                    kind: $0.kind.displayName,
                    status: $0.status.rawValue,
                    startedAt: $0.startedAt,
                    exitCode: $0.exitCode,
                    message: $0.message
                )
            }

        return DiagnosticReportSnapshot(
            generatedAt: Date(),
            appVersion: info["CFBundleShortVersionString"] as? String ?? "Unknown",
            buildVersion: info["CFBundleVersion"] as? String ?? "Unknown",
            bundleIdentifier: bundle.bundleIdentifier ?? "Unknown",
            bundlePath: bundle.bundleURL.path,
            executablePath: bundle.executableURL?.path ?? "Unknown",
            applicationSupportPath: diagnosticPath { try AppDirectories.applicationSupportDirectory() },
            databasePath: diagnosticPath { try AppDirectories.databaseURL() },
            logPath: diagnosticPath { try AppDirectories.logDirectory() },
            fullDiskAccessStatus: fullDiskAccessStatus.hasLikelyFullDiskAccess ? "Ready" : "Needs Access",
            backgroundBackupsStatus: launchAgentStatus.displayName,
            activeOperation: activeOperation.map { "\($0.kind.displayName): \($0.title)" },
            profileCount: profiles.count,
            destinationCount: repositories.count,
            restorePointCount: snapshots.count,
            recentJobCount: jobs.count,
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
            destinations: repositories.map {
                DiagnosticDestinationSummary(
                    name: $0.name,
                    kind: $0.backend.kind.displayName,
                    lastVerifiedAt: $0.lastVerifiedAt
                )
            },
            profiles: profiles.map {
                DiagnosticProfileSummary(
                    name: $0.name,
                    sourceMode: $0.sourceMode.displayName,
                    sourceCount: $0.sources.count,
                    scheduleEnabled: $0.schedule.isEnabled,
                    customExcludeCount: BackupExcludePatternParser.customPatterns(from: $0.excludePatterns).count
                )
            },
            recentJobs: Array(recentJobs)
        )
    }

    private func diagnosticPath(_ resolve: () throws -> URL) -> String {
        do {
            return try resolve().path
        } catch {
            return "Unavailable: \(error.localizedDescription)"
        }
    }

    private func diagnosticReportFilename() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        return "Delta-Diagnostics-\(timestamp).md"
    }

    func chooseBackupSources(allowsMultipleSelection: Bool = false, includeSubvolumes: Bool = false) -> [BackupSource] {
        guardPersistentStoreAvailable()
        guard isPersistentStoreAvailable else { return [] }
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
        guardPersistentStoreAvailable()
        guard isPersistentStoreAvailable else { return [] }
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
        guardPersistentStoreAvailable()
        guard isPersistentStoreAvailable else { return }
        runController.reset()
        localOperationIsRunning = true
        isWorking = true
        self.activeOperation = activeOperation
        activeJobID = nil
        activeStopRequest = nil
        activeProgress = nil
        liveLogLines.removeAll()
        lastLiveLogWasStatus = false
        Task.detached(priority: .userInitiated) {
            do {
                try operation()
                await MainActor.run {
                    self.localOperationIsRunning = false
                    self.isWorking = false
                    self.activeOperation = nil
                    self.activeJobID = nil
                    self.activeStopRequest = nil
                    self.activeProgress = nil
                    self.runController.reset()
                    self.reload()
                }
            } catch {
                await MainActor.run {
                    self.localOperationIsRunning = false
                    self.isWorking = false
                    self.activeOperation = nil
                    self.activeJobID = nil
                    self.activeStopRequest = nil
                    self.activeProgress = nil
                    self.runController.reset()
                    self.alertMessage = error.localizedDescription
                    self.reload()
                }
            }
        }
    }

    private func makeCoordinator() -> BackupCoordinator {
        BackupCoordinator(
            database: database,
            commandBuilder: ResticCommandBuilder(
                resticExecutableURL: ResticExecutableLocator().locate(),
                secretBridgeURL: Self.secretBridgeURL()
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

    private func knownRepositoryIDs() throws -> Set<UUID> {
        Set(try database.fetchRepositories().map(\.id))
    }

    private func guardPersistentStoreAvailable() {
        if let persistentStoreErrorMessage {
            alertMessage = persistentStoreErrorMessage
        }
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
        }
        if liveLogLines.count > 500 {
            liveLogLines.removeFirst(liveLogLines.count - 500)
        }
    }

    private static func secretBridgeURL() -> URL {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "DeltaSecretBridge") {
            return bundled
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        let sibling = executable.deletingLastPathComponent().appendingPathComponent("DeltaSecretBridge")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        return URL(fileURLWithPath: "/usr/bin/false")
    }

    private static func openDatabase() -> (database: DeltaDatabase, errorMessage: String?) {
        do {
            return (try DeltaDatabase.live(), nil)
        } catch {
            let fallbackURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Delta-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("Delta.sqlite")
            do {
                return (
                    try DeltaDatabase(url: fallbackURL),
                    persistentStoreUnavailableMessage(for: error)
                )
            } catch {
                preconditionFailure("Delta cannot create a database: \(error)")
            }
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
