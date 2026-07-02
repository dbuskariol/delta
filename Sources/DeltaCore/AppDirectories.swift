import Foundation

public enum AppDirectories {
    public static let applicationSupportFolderName = "Delta"
    public static let applicationSupportOverrideEnvironmentKey = "DELTA_APP_SUPPORT_DIR"

    public static func applicationSupportDirectory(fileManager: FileManager = .default) throws -> URL {
        if let overridePath = ProcessInfo.processInfo.environment[applicationSupportOverrideEnvironmentKey],
           !overridePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalizedOverridePath = overridePath
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let expandedOverridePath = (normalizedOverridePath as NSString).expandingTildeInPath
            let directory = URL(fileURLWithPath: expandedOverridePath).standardizedFileURL
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent(applicationSupportFolderName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func databaseURL(fileManager: FileManager = .default) throws -> URL {
        try applicationSupportDirectory(fileManager: fileManager).appendingPathComponent("Delta.sqlite")
    }

    public static func logDirectory(fileManager: FileManager = .default) throws -> URL {
        let directory = try applicationSupportDirectory(fileManager: fileManager).appendingPathComponent("Logs", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func lockDirectory(fileManager: FileManager = .default) throws -> URL {
        let directory = try applicationSupportDirectory(fileManager: fileManager).appendingPathComponent("Locks", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func controlDirectory(fileManager: FileManager = .default) throws -> URL {
        let directory = try applicationSupportDirectory(fileManager: fileManager).appendingPathComponent("Control", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
