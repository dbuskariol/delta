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
    var openApp: (DeltaAppModel.Section) -> Void

    init(openApp: @escaping (DeltaAppModel.Section) -> Void) {
        self.openApp = openApp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if let operation = model.activeOperation {
                activeOperationCard(operation)
            } else {
                lastBackupCard
            }
            primaryActions
            Divider()
            utilityActions
        }
        .padding(14)
        .background(DeltaTheme.background)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(statusColor.opacity(0.16))
                    .frame(width: 34, height: 34)
                Image(systemName: statusSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Delta")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            StateBadge(text: statusBadgeText, color: statusColor)
        }
    }

    private func activeOperationCard(_ operation: ActiveOperation) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(operation.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(operation.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(operation.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .disabled(!actionAvailability.canPauseActiveBackup)
                }
                Button(role: .destructive) {
                    model.cancelActiveJob()
                } label: {
                    Label("Stop", systemImage: "xmark")
                }
                .disabled(!actionAvailability.canStopActiveJob)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(DeltaTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(DeltaTheme.border, lineWidth: 1)
        )
    }

    private var lastBackupCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("Last Backup")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let lastBackupRun {
                    StatusPill(status: lastBackupRun.status)
                }
            }
            if let lastBackupRun {
                Text(lastBackupRun.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                BackupRunSummaryLine(job: lastBackupRun)
                if restorePointCount > 0 {
                    Text("\(restorePointCount) restore \(restorePointCount == 1 ? "point" : "points") available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No backup has run yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeltaTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(DeltaTheme.border, lineWidth: 1)
        )
    }

    private var primaryActions: some View {
        VStack(spacing: 8) {
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
        .controlSize(.regular)
    }

    private var utilityActions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    openApp(section: .dashboard)
                } label: {
                    Label("Open", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    openApp(section: .activity)
                } label: {
                    Label("Activity", systemImage: "waveform.path.ecg")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                Button {
                    model.reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    softwareUpdateController.checkForUpdates()
                } label: {
                    Label("Updates", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Delta", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.small)
    }

    private var lastBackupRun: JobRun? {
        model.jobs
            .filter { $0.kind == .backup }
            .max { $0.startedAt < $1.startedAt }
    }

    private var restorePointCount: Int {
        model.snapshots.count
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

    private var statusBadgeText: String {
        statusPresentation.badgeText
    }

    private var statusText: String {
        statusPresentation.headerText
    }

    private var statusPresentation: MenuBarStatusPresentation {
        MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: model.isPersistentStoreAvailable,
            isWorking: model.isWorking,
            activeJobKind: model.activeOperation?.kind,
            latestBackupStatus: lastBackupRun?.status
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
