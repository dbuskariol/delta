import Foundation

public struct DiagnosticToolSummary: Equatable, Sendable {
    public var name: String
    public var path: String
    public var isExecutable: Bool

    public init(name: String, path: String, isExecutable: Bool) {
        self.name = name
        self.path = path
        self.isExecutable = isExecutable
    }
}

public struct DiagnosticDestinationSummary: Equatable, Sendable {
    public var name: String
    public var kind: String
    public var lastVerifiedAt: Date?
    public var format: String?
    public var timeMachineState: String?
    public var committedGeneration: UInt64?
    public var cleanCacheBytes: Int64?
    public var dirtyCacheBytes: Int64?
    public var timeMachineFailureContext: String?
    public var timeMachineLastError: String?

    public init(
        name: String,
        kind: String,
        lastVerifiedAt: Date? = nil,
        format: String? = nil,
        timeMachineState: String? = nil,
        committedGeneration: UInt64? = nil,
        cleanCacheBytes: Int64? = nil,
        dirtyCacheBytes: Int64? = nil,
        timeMachineFailureContext: String? = nil,
        timeMachineLastError: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.lastVerifiedAt = lastVerifiedAt
        self.format = format
        self.timeMachineState = timeMachineState
        self.committedGeneration = committedGeneration
        self.cleanCacheBytes = cleanCacheBytes
        self.dirtyCacheBytes = dirtyCacheBytes
        self.timeMachineFailureContext = timeMachineFailureContext
        self.timeMachineLastError = timeMachineLastError
    }
}

public struct DiagnosticProfileSummary: Equatable, Sendable {
    public var name: String
    public var sourceMode: String
    public var sourceCount: Int
    public var scheduleEnabled: Bool
    public var customExcludeCount: Int

    public init(
        name: String,
        sourceMode: String,
        sourceCount: Int,
        scheduleEnabled: Bool,
        customExcludeCount: Int
    ) {
        self.name = name
        self.sourceMode = sourceMode
        self.sourceCount = sourceCount
        self.scheduleEnabled = scheduleEnabled
        self.customExcludeCount = customExcludeCount
    }
}

public struct DiagnosticJobSummary: Equatable, Sendable {
    public var kind: String
    public var status: String
    public var startedAt: Date
    public var exitCode: Int32?
    public var message: String?

    public init(
        kind: String,
        status: String,
        startedAt: Date,
        exitCode: Int32? = nil,
        message: String? = nil
    ) {
        self.kind = kind
        self.status = status
        self.startedAt = startedAt
        self.exitCode = exitCode
        self.message = message
    }
}

public struct DiagnosticReportSnapshot: Equatable, Sendable {
    public var generatedAt: Date
    public var appVersion: String
    public var buildVersion: String
    public var bundleIdentifier: String
    public var bundlePath: String
    public var executablePath: String
    public var applicationSupportPath: String
    public var databasePath: String
    public var logPath: String
    public var fullDiskAccessStatus: String
    public var backgroundBackupsStatus: String
    public var scheduledAutomationStatus: String
    public var backgroundPasswordAccessStatus: String
    public var appLoginItemStatus: String
    public var notificationStatus: String
    public var menuBarStatus: String
    public var idleSleepProtectionStatus: String
    public var operationalHistoryRetentionStatus: String
    public var backupFreshnessStatus: String
    public var destinationVerificationStatus: String
    public var destinationFreeSpaceStatus: String
    public var restoreDefaultsStatus: String
    public var activeOperation: String?
    public var profileCount: Int
    public var destinationCount: Int
    public var restorePointCount: Int
    public var recentJobCount: Int
    public var tools: [DiagnosticToolSummary]
    public var destinations: [DiagnosticDestinationSummary]
    public var profiles: [DiagnosticProfileSummary]
    public var recentJobs: [DiagnosticJobSummary]

    public init(
        generatedAt: Date,
        appVersion: String,
        buildVersion: String,
        bundleIdentifier: String,
        bundlePath: String,
        executablePath: String,
        applicationSupportPath: String,
        databasePath: String,
        logPath: String,
        fullDiskAccessStatus: String,
        backgroundBackupsStatus: String,
        scheduledAutomationStatus: String = "Running",
        backgroundPasswordAccessStatus: String = "Unchecked",
        appLoginItemStatus: String,
        notificationStatus: String,
        menuBarStatus: String,
        idleSleepProtectionStatus: String,
        operationalHistoryRetentionStatus: String,
        backupFreshnessStatus: String,
        destinationVerificationStatus: String,
        destinationFreeSpaceStatus: String,
        restoreDefaultsStatus: String,
        activeOperation: String?,
        profileCount: Int,
        destinationCount: Int,
        restorePointCount: Int,
        recentJobCount: Int,
        tools: [DiagnosticToolSummary],
        destinations: [DiagnosticDestinationSummary],
        profiles: [DiagnosticProfileSummary],
        recentJobs: [DiagnosticJobSummary]
    ) {
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.buildVersion = buildVersion
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.applicationSupportPath = applicationSupportPath
        self.databasePath = databasePath
        self.logPath = logPath
        self.fullDiskAccessStatus = fullDiskAccessStatus
        self.backgroundBackupsStatus = backgroundBackupsStatus
        self.scheduledAutomationStatus = scheduledAutomationStatus
        self.backgroundPasswordAccessStatus = backgroundPasswordAccessStatus
        self.appLoginItemStatus = appLoginItemStatus
        self.notificationStatus = notificationStatus
        self.menuBarStatus = menuBarStatus
        self.idleSleepProtectionStatus = idleSleepProtectionStatus
        self.operationalHistoryRetentionStatus = operationalHistoryRetentionStatus
        self.backupFreshnessStatus = backupFreshnessStatus
        self.destinationVerificationStatus = destinationVerificationStatus
        self.destinationFreeSpaceStatus = destinationFreeSpaceStatus
        self.restoreDefaultsStatus = restoreDefaultsStatus
        self.activeOperation = activeOperation
        self.profileCount = profileCount
        self.destinationCount = destinationCount
        self.restorePointCount = restorePointCount
        self.recentJobCount = recentJobCount
        self.tools = tools
        self.destinations = destinations
        self.profiles = profiles
        self.recentJobs = recentJobs
    }
}

public struct DiagnosticReportBuilder: Sendable {
    public init() {}

    public func makeReport(snapshot: DiagnosticReportSnapshot) -> String {
        var lines: [String] = [
            "# Delta Diagnostic Report",
            "",
            "Generated: \(timestamp(snapshot.generatedAt))",
            "",
            "## App",
            "- Version: \(snapshot.appVersion) (\(snapshot.buildVersion))",
            "- Bundle ID: \(snapshot.bundleIdentifier)",
            "- Bundle path: \(snapshot.bundlePath)",
            "- Executable path: \(snapshot.executablePath)",
            "",
            "## Local State",
            "- Application Support: \(snapshot.applicationSupportPath)",
            "- Database: \(snapshot.databasePath)",
            "- Logs: \(snapshot.logPath)",
            "",
            "## Status",
            "- Full Disk Access: \(snapshot.fullDiskAccessStatus)",
            "- Scheduled Backups: \(snapshot.backgroundBackupsStatus)",
            "- Scheduled Automation: \(snapshot.scheduledAutomationStatus)",
            "- Password Access: \(snapshot.backgroundPasswordAccessStatus)",
            "- Start at Login: \(snapshot.appLoginItemStatus)",
            "- Notifications: \(snapshot.notificationStatus)",
            "- Menu Bar: \(snapshot.menuBarStatus)",
            "- Idle Sleep Protection: \(snapshot.idleSleepProtectionStatus)",
            "- Activity History Retention: \(snapshot.operationalHistoryRetentionStatus)",
            "- Backup Freshness: \(snapshot.backupFreshnessStatus)",
            "- Destination Verification: \(snapshot.destinationVerificationStatus)",
            "- Destination Free Space: \(snapshot.destinationFreeSpaceStatus)",
            "- Restore Defaults: \(snapshot.restoreDefaultsStatus)",
            "- Active Operation: \(snapshot.activeOperation.map { diagnosticText($0) } ?? "None")",
            "",
            "## Counts",
            "- Profiles: \(snapshot.profileCount)",
            "- Destinations: \(snapshot.destinationCount)",
            "- Restore Points: \(snapshot.restorePointCount)",
            "- Recent Jobs: \(snapshot.recentJobCount)",
            "",
            "## Tools"
        ]

        lines += listOrEmpty(snapshot.tools) { tool in
            "- \(tool.name): \(tool.isExecutable ? "executable" : "missing") at \(tool.path)"
        }

        lines += ["", "## Destinations"]
        lines += listOrEmpty(snapshot.destinations) { destination in
            let verified = destination.lastVerifiedAt.map { "; verified \(timestamp($0))" } ?? ""
            let format = destination.format.map { "; format \(diagnosticText($0))" } ?? ""
            let timeMachine = destination.timeMachineState.map { state in
                let generation = destination.committedGeneration.map { "; generation \($0)" } ?? ""
                let cache: String
                if let clean = destination.cleanCacheBytes, let dirty = destination.dirtyCacheBytes {
                    cache = "; cache clean \(clean) bytes, dirty \(dirty) bytes"
                } else {
                    cache = ""
                }
                let failureContext = destination.timeMachineFailureContext.map {
                    "; failure context \(diagnosticText($0))"
                } ?? ""
                let lastError = destination.timeMachineLastError.map {
                    "; last error \(diagnosticText($0))"
                } ?? ""
                return "; Time Machine \(diagnosticText(state))\(generation)\(cache)\(failureContext)\(lastError)"
            } ?? ""
            return "- \(diagnosticText(destination.name)): \(destination.kind)\(format)\(timeMachine)\(verified)"
        }

        lines += ["", "## Profiles"]
        lines += listOrEmpty(snapshot.profiles) { profile in
            let schedule = profile.scheduleEnabled ? "scheduled" : "manual"
            return "- \(diagnosticText(profile.name)): \(profile.sourceMode); \(profile.sourceCount) source(s); \(schedule); \(profile.customExcludeCount) extra exclude(s)"
        }

        lines += ["", "## Recent Jobs"]
        lines += listOrEmpty(snapshot.recentJobs) { job in
            let exitCode = job.exitCode.map { "; exit \($0)" } ?? ""
            let message = job.message.map { "; \(diagnosticText($0))" } ?? ""
            return "- \(timestamp(job.startedAt)): \(job.kind) \(job.status)\(exitCode)\(message)"
        }

        return privacySafeReport(lines.joined(separator: "\n") + "\n")
    }

    private func listOrEmpty<T>(_ values: [T], render: (T) -> String) -> [String] {
        values.isEmpty ? ["- None"] : values.map(render)
    }

    private func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func diagnosticText(_ value: String, limit: Int = 240) -> String {
        let summarized = ResticLogFormatter.finalSummaryMessage(from: value)
            ?? value
                .split(whereSeparator: \.isNewline)
                .prefix(3)
                .map { ResticLogFormatter.displayMessage(for: String($0)) }
                .joined(separator: " · ")
        let collapsed = SensitiveLogRedactor.redact(summarized)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else {
            return collapsed
        }
        return String(collapsed.prefix(limit)) + "..."
    }

    private func privacySafeReport(_ report: String) -> String {
        let secretRedacted = SensitiveLogRedactor.redact(report)
        guard let expression = try? NSRegularExpression(
            pattern: #"/Users/(?!Shared(?:/|\b)|Guest(?:/|\b))[^/\s]+"#
        ) else {
            return secretRedacted
        }
        let range = NSRange(secretRedacted.startIndex..<secretRedacted.endIndex, in: secretRedacted)
        return expression.stringByReplacingMatches(
            in: secretRedacted,
            range: range,
            withTemplate: "~"
        )
    }
}
