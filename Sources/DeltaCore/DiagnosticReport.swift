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

    public init(name: String, kind: String, lastVerifiedAt: Date? = nil) {
        self.name = name
        self.kind = kind
        self.lastVerifiedAt = lastVerifiedAt
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
    public var appLoginItemStatus: String
    public var notificationStatus: String
    public var menuBarStatus: String
    public var backupFreshnessStatus: String
    public var destinationVerificationStatus: String
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
        appLoginItemStatus: String,
        notificationStatus: String,
        menuBarStatus: String,
        backupFreshnessStatus: String,
        destinationVerificationStatus: String,
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
        self.appLoginItemStatus = appLoginItemStatus
        self.notificationStatus = notificationStatus
        self.menuBarStatus = menuBarStatus
        self.backupFreshnessStatus = backupFreshnessStatus
        self.destinationVerificationStatus = destinationVerificationStatus
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
            "- Background Backups: \(snapshot.backgroundBackupsStatus)",
            "- Start at Login: \(snapshot.appLoginItemStatus)",
            "- Notifications: \(snapshot.notificationStatus)",
            "- Menu Bar: \(snapshot.menuBarStatus)",
            "- Backup Freshness: \(snapshot.backupFreshnessStatus)",
            "- Destination Verification: \(snapshot.destinationVerificationStatus)",
            "- Restore Defaults: \(snapshot.restoreDefaultsStatus)",
            "- Active Operation: \(snapshot.activeOperation ?? "None")",
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
            return "- \(destination.name): \(destination.kind)\(verified)"
        }

        lines += ["", "## Profiles"]
        lines += listOrEmpty(snapshot.profiles) { profile in
            let schedule = profile.scheduleEnabled ? "scheduled" : "manual"
            return "- \(profile.name): \(profile.sourceMode); \(profile.sourceCount) source(s); \(schedule); \(profile.customExcludeCount) extra exclude(s)"
        }

        lines += ["", "## Recent Jobs"]
        lines += listOrEmpty(snapshot.recentJobs) { job in
            let exitCode = job.exitCode.map { "; exit \($0)" } ?? ""
            let message = job.message.map { "; \($0)" } ?? ""
            return "- \(timestamp(job.startedAt)): \(job.kind) \(job.status)\(exitCode)\(message)"
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func listOrEmpty<T>(_ values: [T], render: (T) -> String) -> [String] {
        values.isEmpty ? ["- None"] : values.map(render)
    }

    private func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
