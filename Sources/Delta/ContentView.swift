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
    @AppStorage(
        DeltaAppPreferenceKeys.backupFreshnessWarningHours,
        store: DeltaAppPreferences.sharedStore()
    ) private var backupFreshnessWarningHours = BackupFreshnessWarningThreshold.threeDays.rawValue
    @AppStorage(
        DeltaAppPreferenceKeys.destinationVerificationWarningHours,
        store: DeltaAppPreferences.sharedStore()
    ) private var destinationVerificationWarningHours = DestinationVerificationWarningThreshold.thirtyDays.rawValue
    @AppStorage(
        DeltaAppPreferenceKeys.pausesScheduledBackups,
        store: DeltaAppPreferences.sharedStore()
    ) private var pausesScheduledBackups = false

    var body: some View {
        PageScaffold(
            title: "Dashboard",
            subtitle: "Encrypted, deduplicated backup operations",
            actions: {
                Button {
                    model.runDueBackups()
                } label: {
                    Label(dashboardRunDueTitle, systemImage: model.isWorking ? "arrow.triangle.2.circlepath" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.profiles.isEmpty || model.isWorking || pausesScheduledBackups || !model.isPersistentStoreAvailable)
                .deltaTooltip(dashboardRunDueTooltip)
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

            if model.scheduledBackupsNeedAgentSetup && !pausesScheduledBackups {
                Card {
                    HStack(alignment: .top, spacing: 14) {
                        StatusIcon(symbol: "clock.badge.exclamationmark", color: .orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Scheduled Backups Need Approval")
                                .font(.headline)
                            Text(model.launchAgentStatus.detail)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.selectedSection = .settings
                        } label: {
                            Label("Review", systemImage: "arrow.right")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            if backgroundSecretAccessSummary.needsRepair && scheduledProfileCount > 0 {
                Card {
                    HStack(alignment: .top, spacing: 14) {
                        StatusIcon(symbol: "key.horizontal", color: .orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Password Access Needs Repair")
                                .font(.headline)
                            Text(backgroundSecretAccessSummary.detail)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.selectedSection = .settings
                        } label: {
                            Label("Repair", systemImage: "arrow.right")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            if pausesScheduledBackups && scheduledProfileCount > 0 {
                Card {
                    HStack(alignment: .top, spacing: 14) {
                        StatusIcon(symbol: "pause.circle", color: .orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Scheduled Backups Paused")
                                .font(.headline)
                            Text("Automatic due runs are paused. Manual Back Up Now actions still work for individual profiles.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            pausesScheduledBackups = false
                        } label: {
                            Label("Resume", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            if let operation = model.activeOperation {
                ActiveOperationBanner(
                    operation: operation,
                    progress: model.activeProgress,
                    progressFraction: model.activeDisplayedProgressFraction,
                    latestMessage: model.liveLogLines.last?.message,
                    stopRequest: model.activeStopRequest,
                    onPause: operation.kind == .backup ? { model.pauseActiveBackup() } : nil,
                    onCancel: { model.cancelActiveJob() }
                )
            }

            let sourceWarnings = sourceHealthWarnings
            if !sourceWarnings.isEmpty {
                DashboardHealthCard(
                    title: "Source Attention",
                    symbol: "folder.badge.questionmark",
                    warnings: sourceWarnings
                ) {
                    model.selectedSection = .backups
                }
            }

            let backupWarnings = backupHealthWarnings
            if !backupWarnings.isEmpty {
                DashboardHealthCard(
                    title: "Backup Attention",
                    symbol: "exclamationmark.arrow.triangle.2.circlepath",
                    warnings: backupWarnings
                ) {
                    model.selectedSection = .backups
                }
            }

            let destinationWarnings = destinationHealthWarnings
            if !destinationWarnings.isEmpty {
                DashboardHealthCard(
                    title: "Destination Attention",
                    symbol: "externaldrive.badge.exclamationmark",
                    warnings: destinationWarnings
                ) {
                    model.selectedSection = .repositories
                }
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

    private var backupHealthWarnings: [DashboardHealthWarning] {
        let threshold = BackupFreshnessWarningThreshold.normalized(backupFreshnessWarningHours)
        return DashboardHealthEvaluator().backupWarnings(
            profiles: model.profiles,
            jobs: model.jobs,
            threshold: threshold
        )
    }

    private var destinationHealthWarnings: [DashboardHealthWarning] {
        let threshold = DestinationVerificationWarningThreshold.normalized(destinationVerificationWarningHours)
        return DashboardHealthEvaluator().destinationWarnings(
            repositories: model.repositories,
            threshold: threshold
        )
    }

    private var sourceHealthWarnings: [DashboardHealthWarning] {
        model.sourceHealthWarnings
    }

    private var scheduledProfileCount: Int {
        model.profiles.filter { $0.schedule.isEnabled }.count
    }

    private var backgroundSecretAccessSummary: BackgroundSecretAccessSummary {
        BackgroundSecretAccessSummary(
            reports: model.backgroundSecretAccessReports,
            destinationCount: model.repositories.count
        )
    }

    private var dashboardRunDueTitle: String {
        if model.isWorking {
            return "Running"
        }
        if pausesScheduledBackups {
            return "Paused"
        }
        return "Run due"
    }

    private var dashboardRunDueTooltip: String {
        if model.isWorking {
            return "A Delta job is already running."
        }
        if pausesScheduledBackups {
            return "Scheduled backups are paused in Settings. Manual profile backups are still available."
        }
        return "Run every backup profile that is currently due."
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
                .frame(width: ModalMetrics.sheetWidth, height: 720)
        }
    }
}

private struct DashboardHealthCard: View {
    var title: String
    var symbol: String
    var warnings: [DashboardHealthWarning]
    var action: () -> Void

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                StatusIcon(symbol: symbol, color: primaryColor)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)
                        StateBadge(text: "\(warnings.count)", color: primaryColor)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(warnings) { warning in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(warning.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(warning.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                Spacer(minLength: 12)
                Button {
                    action()
                } label: {
                    Label("Review", systemImage: "arrow.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .deltaTooltip("Open the relevant page to review these health warnings.")
            }
        }
    }

    private var primaryColor: Color {
        warnings.contains(where: \.isCritical) ? .red : .orange
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
    @AppStorage(
        DeltaAppPreferenceKeys.previewsRestoresByDefault,
        store: DeltaAppPreferences.sharedStore()
    ) private var previewsRestoresByDefault = true
    @AppStorage(
        DeltaAppPreferenceKeys.verifiesRestoresByDefault,
        store: DeltaAppPreferences.sharedStore()
    ) private var verifiesRestoresByDefault = true
    @AppStorage(
        DeltaAppPreferenceKeys.defaultRestoreConflictPolicy,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultRestoreConflictPolicyRawValue = RestoreConflictPolicy.ifChanged.rawValue
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
    @State private var appliedRestoreDefaults: RestoreDefaults?

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
                                Text(restorePointLabel(for: snapshot)).tag(snapshot.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 420, alignment: .leading)
                    }

                    if let selectedRestorePointSummary {
                        RestoreFormRow(title: "") {
                            Text(selectedRestorePointSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
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

                        Toggle("Preview only", isOn: $dryRun)
                            .toggleStyle(.checkbox)
                        Toggle("Verify files", isOn: $verify)
                            .toggleStyle(.checkbox)
                            .disabled(dryRun)
                            .deltaTooltip(dryRun ? "Verification runs after a real restore writes files." : "Verify restored file contents after writing.")
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
            applyRestoreDefaultsIfNeeded()
            repositoryID = repositoryID ?? model.repositories.first?.id
            reconcileSelectedRestorePoint()
            refreshRestorePointsForSelectedRepository()
        }
        .onChange(of: repositoryID) { _, _ in
            snapshotID = ""
            resetBrowser()
            reconcileSelectedRestorePoint()
            refreshRestorePointsForSelectedRepository()
        }
        .onChange(of: restorePointIDs) { _, _ in
            reconcileSelectedRestorePoint()
        }
        .onChange(of: snapshotID) { _, _ in
            resetBrowser()
        }
        .onChange(of: restoreDefaults) { _, _ in
            applyRestoreDefaultsIfNeeded()
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

    private var restorePointIDs: [String] {
        repositorySnapshots.map(\.id)
    }

    private var selectedSnapshot: ResticSnapshot? {
        repositorySnapshots.first { $0.id == snapshotID }
    }

    private var backupSummariesByRestorePoint: [String: ResticBackupSummary] {
        var summaries: [String: ResticBackupSummary] = [:]
        for job in model.jobs.sorted(by: { $0.startedAt > $1.startedAt }) where job.kind == .backup {
            guard
                let summary = job.backupSummary ?? ResticLogFormatter.backupSummary(from: job.message),
                let snapshotID = summary.snapshotID,
                summaries[RestorePointSelection.scopedSummaryKey(destinationID: job.repositoryID, restorePointID: snapshotID)] == nil
            else {
                continue
            }
            summaries[RestorePointSelection.scopedSummaryKey(destinationID: job.repositoryID, restorePointID: snapshotID)] = summary
        }
        return summaries
    }

    private var selectedRestorePointSummary: String? {
        guard
            let repositoryID,
            let selectedSnapshot,
            let summary = backupSummariesByRestorePoint[RestorePointSelection.scopedSummaryKey(destinationID: repositoryID, restorePointID: selectedSnapshot.id)]
        else {
            return nil
        }
        return "Backup changes: \(summary.detailedText)"
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
        let destinationIsValid = restoreOriginalPaths || !destinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let inPlaceIsAcknowledged = !restoreOriginalPaths || dryRun || acknowledgedInPlaceRestore
        return selectedRepository != nil && !snapshotID.isEmpty && destinationIsValid && inPlaceIsAcknowledged
    }

    private var restoreDefaults: RestoreDefaults {
        RestoreDefaults.normalized(
            previewFirst: previewsRestoresByDefault,
            verifyRestoredFiles: verifiesRestoresByDefault,
            conflictPolicyRawValue: defaultRestoreConflictPolicyRawValue
        )
    }

    private var hasRestoreDraft: Bool {
        !selectedRestorePaths.isEmpty
            || !destinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || restoreOriginalPaths
            || preRestoreProfileID != nil
            || acknowledgedInPlaceRestore
            || restoreControlsDifferFromAppliedDefaults
    }

    private var restoreControlsDifferFromAppliedDefaults: Bool {
        guard let appliedRestoreDefaults else {
            return false
        }
        return dryRun != appliedRestoreDefaults.previewFirst
            || verify != appliedRestoreDefaults.verifyRestoredFiles
            || conflictPolicy != appliedRestoreDefaults.conflictPolicy
    }

    private func runRestore() {
        guard let repository = selectedRepository else { return }
        let paths = normalizedSelectedRestorePaths
        let request = RestoreRequest(
            repositoryID: repository.id,
            snapshotID: snapshotID,
            scope: paths.isEmpty ? .fullSnapshot : .selectedPaths(paths),
            destination: restoreOriginalPaths ? .originalPaths : .chosenFolder(destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)),
            conflictPolicy: conflictPolicy,
            verifyRestoredFiles: verify,
            dryRun: dryRun,
            confirmedOriginalPathRestore: restoreOriginalPaths && !dryRun && acknowledgedInPlaceRestore,
            preRestoreBackupProfileID: preRestoreProfileID
        )
        model.runRestore(repository: repository, request: request)
    }

    private func applyRestoreDefaultsIfNeeded() {
        let defaults = restoreDefaults
        guard appliedRestoreDefaults != defaults else {
            return
        }
        guard appliedRestoreDefaults == nil || !hasRestoreDraft else {
            return
        }
        dryRun = defaults.previewFirst
        verify = defaults.verifyRestoredFiles
        conflictPolicy = defaults.conflictPolicy
        appliedRestoreDefaults = defaults
    }

    private func restorePointLabel(for snapshot: ResticSnapshot) -> String {
        let base = "\(snapshot.time.formatted(date: .abbreviated, time: .shortened)) · \(snapshot.id.prefix(8))"
        guard
            let repositoryID,
            let summary = backupSummariesByRestorePoint[RestorePointSelection.scopedSummaryKey(destinationID: repositoryID, restorePointID: snapshot.id)]
        else {
            return base
        }
        return "\(base) · \(summary.conciseText)"
    }

    private func reconcileSelectedRestorePoint() {
        let nextSnapshotID = RestorePointSelection.reconciledSelection(currentID: snapshotID, availableIDs: restorePointIDs)
        guard snapshotID != nextSnapshotID else {
            return
        }
        snapshotID = nextSnapshotID
        resetBrowser()
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
    @AppStorage(
        DeltaAppPreferenceKeys.activityLogDetail,
        store: DeltaAppPreferences.sharedStore()
    ) private var activityLogDetailRawValue = ActivityLogDetail.standard.rawValue

    var body: some View {
        PageScaffold(title: "Activity", subtitle: "Jobs, destination checks, and system events") {
            SurfaceSection(title: "Live Backup Logs", symbol: "terminal") {
                LiveLogViewport(
                    lines: Array(model.liveLogLines.suffix(activityLogDetail.liveLineLimit)),
                    isWorking: model.isWorking
                )
            }

            SurfaceSection(title: "Saved Job Logs", symbol: "doc.text.magnifyingglass") {
                PersistentLogViewport(
                    entries: Array(model.jobLogs.suffix(activityLogDetail.savedPreviewLineLimit)),
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

    private var activityLogDetail: ActivityLogDetail {
        ActivityLogDetail.normalized(activityLogDetailRawValue)
    }
}

private enum ActivityLogDetail: String, CaseIterable, Identifiable {
    case compact
    case standard
    case detailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "Compact"
        case .standard: "Standard"
        case .detailed: "Detailed"
        }
    }

    var description: String {
        switch self {
        case .compact:
            return "Show fewer lines for quieter troubleshooting."
        case .standard:
            return "Balanced live output and saved job previews."
        case .detailed:
            return "Show more output when diagnosing long-running jobs."
        }
    }

    var liveLineLimit: Int {
        switch self {
        case .compact: 120
        case .standard: 300
        case .detailed: 500
        }
    }

    var savedPreviewLineLimit: Int {
        switch self {
        case .compact: 120
        case .standard: 240
        case .detailed: 500
        }
    }

    static func normalized(_ rawValue: String) -> ActivityLogDetail {
        ActivityLogDetail(rawValue: rawValue) ?? .standard
    }
}

struct SettingsView: View {
    private enum SettingsCategory: CaseIterable, Identifiable {
        case essentials
        case defaults
        case updates
        case support

        var id: String { title }

        var title: String {
            switch self {
            case .essentials:
                return SettingsSurfaceContract.categoryGeneral
            case .defaults:
                return SettingsSurfaceContract.categoryDefaults
            case .updates:
                return SettingsSurfaceContract.categoryUpdates
            case .support:
                return SettingsSurfaceContract.categoryAdvanced
            }
        }
    }

    @EnvironmentObject private var model: DeltaAppModel
    @EnvironmentObject private var softwareUpdateController: SoftwareUpdateController
    @State private var settingsCategory: SettingsCategory = .essentials
    @AppStorage(
        DeltaAppPreferenceKeys.updateCheckIntervalSeconds,
        store: DeltaAppPreferences.sharedStore()
    ) private var updateCheckIntervalSeconds = AppUpdateCheckInterval.daily.rawValue
    @AppStorage(
        DeltaAppPreferenceKeys.activityLogDetail,
        store: DeltaAppPreferences.sharedStore()
    ) private var activityLogDetailRawValue = ActivityLogDetail.standard.rawValue
    @AppStorage(
        DeltaAppPreferenceKeys.operationalHistoryRetentionDays,
        store: DeltaAppPreferences.sharedStore()
    ) private var operationalHistoryRetentionDays = OperationalHistoryRetention.ninetyDays.rawValue
    @AppStorage(
        DeltaAppPreferenceKeys.backupFreshnessWarningHours,
        store: DeltaAppPreferences.sharedStore()
    ) private var backupFreshnessWarningHours = BackupFreshnessWarningThreshold.threeDays.rawValue
    @AppStorage(
        DeltaAppPreferenceKeys.destinationVerificationWarningHours,
        store: DeltaAppPreferences.sharedStore()
    ) private var destinationVerificationWarningHours = DestinationVerificationWarningThreshold.thirtyDays.rawValue
    @AppStorage(
        DeltaAppPreferenceKeys.previewsRestoresByDefault,
        store: DeltaAppPreferences.sharedStore()
    ) private var previewsRestoresByDefault = true
    @AppStorage(
        DeltaAppPreferenceKeys.verifiesRestoresByDefault,
        store: DeltaAppPreferences.sharedStore()
    ) private var verifiesRestoresByDefault = true
    @AppStorage(
        DeltaAppPreferenceKeys.defaultRestoreConflictPolicy,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultRestoreConflictPolicyRawValue = RestoreConflictPolicy.ifChanged.rawValue
    @AppStorage(
        DeltaAppPreferenceKeys.pausesScheduledBackups,
        store: DeltaAppPreferences.sharedStore()
    ) private var pausesScheduledBackups = false
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfileCatchUpMissedRuns,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileCatchUpMissedRuns = true
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfileRunOnBattery,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileRunOnBattery = true
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfileRunInLowPowerMode,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileRunInLowPowerMode = false
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfilePruneAfterForget,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfilePruneAfterForget = true
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfileCheckAfterPrune,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileCheckAfterPrune = true
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfileUploadLimitKiB,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileUploadLimitKiB = 0
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfileDownloadLimitKiB,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileDownloadLimitKiB = 0
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfileKeepHourly,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileKeepHourly = 24
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfileKeepDaily,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileKeepDaily = 30
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfileKeepWeekly,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileKeepWeekly = 12
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfileKeepMonthly,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileKeepMonthly = 12
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfileKeepYearly,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileKeepYearly = 0
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfileMaintenanceEnabled,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileMaintenanceEnabled = true
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfileMaintenanceIntervalDays,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileMaintenanceIntervalDays = 7
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfileMaintenanceHour,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileMaintenanceHour = 2
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfileMaintenanceMinute,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileMaintenanceMinute = 0
    @AppStorage(
        DeltaAppPreferenceKeys.sendsJobNotifications,
        store: DeltaAppPreferences.sharedStore()
    ) private var sendsJobNotifications = false
    @AppStorage(
        DeltaAppPreferenceKeys.sendsSuccessfulBackupNotifications,
        store: DeltaAppPreferences.sharedStore()
    ) private var sendsSuccessfulBackupNotifications = false
    @AppStorage(
        DeltaAppPreferenceKeys.preventsIdleSleepDuringJobs,
        store: DeltaAppPreferences.sharedStore()
    ) private var preventsIdleSleepDuringJobs = true
    @AppStorage(
        DeltaAppPreferenceKeys.showsMenuBarExtra,
        store: DeltaAppPreferences.sharedStore()
    ) private var showsMenuBarExtra = true
    @State private var automaticallyChecksForUpdates = true
    @State private var automaticallyDownloadsUpdates = false
    @State private var notificationAuthorizationState: DeltaNotificationAuthorizationState = .notDetermined

    var body: some View {
        PageScaffold(
            title: "Settings",
            subtitle: "System access, background backups, updates, and safe defaults",
            actions: {
                Button {
                    model.reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        ) {
            if let persistentStoreErrorMessage = model.persistentStoreErrorMessage {
                SettingsCard(
                    symbol: "externaldrive.badge.exclamationmark",
                    title: "Local App Data",
                    subtitle: "Delta cannot open its local database.",
                    statusText: "Blocked",
                    statusColor: .red
                ) {
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

            SettingsOverviewCard(
                symbol: settingsOverviewSymbol,
                title: settingsOverviewTitle,
                detail: settingsOverviewDetail,
                statusText: settingsOverviewStatusText,
                statusColor: settingsOverviewStatusColor,
                items: settingsStatusItems
            )

            Picker("Settings Group", selection: $settingsCategory) {
                ForEach(SettingsCategory.allCases) { category in
                    Text(category.title).tag(category)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520, alignment: .leading)
            .accessibilityLabel("Settings group")

            if settingsCategory == .essentials {
                SettingsSectionLabel(
                    title: "Background Backups",
                    subtitle: "Unattended scheduling, macOS approval, and reliability controls."
                )

                SettingsCard(
                    symbol: "clock.badge.checkmark",
                    title: "Background Backup Service",
                    subtitle: "Run scheduled profiles while Delta's main window is closed.",
                    statusText: backgroundBackupsPresentation.statusText,
                    statusColor: backgroundBackupsStatusColor
                ) {
                SettingsControlRow(
                    title: "Background backups",
                    detail: backgroundBackupsPresentation.controlDetail
                ) {
                    Toggle("", isOn: backgroundBackupsBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsControlRow(
                    title: "Pause scheduled automation",
                    detail: "Temporarily stop hourly, daily, weekly, monthly, and custom due runs without editing profiles or removing macOS approval."
                ) {
                    Toggle("", isOn: $pausesScheduledBackups)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsNotice(
                    symbol: "clock.arrow.circlepath",
                    title: "What runs in the background",
                    text: BackgroundBackupServicePresentation.purposeText,
                    color: .blue
                )

                SettingsCapabilityList(items: [
                    SettingsCapability(symbol: "moon.zzz", title: "Works with the window closed", detail: "Scheduled profiles can run after sign-in without keeping the main app open."),
                    SettingsCapability(symbol: "person.crop.circle", title: "Runs as your user", detail: "No admin helper, no elevated privileges, and the same file permissions you granted to Delta."),
                    SettingsCapability(symbol: "bolt.badge.checkmark", title: "Honors backup policy", detail: "Battery, Low Power Mode, speed limits, destination availability, and locking are checked before work starts.")
                ])

                SettingsFactGrid(items: [
                    SettingsFact(title: "Scheduled profiles", value: "\(scheduledProfileCount)"),
                    SettingsFact(title: "Automation", value: pausesScheduledBackups ? "Paused" : "Running"),
                    SettingsFact(title: "Passwords", value: backgroundSecretAccessSummary.displayName),
                    SettingsFact(title: "Check cadence", value: "Every 5 min"),
                    SettingsFact(title: "Sign-in check", value: "Enabled"),
                    SettingsFact(title: "Runs as", value: "Your user"),
                    SettingsFact(title: "Admin access", value: "No"),
                    SettingsFact(title: "Login Items approval", value: backgroundBackupsPresentation.approvalText)
                ])

                if backgroundBackupsPresentation.needsAttention {
                    SettingsNotice(
                        symbol: "person.crop.circle.badge.exclamationmark",
                        title: backgroundBackupsPresentation.attentionTitle ?? "Background backups need attention",
                        text: backgroundBackupsPresentation.attentionText ?? "Review Background Backups before relying on scheduled runs.",
                        color: .orange
                    )
                }

                if backgroundSecretAccessSummary.needsRepair {
                    SettingsNotice(
                        symbol: "key.horizontal",
                        title: "Password access needs repair",
                        text: "\(backgroundSecretAccessSummary.detail) Repair access so scheduled backups can read saved destination passwords without Keychain prompts.",
                        color: .orange
                    )
                }

                if scheduledProfileCount == 0 && !backgroundBackupsPresentation.needsAttention && !backgroundSecretAccessSummary.needsRepair {
                    SettingsNotice(
                        symbol: "calendar.badge.plus",
                        title: "No scheduled profiles",
                        text: "Create an hourly, daily, weekly, monthly, or custom scheduled backup profile before background backups are needed.",
                        color: .secondary
                    )
                }

                SettingsActionBar {
                    Button {
                        model.runDueBackups()
                    } label: {
                        Label("Run Due Now", systemImage: "play.fill")
                    }
                    .disabled(model.profiles.isEmpty || model.isWorking || pausesScheduledBackups || !model.isPersistentStoreAvailable)
                    .deltaTooltip(pausesScheduledBackups ? "Scheduled automation is paused. Resume it here or run a manual profile backup." : "Run every backup profile that is currently due using the same scheduler path.")
                    Button {
                        model.openLoginItemsSettings()
                    } label: {
                        Label("Review Login Items", systemImage: "gearshape")
                    }
                    .deltaTooltip("Open macOS Login Items to approve or inspect Delta's background backup service.")
                    Button {
                        model.reload()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .deltaTooltip("Recheck background backup and system access status.")
                    Button {
                        model.repairBackgroundSecretAccess()
                    } label: {
                        Label("Repair Password Access", systemImage: "key")
                    }
                    .disabled(model.repositories.isEmpty || model.isWorking || !model.isPersistentStoreAvailable)
                    .deltaTooltip("Refresh saved destination passwords so background backups can read them without interactive Keychain prompts.")
                }
            }

                SettingsCard(
                symbol: "lock.shield",
                title: "Full Disk Access",
                subtitle: "Allow Delta to read protected folders during full-volume and user-folder backups.",
                statusText: fullDiskAccessStatusText,
                statusColor: model.fullDiskAccessStatus.hasLikelyFullDiskAccess ? .green : .orange
            ) {
                SettingsDescription(
                    text: fullDiskAccessDescription
                )

                SettingsFactGrid(items: [
                    SettingsFact(title: "Protected folders", value: model.fullDiskAccessStatus.hasLikelyFullDiskAccess ? "Readable" : "Blocked"),
                    SettingsFact(title: "Approval", value: "Manual in macOS"),
                    SettingsFact(title: "Best install path", value: "/Applications")
                ])

                SettingsDescription(
                    text: "For development builds, keep Delta installed in /Applications with the same signing identity. macOS ties privacy approval to the signed app identity, so changing that identity can require approval again."
                )

                SettingsActionBar {
                    Button {
                        model.openFullDiskAccessSettings()
                    } label: {
                        Label("Open Privacy Settings", systemImage: "arrow.up.forward.app")
                    }
                    .deltaTooltip("Open Full Disk Access in macOS Privacy & Security.")
                    Button {
                        model.revealInstalledAppInFinder()
                    } label: {
                        Label("Show Delta", systemImage: "folder")
                    }
                    .deltaTooltip("Show the installed Delta app that should be added to Full Disk Access.")
                    Button {
                        model.reload()
                    } label: {
                        Label("Recheck", systemImage: "arrow.clockwise")
                    }
                    .deltaTooltip("Recheck whether protected folders are readable.")
                }
            }

                SettingsCard(
                symbol: "powerplug",
                title: "Power & Reliability",
                subtitle: "Reduce the chance of long-running work being interrupted by idle sleep.",
                statusText: preventsIdleSleepDuringJobs ? "Protected" : "Off",
                statusColor: preventsIdleSleepDuringJobs ? .green : .secondary
            ) {
                SettingsControlRow(
                    title: "Keep Mac awake during backup work",
                    detail: "Prevent idle sleep while Delta is actively preparing, backing up, restoring, checking, or cleaning up a destination."
                ) {
                    Toggle("", isOn: $preventsIdleSleepDuringJobs)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsFactGrid(items: [
                    SettingsFact(title: "Applies to", value: "Active jobs"),
                    SettingsFact(title: "Sleep type", value: "Idle sleep"),
                    SettingsFact(title: "Scheduling", value: "Policy honored")
                ])

                SettingsDescription(
                    text: "This does not override battery or Low Power Mode scheduling rules. It only keeps an already-started job from being paused because the Mac went idle."
                )
            }

                SettingsSectionLabel(
                    title: "App Behavior",
                    subtitle: "Controls for Delta's menu bar, sign-in behavior, and macOS alerts."
                )

                SettingsCard(
                    symbol: "menubar.rectangle",
                    title: "Menu Bar & Login",
                    subtitle: "Keep Delta's quick actions visible and optionally open the app at sign-in.",
                    statusText: menuBarAndLoginStatusText,
                    statusColor: menuBarAndLoginStatusColor
                ) {
                SettingsControlRow(
                    title: "Status menu",
                    detail: "Keep Back Up Now, Run Due Backups, Pause, Stop, last backup status, activity, and update checks available outside the main window."
                ) {
                    Toggle("", isOn: $showsMenuBarExtra)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsControlRow(
                    title: "Start Delta at login",
                    detail: "Open the Delta app after you sign in so the menu bar controls and dashboard are immediately available."
                ) {
                    Toggle("", isOn: appLoginItemBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsFactGrid(items: [
                    SettingsFact(title: "Menu bar", value: showsMenuBarExtra ? "Shown" : "Hidden"),
                    SettingsFact(title: "Start at login", value: appLoginItemStatusText),
                    SettingsFact(title: "Background backups", value: "Separate")
                ])

                SettingsDescription(
                    text: "Start at login opens Delta for convenience. Background Backups above are what actually run scheduled backups when the window is closed."
                )

                if model.appLoginItemStatus == .requiresApproval {
                    SettingsNotice(
                        symbol: "person.crop.circle.badge.exclamationmark",
                        title: "Login Items approval required",
                        text: "macOS may ask you to approve Delta before it can open automatically at sign-in.",
                        color: .orange
                    )
                }

                SettingsActionBar {
                    Button {
                        model.openLoginItemsSettings()
                    } label: {
                        Label("Open Login Items", systemImage: "gearshape")
                    }
                    .deltaTooltip("Open macOS Login Items to approve or inspect Delta startup.")
                    Button {
                        model.reload()
                    } label: {
                        Label("Refresh Status", systemImage: "arrow.clockwise")
                    }
                    .deltaTooltip("Recheck Delta's menu bar and login status.")
                }
            }

                SettingsCard(
                symbol: "bell.badge",
                title: "Notifications",
                subtitle: "Show macOS alerts when backup work needs attention.",
                statusText: notificationStatusText,
                statusColor: notificationStatusColor
            ) {
                SettingsControlRow(
                    title: "Job alerts",
                    detail: "Notify when a backup, restore, destination check, or cleanup fails or finishes with warnings."
                ) {
                    Toggle("", isOn: $sendsJobNotifications)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: sendsJobNotifications) { _, enabled in
                            if enabled {
                                requestNotificationPermission()
                            } else {
                                sendsSuccessfulBackupNotifications = false
                            }
                        }
                }

                SettingsControlRow(
                    title: "Success summaries",
                    detail: "Also notify when a backup finishes successfully with its new, changed, and checked file summary."
                ) {
                    Toggle("", isOn: $sendsSuccessfulBackupNotifications)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!sendsJobNotifications)
                }

                SettingsFactGrid(items: [
                    SettingsFact(title: "macOS permission", value: notificationAuthorizationState.displayName),
                    SettingsFact(title: "Failure alerts", value: sendsJobNotifications ? "On" : "Off"),
                    SettingsFact(title: "Success alerts", value: sendsSuccessfulBackupNotifications ? "On" : "Off"),
                    SettingsFact(title: "Test alert", value: notificationTestAlertStatusText)
                ])

                SettingsActionBar {
                    Button {
                        sendTestNotification()
                    } label: {
                        Label("Send Test Alert", systemImage: "bell.and.waves.left.and.right")
                    }
                    .disabled(!canSendTestNotification)
                    .deltaTooltip(notificationTestAlertTooltip)

                    Button {
                        requestNotificationPermission()
                    } label: {
                        Label("Request Permission", systemImage: "bell.badge")
                    }
                    .disabled(notificationAuthorizationState.canDeliver)
                    .deltaTooltip("Ask macOS for permission to show Delta backup alerts.")

                    Button {
                        model.openNotificationSettings()
                    } label: {
                        Label("Open Notifications", systemImage: "gearshape")
                    }
                    .deltaTooltip("Open macOS Notifications settings for Delta.")

                    Button {
                        refreshNotificationAuthorization()
                    } label: {
                        Label("Refresh Status", systemImage: "arrow.clockwise")
                    }
                    .deltaTooltip("Recheck macOS notification permission.")
                }
            }
            }

            if settingsCategory == .defaults {
                SettingsSectionLabel(
                    title: "Backup & Restore Defaults",
                    subtitle: "Recommended defaults for newly created profiles and restore jobs."
                )

                SettingsCard(
                    symbol: "heart.text.square",
                    title: "Health Monitoring",
                    subtitle: "Dashboard attention thresholds for missed backups and destination integrity checks.",
                    statusText: healthMonitoringStatusText,
                    statusColor: healthMonitoringStatusColor
                ) {
                SettingsControlRow(
                    title: "Backup freshness",
                    detail: "Show dashboard attention when a scheduled profile has no completed backup or its last completed backup is older than this."
                ) {
                    Picker("", selection: $backupFreshnessWarningHours) {
                        ForEach(BackupFreshnessWarningThreshold.allCases) { threshold in
                            Text(threshold.title).tag(threshold.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                    .onChange(of: backupFreshnessWarningHours) { _, _ in
                        normalizeHealthMonitoring()
                    }
                }

                SettingsControlRow(
                    title: "Destination checks",
                    detail: "Show dashboard attention when a destination has never been checked, is unavailable locally, or its last check is older than this."
                ) {
                    Picker("", selection: $destinationVerificationWarningHours) {
                        ForEach(DestinationVerificationWarningThreshold.allCases) { threshold in
                            Text(threshold.title).tag(threshold.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                    .onChange(of: destinationVerificationWarningHours) { _, _ in
                        normalizeHealthMonitoring()
                    }
                }

                SettingsFactGrid(items: [
                    SettingsFact(title: "Backups", value: backupFreshnessThreshold.summaryText),
                    SettingsFact(title: "Destinations", value: destinationVerificationThreshold.summaryText),
                    SettingsFact(title: "Dashboard", value: "Attention only"),
                    SettingsFact(title: "Profiles", value: "Unchanged")
                ])

                SettingsActionBar {
                    Button {
                        resetHealthMonitoringDefaults()
                    } label: {
                        Label("Restore Recommended", systemImage: "arrow.counterclockwise")
                    }
                    Button {
                        model.selectedSection = .dashboard
                    } label: {
                        Label("Open Dashboard", systemImage: "rectangle.grid.2x2")
                    }
                }
            }

                SettingsCard(
                symbol: "slider.horizontal.3",
                title: "New Backup Defaults",
                subtitle: "Defaults applied when creating a profile. Existing profiles keep their own settings.",
                statusText: backupDefaultsStatusText,
                statusColor: backupDefaultsStatusColor
            ) {
                SettingsControlRow(
                    title: "Catch up missed runs",
                    detail: "Run one backup after a scheduled time was missed because the Mac was asleep, offline, or the destination was unavailable."
                ) {
                    Toggle("", isOn: $defaultProfileCatchUpMissedRuns)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsControlRow(
                    title: "Run on battery",
                    detail: "Allow scheduled backups when the Mac is not connected to power."
                ) {
                    Toggle("", isOn: $defaultProfileRunOnBattery)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsControlRow(
                    title: "Run in Low Power Mode",
                    detail: "Allow scheduled backups even when macOS is conserving power."
                ) {
                    Toggle("", isOn: $defaultProfileRunInLowPowerMode)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsControlRow(
                    title: "Free space after cleanup",
                    detail: "After old restore points are forgotten, remove unreferenced backup data from the destination."
                ) {
                    Toggle("", isOn: $defaultProfilePruneAfterForget)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsControlRow(
                    title: "Verify after cleanup",
                    detail: "Run a destination check after cleanup to confirm backup data is still readable."
                ) {
                    Toggle("", isOn: $defaultProfileCheckAfterPrune)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsControlRow(
                    title: "Default speed limits",
                    detail: "Optional upload and download caps for new profiles. Leave blank for unlimited."
                ) {
                    HStack(spacing: 8) {
                        TextField("Upload KiB/s", text: defaultUploadLimitBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 112)
                        TextField("Download KiB/s", text: defaultDownloadLimitBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 128)
                    }
                }

                SettingsControlRow(
                    title: "Default retention",
                    detail: "How many restore points new profiles keep before scheduled cleanup removes older ones."
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Stepper("Hourly \(defaultProfileKeepHourly)", value: $defaultProfileKeepHourly, in: 0...168)
                                .frame(width: 100, alignment: .leading)
                            Stepper("Daily \(defaultProfileKeepDaily)", value: $defaultProfileKeepDaily, in: 0...365)
                                .frame(width: 100, alignment: .leading)
                            Stepper("Weekly \(defaultProfileKeepWeekly)", value: $defaultProfileKeepWeekly, in: 0...260)
                                .frame(width: 104, alignment: .leading)
                        }
                        HStack(spacing: 8) {
                            Stepper("Monthly \(defaultProfileKeepMonthly)", value: $defaultProfileKeepMonthly, in: 0...120)
                                .frame(width: 112, alignment: .leading)
                            Stepper("Yearly \(defaultProfileKeepYearly)", value: $defaultProfileKeepYearly, in: 0...50)
                                .frame(width: 100, alignment: .leading)
                        }
                    }
                }

                SettingsControlRow(
                    title: "Automatic cleanup",
                    detail: "Create new profiles with scheduled cleanup for old restore points."
                ) {
                    Toggle("", isOn: $defaultProfileMaintenanceEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsControlRow(
                    title: "Cleanup cadence",
                    detail: "How often new profiles should free unneeded data and run post-cleanup checks."
                ) {
                    HStack(spacing: 10) {
                        Stepper("Every \(defaultProfileMaintenanceIntervalDays)d", value: $defaultProfileMaintenanceIntervalDays, in: 1...90)
                            .frame(width: 130, alignment: .leading)
                        TimeControls(hour: $defaultProfileMaintenanceHour, minute: $defaultProfileMaintenanceMinute)
                    }
                    .disabled(!defaultProfileMaintenanceEnabled)
                }

                SettingsFactGrid(items: [
                    SettingsFact(title: "Schedule", value: "Daily 20:00"),
                    SettingsFact(title: "Retention", value: defaultRetentionSummary),
                    SettingsFact(title: "Bandwidth", value: defaultBandwidthSummary),
                    SettingsFact(title: "Cleanup", value: defaultCleanupSummary),
                    SettingsFact(title: "Destination locks", value: "Automatic"),
                    SettingsFact(title: "Backup type", value: "Incremental"),
                    SettingsFact(title: "Existing profiles", value: "Unchanged")
                ])

                SettingsActionBar {
                    Button {
                        resetBackupDefaults()
                    } label: {
                        Label("Restore Recommended", systemImage: "arrow.counterclockwise")
                    }
                    Button {
                        model.selectedSection = .backups
                    } label: {
                        Label("Manage Profiles", systemImage: "externaldrive.badge.plus")
                    }
                    Button {
                        model.selectedSection = .repositories
                    } label: {
                        Label("Manage Destinations", systemImage: "externaldrive.connected.to.line.below")
                    }
                }
            }

                SettingsCard(
                symbol: "arrow.uturn.backward.circle",
                title: "Restore Defaults",
                subtitle: "Safety defaults used when the Restore page opens.",
                statusText: restoreDefaultsStatusText,
                statusColor: restoreDefaultsStatusColor
            ) {
                SettingsControlRow(
                    title: "Preview first",
                    detail: "Open restores as a preview so Delta shows what would happen before writing files."
                ) {
                    Toggle("", isOn: $previewsRestoresByDefault)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsControlRow(
                    title: "Verify files",
                    detail: "Ask the backup engine to verify restored file content after writes complete."
                ) {
                    Toggle("", isOn: $verifiesRestoresByDefault)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsControlRow(
                    title: "Existing files",
                    detail: "Default overwrite policy for files that already exist at the restore destination."
                ) {
                    Picker("", selection: $defaultRestoreConflictPolicyRawValue) {
                        ForEach(RestoreConflictPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    .onChange(of: defaultRestoreConflictPolicyRawValue) { _, _ in
                        normalizeRestorePreferences()
                    }
                }

                SettingsDescription(
                    text: "These defaults keep restores conservative without hiding control. Each restore can still be changed before previewing or running it."
                )

                SettingsActionBar {
                    Button {
                        resetRestoreDefaults()
                    } label: {
                        Label("Restore Recommended", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            }

            if settingsCategory == .updates {
                SettingsSectionLabel(
                    title: "Updates",
                    subtitle: "Signed update checks and install behavior."
                )

                SettingsCard(
                    symbol: "arrow.down.circle",
                    title: "Automatic Updates",
                    subtitle: "Check for signed Delta releases using Sparkle.",
                    statusText: automaticUpdatesStatusText,
                    statusColor: automaticUpdatesStatusColor
                ) {
                SettingsControlRow(
                    title: "Automatic checks",
                    detail: "Delta verifies signed update packages before installing them."
                ) {
                    Toggle("", isOn: $automaticallyChecksForUpdates)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: automaticallyChecksForUpdates) { _, _ in
                            applyUpdatePreferences()
                        }
                }

                SettingsControlRow(
                    title: "Check interval",
                    detail: "How often Delta asks Sparkle to check for a newer build."
                ) {
                    Picker("", selection: $updateCheckIntervalSeconds) {
                        ForEach(AppUpdateCheckInterval.allCases) { interval in
                            Text(interval.title).tag(interval.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 250)
                    .disabled(!automaticallyChecksForUpdates)
                    .onChange(of: updateCheckIntervalSeconds) { _, _ in
                        applyUpdatePreferences()
                    }
                }

                SettingsControlRow(
                    title: "Download in background",
                    detail: "Let Sparkle download signed updates after it finds them, then prompt before replacing Delta."
                ) {
                    Toggle("", isOn: $automaticallyDownloadsUpdates)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!automaticallyChecksForUpdates || !softwareUpdateController.allowsAutomaticUpdates)
                        .onChange(of: automaticallyDownloadsUpdates) { _, _ in
                            applyUpdatePreferences()
                        }
                }

                SettingsFactGrid(items: [
                    SettingsFact(title: "Checks", value: automaticallyChecksForUpdates ? AppUpdateCheckInterval.normalized(updateCheckIntervalSeconds).title : "Off"),
                    SettingsFact(title: "Downloads", value: automaticallyDownloadsUpdates && automaticallyChecksForUpdates ? "Background" : "Manual"),
                    SettingsFact(title: "Packages", value: "Signed"),
                    SettingsFact(title: "Install", value: "Prompted")
                ])

                SettingsActionBar {
                    Button {
                        softwareUpdateController.checkForUpdates()
                    } label: {
                        Label("Check Now", systemImage: "arrow.clockwise")
                    }
                    .disabled(!softwareUpdateController.canCheckForUpdates)
                }
            }
            }

            if settingsCategory == .support {
                SettingsSectionLabel(
                    title: "Support",
                    subtitle: "Diagnostics and local files for troubleshooting without exposing secrets."
                )

                SettingsCard(
                    symbol: "info.circle",
                    title: "About Delta",
                    subtitle: "Build and local state used when troubleshooting.",
                    statusText: appVersionStatusText,
                    statusColor: .blue
                ) {
                SettingsFactGrid(items: [
                    SettingsFact(title: "Version", value: appVersion),
                    SettingsFact(title: "Build", value: buildVersion),
                    SettingsFact(title: "Bundle ID", value: bundleIdentifier),
                    SettingsFact(title: "Profiles", value: "\(model.profiles.count)"),
                    SettingsFact(title: "Destinations", value: "\(model.repositories.count)"),
                    SettingsFact(title: "Restore points", value: "\(model.snapshots.count)")
                ])

                SettingsDescription(
                    text: "Install and update Delta from the signed app in /Applications to keep macOS privacy approvals stable across builds."
                )
            }

                SettingsCard(
                symbol: "externaldrive.badge.checkmark",
                title: "Backup Tools",
                subtitle: "Bundled engines Delta uses for encrypted backups and remote destinations.",
                statusText: backupToolStatusText,
                statusColor: backupToolStatusColor
            ) {
                SettingsFactGrid(items: [
                    SettingsFact(title: "Backup engine", value: isResticExecutableAvailable ? "Ready" : "Missing"),
                    SettingsFact(title: "Cloud helper", value: isRcloneExecutableAvailable ? "Ready" : "Missing"),
                    SettingsFact(title: "Install mode", value: "Bundled")
                ])

                SettingsDescription(
                    text: "Delta uses its bundled, signed backup tools so scheduled jobs and restores run with the same tested binaries as the app."
                )

                SettingsActionBar {
                    Button {
                        model.revealBackupToolsFolder()
                    } label: {
                        Label("Show Tools", systemImage: "folder")
                    }
                    .deltaTooltip("Show Delta's bundled backup engine and cloud helper in Finder.")
                }
            }

                SettingsCard(
                symbol: "folder.badge.gearshape",
                title: "Support Files",
                subtitle: "Open local data and logs used for troubleshooting."
            ) {
                ActionLine(
                    description: "Database, locks, background control state, and support files.",
                    buttonTitle: "Show App Data",
                    symbol: "folder",
                    action: model.revealApplicationSupportFolder
                )
                ActionLine(
                    description: "Saved backup, restore, check, and prune output.",
                    buttonTitle: "Show Logs",
                    symbol: "doc.text.magnifyingglass",
                    action: model.revealLogFolder
                )
            }

                SettingsCard(
                symbol: "stethoscope",
                title: "Diagnostics",
                subtitle: "Control troubleshooting output and generate support information without secrets."
            ) {
                SettingsControlRow(
                    title: "Activity log detail",
                    detail: activityLogDetail.description
                ) {
                    Picker("", selection: $activityLogDetailRawValue) {
                        ForEach(ActivityLogDetail.allCases) { detail in
                            Text(detail.title).tag(detail.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }

                SettingsControlRow(
                    title: "History retention",
                    detail: "Automatically remove old job summaries, saved output, restore requests, and events. Backup data and restore points are not affected."
                ) {
                    Picker("", selection: $operationalHistoryRetentionDays) {
                        ForEach(OperationalHistoryRetention.allCases) { retention in
                            Text(retention.title).tag(retention.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 180)
                    .onChange(of: operationalHistoryRetentionDays) { _, _ in
                        normalizeOperationalHistoryRetention()
                    }
                }

                SettingsFactGrid(items: [
                    SettingsFact(title: "Live view", value: activityLogDetail.title),
                    SettingsFact(title: "Saved history", value: operationalHistoryRetention.summaryText),
                    SettingsFact(title: "Backup data", value: "Unaffected")
                ])

                ActionLine(
                    description: "Copy a sanitized report with app, helper, destination, profile, and recent job state.",
                    buttonTitle: "Copy Report",
                    symbol: "doc.on.doc",
                    action: model.copyDiagnosticReport
                )
                ActionLine(
                    description: "Save the same report as a Markdown file.",
                    buttonTitle: "Export Report",
                    symbol: "square.and.arrow.down",
                    action: model.exportDiagnosticReport
                )

                SettingsActionBar {
                    Button {
                        normalizeOperationalHistoryRetention()
                        model.pruneOperationalHistoryNow()
                    } label: {
                        Label("Clean Up Now", systemImage: "trash")
                    }
                    .disabled(model.isWorking || !model.isPersistentStoreAvailable)
                    .deltaTooltip("Apply the selected activity history retention policy now.")
                }
            }
            }
        }
        .onAppear {
            automaticallyChecksForUpdates = softwareUpdateController.automaticallyChecksForUpdates
            automaticallyDownloadsUpdates = softwareUpdateController.automaticallyDownloadsUpdates
            activityLogDetailRawValue = activityLogDetail.rawValue
            normalizeOperationalHistoryRetention()
            normalizeHealthMonitoring()
            normalizeBackupDefaults()
            normalizeRestorePreferences()
            applyUpdatePreferences()
            refreshNotificationAuthorization()
        }
    }

    private var scheduledProfileCount: Int {
        model.profiles.filter { $0.schedule.isEnabled }.count
    }

    private var backgroundSecretAccessSummary: BackgroundSecretAccessSummary {
        BackgroundSecretAccessSummary(
            reports: model.backgroundSecretAccessReports,
            destinationCount: model.repositories.count
        )
    }

    private var backgroundSecretAccessStatusColor: Color {
        switch backgroundSecretAccessSummary.state {
        case .ready:
            return .green
        case .needsRepair:
            return .orange
        case .unchecked:
            return .secondary
        case .noDestinations:
            return .secondary
        }
    }

    private var backgroundBackupsPresentation: BackgroundBackupServicePresentation {
        BackgroundBackupServicePresentation.make(
            status: model.launchAgentStatus,
            scheduledProfileCount: scheduledProfileCount,
            pausesScheduledBackups: pausesScheduledBackups
        )
    }

    private var settingsOverviewTitle: String {
        if !model.isPersistentStoreAvailable {
            return "Local app data needs attention"
        }
        if backupToolStatusText != "Ready" {
            return "Backup tools need attention"
        }
        if !model.fullDiskAccessStatus.hasLikelyFullDiskAccess {
            return "System access needs attention"
        }
        if backgroundSecretAccessSummary.needsRepair {
            return "Password access needs repair"
        }
        if pausesScheduledBackups && scheduledProfileCount > 0 {
            return "Scheduled backups are paused"
        }
        if backgroundBackupsPresentation.needsAttention {
            return "Scheduled backups need attention"
        }
        if sendsJobNotifications && !notificationAuthorizationState.canDeliver {
            return "Notifications need permission"
        }
        return "Delta is ready"
    }

    private var settingsOverviewSymbol: String {
        if !model.isPersistentStoreAvailable || backupToolStatusText != "Ready" {
            return "xmark.octagon"
        }
        if settingsOverviewNeedsReview {
            return "exclamationmark.triangle"
        }
        return "checkmark.seal"
    }

    private var settingsOverviewDetail: String {
        if !model.isPersistentStoreAvailable {
            return "Delta cannot use its local database until app data opens successfully."
        }
        if backupToolStatusText != "Ready" {
            return backupToolStatusDetail
        }
        if !model.fullDiskAccessStatus.hasLikelyFullDiskAccess {
            return fullDiskAccessDescription
        }
        if backgroundSecretAccessSummary.needsRepair {
            return "\(backgroundSecretAccessSummary.detail) Repair access before relying on unattended scheduled backups."
        }
        if pausesScheduledBackups && scheduledProfileCount > 0 {
            return "Automatic scheduled runs are paused. Manual Back Up Now actions still work for individual profiles."
        }
        if let attentionText = backgroundBackupsPresentation.attentionText {
            return attentionText
        }
        if sendsJobNotifications && !notificationAuthorizationState.canDeliver {
            return "macOS notification permission is required before Delta can send backup alerts."
        }
        return "Background scheduling, protected-folder access, update checks, notifications, and bundled backup tools are summarized here."
    }

    private var settingsOverviewStatusText: String {
        settingsOverviewNeedsReview ? "Review" : "Ready"
    }

    private var settingsOverviewStatusColor: Color {
        if !model.isPersistentStoreAvailable || backupToolStatusText != "Ready" {
            return .red
        }
        if !model.fullDiskAccessStatus.hasLikelyFullDiskAccess
            || backgroundSecretAccessSummary.needsRepair
            || (pausesScheduledBackups && scheduledProfileCount > 0)
            || backgroundBackupsPresentation.needsAttention
            || (sendsJobNotifications && !notificationAuthorizationState.canDeliver) {
            return .orange
        }
        return .green
    }

    private var settingsOverviewNeedsReview: Bool {
        !model.isPersistentStoreAvailable
            || backupToolStatusText != "Ready"
            || !model.fullDiskAccessStatus.hasLikelyFullDiskAccess
            || backgroundSecretAccessSummary.needsRepair
            || (pausesScheduledBackups && scheduledProfileCount > 0)
            || backgroundBackupsPresentation.needsAttention
            || (sendsJobNotifications && !notificationAuthorizationState.canDeliver)
    }

    private var settingsStatusItems: [SettingsStatusItem] {
        [
            SettingsStatusItem(
                title: SettingsSurfaceContract.statusSummaryTitles[0],
                value: fullDiskAccessStatusText,
                symbol: "lock.shield",
                color: fullDiskAccessStatusColor,
                detail: model.fullDiskAccessStatus.hasLikelyFullDiskAccess ? "Protected folders readable" : "Action required"
            ),
            SettingsStatusItem(
                title: SettingsSurfaceContract.statusSummaryTitles[1],
                value: backgroundBackupsPresentation.statusText,
                symbol: "clock.badge.checkmark",
                color: backgroundBackupsStatusColor,
                detail: backgroundBackupsPresentation.statusDetail
            ),
            SettingsStatusItem(
                title: SettingsSurfaceContract.statusSummaryTitles[2],
                value: backgroundSecretAccessSummary.displayName,
                symbol: "key.horizontal",
                color: backgroundSecretAccessStatusColor,
                detail: backgroundSecretAccessSummary.detail
            ),
            SettingsStatusItem(
                title: SettingsSurfaceContract.statusSummaryTitles[3],
                value: automaticUpdatesStatusText,
                symbol: "arrow.down.circle",
                color: automaticUpdatesStatusColor,
                detail: automaticUpdatesSummaryDetail
            ),
            SettingsStatusItem(
                title: SettingsSurfaceContract.statusSummaryTitles[4],
                value: notificationStatusText,
                symbol: "bell.badge",
                color: notificationStatusColor,
                detail: sendsJobNotifications ? "Job alerts configured" : "Alerts disabled"
            ),
            SettingsStatusItem(
                title: SettingsSurfaceContract.statusSummaryTitles[5],
                value: showsMenuBarExtra ? "Shown" : "Hidden",
                symbol: "menubar.rectangle",
                color: showsMenuBarExtra ? .green : .secondary,
                detail: model.appLoginItemStatus == .enabled ? "Starts at login" : "Login optional"
            ),
            SettingsStatusItem(
                title: SettingsSurfaceContract.statusSummaryTitles[6],
                value: backupToolStatusText,
                symbol: "externaldrive.badge.checkmark",
                color: backupToolStatusColor,
                detail: backupToolStatusDetail
            )
        ]
    }

    private var activityLogDetail: ActivityLogDetail {
        ActivityLogDetail.normalized(activityLogDetailRawValue)
    }

    private var operationalHistoryRetention: OperationalHistoryRetention {
        OperationalHistoryRetention.normalized(operationalHistoryRetentionDays)
    }

    private var fullDiskAccessStatusText: String {
        model.fullDiskAccessStatus.hasLikelyFullDiskAccess ? "Ready" : "Needs Access"
    }

    private var fullDiskAccessStatusColor: Color {
        model.fullDiskAccessStatus.hasLikelyFullDiskAccess ? .green : .orange
    }

    private var fullDiskAccessDescription: String {
        model.fullDiskAccessStatus.hasLikelyFullDiskAccess
            ? "Protected locations look readable for full-volume and selected-folder backups."
            : "Protected locations are not readable yet. Open Privacy & Security, add Delta with the + button if needed, then recheck access."
    }

    private var appLoginItemStatusText: String {
        switch model.appLoginItemStatus {
        case .enabled:
            return "On"
        case .requiresApproval:
            return "Needs Approval"
        case .notRegistered:
            return "Off"
        case .notFound:
            return "Missing App"
        case .unavailable:
            return "Unavailable"
        case .unknown:
            return "Unknown"
        }
    }

    private var menuBarAndLoginStatusText: String {
        if model.appLoginItemStatus == .requiresApproval {
            return "Needs Approval"
        }
        if showsMenuBarExtra && model.appLoginItemStatus == .enabled {
            return "On"
        }
        if showsMenuBarExtra {
            return "Menu Shown"
        }
        if model.appLoginItemStatus == .enabled {
            return "Starts at Login"
        }
        return "Off"
    }

    private var menuBarAndLoginStatusColor: Color {
        switch model.appLoginItemStatus {
        case .requiresApproval:
            return .orange
        case .notFound, .unknown:
            return .red
        case .enabled:
            return .green
        case .notRegistered, .unavailable:
            return showsMenuBarExtra ? .green : .secondary
        }
    }

    private var notificationStatusText: String {
        guard sendsJobNotifications else {
            return "Off"
        }
        return notificationAuthorizationState.canDeliver ? "On" : "Needs Permission"
    }

    private var notificationStatusColor: Color {
        guard sendsJobNotifications else {
            return .secondary
        }
        switch notificationAuthorizationState {
        case .authorized, .provisional, .ephemeral:
            return .green
        case .notDetermined:
            return .orange
        case .denied, .unknown:
            return .red
        }
    }

    private var canSendTestNotification: Bool {
        sendsJobNotifications && notificationAuthorizationState.canDeliver
    }

    private var notificationTestAlertStatusText: String {
        if !sendsJobNotifications {
            return "Enable alerts"
        }
        if !notificationAuthorizationState.canDeliver {
            return "Needs Permission"
        }
        return "Ready"
    }

    private var notificationTestAlertTooltip: String {
        if !sendsJobNotifications {
            return "Enable job alerts before sending a test notification."
        }
        if !notificationAuthorizationState.canDeliver {
            return "Allow Delta in macOS Notifications settings before sending a test alert."
        }
        return "Send a macOS notification now to confirm Delta alerts are working."
    }

    private var automaticUpdatesStatusText: String {
        guard automaticallyChecksForUpdates else {
            return "Off"
        }
        return automaticallyDownloadsUpdates ? "Auto Download" : "Checks On"
    }

    private var automaticUpdatesStatusColor: Color {
        automaticallyChecksForUpdates ? .green : .secondary
    }

    private var automaticUpdatesSummaryDetail: String {
        guard automaticallyChecksForUpdates else {
            return "Manual checks only"
        }
        let interval = AppUpdateCheckInterval.normalized(updateCheckIntervalSeconds).summaryText
        return automaticallyDownloadsUpdates ? "\(interval), downloads ready" : interval
    }

    private var restoreDefaultsStatusText: String {
        previewsRestoresByDefault && verifiesRestoresByDefault ? "Conservative" : "Custom"
    }

    private var restoreDefaultsStatusColor: Color {
        previewsRestoresByDefault && verifiesRestoresByDefault ? .green : .orange
    }

    private var healthMonitoringStatusText: String {
        backupFreshnessThreshold == .threeDays && destinationVerificationThreshold == .thirtyDays
            ? "Recommended"
            : "Custom"
    }

    private var healthMonitoringStatusColor: Color {
        healthMonitoringStatusText == "Recommended" ? .green : .orange
    }

    private var backupDefaultsStatusText: String {
        !defaultProfileCatchUpMissedRuns
            || !defaultProfileRunOnBattery
            || defaultProfileRunInLowPowerMode
            || !defaultProfilePruneAfterForget
            || !defaultProfileCheckAfterPrune
            || defaultProfileUploadLimitKiB > 0
            || defaultProfileDownloadLimitKiB > 0
            || defaultProfileKeepHourly != 24
            || defaultProfileKeepDaily != 30
            || defaultProfileKeepWeekly != 12
            || defaultProfileKeepMonthly != 12
            || defaultProfileKeepYearly != 0
            || !defaultProfileMaintenanceEnabled
            || defaultProfileMaintenanceIntervalDays != 7
            || defaultProfileMaintenanceHour != 2
            || defaultProfileMaintenanceMinute != 0
            ? "Custom"
            : "Recommended"
    }

    private var backupDefaultsStatusColor: Color {
        backupDefaultsStatusText == "Recommended" ? .green : .orange
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    private var buildVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "Unknown"
    }

    private var appVersionStatusText: String {
        appVersion == "Unknown" ? "Unknown" : "Beta \(appVersion)"
    }

    private var resticToolURL: URL {
        ResticExecutableLocator().locate(in: Bundle.main)
    }

    private var rcloneToolURL: URL {
        resticToolURL.deletingLastPathComponent().appendingPathComponent("rclone")
    }

    private var isResticExecutableAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: resticToolURL.path)
    }

    private var isRcloneExecutableAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: rcloneToolURL.path)
    }

    private var backupToolStatusText: String {
        isResticExecutableAvailable && isRcloneExecutableAvailable ? "Ready" : "Missing"
    }

    private var backupToolStatusColor: Color {
        backupToolStatusText == "Ready" ? .green : .red
    }

    private var backupToolStatusDetail: String {
        if isResticExecutableAvailable && isRcloneExecutableAvailable {
            return "Bundled engines available"
        }
        if isResticExecutableAvailable {
            return "Cloud helper missing"
        }
        if isRcloneExecutableAvailable {
            return "Backup engine missing"
        }
        return "Backup engines missing"
    }

    private var defaultUploadLimitBinding: Binding<String> {
        Binding(
            get: { defaultProfileUploadLimitKiB > 0 ? String(defaultProfileUploadLimitKiB) : "" },
            set: { defaultProfileUploadLimitKiB = normalizedOptionalPositiveInteger(from: $0, maximum: 1_048_576) }
        )
    }

    private var defaultDownloadLimitBinding: Binding<String> {
        Binding(
            get: { defaultProfileDownloadLimitKiB > 0 ? String(defaultProfileDownloadLimitKiB) : "" },
            set: { defaultProfileDownloadLimitKiB = normalizedOptionalPositiveInteger(from: $0, maximum: 1_048_576) }
        )
    }

    private var defaultBandwidthSummary: String {
        switch (defaultProfileUploadLimitKiB, defaultProfileDownloadLimitKiB) {
        case let (upload, download) where upload > 0 && download > 0:
            return "Up \(upload) / Down \(download)"
        case let (upload, _) where upload > 0:
            return "Upload \(upload)"
        case let (_, download) where download > 0:
            return "Download \(download)"
        default:
            return "Unlimited"
        }
    }

    private var defaultRetentionSummary: String {
        let components = [
            "\(defaultProfileKeepHourly)h",
            "\(defaultProfileKeepDaily)d",
            "\(defaultProfileKeepWeekly)w",
            "\(defaultProfileKeepMonthly)m"
        ]
        let base = components.joined(separator: " / ")
        guard defaultProfileKeepYearly > 0 else {
            return base
        }
        return "\(base) / \(defaultProfileKeepYearly)y"
    }

    private var defaultCleanupSummary: String {
        guard defaultProfileMaintenanceEnabled else {
            return "Manual"
        }
        return "Every \(defaultProfileMaintenanceIntervalDays)d at \(twoDigit(defaultProfileMaintenanceHour)):\(twoDigit(defaultProfileMaintenanceMinute))"
    }

    private var backupFreshnessThreshold: BackupFreshnessWarningThreshold {
        BackupFreshnessWarningThreshold.normalized(backupFreshnessWarningHours)
    }

    private var destinationVerificationThreshold: DestinationVerificationWarningThreshold {
        DestinationVerificationWarningThreshold.normalized(destinationVerificationWarningHours)
    }

    private func applyUpdatePreferences() {
        let interval = AppUpdateCheckInterval.normalized(updateCheckIntervalSeconds)
        if updateCheckIntervalSeconds != interval.rawValue {
            updateCheckIntervalSeconds = interval.rawValue
        }
        softwareUpdateController.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        softwareUpdateController.updateCheckInterval = TimeInterval(interval.rawValue)
        softwareUpdateController.automaticallyDownloadsUpdates = automaticallyChecksForUpdates && automaticallyDownloadsUpdates
    }

    private func normalizeRestorePreferences() {
        if RestoreConflictPolicy(rawValue: defaultRestoreConflictPolicyRawValue) == nil {
            defaultRestoreConflictPolicyRawValue = RestoreConflictPolicy.ifChanged.rawValue
        }
    }

    private func normalizeOperationalHistoryRetention() {
        let normalized = operationalHistoryRetention.rawValue
        if operationalHistoryRetentionDays != normalized {
            operationalHistoryRetentionDays = normalized
        }
    }

    private func normalizeHealthMonitoring() {
        let normalizedBackupFreshness = backupFreshnessThreshold.rawValue
        if backupFreshnessWarningHours != normalizedBackupFreshness {
            backupFreshnessWarningHours = normalizedBackupFreshness
        }
        let normalizedDestinationVerification = destinationVerificationThreshold.rawValue
        if destinationVerificationWarningHours != normalizedDestinationVerification {
            destinationVerificationWarningHours = normalizedDestinationVerification
        }
    }

    private func normalizeBackupDefaults() {
        defaultProfileUploadLimitKiB = clamped(defaultProfileUploadLimitKiB, to: 0...1_048_576)
        defaultProfileDownloadLimitKiB = clamped(defaultProfileDownloadLimitKiB, to: 0...1_048_576)
        defaultProfileKeepHourly = clamped(defaultProfileKeepHourly, to: 0...168)
        defaultProfileKeepDaily = clamped(defaultProfileKeepDaily, to: 0...365)
        defaultProfileKeepWeekly = clamped(defaultProfileKeepWeekly, to: 0...260)
        defaultProfileKeepMonthly = clamped(defaultProfileKeepMonthly, to: 0...120)
        defaultProfileKeepYearly = clamped(defaultProfileKeepYearly, to: 0...50)
        defaultProfileMaintenanceIntervalDays = clamped(defaultProfileMaintenanceIntervalDays, to: 1...90)
        defaultProfileMaintenanceHour = clamped(defaultProfileMaintenanceHour, to: 0...23)
        defaultProfileMaintenanceMinute = clamped(defaultProfileMaintenanceMinute, to: 0...59)
    }

    private func resetHealthMonitoringDefaults() {
        backupFreshnessWarningHours = BackupFreshnessWarningThreshold.threeDays.rawValue
        destinationVerificationWarningHours = DestinationVerificationWarningThreshold.thirtyDays.rawValue
    }

    private func resetBackupDefaults() {
        defaultProfileCatchUpMissedRuns = true
        defaultProfileRunOnBattery = true
        defaultProfileRunInLowPowerMode = false
        defaultProfilePruneAfterForget = true
        defaultProfileCheckAfterPrune = true
        defaultProfileUploadLimitKiB = 0
        defaultProfileDownloadLimitKiB = 0
        defaultProfileKeepHourly = 24
        defaultProfileKeepDaily = 30
        defaultProfileKeepWeekly = 12
        defaultProfileKeepMonthly = 12
        defaultProfileKeepYearly = 0
        defaultProfileMaintenanceEnabled = true
        defaultProfileMaintenanceIntervalDays = 7
        defaultProfileMaintenanceHour = 2
        defaultProfileMaintenanceMinute = 0
    }

    private func resetRestoreDefaults() {
        previewsRestoresByDefault = true
        verifiesRestoresByDefault = true
        defaultRestoreConflictPolicyRawValue = RestoreConflictPolicy.ifChanged.rawValue
    }

    private func refreshNotificationAuthorization() {
        Task {
            notificationAuthorizationState = await DeltaUserNotifier.authorizationState()
        }
    }

    private func requestNotificationPermission() {
        Task {
            let state = await DeltaUserNotifier.requestAuthorization()
            notificationAuthorizationState = state
            if !state.canDeliver {
                sendsJobNotifications = false
                sendsSuccessfulBackupNotifications = false
                model.alertMessage = "Delta cannot send notifications until they are allowed in macOS Notifications settings."
            }
        }
    }

    private func sendTestNotification() {
        let settings = JobNotificationSettings(
            isEnabled: sendsJobNotifications,
            includesSuccessfulBackups: sendsSuccessfulBackupNotifications
        )
        guard let content = JobNotificationPolicy.testAlertContent(
            settings: settings,
            authorizationState: notificationAuthorizationState,
            identifier: UUID().uuidString
        ) else {
            if !sendsJobNotifications {
                model.alertMessage = "Turn on job alerts before sending a test notification."
            } else if !notificationAuthorizationState.canDeliver {
                model.alertMessage = "Delta cannot send notifications until they are allowed in macOS Notifications settings."
            }
            return
        }
        DeltaUserNotifier.deliver(content)
    }

    private func normalizedOptionalPositiveInteger(from text: String, maximum: Int) -> Int {
        let digits = text.filter(\.isNumber)
        guard let value = Int(digits), value > 0 else {
            return 0
        }
        return min(value, maximum)
    }

    private func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func twoDigit(_ value: Int) -> String {
        String(format: "%02d", value)
    }

    private var backgroundBackupsStatusColor: Color {
        switch backgroundBackupsPresentation.severity {
        case .ready:
            return .green
        case .inactive:
            return .secondary
        case .attention:
            return .orange
        case .blocked:
            return .red
        }
    }

    private var backgroundBackupsBinding: Binding<Bool> {
        Binding(
            get: { model.launchAgentStatus == .enabled || model.launchAgentStatus == .requiresApproval },
            set: { enabled in
                if enabled {
                    model.registerAgent()
                } else {
                    model.unregisterAgent()
                }
            }
        )
    }

    private var appLoginItemBinding: Binding<Bool> {
        Binding(
            get: { model.appLoginItemStatus == .enabled || model.appLoginItemStatus == .requiresApproval },
            set: { enabled in
                if enabled {
                    model.registerAppLoginItem()
                } else {
                    model.unregisterAppLoginItem()
                }
            }
        )
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
                            IconButton(symbol: "pencil", help: "Edit sources, exclusions, destination, schedule, and retention") {
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
                        progressFraction: model.activeDisplayedProgressFraction,
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
                .frame(width: ModalMetrics.sheetWidth, height: 720)
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
        return latestBackupRun.isPausedBackup
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
        case let .sftp(host, path, username, port, identityFilePath):
            let user = username.map { "\($0)@" } ?? ""
            let portPart = port.map { ":\($0)" } ?? ""
            let keyPart = identityFilePath == nil ? "" : " - key"
            return "\(user)\(host)\(portPart):\(path)\(keyPart)"
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
    @State private var customExcludePatternsText = ""
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
        let schedule = profile?.schedule ?? BackupProfileDefaults.schedule()
        let scheduleState = Self.scheduleEditorState(for: schedule.kind)
        let retention = profile?.retention ?? BackupProfileDefaults.retention()

        _name = State(initialValue: profile?.name ?? "Mac Backup")
        _mode = State(initialValue: profile?.sourceMode ?? .customFolders)
        _sources = State(initialValue: profile?.sources ?? [])
        _repositoryID = State(initialValue: profile?.repositoryID)
        _customExcludePatternsText = State(initialValue: BackupExcludePatternParser.displayText(for: profile?.excludePatterns ?? BackupExcludePolicy.defaultMacOSExcludes))
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
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        if mode == .fullVolume {
                            Button {
                                sources = [model.startupVolumeSource()]
                            } label: {
                                Label("Startup Volume", systemImage: "internaldrive")
                            }
                            Button {
                                let selectedSources = model.chooseBackupVolumeSources(allowsMultipleSelection: true)
                                if !selectedSources.isEmpty {
                                    sources = selectedSources
                                }
                            } label: {
                                Label("Choose Volume", systemImage: "externaldrive.badge.plus")
                            }
                        } else {
                            Button {
                                let selectedSources = model.chooseBackupSources(allowsMultipleSelection: true, includeSubvolumes: true)
                                if !selectedSources.isEmpty {
                                    sources = selectedSources
                                }
                            } label: {
                                Label("Choose Folders", systemImage: "folder.badge.plus")
                            }
                        }
                    }
                    Text(sourceSummaryText)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 460, alignment: .leading)
                }
            }

            FieldRow(title: "Extra excludes") {
                ExclusionPatternEditor(text: $customExcludePatternsText)
                    .frame(width: ModalMetrics.primaryControlWidth)
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
        .onChange(of: mode) { oldMode, newMode in
            guard oldMode != newMode else { return }
            switch newMode {
            case .fullVolume:
                sources = [model.startupVolumeSource()]
            case .customFolders:
                sources.removeAll()
            }
        }
    }

    private var sheetTitle: String {
        existingProfile == nil ? "New Backup Profile" : "Edit Backup Profile"
    }

    private var sheetSubtitle: String {
        existingProfile == nil ? "Define what to protect and when to run." : "Update what to protect and when to run."
    }

    private var sourceSummaryText: String {
        guard !sources.isEmpty else {
            return mode == .fullVolume ? "No volume selected" : "No folders selected"
        }

        let paths = sources.map { source in
            if mode == .fullVolume, source.path == "/" {
                return "Startup volume (/)"
            }
            return source.path
        }
        return paths.joined(separator: ", ")
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

    private var selectedExcludePatterns: [String] {
        BackupExcludePatternParser.mergingDefaults(
            with: BackupExcludePatternParser.parse(customExcludePatternsText)
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
            profile.excludePatterns = selectedExcludePatterns
            profile.updatedAt = Date()
            model.saveProfile(profile)
        } else {
            model.createProfile(
                name: name,
                mode: mode,
                sources: sources,
                repositoryID: repositoryID,
                schedule: selectedSchedule,
                retention: selectedRetention,
                excludePatterns: selectedExcludePatterns
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
    @State private var sftpIdentityFilePath = ""
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
        _sftpIdentityFilePath = State(initialValue: backendState.sftpIdentityFilePath)
        _storageMode = State(initialValue: repository?.secretStorageMode ?? .appManagedKeychain)
        _credentialValues = State(initialValue: Dictionary(uniqueKeysWithValues: ResticBackendCredentialTemplates.fields(for: backendState.kind).map { ($0.environmentKey, "") }))
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
            let fields = ResticBackendCredentialTemplates.fields(for: newKind)
            credentialValues = Dictionary(uniqueKeysWithValues: fields.map { ($0.environmentKey, credentialValues[$0.environmentKey] ?? "") })
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
            FieldRow(title: "SSH key") {
                HStack(spacing: 8) {
                    TextField("Optional private key file", text: $sftpIdentityFilePath)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        if let path = model.chooseFile().first {
                            sftpIdentityFilePath = path
                        }
                    } label: {
                        Image(systemName: "key")
                    }
                    .deltaTooltip("Choose an SSH private key file for non-interactive SFTP backups.")
                }
            }
            FieldRow(title: "") {
                SettingsNotice(
                    symbol: "key.horizontal",
                    title: "Scheduled SFTP requires non-interactive SSH",
                    text: "Delta runs SFTP with SSH batch mode so background backups fail clearly instead of waiting for a password prompt. Use a key file, ssh-agent, or your SSH config.",
                    color: .blue
                )
            }
        case .rest:
            FieldRow(title: "URL") { TextField("https://backup.example.com/repo", text: $primary).textFieldStyle(.roundedBorder) }
        case .s3:
            FieldRow(title: "Bucket") { TextField("bucket", text: $primary).textFieldStyle(.roundedBorder) }
            FieldRow(title: "Path") { TextField("Optional", text: $secondary).textFieldStyle(.roundedBorder) }
            FieldRow(title: "Endpoint") { TextField("s3.us-east-1.amazonaws.com or https://server:port", text: $tertiary).textFieldStyle(.roundedBorder) }
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
        let fields = ResticBackendCredentialTemplates.fields(for: kind)
        if !fields.isEmpty {
            Divider()
            ForEach(fields) { field in
                FieldRow(title: field.title) {
                    if field.isSecret {
                        SecureField(field.placeholder.isEmpty ? field.title : field.placeholder, text: credentialBinding(for: field.environmentKey))
                            .textFieldStyle(.roundedBorder)
                    } else {
                        TextField(field.placeholder.isEmpty ? field.title : field.placeholder, text: credentialBinding(for: field.environmentKey))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }

    private var backend: RepositoryBackend {
        switch kind {
        case .local: .local(path: primary)
        case .sftp: .sftp(
            host: primary,
            path: secondary,
            username: tertiary.isEmpty ? nil : tertiary,
            port: parsedPort,
            identityFilePath: sftpIdentityFilePath.isEmpty ? nil : sftpIdentityFilePath
        )
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
        if kind == .s3 && tertiary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
        case let .sftp(host, path, username, port, identityFilePath):
            RepositoryEditorState(
                kind: .sftp,
                primary: host,
                secondary: path,
                tertiary: username ?? "",
                quaternary: port.map(String.init) ?? "",
                sftpIdentityFilePath: identityFilePath ?? ""
            )
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
        var sftpIdentityFilePath = ""
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

struct SettingsStatusItem: Identifiable {
    var id: String { title }
    var title: String
    var value: String
    var symbol: String
    var color: Color
    var detail: String
}

struct SettingsOverviewCard: View {
    var symbol: String
    var title: String
    var detail: String
    var statusText: String
    var statusColor: Color
    var items: [SettingsStatusItem]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    StatusIcon(symbol: symbol, color: statusColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline)
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    StateBadge(text: statusText, color: statusColor)
                        .lineLimit(1)
                }

                Divider()

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(items) { item in
                        SettingsOverviewItem(item: item)
                    }
                }
            }
        }
    }

    private var columns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 210), spacing: 12)
        ]
    }
}

struct SettingsOverviewItem: View {
    var item: SettingsStatusItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 24, height: 24)
                .foregroundStyle(item.color)
                .background(item.color.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(item.value)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsCard<Content: View>: View {
    var symbol: String
    var title: String
    var subtitle: String?
    var statusText: String?
    var statusColor: Color
    @ViewBuilder var content: Content

    init(
        symbol: String,
        title: String,
        subtitle: String? = nil,
        statusText: String? = nil,
        statusColor: Color = .secondary,
        @ViewBuilder content: () -> Content
    ) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.statusText = statusText
        self.statusColor = statusColor
        self.content = content()
    }

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                StatusIcon(symbol: symbol, color: statusText == nil ? .blue : statusColor)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title)
                                .font(.headline)
                            if let subtitle {
                                Text(subtitle)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let statusText {
                            StateBadge(text: statusText, color: statusColor)
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                    }

                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct SettingsFact: Identifiable {
    var id: String { title }
    var title: String
    var value: String
}

struct SettingsCapability: Identifiable {
    var id: String { title }
    var symbol: String
    var title: String
    var detail: String
}

struct SettingsSectionLabel: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsCapabilityList: View {
    var items: [SettingsCapability]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                        Text(item.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeltaTheme.badge.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SettingsFactGrid: View {
    var items: [SettingsFact]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.value)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DeltaTheme.badge.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var columns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 150), spacing: 8)
        ]
    }
}

struct SettingsControlRow<Control: View>: View {
    var title: String
    var detail: String
    @ViewBuilder var control: Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalLayout
            verticalLayout
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var horizontalLayout: some View {
        HStack(alignment: .center, spacing: 16) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)

            control
                .frame(width: 320, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            label
            control
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsActionBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

struct SettingsDescription: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsNotice: View {
    var symbol: String
    var title: String
    var text: String
    var color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(color)
                .background(color.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeltaTheme.badge.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

struct ExclusionPatternEditor: View {
    @Binding var text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.18))
            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(height: 84)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("One path or pattern per line")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 9)
                    .padding(.leading, 10)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 84)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(DeltaTheme.border, lineWidth: 1)
        )
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
    var progressFraction: Double?
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
                        progressFraction: progressFraction,
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
    var progressFraction: Double?
    var latestMessage: String?
    var stopRequest: ResticRunStopReason?
    var onPause: (() -> Void)?
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progressFraction {
                ProgressView(value: progressFraction, total: 1)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Estimated backup progress")
                    .accessibilityValue("\(Int(progressFraction * 100)) percent")
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Backup progress")
                    .accessibilityValue("Scanning")
            }
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
        .deltaTooltip("Estimated progress is stabilized while Delta discovers source files. The processed-file counter shows the current backup work.")
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
        Text(status.displayName)
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
        HStack(alignment: .center, spacing: 16) {
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: action) {
                Label(buttonTitle, systemImage: symbol)
            }
            .controlSize(.small)
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        if let summary {
            BackupSummaryMetricRow(summary: summary)
        } else if let summaryText {
            Text(summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var summary: ResticBackupSummary? {
        guard job.kind == .backup else {
            return nil
        }
        return job.backupSummary ?? ResticLogFormatter.backupSummary(from: job.message)
    }

    private var summaryText: String? {
        guard job.kind == .backup else {
            return nil
        }
        guard let message = job.message, !message.isEmpty else {
            return nil
        }
        if message.localizedCaseInsensitiveContains("paused") {
            return message
        }
        if message.localizedCaseInsensitiveContains("backup summary") || message.localizedCaseInsensitiveContains("no changes detected") {
            return message
                .replacingOccurrences(of: "Backup summary · ", with: "")
                .replacingOccurrences(of: "No changes detected · ", with: "")
        }
        return nil
    }
}

struct BackupSummaryMetricRow: View {
    var summary: ResticBackupSummary

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                ForEach(metrics) { metric in
                    BackupSummaryMetricPill(metric: metric)
                }
            }
            Text(summary.conciseText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .deltaTooltip(summary.detailedText)
    }

    private var metrics: [BackupSummaryMetric] {
        var items = [
            BackupSummaryMetric(title: "New", value: summary.filesNew.formatted()),
            BackupSummaryMetric(title: "Changed", value: summary.filesChanged.formatted())
        ]
        if summary.hasChanges, let dataAdded = summary.dataAdded, dataAdded > 0 {
            items.append(
                BackupSummaryMetric(
                    title: "Added",
                    value: ByteCountFormatter.string(fromByteCount: dataAdded, countStyle: .file)
                )
            )
        } else if summary.totalBytesProcessed > 0 {
            items.append(
                BackupSummaryMetric(
                    title: "Checked",
                    value: ByteCountFormatter.string(fromByteCount: summary.totalBytesProcessed, countStyle: .file)
                )
            )
        } else {
            let fileCount = summary.totalFilesProcessed > 0 ? summary.totalFilesProcessed : summary.filesUnmodified
            if fileCount > 0 {
                items.append(BackupSummaryMetric(title: "Checked", value: fileCount.formatted()))
            }
        }
        return items
    }
}

struct BackupSummaryMetric: Identifiable {
    var id: String { title }
    var title: String
    var value: String
}

struct BackupSummaryMetricPill: View {
    var metric: BackupSummaryMetric

    var body: some View {
        HStack(spacing: 4) {
            Text(metric.value)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .monospacedDigit()
            Text(metric.title.lowercased())
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(DeltaTheme.badge.opacity(0.85))
        .clipShape(Capsule())
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
