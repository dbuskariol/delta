import Foundation

public struct RestoreDefaults: Equatable, Sendable {
    public var previewFirst: Bool
    public var verifyRestoredFiles: Bool
    public var conflictPolicy: RestoreConflictPolicy

    public init(
        previewFirst: Bool = true,
        verifyRestoredFiles: Bool = true,
        conflictPolicy: RestoreConflictPolicy = .ifChanged
    ) {
        self.previewFirst = previewFirst
        self.verifyRestoredFiles = verifyRestoredFiles
        self.conflictPolicy = conflictPolicy
    }

    public static func current() -> RestoreDefaults {
        RestoreDefaults(
            previewFirst: DeltaAppPreferences.bool(
                for: DeltaAppPreferenceKeys.previewsRestoresByDefault,
                default: true
            ),
            verifyRestoredFiles: DeltaAppPreferences.bool(
                for: DeltaAppPreferenceKeys.verifiesRestoresByDefault,
                default: true
            ),
            conflictPolicy: normalizedConflictPolicy(
                DeltaAppPreferences.string(
                    for: DeltaAppPreferenceKeys.defaultRestoreConflictPolicy,
                    default: RestoreConflictPolicy.ifChanged.rawValue
                )
            )
        )
    }

    public static func normalized(
        previewFirst: Bool,
        verifyRestoredFiles: Bool,
        conflictPolicyRawValue: String
    ) -> RestoreDefaults {
        RestoreDefaults(
            previewFirst: previewFirst,
            verifyRestoredFiles: verifyRestoredFiles,
            conflictPolicy: normalizedConflictPolicy(conflictPolicyRawValue)
        )
    }

    public var summaryText: String {
        "\(previewFirst ? "Preview first" : "Direct restore"), \(verifyRestoredFiles ? "verify files" : "no verification"), \(conflictPolicy.displayName)"
    }

    private static func normalizedConflictPolicy(_ rawValue: String) -> RestoreConflictPolicy {
        RestoreConflictPolicy(rawValue: rawValue) ?? .ifChanged
    }
}
