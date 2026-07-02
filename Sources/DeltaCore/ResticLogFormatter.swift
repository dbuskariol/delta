import Foundation

public enum ResticLogFormatter {
    public static func displayMessage(for rawMessage: String) -> String {
        let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            trimmed.first == "{",
            let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return trimmed
        }

        guard let messageType = object["message_type"] as? String else {
            return trimmed
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
            return trimmed
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
