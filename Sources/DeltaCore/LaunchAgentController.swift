import Foundation

#if canImport(ServiceManagement)
import ServiceManagement
#endif

public enum LaunchAgentRegistrationStatus: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case unavailable
    case unknown(String)

    public var displayName: String {
        switch self {
        case .enabled: "Ready"
        case .requiresApproval: "Needs Approval"
        case .notRegistered: "Off"
        case .notFound: "Missing Scheduler"
        case .unavailable: "Unavailable"
        case .unknown: "Unknown"
        }
    }

    public var detail: String {
        switch self {
        case .enabled:
            return "Scheduled backups can run while Delta is closed."
        case .requiresApproval:
            return "Approve Delta in Login Items to allow scheduled backups."
        case .notRegistered:
            return "Turn on background backups to run scheduled backups while Delta is closed."
        case .notFound:
            return "The background scheduler could not be found in the app bundle."
        case .unavailable:
            return "Background backups are unavailable on this macOS version."
        case .unknown:
            return "macOS returned an unknown background backup status."
        }
    }

    public var blocksScheduledBackups: Bool {
        self != .enabled
    }

    static func parse(_ rawValue: String) -> LaunchAgentRegistrationStatus {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "enabled":
            return .enabled
        case "requiresapproval", "requires_approval", "requires approval":
            return .requiresApproval
        case "notregistered", "not_registered", "not registered":
            return .notRegistered
        case "notfound", "not_found", "not found":
            return .notFound
        case "unavailable":
            return .unavailable
        default:
            if normalized.contains("rawvalue: 0") || normalized == "0" {
                return .notRegistered
            }
            if normalized.contains("rawvalue: 1") || normalized == "1" {
                return .enabled
            }
            if normalized.contains("rawvalue: 2") || normalized == "2" {
                return .requiresApproval
            }
            if normalized.contains("rawvalue: 3") || normalized == "3" {
                return .notFound
            }
            return .unknown(rawValue)
        }
    }
}

public enum LaunchAgentController {
    public static let defaultPlistName = "com.delta.backup.agent.plist"

    public static func register(plistName: String = defaultPlistName) throws {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            try SMAppService.agent(plistName: plistName).register()
        }
        #endif
    }

    public static func unregister(plistName: String = defaultPlistName) throws {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            try SMAppService.agent(plistName: plistName).unregister()
        }
        #endif
    }

    public static func status(plistName: String = defaultPlistName) -> LaunchAgentRegistrationStatus {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            switch SMAppService.agent(plistName: plistName).status {
            case .enabled:
                return .enabled
            case .requiresApproval:
                return .requiresApproval
            case .notRegistered:
                return .notRegistered
            case .notFound:
                return .notFound
            @unknown default:
                return LaunchAgentRegistrationStatus.parse("\(SMAppService.agent(plistName: plistName).status)")
            }
        }
        #endif
        return .unavailable
    }
}

public enum AppLoginItemController {
    public static func register() throws {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            try SMAppService.mainApp.register()
        }
        #endif
    }

    public static func unregister() throws {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            try SMAppService.mainApp.unregister()
        }
        #endif
    }

    public static func status() -> LaunchAgentRegistrationStatus {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled:
                return .enabled
            case .requiresApproval:
                return .requiresApproval
            case .notRegistered:
                return .notRegistered
            case .notFound:
                return .notFound
            @unknown default:
                return LaunchAgentRegistrationStatus.parse("\(SMAppService.mainApp.status)")
            }
        }
        #endif
        return .unavailable
    }
}

public enum FullDiskAccessGuide {
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

public enum LoginItemsGuide {
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
}

public enum NotificationSettingsGuide {
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
}
