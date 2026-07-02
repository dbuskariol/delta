import Foundation

public struct MenuBarStatusPresentation: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        case ready
        case running
        case attention
        case blocked
    }

    public var symbolName: String
    public var headerText: String
    public var badgeText: String
    public var accessibilityLabel: String
    public var tone: Tone

    public init(
        symbolName: String,
        headerText: String,
        badgeText: String,
        accessibilityLabel: String,
        tone: Tone
    ) {
        self.symbolName = symbolName
        self.headerText = headerText
        self.badgeText = badgeText
        self.accessibilityLabel = accessibilityLabel
        self.tone = tone
    }

    public static func make(
        isPersistentStoreAvailable: Bool,
        isWorking: Bool,
        activeJobKind: JobKind?,
        latestBackupStatus: JobStatus?
    ) -> MenuBarStatusPresentation {
        guard isPersistentStoreAvailable else {
            return MenuBarStatusPresentation(
                symbolName: "externaldrive.badge.exclamationmark",
                headerText: "Storage unavailable",
                badgeText: "Blocked",
                accessibilityLabel: "Delta, storage unavailable",
                tone: .blocked
            )
        }

        if isWorking {
            let headerText: String
            if let activeJobKind {
                headerText = activeJobKind == .backup ? "Backup running" : "\(activeJobKind.displayName) running"
            } else {
                headerText = "Backup running"
            }
            return MenuBarStatusPresentation(
                symbolName: "arrow.triangle.2.circlepath",
                headerText: headerText,
                badgeText: "Running",
                accessibilityLabel: "Delta, \(headerText.lowercased())",
                tone: .running
            )
        }

        guard let latestBackupStatus else {
            return MenuBarStatusPresentation(
                symbolName: "externaldrive.badge.checkmark",
                headerText: "Ready",
                badgeText: "Ready",
                accessibilityLabel: "Delta, ready",
                tone: .ready
            )
        }

        switch latestBackupStatus {
        case .failed, .warning, .cancelled:
            let displayName = latestBackupStatus.displayName
            return MenuBarStatusPresentation(
                symbolName: "externaldrive.badge.exclamationmark",
                headerText: "Last backup \(displayName.lowercased())",
                badgeText: displayName,
                accessibilityLabel: "Delta, last backup \(displayName)",
                tone: .attention
            )
        case .queued, .running:
            return MenuBarStatusPresentation(
                symbolName: "arrow.triangle.2.circlepath",
                headerText: "Backup \(latestBackupStatus.displayName.lowercased())",
                badgeText: latestBackupStatus.displayName,
                accessibilityLabel: "Delta, backup \(latestBackupStatus.displayName.lowercased())",
                tone: .running
            )
        case .succeeded:
            return MenuBarStatusPresentation(
                symbolName: "externaldrive.badge.checkmark",
                headerText: "Last backup completed",
                badgeText: "Ready",
                accessibilityLabel: "Delta, last backup Completed",
                tone: .ready
            )
        }
    }
}
