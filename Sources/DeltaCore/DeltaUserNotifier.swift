import Foundation
import Synchronization
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

public enum DeltaNotificationDeliveryResult: Equatable, Sendable {
    case delivered
    case failed(String)
    case timedOut
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
        UNUserNotificationCenter.current().add(request(for: content))
    }

    public static func deliverAndWait(
        _ content: JobNotificationContent,
        timeout: TimeInterval = 5
    ) -> DeltaNotificationDeliveryResult {
        waitForDelivery(timeout: timeout) { completion in
            UNUserNotificationCenter.current().add(
                request(for: content),
                withCompletionHandler: completion
            )
        }
    }

    static func waitForDelivery(
        timeout: TimeInterval,
        submit: (@escaping @Sendable (Error?) -> Void) -> Void
    ) -> DeltaNotificationDeliveryResult {
        let completionState = DeltaNotificationDeliveryCompletionState()
        let semaphore = DispatchSemaphore(value: 0)
        submit { error in
            completionState.record(error: error)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + max(0, timeout)) == .success else {
            return .timedOut
        }
        return completionState.result
    }

    private static func request(for content: JobNotificationContent) -> UNNotificationRequest {
        let requestContent = UNMutableNotificationContent()
        requestContent.title = content.title
        requestContent.body = content.body
        requestContent.sound = .default

        return UNNotificationRequest(
            identifier: "delta.job.\(content.identifier)",
            content: requestContent,
            trigger: nil
        )
    }
}

private final class DeltaNotificationDeliveryCompletionState: Sendable {
    private let storedResult = Mutex<DeltaNotificationDeliveryResult>(.timedOut)

    var result: DeltaNotificationDeliveryResult {
        storedResult.withLock { $0 }
    }

    func record(error: Error?) {
        storedResult.withLock {
            $0 = error.map { .failed($0.localizedDescription) } ?? .delivered
        }
    }
}
