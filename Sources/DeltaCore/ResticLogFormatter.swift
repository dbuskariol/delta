import Foundation

public struct ResticProgressSnapshot: Equatable, Sendable {
    public var percentDone: Double?
    public var filesDone: Int?
    public var totalFiles: Int?
    public var bytesDone: Int?
    public var currentPath: String?
    public var displayMessage: String

    public init(
        percentDone: Double? = nil,
        filesDone: Int? = nil,
        totalFiles: Int? = nil,
        bytesDone: Int? = nil,
        currentPath: String? = nil,
        displayMessage: String
    ) {
        self.percentDone = percentDone
        self.filesDone = filesDone
        self.totalFiles = totalFiles
        self.bytesDone = bytesDone
        self.currentPath = currentPath
        self.displayMessage = displayMessage
    }
}

public enum ResticLogFormatter {
    public static func displayMessage(for rawMessage: String) -> String {
        guard let object = jsonObject(from: rawMessage) else {
            return rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return displayMessage(from: object, fallback: rawMessage)
    }

    public static func progressSnapshot(for rawMessage: String) -> ResticProgressSnapshot? {
        guard
            let object = jsonObject(from: rawMessage),
            object["message_type"] as? String == "status"
        else {
            return nil
        }

        let percentDone = number(object["percent_done"]).map { min(max($0, 0), 1) }
        return ResticProgressSnapshot(
            percentDone: percentDone,
            filesDone: integer(object["files_done"]),
            totalFiles: integer(object["total_files"]),
            bytesDone: integer(object["bytes_done"]),
            currentPath: currentPath(from: object),
            displayMessage: statusMessage(from: object)
        )
    }

    private static func jsonObject(from rawMessage: String) -> [String: Any]? {
        let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            trimmed.first == "{",
            let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func displayMessage(from object: [String: Any], fallback: String) -> String {
        guard let messageType = object["message_type"] as? String else {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch messageType {
        case "status":
            return statusMessage(from: object)
        case "summary":
            return summaryMessage(from: object)
        case "error":
            return errorMessage(from: object)
        default:
            if let message = object["message"] as? String, !message.isEmpty {
                return message
            }
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func statusMessage(from object: [String: Any]) -> String {
        var parts: [String] = []
        if let percentDone = number(object["percent_done"]) {
            parts.append("Estimated \(Int((percentDone * 100).rounded()))%")
        }
        if let filesDone = integer(object["files_done"]) {
            if let totalFiles = integer(object["total_files"]), totalFiles > 0 {
                parts.append("\(filesDone)/\(totalFiles) files")
            } else {
                parts.append("\(filesDone) files")
            }
        }
        if let bytesDone = integer(object["bytes_done"]), bytesDone > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytesDone), countStyle: .file))
        }
        if let currentPath = currentPath(from: object) {
            parts.append("Current \(compactPath(currentPath))")
        }
        return parts.isEmpty ? "Backup is scanning sources" : parts.joined(separator: " · ")
    }

    private static func summaryMessage(from object: [String: Any]) -> String {
        var parts = ["Backup summary"]
        if let files = integer(object["total_files_processed"]) {
            parts.append("\(files) files processed")
        }
        if let bytes = integer(object["total_bytes_processed"]) {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private static func errorMessage(from object: [String: Any]) -> String {
        let message = (object["message"] as? String) ?? (object["error"] as? String) ?? "A backup item could not be processed."
        if let item = object["item"] as? String, !item.isEmpty {
            return "\(message): \(item)"
        }
        return message
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        default:
            return nil
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Double:
            return Int(value)
        case let value as NSNumber:
            return value.intValue
        default:
            return nil
        }
    }

    private static func currentPath(from object: [String: Any]) -> String? {
        if let currentFile = object["current_file"] as? String, !currentFile.isEmpty {
            return currentFile
        }
        if let currentFiles = object["current_files"] as? [String] {
            return currentFiles.first { !$0.isEmpty }
        }
        if let item = object["item"] as? String, !item.isEmpty {
            return item
        }
        return nil
    }

    private static func compactPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "/").map(String.init)
        guard components.count > 3 else {
            return trimmed
        }
        return ".../" + components.suffix(3).joined(separator: "/")
    }
}
