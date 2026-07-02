import Foundation

public enum BackgroundSecretAccessState: Equatable, Sendable {
    case noDestinations
    case unchecked
    case ready
    case needsRepair
}

public struct BackgroundSecretAccessSummary: Equatable, Sendable {
    public var state: BackgroundSecretAccessState
    public var destinationCount: Int
    public var checkedSecretCount: Int
    public var failureCount: Int
    public var failedDestinationNames: [String]
    public var firstFailure: RepositorySecretAccessFailure?

    public init(reports: [RepositorySecretAccessReport], destinationCount: Int) {
        self.destinationCount = destinationCount
        checkedSecretCount = reports.reduce(0) { $0 + $1.checkedAccounts }
        let failures = reports.flatMap(\.failures)
        failureCount = failures.count
        failedDestinationNames = reports
            .filter { !$0.isFullyAccessible }
            .map(\.repositoryName)
            .sorted()
        firstFailure = failures.first

        if destinationCount == 0 {
            state = .noDestinations
        } else if reports.isEmpty {
            state = .unchecked
        } else if failures.isEmpty {
            state = .ready
        } else {
            state = .needsRepair
        }
    }

    public var displayName: String {
        switch state {
        case .noDestinations:
            return "Not Needed"
        case .unchecked:
            return "Unchecked"
        case .ready:
            return "Ready"
        case .needsRepair:
            return "Needs Repair"
        }
    }

    public var detail: String {
        switch state {
        case .noDestinations:
            return "No saved destinations need password access yet."
        case .unchecked:
            return "Saved destination passwords have not been checked for background use yet."
        case .ready:
            return checkedSecretCount == 1
                ? "One saved secret can be read without interactive Keychain prompts."
                : "\(checkedSecretCount) saved secrets can be read without interactive Keychain prompts."
        case .needsRepair:
            let destinationText = failedDestinationNames.prefix(3).joined(separator: ", ")
            let remaining = failedDestinationNames.count - min(failedDestinationNames.count, 3)
            let suffix = remaining > 0 ? " and \(remaining) more" : ""
            let destinationSummary = destinationText.isEmpty ? "saved destinations" : "\(destinationText)\(suffix)"
            return "\(failureCount) saved \(failureCount == 1 ? "secret needs" : "secrets need") repair for \(destinationSummary)."
        }
    }

    public var needsRepair: Bool {
        state == .needsRepair
    }
}
