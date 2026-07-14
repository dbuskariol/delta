import Foundation

public enum BackupIssueCategory: String, Codable, CaseIterable, Sendable {
    case permissionDenied
    case changedDuringRead
    case unavailable
    case inputOutput
    case resourceBusy
    case unsupported
    case other

    public var title: String {
        switch self {
        case .permissionDenied: "Permission denied"
        case .changedDuringRead: "Changed during backup"
        case .unavailable: "No longer available"
        case .inputOutput: "Storage read error"
        case .resourceBusy: "Temporarily busy"
        case .unsupported: "Unsupported item"
        case .other: "Other read issue"
        }
    }

    public var guidance: String {
        switch self {
        case .permissionDenied:
            "Restore file ownership or access, or exclude the item only when it is generated data."
        case .changedDuringRead:
            "Retry the backup. Exclude the location only when it contains replaceable cache data."
        case .unavailable:
            "The item disappeared during the scan. Retry to confirm whether the issue is temporary."
        case .inputOutput:
            "Check the source disk and connection before retrying. Do not exclude important data."
        case .resourceBusy:
            "Retry after the app or service using this item has finished."
        case .unsupported:
            "Review the item type before deciding whether it is safe to exclude."
        case .other:
            "Review the reported cause before retrying or changing backup coverage."
        }
    }
}

public struct BackupIssueExclusionRecommendation: Codable, Equatable, Sendable {
    public var pattern: String
    public var title: String
    public var detail: String

    public init(pattern: String, title: String, detail: String) {
        self.pattern = pattern
        self.title = title
        self.detail = detail
    }
}

public struct BackupIssue: Codable, Equatable, Sendable {
    public var path: String
    public var reason: String
    public var operation: String?
    public var category: BackupIssueCategory

    public init(path: String, reason: String, operation: String? = nil) {
        let cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanReason = Self.conciseReason(
            reason.trimmingCharacters(in: .whitespacesAndNewlines),
            path: cleanPath
        )
        self.path = cleanPath
        self.reason = cleanReason.isEmpty ? "The item could not be read." : cleanReason
        self.operation = operation?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.category = Self.category(for: cleanReason)
    }

    public var displayMessage: String {
        "\(reason): \(path)"
    }

    public var exactExclusionPattern: String {
        BackupExcludePolicy.literalPattern(for: path)
    }

    public var recommendedExclusion: BackupIssueExclusionRecommendation? {
        if let directory = pathPrefix(through: "/Library/Application Support/FileProvider/", endingAt: "/wharf/tombstone") {
            return BackupIssueExclusionRecommendation(
                pattern: BackupExcludePolicy.literalPattern(for: directory),
                title: "FileProvider temporary data",
                detail: "Generated cloud-file bookkeeping that is not useful in a restore."
            )
        }
        if let directory = pathPrefix(through: "/Library/Google/GoogleSoftwareUpdate/Stats") {
            return BackupIssueExclusionRecommendation(
                pattern: BackupExcludePolicy.literalPattern(for: directory),
                title: "Google update statistics",
                detail: "Generated updater statistics that can be recreated."
            )
        }
        if let directory = pathPrefix(through: "/Library/Group Containers/group.com.apple.CoreSpeech/Caches") {
            return BackupIssueExclusionRecommendation(
                pattern: BackupExcludePolicy.literalPattern(for: directory),
                title: "CoreSpeech generated cache",
                detail: "Generated speech-model cache data that macOS recreates."
            )
        }
        if path.contains("/Library/Group Containers/group.com.apple.secure-control-center-preferences/") {
            return BackupIssueExclusionRecommendation(
                pattern: exactExclusionPattern,
                title: "Control Center generated state",
                detail: "Machine-specific system state that is not portable during restore."
            )
        }
        return nil
    }

    public func acknowledgmentFingerprint(profileID: UUID) -> String {
        [
            profileID.uuidString.lowercased(),
            category.rawValue,
            path.precomposedStringWithCanonicalMapping.lowercased(),
            reason.precomposedStringWithCanonicalMapping.lowercased(),
            operation?.precomposedStringWithCanonicalMapping.lowercased() ?? ""
        ].joined(separator: "\u{1F}")
    }

    private static func category(for reason: String) -> BackupIssueCategory {
        let value = reason.lowercased()
        if containsAny(value, ["permission denied", "operation not permitted", "access denied"]) {
            return .permissionDenied
        }
        if containsAny(value, ["changed while reading", "changed as we read", "modified during", "file changed"]) {
            return .changedDuringRead
        }
        if containsAny(value, ["no such file", "not found", "does not exist", "vanished"]) {
            return .unavailable
        }
        if containsAny(value, ["input/output error", "i/o error", "device error"]) {
            return .inputOutput
        }
        if containsAny(value, ["resource busy", "temporarily unavailable", "device busy"]) {
            return .resourceBusy
        }
        if containsAny(value, ["unsupported", "invalid file type", "not supported"]) {
            return .unsupported
        }
        return .other
    }

    private static func conciseReason(_ reason: String, path: String) -> String {
        guard !path.isEmpty else { return reason }
        let withoutPath = reason
            .replacingOccurrences(of: path, with: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":-")))
        return withoutPath
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .replacingOccurrences(of: " :", with: ":")
    }

    private static func containsAny(_ value: String, _ fragments: [String]) -> Bool {
        fragments.contains { value.contains($0) }
    }

    private func pathPrefix(through marker: String) -> String? {
        guard let range = path.range(of: marker) else { return nil }
        return String(path[..<range.upperBound])
    }

    private func pathPrefix(through startMarker: String, endingAt endMarker: String) -> String? {
        guard let startRange = path.range(of: startMarker) else { return nil }
        guard let endRange = path.range(of: endMarker, range: startRange.lowerBound..<path.endIndex) else { return nil }
        return String(path[..<endRange.upperBound])
    }
}

public struct BackupIssueGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var category: BackupIssueCategory
    public var issues: [BackupIssue]

    public static func grouped(_ issues: [BackupIssue]) -> [BackupIssueGroup] {
        let groups = Dictionary(grouping: issues) { issue in
            issue.category == .other
                ? "\(issue.category.rawValue):\(issue.reason.lowercased())"
                : issue.category.rawValue
        }
        return groups.map { id, issues in
            BackupIssueGroup(
                id: id,
                category: issues[0].category,
                issues: issues.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            )
        }
        .sorted { lhs, rhs in
            lhs.category.title.localizedStandardCompare(rhs.category.title) == .orderedAscending
        }
    }
}

public struct BackupIssueAcknowledgmentStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = DeltaAppPreferences.sharedStore()) {
        self.defaults = defaults
    }

    public func isAcknowledged(_ issue: BackupIssue, profileID: UUID) -> Bool {
        fingerprints.contains(issue.acknowledgmentFingerprint(profileID: profileID))
    }

    public func allAcknowledged(_ issues: [BackupIssue], profileID: UUID) -> Bool {
        guard !issues.isEmpty else { return false }
        let values = fingerprints
        return issues.allSatisfy {
            values.contains($0.acknowledgmentFingerprint(profileID: profileID))
        }
    }

    public func setAcknowledged(_ acknowledged: Bool, issues: [BackupIssue], profileID: UUID) {
        var values = fingerprints
        for issue in issues {
            let fingerprint = issue.acknowledgmentFingerprint(profileID: profileID)
            if acknowledged {
                values.insert(fingerprint)
            } else {
                values.remove(fingerprint)
            }
        }
        defaults.set(Array(values).sorted(), forKey: DeltaAppPreferenceKeys.acknowledgedBackupIssueFingerprints)
    }

    private var fingerprints: Set<String> {
        Set(defaults.stringArray(forKey: DeltaAppPreferenceKeys.acknowledgedBackupIssueFingerprints) ?? [])
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
