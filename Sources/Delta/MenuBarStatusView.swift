import AppKit
import DeltaCore
import SwiftUI

struct DeltaMenuBarView: View {
    @EnvironmentObject private var model: DeltaAppModel
    @EnvironmentObject private var softwareUpdateController: SoftwareUpdateController
    @AppStorage(
        DeltaAppPreferenceKeys.pausesScheduledBackups,
        store: DeltaAppPreferences.sharedStore()
    ) private var pausesScheduledBackups = false
    @State private var menuContentHeight: CGFloat = 240
    var openApp: (DeltaAppModel.Section) -> Void

    init(openApp: @escaping (DeltaAppModel.Section) -> Void) {
        self.openApp = openApp
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                menuContent
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: DeltaMenuContentHeightPreferenceKey.self,
                                value: geometry.size.height
                            )
                        }
                    }
            }
            .scrollIndicators(menuContentHeight > 520 ? .visible : .hidden)
            .frame(height: min(menuContentHeight, 520))
            .onPreferenceChange(DeltaMenuContentHeightPreferenceKey.self) { height in
                guard height > 0, abs(menuContentHeight - height) > 0.5 else { return }
                menuContentHeight = height
            }

            Divider()
            footer
        }
        .frame(width: 370)
        .background(.regularMaterial)
    }

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let operation = model.activeOperation {
                activeOperationCard(operation)
            } else if !model.profiles.isEmpty {
                lastBackupSection
            }
            if !model.profiles.isEmpty {
                backupActions
            }
            if !timeMachineRepositories.isEmpty {
                timeMachineActions
            }
            if model.profiles.isEmpty, timeMachineRepositories.isEmpty {
                noBackupsConfigured
            }
        }
        .padding(14)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(statusColor.gradient)
                Image(systemName: statusSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Delta")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()

            Button {
                openApp(section: .dashboard)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Open Delta")
            .deltaTooltip("Open Delta")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func activeOperationCard(_ operation: ActiveOperation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(statusBadgeText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .textCase(.uppercase)
                Spacer()
                Text(operation.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(operation.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(operation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            MenuBarProgressView(
                progress: model.activeProgress,
                progressFraction: model.activeDisplayedProgressFraction,
                latestMessage: model.liveLogLines.last?.message,
                stopRequest: model.activeStopRequest
            )

            HStack(spacing: 8) {
                if operation.kind == .backup {
                    Button {
                        model.pauseActiveBackup()
                    } label: {
                        Image(systemName: "pause.fill")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!actionAvailability.canPauseActiveBackup)
                    .accessibilityLabel("Pause Backup")
                    .deltaTooltip("Pause Backup")
                }

                Button(role: .destructive) {
                    model.cancelActiveJob()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!actionAvailability.canStopActiveJob)

                Button {
                    openApp(section: .activity)
                } label: {
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Open Activity")
                .deltaTooltip("Open Activity")
            }
            .controlSize(.small)
        }
        .padding(13)
        .background(statusColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(statusColor.opacity(0.22), lineWidth: 1)
        }
    }

    private var lastBackupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Last Backup")

            if let lastBackupRun {
                Button {
                    openApp(section: .activity)
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 9) {
                            Image(systemName: lastBackupOutcomeSymbol)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(lastBackupOutcomeColor)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(lastBackupRun.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.subheadline.weight(.medium))
                                Text(lastBackupOutcome.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 0)

                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }

                        if let summary = lastBackupSummaryText {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if restorePointCount > 0 {
                            Text("\(restorePointCount) restore \(restorePointCount == 1 ? "point" : "points") available")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(10)
                }
                .buttonStyle(.plain)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHint("Open this run in Activity")
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "clock.badge.questionmark")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text("No backup has run yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var backupActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Backup")

            HStack(spacing: 8) {
                if model.profiles.count <= 1 {
                    Button {
                        if let profile = model.profiles.first {
                            model.runNow(profile: profile)
                        }
                    } label: {
                        Label("Back Up Now", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!actionAvailability.canBackUpNow)
                } else {
                    Menu {
                        ForEach(model.profiles) { profile in
                            Button(profile.name) {
                                model.runNow(profile: profile)
                            }
                        }
                    } label: {
                        Label("Back Up Now", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!actionAvailability.canBackUpNow)
                }

                Button {
                    model.runDueBackups()
                } label: {
                    Label(actionAvailability.runDueTitle, systemImage: actionAvailability.runDueSymbolName)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!actionAvailability.canRunDueBackups)
                .deltaTooltip(actionAvailability.runDueTooltip)
            }
        }
        .controlSize(.regular)
    }

    private var timeMachineActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Time Machine")

            Button {
                openApp(section: .destinations)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(timeMachineStatusColor)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(timeMachineStatusTitle)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(timeMachineStatusDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .padding(10)
            }
            .buttonStyle(.plain)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityHint("Open Time Machine destinations in Delta")

            HStack(spacing: 8) {
                if timeMachineBackupCandidates.count <= 1 {
                    Button {
                        if let repository = timeMachineBackupCandidates.first {
                            model.startTimeMachineBackup(repository)
                        }
                    } label: {
                        Label("Back Up Now", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStartTimeMachineBackup)
                    .accessibilityLabel(timeMachineBackupAccessibilityLabel)
                    .deltaTooltip(timeMachineBackupTooltip)
                } else {
                    Menu {
                        ForEach(timeMachineBackupCandidates) { repository in
                            Button(repository.name) {
                                model.startTimeMachineBackup(repository)
                            }
                        }
                    } label: {
                        Label("Back Up Now", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStartTimeMachineBackup)
                    .deltaTooltip("Choose a connected Time Machine disk and start a backup with macOS.")
                }

                Button {
                    model.openTimeMachine()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .disabled(!timeMachineHasMountedDisk)
                .accessibilityLabel("Open Time Machine")
                .deltaTooltip("Browse and restore from a connected Time Machine disk.")
            }
            .controlSize(.regular)
        }
    }

    private var noBackupsConfigured: some View {
        Button {
            openApp(section: .destinations)
        } label: {
            Label("Add a backup destination", systemImage: "externaldrive.badge.plus")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            footerButton("Open Delta", systemImage: "macwindow") {
                openApp(section: .dashboard)
            }
            footerButton("Open Activity", systemImage: "waveform.path.ecg") {
                openApp(section: .activity)
            }
            footerButton("Refresh", systemImage: "arrow.clockwise") {
                model.reload()
            }
            footerButton("Check for Updates", systemImage: "arrow.triangle.2.circlepath") {
                softwareUpdateController.checkForUpdates()
            }

            Spacer(minLength: 2)

            footerButton("Quit Delta", systemImage: "power", role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func footerButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .deltaTooltip(title)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private var lastBackupRun: JobRun? {
        model.jobs
            .filter { $0.kind == .backup }
            .max { $0.startedAt < $1.startedAt }
    }

    private var restorePointCount: Int {
        model.snapshots.count
    }

    private var timeMachineRepositories: [BackupRepository] {
        model.repositories.filter { $0.format == .timeMachine }
    }

    private var timeMachineBackupCandidates: [BackupRepository] {
        timeMachineRepositories.filter {
            TimeMachineDestinationPresentation.make(
                state: model.timeMachineStatesByRepository[$0.id]
            ).primaryAction == .backUpNow
        }
    }

    private var timeMachineHasMountedDisk: Bool {
        timeMachineRepositories.contains {
            TimeMachineDestinationPresentation.make(
                state: model.timeMachineStatesByRepository[$0.id]
            ).isMounted
        }
    }

    private var timeMachineNeedsAttention: Bool {
        timeMachineRepositories.contains { repository in
            guard let state = model.timeMachineStatesByRepository[repository.id] else {
                return true
            }
            if state.lifecycle == .preparing || state.lifecycle == .disconnecting {
                return false
            }
            return TimeMachineDestinationPresentation.make(state: state).primaryAction != .backUpNow
        }
    }

    private var timeMachineStatusTitle: String {
        if timeMachineRepositories.count == 1,
           let repository = timeMachineRepositories.first {
            return repository.name
        }
        return "\(timeMachineRepositories.count) Time Machine disks"
    }

    private var timeMachineStatusDetail: String {
        if timeMachineRepositories.count == 1,
           let repository = timeMachineRepositories.first {
            return TimeMachineDestinationPresentation.make(
                state: model.timeMachineStatesByRepository[repository.id]
            ).status
        }
        let mountedCount = timeMachineRepositories.filter {
            TimeMachineDestinationPresentation.make(
                state: model.timeMachineStatesByRepository[$0.id]
            ).isMounted
        }.count
        return "\(mountedCount) connected"
    }

    private var timeMachineStatusColor: Color {
        if timeMachineNeedsAttention { return .orange }
        if !timeMachineBackupCandidates.isEmpty { return .teal }
        return .secondary
    }

    private var canStartTimeMachineBackup: Bool {
        model.isPersistentStoreAvailable
            && !model.isWorking
            && !timeMachineBackupCandidates.isEmpty
    }

    private var timeMachineBackupAccessibilityLabel: String {
        guard let repository = timeMachineBackupCandidates.first else {
            return "Back Up Now with Time Machine"
        }
        return "Back Up \(repository.name) Now with Time Machine"
    }

    private var timeMachineBackupTooltip: String {
        timeMachineBackupCandidates.isEmpty
            ? "Connect a ready Time Machine disk in Destinations before starting a backup."
            : "Ask macOS Time Machine to back up to this connected disk."
    }

    private var statusSymbol: String {
        statusPresentation.symbolName
    }

    private var statusColor: Color {
        switch statusPresentation.tone {
        case .ready:
            return .green
        case .running:
            return .blue
        case .attention:
            return .orange
        case .blocked:
            return .red
        }
    }

    private var statusText: String {
        statusPresentation.headerText
    }

    private var statusBadgeText: String {
        statusPresentation.badgeText
    }

    private var lastBackupOutcome: JobOutcomePresentation {
        guard let lastBackupRun else {
            return JobOutcomePresentation(status: .queued)
        }
        return model.outcomePresentation(for: lastBackupRun)
    }

    private var lastBackupOutcomeColor: Color {
        switch lastBackupOutcome.visualStatus {
        case .succeeded: .green
        case .warning: .orange
        case .failed: .red
        case .running: .blue
        case .queued: .secondary
        case .cancelled: .gray
        }
    }

    private var lastBackupOutcomeSymbol: String {
        switch lastBackupOutcome.visualStatus {
        case .succeeded: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .queued: "clock.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    private var lastBackupSummaryText: String? {
        guard let lastBackupRun else { return nil }
        let summary = lastBackupRun.backupSummary ?? ResticLogFormatter.backupSummary(from: lastBackupRun.message)
        return summary?.conciseText
    }

    private var statusPresentation: MenuBarStatusPresentation {
        MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: model.isPersistentStoreAvailable,
            isWorking: model.isWorking,
            activeJobKind: model.activeOperation?.kind,
            latestBackupStatus: lastBackupRun?.status,
            acknowledgedOmissionCount: lastBackupRun.flatMap { model.acknowledgedWarningIssueCounts[$0.id] },
            hasDestinationAttention: timeMachineNeedsAttention
        )
    }

    private var actionAvailability: MenuBarActionAvailability {
        MenuBarActionAvailability.make(
            profileCount: model.profiles.count,
            isPersistentStoreAvailable: model.isPersistentStoreAvailable,
            isWorking: model.isWorking,
            pausesScheduledBackups: pausesScheduledBackups,
            activeJobKind: model.activeOperation?.kind,
            activeStopRequest: model.activeStopRequest
        )
    }

    private func openApp(section: DeltaAppModel.Section) {
        model.selectedSection = section
        openApp(section)
    }
}

private struct DeltaMenuContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 240

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MenuBarProgressView: View {
    var progress: ResticProgressSnapshot?
    var progressFraction: Double?
    var latestMessage: String?
    var stopRequest: ResticRunStopReason?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progressFraction {
                ProgressView(value: progressFraction, total: 1)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .accessibilityLabel("Estimated backup progress")
                    .accessibilityValue("\(Int(progressFraction * 100)) percent")
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .accessibilityLabel("Backup progress")
                    .accessibilityValue("Scanning")
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(9)
        .background(DeltaTheme.badge.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusText: String {
        if let stopRequest {
            return stopRequest == .pause ? "Pausing safely..." : "Stopping safely..."
        }
        if let displayMessage = progress?.displayMessage, !displayMessage.isEmpty {
            return displayMessage
        }
        if let latestMessage, !latestMessage.isEmpty {
            return latestMessage
        }
        return "Preparing backup..."
    }
}
