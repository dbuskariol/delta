import Foundation

public protocol SystemActivityManaging: Sendable {
    func beginActivity(named reason: String) -> SystemActivityAssertion?
}

public struct SystemActivityAssertion: @unchecked Sendable {
    private let endHandler: () -> Void

    public init(endHandler: @escaping () -> Void) {
        self.endHandler = endHandler
    }

    public func end() {
        endHandler()
    }
}

public struct ProcessInfoSystemActivityManager: SystemActivityManaging {
    public init() {}

    public func beginActivity(named reason: String) -> SystemActivityAssertion? {
        guard DeltaAppPreferences.bool(
            for: DeltaAppPreferenceKeys.preventsIdleSleepDuringJobs,
            default: true
        ) else {
            return nil
        }

        let token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: reason
        )
        return SystemActivityAssertion {
            ProcessInfo.processInfo.endActivity(token)
        }
    }
}
