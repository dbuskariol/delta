import AppKit
import DeltaCore
import Foundation
import SwiftUI

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
    @Published var events: [EventLog] = []
    @Published var fullDiskAccessStatus = FullDiskAccessProbe().check()
    @Published var isWorking = false
    @Published var alertMessage: String?
    @Published var liveLogLines: [ResticOutputEvent] = []

    private let database: DeltaDatabase
    private let secretStore = KeychainSecretStore()
    private let credentialResolver = RepositoryCredentialResolver()
    private let bookmarkStore = SecurityScopedBookmarkStore()

    init() {
        let result = Self.openDatabase()
        database = result.database
        alertMessage = result.warning
        reload()
    }

    func reload() {
        do {
            repositories = try database.fetchRepositories()
            profiles = try database.fetchProfiles()
            jobs = try database.fetchJobRuns(limit: 100)
            jobLogs = try database.fetchJobLogs(limit: 300)
            snapshots = try database.fetchSnapshots()
            snapshotsByRepository = try database.fetchSnapshotsByRepository()
            events = try database.fetchEvents(limit: 200)
            fullDiskAccessStatus = FullDiskAccessProbe().check()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func createRepository(
        name: String,
        backend: RepositoryBackend,
        storageMode: SecretStorageMode = .appManagedKeychain,
        passphrase: String? = nil,
        backendCredentials: [String: String] = [:]
    ) {
        do {
            let repositoryID = UUID()
            let credentialReferences = try credentialResolver.saveCredentials(backendCredentials, repositoryID: repositoryID)
            let repository = BackupRepository(
                id: repositoryID,
                name: name,
                backend: backend,
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
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func saveRepository(
        _ repository: BackupRepository,
        name: String,
        backend: RepositoryBackend,
        backendCredentials: [String: String] = [:]
    ) {
        do {
            var updatedRepository = repository
            updatedRepository.name = name
            updatedRepository.backend = backend
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
        } catch {
            alertMessage = error.localizedDescription
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
        guard let repository = repositories.first(where: { $0.id == profile.repositoryID }) else {
            alertMessage = "Destination for this profile no longer exists."
            return
        }
        let coordinator = makeCoordinator()
        performBackgroundWork {
            _ = try coordinator.runBackup(profile: profile, repository: repository)
        }
    }

    func initializeRepository(_ repository: BackupRepository) {
        let coordinator = makeCoordinator()
        performBackgroundWork {
            _ = try coordinator.initializeRepository(repository)
        }
    }

    func checkRepository(_ repository: BackupRepository) {
        let coordinator = makeCoordinator()
        performBackgroundWork {
            _ = try coordinator.check(repository: repository, readDataSubset: "1/100")
        }
    }

    func prune(profile: BackupProfile) {
        guard let repository = repositories.first(where: { $0.id == profile.repositoryID }) else {
            alertMessage = "Destination for this profile no longer exists."
            return
        }
        let coordinator = makeCoordinator()
        performBackgroundWork {
            _ = try coordinator.forgetAndPrune(profile: profile, repository: repository)
        }
    }

    func runDueBackups() {
        let coordinator = makeCoordinator()
        performBackgroundWork {
            _ = try coordinator.runDueBackups()
        }
    }

    func refreshSnapshots(repository: BackupRepository) {
        let coordinator = makeCoordinator()
        performBackgroundWork {
            _ = try coordinator.refreshSnapshots(repository: repository)
        }
    }

    func runRestore(repository: BackupRepository, request: RestoreRequest) {
        let coordinator = makeCoordinator()
        performBackgroundWork {
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

    private func performBackgroundWork(_ operation: @escaping @Sendable () throws -> Void) {
        isWorking = true
        liveLogLines.removeAll()
        Task.detached(priority: .userInitiated) {
            do {
                try operation()
                await MainActor.run {
                    self.isWorking = false
                    self.reload()
                }
            } catch {
                await MainActor.run {
                    self.isWorking = false
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
            runner: ResticRunner(),
            outputHandler: { [weak self] _, event in
                Task { @MainActor [weak self] in
                    self?.appendLiveLog(event)
                }
            }
        )
    }

    private func appendLiveLog(_ event: ResticOutputEvent) {
        let trimmed = event.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        let displayMessage = ResticLogFormatter.displayMessage(for: trimmed)
        liveLogLines.append(ResticOutputEvent(date: event.date, stream: event.stream, message: String(displayMessage.prefix(2_000))))
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
