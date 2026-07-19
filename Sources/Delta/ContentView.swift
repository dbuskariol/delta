import DeltaCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: DeltaAppModel
    @EnvironmentObject private var softwareUpdateController: SoftwareUpdateController
    @State private var isPresentingDestinationSheet = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                VStack(spacing: 3) {
                    ForEach(primarySections) { section in
                        sidebarButton(section)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.top, 8)

                Spacer(minLength: 12)

                Divider()
                sidebarButton(.settings)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 9)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 280)
        } detail: {
            switch model.selectedSection {
            case .dashboard:
                DashboardView(onAddDestination: presentDestinationEditor)
            case .backups:
                BackupsView(onAddDestination: presentDestinationEditor)
            case .destinations:
                DestinationsView(isPresentingDestinationSheet: $isPresentingDestinationSheet)
            case .restore:
                RestoreView(onAddDestination: presentDestinationEditor)
            case .activity:
                ActivityView()
            case .settings:
                SettingsView()
            }
        }
        .background(DeltaTheme.background)
        .onChange(of: model.selectedSection) { _, section in
            model.reload()
            if section == .settings {
                model.refreshSystemState(force: true)
            }
        }
        .onChange(of: model.softwareUpdateReadiness) { _, _ in
            softwareUpdateController.applicationSafetyDidChange()
        }
        .onAppear {
            softwareUpdateController.applicationSafetyDidChange()
        }
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

    private var primarySections: [DeltaAppModel.Section] {
        DeltaAppModel.Section.allCases.filter { $0 != .settings }
    }

    private func sidebarButton(_ section: DeltaAppModel.Section) -> some View {
        let isSelected = model.selectedSection == section
        return Button {
            model.selectedSection = section
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.symbol)
                    .frame(width: 17)
                Text(section.rawValue)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .font(.body)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(
                isSelected ? Color.accentColor : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func presentDestinationEditor() {
        model.selectedSection = .destinations
        isPresentingDestinationSheet = true
    }
}

struct DashboardView: View {
    @EnvironmentObject private var model: DeltaAppModel
    var onAddDestination: () -> Void
    @AppStorage(
        DeltaAppPreferenceKeys.backupFreshnessWarningHours,
        store: DeltaAppPreferences.sharedStore()
    ) private var backupFreshnessWarningHours = BackupFreshnessWarningThreshold.threeDays.rawValue
    @AppStorage(
        DeltaAppPreferenceKeys.destinationVerificationWarningHours,
        store: DeltaAppPreferences.sharedStore()
    ) private var destinationVerificationWarningHours = DestinationVerificationWarningThreshold.thirtyDays.rawValue
    @AppStorage(
        DeltaAppPreferenceKeys.destinationFreeSpaceWarningGiB,
        store: DeltaAppPreferences.sharedStore()
    ) private var destinationFreeSpaceWarningGiB = DestinationFreeSpaceWarningThreshold.fiftyGiB.rawValue
    @AppStorage(
        DeltaAppPreferenceKeys.pausesScheduledBackups,
        store: DeltaAppPreferences.sharedStore()
    ) private var pausesScheduledBackups = false

    var body: some View {
        PageScaffold(
            title: "Dashboard",
            subtitle: "Backup health, recent results, and what runs next",
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
                            Text(model.scheduledBackupServiceError ?? model.launchAgentStatus.detail)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.showSettings(.permissions)
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
                            model.showSettings(.permissions)
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
                    model.selectedSection = .destinations
                }
            }

            if !model.fullDiskAccessStatus.hasLikelyFullDiskAccess {
                Card {
                    HStack(alignment: .top, spacing: 14) {
                        StatusIcon(symbol: "lock.shield", color: .orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Readiness")
                                .font(.headline)
                            Text("Full Disk Access has not been confirmed. Full-volume backups may miss protected data, and Time Machine disks cannot be added or removed.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            StateBadge(text: "Needs Access", color: .orange)
                            Button {
                                model.showSettings(.permissions)
                            } label: {
                                Label("Review", systemImage: "arrow.right")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .deltaTooltip("Review Full Disk Access and Delta's other macOS permissions.")
                        }
                    }
                }
            }

            SectionHeader(title: "Backup Overview")
            DashboardBackupOverview(
                profiles: model.profiles,
                destinationCount: model.repositories.count,
                deltaDestinationCount: model.repositories.filter { $0.format == .delta }.count,
                jobs: model.jobs,
                acknowledgedWarningIssueCounts: model.acknowledgedWarningIssueCounts,
                onOpenBackups: { model.selectedSection = .backups },
                onOpenDestinations: onAddDestination
            )
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
        let freeSpaceThreshold = DestinationFreeSpaceWarningThreshold.normalized(destinationFreeSpaceWarningGiB)
        return DashboardHealthEvaluator().destinationWarnings(
            repositories: model.repositories,
            timeMachineStatesByRepository: model.timeMachineStatesByRepository,
            threshold: threshold,
            freeSpaceThreshold: freeSpaceThreshold
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

private struct DashboardBackupOverview: View {
    var profiles: [BackupProfile]
    var destinationCount: Int
    var deltaDestinationCount: Int
    var jobs: [JobRun]
    var acknowledgedWarningIssueCounts: [UUID: Int]
    var onOpenBackups: () -> Void
    var onOpenDestinations: () -> Void

    var body: some View {
        Card {
            if profiles.isEmpty {
                HStack(spacing: 12) {
                    StatusIcon(symbol: "externaldrive.badge.plus", color: .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No backup profiles")
                            .font(.headline)
                        Text(emptyStateMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(emptyStateActionTitle, action: emptyStateAction)
                        .buttonStyle(.bordered)
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    DashboardBackupFact(
                        symbol: "clock.badge.checkmark",
                        title: "Next automatic backup",
                        value: nextBackupTitle,
                        detail: nextBackupDetail,
                        color: nextBackupIsDue ? .orange : .blue
                    )
                    Divider()
                        .padding(.horizontal, 20)
                    DashboardBackupFact(
                        symbol: lastBackupSymbol,
                        title: "Last backup",
                        value: lastBackupTitle,
                        detail: lastBackupDetail,
                        color: lastBackupColor
                    )
                    Divider()
                        .padding(.horizontal, 20)
                    VStack(alignment: .trailing, spacing: 8) {
                        Text("\(profiles.count) \(profiles.count == 1 ? "profile" : "profiles")")
                            .font(.subheadline.weight(.semibold))
                        Text("Schedules and retention are managed on Backups.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                        Button("Manage Backups", action: onOpenBackups)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private var emptyStateMessage: String {
        if destinationCount == 0 {
            return "Add a destination for encrypted restore points, then choose the folders or volume to protect."
        }
        if deltaDestinationCount == 0 {
            return "Delta backup profiles require a Delta encrypted backup destination. macOS manages Time Machine sources and schedules."
        }
        return "Create a profile for the folders or volume you want to protect."
    }

    private var emptyStateActionTitle: String {
        if destinationCount == 0 { return "Add Destination" }
        if deltaDestinationCount == 0 { return "Add Delta Destination" }
        return "Open Backups"
    }

    private var emptyStateAction: () -> Void {
        deltaDestinationCount == 0 ? onOpenDestinations : onOpenBackups
    }

    private var latestBackup: JobRun? {
        jobs
            .filter { $0.kind == .backup && $0.status != .queued && $0.status != .running }
            .max { $0.startedAt < $1.startedAt }
    }

    private var scheduledCandidates: [(profile: BackupProfile, decision: ScheduleDecision)] {
        profiles.compactMap { profile in
            guard profile.schedule.isEnabled else { return nil }
            let lastAttempt = jobs
                .filter { $0.profileID == profile.id && $0.kind == .backup && $0.status != .queued }
                .compactMap { $0.finishedAt ?? $0.startedAt }
                .max()
            return (profile, ScheduleEvaluator().decision(for: profile.schedule, lastRun: lastAttempt))
        }
    }

    private var nextCandidate: (profile: BackupProfile, decision: ScheduleDecision)? {
        if let due = scheduledCandidates.first(where: { $0.decision.isDue }) {
            return due
        }
        return scheduledCandidates
            .filter { $0.decision.nextRun != nil }
            .min { lhs, rhs in
                (lhs.decision.nextRun ?? .distantFuture) < (rhs.decision.nextRun ?? .distantFuture)
            }
    }

    private var nextBackupIsDue: Bool { nextCandidate?.decision.isDue == true }

    private var nextBackupTitle: String {
        guard let nextCandidate else { return "No active schedules" }
        if nextCandidate.decision.isDue { return "Due now" }
        return nextCandidate.decision.nextRun?.formatted(date: .abbreviated, time: .shortened) ?? "Not scheduled"
    }

    private var nextBackupDetail: String {
        nextCandidate?.profile.name ?? "Enable a profile schedule to run backups automatically."
    }

    private var lastBackupTitle: String {
        guard let latestBackup else { return "No completed backups" }
        return (latestBackup.finishedAt ?? latestBackup.startedAt).formatted(date: .abbreviated, time: .shortened)
    }

    private var lastBackupDetail: String {
        guard let latestBackup else { return "Run a profile to create the first restore point." }
        let profileName = latestBackup.profileID.flatMap { id in profiles.first { $0.id == id }?.name }
        let outcome = outcome(for: latestBackup)
        return [profileName, outcome.displayName, outcome.detailText].compactMap { $0 }.joined(separator: " · ")
    }

    private var lastBackupSymbol: String {
        switch latestBackup.map(outcome(for:))?.visualStatus {
        case .failed: "xmark.circle"
        case .warning: "exclamationmark.triangle"
        case .cancelled: "pause.circle"
        default: "checkmark.circle"
        }
    }

    private var lastBackupColor: Color {
        switch latestBackup.map(outcome(for:))?.visualStatus {
        case .failed: .red
        case .warning, .cancelled: .orange
        case .succeeded: .green
        default: .secondary
        }
    }

    private func outcome(for job: JobRun) -> JobOutcomePresentation {
        JobOutcomePresentation(
            status: job.status,
            acknowledgedOmissionCount: acknowledgedWarningIssueCounts[job.id]
        )
    }
}

private struct DashboardBackupFact: View {
    var symbol: String
    var title: String
    var value: String
    var detail: String
    var color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusIcon(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BackupsView: View {
    @EnvironmentObject private var model: DeltaAppModel
    var onAddDestination: () -> Void
    @State private var isPresentingProfileSheet = false

    var body: some View {
        PageScaffold(
            title: "Backups",
            subtitle: "Sources, schedules, and retention",
            actions: {
                if !deltaRepositories.isEmpty && !model.profiles.isEmpty {
                    Button {
                        isPresentingProfileSheet = true
                    } label: {
                        Label("New profile", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isPersistentStoreAvailable)
                }
            }
        ) {
            if model.repositories.isEmpty {
                EmptyStateView(
                    symbol: "shippingbox",
                    title: "Create a destination first",
                    message: "Backups need a local drive, mounted network drive, or cloud destination.",
                    actionTitle: "Add Destination",
                    action: onAddDestination
                )
            } else if deltaRepositories.isEmpty {
                EmptyStateView(
                    symbol: "clock.arrow.circlepath",
                    title: "Time Machine is managed by macOS",
                    message: "Delta presents the remote disk, while macOS manages Time Machine sources and schedules. Add a Delta encrypted backup destination to create Delta profiles.",
                    actionTitle: "Add Delta Destination",
                    action: onAddDestination
                )
            } else if model.profiles.isEmpty {
                EmptyStateView(
                    symbol: "externaldrive.badge.plus",
                    title: "No profiles yet",
                    message: "Create a profile for a full volume or selected folders.",
                    actionTitle: "New Profile",
                    action: { isPresentingProfileSheet = true }
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
                .frame(width: ModalMetrics.sheetWidth, height: ModalMetrics.sheetHeight)
        }
    }

    private var deltaRepositories: [BackupRepository] {
        model.repositories.filter { $0.format == .delta }
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

struct DestinationsView: View {
    @EnvironmentObject private var model: DeltaAppModel
    @Binding var isPresentingDestinationSheet: Bool

    var body: some View {
        PageScaffold(
            title: "Destinations",
            subtitle: "Where encrypted backups are stored",
            actions: {
                if !model.repositories.isEmpty {
                    Button {
                        isPresentingDestinationSheet = true
                    } label: {
                        Label("New destination", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isPersistentStoreAvailable)
                }
            }
        ) {
            if model.repositories.isEmpty {
                EmptyStateView(
                    symbol: "shippingbox",
                    title: "No destinations",
                    message: "Add a drive, NAS path, or cloud location to store encrypted restore points.",
                    actionTitle: "New Destination",
                    action: { isPresentingDestinationSheet = true }
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(model.repositories) { destination in
                        DestinationRow(destination: destination)
                    }
                }
            }
        }
        .sheet(isPresented: $isPresentingDestinationSheet) {
            DestinationEditorView()
                .environmentObject(model)
        }
    }
}

struct RestoreView: View {
    @EnvironmentObject private var model: DeltaAppModel
    var onAddDestination: () -> Void
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
    @State private var expandedBrowserPaths: Set<String> = []
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
            subtitle: "Browse an earlier backup and recover exactly what you need",
            actions: {
                if !timeMachineRepositories.isEmpty, !deltaRepositories.isEmpty {
                    Button {
                        model.openTimeMachine()
                    } label: {
                        Label("Open Time Machine", systemImage: "clock.arrow.circlepath")
                    }
                    .deltaTooltip("Browse and restore from connected Time Machine backups using macOS.")
                }
                if !deltaRepositories.isEmpty {
                    Button {
                        if let repository = selectedRepository {
                            model.refreshSnapshots(repository: repository)
                        }
                    } label: {
                        Label("Refresh Points", systemImage: "arrow.clockwise")
                    }
                    .disabled(selectedRepository == nil || model.isWorking)
                }
            }
        ) {
            if model.repositories.isEmpty {
                EmptyStateView(
                    symbol: "arrow.uturn.backward.circle",
                    title: "No destinations to restore from",
                    message: "Add a destination and create a restore point before recovering files.",
                    actionTitle: "Add Destination",
                    action: onAddDestination
                )
            } else if deltaRepositories.isEmpty {
                EmptyStateView(
                    symbol: "clock.arrow.circlepath",
                    title: "Restore with Time Machine",
                    message: "Time Machine owns browsing and recovery for these destinations. Connect the disk, then use the native Time Machine restore experience.",
                    actionTitle: "Open Time Machine",
                    action: { model.openTimeMachine() }
                )
            } else {
                restoreWorkflow
            }
        }
        .onAppear {
            applyRestoreDefaultsIfNeeded()
            repositoryID = repositoryID ?? model.repositories.first(where: { $0.format == .delta })?.id
            reconcileSelectedRestorePoint()
            refreshRestorePointsIfNeeded()
        }
        .onChange(of: repositoryID) { _, _ in
            snapshotID = ""
            resetBrowser()
            reconcileSelectedRestorePoint()
            refreshRestorePointsIfNeeded()
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

    private var deltaRepositories: [BackupRepository] {
        model.repositories.filter { $0.format == .delta }
    }

    private var timeMachineRepositories: [BackupRepository] {
        model.repositories.filter { $0.format == .timeMachine }
    }

    @ViewBuilder
    private var restoreWorkflow: some View {
        RestoreStepCard(number: 1, title: "Restore Point", subtitle: "Choose where the backup is stored and the point in time.") {
            RestoreForm {
                RestoreFormRow(title: "Destination") {
                    Picker("Destination", selection: $repositoryID) {
                        Text("Choose").tag(UUID?.none)
                        ForEach(model.repositories.filter { $0.format == .delta }) { repository in
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
                expandedPaths: $expandedBrowserPaths,
                repository: selectedRepository,
                snapshotID: snapshotID,
                currentPath: currentBrowserDirectory,
                selectedCount: normalizedSelectedRestorePaths.count,
                isLoading: isLoadingBrowserEntries,
                canBrowse: canBrowseSnapshot,
                emptyMessage: browserEmptyMessage,
                onOpen: openBrowserDirectory,
                onBack: navigateBrowserBack,
                onRoot: navigateBrowserRoot,
                onRefresh: refreshCurrentBrowserDirectory,
                onClearSelection: clearRestoreSelection,
                onLoadChildren: loadBrowserDirectoryChildren
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

                RestoreFormRow(title: "Existing files") {
                    Picker("Conflicts", selection: $conflictPolicy) {
                        ForEach(RestoreConflictPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .leading)
                }

                RestoreFormRow(title: "Options") {
                    Toggle("Preview only", isOn: $dryRun)
                        .toggleStyle(.checkbox)
                    Toggle("Verify files", isOn: $verify)
                        .toggleStyle(.checkbox)
                        .disabled(dryRun)
                        .deltaTooltip(dryRun ? "Verification runs after a real restore writes files." : "Verify restored file contents after writing.")
                }

                RestoreFormRow(title: "Safety backup") {
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
                        name: SnapshotBrowserPaths.displayName(for: path),
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
        .filter { SnapshotBrowserPaths.normalized($0.path) != SnapshotBrowserPaths.normalized(currentBrowserDirectory) }
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

    private func refreshRestorePointsIfNeeded() {
        guard repositorySnapshots.isEmpty else { return }
        refreshRestorePointsForSelectedRepository()
    }

    private func openBrowserDirectory(_ path: String) {
        guard let repository = selectedRepository, !snapshotID.isEmpty else {
            return
        }
        guard currentBrowserDirectory != path else {
            return
        }
        expandedBrowserPaths.insert(path)
        browserPathStack.append(path)
        model.loadSnapshotEntries(repository: repository, snapshotID: snapshotID, directoryPath: path)
    }

    private func navigateBrowserBack() {
        guard !browserPathStack.isEmpty else {
            return
        }
        browserPathStack.removeLast()
    }

    private func navigateBrowserRoot() {
        browserPathStack.removeAll()
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

    private func loadBrowserDirectoryChildren(_ path: String, force: Bool) {
        guard let repository = selectedRepository, !snapshotID.isEmpty else {
            return
        }
        model.loadSnapshotEntries(repository: repository, snapshotID: snapshotID, directoryPath: path, force: force)
    }

    private func clearRestoreSelection() {
        selectedRestorePaths.removeAll()
    }

    private func resetBrowser() {
        selectedRestorePaths.removeAll()
        browserPathStack.removeAll()
        expandedBrowserPaths.removeAll()
    }

    private static func normalizedRestorePaths(_ paths: [String]) -> [String] {
        let normalized = Set(paths.map(SnapshotBrowserPaths.normalized).filter { !$0.isEmpty })
        return normalized
            .filter { path in
                !normalized.contains { candidate in
                    candidate != path && path.hasPrefix(candidate == "/" ? "/" : "\(candidate)/")
                }
            }
            .sorted()
    }
}

struct SnapshotBrowserPanel: View {
    var entries: [ResticSnapshotEntry]
    @Binding var selectedPaths: Set<String>
    @Binding var expandedPaths: Set<String>
    var repository: BackupRepository?
    var snapshotID: String
    var currentPath: String?
    var selectedCount: Int
    var isLoading: Bool
    var canBrowse: Bool
    var emptyMessage: String
    var onOpen: (String) -> Void
    var onBack: () -> Void
    var onRoot: () -> Void
    var onRefresh: () -> Void
    var onClearSelection: () -> Void
    var onLoadChildren: (String, Bool) -> Void

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
                SnapshotBrowserPathBar(
                    path: currentPath,
                    isLoading: isLoading,
                    onBack: onBack,
                    onRoot: onRoot
                )
            }

            browserBody
                .frame(height: 330)

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
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            SnapshotBrowserTreeNode(
                                entry: entry,
                                selectedPaths: $selectedPaths,
                                expandedPaths: $expandedPaths,
                                repository: repository,
                                snapshotID: snapshotID,
                                canBrowse: canBrowse,
                                depth: 0,
                                onOpen: onOpen,
                                onLoadChildren: onLoadChildren
                            )
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
}

struct SnapshotBrowserPathBar: View {
    var path: String
    var isLoading: Bool
    var onBack: () -> Void
    var onRoot: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(isLoading)

            Button {
                onRoot()
            } label: {
                Label("Sources", systemImage: "externaldrive")
            }
            .buttonStyle(.borderless)
            .disabled(isLoading)

            Text(path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 2)
    }
}

struct SnapshotBrowserTreeNode: View {
    @EnvironmentObject private var model: DeltaAppModel

    var entry: ResticSnapshotEntry
    @Binding var selectedPaths: Set<String>
    @Binding var expandedPaths: Set<String>
    var repository: BackupRepository?
    var snapshotID: String
    var canBrowse: Bool
    var depth: Int
    var onOpen: (String) -> Void
    var onLoadChildren: (String, Bool) -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row

            if entry.type.isDirectory && isExpanded {
                if isLoadingChildren && childEntries.isEmpty {
                    SnapshotBrowserIndentedText(text: "Loading...", depth: depth + 1)
                } else if childEntries.isEmpty {
                    SnapshotBrowserIndentedText(text: "Empty folder", depth: depth + 1)
                } else {
                    ForEach(childEntries) { child in
                        SnapshotBrowserTreeNode(
                            entry: child,
                            selectedPaths: $selectedPaths,
                            expandedPaths: $expandedPaths,
                            repository: repository,
                            snapshotID: snapshotID,
                            canBrowse: canBrowse,
                            depth: depth + 1,
                            onOpen: onOpen,
                            onLoadChildren: onLoadChildren
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var row: some View {
        HStack(spacing: 8) {
            disclosureButton

            Toggle("", isOn: selectionBinding)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 18)

            Image(systemName: iconName)
                .foregroundStyle(iconColor)
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

            Spacer(minLength: 10)

            if isLoadingChildren {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else if let detailText {
                Text(detailText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if entry.type.isDirectory {
                Button {
                    onOpen(entry.path)
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(!canBrowse)
                .accessibilityLabel("Open \(entry.name)")
                .deltaTooltip("Open folder")
            } else {
                Color.clear
                    .frame(width: 18, height: 18)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .padding(.leading, CGFloat(depth) * 18)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture(count: 2) {
            if entry.type.isDirectory {
                onOpen(entry.path)
            } else {
                toggleSelection()
            }
        }
    }

    @ViewBuilder
    private var disclosureButton: some View {
        if entry.type.isDirectory {
            Button {
                toggleExpanded()
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)
            .accessibilityLabel(isExpanded ? "Collapse \(entry.name)" : "Expand \(entry.name)")
        } else {
            Color.clear
                .frame(width: 16, height: 16)
        }
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

    private var iconColor: Color {
        switch entry.type {
        case .directory:
            return .blue
        case .symlink:
            return .purple
        case .file, .other:
            return .secondary
        }
    }

    private var detailText: String? {
        if entry.type.isDirectory, let repository, !snapshotID.isEmpty {
            let count = model.snapshotEntries(repositoryID: repository.id, snapshotID: snapshotID, directoryPath: entry.path)?
                .filter { SnapshotBrowserPaths.normalized($0.path) != SnapshotBrowserPaths.normalized(entry.path) }
                .count
            return count.map { "\($0) items" }
        }
        guard let size = entry.size, !entry.type.isDirectory else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private var childEntries: [ResticSnapshotEntry] {
        guard let repository, !snapshotID.isEmpty else {
            return []
        }
        return (model.snapshotEntries(repositoryID: repository.id, snapshotID: snapshotID, directoryPath: entry.path) ?? [])
            .filter { SnapshotBrowserPaths.normalized($0.path) != SnapshotBrowserPaths.normalized(entry.path) }
            .sortedForBrowser()
    }

    private var isLoadingChildren: Bool {
        guard let repository, !snapshotID.isEmpty else {
            return false
        }
        return model.isLoadingSnapshotEntries(repositoryID: repository.id, snapshotID: snapshotID, directoryPath: entry.path)
    }

    private var canExpand: Bool {
        canBrowse && entry.type.isDirectory
    }

    private var isExpanded: Bool {
        expandedPaths.contains(entry.path)
    }

    private var isSelected: Bool {
        selectedPaths.contains(entry.path)
    }

    private var rowBackground: Color {
        if isSelected {
            return DeltaTheme.badge.opacity(0.95)
        }
        if isHovering {
            return DeltaTheme.badge.opacity(0.45)
        }
        return .clear
    }

    private var selectionBinding: Binding<Bool> {
        Binding(
            get: { selectedPaths.contains(entry.path) },
            set: { selected in
                if selected {
                    selectedPaths.insert(entry.path)
                } else {
                    selectedPaths.remove(entry.path)
                }
            }
        )
    }

    private func toggleExpanded() {
        guard canExpand else {
            return
        }
        withAnimation(.easeOut(duration: 0.12)) {
            if isExpanded {
                expandedPaths.remove(entry.path)
            } else {
                expandedPaths.insert(entry.path)
                onLoadChildren(entry.path, false)
            }
        }
    }

    private func toggleSelection() {
        if isSelected {
            selectedPaths.remove(entry.path)
        } else {
            selectedPaths.insert(entry.path)
        }
    }
}

struct SnapshotBrowserIndentedText: View {
    var text: String
    var depth: Int

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .padding(.leading, 70 + CGFloat(depth) * 18)
    }
}

private enum SnapshotBrowserPaths {
    static func normalized(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        if trimmed == "/" {
            return "/"
        }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    static func displayName(for path: String) -> String {
        if path == "/" {
            return "System volume (/)"
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
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
    @State private var section: ActivitySection = .jobs
    @State private var jobFilter: ActivityJobFilter = .all
    @State private var selectedJobID: UUID?

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Activity")
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                        Text("Run history, issues, and diagnostic output")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    Picker("View", selection: $section) {
                        ForEach(ActivitySection.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    Button {
                        model.reload()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }

                Group {
                    switch section {
                    case .jobs:
                        activityWorkspace
                    case .events:
                        ActivityEventList(events: model.events)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .background(DeltaTheme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DeltaTheme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .topLeading
            )
            .clipped()
        }
        .background(DeltaTheme.background)
        .task {
            reconcileSelection()
        }
        .onChange(of: model.jobs) { _, _ in
            reconcileSelection()
        }
        .onChange(of: jobFilter) { _, _ in
            reconcileSelection()
        }
    }

    private var activityWorkspace: some View {
        Group {
            if visibleJobs.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    activityListHeader
                    Divider()
                    ContentUnavailableView(
                        jobFilter == .attention ? "No Runs Need Attention" : "No Runs Yet",
                        systemImage: jobFilter == .attention ? "checkmark.circle" : "clock.arrow.circlepath",
                        description: Text(jobFilter == .attention ? "Warning and failed runs appear here." : "Backup and maintenance history will appear here.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        activityListHeader
                        Divider()
                        List(selection: $selectedJobID) {
                            ForEach(visibleJobs) { job in
                                ActivityJobListRow(
                                    job: job,
                                    profileName: profileName(for: job),
                                    outcome: model.outcomePresentation(for: job)
                                )
                                .tag(job.id)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 0, maxHeight: .infinity)
                    }
                    .frame(width: 300)
                    .frame(minHeight: 0, maxHeight: .infinity)
                    .clipped()

                    Divider()

                    if let selectedJob {
                        ActivityJobDetailView(
                            job: selectedJob,
                            profileName: profileName(for: selectedJob),
                            repositoryName: repositoryName(for: selectedJob)
                        )
                        .id(selectedJob.id)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .clipped()
                    } else {
                        ContentUnavailableView(
                            "Select a Run",
                            systemImage: "waveform.path.ecg",
                            description: Text("Choose a run to inspect its result and output.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
    }

    private var activityListHeader: some View {
        HStack {
            Text("Runs")
                .font(.headline)
            Spacer()
            Picker("Filter", selection: $jobFilter) {
                ForEach(ActivityJobFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 150)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var visibleJobs: [JobRun] {
        switch jobFilter {
        case .all:
            model.jobs
        case .attention:
            model.jobs.filter { model.outcomePresentation(for: $0).needsAttention }
        }
    }

    private var selectedJob: JobRun? {
        guard let selectedJobID else { return nil }
        return visibleJobs.first { $0.id == selectedJobID }
    }

    private func profileName(for job: JobRun) -> String? {
        job.profileID.flatMap { profileID in
            model.profiles.first { $0.id == profileID }?.name
        }
    }

    private func repositoryName(for job: JobRun) -> String? {
        model.repositories.first { $0.id == job.repositoryID }?.name
    }

    private func reconcileSelection() {
        guard selectedJob == nil else { return }
        selectedJobID = visibleJobs.first?.id
    }
}

private enum ActivitySection: String, CaseIterable, Identifiable {
    case jobs
    case events

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jobs: "Runs"
        case .events: "Events"
        }
    }
}

private enum ActivityJobFilter: String, CaseIterable, Identifiable {
    case all
    case attention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Runs"
        case .attention: "Needs Attention"
        }
    }
}

private enum ActivityLogFilter: String, CaseIterable, Identifiable {
    case issues
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .issues: "Issues"
        case .all: "All Output"
        }
    }
}

private struct ActivityJobListRow: View {
    var job: JobRun
    var profileName: String?
    var outcome: JobOutcomePresentation

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: outcome.activitySymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(outcome.activityColor)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(profileName ?? job.kind.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(outcome.displayName)
                        .foregroundStyle(outcome.activityColor)
                    Text("·")
                    Text(job.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .lineLimit(1)
                if let detailText = outcome.detailText {
                    Text(detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if job.kind != .backup || profileName != nil {
                    Text(job.kind.displayName)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
    }
}

private struct ActivityJobDetailView: View {
    private static let logBottomAnchor = "activity-log-bottom"

    @EnvironmentObject private var model: DeltaAppModel
    var job: JobRun
    var profileName: String?
    var repositoryName: String?

    @State private var logFilter: ActivityLogFilter
    @State private var entries: [JobLogEntry] = []
    @State private var totalCount = 0
    @State private var issueCount = 0
    @State private var nextCursor: JobLogCursor?
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var loadError: String?

    init(job: JobRun, profileName: String?, repositoryName: String?) {
        self.job = job
        self.profileName = profileName
        self.repositoryName = repositoryName
        _logFilter = State(initialValue: job.status == .warning || job.status == .failed ? .issues : .all)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                StatusIcon(symbol: outcome.activitySymbol, color: outcome.activityColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(profileName ?? job.kind.displayName)
                        .font(.title3.weight(.semibold))
                    Text(jobMetadata)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                StatusPill(outcome: outcome)
            }

            if let message = job.message, !message.isEmpty,
               job.status == .warning || job.status == .failed || job.status == .cancelled {
                ActivityResultNotice(outcome: outcome, message: message)
            }

            if let summary = job.backupSummary {
                BackupSummaryMetricRow(summary: summary)
            }

            Divider()

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(logSectionTitle)
                        .font(.headline)
                    Text(logCountSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if issueCount > 0 || job.status == .warning || job.status == .failed {
                    Picker("Output", selection: $logFilter) {
                        ForEach(ActivityLogFilter.allCases) { filter in
                            Text(filter == .issues && outcome.hasKnownOmissions ? "Omissions" : filter.title)
                                .tag(filter)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }
                if hasMore {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        Label("Earlier", systemImage: "arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)
                }
            }

            Group {
                if isLoading && entries.isEmpty {
                    ProgressView("Loading output...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView(
                        "Output Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else if entries.isEmpty {
                    ContentUnavailableView(
                        logFilter == .issues ? "No Issue Details" : "No Output Saved",
                        systemImage: logFilter == .issues ? "checkmark.circle" : "doc.text",
                        description: Text(logFilter == .issues ? "This run did not save any issue lines." : "This run did not save diagnostic output.")
                    )
                } else if logFilter == .issues, !structuredIssues.isEmpty {
                    BackupIssueReviewList(
                        issues: structuredIssues,
                        profileID: job.profileID
                    )
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(entries) { entry in
                                    ActivityLogRow(entry: entry)
                                        .padding(.horizontal, 8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Divider()
                                }
                                Color.clear
                                    .frame(height: 1)
                                    .id(Self.logBottomAnchor)
                            }
                        }
                        .defaultScrollAnchor(.bottom)
                        .onChange(of: entries.last?.id) { previousID, latestID in
                            guard latestID != nil, latestID != previousID else { return }
                            Task { @MainActor in
                                await Task.yield()
                                withAnimation(.easeOut(duration: 0.18)) {
                                    proxy.scrollTo(Self.logBottomAnchor, anchor: .bottom)
                                }
                            }
                        }
                        .frame(minHeight: 0, maxHeight: .infinity)
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .padding(18)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .task(id: loadIdentity) {
            await loadInitialPage()
        }
    }

    private var loadIdentity: String {
        // The live list is bounded, so its count stops changing once it is full. The newest
        // entry ID keeps Activity refreshing for every persisted line throughout long runs.
        let liveRevision = job.status == .running ? model.jobLogs.last?.id.uuidString ?? "empty" : "complete"
        return "\(job.id.uuidString)-\(logFilter.rawValue)-\(liveRevision)"
    }

    private var outcome: JobOutcomePresentation {
        model.outcomePresentation(for: job)
    }

    private var structuredIssues: [BackupIssue] {
        entries.compactMap(\.backupIssue)
    }

    private var jobMetadata: String {
        var parts = [
            job.kind.displayName,
            job.startedAt.formatted(date: .abbreviated, time: .shortened)
        ]
        if let repositoryName {
            parts.append(repositoryName)
        }
        return parts.joined(separator: " · ")
    }

    private var logCountSummary: String {
        if logFilter == .issues {
            if outcome.hasKnownOmissions {
                return "\(issueCount) known \(issueCount == 1 ? "omission" : "omissions") · \(totalCount) total lines"
            }
            return "\(issueCount) \(issueCount == 1 ? "issue" : "issues") · \(totalCount) total lines"
        }
        return "\(totalCount) total \(totalCount == 1 ? "line" : "lines")"
    }

    private var logSectionTitle: String {
        if logFilter == .issues, outcome.hasKnownOmissions {
            return "Known Omissions"
        }
        return logFilter == .issues ? "Issues" : "Output"
    }

    private func loadInitialPage() async {
        let requestedFilter = logFilter
        isLoading = true
        loadError = nil
        do {
            let page = try await model.activityLogPage(
                for: job.id,
                issuesOnly: requestedFilter == .issues
            )
            guard !Task.isCancelled, logFilter == requestedFilter else { return }
            entries = page.entries
            totalCount = page.totalCount
            issueCount = page.issueCount
            nextCursor = page.nextCursor
            hasMore = page.hasMore
        } catch {
            guard !Task.isCancelled, logFilter == requestedFilter else { return }
            entries = []
            nextCursor = nil
            hasMore = false
            loadError = error.localizedDescription
        }
        if logFilter == requestedFilter {
            isLoading = false
        }
    }

    private func loadMore() async {
        guard hasMore, let nextCursor, !isLoading else { return }
        let requestedFilter = logFilter
        isLoading = true
        loadError = nil
        do {
            let page = try await model.activityLogPage(
                for: job.id,
                before: nextCursor,
                issuesOnly: requestedFilter == .issues
            )
            guard !Task.isCancelled, logFilter == requestedFilter else { return }
            entries = page.entries + entries
            totalCount = page.totalCount
            issueCount = page.issueCount
            self.nextCursor = page.nextCursor
            hasMore = page.hasMore
        } catch {
            guard !Task.isCancelled, logFilter == requestedFilter else { return }
            loadError = error.localizedDescription
        }
        if logFilter == requestedFilter {
            isLoading = false
        }
    }
}

private struct PendingBackupIssueExclusion: Identifiable {
    var id = UUID()
    var patterns: [String]
    var title: String
    var message: String
}

private struct BackupIssueReviewList: View {
    @EnvironmentObject private var model: DeltaAppModel
    var issues: [BackupIssue]
    var profileID: UUID?

    @State private var pendingExclusion: PendingBackupIssueExclusion?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                reviewHeader
                    .padding(.bottom, 14)

                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    BackupIssueGroupView(
                        group: group,
                        profileID: profileID,
                        excludedPatterns: excludedPatterns,
                        requestExactExclusion: requestExactExclusion,
                        setAcknowledged: setAcknowledged
                    )
                    if index < groups.count - 1 {
                        Divider()
                            .padding(.vertical, 14)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .alert(item: $pendingExclusion) { request in
            Alert(
                title: Text(request.title),
                message: Text(request.message),
                primaryButton: .destructive(Text("Exclude")) {
                    guard let profileID else { return }
                    _ = model.addBackupIssueExclusions(request.patterns, profileID: profileID)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var reviewHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(issues.count) omitted \(issues.count == 1 ? "item" : "items")")
                        .font(.subheadline.weight(.semibold))
                    Text("The restore point exists, but these items were not included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let profile {
                HStack(spacing: 8) {
                    Button {
                        model.runNow(profile: profile)
                    } label: {
                        Label("Back Up Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isWorking)
                    if !availableRecommendedExclusions.isEmpty {
                        Button {
                            requestRecommendedExclusions()
                        } label: {
                            Label("Apply Recommended", systemImage: "checkmark.shield")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            Text(reviewGuidance)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var allIssuesAcknowledged: Bool {
        guard let profileID, !issues.isEmpty else { return false }
        return issues.allSatisfy { model.isBackupIssueAcknowledged($0, profileID: profileID) }
    }

    private var reviewGuidance: String {
        if allIssuesAcknowledged {
            return "These known omissions remain visible for audit, but no longer require attention. Excluding an item changes future backups."
        }
        return "Acknowledging a reviewed omission removes repeat attention while preserving it for audit. Excluding an item changes future backups."
    }

    private var excludedPatterns: Set<String> {
        Set(profile?.excludePatterns ?? [])
    }

    private var profile: BackupProfile? {
        guard let profileID else { return nil }
        return model.profiles.first(where: { $0.id == profileID })
    }

    private var recommendedExclusions: [BackupIssueExclusionRecommendation] {
        let recommendations = issues.compactMap(\.recommendedExclusion)
        return Dictionary(grouping: recommendations, by: \.pattern)
            .values
            .compactMap(\.first)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var availableRecommendedExclusions: [BackupIssueExclusionRecommendation] {
        recommendedExclusions.filter { !excludedPatterns.contains($0.pattern) }
    }

    private var groups: [BackupIssueGroup] {
        BackupIssueGroup.grouped(issues)
    }

    private func requestExactExclusion(_ issue: BackupIssue) {
        pendingExclusion = PendingBackupIssueExclusion(
            patterns: [issue.exactExclusionPattern],
            title: "Exclude this item?",
            message: "Future restore points will omit \(issue.path). Existing restore points are unchanged."
        )
    }

    private func requestRecommendedExclusions() {
        let recommendations = availableRecommendedExclusions
        guard !recommendations.isEmpty else { return }
        pendingExclusion = PendingBackupIssueExclusion(
            patterns: recommendations.map(\.pattern),
            title: "Apply recommended exclusions?",
            message: "Delta will omit \(recommendations.count) reviewed generated-data \(recommendations.count == 1 ? "location" : "locations") from future restore points. Existing restore points are unchanged."
        )
    }

    private func setAcknowledged(_ acknowledged: Bool, issues: [BackupIssue]) {
        guard let profileID else { return }
        model.setBackupIssuesAcknowledged(acknowledged, issues: issues, profileID: profileID)
    }
}

private struct BackupIssueGroupView: View {
    @EnvironmentObject private var model: DeltaAppModel
    var group: BackupIssueGroup
    var profileID: UUID?
    var excludedPatterns: Set<String>
    var requestExactExclusion: (BackupIssue) -> Void
    var setAcknowledged: (Bool, [BackupIssue]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: group.category.symbol)
                    .foregroundStyle(group.category.color)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(group.category.title)
                            .font(.subheadline.weight(.semibold))
                        Text("\(group.issues.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(group.category.guidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if profileID != nil {
                    Button(allAcknowledged ? "Restore Alerts" : "Acknowledge Group") {
                        setAcknowledged(!allAcknowledged, group.issues)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            ForEach(Array(group.issues.enumerated()), id: \.offset) { index, issue in
                if index > 0 {
                    Divider()
                        .padding(.leading, 26)
                }
                BackupIssueRow(
                    issue: issue,
                    profileID: profileID,
                    isExcluded: excludedPatterns.contains(issue.exactExclusionPattern)
                        || issue.recommendedExclusion.map { excludedPatterns.contains($0.pattern) } == true,
                    requestExclusion: { requestExactExclusion(issue) },
                    setAcknowledged: { setAcknowledged($0, [issue]) }
                )
                .padding(.leading, 26)
            }
        }
    }

    private var allAcknowledged: Bool {
        guard let profileID else { return false }
        return group.issues.allSatisfy { model.isBackupIssueAcknowledged($0, profileID: profileID) }
    }
}

private struct BackupIssueRow: View {
    @EnvironmentObject private var model: DeltaAppModel
    var issue: BackupIssue
    var profileID: UUID?
    var isExcluded: Bool
    var requestExclusion: () -> Void
    var setAcknowledged: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.path)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(issue.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let operation = issue.operation {
                    Text(operation.capitalized)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if profileID != nil {
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        if isExcluded {
                            Label("Excluded", systemImage: "checkmark")
                                .foregroundStyle(.green)
                        }
                        if isAcknowledged {
                            Label("Alerts off", systemImage: "bell.slash")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)

                    Menu {
                        Button {
                            model.revealBackupIssue(issue)
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                        }
                        if !isExcluded {
                            Button(action: requestExclusion) {
                                Label("Exclude from Future Backups", systemImage: "minus.circle")
                            }
                        }
                        Button {
                            setAcknowledged(!isAcknowledged)
                        } label: {
                            Label(
                                isAcknowledged ? "Restore Repeat Alerts" : "Acknowledge Repeat Alerts",
                                systemImage: isAcknowledged ? "bell" : "bell.slash"
                            )
                        }
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .fixedSize()
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var isAcknowledged: Bool {
        guard let profileID else { return false }
        return model.isBackupIssueAcknowledged(issue, profileID: profileID)
    }
}

private extension BackupIssueCategory {
    var symbol: String {
        switch self {
        case .permissionDenied: "lock.fill"
        case .changedDuringRead: "arrow.triangle.2.circlepath"
        case .unavailable: "questionmark.folder"
        case .inputOutput: "externaldrive.badge.exclamationmark"
        case .resourceBusy: "clock.badge.exclamationmark"
        case .unsupported: "nosign"
        case .other: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .permissionDenied, .inputOutput: .orange
        case .changedDuringRead: .blue
        case .unavailable, .resourceBusy: .secondary
        case .unsupported, .other: .secondary
        }
    }
}

private struct ActivityResultNotice: View {
    var outcome: JobOutcomePresentation
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: outcome.activitySymbol)
                .foregroundStyle(outcome.activityColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(outcome.displayName)
                    .font(.subheadline.weight(.semibold))
                Text(noticeMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(outcome.activityColor.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var noticeMessage: String {
        if outcome.hasKnownOmissions {
            return "Backup completed with \(outcome.detailText ?? "known omissions"). No new issues need attention."
        }
        return message
    }
}

private struct ActivityLogRow: View {
    var entry: JobLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(entry.date.formatted(date: .omitted, time: .standard))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 74, alignment: .leading)
            Text(entry.stream == .standardError ? "ISSUE" : "INFO")
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(entry.stream == .standardError ? .orange : .secondary)
                .frame(width: 42, alignment: .leading)
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(entry.stream == .standardError ? .primary : .secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let level = entry.stream == .standardError ? "Issue" : "Information"
        return "\(entry.date.formatted(date: .omitted, time: .standard)), \(level), \(entry.message)"
    }
}

private struct ActivityEventList: View {
    var events: [EventLog]

    var body: some View {
        if events.isEmpty {
            ContentUnavailableView(
                "No Events",
                systemImage: "list.bullet.rectangle",
                description: Text("System and scheduling events will appear here.")
            )
        } else {
            List(events) { event in
                EventRow(event: event)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 0, maxHeight: .infinity)
        }
    }
}

private extension JobStatus {
    var activityColor: Color {
        switch self {
        case .succeeded: .green
        case .warning: .orange
        case .failed: .red
        case .running: .blue
        case .queued: .secondary
        case .cancelled: .gray
        }
    }

    var activitySymbol: String {
        switch self {
        case .succeeded: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .queued: "clock.fill"
        case .cancelled: "stop.circle.fill"
        }
    }
}

private extension JobOutcomePresentation {
    var activityColor: Color { visualStatus.activityColor }
    var activitySymbol: String { visualStatus.activitySymbol }
}

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var model: DeltaAppModel
    @EnvironmentObject private var softwareUpdateController: SoftwareUpdateController
    @State private var showsScheduledBackupsDetails = false
    @AppStorage(
        DeltaAppPreferenceKeys.updateCheckIntervalSeconds,
        store: DeltaAppPreferences.sharedStore()
    ) private var updateCheckIntervalSeconds = AppUpdateCheckInterval.daily.rawValue
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
        DeltaAppPreferenceKeys.destinationFreeSpaceWarningGiB,
        store: DeltaAppPreferences.sharedStore()
    ) private var destinationFreeSpaceWarningGiB = DestinationFreeSpaceWarningThreshold.fiftyGiB.rawValue
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
        DeltaAppPreferenceKeys.defaultProfileScheduleEnabled,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileScheduleEnabled = true
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfileScheduleKind,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileScheduleKindRawValue = DefaultBackupScheduleKind.daily.rawValue
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfileScheduleHour,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileScheduleHour = 20
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfileScheduleMinute,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileScheduleMinute = 0
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfileScheduleWeekday,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileScheduleWeekday = 2
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfileScheduleDay,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileScheduleDay = 1
    @AppStorage(
        DeltaAppPreferenceKeys.defaultProfileScheduleIntervalMinutes,
        store: DeltaAppPreferences.sharedStore()
    ) private var defaultProfileScheduleIntervalMinutes = 120
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
        VStack(spacing: 0) {
            settingsNavigation
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    settingsPageHeader

                    if let persistentStoreErrorMessage = model.persistentStoreErrorMessage {
                        SettingsCard(title: "Local App Data") {
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

                    if settingsCategory == .general {
                        SettingsCard(title: "Scheduled Backups") {
                            SettingsControlRow(
                                title: "Allow scheduled backups",
                                detail: backgroundBackupsPresentation.controlDetail
                            ) {
                                Toggle("", isOn: backgroundBackupsBinding)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }

                            SettingsDivider()

                            SettingsControlRow(
                                title: "Pause automatic runs",
                                detail:
                                    "Temporarily stop hourly, daily, weekly, monthly, and custom due runs without editing profiles or removing macOS approval."
                            ) {
                                Toggle("", isOn: $pausesScheduledBackups)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }

                            if let scheduledBackupServiceError = model.scheduledBackupServiceError {
                                SettingsNotice(
                                    symbol: "exclamationmark.triangle",
                                    title: "Automatic backup service needs repair",
                                    text: scheduledBackupServiceError,
                                    color: .red
                                )
                            } else if backgroundBackupsPresentation.needsAttention {
                                SettingsNotice(
                                    symbol: "person.crop.circle.badge.exclamationmark",
                                    title: backgroundBackupsPresentation.attentionTitle ?? "Scheduled backups need attention",
                                    text: backgroundBackupsPresentation.attentionText ?? "Review Scheduled Backups before relying on scheduled runs.",
                                    color: .orange
                                )
                            }

                            if backgroundSecretAccessSummary.needsRepair {
                                SettingsNotice(
                                    symbol: "key.horizontal",
                                    title: "Password access needs repair",
                                    text:
                                        "\(backgroundSecretAccessSummary.detail) Repair access so scheduled backups can read saved destination passwords without Keychain prompts.",
                                    color: .orange
                                )
                            }

                            if scheduledProfileCount == 0 && !backgroundBackupsPresentation.needsAttention && !backgroundSecretAccessSummary.needsRepair {
                                SettingsNotice(
                                    symbol: "calendar.badge.plus",
                                    title: "No scheduled profiles",
                                    text:
                                        "Create an hourly, daily, weekly, monthly, or custom scheduled backup profile before automatic scheduled backups are needed.",
                                    color: .secondary
                                )
                            }

                            SettingsDivider()

                            SettingsDisclosure(
                                title: "How Scheduled Backups Work",
                                symbol: "questionmark.circle",
                                isExpanded: $showsScheduledBackupsDetails
                            ) {
                                SettingsDescription(text: BackgroundBackupServicePresentation.purposeText)
                                SettingsCapabilityList(items: [
                                    SettingsCapability(
                                        symbol: "checkmark.seal", title: "Approved by macOS",
                                        detail: "macOS approves Delta's scheduled-backup service in Login Items before unattended runs are allowed."),
                                    SettingsCapability(
                                        symbol: "moon.zzz", title: "Runs while Delta is closed",
                                        detail: "Scheduled profiles can run after sign-in without keeping the main window open."),
                                    SettingsCapability(
                                        symbol: "person.crop.circle", title: "No admin privileges",
                                        detail: "The service runs as your user account with the same file permissions granted to Delta."),
                                    SettingsCapability(
                                        symbol: "bolt.badge.checkmark", title: "Checks policy first",
                                        detail: "Battery, Low Power Mode, speed limits, destination availability, and locking are checked before work starts.")
                                ])
                            }

                            SettingsDivider()

                            SettingsActionRow(
                                title: "Run due backups",
                                detail: "Start every profile that is currently due using the same rules as scheduled runs.",
                                systemImage: "play.fill"
                            ) {
                                Button("Run Due Now") {
                                    model.runDueBackups()
                                }
                                .disabled(model.profiles.isEmpty || model.isWorking || pausesScheduledBackups || !model.isPersistentStoreAvailable)
                                .deltaTooltip(
                                    pausesScheduledBackups
                                        ? "Automatic scheduled runs are paused. Resume them here or run a manual profile backup."
                                        : "Run every backup profile that is currently due using the same rules as automatic scheduled runs.")
                            }

                            SettingsDivider()

                            SettingsActionRow(
                                title: "Scheduled backup access",
                                detail: "Review Login Items approval and saved-password access for unattended runs.",
                                systemImage: "lock.shield"
                            ) {
                                Button("Review Permissions") {
                                    settingsCategory = .permissions
                                }
                                .deltaTooltip("Review every macOS permission and unattended-access check in one place.")
                            }
                        }

                        SettingsCard(title: "Power & Reliability") {
                            SettingsControlRow(
                                title: "Keep Mac awake during backup work",
                                detail: "Prevent idle sleep while Delta is actively preparing, backing up, restoring, checking, or cleaning up a destination."
                            ) {
                                Toggle("", isOn: $preventsIdleSleepDuringJobs)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }
                        }

                        SettingsCard(title: "Menu Bar & Login") {
                            SettingsControlRow(
                                title: "Status menu",
                                detail:
                                    "Keep Back Up Now, Run Due Backups, Pause, Stop, last backup status, activity, and update checks available outside the main window."
                            ) {
                                Toggle("", isOn: $showsMenuBarExtra)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }

                            SettingsDivider()

                            SettingsControlRow(
                                title: "Start Delta at login",
                                detail: "Open the Delta app after you sign in so the menu bar controls and dashboard are immediately available."
                            ) {
                                Toggle("", isOn: appLoginItemBinding)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }

                            if model.appLoginItemStatus == .requiresApproval {
                                SettingsNotice(
                                    symbol: "person.crop.circle.badge.exclamationmark",
                                    title: "Login Items approval required",
                                    text: "macOS may ask you to approve Delta before it can open automatically at sign-in.",
                                    color: .orange
                                )
                            }

                            SettingsDivider()

                            SettingsActionRow(
                                title: "Login Items",
                                detail: "Review Delta's sign-in approval in macOS System Settings.",
                                systemImage: "gearshape"
                            ) {
                                HStack(spacing: 8) {
                                    Button("System Settings") {
                                        model.openLoginItemsSettings()
                                    }
                                    .deltaTooltip("Open macOS Login Items to approve or inspect Delta startup.")
                                    Button("Refresh") {
                                        model.reload()
                                    }
                                    .deltaTooltip("Recheck Delta's menu bar and login status.")
                                }
                            }
                        }

                        SettingsCard(title: "Notifications") {
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

                            SettingsDivider()

                            SettingsControlRow(
                                title: "Success summaries",
                                detail: "Also notify when a backup finishes successfully with its new, changed, and checked file summary."
                            ) {
                                Toggle("", isOn: $sendsSuccessfulBackupNotifications)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .disabled(!sendsJobNotifications)
                            }

                            SettingsDivider()

                            SettingsActionRow(
                                title: "Notification access",
                                detail: "macOS permission: \(notificationAuthorizationState.displayName).",
                                systemImage: "bell.and.waves.left.and.right"
                            ) {
                                HStack(spacing: 8) {
                                    Button("Send Test") {
                                        sendTestNotification()
                                    }
                                    .disabled(!canSendTestNotification)
                                    .deltaTooltip(notificationTestAlertTooltip)

                                    Button("Review Permissions") {
                                        settingsCategory = .permissions
                                    }
                                    .deltaTooltip("Review notification access alongside Delta's other macOS permissions.")
                                }
                            }
                        }
                    }

                    if settingsCategory == .permissions {
                        SettingsCard(title: "System Access") {
                            SettingsPermissionRow(
                                title: "Full Disk Access",
                                detail: fullDiskAccessDescription,
                                systemImage: "externaldrive.badge.person.crop",
                                status: fullDiskAccessPermissionPresentation
                            ) {
                                fullDiskAccessPermissionActions
                            }

                            SettingsDivider()

                            SettingsPermissionRow(
                                title: "Time Machine File System",
                                detail: timeMachineFileSystemPermissionDescription,
                                systemImage: "externaldrive.badge.timemachine",
                                status: timeMachineFileSystemPermissionPresentation
                            ) {
                                timeMachineFileSystemPermissionActions
                            }

                            SettingsDivider()

                            SettingsPermissionRow(
                                title: "Time Machine System Support",
                                detail: timeMachineSystemSupportDescription,
                                systemImage: "lock.shield",
                                status: timeMachineSystemSupportPermissionPresentation
                            ) {
                                timeMachineSystemSupportPermissionActions
                            }

                            SettingsDivider()

                            SettingsPermissionRow(
                                title: "Notifications",
                                detail:
                                    "Only required when job alerts are enabled. Delta uses notifications for backup results and warnings, never advertising.",
                                systemImage: "bell.badge",
                                status: notificationPermissionPresentation
                            ) {
                                notificationPermissionActions
                            }

                            SettingsDivider()

                            SettingsPermissionRow(
                                title: "Scheduled Backups",
                                detail: "macOS approves Delta in Login Items before scheduled profiles can run while the main window is closed.",
                                systemImage: "clock.badge.checkmark",
                                status: scheduledBackupsPermissionPresentation
                            ) {
                                scheduledBackupsPermissionActions
                            }

                            SettingsDivider()

                            SettingsPermissionRow(
                                title: "Saved Passwords",
                                detail: backgroundSecretAccessSummary.detail,
                                systemImage: "key.horizontal",
                                status: passwordAccessPermissionPresentation
                            ) {
                                passwordAccessPermissionActions
                            }
                        }

                        SettingsPermissionNote(
                            title: "Access stays under your control",
                            detail:
                                "Delta requests only the access needed by features you enable. Full Disk Access is granted in macOS System Settings, notifications can be allowed on demand, and saved passwords remain in your Keychain.",
                            systemImage: "hand.raised"
                        )
                    }

                    if settingsCategory == .defaults {
                        SettingsCard(title: "Health Monitoring") {
                            SettingsControlRow(
                                title: "Backup freshness",
                                detail:
                                    "Show dashboard attention when a scheduled profile has no completed backup or its last completed backup is older than this."
                            ) {
                                Picker("", selection: $backupFreshnessWarningHours) {
                                    ForEach(BackupFreshnessWarningThreshold.allCases) { threshold in
                                        Text(threshold.title).tag(threshold.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 120)
                                .onChange(of: backupFreshnessWarningHours) { _, _ in
                                    normalizeHealthMonitoring()
                                }
                            }

                            SettingsDivider()

                            SettingsControlRow(
                                title: "Destination checks",
                                detail:
                                    "Show dashboard attention when a destination has never been successfully verified, is unavailable locally, or its last successful verification is older than this."
                            ) {
                                Picker("", selection: $destinationVerificationWarningHours) {
                                    ForEach(DestinationVerificationWarningThreshold.allCases) { threshold in
                                        Text(threshold.title).tag(threshold.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 120)
                                .onChange(of: destinationVerificationWarningHours) { _, _ in
                                    normalizeHealthMonitoring()
                                }
                            }

                            SettingsDivider()

                            SettingsControlRow(
                                title: "Destination free space",
                                detail:
                                    "Show dashboard attention when a local or mounted destination has less available space than this. Remote cloud destinations are skipped."
                            ) {
                                Picker("", selection: $destinationFreeSpaceWarningGiB) {
                                    ForEach(DestinationFreeSpaceWarningThreshold.allCases) { threshold in
                                        Text(threshold.title).tag(threshold.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 120)
                                .onChange(of: destinationFreeSpaceWarningGiB) { _, _ in
                                    normalizeHealthMonitoring()
                                }
                            }

                            SettingsDivider()

                            SettingsActionRow(
                                title: "Monitoring defaults",
                                detail: "Restore Delta's recommended thresholds or review current backup health.",
                                systemImage: "arrow.counterclockwise"
                            ) {
                                HStack(spacing: 8) {
                                    Button("Restore") {
                                        resetHealthMonitoringDefaults()
                                    }
                                    Button("Open Dashboard") {
                                        model.selectedSection = .dashboard
                                    }
                                }
                            }
                        }

                        SettingsCard(title: "New Backup Defaults") {
                            SettingsControlRow(
                                title: "Schedule new profiles",
                                detail: "Create new backup profiles with scheduled runs enabled by default."
                            ) {
                                Toggle("", isOn: $defaultProfileScheduleEnabled)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }

                            SettingsDivider()

                            SettingsControlRow(
                                title: "Default schedule",
                                detail: "Initial cadence for newly-created profiles. Each profile can still be changed before saving."
                            ) {
                                VStack(alignment: .trailing, spacing: 10) {
                                    Picker("", selection: $defaultProfileScheduleKindRawValue) {
                                        ForEach(ScheduleEditorKind.allCases) { kind in
                                            Text(kind.displayName).tag(kind.rawValue)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .frame(width: 120)
                                    .onChange(of: defaultProfileScheduleKindRawValue) { _, _ in
                                        normalizeBackupDefaults()
                                    }

                                    defaultScheduleControls
                                }
                                .disabled(!defaultProfileScheduleEnabled)
                            }

                            SettingsDivider()

                            SettingsControlRow(
                                title: "Catch up missed runs",
                                detail:
                                    "Run one backup after a scheduled time was missed because the Mac was asleep, offline, or the destination was unavailable."
                            ) {
                                Toggle("", isOn: $defaultProfileCatchUpMissedRuns)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }

                            SettingsDivider()

                            SettingsControlRow(
                                title: "Run on battery",
                                detail: "Allow scheduled backups when the Mac is not connected to power."
                            ) {
                                Toggle("", isOn: $defaultProfileRunOnBattery)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }

                            SettingsDivider()

                            SettingsControlRow(
                                title: "Run in Low Power Mode",
                                detail: "Allow scheduled backups even when macOS is conserving power."
                            ) {
                                Toggle("", isOn: $defaultProfileRunInLowPowerMode)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }
                        }

                        SettingsCard(title: "Retention & Cleanup Defaults") {

                            SettingsControlRow(
                                title: "Free space after cleanup",
                                detail: "After old restore points are forgotten, remove unreferenced backup data from the destination."
                            ) {
                                Toggle("", isOn: $defaultProfilePruneAfterForget)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }

                            SettingsDivider()

                            SettingsControlRow(
                                title: "Verify after cleanup",
                                detail: "Run a destination check after cleanup to confirm backup data is still readable."
                            ) {
                                Toggle("", isOn: $defaultProfileCheckAfterPrune)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }

                            SettingsDivider()

                            SettingsControlRow(
                                title: "Default speed limits",
                                detail: "Optional upload and download caps for new profiles. Leave blank for unlimited."
                            ) {
                                HStack(spacing: 8) {
                                    TextField("Upload KiB/s", text: defaultUploadLimitBinding)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: .infinity)
                                    TextField("Download KiB/s", text: defaultDownloadLimitBinding)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: .infinity)
                                }
                                .frame(width: settingsControlRowControlWidth, alignment: .trailing)
                            }

                            SettingsDivider()

                            SettingsControlRow(
                                title: "Default retention",
                                detail: "How many restore points new profiles keep before scheduled cleanup removes older ones."
                            ) {
                                LazyVGrid(columns: settingsCounterColumns, alignment: .leading, spacing: 10) {
                                    Stepper("Hourly \(defaultProfileKeepHourly)", value: $defaultProfileKeepHourly, in: 0...168)
                                    Stepper("Daily \(defaultProfileKeepDaily)", value: $defaultProfileKeepDaily, in: 0...365)
                                    Stepper("Weekly \(defaultProfileKeepWeekly)", value: $defaultProfileKeepWeekly, in: 0...260)
                                    Stepper("Monthly \(defaultProfileKeepMonthly)", value: $defaultProfileKeepMonthly, in: 0...120)
                                    Stepper("Yearly \(defaultProfileKeepYearly)", value: $defaultProfileKeepYearly, in: 0...50)
                                }
                                .frame(width: settingsControlRowControlWidth, alignment: .trailing)
                            }

                            SettingsDivider()

                            SettingsControlRow(
                                title: "Automatic cleanup",
                                detail: "Create new profiles with scheduled cleanup for old restore points."
                            ) {
                                Toggle("", isOn: $defaultProfileMaintenanceEnabled)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }

                            SettingsDivider()

                            SettingsControlRow(
                                title: "Cleanup cadence",
                                detail: "How often new profiles should free unneeded data and run post-cleanup checks."
                            ) {
                                LazyVGrid(columns: settingsCounterColumns, alignment: .leading, spacing: 10) {
                                    Stepper("Every \(defaultProfileMaintenanceIntervalDays)d", value: $defaultProfileMaintenanceIntervalDays, in: 1...90)
                                    Stepper("Hour \(defaultProfileMaintenanceHour)", value: $defaultProfileMaintenanceHour, in: 0...23)
                                    Stepper("Minute \(defaultProfileMaintenanceMinute)", value: $defaultProfileMaintenanceMinute, in: 0...59)
                                }
                                .frame(width: settingsControlRowControlWidth, alignment: .trailing)
                                .disabled(!defaultProfileMaintenanceEnabled)
                            }

                            SettingsDivider()

                            SettingsActionRow(
                                title: "Backup defaults",
                                detail: "Restore recommended values or manage the profiles and destinations that use them.",
                                systemImage: "arrow.counterclockwise"
                            ) {
                                HStack(spacing: 8) {
                                    Button("Restore") {
                                        resetBackupDefaults()
                                    }
                                    Button("Profiles") {
                                        model.selectedSection = .backups
                                    }
                                    Button("Destinations") {
                                        model.selectedSection = .destinations
                                    }
                                }
                            }
                        }

                        SettingsCard(title: "Restore Defaults") {
                            SettingsControlRow(
                                title: "Preview first",
                                detail: "Open restores as a preview so Delta shows what would happen before writing files."
                            ) {
                                Toggle("", isOn: $previewsRestoresByDefault)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }

                            SettingsDivider()

                            SettingsControlRow(
                                title: "Verify files",
                                detail: "Ask the backup engine to verify restored file content after writes complete."
                            ) {
                                Toggle("", isOn: $verifiesRestoresByDefault)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }

                            SettingsDivider()

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
                                .pickerStyle(.menu)
                                .frame(width: 180)
                                .onChange(of: defaultRestoreConflictPolicyRawValue) { _, _ in
                                    normalizeRestorePreferences()
                                }
                            }

                            SettingsDivider()

                            SettingsActionRow(
                                title: "Restore defaults",
                                detail: "Restore Delta's conservative recommended values.",
                                systemImage: "arrow.counterclockwise"
                            ) {
                                Button("Restore") {
                                    resetRestoreDefaults()
                                }
                            }
                        }
                    }

                    if settingsCategory == .updates {
                        SettingsCard(title: "Automatic Updates") {
                            SettingsControlRow(
                                title: "Automatically check for updates",
                                detail: "Securely check the signed Delta release feed in the background."
                            ) {
                                Toggle("", isOn: $automaticallyChecksForUpdates)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .onChange(of: automaticallyChecksForUpdates) { _, _ in
                                        applyUpdatePreferences()
                                    }
                            }

                            if automaticallyChecksForUpdates {
                                SettingsDivider()

                                SettingsValueRow(
                                    title: "Check frequency",
                                    detail: "How often Delta checks the signed update feed.",
                                    systemImage: "calendar.badge.clock"
                                ) {
                                    Picker("Frequency", selection: $updateCheckIntervalSeconds) {
                                        ForEach(AppUpdateCheckInterval.allCases) { interval in
                                            Text(interval.title).tag(interval.rawValue)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .frame(width: 110)
                                    .onChange(of: updateCheckIntervalSeconds) { _, _ in
                                        applyUpdatePreferences()
                                    }
                                }

                                if softwareUpdateController.allowsAutomaticUpdates {
                                    SettingsDivider()

                                    SettingsControlRow(
                                        title: "Download updates automatically",
                                        detail: "Prepare verified updates so they are ready when you quit Delta."
                                    ) {
                                        Toggle("", isOn: $automaticallyDownloadsUpdates)
                                            .labelsHidden()
                                            .toggleStyle(.switch)
                                            .onChange(of: automaticallyDownloadsUpdates) { _, _ in
                                                applyUpdatePreferences()
                                            }
                                    }
                                }
                            }
                        }

                        SettingsCard(title: "Delta") {
                            SettingsActionRow(
                                title: "Delta \(appVersion) (\(buildVersion))",
                                detail: softwareUpdateController.updateSafetyDetail
                                    ?? "Updates are signed and verified by Sparkle before installation.",
                                systemImage: "app.badge.checkmark"
                            ) {
                                Button("Check Now") {
                                    softwareUpdateController.checkForUpdates()
                                }
                                .disabled(!softwareUpdateController.canCheckForUpdates)
                            }
                        }
                    }

                    if settingsCategory == .support {
                        SettingsCard(title: "Delta") {
                            SettingsValueRow(
                                title: "Delta \(appVersion) (\(buildVersion))",
                                detail: "Install and update the signed app in Applications to keep macOS privacy approvals stable.",
                                systemImage: "app.badge.checkmark"
                            ) {
                                Text(bundleIdentifier)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                            }

                            SettingsDivider()

                            SettingsValueRow(
                                title: "Local library",
                                detail: "\(model.profiles.count) profiles, \(model.repositories.count) destinations, and \(model.snapshots.count) restore points.",
                                systemImage: "externaldrive.badge.icloud"
                            ) {
                                EmptyView()
                            }
                        }

                        SettingsCard(title: "Backup Tools") {
                            SettingsValueRow(
                                title: "Backup engine",
                                detail: "restic creates, checks, and restores Delta's encrypted backup data.",
                                systemImage: "externaldrive.badge.checkmark"
                            ) {
                                SettingsStatusLabel(isReady: isResticExecutableAvailable)
                            }

                            SettingsDivider()

                            SettingsValueRow(
                                title: "Remote destinations",
                                detail: "rclone connects Delta to supported remote storage providers.",
                                systemImage: "network"
                            ) {
                                SettingsStatusLabel(isReady: isRcloneExecutableAvailable)
                            }

                            SettingsDivider()

                            SettingsActionRow(
                                title: "Bundled tools",
                                detail: "Delta ships the tested binaries used by manual and scheduled jobs.",
                                systemImage: "shippingbox"
                            ) {
                                Button("Show Tools") {
                                    model.revealBackupToolsFolder()
                                }
                                .deltaTooltip("Show Delta's bundled backup engine and remote-destination tool in Finder.")
                            }
                        }

                        SettingsCard(title: "Support Files") {
                            SettingsActionRow(
                                title: "Application data",
                                detail: "Database, locks, background control state, and support files.",
                                systemImage: "folder"
                            ) {
                                Button("Show App Data", action: model.revealApplicationSupportFolder)
                            }

                            SettingsDivider()

                            SettingsActionRow(
                                title: "Job logs",
                                detail: "Saved backup, restore, check, and cleanup output.",
                                systemImage: "doc.text.magnifyingglass"
                            ) {
                                Button("Show Logs", action: model.revealLogFolder)
                            }
                        }

                        SettingsCard(title: "Diagnostics") {
                            SettingsControlRow(
                                title: "History retention",
                                detail:
                                    "Automatically remove old job summaries, saved output, restore requests, and events. Backup data and restore points are not affected."
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

                            SettingsDivider()

                            SettingsActionRow(
                                title: "Copy diagnostic report",
                                detail: "Copy sanitized app, scheduled-backup, destination, profile, and recent job state.",
                                systemImage: "doc.on.doc"
                            ) {
                                Button("Copy Report", action: model.copyDiagnosticReport)
                            }

                            SettingsDivider()

                            SettingsActionRow(
                                title: "Export diagnostic report",
                                detail: "Save the same sanitized report as a Markdown file.",
                                systemImage: "square.and.arrow.down"
                            ) {
                                Button("Export Report", action: model.exportDiagnosticReport)
                            }

                            SettingsDivider()

                            SettingsActionRow(
                                title: "Clean up saved history",
                                detail: "Apply the selected retention policy now. Backup data and restore points are unaffected.",
                                systemImage: "trash"
                            ) {
                                Button("Clean Up Now") {
                                    normalizeOperationalHistoryRetention()
                                    model.pruneOperationalHistoryNow()
                                }
                                .disabled(model.isWorking || !model.isPersistentStoreAvailable)
                                .deltaTooltip("Apply the selected activity history retention policy now.")
                            }
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Settings")
        .onAppear {
            refreshSettingsStatus()
            automaticallyChecksForUpdates = softwareUpdateController.automaticallyChecksForUpdates
            automaticallyDownloadsUpdates = softwareUpdateController.automaticallyDownloadsUpdates
            normalizeOperationalHistoryRetention()
            normalizeHealthMonitoring()
            normalizeBackupDefaults()
            normalizeRestorePreferences()
            applyUpdatePreferences()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshSettingsStatus()
        }
    }

    private var scheduledProfileCount: Int {
        model.profiles.filter { $0.schedule.isEnabled }.count
    }

    private var settingsCategory: DeltaAppModel.SettingsCategory {
        get { model.selectedSettingsCategory }
        nonmutating set { model.selectedSettingsCategory = newValue }
    }

    private var settingsNavigation: some View {
        HStack(spacing: 6) {
            ForEach(DeltaAppModel.SettingsCategory.allCases) { category in
                Button {
                    settingsCategory = category
                } label: {
                    Label(category.title, systemImage: category.symbol)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 11)
                        .frame(height: 32)
                        .background(
                            settingsCategory == category
                                ? Color.accentColor.opacity(0.16)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(settingsCategory == category ? .primary : .secondary)
                .deltaTooltip(category.title)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(height: 52)
        .background(.bar)
    }

    private var settingsPageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(settingsCategory.title)
                .font(.largeTitle.weight(.bold))
            Text(settingsCategory.subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 2)
    }

    private var backgroundSecretAccessSummary: BackgroundSecretAccessSummary {
        BackgroundSecretAccessSummary(
            reports: model.backgroundSecretAccessReports,
            destinationCount: model.repositories.count
        )
    }

    private var backgroundBackupsPresentation: BackgroundBackupServicePresentation {
        BackgroundBackupServicePresentation.make(
            status: model.launchAgentStatus,
            scheduledProfileCount: scheduledProfileCount,
            pausesScheduledBackups: pausesScheduledBackups
        )
    }

    private var fullDiskAccessPermissionPresentation: SettingsPermissionPresentation {
        model.fullDiskAccessStatus.hasLikelyFullDiskAccess ? .ready : .notAllowed
    }

    private var hasTimeMachineDestinations: Bool {
        model.repositories.contains { $0.format == .timeMachine }
    }

    private var timeMachineFileSystemPermissionPresentation: SettingsPermissionPresentation {
        guard hasTimeMachineDestinations else { return .notNeeded }
        switch model.timeMachineFileSystemStatus {
        case .enabled: return .ready
        case .disabled: return .needsAttention
        case .notInstalled, .unavailable: return .notAllowed
        }
    }

    private var timeMachineSystemSupportPermissionPresentation: SettingsPermissionPresentation {
        guard hasTimeMachineDestinations else { return .notNeeded }
        return model.timeMachineSystemSupportIsCurrent ? .ready : .needsAttention
    }

    private var notificationPermissionPresentation: SettingsPermissionPresentation {
        switch notificationAuthorizationState {
        case .authorized:
            return .ready
        case .provisional:
            return .quiet
        case .ephemeral:
            return .temporary
        case .notDetermined:
            return .notRequested
        case .denied:
            return .notAllowed
        case .unknown:
            return .checkAgain
        }
    }

    private var scheduledBackupsPermissionPresentation: SettingsPermissionPresentation {
        if model.scheduledBackupServiceError != nil {
            return .needsAttention
        }
        switch backgroundBackupsPresentation.severity {
        case .ready:
            return .ready
        case .inactive:
            return .notNeeded
        case .attention, .blocked:
            return .needsAttention
        }
    }

    private var passwordAccessPermissionPresentation: SettingsPermissionPresentation {
        switch backgroundSecretAccessSummary.state {
        case .ready:
            return .ready
        case .needsRepair:
            return .needsAttention
        case .unchecked:
            return .checkAgain
        case .noDestinations:
            return .notNeeded
        }
    }

    @ViewBuilder
    private var fullDiskAccessPermissionActions: some View {
        if !model.fullDiskAccessStatus.hasLikelyFullDiskAccess {
            Button("Show Delta") {
                model.revealInstalledAppInFinder()
            }
            Button("System Settings") {
                model.openFullDiskAccessSettings()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var timeMachineFileSystemPermissionActions: some View {
        if hasTimeMachineDestinations, model.timeMachineFileSystemStatus != .enabled {
            Button("System Settings") {
                model.openFileSystemExtensionsSettings()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var timeMachineSystemSupportPermissionActions: some View {
        if hasTimeMachineDestinations, !model.timeMachineSystemSupportIsCurrent {
            Button("Set Up") {
                model.requestTimeMachineSystemAccess()
            }
            .buttonStyle(.borderedProminent)
            Button("Review Login Items") {
                model.openLoginItemsSettings()
            }
        }
    }

    @ViewBuilder
    private var notificationPermissionActions: some View {
        switch notificationAuthorizationState {
        case .notDetermined:
            Button("Allow Notifications") {
                requestNotificationPermission()
            }
            .buttonStyle(.borderedProminent)
        case .denied:
            Button("System Settings") {
                model.openNotificationSettings()
            }
        case .unknown:
            Button("Check Again") {
                refreshNotificationAuthorization()
            }
        case .authorized, .provisional, .ephemeral:
            EmptyView()
        }
    }

    @ViewBuilder
    private var scheduledBackupsPermissionActions: some View {
        if scheduledBackupsPermissionPresentation == .needsAttention {
            Button("Review Login Items") {
                model.openLoginItemsSettings()
            }
        }
    }

    @ViewBuilder
    private var passwordAccessPermissionActions: some View {
        switch backgroundSecretAccessSummary.state {
        case .needsRepair:
            Button("Repair Password Access") {
                model.repairBackgroundSecretAccess()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isWorking || !model.isPersistentStoreAvailable)
        case .unchecked:
            Button("Check Again") {
                model.reload()
            }
        case .ready, .noDestinations:
            EmptyView()
        }
    }

    private var operationalHistoryRetention: OperationalHistoryRetention {
        OperationalHistoryRetention.normalized(operationalHistoryRetentionDays)
    }

    private var fullDiskAccessDescription: String {
        model.fullDiskAccessStatus.hasLikelyFullDiskAccess
            ? "Protected locations look readable for full-volume backups and macOS Time Machine destination changes."
            : "Required for protected backup sources and to add or remove Time Machine disks. Open Privacy & Security, add Delta with the + button if needed, then recheck access."
    }

    private var timeMachineFileSystemPermissionDescription: String {
        guard hasTimeMachineDestinations else {
            return "Only required when a destination uses Time Machine format."
        }
        switch model.timeMachineFileSystemStatus {
        case .enabled:
            return "Delta's File System Extension is enabled and can present remote sparsebundle files to macOS."
        case .disabled:
            return "Open Login Items & Extensions, select File System Extensions, and turn on Delta Time Machine Storage."
        case .notInstalled:
            return "The File System Extension is missing from this Delta installation. Reinstall the signed app."
        case let .unavailable(message):
            return "macOS could not report File System Extension status: \(message)"
        }
    }

    private var timeMachineSystemSupportDescription: String {
        guard hasTimeMachineDestinations else {
            return "Only required when a destination uses Time Machine format."
        }
        if model.timeMachineSystemSupportIsCurrent {
            return "The user service can reach saved remote credentials, and the narrowly scoped system helper can safely add or remove the verified disk in Time Machine."
        }
        if let error = model.timeMachineSystemRegistrationError {
            return error
        }
        if model.timeMachineServiceStatus == .enabled,
           model.timeMachineSetupHelperStatus == .enabled {
            return "Delta needs to refresh Time Machine system support for this installed app version before connecting a disk."
        }
        return "Set up Delta's background service and narrowly scoped disk helper, then approve them in Login Items if macOS asks."
    }

    private var canSendTestNotification: Bool {
        sendsJobNotifications && notificationAuthorizationState.canDeliver
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

    @ViewBuilder
    private var defaultScheduleControls: some View {
        switch defaultProfileScheduleKind {
        case .hourly:
            Stepper("Minute \(defaultProfileScheduleMinute)", value: $defaultProfileScheduleMinute, in: 0...59)
                .frame(width: 126, alignment: .leading)
        case .daily:
            TimeControls(hour: $defaultProfileScheduleHour, minute: $defaultProfileScheduleMinute)
        case .weekly:
            HStack(spacing: 12) {
                Picker("Weekday", selection: $defaultProfileScheduleWeekday) {
                    ForEach(1...7, id: \.self) { value in
                        Text(Calendar.current.weekdaySymbols[value - 1]).tag(value)
                    }
                }
                .frame(width: 170)
                TimeControls(hour: $defaultProfileScheduleHour, minute: $defaultProfileScheduleMinute)
            }
        case .monthly:
            HStack(spacing: 12) {
                Stepper("Day \(defaultProfileScheduleDay)", value: $defaultProfileScheduleDay, in: 1...31)
                    .frame(width: 100, alignment: .leading)
                TimeControls(hour: $defaultProfileScheduleHour, minute: $defaultProfileScheduleMinute)
            }
        case .custom:
            Stepper(
                ScheduleIntervalPresentation.title(minutes: defaultProfileScheduleIntervalMinutes),
                value: $defaultProfileScheduleIntervalMinutes,
                in: 1...10_080,
                step: 15
            )
                .frame(width: 196, alignment: .leading)
        }
    }

    private var defaultProfileScheduleKind: ScheduleEditorKind {
        ScheduleEditorKind(rawValue: defaultProfileScheduleKindRawValue) ?? .daily
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

    private var backupFreshnessThreshold: BackupFreshnessWarningThreshold {
        BackupFreshnessWarningThreshold.normalized(backupFreshnessWarningHours)
    }

    private var destinationVerificationThreshold: DestinationVerificationWarningThreshold {
        DestinationVerificationWarningThreshold.normalized(destinationVerificationWarningHours)
    }

    private var destinationFreeSpaceThreshold: DestinationFreeSpaceWarningThreshold {
        DestinationFreeSpaceWarningThreshold.normalized(destinationFreeSpaceWarningGiB)
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
        let normalizedDestinationFreeSpace = destinationFreeSpaceThreshold.rawValue
        if destinationFreeSpaceWarningGiB != normalizedDestinationFreeSpace {
            destinationFreeSpaceWarningGiB = normalizedDestinationFreeSpace
        }
        let normalizedDestinationVerification = destinationVerificationThreshold.rawValue
        if destinationVerificationWarningHours != normalizedDestinationVerification {
            destinationVerificationWarningHours = normalizedDestinationVerification
        }
    }

    private func normalizeBackupDefaults() {
        let normalizedScheduleKind = DefaultBackupScheduleKind.normalized(defaultProfileScheduleKindRawValue).rawValue
        if defaultProfileScheduleKindRawValue != normalizedScheduleKind {
            defaultProfileScheduleKindRawValue = normalizedScheduleKind
        }
        defaultProfileScheduleHour = clamped(defaultProfileScheduleHour, to: 0...23)
        defaultProfileScheduleMinute = clamped(defaultProfileScheduleMinute, to: 0...59)
        defaultProfileScheduleWeekday = clamped(defaultProfileScheduleWeekday, to: 1...7)
        defaultProfileScheduleDay = clamped(defaultProfileScheduleDay, to: 1...31)
        defaultProfileScheduleIntervalMinutes = clamped(defaultProfileScheduleIntervalMinutes, to: 1...10_080)
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
        destinationFreeSpaceWarningGiB = DestinationFreeSpaceWarningThreshold.fiftyGiB.rawValue
        destinationVerificationWarningHours = DestinationVerificationWarningThreshold.thirtyDays.rawValue
    }

    private func resetBackupDefaults() {
        defaultProfileScheduleEnabled = true
        defaultProfileScheduleKindRawValue = DefaultBackupScheduleKind.daily.rawValue
        defaultProfileScheduleHour = 20
        defaultProfileScheduleMinute = 0
        defaultProfileScheduleWeekday = 2
        defaultProfileScheduleDay = 1
        defaultProfileScheduleIntervalMinutes = 120
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

    private func refreshSettingsStatus() {
        model.refreshSystemState(force: true)
        refreshNotificationAuthorization()
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

private let rowFactColumns = [
    GridItem(.adaptive(minimum: 180), spacing: 16, alignment: .leading)
]

private struct RowFact: View {
    var symbol: String
    var title: String
    var value: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ProfileRow: View {
    @EnvironmentObject private var model: DeltaAppModel
    var profile: BackupProfile
    @State private var isPresentingEditor = false
    @State private var isConfirmingCleanup = false
    @State private var isConfirmingDelete = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    StatusIcon(symbol: profile.sourceMode == .fullVolume ? "internaldrive" : "folder", color: statusColor)
                    VStack(alignment: .leading, spacing: 5) {
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
                        Text(sourceSummary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
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

                        Menu {
                            Button {
                                isPresentingEditor = true
                            } label: {
                                Label("Edit Profile", systemImage: "pencil")
                            }
                            Button {
                                isConfirmingCleanup = true
                            } label: {
                                Label("Clean Up Old Backups", systemImage: "scissors")
                            }
                            .disabled(model.isWorking || !model.isPersistentStoreAvailable)
                            Divider()
                            Button(role: .destructive) {
                                isConfirmingDelete = true
                            } label: {
                                Label("Delete Profile", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 18, height: 18)
                        }
                        .menuStyle(.button)
                        .controlSize(.small)
                        .disabled(model.isWorking || !model.isPersistentStoreAvailable)
                        .accessibilityLabel("More actions for \(profile.name)")
                        .deltaTooltip("More profile actions")
                    }
                }

                Divider()

                LazyVGrid(columns: rowFactColumns, alignment: .leading, spacing: 12) {
                    RowFact(symbol: "externaldrive", title: "Destination", value: repositoryName)
                    RowFact(symbol: "calendar", title: "Schedule", value: scheduleStatusSummary)
                    RowFact(symbol: "clock.arrow.circlepath", title: "Retention", value: retentionSummary)
                }

                if let latestBackupRun, !isActiveBackup {
                    BackupRunSummaryLine(
                        job: latestBackupRun,
                        outcome: model.outcomePresentation(for: latestBackupRun)
                    )
                }

                if isActiveBackup {
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
                .frame(width: ModalMetrics.sheetWidth, height: ModalMetrics.sheetHeight)
        }
        .confirmationDialog("Clean Up Old Restore Points?", isPresented: $isConfirmingCleanup) {
            Button("Clean Up", role: .destructive) {
                model.prune(profile: profile)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delta will permanently forget restore points outside this profile's retention rules and reclaim unreferenced data from \(repositoryName). A destination check runs afterward when enabled.")
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
        switch latestBackupRun.map(model.outcomePresentation(for:))?.visualStatus {
        case .succeeded: return .green
        case .warning: return .orange
        case .failed: return .red
        default: return .secondary
        }
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

    private var repositoryName: String {
        model.repositories.first(where: { $0.id == profile.repositoryID })?.name ?? "Missing destination"
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
        "\(profile.retention.keepDaily)d · \(profile.retention.keepWeekly)w · \(profile.retention.keepMonthly)m"
    }

    private var scheduleStatusSummary: String {
        guard profile.schedule.isEnabled else { return "Off" }
        let lastAttempt = latestBackupRun.flatMap { $0.finishedAt ?? $0.startedAt }
        let decision = ScheduleEvaluator().decision(for: profile.schedule, lastRun: lastAttempt)
        if decision.isDue { return "Due now" }
        guard let nextRun = decision.nextRun else { return scheduleSummary }
        return nextRun.formatted(date: .abbreviated, time: .shortened)
    }

    private func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        let index = min(max(weekday - 1, 0), symbols.count - 1)
        return symbols[index]
    }
}

struct DestinationRow: View {
    @EnvironmentObject private var model: DeltaAppModel
    @EnvironmentObject private var softwareUpdateController: SoftwareUpdateController
    var destination: BackupRepository
    @State private var isPresentingEditor = false
    @State private var passwordSheetMode: DestinationPasswordSheetMode?
    @State private var isConfirmingDelete = false
    @State private var isPresentingRecoveryKey = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    StatusIcon(
                        symbol: destination.format == .timeMachine
                            ? "clock.arrow.circlepath"
                            : (destination.backend.kind == .local ? "externaldrive" : "network"),
                        color: destination.format == .timeMachine
                            ? timeMachineStatusColor
                            : (destination.lastVerifiedAt == nil ? .secondary : .teal)
                    )
                    VStack(alignment: .leading, spacing: 5) {
                        Text(destination.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(backendSummary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        if destination.format == .timeMachine {
                            switch timeMachinePresentation.primaryAction {
                            case .backUpNow:
                                Button {
                                    model.startTimeMachineBackup(destination)
                                } label: {
                                    Label("Back Up Now", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(
                                    model.isWorking
                                        || !model.isPersistentStoreAvailable
                                )
                                .deltaTooltip("Ask macOS Time Machine to start an automatic-style backup to this destination.")
                            case .connect:
                                Button {
                                    if let message = softwareUpdateController.timeMachineConnectionBlockMessage {
                                        model.alertMessage = message
                                        return
                                    }
                                    softwareUpdateController.reserveTimeMachineSystemTransition()
                                    model.connectTimeMachineDestination(destination)
                                } label: {
                                    Label(timeMachineConnectionActionTitle, systemImage: "externaldrive.connected.to.line.below")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(model.isWorking || !model.isPersistentStoreAvailable)
                                .deltaTooltip("Present this encrypted remote disk to macOS Time Machine.")
                            case .repair:
                                Button {
                                    model.initializeRepository(destination)
                                } label: {
                                    Label("Repair Setup", systemImage: "wrench.and.screwdriver")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(model.isWorking || !model.isPersistentStoreAvailable)
                                .deltaTooltip("Authenticate and repair this destination's remote Time Machine setup.")
                            case .checkRemoteStorage:
                                Button {
                                    model.checkRepository(destination)
                                } label: {
                                    Label("Check Again", systemImage: "checkmark.shield")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(model.isWorking || !model.isPersistentStoreAvailable)
                                .deltaTooltip("Recheck the authenticated remote Time Machine history after restoring or reconnecting its storage.")
                            case .none:
                                if let lifecycle = model.timeMachineStatesByRepository[destination.id]?.lifecycle,
                                   lifecycle == .preparing || lifecycle == .disconnecting {
                                    ProgressView()
                                        .controlSize(.small)
                                        .accessibilityLabel(
                                            lifecycle == .disconnecting
                                                ? "Disconnecting \(destination.name)"
                                                : "Connecting \(destination.name)"
                                        )
                                }
                            }
                            if timeMachineIsMounted {
                                Button {
                                    softwareUpdateController.reserveTimeMachineSystemTransition()
                                    model.disconnectTimeMachineDestination(destination)
                                } label: {
                                    Image(systemName: "eject")
                                        .frame(width: 18, height: 18)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(model.isWorking || !model.isPersistentStoreAvailable)
                                .accessibilityLabel("Disconnect \(destination.name)")
                                .deltaTooltip("Finish pending writes and safely disconnect this Time Machine disk.")
                            }
                        } else {
                            Button {
                                model.checkRepository(destination)
                            } label: {
                                Label("Check", systemImage: "checkmark.shield")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(model.isWorking || !model.isPersistentStoreAvailable)
                            .deltaTooltip("Verify this destination and a sample of stored backup data.")
                        }

                        Menu {
                            Button {
                                isPresentingEditor = true
                            } label: {
                                Label("Edit Destination", systemImage: "pencil")
                            }
                            .disabled(timeMachineBlocksConfigurationChanges)
                            if destination.format == .delta {
                                Button {
                                    passwordSheetMode = .rotate
                                } label: {
                                    Label("Change Encryption Password", systemImage: "key.horizontal")
                                }
                                Button {
                                    passwordSheetMode = .reconnect
                                } label: {
                                    Label("Reconnect with Original Password", systemImage: "link.badge.plus")
                                }
                                Button {
                                    model.refreshSnapshots(repository: destination)
                                } label: {
                                    Label("Refresh Restore Points", systemImage: "arrow.clockwise")
                                }
                            } else {
                                Button {
                                    model.openTimeMachine()
                                } label: {
                                    Label("Browse Time Machine Backups", systemImage: "clock.arrow.circlepath")
                                }
                                .disabled(!timeMachineIsMounted)
                                Button {
                                    model.openTimeMachineSettings()
                                } label: {
                                    Label("Time Machine Settings", systemImage: "gear")
                                }
                                Button {
                                    model.checkRepository(destination)
                                } label: {
                                    Label("Check Remote Storage", systemImage: "checkmark.shield")
                                }
                                .disabled(timeMachineBlocksConfigurationChanges)
                                if destination.secretStorageMode == .appManagedKeychain {
                                    Button {
                                        isPresentingRecoveryKey = true
                                    } label: {
                                        Label("Show Recovery Key", systemImage: "key.viewfinder")
                                    }
                                }
                            }
                            Button {
                                model.initializeRepository(destination)
                            } label: {
                                Label("Repair Destination Setup", systemImage: "wrench.and.screwdriver")
                            }
                            .disabled(timeMachineBlocksConfigurationChanges)
                            if destination.format == .timeMachine, timeMachineBlocksConfigurationChanges {
                                Text(timeMachineIsMounted
                                    ? "Disconnect to edit, repair, or verify remote storage."
                                    : "Wait for the current connection operation to finish.")
                            }
                            Divider()
                            Button(role: .destructive) {
                                isConfirmingDelete = true
                            } label: {
                                Label("Remove Destination", systemImage: "trash")
                            }
                            .disabled(timeMachineRemovalIsUnavailable)
                            if timeMachineRemovalRequiresConnection {
                                Text("Connect this Time Machine disk before removing it from Delta so the saved macOS destination can be verified and removed safely.")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 18, height: 18)
                        }
                        .menuStyle(.button)
                        .controlSize(.small)
                        .disabled(model.isWorking || !model.isPersistentStoreAvailable)
                        .accessibilityLabel("More actions for \(destination.name)")
                        .deltaTooltip("More destination actions")
                    }
                }

                Divider()

                LazyVGrid(columns: rowFactColumns, alignment: .leading, spacing: 12) {
                    RowFact(symbol: "shippingbox", title: "Format", value: destination.format.displayName)
                    RowFact(
                        symbol: destination.format == .timeMachine ? "externaldrive.connected.to.line.below" : "clock.arrow.circlepath",
                        title: destination.format == .timeMachine ? "Time Machine" : "Restore Points",
                        value: destination.format == .timeMachine ? timeMachineStatus : "\(restorePointCount)"
                    )
                    if destination.format == .timeMachine {
                        RowFact(symbol: "calendar", title: "Schedule", value: "Managed by macOS")
                    }
                    RowFact(symbol: "checkmark.seal", title: "Last Verified", value: verificationSummary)
                }
                if let timeMachineError {
                    InlineWarning(
                        symbol: timeMachinePresentation.warningSymbol ?? "exclamationmark.triangle",
                        title: timeMachineWarningTitle,
                        message: timeMachineError
                    )
                }
            }
        }
        .sheet(isPresented: $isPresentingEditor) {
            DestinationEditorView(destination: destination)
                .environmentObject(model)
        }
        .sheet(item: $passwordSheetMode) { mode in
            DestinationPasswordView(destination: destination, mode: mode)
                .environmentObject(model)
        }
        .sheet(isPresented: $isPresentingRecoveryKey) {
            TimeMachineRecoveryKeyView(destination: destination)
                .environmentObject(model)
        }
        .confirmationDialog("Remove Destination?", isPresented: $isConfirmingDelete) {
            Button("Remove", role: .destructive) {
                model.deleteRepository(destination)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(destinationRemovalMessage)
        }
    }

    private var verificationSummary: String {
        guard let lastVerifiedAt = destination.lastVerifiedAt else {
            return "Never"
        }
        return lastVerifiedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var restorePointCount: Int {
        model.snapshotsByRepository[destination.id]?.count ?? 0
    }

    private var timeMachineStatus: String {
        timeMachinePresentation.status
    }

    private var timeMachineIsMounted: Bool {
        timeMachinePresentation.isMounted
    }

    private var timeMachineBlocksConfigurationChanges: Bool {
        destination.format == .timeMachine
            && model.timeMachineStatesByRepository[destination.id]?.blocksConfigurationChanges == true
    }

    private var timeMachineRemovalRequiresConnection: Bool {
        guard
            destination.format == .timeMachine,
            let state = model.timeMachineStatesByRepository[destination.id]
        else { return false }
        return state.lifecycle != .mounted
            && state.timeMachineDestinationID != nil
    }

    private var timeMachineRemovalIsUnavailable: Bool {
        guard
            destination.format == .timeMachine,
            let state = model.timeMachineStatesByRepository[destination.id]
        else { return false }
        return state.lifecycle == .preparing
            || state.lifecycle == .disconnecting
            || timeMachineRemovalRequiresConnection
    }

    private var timeMachineError: String? {
        guard destination.format == .timeMachine else { return nil }
        return timeMachinePresentation.warningMessage
    }

    private var timeMachinePresentation: TimeMachineDestinationPresentation {
        TimeMachineDestinationPresentation.make(
            state: model.timeMachineStatesByRepository[destination.id]
        )
    }

    private var timeMachineWarningTitle: String {
        timeMachinePresentation.warningTitle ?? "Time Machine disk is unavailable"
    }

    private var timeMachineConnectionActionTitle: String {
        switch model.timeMachineStatesByRepository[destination.id]?.lastFailureContext {
        case .systemConnection, .storageService:
            "Try Again"
        default:
            "Connect"
        }
    }

    private var timeMachineStatusColor: Color {
        guard let state = model.timeMachineStatesByRepository[destination.id] else {
            return .orange
        }
        if state.lastError != nil {
            return .orange
        }
        switch state.lifecycle {
        case .mounted, .ready:
            return .teal
        case .preparing, .disconnecting:
            return .blue
        case .waitingForPermissions, .needsRepair, .failed:
            return .orange
        case .disconnected:
            return .secondary
        }
    }

    private var destinationRemovalMessage: String {
        guard destination.format == .timeMachine else {
            return "This removes the destination from Delta, deletes cached restore point metadata, and removes Delta's saved password. Backup data at the destination is not deleted; keep the original encryption password if you may reconnect it later."
        }
        let systemRemoval = timeMachineIsMounted
            ? "Delta will remove this verified disk from macOS Time Machine and safely detach it. "
            : ""
        if destination.secretStorageMode == .appManagedKeychain {
            return "\(systemRemoval)Removing this destination deletes Delta's local configuration and bounded cache, but not remote backup data. The encrypted-disk recovery key remains in this Mac's Keychain so the remote disk can be reconnected later; provider credentials must be entered again."
        }
        return "\(systemRemoval)Removing this destination deletes Delta's local configuration, bounded cache, and saved credentials, but not remote backup data. Keep the original encryption password to reconnect the remote disk later."
    }

    private var backendSummary: String {
        switch destination.backend {
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

struct TimeMachineRecoveryKeyView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: DeltaAppModel
    let destination: BackupRepository
    @State private var recoveryKey: String?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var copied = false
    @State private var clipboardCleanupTask: Task<Void, Never>?
    @State private var clipboardChangeCount: Int?

    var body: some View {
        SheetScaffold(
            title: "Time Machine Recovery Key",
            subtitle: "Save this key somewhere secure if you need to reconnect the encrypted disk on another Mac."
        ) {
            SheetFormSection(
                title: destination.name,
                subtitle: "Anyone with this key and access to the remote destination can unlock its Time Machine disk.",
                symbol: "key.viewfinder"
            ) {
                FieldRow(title: "Recovery key") {
                    Group {
                        if let recoveryKey {
                            Text(recoveryKey)
                                .textSelection(.enabled)
                                .font(.system(.body, design: .monospaced))
                        } else if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Hidden")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: ModalMetrics.primaryControlWidth, alignment: .leading)
                    .accessibilityLabel("Time Machine recovery key")
                    .accessibilityValue(recoveryKey == nil ? "Hidden" : "Revealed")
                }
                if let errorMessage {
                    FieldRow(title: "") {
                        InlineWarning(
                            symbol: "exclamationmark.triangle",
                            title: "Recovery key unavailable",
                            message: errorMessage
                        )
                    }
                }
                FieldRow(title: "") {
                    Text("When copied, Delta clears the clipboard after one minute unless you copy something else first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: ModalMetrics.primaryControlWidth, alignment: .leading)
                }
            }

            SheetActions {
                Button("Done") { dismiss() }
                if let recoveryKey {
                    Button(copied ? "Copied" : "Copy Recovery Key") {
                        copy(recoveryKey)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Reveal Recovery Key") {
                        reveal()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading)
                }
            }
        }
        .frame(width: ModalMetrics.sheetWidth, height: ModalMetrics.compactDestinationSheetHeight)
        .onDisappear {
            clipboardCleanupTask?.cancel()
            if let clipboardChangeCount,
               NSPasteboard.general.changeCount == clipboardChangeCount {
                NSPasteboard.general.clearContents()
            }
        }
    }

    private func reveal() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                recoveryKey = try await model.timeMachineRecoveryKey(for: destination)
            } catch {
                errorMessage = SensitiveLogRedactor.redact(error.localizedDescription)
            }
            isLoading = false
        }
    }

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(value, forType: .string) else { return }
        copied = true
        let protectedChangeCount = pasteboard.changeCount
        clipboardChangeCount = protectedChangeCount
        clipboardCleanupTask?.cancel()
        clipboardCleanupTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            if NSPasteboard.general.changeCount == protectedChangeCount {
                NSPasteboard.general.clearContents()
            }
            clipboardChangeCount = nil
            copied = false
        }
    }
}

enum DestinationPasswordSheetMode: String, Identifiable {
    case reconnect
    case rotate

    var id: String { rawValue }
}

struct DestinationPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: DeltaAppModel
    let destination: BackupRepository
    let mode: DestinationPasswordSheetMode
    @State private var password = ""
    @State private var confirmation = ""
    @State private var isSubmitting = false
    @State private var operationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                SheetFormSection(title: sectionTitle, subtitle: sectionSubtitle, symbol: symbol) {
                    FieldRow(title: fieldTitle) {
                        SecureField(fieldPlaceholder, text: $password)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isSubmitting)
                    }
                    if mode == .rotate {
                        FieldRow(title: "Confirm") {
                            SecureField("Confirm new password", text: $confirmation)
                                .textFieldStyle(.roundedBorder)
                                .disabled(isSubmitting)
                        }
                        FieldRow(title: "") {
                            Text("Use at least 12 characters. Delta never puts passwords in process arguments, environment variables, logs, or temporary files.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                SettingsNotice(
                    symbol: mode == .rotate ? "checkmark.shield" : "lock.open",
                    title: noticeTitle,
                    text: noticeText,
                    color: .blue
                )

                if let operationError {
                    InlineWarning(
                        symbol: "exclamationmark.triangle.fill",
                        title: errorTitle,
                        message: operationError
                    )
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Divider()

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(isSubmitting)
                Button { submit() } label: {
                    HStack(spacing: 7) {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isSubmitting ? progressActionTitle : actionTitle)
                    }
                    .frame(minWidth: 124)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit || isSubmitting || model.isWorking)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
        .frame(width: ModalMetrics.sheetWidth, height: sheetHeight)
        .background(DeltaTheme.background)
        .interactiveDismissDisabled(isSubmitting)
        .onChange(of: password) { _, _ in operationError = nil }
        .onChange(of: confirmation) { _, _ in operationError = nil }
    }

    private var title: String {
        mode == .rotate ? "Change Encryption Password" : "Reconnect Destination"
    }

    private var subtitle: String {
        mode == .rotate
            ? "Replace the password used to unlock \(destination.name)."
            : "Restore access without changing encrypted backup data."
    }

    private var sectionTitle: String {
        mode == .rotate ? "New Password" : "Original Password"
    }

    private var sectionSubtitle: String {
        mode == .rotate
            ? "Delta adds and verifies a new key before retiring the old key."
            : "Enter the password that currently unlocks the existing backup."
    }

    private var symbol: String {
        mode == .rotate ? "key.horizontal" : "link"
    }

    private var fieldTitle: String {
        mode == .rotate ? "New Password" : "Password"
    }

    private var fieldPlaceholder: String {
        mode == .rotate ? "New encryption password" : "Original encryption password"
    }

    private var noticeTitle: String {
        mode == .rotate ? "Transactional key rotation" : "Validation before saving"
    }

    private var noticeText: String {
        mode == .rotate
            ? "The current key remains valid until the new key works and Keychain has been updated. A failure cannot silently lock you out."
            : "Delta tests this password against the destination first. An incorrect value never replaces the saved password."
    }

    private var actionTitle: String {
        mode == .rotate ? "Change Password" : "Reconnect"
    }

    private var progressActionTitle: String {
        mode == .rotate ? "Changing..." : "Checking..."
    }

    private var errorTitle: String {
        mode == .rotate ? "Password could not be changed" : "Destination could not be reconnected"
    }

    private var sheetHeight: CGFloat {
        switch (mode, operationError == nil) {
        case (.reconnect, true): 390
        case (.reconnect, false): 480
        case (.rotate, true): 490
        case (.rotate, false): 580
        }
    }

    private var canSubmit: Bool {
        switch mode {
        case .reconnect:
            return !password.isEmpty
        case .rotate:
            return password.count >= 12 && password == confirmation
        }
    }

    private func submit() {
        guard canSubmit, !isSubmitting else { return }
        operationError = nil
        isSubmitting = true
        Task {
            do {
                let warning: String?
                switch mode {
                case .reconnect:
                    warning = try await model.reconnectRepositoryPassword(destination, originalPassword: password)
                case .rotate:
                    warning = try await model.rotateRepositoryPassword(destination, newPassword: password)
                }
                password = ""
                confirmation = ""
                isSubmitting = false
                dismiss()
                if let warning {
                    model.alertMessage = warning
                }
            } catch {
                isSubmitting = false
                operationError = error.localizedDescription
            }
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
            SheetFormSection(
                title: "Backup Content",
                subtitle: "Choose what Delta protects and where encrypted backup data is stored.",
                symbol: "folder"
            ) {
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
                    .frame(width: 260, alignment: .leading)
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
                            }
                            if mode == .customFolders {
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
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .frame(maxWidth: ModalMetrics.primaryControlWidth, alignment: .leading)
                    }
                }

                FieldRow(title: "Destination") {
                    Picker("Destination", selection: $repositoryID) {
                        Text("Choose").tag(UUID?.none)
                        ForEach(model.repositories.filter { $0.format == .delta }) { repository in
                            Text(repository.name).tag(Optional(repository.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 300, alignment: .leading)
                }

                FieldRow(title: "Extra excludes") {
                    ExclusionPatternEditor(text: $customExcludePatternsText)
                        .frame(width: ModalMetrics.primaryControlWidth)
                }
            }

            SheetFormSection(
                title: "Automatic Schedule",
                subtitle: "Set when this profile runs and which power or network limits apply.",
                symbol: "calendar"
            ) {
                FieldRow(title: "Frequency") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Schedule", selection: $scheduleKind) {
                            ForEach(ScheduleEditorKind.allCases) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: ModalMetrics.primaryControlWidth, alignment: .leading)

                        scheduleControls
                    }
                }

                FieldRow(title: "Run policy") {
                    LazyVGrid(columns: modalOptionColumns, alignment: .leading, spacing: 10) {
                        Toggle("Enabled", isOn: $scheduleEnabled)
                            .toggleStyle(.checkbox)
                        Toggle("Catch up missed runs", isOn: $catchUpMissedRuns)
                            .toggleStyle(.checkbox)
                        Toggle("Run on battery", isOn: $runOnBattery)
                            .toggleStyle(.checkbox)
                        Toggle("Run in Low Power Mode", isOn: $runInLowPowerMode)
                            .toggleStyle(.checkbox)
                    }
                    .frame(width: ModalMetrics.primaryControlWidth, alignment: .leading)
                }

                FieldRow(title: "Speed limits") {
                    HStack(spacing: 10) {
                        TextField("Upload KiB/s", text: $uploadLimit)
                            .textFieldStyle(.roundedBorder)
                        TextField("Download KiB/s", text: $downloadLimit)
                            .textFieldStyle(.roundedBorder)
                    }
                    .frame(width: ModalMetrics.primaryControlWidth)
                }
            }

            SheetFormSection(
                title: "Retention & Cleanup",
                subtitle: "Keep useful history while reclaiming destination space on a predictable schedule.",
                symbol: "clock.arrow.circlepath"
            ) {
                FieldRow(title: "Restore points") {
                    LazyVGrid(columns: modalRetentionColumns, alignment: .leading, spacing: 10) {
                        Stepper("Hourly \(keepHourly)", value: $keepHourly, in: 0...168)
                        Stepper("Daily \(keepDaily)", value: $keepDaily, in: 0...365)
                        Stepper("Weekly \(keepWeekly)", value: $keepWeekly, in: 0...260)
                        Stepper("Monthly \(keepMonthly)", value: $keepMonthly, in: 0...120)
                        Stepper("Yearly \(keepYearly)", value: $keepYearly, in: 0...50)
                    }
                    .frame(width: ModalMetrics.primaryControlWidth, alignment: .leading)
                }

                FieldRow(title: "Cleanup") {
                    VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: modalOptionColumns, alignment: .leading, spacing: 10) {
                            Toggle("Free space after cleanup", isOn: $pruneAfterForget)
                                .toggleStyle(.checkbox)
                            Toggle("Verify after cleanup", isOn: $checkAfterPrune)
                                .toggleStyle(.checkbox)
                            Toggle("Automatic cleanup", isOn: $maintenanceEnabled)
                                .toggleStyle(.checkbox)
                        }
                        Divider()
                        HStack(spacing: 16) {
                            Stepper("Every \(maintenanceIntervalDays) days", value: $maintenanceIntervalDays, in: 1...90)
                            TimeControls(hour: $maintenanceHour, minute: $maintenanceMinute)
                        }
                        .disabled(!maintenanceEnabled)
                    }
                    .frame(width: ModalMetrics.primaryControlWidth, alignment: .leading)
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
            repositoryID = repositoryID ?? model.repositories.first(where: { $0.format == .delta })?.id
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
            Stepper(
                ScheduleIntervalPresentation.title(minutes: intervalMinutes),
                value: $intervalMinutes,
                in: 1...10_080,
                step: 15
            )
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

struct DestinationEditorView: View {
    private enum TimeMachineCreationMode: String, CaseIterable, Identifiable {
        case newDisk
        case reconnect

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .newDisk: "New Disk"
            case .reconnect: "Existing Disk"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: DeltaAppModel
    private let existingDestination: BackupRepository?
    @State private var name = "Primary Destination"
    @State private var format: BackupFormat = .delta
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
    @State private var timeMachineVolumeName = "Delta Time Machine"
    @State private var timeMachineCapacityGiB = "1024"
    @State private var timeMachineCacheMiB = "1024"
    @State private var timeMachineCreationMode: TimeMachineCreationMode = .newDisk
    @State private var timeMachineRecoveryPassword = ""
    @State private var isSubmitting = false
    @State private var submissionError: String?

    init(destination: BackupRepository? = nil) {
        existingDestination = destination
        let backendState = Self.editorState(for: destination?.backend ?? .local(path: ""))
        _name = State(initialValue: destination?.name ?? "Primary Destination")
        _format = State(initialValue: destination?.format ?? .delta)
        _kind = State(initialValue: backendState.kind)
        _primary = State(initialValue: backendState.primary)
        _secondary = State(initialValue: backendState.secondary)
        _tertiary = State(initialValue: backendState.tertiary)
        _quaternary = State(initialValue: backendState.quaternary)
        _sftpIdentityFilePath = State(initialValue: backendState.sftpIdentityFilePath)
        _storageMode = State(initialValue: destination?.secretStorageMode ?? .appManagedKeychain)
        let timeMachineSettings = destination?.timeMachineSettings
        _timeMachineVolumeName = State(initialValue: timeMachineSettings?.volumeName ?? "Delta Time Machine")
        _timeMachineCapacityGiB = State(
            initialValue: String((timeMachineSettings?.imageCapacityBytes ?? TimeMachineRepositorySettings.defaultImageCapacityBytes) / 1_073_741_824)
        )
        _timeMachineCacheMiB = State(
            initialValue: String((timeMachineSettings?.cacheLimitBytes ?? TimeMachineRepositorySettings.defaultCacheLimitBytes) / 1_048_576)
        )
        _credentialValues = State(initialValue: Dictionary(uniqueKeysWithValues: ResticBackendCredentialTemplates.fields(for: backendState.kind).map { ($0.environmentKey, "") }))
    }

    var body: some View {
        SheetScaffold(title: sheetTitle, subtitle: sheetSubtitle) {
            SheetFormSection(
                title: "Location",
                subtitle: "Choose the drive, server, or cloud location that stores encrypted backup data.",
                symbol: "externaldrive"
            ) {
                FieldRow(title: "Name") {
                    TextField("Destination name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                FieldRow(title: "Format") {
                    Picker("Format", selection: $format) {
                        ForEach(BackupFormat.allCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: ModalMetrics.primaryControlWidth, alignment: .leading)
                    .disabled(existingDestination != nil)
                }

                FieldRow(title: "") {
                    Text(format.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: ModalMetrics.primaryControlWidth, alignment: .leading)
                }

                if format == .timeMachine, existingDestination == nil {
                    FieldRow(title: "Set up") {
                        Picker("Set up", selection: $timeMachineCreationMode) {
                            ForEach(TimeMachineCreationMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: ModalMetrics.primaryControlWidth, alignment: .leading)
                    }
                }

                FieldRow(title: "Type") {
                    Picker("Type", selection: $kind) {
                        ForEach(availableBackendKinds, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(width: ModalMetrics.primaryControlWidth, alignment: .leading)
                }

                backendFields
                credentialFields
            }

            if format == .timeMachine {
                SheetFormSection(
                    title: "Time Machine Disk",
                    subtitle: isReconnectingTimeMachine
                        ? "Reconnect an existing Delta-managed Time Machine disk without replacing or reinitializing its remote data."
                        : "Delta presents this remote storage to macOS as a native encrypted Time Machine disk. Only a bounded working cache stays on this Mac.",
                    symbol: "clock.arrow.circlepath"
                ) {
                    if !isReconnectingTimeMachine {
                        FieldRow(title: "Disk name") {
                            TextField("Delta Time Machine", text: $timeMachineVolumeName)
                                .textFieldStyle(.roundedBorder)
                                .disabled(existingDestination != nil)
                        }
                        FieldRow(title: "Capacity") {
                            HStack(spacing: 8) {
                                TextField("1024", text: $timeMachineCapacityGiB)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 110)
                                    .disabled(existingDestination != nil)
                                Text("GiB logical capacity")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if existingDestination != nil {
                            FieldRow(title: "") {
                                Text("Disk name and logical capacity are fixed after creation.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: ModalMetrics.primaryControlWidth, alignment: .leading)
                            }
                        }
                    }
                    FieldRow(title: "Local cache") {
                        HStack(spacing: 8) {
                            TextField("1024", text: $timeMachineCacheMiB)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 110)
                            Text("MiB maximum")
                                .foregroundStyle(.secondary)
                        }
                    }
                    FieldRow(title: "") {
                        Text("A performance window, not a backup-size limit. Delta streams verified bands as needed; backups of any supported size use this bounded cache plus at most one 64 MiB transfer-verification batch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: ModalMetrics.primaryControlWidth, alignment: .leading)
                    }
                    FieldRow(title: "") {
                        SettingsNotice(
                            symbol: isReconnectingTimeMachine ? "arrow.triangle.2.circlepath" : "externaldrive.badge.icloud",
                            title: isReconnectingTimeMachine ? "Authenticated recovery" : "Remote-first storage",
                            text: isReconnectingTimeMachine
                                ? "Delta reads the remote recovery record, authenticates it with the disk password, and verifies the latest signed generation before saving any local configuration. The disk name and capacity come from that authenticated record."
                                : "Delta never stages the complete sparsebundle locally. Writes enter the bounded cache; a Time Machine sync succeeds only after the authenticated remote generation is durable.",
                            color: .blue
                        )
                    }
                }
            }

            SheetFormSection(
                title: "Encryption",
                subtitle: encryptionSubtitle,
                symbol: "lock.shield"
            ) {
                if isReconnectingTimeMachine {
                    FieldRow(title: "Recovery key") {
                        SecureField("Original password or recovery key", text: $timeMachineRecoveryPassword)
                            .textFieldStyle(.roundedBorder)
                    }
                    FieldRow(title: "") {
                        Text("Leave this blank to use an app-managed recovery key already saved on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: ModalMetrics.primaryControlWidth, alignment: .leading)
                    }
                } else if existingDestination == nil {
                    FieldRow(title: "Password") {
                        Picker("Password", selection: $storageMode) {
                            ForEach(SecretStorageMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: ModalMetrics.primaryControlWidth, alignment: .leading)
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
                } else if let existingDestination {
                    FieldRow(title: "Password") {
                        Text(existingDestination.secretStorageMode.displayName)
                            .foregroundStyle(.secondary)
                    }
                    FieldRow(title: "") {
                        Text(existingEncryptionDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            SheetActions {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle) {
                    if isReconnectingTimeMachine {
                        isSubmitting = true
                        Task {
                            let success = await model.reconnectTimeMachineRepository(
                                name: name,
                                backend: backend,
                                cacheLimitBytes: parsedTimeMachineCacheBytes ?? 0,
                                recoveryPassword: timeMachineRecoveryPassword,
                                backendCredentials: sanitizedCredentialValues
                            )
                            isSubmitting = false
                            if success {
                                dismiss()
                            } else {
                                captureSubmissionError()
                            }
                        }
                    } else {
                        if saveDestination() {
                            dismiss()
                        } else {
                            captureSubmissionError()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !canCreate
                        || !model.isPersistentStoreAvailable
                        || isSubmitting
                        || model.isWorking
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: ModalMetrics.sheetWidth, height: preferredSheetHeight)
        .animation(.easeInOut(duration: 0.18), value: preferredSheetHeight)
        .onChange(of: kind) { _, newKind in
            let fields = ResticBackendCredentialTemplates.fields(for: newKind)
            credentialValues = Dictionary(uniqueKeysWithValues: fields.map { ($0.environmentKey, credentialValues[$0.environmentKey] ?? "") })
        }
        .onChange(of: format) { _, newFormat in
            if newFormat == .timeMachine, !kind.supportsTimeMachineObjectStorage {
                kind = .local
            }
            if newFormat != .timeMachine {
                timeMachineCreationMode = .newDisk
            }
        }
        .alert(submissionErrorTitle, isPresented: submissionErrorBinding) {
            Button("OK") {
                submissionError = nil
            }
        } message: {
            Text(submissionError ?? "The destination could not be saved.")
        }
    }

    private var sheetTitle: String {
        existingDestination == nil ? "New Destination" : "Edit Destination"
    }

    private var sheetSubtitle: String {
        if format == .timeMachine {
            return existingDestination == nil
                ? "Choose where the encrypted Time Machine disk is stored."
                : "Update this Time Machine disk's remote connection and bounded local cache."
        }
        return existingDestination == nil
            ? "Choose where encrypted restore points are stored."
            : "Update where encrypted restore points are stored."
    }

    private var encryptionSubtitle: String {
        if isReconnectingTimeMachine {
            return "Use the original disk password or an exported recovery key."
        }
        if format == .timeMachine, existingDestination != nil {
            return "This encrypted disk keeps its original password and recovery method."
        }
        if format == .timeMachine {
            return "Choose who manages the password for the encrypted Time Machine disk."
        }
        return "Every Delta destination is encrypted. Choose who manages the password needed for restore."
    }

    private var existingEncryptionDetail: String {
        if format == .timeMachine {
            return "The disk password cannot be changed from this editor. To reconnect its remote data, create a destination using Time Machine › Existing Disk and the original password or recovery key."
        }
        return "Use the destination actions menu to reconnect or change the encryption password."
    }

    private var preferredSheetHeight: CGFloat {
        let fieldHeight: CGFloat = 36
        let backendRows: Int
        switch kind {
        case .local, .rest, .custom:
            backendRows = 1
        case .backblazeB2, .azureBlob, .googleCloudStorage, .swiftObjectStorage, .rclone:
            backendRows = 2
        case .s3:
            backendRows = 4
        case .sftp:
            backendRows = 7
        }

        let credentialRows = ResticBackendCredentialTemplates.fields(for: kind).count
        let passphraseRows = existingDestination == nil && storageMode == .userManagedPassphrase ? 2 : 0
        let timeMachineRows = format == .timeMachine
            ? (isReconnectingTimeMachine ? 5 : 6)
            : 0
        let contentHeight = ModalMetrics.compactDestinationSheetHeight
            + CGFloat(max(backendRows - 1, 0) + credentialRows + passphraseRows + timeMachineRows) * fieldHeight
        return min(contentHeight, ModalMetrics.sheetHeight)
    }

    @ViewBuilder
    private var backendFields: some View {
        switch kind {
        case .local:
            FieldRow(title: "Folder") {
                HStack {
                    TextField("Destination folder", text: $primary)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 460)
                    Button {
                        if let path = model.chooseFolder().first {
                            primary = path
                        }
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Choose destination folder")
                    .deltaTooltip("Choose the folder that will store this destination.")
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
                    .accessibilityLabel("Choose SSH private key")
                    .deltaTooltip("Choose an SSH private key file for non-interactive SFTP backups.")
                }
            }
            FieldRow(title: "") {
                SettingsNotice(
                    symbol: "key.horizontal",
                    title: "Scheduled SFTP requires non-interactive SSH",
                    text: "Delta runs SFTP with SSH batch mode so scheduled backups fail clearly instead of waiting for a password prompt. Use a key file, ssh-agent, or your SSH config.",
                    color: .blue
                )
            }
        case .rest:
            FieldRow(title: "URL") { TextField("https://backup.example.com/delta", text: $primary).textFieldStyle(.roundedBorder) }
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

    private var availableBackendKinds: [RepositoryBackendKind] {
        RepositoryBackendKind.allCases.filter {
            format == .delta || $0.supportsTimeMachineObjectStorage
        }
    }

    private var timeMachineSettings: TimeMachineRepositorySettings? {
        guard format == .timeMachine, !isReconnectingTimeMachine else { return nil }
        let gib: Int64 = 1_073_741_824
        let mib: Int64 = 1_048_576
        guard
            let capacity = Int64(timeMachineCapacityGiB),
            let cache = Int64(timeMachineCacheMiB),
            capacity > 0,
            cache > 0,
            capacity <= Int64.max / gib,
            cache <= Int64.max / mib
        else {
            return nil
        }
        let existing = existingDestination?.timeMachineSettings
        return TimeMachineRepositorySettings(
            storeID: existing?.storeID ?? UUID(),
            volumeName: timeMachineVolumeName,
            imageCapacityBytes: capacity * gib,
            cacheLimitBytes: cache * mib,
            manifestKeychainAccount: existing?.manifestKeychainAccount
        )
    }

    private var canCreate: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if format == .timeMachine {
            guard kind.supportsTimeMachineObjectStorage else { return false }
            if isReconnectingTimeMachine {
                guard parsedTimeMachineCacheBytes != nil else { return false }
            } else {
                guard timeMachineSettings != nil else { return false }
            }
        }
        if kind == .sftp && secondary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if kind == .s3 && tertiary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if kind == .sftp && !quaternary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsedPort, (1...65_535).contains(parsedPort) else { return false }
        }
        if existingDestination == nil && storageMode == .userManagedPassphrase {
            guard !passphrase.isEmpty, passphrase == passphraseConfirmation else { return false }
        }
        return true
    }

    private var parsedPort: Int? {
        let value = quaternary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return Int(value)
    }

    private var isReconnectingTimeMachine: Bool {
        existingDestination == nil
            && format == .timeMachine
            && timeMachineCreationMode == .reconnect
    }

    private var parsedTimeMachineCacheBytes: Int64? {
        let mib: Int64 = 1_048_576
        guard
            let cache = Int64(timeMachineCacheMiB),
            cache > 0,
            cache <= Int64.max / mib
        else {
            return nil
        }
        return cache * mib
    }

    private var actionTitle: String {
        if isSubmitting { return "Reconnecting…" }
        if isReconnectingTimeMachine { return "Reconnect" }
        return existingDestination == nil ? "Create" : "Save"
    }

    private var submissionErrorTitle: String {
        if isReconnectingTimeMachine {
            return "Couldn’t Reconnect Time Machine Disk"
        }
        return existingDestination == nil
            ? "Couldn’t Create Destination"
            : "Couldn’t Save Destination"
    }

    private var submissionErrorBinding: Binding<Bool> {
        Binding(
            get: { submissionError != nil },
            set: { isPresented in
                if !isPresented {
                    submissionError = nil
                }
            }
        )
    }

    private func captureSubmissionError() {
        submissionError = model.alertMessage ?? "The destination could not be saved."
        model.alertMessage = nil
    }

    private func saveDestination() -> Bool {
        if let existingDestination {
            return model.saveRepository(
                existingDestination,
                name: name,
                backend: backend,
                timeMachineSettings: timeMachineSettings,
                backendCredentials: sanitizedCredentialValues
            )
        } else {
            return model.createRepository(
                name: name,
                backend: backend,
                format: format,
                timeMachineSettings: timeMachineSettings,
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

    private static func editorState(for backend: RepositoryBackend) -> DestinationEditorState {
        switch backend {
        case let .local(path):
            DestinationEditorState(kind: .local, primary: path)
        case let .sftp(host, path, username, port, identityFilePath):
            DestinationEditorState(
                kind: .sftp,
                primary: host,
                secondary: path,
                tertiary: username ?? "",
                quaternary: port.map(String.init) ?? "",
                sftpIdentityFilePath: identityFilePath ?? ""
            )
        case let .rest(url):
            DestinationEditorState(kind: .rest, primary: url)
        case let .s3(endpoint, bucket, path, region):
            DestinationEditorState(kind: .s3, primary: bucket, secondary: path ?? "", tertiary: endpoint ?? "", quaternary: region ?? "")
        case let .backblazeB2(bucket, path):
            DestinationEditorState(kind: .backblazeB2, primary: bucket, secondary: path ?? "")
        case let .azureBlob(container, path):
            DestinationEditorState(kind: .azureBlob, primary: container, secondary: path ?? "")
        case let .googleCloudStorage(bucket, path):
            DestinationEditorState(kind: .googleCloudStorage, primary: bucket, secondary: path ?? "")
        case let .swiftObjectStorage(container, path):
            DestinationEditorState(kind: .swiftObjectStorage, primary: container, secondary: path ?? "")
        case let .rclone(remote, path):
            DestinationEditorState(kind: .rclone, primary: remote, secondary: path)
        case let .custom(repository):
            DestinationEditorState(kind: .custom, primary: repository)
        }
    }

    private struct DestinationEditorState {
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
            LazyVStack(alignment: .leading, spacing: 18) {
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

struct SheetFormSection<Content: View>: View {
    var title: String
    var subtitle: String
    var symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(DeltaTheme.badge)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeltaTheme.badge.opacity(0.35))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(DeltaTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

enum ModalMetrics {
    static let sheetWidth: CGFloat = 760
    static let sheetHeight: CGFloat = 720
    static let compactDestinationSheetHeight: CGFloat = 500
    static let labelWidth: CGFloat = 154
    static let contentWidth: CGFloat = 520
    static let primaryControlWidth: CGFloat = 500
}

private let modalOptionColumns = [
    GridItem(.flexible(minimum: 190), spacing: 16, alignment: .leading),
    GridItem(.flexible(minimum: 190), spacing: 16, alignment: .leading)
]

private let modalRetentionColumns = [
    GridItem(.adaptive(minimum: 145), spacing: 12, alignment: .leading)
]

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
    var title: String
    @ViewBuilder var content: Content

    init(
        title: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsCapability: Identifiable {
    var id: String { title }
    var symbol: String
    var title: String
    var detail: String
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

private let settingsControlRowControlWidth: CGFloat = 340
private let settingsCounterColumns = [
    GridItem(.flexible(), spacing: 12, alignment: .leading),
    GridItem(.flexible(), spacing: 12, alignment: .leading),
    GridItem(.flexible(), spacing: 12, alignment: .leading)
]

struct SettingsControlRow<Control: View>: View {
    var title: String
    var detail: String
    @ViewBuilder var control: Control

    var body: some View {
        SettingsValueRow(
            title: title,
            detail: detail,
            systemImage: SettingsControlSymbol.symbol(for: title)
        ) {
            control
        }
    }
}

private struct SettingsRowDescription: View {
    var title: String
    var detail: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsValueRow<Control: View>: View {
    var title: String
    var detail: String
    var systemImage: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 14) {
            SettingsRowDescription(title: title, detail: detail, systemImage: systemImage)
            control
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

private struct SettingsActionRow<Control: View>: View {
    var title: String
    var detail: String
    var systemImage: String
    @ViewBuilder var control: Control

    var body: some View {
        SettingsValueRow(title: title, detail: detail, systemImage: systemImage) {
            control
        }
    }
}

private struct SettingsStatusLabel: View {
    var isReady: Bool

    var body: some View {
        Label(isReady ? "Ready" : "Missing", systemImage: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(isReady ? .green : .orange)
            .fixedSize()
    }
}

private enum SettingsControlSymbol {
    static func symbol(for title: String) -> String {
        switch title {
        case "Allow scheduled backups": "clock.badge.checkmark"
        case "Pause automatic runs": "pause.circle"
        case "Keep Mac awake during backup work": "powerplug"
        case "Status menu": "menubar.rectangle"
        case "Start Delta at login": "power"
        case "Job alerts": "exclamationmark.bubble"
        case "Success summaries": "checkmark.bubble"
        case "Backup freshness": "clock.badge.exclamationmark"
        case "Destination checks": "externaldrive.badge.checkmark"
        case "Destination free space": "internaldrive"
        case "Schedule new profiles": "calendar.badge.plus"
        case "Default schedule": "calendar"
        case "Catch up missed runs": "arrow.clockwise"
        case "Run on battery": "battery.100percent"
        case "Run in Low Power Mode": "leaf"
        case "Free space after cleanup": "externaldrive.badge.minus"
        case "Verify after cleanup": "checkmark.shield"
        case "Default speed limits": "speedometer"
        case "Default retention": "archivebox"
        case "Automatic cleanup": "trash.slash"
        case "Cleanup cadence": "calendar.badge.clock"
        case "Preview first": "eye"
        case "Verify files": "checkmark.shield"
        case "Existing files": "doc.on.doc"
        case "Automatic checks", "Automatically check for updates": "arrow.triangle.2.circlepath"
        case "Check interval", "Check frequency": "calendar.badge.clock"
        case "Download in background", "Download updates automatically": "arrow.down.circle"
        case "History retention": "clock.arrow.circlepath"
        default: "slider.horizontal.3"
        }
    }
}

enum SettingsPermissionPresentation: Equatable {
    case ready
    case notRequested
    case notAllowed
    case needsAttention
    case notNeeded
    case checkAgain
    case quiet
    case temporary

    var title: String {
        switch self {
        case .ready: "Allowed"
        case .notRequested: "Not Requested"
        case .notAllowed: "Not Allowed"
        case .needsAttention: "Needs Attention"
        case .notNeeded: "Not Needed"
        case .checkAgain: "Check Again"
        case .quiet: "Quietly Allowed"
        case .temporary: "Temporarily Allowed"
        }
    }

    var systemImage: String {
        switch self {
        case .ready, .quiet, .temporary: "checkmark.circle.fill"
        case .notNeeded: "minus.circle.fill"
        case .notRequested, .checkAgain: "questionmark.circle.fill"
        case .notAllowed, .needsAttention: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ready: .green
        case .quiet, .temporary: .blue
        case .notNeeded, .notRequested, .checkAgain: .secondary
        case .notAllowed, .needsAttention: .orange
        }
    }
}

struct SettingsPermissionRow<Actions: View>: View {
    var title: String
    var detail: String
    var systemImage: String
    var status: SettingsPermissionPresentation
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 12) {
                SettingsRowDescription(title: title, detail: detail, systemImage: systemImage)
                statusLabel
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(status.title)")
            .accessibilityHint(detail)
            actionGroup
        }
    }

    private var statusLabel: some View {
        Label(status.title, systemImage: status.systemImage)
            .font(.callout.weight(.medium))
            .foregroundStyle(status.color)
            .fixedSize()
    }

    private var actionGroup: some View {
        HStack(spacing: 8) {
            actions
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct SettingsPermissionNote: View {
    var title: String
    var detail: String
    var systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 42)
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

struct SettingsDisclosure<Content: View>: View {
    var title: String
    var symbol: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(DeltaTheme.badge.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 12)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.16), value: isExpanded)
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DeltaTheme.badge.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    content
                }
                .padding(.leading, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .frame(width: ModalMetrics.labelWidth, alignment: .leading)
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
    var actionTitle: String?
    var action: (() -> Void)?

    init(
        symbol: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        Card {
            VStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 58, height: 58)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 220)
        }
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
    var outcome: JobOutcomePresentation

    init(status: JobStatus) {
        outcome = JobOutcomePresentation(status: status)
    }

    init(outcome: JobOutcomePresentation) {
        self.outcome = outcome
    }

    var body: some View {
        Text(outcome.displayName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch outcome.visualStatus {
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

struct BackupRunSummaryLine: View {
    var job: JobRun
    var outcome: JobOutcomePresentation?

    init(job: JobRun, outcome: JobOutcomePresentation? = nil) {
        self.job = job
        self.outcome = outcome
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let summary {
                BackupSummaryMetricRow(summary: summary)
            } else if let summaryText {
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let detailText = effectiveOutcome.detailText {
                Label(detailText, systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var effectiveOutcome: JobOutcomePresentation {
        outcome ?? JobOutcomePresentation(status: job.status)
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
