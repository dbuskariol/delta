import DeltaCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: DeltaAppModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(DeltaAppModel.Section.allCases, selection: $model.selectedSection) { section in
                    Label(section.rawValue, systemImage: section.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .tag(section)
                        .padding(.vertical, 2)
                }
                .scrollContentBackground(.hidden)

                SidebarStatusView(isWorking: model.isWorking)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 280)
        } detail: {
            switch model.selectedSection {
            case .dashboard:
                DashboardView()
            case .backups:
                BackupsView()
            case .repositories:
                RepositoriesView()
            case .restore:
                RestoreView()
            case .activity:
                ActivityView()
            case .settings:
                SettingsView()
            }
        }
        .background(DeltaTheme.background)
        .alert("Delta", isPresented: alertBinding) {
            Button("OK") {
                model.alertMessage = nil
            }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { model.alertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    model.alertMessage = nil
                }
            }
        )
    }
}

struct DashboardView: View {
    @EnvironmentObject private var model: DeltaAppModel

    var body: some View {
        PageScaffold(
            title: "Dashboard",
            subtitle: "Encrypted, deduplicated backup operations",
            actions: {
                Button {
                    model.runDueBackups()
                } label: {
                    Label(model.isWorking ? "Running" : "Run due", systemImage: model.isWorking ? "arrow.triangle.2.circlepath" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.profiles.isEmpty || model.isWorking || !model.isPersistentStoreAvailable)
                .deltaTooltip(model.isWorking ? "A Delta job is already running." : "Run every backup profile that is currently due.")
            }
        ) {
            LazyVGrid(columns: DeltaTheme.statColumns, spacing: 12) {
                StatPanel(title: "Profiles", value: "\(model.profiles.count)", symbol: "externaldrive.badge.plus")
                StatPanel(title: "Destinations", value: "\(model.repositories.count)", symbol: "externaldrive.connected.to.line.below")
                StatPanel(title: "Restore Points", value: "\(model.snapshots.count)", symbol: "clock.arrow.circlepath")
                StatPanel(title: "Recent Jobs", value: "\(model.jobs.count)", symbol: "waveform.path.ecg")
            }

            if let persistentStoreErrorMessage = model.persistentStoreErrorMessage {
                Card {
                    HStack(alignment: .top, spacing: 14) {
                        StatusIcon(symbol: "externaldrive.badge.exclamationmark", color: .red)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Storage Unavailable")
                                .font(.headline)
                            Text(persistentStoreErrorMessage)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        StateBadge(text: "Blocked", color: .red)
                    }
                }
            }

            if let operation = model.activeOperation {
                ActiveOperationBanner(
                    operation: operation,
                    progress: model.activeProgress,
                    latestMessage: model.liveLogLines.last?.message,
                    stopRequest: model.activeStopRequest,
                    onPause: operation.kind == .backup ? { model.pauseActiveBackup() } : nil,
                    onCancel: { model.cancelActiveJob() }
                )
            }

            if !model.fullDiskAccessStatus.hasLikelyFullDiskAccess {
                Card {
                    HStack(alignment: .top, spacing: 14) {
                        StatusIcon(symbol: "lock.shield", color: .orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Readiness")
                                .font(.headline)
                            Text("Full Disk Access has not been confirmed. Full-volume backups may miss protected data.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StateBadge(text: "Needs Access", color: .orange)
                    }
                }
            }

            SectionHeader(title: "Backup Profiles")
            if model.profiles.isEmpty {
                EmptyStateView(
                    symbol: "externaldrive.badge.plus",
                    title: "No backup profiles",
                    message: "Create a backup profile after adding a storage destination."
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(model.profiles) { profile in
                        ProfileRow(profile: profile, showsInlineProgress: false)
                    }
                }
            }
        }
    }
}

struct BackupsView: View {
    @EnvironmentObject private var model: DeltaAppModel
    @State private var isPresentingProfileSheet = false

    var body: some View {
        PageScaffold(
            title: "Backups",
            subtitle: "Sources, schedules, and retention",
            actions: {
                Button {
                    isPresentingProfileSheet = true
                } label: {
                    Label("New profile", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.repositories.isEmpty || !model.isPersistentStoreAvailable)
            }
        ) {
            if model.repositories.isEmpty {
                EmptyStateView(
                    symbol: "shippingbox",
                    title: "Create a destination first",
                    message: "Backups need a local drive, mounted network drive, or cloud destination."
                )
            } else if model.profiles.isEmpty {
                EmptyStateView(
                    symbol: "externaldrive.badge.plus",
                    title: "No profiles yet",
                    message: "Create a profile for a full volume or selected folders."
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(model.profiles) { profile in
                        ProfileRow(profile: profile)
                    }
                }
            }
        }
        .sheet(isPresented: $isPresentingProfileSheet) {
            ProfileEditorView()
                .environmentObject(model)
                .frame(width: ModalMetrics.sheetWidth, height: 680)
        }
    }
}

struct RepositoriesView: View {
    @EnvironmentObject private var model: DeltaAppModel
    @State private var isPresentingRepositorySheet = false

    var body: some View {
        PageScaffold(
            title: "Destinations",
            subtitle: "Where encrypted backups are stored",
            actions: {
                Button {
                    isPresentingRepositorySheet = true
                } label: {
                    Label("New destination", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isPersistentStoreAvailable)
            }
        ) {
            if model.repositories.isEmpty {
                EmptyStateView(
                    symbol: "shippingbox",
                    title: "No destinations",
                    message: "Add a drive, NAS path, or cloud location to store encrypted restore points."
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(model.repositories) { repository in
                        RepositoryRow(repository: repository)
                    }
                }
            }
        }
        .sheet(isPresented: $isPresentingRepositorySheet) {
            RepositoryEditorView()
                .environmentObject(model)
                .frame(width: ModalMetrics.sheetWidth)
        }
    }
}

struct RestoreView: View {
    @EnvironmentObject private var model: DeltaAppModel
    @State private var repositoryID: UUID?
    @State private var snapshotID = ""
    @State private var selectedRestorePaths: Set<String> = []
    @State private var browserPathStack: [String] = []
    @State private var destinationPath = ""
    @State private var restoreOriginalPaths = false
    @State private var conflictPolicy: RestoreConflictPolicy = .ifChanged
    @State private var dryRun = true
    @State private var verify = true
    @State private var preRestoreProfileID: UUID?
    @State private var acknowledgedInPlaceRestore = false

    var body: some View {
        PageScaffold(
            title: "Restore",
            subtitle: "Recover complete restore points or specific paths",
            actions: {
                Button {
                    if let repository = selectedRepository {
                        model.refreshSnapshots(repository: repository)
                    }
                } label: {
                    Label("Refresh Points", systemImage: "arrow.clockwise")
                }
                .disabled(selectedRepository == nil || model.isWorking)
            }
        ) {
            RestoreStepCard(number: 1, title: "Restore Point", subtitle: "Choose where the backup is stored and the point in time.") {
                RestoreForm {
                    RestoreFormRow(title: "Destination") {
                        Picker("Destination", selection: $repositoryID) {
                            Text("Choose").tag(UUID?.none)
                            ForEach(model.repositories) { repository in
                                Text(repository.name).tag(Optional(repository.id))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 300, alignment: .leading)
                    }

                    RestoreFormRow(title: "Restore Point") {
                        Picker("Restore Point", selection: $snapshotID) {
                            Text("Choose").tag("")
                            ForEach(repositorySnapshots) { snapshot in
                                Text("\(snapshot.time.formatted(date: .abbreviated, time: .shortened))  \(snapshot.id.prefix(8))").tag(snapshot.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 420, alignment: .leading)
                    }
                }
            }

            RestoreStepCard(number: 2, title: "Scope", subtitle: "Restore everything from that point, or limit recovery to selected paths.") {
                SnapshotBrowserPanel(
                    entries: browserEntries,
                    selectedPaths: $selectedRestorePaths,
                    currentPath: currentBrowserDirectory,
                    selectedCount: normalizedSelectedRestorePaths.count,
                    isLoading: isLoadingBrowserEntries,
                    canBrowse: canBrowseSnapshot,
                    emptyMessage: browserEmptyMessage,
                    onOpen: openBrowserDirectory,
                    onBack: navigateBrowserBack,
                    onRefresh: refreshCurrentBrowserDirectory,
                    onClearSelection: clearRestoreSelection
                )
            }

            RestoreStepCard(number: 3, title: "Destination", subtitle: "Preview by default, then restore to a chosen folder or original paths.") {
                VStack(alignment: .leading, spacing: 14) {
                    RestoreFormRow(title: "") {
                        Toggle("Restore to original paths", isOn: $restoreOriginalPaths)
                            .toggleStyle(.checkbox)
                    }

                    if restoreOriginalPaths && !dryRun {
                        InlineWarning(
                            symbol: "exclamationmark.triangle",
                            title: "In-place restore can overwrite current files.",
                            message: "Create a pre-restore backup and confirm this operation before continuing."
                        )
                        RestoreFormRow(title: "") {
                            Toggle("I understand this in-place restore can overwrite current files.", isOn: $acknowledgedInPlaceRestore)
                                .toggleStyle(.checkbox)
                        }
                    }

                    RestoreFormRow(title: "Destination") {
                        HStack(spacing: 8) {
                            TextField("Destination folder", text: $destinationPath)
                                .textFieldStyle(.roundedBorder)
                                .disabled(restoreOriginalPaths)
                            Button {
                                if let path = model.chooseFolder().first {
                                    destinationPath = path
                                }
                            } label: {
                                Image(systemName: "folder")
                            }
                            .disabled(restoreOriginalPaths)
                            .deltaTooltip("Choose destination folder")
                        }
                    }

                    RestoreFormRow(title: "Conflicts") {
                        Picker("Conflicts", selection: $conflictPolicy) {
                            ForEach(RestoreConflictPolicy.allCases, id: \.self) { policy in
                                Text(policy.displayName).tag(policy)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170, alignment: .leading)

                        Toggle("Dry run", isOn: $dryRun)
                            .toggleStyle(.checkbox)
                        Toggle("Verify files", isOn: $verify)
                            .toggleStyle(.checkbox)
                    }

                    RestoreFormRow(title: "Pre-restore backup") {
                        Picker("Pre-restore backup", selection: $preRestoreProfileID) {
                            Text("None").tag(UUID?.none)
                            ForEach(model.profiles) { profile in
                                Text(profile.name).tag(Optional(profile.id))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 300, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button {
                    runRestore()
                } label: {
                    Label(dryRun ? "Preview Restore" : "Start Restore", systemImage: dryRun ? "doc.text.magnifyingglass" : "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canRestore || model.isWorking || !model.isPersistentStoreAvailable)
            }
        }
        .onAppear {
            if repositoryID == nil {
                repositoryID = model.repositories.first?.id
                Task { @MainActor in
                    refreshRestorePointsForSelectedRepository()
                }
            } else {
                refreshRestorePointsForSelectedRepository()
            }
        }
        .onChange(of: repositoryID) { _, _ in
            snapshotID = ""
            resetBrowser()
            refreshRestorePointsForSelectedRepository()
        }
        .onChange(of: snapshotID) { _, _ in
            resetBrowser()
        }
    }

    private var selectedRepository: BackupRepository? {
        guard let repositoryID else { return nil }
        return model.repositories.first(where: { $0.id == repositoryID })
    }

    private var repositorySnapshots: [ResticSnapshot] {
        guard let repositoryID else { return [] }
        return model.snapshotsByRepository[repositoryID] ?? []
    }

    private var selectedSnapshot: ResticSnapshot? {
        repositorySnapshots.first { $0.id == snapshotID }
    }

    private var currentBrowserDirectory: String? {
        browserPathStack.last
    }

    private var canBrowseSnapshot: Bool {
        selectedRepository != nil && selectedSnapshot != nil && !model.isWorking
    }

    private var isLoadingBrowserEntries: Bool {
        guard let repositoryID, !snapshotID.isEmpty, let currentBrowserDirectory else {
            return false
        }
        return model.isLoadingSnapshotEntries(
            repositoryID: repositoryID,
            snapshotID: snapshotID,
            directoryPath: currentBrowserDirectory
        )
    }

    private var browserEntries: [ResticSnapshotEntry] {
        guard let selectedSnapshot else {
            return []
        }
        guard let currentBrowserDirectory else {
            return selectedSnapshot.paths
                .map { path in
                    ResticSnapshotEntry(
                        name: Self.displayName(for: path),
                        path: path,
                        type: .directory
                    )
                }
                .sortedForBrowser()
        }
        guard let repositoryID else {
            return []
        }
        return (model.snapshotEntries(
            repositoryID: repositoryID,
            snapshotID: snapshotID,
            directoryPath: currentBrowserDirectory
        ) ?? [])
        .filter { Self.normalizedPath($0.path) != Self.normalizedPath(currentBrowserDirectory) }
        .sortedForBrowser()
    }

    private var browserEmptyMessage: String {
        if selectedRepository == nil {
            return "Choose a destination first."
        }
        if snapshotID.isEmpty {
            return "Choose a restore point to browse its contents."
        }
        if currentBrowserDirectory == nil {
            return "This restore point does not list any backed-up source roots."
        }
        if isLoadingBrowserEntries {
            return "Loading folder contents..."
        }
        return "No files or folders were found here."
    }

    private var normalizedSelectedRestorePaths: [String] {
        Self.normalizedRestorePaths(Array(selectedRestorePaths))
    }

    private var canRestore: Bool {
        let destinationIsValid = restoreOriginalPaths || !destinationPath.isEmpty
        let inPlaceIsAcknowledged = !restoreOriginalPaths || dryRun || acknowledgedInPlaceRestore
        return selectedRepository != nil && !snapshotID.isEmpty && destinationIsValid && inPlaceIsAcknowledged
    }

    private func runRestore() {
        guard let repository = selectedRepository else { return }
        let paths = normalizedSelectedRestorePaths
        let request = RestoreRequest(
            repositoryID: repository.id,
            snapshotID: snapshotID,
            scope: paths.isEmpty ? .fullSnapshot : .selectedPaths(paths),
            destination: restoreOriginalPaths ? .originalPaths : .chosenFolder(destinationPath),
            conflictPolicy: conflictPolicy,
            verifyRestoredFiles: verify,
            dryRun: dryRun,
            confirmedOriginalPathRestore: restoreOriginalPaths && !dryRun && acknowledgedInPlaceRestore,
            preRestoreBackupProfileID: preRestoreProfileID
        )
        model.runRestore(repository: repository, request: request)
    }

    private func refreshRestorePointsForSelectedRepository() {
        guard let repository = selectedRepository, !model.isWorking else {
            return
        }
        model.refreshSnapshots(repository: repository)
    }

    private func openBrowserDirectory(_ path: String) {
        guard let repository = selectedRepository, !snapshotID.isEmpty else {
            return
        }
        browserPathStack.append(path)
        model.loadSnapshotEntries(repository: repository, snapshotID: snapshotID, directoryPath: path)
    }

    private func navigateBrowserBack() {
        guard !browserPathStack.isEmpty else {
            return
        }
        browserPathStack.removeLast()
    }

    private func refreshCurrentBrowserDirectory() {
        guard let repository = selectedRepository, !snapshotID.isEmpty, let currentBrowserDirectory else {
            return
        }
        model.loadSnapshotEntries(
            repository: repository,
            snapshotID: snapshotID,
            directoryPath: currentBrowserDirectory,
            force: true
        )
    }

    private func clearRestoreSelection() {
        selectedRestorePaths.removeAll()
    }

    private func resetBrowser() {
        selectedRestorePaths.removeAll()
        browserPathStack.removeAll()
    }

    private static func normalizedRestorePaths(_ paths: [String]) -> [String] {
        let normalized = Set(paths.map(normalizedPath).filter { !$0.isEmpty })
        return normalized
            .filter { path in
                !normalized.contains { candidate in
                    candidate != path && path.hasPrefix(candidate == "/" ? "/" : "\(candidate)/")
                }
            }
            .sorted()
    }

    private static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        if trimmed == "/" {
            return "/"
        }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    private static func displayName(for path: String) -> String {
        if path == "/" {
            return "System volume (/)"
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
}

struct SnapshotBrowserPanel: View {
    var entries: [ResticSnapshotEntry]
    @Binding var selectedPaths: Set<String>
    var currentPath: String?
    var selectedCount: Int
    var isLoading: Bool
    var canBrowse: Bool
    var emptyMessage: String
    var onOpen: (String) -> Void
    var onBack: () -> Void
    var onRefresh: () -> Void
    var onClearSelection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(currentTitle, systemImage: currentPath == nil ? "externaldrive" : "folder")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if selectedCount > 0 {
                    Text("\(selectedCount) selected")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.blue.opacity(0.16))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
                Button {
                    onClearSelection()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .disabled(selectedPaths.isEmpty)
                .deltaTooltip("Clear selected files and folders")

                Button {
                    onRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!canBrowse || currentPath == nil || isLoading)
                .deltaTooltip("Reload this folder")
            }

            if let currentPath {
                HStack(spacing: 8) {
                    Button {
                        onBack()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLoading)

                    Text(currentPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            browserBody
                .frame(height: 280)

            Text(selectedCount == 0 ? "No files or folders selected. Delta will restore everything from this restore point." : "Delta will restore only the selected files and folders.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var browserBody: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(DeltaTheme.logPaneBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DeltaTheme.border, lineWidth: 1)
                )

            if isLoading && entries.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading folder contents...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if entries.isEmpty {
                CompactEmptyRow(text: emptyMessage)
                    .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            SnapshotBrowserRow(
                                entry: entry,
                                isSelected: selectionBinding(for: entry.path),
                                canOpen: canBrowse && entry.type.isDirectory,
                                onOpen: { onOpen(entry.path) }
                            )
                            if entry.id != entries.last?.id {
                                Divider()
                                    .padding(.leading, 42)
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    private var currentTitle: String {
        currentPath == nil ? "Backed-up sources" : "Folder contents"
    }

    private func selectionBinding(for path: String) -> Binding<Bool> {
        Binding(
            get: { selectedPaths.contains(path) },
            set: { selected in
                if selected {
                    selectedPaths.insert(path)
                } else {
                    selectedPaths.remove(path)
                }
            }
        )
    }
}

struct SnapshotBrowserRow: View {
    var entry: ResticSnapshotEntry
    @Binding var isSelected: Bool
    var canOpen: Bool
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 20)

            Image(systemName: entry.type.isDirectory ? "folder.fill" : iconName)
                .foregroundStyle(entry.type.isDirectory ? .blue : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(entry.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            if let sizeText {
                Text(sizeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if canOpen {
                Button {
                    onOpen()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .deltaTooltip("Browse folder")
            } else {
                Color.clear
                    .frame(width: 18, height: 18)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch entry.type {
        case .directory:
            return "folder.fill"
        case .file:
            return "doc"
        case .symlink:
            return "arrowshape.turn.up.right"
        case .other:
            return "questionmark.square"
        }
    }

    private var sizeText: String? {
        guard let size = entry.size, !entry.type.isDirectory else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

private extension Array where Element == ResticSnapshotEntry {
    func sortedForBrowser() -> [ResticSnapshotEntry] {
        sorted {
            if $0.type.isDirectory != $1.type.isDirectory {
                return $0.type.isDirectory
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

struct ActivityView: View {
    @EnvironmentObject private var model: DeltaAppModel

    var body: some View {
        PageScaffold(title: "Activity", subtitle: "Jobs, destination checks, and system events") {
            SurfaceSection(title: "Live Backup Logs", symbol: "terminal") {
                LiveLogViewport(
                    lines: Array(model.liveLogLines.suffix(300)),
                    isWorking: model.isWorking
                )
            }

            SurfaceSection(title: "Saved Job Logs", symbol: "doc.text.magnifyingglass") {
                PersistentLogViewport(
                    entries: Array(model.jobLogs.suffix(240)),
                    jobs: model.jobs
                )
            }

            SurfaceSection(title: "Recent Jobs", symbol: "waveform.path.ecg") {
                if model.jobs.isEmpty {
                    CompactEmptyRow(text: "No jobs have run yet.")
                } else {
                    ForEach(model.jobs) { job in
                        JobRow(job: job)
                    }
                }
            }

            SurfaceSection(title: "Events", symbol: "list.bullet.rectangle") {
                if model.events.isEmpty {
                    CompactEmptyRow(text: "No events recorded.")
                } else {
                    ForEach(model.events) { event in
                        EventRow(event: event)
                    }
                }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: DeltaAppModel
    @EnvironmentObject private var softwareUpdateController: SoftwareUpdateController
    @State private var automaticallyChecksForUpdates = true

    var body: some View {
        PageScaffold(title: "Settings", subtitle: "Updates, permissions, and background scheduling") {
            SettingsCard(symbol: "arrow.down.circle", title: "Automatic Updates") {
                Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                    .toggleStyle(.checkbox)
                    .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                        softwareUpdateController.automaticallyChecksForUpdates = newValue
                    }
                ActionLine(
                    description: "Delta verifies signed update packages before installing them.",
                    buttonTitle: "Check Now",
                    symbol: "arrow.clockwise",
                    action: softwareUpdateController.checkForUpdates
                )
            }

            SettingsCard(symbol: "lock.shield", title: "Full Disk Access") {
                HStack {
                    StateBadge(
                        text: model.fullDiskAccessStatus.hasLikelyFullDiskAccess ? "Ready" : "Needs Access",
                        color: model.fullDiskAccessStatus.hasLikelyFullDiskAccess ? .green : .orange
                    )
                    Text(model.fullDiskAccessStatus.hasLikelyFullDiskAccess ? "Protected locations look readable." : "Protected locations are not readable yet.")
                        .foregroundStyle(.secondary)
                }
                ActionLine(
                    description: "macOS requires you to add Delta manually if it is not already listed.",
                    buttonTitle: "Open Privacy Settings",
                    symbol: "arrow.up.forward.app",
                    action: model.openFullDiskAccessSettings
                )
                ActionLine(
                    description: "Use this when Privacy & Security asks you to choose the app with the + button.",
                    buttonTitle: "Show Delta",
                    symbol: "folder",
                    action: model.revealInstalledAppInFinder
                )
                Button {
                    model.reload()
                } label: {
                    Label("Recheck Access", systemImage: "arrow.clockwise")
                }
            }

            if let persistentStoreErrorMessage = model.persistentStoreErrorMessage {
                SettingsCard(symbol: "externaldrive.badge.exclamationmark", title: "App Data Storage") {
                    HStack {
                        StateBadge(text: "Blocked", color: .red)
                        Text("Backup and restore actions are disabled.")
                            .foregroundStyle(.secondary)
                    }
                    Text(persistentStoreErrorMessage)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        model.reload()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                }
            }

            SettingsCard(symbol: "clock.badge.checkmark", title: "LaunchAgent") {
                HStack {
                    Text("Status")
                        .foregroundStyle(.secondary)
                    Text(LaunchAgentController.status())
                        .font(.system(.body, design: .monospaced))
                }
                HStack {
                    Button("Register") {
                        model.registerAgent()
                    }
                    Button("Unregister") {
                        model.unregisterAgent()
                    }
                }
            }
        }
        .onAppear {
            automaticallyChecksForUpdates = softwareUpdateController.automaticallyChecksForUpdates
            softwareUpdateController.updateCheckInterval = 86_400
        }
    }
}

struct ProfileRow: View {
    @EnvironmentObject private var model: DeltaAppModel
    var profile: BackupProfile
    var showsInlineProgress = true
    @State private var isPresentingEditor = false
    @State private var isConfirmingDelete = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    StatusIcon(symbol: profile.sourceMode == .fullVolume ? "internaldrive" : "folder", color: statusColor)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(profile.name)
                                .font(.headline)
                                .lineLimit(1)
                            if isActiveBackup {
                                StateBadge(text: "Running", color: .blue)
                            } else if isPausedBackup {
                                StateBadge(text: "Paused", color: .orange)
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(sourceSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(repositorySummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        HStack(spacing: 8) {
                            MetadataBadge(text: profile.sourceMode.displayName)
                            MetadataBadge(text: scheduleSummary)
                            MetadataBadge(text: retentionSummary)
                        }
                        if let latestBackupRun {
                            BackupRunSummaryLine(job: latestBackupRun)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .trailing, spacing: 8) {
                        Button {
                            if isPausedBackup {
                                model.resumeBackup(profile: profile)
                            } else {
                                model.runNow(profile: profile)
                            }
                        } label: {
                            Label(primaryActionTitle, systemImage: primaryActionSymbol)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.isWorking || !model.isPersistentStoreAvailable)
                        .fixedSize()
                        .deltaTooltip(primaryActionTooltip)
                        .accessibilityLabel(primaryActionTitle)

                        HStack(spacing: 8) {
                            IconButton(symbol: "pencil", help: "Edit sources, destination, schedule, and retention") {
                                isPresentingEditor = true
                            }
                            .disabled(model.isWorking || !model.isPersistentStoreAvailable)
                            IconButton(symbol: "scissors", help: "Run retention cleanup for this profile") {
                                model.prune(profile: profile)
                            }
                            .disabled(model.isWorking || !model.isPersistentStoreAvailable)
                            IconButton(symbol: "trash", help: "Delete this backup profile") {
                                isConfirmingDelete = true
                            }
                            .disabled(model.isWorking || !model.isPersistentStoreAvailable)
                        }
                    }
                }

                if isActiveBackup && showsInlineProgress {
                    InlineBackupProgress(
                        progress: model.activeProgress,
                        latestMessage: model.liveLogLines.last?.message,
                        stopRequest: model.activeStopRequest,
                        onPause: model.pauseActiveBackup,
                        onCancel: model.cancelActiveJob
                    )
                } else if isPausedBackup {
                    PausedBackupNotice()
                }
            }
        }
        .sheet(isPresented: $isPresentingEditor) {
            ProfileEditorView(profile: profile)
                .environmentObject(model)
                .frame(width: ModalMetrics.sheetWidth, height: 680)
        }
        .confirmationDialog("Delete Backup Profile?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                model.deleteProfile(profile)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the profile from Delta. Existing restore points in the destination are not deleted.")
        }
    }

    private var sourceSummary: String {
        profile.sources.map(\.path).joined(separator: ", ")
    }

    private var isActiveBackup: Bool {
        model.activeOperation?.kind == .backup && model.activeOperation?.profileID == profile.id
    }

    private var isPausedBackup: Bool {
        guard !isActiveBackup, let latestBackupRun else {
            return false
        }
        return latestBackupRun.status == .cancelled
            && latestBackupRun.message?.localizedCaseInsensitiveContains("paused") == true
    }

    private var latestBackupRun: JobRun? {
        model.jobs
            .filter { $0.profileID == profile.id && $0.kind == .backup }
            .max { $0.startedAt < $1.startedAt }
    }

    private var statusColor: Color {
        if isActiveBackup {
            return .blue
        }
        if isPausedBackup {
            return .orange
        }
        return .gray
    }

    private var primaryActionTitle: String {
        if isActiveBackup {
            return "Running"
        }
        if isPausedBackup {
            return "Resume"
        }
        return "Back Up Now"
    }

    private var primaryActionSymbol: String {
        if isActiveBackup {
            return "arrow.triangle.2.circlepath"
        }
        if isPausedBackup {
            return "play.circle.fill"
        }
        return "play.fill"
    }

    private var primaryActionTooltip: String {
        if isActiveBackup {
            return "This backup is running. Progress is shown below."
        }
        if isPausedBackup {
            return "Resume this backup. Delta continues from already saved backup data."
        }
        return "Start this backup profile immediately."
    }

    private var repositorySummary: String {
        let repositoryName = model.repositories.first(where: { $0.id == profile.repositoryID })?.name ?? "Missing destination"
        return "Destination: \(repositoryName)"
    }

    private var scheduleSummary: String {
        guard profile.schedule.isEnabled else { return "Paused" }
        switch profile.schedule.kind {
        case let .hourly(minute):
            return "Hourly :\(String(format: "%02d", minute))"
        case let .daily(hour, minute):
            return "Daily \(String(format: "%02d:%02d", hour, minute))"
        case let .weekly(weekday, hour, minute):
            return "\(weekdayName(weekday)) \(String(format: "%02d:%02d", hour, minute))"
        case let .monthly(day, hour, minute):
            return "Monthly \(day) \(String(format: "%02d:%02d", hour, minute))"
        case let .customInterval(seconds):
            return "Every \(Int(seconds / 60))m"
        }
    }

    private var retentionSummary: String {
        "Keep \(profile.retention.keepDaily)d/\(profile.retention.keepWeekly)w/\(profile.retention.keepMonthly)m"
    }

    private func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        let index = min(max(weekday - 1, 0), symbols.count - 1)
        return symbols[index]
    }
}

struct RepositoryRow: View {
    @EnvironmentObject private var model: DeltaAppModel
    var repository: BackupRepository
    @State private var isPresentingEditor = false
    @State private var isConfirmingDelete = false

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                StatusIcon(symbol: repository.backend.kind == .local ? "externaldrive" : "network", color: .teal)
                VStack(alignment: .leading, spacing: 8) {
                    Text(repository.name)
                        .font(.headline)
                        .lineLimit(1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(repository.backend.kind.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(backendSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack(spacing: 8) {
                        MetadataBadge(text: repository.secretStorageMode.displayName)
                        MetadataBadge(text: verificationSummary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    IconButton(symbol: "pencil", help: "Edit destination settings and credentials") {
                        isPresentingEditor = true
                    }
                    .disabled(model.isWorking || !model.isPersistentStoreAvailable)
                    IconButton(symbol: "shippingbox.and.arrow.backward", help: "Retry destination preparation") {
                        model.initializeRepository(repository)
                    }
                    .disabled(model.isWorking || !model.isPersistentStoreAvailable)
                    IconButton(symbol: "checkmark.shield", help: "Check destination integrity") {
                        model.checkRepository(repository)
                    }
                    .disabled(model.isWorking || !model.isPersistentStoreAvailable)
                    IconButton(symbol: "arrow.clockwise", help: "Refresh restore points from this destination") {
                        model.refreshSnapshots(repository: repository)
                    }
                    .disabled(model.isWorking || !model.isPersistentStoreAvailable)
                    IconButton(symbol: "trash", help: "Remove this destination from Delta") {
                        isConfirmingDelete = true
                    }
                    .disabled(model.isWorking || !model.isPersistentStoreAvailable)
                }
            }
        }
        .sheet(isPresented: $isPresentingEditor) {
            RepositoryEditorView(repository: repository)
                .environmentObject(model)
                .frame(width: ModalMetrics.sheetWidth)
        }
        .confirmationDialog("Remove Destination?", isPresented: $isConfirmingDelete) {
            Button("Remove", role: .destructive) {
                model.deleteRepository(repository)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the destination from Delta and deletes cached restore point metadata. Backup data at the destination is not deleted.")
        }
    }

    private var verificationSummary: String {
        guard let lastVerifiedAt = repository.lastVerifiedAt else {
            return "Not checked"
        }
        return "Verified \(lastVerifiedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private var backendSummary: String {
        switch repository.backend {
        case let .local(path):
            return path
        case let .sftp(host, path, username, port):
            let user = username.map { "\($0)@" } ?? ""
            let portPart = port.map { ":\($0)" } ?? ""
            return "\(user)\(host)\(portPart):\(path)"
        case let .rest(url):
            return url
        case let .s3(endpoint, bucket, path, _):
            return [endpoint, bucket, path].compactMap { $0 }.joined(separator: " / ")
        case let .backblazeB2(bucket, path),
             let .azureBlob(bucket, path),
             let .googleCloudStorage(bucket, path),
             let .swiftObjectStorage(bucket, path):
            return [bucket, path].compactMap { $0 }.joined(separator: " / ")
        case let .rclone(remote, path):
            return "\(remote):\(path)"
        case let .custom(repository):
            return repository
        }
    }
}

struct ProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: DeltaAppModel
    private let existingProfile: BackupProfile?
    @State private var name = "Mac Backup"
    @State private var mode: BackupSourceMode = .customFolders
    @State private var sources: [BackupSource] = []
    @State private var repositoryID: UUID?
    @State private var scheduleKind: ScheduleEditorKind = .daily
    @State private var hour = 20
    @State private var minute = 0
    @State private var weekday = 2
    @State private var day = 1
    @State private var intervalMinutes = 120
    @State private var scheduleEnabled = true
    @State private var catchUpMissedRuns = true
    @State private var runOnBattery = true
    @State private var runInLowPowerMode = false
    @State private var uploadLimit = ""
    @State private var downloadLimit = ""
    @State private var keepHourly = 24
    @State private var keepDaily = 30
    @State private var keepWeekly = 12
    @State private var keepMonthly = 12
    @State private var keepYearly = 0
    @State private var pruneAfterForget = true
    @State private var checkAfterPrune = true
    @State private var maintenanceEnabled = true
    @State private var maintenanceIntervalDays = 7
    @State private var maintenanceHour = 2
    @State private var maintenanceMinute = 0

    init(profile: BackupProfile? = nil) {
        existingProfile = profile
        let schedule = profile?.schedule ?? BackupSchedule()
        let scheduleState = Self.scheduleEditorState(for: schedule.kind)
        let retention = profile?.retention ?? RetentionPolicy()

        _name = State(initialValue: profile?.name ?? "Mac Backup")
        _mode = State(initialValue: profile?.sourceMode ?? .customFolders)
        _sources = State(initialValue: profile?.sources ?? [])
        _repositoryID = State(initialValue: profile?.repositoryID)
        _scheduleKind = State(initialValue: scheduleState.kind)
        _hour = State(initialValue: scheduleState.hour)
        _minute = State(initialValue: scheduleState.minute)
        _weekday = State(initialValue: scheduleState.weekday)
        _day = State(initialValue: scheduleState.day)
        _intervalMinutes = State(initialValue: scheduleState.intervalMinutes)
        _scheduleEnabled = State(initialValue: schedule.isEnabled)
        _catchUpMissedRuns = State(initialValue: schedule.catchUpMissedRuns)
        _runOnBattery = State(initialValue: schedule.runOnBattery)
        _runInLowPowerMode = State(initialValue: schedule.runInLowPowerMode)
        _uploadLimit = State(initialValue: schedule.uploadLimitKiB.map(String.init) ?? "")
        _downloadLimit = State(initialValue: schedule.downloadLimitKiB.map(String.init) ?? "")
        _keepHourly = State(initialValue: retention.keepHourly)
        _keepDaily = State(initialValue: retention.keepDaily)
        _keepWeekly = State(initialValue: retention.keepWeekly)
        _keepMonthly = State(initialValue: retention.keepMonthly)
        _keepYearly = State(initialValue: retention.keepYearly)
        _pruneAfterForget = State(initialValue: retention.pruneAfterForget)
        _checkAfterPrune = State(initialValue: retention.checkAfterPrune)
        _maintenanceEnabled = State(initialValue: retention.maintenanceSchedule.isEnabled)
        _maintenanceIntervalDays = State(initialValue: retention.maintenanceSchedule.intervalDays)
        _maintenanceHour = State(initialValue: retention.maintenanceSchedule.hour)
        _maintenanceMinute = State(initialValue: retention.maintenanceSchedule.minute)
    }

    var body: some View {
        SheetScaffold(title: sheetTitle, subtitle: sheetSubtitle) {
            FieldRow(title: "Name") {
                TextField("Profile name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            FieldRow(title: "Source type") {
                Picker("Source", selection: $mode) {
                    ForEach(BackupSourceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 230, alignment: .leading)
            }

            FieldRow(title: "Sources") {
                HStack(spacing: 10) {
                    Button {
                        if mode == .fullVolume {
                            sources = model.chooseBackupSources(allowsMultipleSelection: false, includeSubvolumes: false)
                        } else {
                            sources = model.chooseBackupSources(allowsMultipleSelection: true, includeSubvolumes: true)
                        }
                    } label: {
                        Label("Choose", systemImage: "folder.badge.plus")
                    }
                    Text(sources.isEmpty ? "No sources selected" : sources.map(\.path).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 380, alignment: .leading)
                }
            }

            FieldRow(title: "Destination") {
                Picker("Destination", selection: $repositoryID) {
                    Text("Choose").tag(UUID?.none)
                    ForEach(model.repositories) { repository in
                        Text(repository.name).tag(Optional(repository.id))
                    }
                }
                .labelsHidden()
                .frame(width: 264, alignment: .leading)
            }

            FieldRow(title: "Schedule") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Schedule", selection: $scheduleKind) {
                        ForEach(ScheduleEditorKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 350, alignment: .leading)

                    scheduleControls
                }
            }

            FieldRow(title: "Run policy") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 18) {
                        Toggle("Enabled", isOn: $scheduleEnabled)
                            .toggleStyle(.checkbox)
                            .frame(width: 170, alignment: .leading)
                        Toggle("Catch up missed runs", isOn: $catchUpMissedRuns)
                            .toggleStyle(.checkbox)
                            .frame(width: 210, alignment: .leading)
                    }
                    HStack(spacing: 18) {
                        Toggle("Run on battery", isOn: $runOnBattery)
                            .toggleStyle(.checkbox)
                            .frame(width: 170, alignment: .leading)
                        Toggle("Run in Low Power Mode", isOn: $runInLowPowerMode)
                            .toggleStyle(.checkbox)
                            .frame(width: 210, alignment: .leading)
                    }
                }
            }

            FieldRow(title: "Bandwidth") {
                HStack(spacing: 10) {
                    TextField("Upload KiB/s", text: $uploadLimit)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 132)
                    TextField("Download KiB/s", text: $downloadLimit)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 132)
                }
            }

            FieldRow(title: "Retention") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Stepper("Hourly \(keepHourly)", value: $keepHourly, in: 0...168)
                            .frame(width: 122, alignment: .leading)
                        Stepper("Daily \(keepDaily)", value: $keepDaily, in: 0...365)
                            .frame(width: 122, alignment: .leading)
                        Stepper("Weekly \(keepWeekly)", value: $keepWeekly, in: 0...260)
                            .frame(width: 132, alignment: .leading)
                    }
                    HStack(spacing: 10) {
                        Stepper("Monthly \(keepMonthly)", value: $keepMonthly, in: 0...120)
                            .frame(width: 122, alignment: .leading)
                        Stepper("Yearly \(keepYearly)", value: $keepYearly, in: 0...50)
                            .frame(width: 122, alignment: .leading)
                    }
                    HStack(spacing: 18) {
                        Toggle("Free space after cleanup", isOn: $pruneAfterForget)
                            .toggleStyle(.checkbox)
                            .frame(width: 170, alignment: .leading)
                        Toggle("Verify after cleanup", isOn: $checkAfterPrune)
                            .toggleStyle(.checkbox)
                            .frame(width: 170, alignment: .leading)
                    }
                    Divider()
                        .frame(width: 390)
                    HStack(spacing: 18) {
                        Toggle("Automatic cleanup", isOn: $maintenanceEnabled)
                            .toggleStyle(.checkbox)
                            .frame(width: 170, alignment: .leading)
                        Stepper("Every \(maintenanceIntervalDays) days", value: $maintenanceIntervalDays, in: 1...90)
                            .frame(width: 170, alignment: .leading)
                    }
                    TimeControls(hour: $maintenanceHour, minute: $maintenanceMinute)
                        .disabled(!maintenanceEnabled)
                }
            }

            SheetActions {
                Button("Cancel") { dismiss() }
                Button(existingProfile == nil ? "Create" : "Save") {
                    if let repositoryID {
                        saveProfile(repositoryID: repositoryID)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || repositoryID == nil || sources.isEmpty || !model.isPersistentStoreAvailable)
            }
        }
        .onAppear {
            repositoryID = repositoryID ?? model.repositories.first?.id
        }
    }

    private var sheetTitle: String {
        existingProfile == nil ? "New Backup Profile" : "Edit Backup Profile"
    }

    private var sheetSubtitle: String {
        existingProfile == nil ? "Define what to protect and when to run." : "Update what to protect and when to run."
    }

    @ViewBuilder
    private var scheduleControls: some View {
        switch scheduleKind {
        case .hourly:
            Stepper("Minute \(minute)", value: $minute, in: 0...59)
                .frame(width: 120, alignment: .leading)
        case .daily:
            TimeControls(hour: $hour, minute: $minute)
        case .weekly:
            HStack(spacing: 12) {
                Picker("Weekday", selection: $weekday) {
                    ForEach(1...7, id: \.self) { value in
                        Text(Calendar.current.weekdaySymbols[value - 1]).tag(value)
                    }
                }
                .frame(width: 170)
                TimeControls(hour: $hour, minute: $minute)
            }
        case .monthly:
            HStack(spacing: 12) {
                Stepper("Day \(day)", value: $day, in: 1...31)
                    .frame(width: 100, alignment: .leading)
                TimeControls(hour: $hour, minute: $minute)
            }
        case .custom:
            Stepper("Every \(intervalMinutes) minutes", value: $intervalMinutes, in: 1...10_080, step: 15)
                .frame(width: 190, alignment: .leading)
        }
    }

    private var selectedSchedule: BackupSchedule {
        BackupSchedule(
            kind: selectedScheduleKind,
            isEnabled: scheduleEnabled,
            catchUpMissedRuns: catchUpMissedRuns,
            runOnBattery: runOnBattery,
            runInLowPowerMode: runInLowPowerMode,
            uploadLimitKiB: positiveInteger(uploadLimit),
            downloadLimitKiB: positiveInteger(downloadLimit)
        )
    }

    private var selectedScheduleKind: ScheduleKind {
        switch scheduleKind {
        case .hourly:
            return .hourly(minute: minute)
        case .daily:
            return .daily(hour: hour, minute: minute)
        case .weekly:
            return .weekly(weekday: weekday, hour: hour, minute: minute)
        case .monthly:
            return .monthly(day: day, hour: hour, minute: minute)
        case .custom:
            return .customInterval(seconds: TimeInterval(intervalMinutes * 60))
        }
    }

    private var selectedRetention: RetentionPolicy {
        RetentionPolicy(
            keepHourly: keepHourly,
            keepDaily: keepDaily,
            keepWeekly: keepWeekly,
            keepMonthly: keepMonthly,
            keepYearly: keepYearly,
            pruneAfterForget: pruneAfterForget,
            checkAfterPrune: checkAfterPrune,
            maintenanceSchedule: RetentionMaintenanceSchedule(
                isEnabled: maintenanceEnabled,
                intervalDays: maintenanceIntervalDays,
                hour: maintenanceHour,
                minute: maintenanceMinute
            )
        )
    }

    private func saveProfile(repositoryID: UUID) {
        if var profile = existingProfile {
            profile.name = name
            profile.sourceMode = mode
            profile.sources = sources
            profile.repositoryID = repositoryID
            profile.schedule = selectedSchedule
            profile.retention = selectedRetention
            profile.updatedAt = Date()
            model.saveProfile(profile)
        } else {
            model.createProfile(
                name: name,
                mode: mode,
                sources: sources,
                repositoryID: repositoryID,
                schedule: selectedSchedule,
                retention: selectedRetention
            )
        }
    }

    private func positiveInteger(_ value: String) -> Int? {
        guard let integer = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), integer > 0 else {
            return nil
        }
        return integer
    }

    private static func scheduleEditorState(for kind: ScheduleKind) -> ScheduleEditorState {
        switch kind {
        case let .hourly(minute):
            return ScheduleEditorState(kind: .hourly, minute: minute)
        case let .daily(hour, minute):
            return ScheduleEditorState(kind: .daily, hour: hour, minute: minute)
        case let .weekly(weekday, hour, minute):
            return ScheduleEditorState(kind: .weekly, hour: hour, minute: minute, weekday: weekday)
        case let .monthly(day, hour, minute):
            return ScheduleEditorState(kind: .monthly, hour: hour, minute: minute, day: day)
        case let .customInterval(seconds):
            return ScheduleEditorState(kind: .custom, intervalMinutes: max(1, Int(seconds / 60)))
        }
    }

    private struct ScheduleEditorState {
        var kind: ScheduleEditorKind
        var hour = 20
        var minute = 0
        var weekday = 2
        var day = 1
        var intervalMinutes = 120
    }
}

enum ScheduleEditorKind: String, CaseIterable, Identifiable {
    case hourly
    case daily
    case weekly
    case monthly
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hourly: "Hourly"
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .custom: "Custom"
        }
    }
}

struct TimeControls: View {
    @Binding var hour: Int
    @Binding var minute: Int

    var body: some View {
        HStack(spacing: 10) {
            Stepper("Hour \(hour)", value: $hour, in: 0...23)
                .frame(width: 92, alignment: .leading)
            Stepper("Minute \(minute)", value: $minute, in: 0...59)
                .frame(width: 112, alignment: .leading)
        }
    }
}

struct RepositoryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: DeltaAppModel
    private let existingRepository: BackupRepository?
    @State private var name = "Primary Destination"
    @State private var kind: RepositoryBackendKind = .local
    @State private var primary = ""
    @State private var secondary = ""
    @State private var tertiary = ""
    @State private var quaternary = ""
    @State private var storageMode: SecretStorageMode = .appManagedKeychain
    @State private var passphrase = ""
    @State private var passphraseConfirmation = ""
    @State private var credentialValues: [String: String] = [:]

    init(repository: BackupRepository? = nil) {
        existingRepository = repository
        let backendState = Self.editorState(for: repository?.backend ?? .local(path: ""))
        _name = State(initialValue: repository?.name ?? "Primary Destination")
        _kind = State(initialValue: backendState.kind)
        _primary = State(initialValue: backendState.primary)
        _secondary = State(initialValue: backendState.secondary)
        _tertiary = State(initialValue: backendState.tertiary)
        _quaternary = State(initialValue: backendState.quaternary)
        _storageMode = State(initialValue: repository?.secretStorageMode ?? .appManagedKeychain)
        _credentialValues = State(initialValue: Dictionary(uniqueKeysWithValues: ResticBackendCredentialTemplates.keys(for: backendState.kind).map { ($0, "") }))
    }

    var body: some View {
        SheetScaffold(title: sheetTitle, subtitle: sheetSubtitle) {
            FieldRow(title: "Name") {
                TextField("Destination name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            FieldRow(title: "Type") {
                Picker("Type", selection: $kind) {
                    ForEach(RepositoryBackendKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: ModalMetrics.primaryControlWidth, alignment: .leading)
            }

            backendFields
            credentialFields

            if existingRepository == nil {
                FieldRow(title: "Encryption password") {
                    Picker("Password", selection: $storageMode) {
                        ForEach(SecretStorageMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 360, alignment: .leading)
                }

                if storageMode == .userManagedPassphrase {
                    FieldRow(title: "Passphrase") {
                        SecureField("Encryption passphrase", text: $passphrase)
                            .textFieldStyle(.roundedBorder)
                    }
                    FieldRow(title: "Confirm") {
                        SecureField("Confirm encryption passphrase", text: $passphraseConfirmation)
                            .textFieldStyle(.roundedBorder)
                    }
                    if !passphraseConfirmation.isEmpty && passphrase != passphraseConfirmation {
                        FieldRow(title: "") {
                            InlineWarning(
                                symbol: "exclamationmark.triangle",
                                title: "Passphrases do not match.",
                                message: "This password is required to restore encrypted backup data."
                            )
                            .frame(width: ModalMetrics.primaryControlWidth, alignment: .leading)
                        }
                    }
                }
            } else if let existingRepository {
                FieldRow(title: "Encryption password") {
                    Text(existingRepository.secretStorageMode.displayName)
                        .foregroundStyle(.secondary)
                }
            }

            SheetActions {
                Button("Cancel") { dismiss() }
                Button(existingRepository == nil ? "Create" : "Save") {
                    if saveDestination() {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate || !model.isPersistentStoreAvailable)
            }
        }
        .onChange(of: kind) { _, newKind in
            let keys = ResticBackendCredentialTemplates.keys(for: newKind)
            credentialValues = Dictionary(uniqueKeysWithValues: keys.map { ($0, credentialValues[$0] ?? "") })
        }
    }

    private var sheetTitle: String {
        existingRepository == nil ? "New Destination" : "Edit Destination"
    }

    private var sheetSubtitle: String {
        existingRepository == nil ? "Choose where encrypted restore points are stored." : "Update where encrypted restore points are stored."
    }

    @ViewBuilder
    private var backendFields: some View {
        switch kind {
        case .local:
            FieldRow(title: "Folder") {
                HStack {
                    TextField("Destination folder", text: $primary)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: ModalMetrics.primaryControlWidth)
                    Button {
                        if let path = model.chooseFolder().first {
                            primary = path
                        }
                    } label: {
                        Image(systemName: "folder")
                    }
                }
            }
        case .sftp:
            FieldRow(title: "Host") { TextField("nas.local", text: $primary).textFieldStyle(.roundedBorder) }
            FieldRow(title: "Path") { TextField("/absolute/destination/path", text: $secondary).textFieldStyle(.roundedBorder) }
            FieldRow(title: "Username") { TextField("Optional", text: $tertiary).textFieldStyle(.roundedBorder) }
            FieldRow(title: "Port") { TextField("Optional", text: $quaternary).textFieldStyle(.roundedBorder) }
        case .rest:
            FieldRow(title: "URL") { TextField("https://backup.example.com/repo", text: $primary).textFieldStyle(.roundedBorder) }
        case .s3:
            FieldRow(title: "Bucket") { TextField("bucket", text: $primary).textFieldStyle(.roundedBorder) }
            FieldRow(title: "Path") { TextField("Optional", text: $secondary).textFieldStyle(.roundedBorder) }
            FieldRow(title: "Endpoint") { TextField("Optional", text: $tertiary).textFieldStyle(.roundedBorder) }
            FieldRow(title: "Region") { TextField("Optional", text: $quaternary).textFieldStyle(.roundedBorder) }
        case .backblazeB2:
            FieldRow(title: "Bucket") { TextField("bucket", text: $primary).textFieldStyle(.roundedBorder) }
            FieldRow(title: "Path") { TextField("Optional", text: $secondary).textFieldStyle(.roundedBorder) }
        case .azureBlob:
            FieldRow(title: "Container") { TextField("container", text: $primary).textFieldStyle(.roundedBorder) }
            FieldRow(title: "Path") { TextField("Optional", text: $secondary).textFieldStyle(.roundedBorder) }
        case .googleCloudStorage:
            FieldRow(title: "Bucket") { TextField("bucket", text: $primary).textFieldStyle(.roundedBorder) }
            FieldRow(title: "Path") { TextField("Optional", text: $secondary).textFieldStyle(.roundedBorder) }
        case .swiftObjectStorage:
            FieldRow(title: "Container") { TextField("container", text: $primary).textFieldStyle(.roundedBorder) }
            FieldRow(title: "Path") { TextField("Optional", text: $secondary).textFieldStyle(.roundedBorder) }
        case .rclone:
            FieldRow(title: "Remote") { TextField("remote", text: $primary).textFieldStyle(.roundedBorder) }
            FieldRow(title: "Path") { TextField("path", text: $secondary).textFieldStyle(.roundedBorder) }
        case .custom:
            FieldRow(title: "Destination URL") { TextField("Backup destination URL", text: $primary).textFieldStyle(.roundedBorder) }
        }
    }

    @ViewBuilder
    private var credentialFields: some View {
        let keys = ResticBackendCredentialTemplates.keys(for: kind)
        if !keys.isEmpty {
            Divider()
            ForEach(keys, id: \.self) { key in
                FieldRow(title: key) {
                    SecureField(key, text: credentialBinding(for: key))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var backend: RepositoryBackend {
        switch kind {
        case .local: .local(path: primary)
        case .sftp: .sftp(host: primary, path: secondary, username: tertiary.isEmpty ? nil : tertiary, port: parsedPort)
        case .rest: .rest(url: primary)
        case .s3: .s3(endpoint: tertiary.isEmpty ? nil : tertiary, bucket: primary, path: secondary.isEmpty ? nil : secondary, region: quaternary.isEmpty ? nil : quaternary)
        case .backblazeB2: .backblazeB2(bucket: primary, path: secondary.isEmpty ? nil : secondary)
        case .azureBlob: .azureBlob(container: primary, path: secondary.isEmpty ? nil : secondary)
        case .googleCloudStorage: .googleCloudStorage(bucket: primary, path: secondary.isEmpty ? nil : secondary)
        case .swiftObjectStorage: .swiftObjectStorage(container: primary, path: secondary.isEmpty ? nil : secondary)
        case .rclone: .rclone(remote: primary, path: secondary)
        case .custom: .custom(repository: primary)
        }
    }

    private var sanitizedCredentialValues: [String: String] {
        credentialValues.filter { !$0.key.isEmpty && !$0.value.isEmpty }
    }

    private var canCreate: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if kind == .sftp && secondary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if kind == .sftp && !quaternary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsedPort, (1...65_535).contains(parsedPort) else { return false }
        }
        if existingRepository == nil && storageMode == .userManagedPassphrase {
            guard !passphrase.isEmpty, passphrase == passphraseConfirmation else { return false }
        }
        return true
    }

    private var parsedPort: Int? {
        let value = quaternary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return Int(value)
    }

    private func saveDestination() -> Bool {
        if let existingRepository {
            return model.saveRepository(
                existingRepository,
                name: name,
                backend: backend,
                backendCredentials: sanitizedCredentialValues
            )
        } else {
            return model.createRepository(
                name: name,
                backend: backend,
                storageMode: storageMode,
                passphrase: passphrase,
                backendCredentials: sanitizedCredentialValues
            )
        }
    }

    private func credentialBinding(for key: String) -> Binding<String> {
        Binding(
            get: { credentialValues[key, default: ""] },
            set: { credentialValues[key] = $0 }
        )
    }

    private static func editorState(for backend: RepositoryBackend) -> RepositoryEditorState {
        switch backend {
        case let .local(path):
            RepositoryEditorState(kind: .local, primary: path)
        case let .sftp(host, path, username, port):
            RepositoryEditorState(kind: .sftp, primary: host, secondary: path, tertiary: username ?? "", quaternary: port.map(String.init) ?? "")
        case let .rest(url):
            RepositoryEditorState(kind: .rest, primary: url)
        case let .s3(endpoint, bucket, path, region):
            RepositoryEditorState(kind: .s3, primary: bucket, secondary: path ?? "", tertiary: endpoint ?? "", quaternary: region ?? "")
        case let .backblazeB2(bucket, path):
            RepositoryEditorState(kind: .backblazeB2, primary: bucket, secondary: path ?? "")
        case let .azureBlob(container, path):
            RepositoryEditorState(kind: .azureBlob, primary: container, secondary: path ?? "")
        case let .googleCloudStorage(bucket, path):
            RepositoryEditorState(kind: .googleCloudStorage, primary: bucket, secondary: path ?? "")
        case let .swiftObjectStorage(container, path):
            RepositoryEditorState(kind: .swiftObjectStorage, primary: container, secondary: path ?? "")
        case let .rclone(remote, path):
            RepositoryEditorState(kind: .rclone, primary: remote, secondary: path)
        case let .custom(repository):
            RepositoryEditorState(kind: .custom, primary: repository)
        }
    }

    private struct RepositoryEditorState {
        var kind: RepositoryBackendKind
        var primary = ""
        var secondary = ""
        var tertiary = ""
        var quaternary = ""
    }
}

struct PageScaffold<Actions: View, Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder actions: () -> Actions = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    actions
                }
                content
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(DeltaTheme.background)
    }
}

struct SheetScaffold<Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(22)
        .frame(width: ModalMetrics.sheetWidth, alignment: .topLeading)
    }
}

enum ModalMetrics {
    static let sheetWidth: CGFloat = 760
    static let labelWidth: CGFloat = 154
    static let contentWidth: CGFloat = 548
    static let primaryControlWidth: CGFloat = 420
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(DeltaTheme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(DeltaTheme.border, lineWidth: 1)
            )
    }
}

struct RestoreStepCard<Content: View>: View {
    var number: Int
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    Text("\(number)")
                        .font(.caption.weight(.bold))
                        .frame(width: 24, height: 24)
                        .background(.blue.opacity(0.18))
                        .foregroundStyle(.blue)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.headline)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                content
                    .padding(.leading, 38)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RestoreForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RestoreFormRow<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .font(.subheadline.weight(.medium))
                .frame(width: 130, alignment: .trailing)
                .padding(.top, 5)
            HStack(spacing: 14) {
                content
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SurfaceSection<Content: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                Divider()
                content
            }
        }
    }
}

struct SettingsCard<Content: View>: View {
    var symbol: String
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                StatusIcon(symbol: symbol, color: .blue)
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.headline)
                    content
                }
            }
        }
    }
}

struct FieldRow<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(title)
                .foregroundStyle(.secondary)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: ModalMetrics.labelWidth, alignment: .trailing)
                .padding(.top, 5)
            content
                .frame(width: ModalMetrics.contentWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FormGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
    }
}

struct SheetActions<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            Spacer()
            content
        }
        .padding(.top, 4)
    }
}

struct SectionHeader: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .padding(.top, 4)
    }
}

struct StatPanel: View {
    var title: String
    var value: String
    var symbol: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ActiveOperationBanner: View {
    var operation: ActiveOperation
    var progress: ResticProgressSnapshot?
    var latestMessage: String?
    var stopRequest: ResticRunStopReason?
    var onPause: (() -> Void)?
    var onCancel: () -> Void

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                StatusIcon(symbol: operation.kind.statusSymbol, color: .blue)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(operation.title)
                            .font(.headline)
                        StateBadge(text: operation.kind == .backup ? "Backup Running" : "Running", color: .blue)
                    }
                    Text(operation.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    InlineBackupProgress(
                        progress: progress,
                        latestMessage: latestMessage,
                        stopRequest: stopRequest
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ActiveOperationControls(
                    stopRequest: stopRequest,
                    onPause: onPause,
                    onCancel: onCancel
                )
            }
        }
    }
}

struct InlineBackupProgress: View {
    var progress: ResticProgressSnapshot?
    var latestMessage: String?
    var stopRequest: ResticRunStopReason?
    var onPause: (() -> Void)?
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if onPause != nil || onCancel != nil {
                ActiveOperationControls(
                    stopRequest: stopRequest,
                    onPause: onPause,
                    onCancel: onCancel
                )
            }
        }
        .padding(10)
        .background(DeltaTheme.badge.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .deltaTooltip("Delta shows stable processed-file counters because backup totals can change while sources are being discovered.")
    }

    private var statusText: String {
        if let displayMessage = progress?.displayMessage, !displayMessage.isEmpty {
            return displayMessage
        }
        if let latestMessage, !latestMessage.isEmpty {
            return latestMessage
        }
        return "Scanning sources and preparing backup data..."
    }
}

struct PausedBackupNotice: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle")
                .foregroundStyle(.orange)
            Text("Backup paused. Resume continues from data already saved in the destination.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ActiveOperationControls: View {
    var stopRequest: ResticRunStopReason?
    var onPause: (() -> Void)?
    var onCancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if let stopRequest {
                Label(stopRequest == .pause ? "Pausing" : "Cancelling", systemImage: "hourglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            } else {
                if let onPause {
                    Button {
                        onPause()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .deltaTooltip("Pause this backup. Run it again to continue from saved backup data.")
                }
                if let onCancel {
                    Button(role: .destructive) {
                        onCancel()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .deltaTooltip("Stop the current job safely.")
                }
            }
        }
    }
}

struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        Card {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 170)
        }
    }
}

struct SidebarStatusView: View {
    var isWorking: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isWorking ? "arrow.triangle.2.circlepath" : "checkmark.seal")
            Text(isWorking ? "Running" : "Ready")
                .font(.caption)
            Spacer()
        }
        .padding(12)
        .foregroundStyle(.secondary)
    }
}

struct StatusIcon: View {
    var symbol: String
    var color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 34, height: 34)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct MetadataBadge: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(DeltaTheme.badge)
            .clipShape(Capsule())
    }
}

struct IconButton: View {
    var symbol: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(help)
        .deltaTooltip(help)
    }
}

extension View {
    func deltaTooltip(_ text: String) -> some View {
        modifier(DeltaTooltipModifier(text: text))
    }
}

private struct DeltaTooltipModifier: ViewModifier {
    let text: String
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if isHovering {
                    TooltipBubble(text: text)
                        .offset(y: 34)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                        .allowsHitTesting(false)
                        .zIndex(100)
                }
            }
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.08)) {
                    isHovering = hovering
                }
            }
            .zIndex(isHovering ? 100 : 0)
    }
}

struct TooltipBubble: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(DeltaTheme.tooltipBackground)
                    .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(DeltaTheme.border, lineWidth: 1)
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 220)
    }
}

struct StatusPill: View {
    var status: JobStatus

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch status {
        case .succeeded: .green
        case .warning: .orange
        case .failed: .red
        case .running: .blue
        case .queued: .secondary
        case .cancelled: .gray
        }
    }
}

struct StateBadge: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

struct InlineWarning: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ActionLine: View {
    var description: String
    var buttonTitle: String
    var symbol: String
    var action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(description)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button(action: action) {
                Label(buttonTitle, systemImage: symbol)
            }
        }
    }
}

struct JobRow: View {
    var job: JobRun

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusPill(status: job.status)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.kind.displayName)
                    .font(.system(.body, design: .rounded))
                BackupRunSummaryLine(job: job)
            }
            Spacer()
            Text(job.startedAt.formatted(date: .abbreviated, time: .shortened))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

struct BackupRunSummaryLine: View {
    var job: JobRun

    var body: some View {
        if let summaryText {
            Text(summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var summaryText: String? {
        guard job.kind == .backup else {
            return nil
        }
        if let summary = ResticLogFormatter.backupSummary(from: job.message) {
            return summary.conciseText
        }
        return job.message?.localizedCaseInsensitiveContains("paused") == true ? job.message : nil
    }
}

struct EventRow: View {
    var event: EventLog

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.level == .error ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(event.level == .error ? .red : .secondary)
            Text(event.message)
            Spacer()
            Text(event.createdAt.formatted(date: .omitted, time: .shortened))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

struct LiveLogViewport: View {
    var lines: [ResticOutputEvent]
    var isWorking: Bool

    var body: some View {
        LogViewport(
            height: DeltaTheme.liveLogPaneHeight,
            itemCount: lines.count,
            bottomID: lines.last?.id
        ) {
            if lines.isEmpty {
                CompactEmptyRow(text: isWorking ? "Waiting for backup output..." : "No backup output is streaming right now.")
            } else {
                ForEach(lines) { line in
                    LiveLogRow(line: line)
                        .id(line.id)
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
    }
}

struct PersistentLogViewport: View {
    var entries: [JobLogEntry]
    var jobs: [JobRun]

    var body: some View {
        PlainLogViewport(height: DeltaTheme.savedLogPaneHeight) {
            if entries.isEmpty {
                CompactEmptyRow(text: "No saved job output yet.")
            } else {
                ForEach(jobLogGroups) { group in
                    SavedJobLogGroupView(group: group)
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
    }

    private var jobLogGroups: [SavedJobLogGroup] {
        let jobByID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        return Dictionary(grouping: entries, by: \.jobID)
            .map { jobID, entries in
                SavedJobLogGroup(
                    id: jobID,
                    job: jobByID[jobID],
                    entries: entries.sorted { $0.date < $1.date }
                )
            }
            .sorted { $0.latestDate > $1.latestDate }
    }
}

struct SavedJobLogGroup: Identifiable {
    var id: UUID
    var job: JobRun?
    var entries: [JobLogEntry]

    var latestDate: Date {
        entries.map(\.date).max() ?? .distantPast
    }
}

struct SavedJobLogGroupView: View {
    @EnvironmentObject private var model: DeltaAppModel
    var group: SavedJobLogGroup
    @State private var isExpanded = false
    @State private var loadedEntries: [JobLogEntry] = []

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(displayEntries) { entry in
                    PersistentLogRow(entry: entry, job: group.job)
                        .id(entry.id)
                }
            }
            .padding(.top, 6)
            .padding(.leading, 14)
        } label: {
            HStack(spacing: 10) {
                Text(jobTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(group.latestDate.formatted(date: .omitted, time: .standard))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(lineCountLabel)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded && loadedEntries.isEmpty {
                loadedEntries = model.savedLogs(for: group.id)
            }
        }
    }

    private var displayEntries: [JobLogEntry] {
        isExpanded && !loadedEntries.isEmpty ? loadedEntries : group.entries
    }

    private var lineCountLabel: String {
        if isExpanded && !loadedEntries.isEmpty {
            return "\(loadedEntries.count) \(loadedEntries.count == 1 ? "line" : "lines")"
        }
        return "\(group.entries.count) preview \(group.entries.count == 1 ? "line" : "lines")"
    }

    private var jobTitle: String {
        guard let job = group.job else {
            return "Job \(group.id.uuidString.prefix(8))"
        }
        return "\(job.kind.displayName) \(group.id.uuidString.prefix(6))"
    }
}

struct LogViewport<BottomID: Hashable, Content: View>: View {
    var height: CGFloat
    var itemCount: Int
    var bottomID: BottomID?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    content
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: height)
            .background(DeltaTheme.logPaneBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(DeltaTheme.border, lineWidth: 1)
            )
            .onAppear {
                scrollToBottom(with: proxy)
            }
            .onChange(of: itemCount) { _, _ in
                scrollToBottom(with: proxy)
            }
        }
    }

    private func scrollToBottom(with proxy: ScrollViewProxy) {
        guard let bottomID else {
            return
        }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.12)) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }
}

struct PlainLogViewport<Content: View>: View {
    var height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .background(DeltaTheme.logPaneBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(DeltaTheme.border, lineWidth: 1)
        )
    }
}

struct LiveLogRow: View {
    var line: ResticOutputEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.date.formatted(date: .omitted, time: .standard))
                .foregroundStyle(.tertiary)
                .frame(width: 72, alignment: .leading)
            Text(line.stream == .standardError ? "ERR" : "OUT")
                .foregroundStyle(line.stream == .standardError ? .orange : .secondary)
                .frame(width: 30, alignment: .leading)
            Text(line.message)
                .foregroundStyle(line.stream == .standardError ? .primary : .secondary)
                .lineLimit(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PersistentLogRow: View {
    var entry: JobLogEntry
    var job: JobRun?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.date.formatted(date: .omitted, time: .standard))
                .foregroundStyle(.tertiary)
                .frame(width: 72, alignment: .leading)
            Text(jobLabel)
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(entry.stream == .standardError ? "ERR" : "OUT")
                .foregroundStyle(entry.stream == .standardError ? .orange : .secondary)
                .frame(width: 30, alignment: .leading)
            Text(entry.message)
                .foregroundStyle(entry.stream == .standardError ? .primary : .secondary)
                .lineLimit(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var jobLabel: String {
        guard let job else {
            return String(entry.jobID.uuidString.prefix(8))
        }
        return "\(job.kind.displayName) \(entry.jobID.uuidString.prefix(6))"
    }
}

struct CompactEmptyRow: View {
    var text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }
}

enum DeltaTheme {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor).opacity(0.45)
    static let badge = Color(nsColor: .tertiarySystemFill)
    static let tooltipBackground = Color(nsColor: .windowBackgroundColor).opacity(0.98)
    static let logPaneBackground = Color(nsColor: .textBackgroundColor).opacity(0.16)
    static let liveLogPaneHeight: CGFloat = 300
    static let savedLogPaneHeight: CGFloat = 220
    static let statColumns = [
        GridItem(.adaptive(minimum: 190), spacing: 12)
    ]
}

private extension JobKind {
    var statusSymbol: String {
        switch self {
        case .initializeRepository:
            return "shippingbox.and.arrow.backward"
        case .backup:
            return "arrow.triangle.2.circlepath"
        case .restore:
            return "arrow.uturn.backward.circle"
        case .check:
            return "checkmark.shield"
        case .prune:
            return "scissors"
        }
    }
}
