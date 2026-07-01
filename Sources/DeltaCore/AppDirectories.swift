import Foundation

public enum AppDirectories {
    public static let applicationSupportFolderName = "Delta"

    public static func applicationSupportDirectory(fileManager: FileManager = .default) throws -> URL {
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
}
