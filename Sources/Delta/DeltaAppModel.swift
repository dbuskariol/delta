import AppKit
import DeltaCore
import Foundation
import SwiftUI

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

    private let database: DeltaDatabase
    private let secretStore = KeychainSecretStore()
    private let credentialResolver = RepositoryCredentialResolver()
    private let bookmarkStore = SecurityScopedBookmarkStore()
    private let repositoryValidator = BackupRepositoryValidator()
    private let runController = ResticRunController()
    private let runControlStore = ResticRunControlStore()
    private var localOperationIsRunning = false
    private var databaseRefreshTask: Task<Void, Never>?
    private var lastLiveLogWasStatus = false

    init() {
        let result = Self.openDatabase()
        database = result.database
        alertMessage = result.warning
        reload()
        startDatabaseRefreshLoop()
    }

    deinit {
        databaseRefreshTask?.cancel()
    }

    func reload() {
        do {
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
        do {
            let validated = try repositoryValidator.validate(name: name, backend: backend)
            let repositoryID = UUID()
            let credentialReferences = try credentialResolver.saveCredentials(backendCredentials, repositoryID: repositoryID)
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
            case .userManagedPassphrase:
                guard let passphrase, !passphrase.isEmpty else {
                    throw DeltaUIError.message("An encryption passphrase is required for user-managed destinations.")
                }
                try secretStore.save(secret: passphrase, account: repository.keychainAccount)
            }
            try database.saveRepository(repository)
            try database.appendEvent(EventLog(level: .info, message: "Destination '\(repository.name)' was created."))
            reload()
            initializeRepository(repository)
            return true
        } catch {
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

    func createProfile(
        name: String,
        mode: BackupSourceMode,
        sources: [BackupSource],
        repositoryID: UUID,
        schedule: BackupSchedule,
        retention: RetentionPolicy = RetentionPolicy()
    ) {
        do {
            guard !sources.isEmpty else {
                throw DeltaUIError.message("Choose at least one source.")
            }
            let profile = BackupProfile(
                name: name,
                sourceMode: mode,
                sources: sources,
                repositoryID: repositoryID,
                schedule: schedule,
                retention: retention
            )
            try database.saveProfile(profile)
            try database.appendEvent(EventLog(level: .info, message: "Backup profile '\(profile.name)' was created."))
            reload()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func saveProfile(_ profile: BackupProfile) {
        do {
            try database.saveProfile(profile)
            try database.appendEvent(EventLog(level: .info, message: "Backup profile '\(profile.name)' was updated."))
            reload()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func deleteProfile(_ profile: BackupProfile) {
        do {
            try database.deleteProfile(id: profile.id)
            try database.appendEvent(EventLog(level: .info, message: "Backup profile '\(profile.name)' was removed."))
            reload()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func deleteRepository(_ repository: BackupRepository) {
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
        guard isWorking, activeOperation?.kind == .backup, activeStopRequest == nil else {
            return
        }
        requestActiveStop(.pause)
    }

    func cancelActiveJob() {
        guard isWorking, activeOperation != nil, activeStopRequest == nil else {
            return
        }
        requestActiveStop(.cancel)
    }

    func initializeRepository(_ repository: BackupRepository) {
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
            alertMessage = "DeltaAgent registration requested. macOS may ask for confirmation in Login Items."
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func unregisterAgent() {
        do {
            try LaunchAgentController.unregister()
            alertMessage = "DeltaAgent was unregistered."
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccessGuide.settingsURL)
    }

    func revealInstalledAppInFinder() {
        let installedApp = URL(fileURLWithPath: "/Applications/Delta.app")
        NSWorkspace.shared.activateFileViewerSelecting([installedApp])
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

    func chooseBackupSources(allowsMultipleSelection: Bool = false, includeSubvolumes: Bool = false) -> [BackupSource] {
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

    private func performBackgroundWork(activeOperation: ActiveOperation, _ operation: @escaping @Sendable () throws -> Void) {
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

    private static func openDatabase() -> (database: DeltaDatabase, warning: String?) {
        do {
            return (try DeltaDatabase.live(), nil)
        } catch {
            let fallbackURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Delta-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("Delta.sqlite")
            do {
                return (
                    try DeltaDatabase(url: fallbackURL),
                    "Delta could not open the Application Support database and is using a temporary session database. \(error.localizedDescription)"
                )
            } catch {
                preconditionFailure("Delta cannot create a database: \(error)")
            }
        }
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
