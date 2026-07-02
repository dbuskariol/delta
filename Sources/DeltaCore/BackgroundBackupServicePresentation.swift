import Foundation

public enum BackgroundBackupServiceSeverity: Equatable, Sendable {
    case ready
    case inactive
    case attention
    case blocked
}

public struct BackgroundBackupServicePresentation: Equatable, Sendable {
    public var statusText: String
    public var statusDetail: String
    public var controlDetail: String
    public var approvalText: String
    public var attentionTitle: String?
    public var attentionText: String?
    public var severity: BackgroundBackupServiceSeverity

    public var needsAttention: Bool {
        attentionTitle != nil && attentionText != nil
    }

    public static let purposeText = "Scheduled Backups check for due profiles after you sign in, start only work allowed by each profile's power and destination rules, then exit when there is no work. They use macOS Login Items approval, run as your user account, and do not use admin privileges."

    public static func make(
        status: LaunchAgentRegistrationStatus,
        scheduledProfileCount: Int,
        pausesScheduledBackups: Bool
    ) -> BackgroundBackupServicePresentation {
        let hasScheduledProfiles = scheduledProfileCount > 0
        let isPaused = pausesScheduledBackups && hasScheduledProfiles

        return BackgroundBackupServicePresentation(
            statusText: statusText(
                status: status,
                hasScheduledProfiles: hasScheduledProfiles,
                isPaused: isPaused
            ),
            statusDetail: statusDetail(
                status: status,
                hasScheduledProfiles: hasScheduledProfiles,
                isPaused: isPaused
            ),
            controlDetail: controlDetail(
                status: status,
                scheduledProfileCount: scheduledProfileCount,
                isPaused: isPaused
            ),
            approvalText: approvalText(status: status),
            attentionTitle: attentionTitle(
                status: status,
                hasScheduledProfiles: hasScheduledProfiles,
                isPaused: isPaused
            ),
            attentionText: attentionText(
                status: status,
                hasScheduledProfiles: hasScheduledProfiles,
                isPaused: isPaused
            ),
            severity: severity(
                status: status,
                hasScheduledProfiles: hasScheduledProfiles,
                isPaused: isPaused
            )
        )
    }

    private static func statusText(
        status: LaunchAgentRegistrationStatus,
        hasScheduledProfiles: Bool,
        isPaused: Bool
    ) -> String {
        if isPaused {
            return "Paused"
        }
        if !hasScheduledProfiles && status == .notRegistered {
            return "Not Needed"
        }
        return status.displayName
    }

    private static func statusDetail(
        status: LaunchAgentRegistrationStatus,
        hasScheduledProfiles: Bool,
        isPaused: Bool
    ) -> String {
        if isPaused {
            return "Automated runs paused"
        }
        if !hasScheduledProfiles {
            return status == .enabled ? "Ready for future schedules" : "No scheduled profiles"
        }
        return status == .enabled ? "Schedules can run when closed" : "Scheduled runs need attention"
    }

    private static func controlDetail(
        status: LaunchAgentRegistrationStatus,
        scheduledProfileCount: Int,
        isPaused: Bool
    ) -> String {
        if isPaused {
            return "Keep macOS approval in place, but skip automatic due runs until they are resumed."
        }
        if scheduledProfileCount == 0 {
            return "Optional until at least one backup profile has an hourly, daily, weekly, monthly, or custom schedule."
        }
        if status == .enabled {
            let noun = scheduledProfileCount == 1 ? "profile" : "profiles"
            return "Allow \(scheduledProfileCount) scheduled \(noun) to run after sign-in while Delta's main window is closed."
        }
        return status.detail
    }

    private static func approvalText(status: LaunchAgentRegistrationStatus) -> String {
        switch status {
        case .enabled:
            return "Approved"
        case .requiresApproval:
            return "Needed"
        case .notRegistered:
            return "Off"
        case .notFound:
            return "Missing"
        case .unavailable:
            return "Unavailable"
        case .unknown:
            return "Unknown"
        }
    }

    private static func attentionTitle(
        status: LaunchAgentRegistrationStatus,
        hasScheduledProfiles: Bool,
        isPaused: Bool
    ) -> String? {
        guard hasScheduledProfiles else {
            return nil
        }
        if isPaused {
            return "Scheduled backups paused"
        }
        switch status {
        case .enabled:
            return nil
        case .requiresApproval:
            return "macOS approval required"
        case .notRegistered:
            return "Scheduled backups are off"
        case .notFound:
            return "Scheduler missing"
        case .unavailable:
            return "Scheduled backups unavailable"
        case .unknown:
            return "Unknown schedule status"
        }
    }

    private static func attentionText(
        status: LaunchAgentRegistrationStatus,
        hasScheduledProfiles: Bool,
        isPaused: Bool
    ) -> String? {
        guard hasScheduledProfiles else {
            return nil
        }
        if isPaused {
            return "Automatic scheduled runs are paused. Resume them here when you want due backups to run again."
        }
        switch status {
        case .enabled:
            return nil
        case .requiresApproval:
            return "Approve Delta in Login Items before scheduled backups can run while the main window is closed."
        case .notRegistered:
            return "Turn on Scheduled Backups before scheduled profiles can run while the main window is closed."
        case .notFound:
            return "Delta's signed scheduler is missing from the installed app bundle. Reinstall Delta from the latest build."
        case .unavailable:
            return "This macOS version cannot run Delta's scheduler."
        case .unknown:
            return "macOS returned an unknown schedule status. Refresh status, then review Login Items if scheduled backups do not run."
        }
    }

    private static func severity(
        status: LaunchAgentRegistrationStatus,
        hasScheduledProfiles: Bool,
        isPaused: Bool
    ) -> BackgroundBackupServiceSeverity {
        if isPaused {
            return .attention
        }
        if !hasScheduledProfiles && status == .notRegistered {
            return .inactive
        }
        switch status {
        case .enabled:
            return .ready
        case .requiresApproval, .notRegistered:
            return .attention
        case .notFound, .unavailable, .unknown:
            return .blocked
        }
    }
}
