import Foundation

public struct JobOutcomePresentation: Equatable, Sendable {
    public let technicalStatus: JobStatus
    public let acknowledgedOmissionCount: Int

    public init(status: JobStatus, acknowledgedOmissionCount: Int? = nil) {
        technicalStatus = status
        self.acknowledgedOmissionCount = status == .warning
            ? max(acknowledgedOmissionCount ?? 0, 0)
            : 0
    }

    public var hasKnownOmissions: Bool {
        technicalStatus == .warning && acknowledgedOmissionCount > 0
    }

    public var visualStatus: JobStatus {
        hasKnownOmissions ? .succeeded : technicalStatus
    }

    public var displayName: String {
        hasKnownOmissions ? "Completed" : technicalStatus.displayName
    }

    public var detailText: String? {
        guard hasKnownOmissions else { return nil }
        return "\(acknowledgedOmissionCount) known \(acknowledgedOmissionCount == 1 ? "omission" : "omissions")"
    }

    public var needsAttention: Bool {
        technicalStatus == .failed || (technicalStatus == .warning && !hasKnownOmissions)
    }
}
