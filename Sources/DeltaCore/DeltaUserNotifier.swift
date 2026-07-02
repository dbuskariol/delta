import Foundation
import UserNotifications

public enum DeltaNotificationAuthorizationState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case provisional
    case ephemeral
    case unknown

    public var displayName: String {
        switch self {
        case .notDetermined:
            return "Not Asked"
        case .authorized:
            return "Allowed"
        case .denied:
            return "Blocked"
        case .provisional:
            return "Quiet"
        case .ephemeral:
            return "Temporary"
        case .unknown:
            return "Unknown"
        }
    }

    public var canDeliver: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied, .unknown:
            return false
        }
    }

    public init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .denied
        case .authorized:
            self = .authorized
        case .provisional:
            self = .provisional
        case .ephemeral:
            self = .ephemeral
        @unknown default:
            self = .unknown
        }
    }
}

public enum DeltaUserNotifier {
    public static func authorizationState() async -> DeltaNotificationAuthorizationState {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: DeltaNotificationAuthorizationState(settings.authorizationStatus))
            }
        }
    }

    public static func requestAuthorization() async -> DeltaNotificationAuthorizationState {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await authorizationState()
    }

    public static func deliver(_ content: JobNotificationContent) {
        let requestContent = UNMutableNotificationContent()
        requestContent.title = content.title
        requestContent.body = content.body
        requestContent.sound = .default

        let request = UNNotificationRequest(
            identifier: "delta.job.\(content.identifier)",
            content: requestContent,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
