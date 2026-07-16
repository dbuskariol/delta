import Foundation

public struct ResticProgressSnapshot: Codable, Equatable, Sendable {
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

public struct ResticBackupSummary: Codable, Equatable, Sendable {
    public var filesNew: Int
    public var filesChanged: Int
    public var filesUnmodified: Int
    public var totalFilesProcessed: Int
    public var totalBytesProcessed: Int64
    public var dataAdded: Int64?
    public var dataBlobs: Int?
    public var snapshotID: String?

    public init(
        filesNew: Int = 0,
        filesChanged: Int = 0,
        filesUnmodified: Int = 0,
        totalFilesProcessed: Int = 0,
        totalBytesProcessed: Int64 = 0,
        dataAdded: Int64? = nil,
        dataBlobs: Int? = nil,
        snapshotID: String? = nil
    ) {
        self.filesNew = filesNew
        self.filesChanged = filesChanged
        self.filesUnmodified = filesUnmodified
        self.totalFilesProcessed = totalFilesProcessed
        self.totalBytesProcessed = totalBytesProcessed
        self.dataAdded = dataAdded
        self.dataBlobs = dataBlobs
        self.snapshotID = snapshotID
    }

    public var hasChanges: Bool {
        filesNew > 0 || filesChanged > 0 || (dataBlobs ?? 0) > 0
    }

    public var conciseText: String {
        if !hasChanges {
            var parts = [
                "\(filesNew.formatted()) new",
                "\(filesChanged.formatted()) changed"
            ]
            if totalBytesProcessed > 0 {
                parts.append("\(Self.byteString(totalBytesProcessed)) checked")
            } else {
                let fileCount = totalFilesProcessed > 0 ? totalFilesProcessed : filesUnmodified
                if fileCount > 0 {
                    parts.append("\(fileCount.formatted()) files checked")
                }
            }
            return parts.joined(separator: " · ")
        }

        var parts = [
            "\(filesNew.formatted()) new",
            "\(filesChanged.formatted()) changed"
        ]
        if let dataAdded, dataAdded > 0 {
            parts.append("\(Self.byteString(dataAdded)) added")
        } else if totalBytesProcessed > 0 {
            parts.append("\(Self.byteString(totalBytesProcessed)) checked")
        }
        return parts.joined(separator: " · ")
    }

    public var detailedText: String {
        var parts = [
            "\(filesNew.formatted()) new",
            "\(filesChanged.formatted()) changed",
            "\(filesUnmodified.formatted()) unchanged"
        ]
        if let dataAdded, dataAdded > 0 {
            parts.append("\(Self.byteString(dataAdded)) added")
        } else if totalBytesProcessed > 0 {
            parts.append("\(Self.byteString(totalBytesProcessed)) checked")
        }
        return parts.joined(separator: " · ")
    }

    public var logText: String {
        hasChanges ? "Backup summary · \(detailedText)" : "No changes detected · \(conciseText)"
    }

    private static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

public enum ResticLogFormatter {
    public static func displayMessage(for rawMessage: String) -> String {
        if let retentionMessage = retentionSummaryMessage(from: rawMessage) {
            return retentionMessage
        }
        if let itemCount = jsonArrayItemCount(from: rawMessage) {
            return "Structured operation output · \(itemCount.formatted()) \(itemCount == 1 ? "item" : "items")"
        }
        guard let object = jsonObject(from: rawMessage) else {
            return SensitiveLogRedactor.redact(rawMessage.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return SensitiveLogRedactor.redact(displayMessage(from: object, fallback: rawMessage))
    }

    public static func backupSummary(from output: String?) -> ResticBackupSummary? {
        guard let output else {
            return nil
        }
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard
                let object = jsonObject(from: String(line)),
                object["message_type"] as? String == "summary"
            else {
                continue
            }
            return backupSummary(from: object)
        }
        return nil
    }

    public static func finalSummaryMessage(from output: String?) -> String? {
        guard let output else {
            return nil
        }
        if let retentionMessage = retentionSummaryMessage(from: output) {
            return retentionMessage
        }
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard
                let object = jsonObject(from: String(line)),
                object["message_type"] as? String == "summary"
            else {
                continue
            }
            return displayMessage(from: object, fallback: String(line))
        }
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard
                let object = jsonObject(from: String(line)),
                let messageType = object["message_type"] as? String,
                messageType != "status",
                messageType != "verbose_status"
            else {
                continue
            }
            return displayMessage(from: object, fallback: String(line))
        }
        return nil
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
            displayMessage: SensitiveLogRedactor.redact(statusMessage(from: object))
        )
    }

    public static func isStatusMessage(_ rawMessage: String) -> Bool {
        guard let object = jsonObject(from: rawMessage) else {
            return false
        }
        return object["message_type"] as? String == "status"
    }

    public static func backupIssue(for rawMessage: String) -> BackupIssue? {
        guard let object = jsonObject(from: rawMessage) else { return nil }
        return backupIssue(from: object)
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

    private static func retentionSummaryMessage(from rawMessage: String) -> String? {
        let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            trimmed.first == "[",
            let data = trimmed.data(using: .utf8),
            let groups = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            groups.allSatisfy({ $0["keep"] != nil || $0["remove"] != nil || $0["reasons"] != nil })
        else {
            return nil
        }

        let kept = groups.reduce(0) { count, group in
            count + ((group["keep"] as? [Any])?.count ?? 0)
        }
        let removed = groups.reduce(0) { count, group in
            count + ((group["remove"] as? [Any])?.count ?? 0)
        }
        return "Retention complete · kept \(restorePointCountText(kept)) · removed \(restorePointCountText(removed))"
    }

    private static func jsonArrayItemCount(from rawMessage: String) -> Int? {
        let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            trimmed.first == "[",
            let data = trimmed.data(using: .utf8),
            let items = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else {
            return nil
        }
        return items.count
    }

    private static func restorePointCountText(_ count: Int) -> String {
        "\(count.formatted()) restore \(count == 1 ? "point" : "points")"
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
        case "exit_error":
            return errorMessage(from: object)
        case "initialized":
            return "Destination prepared"
        default:
            if let message = object["message"] as? String, !message.isEmpty {
                return message
            }
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func statusMessage(from object: [String: Any]) -> String {
        var parts: [String] = []
        if let filesDone = integer(object["files_done"]) {
            parts.append("Processed \(filesDone.formatted()) files")
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
        backupSummary(from: object)?.logText ?? genericSummaryMessage(from: object)
    }

    private static func backupSummary(from object: [String: Any]) -> ResticBackupSummary? {
        guard object["message_type"] as? String == "summary" else {
            return nil
        }
        let hasBackupCounters = object["files_new"] != nil
            || object["files_changed"] != nil
            || object["files_unmodified"] != nil
            || object["data_added"] != nil
        guard hasBackupCounters else {
            return nil
        }
        return ResticBackupSummary(
            filesNew: integer(object["files_new"]) ?? 0,
            filesChanged: integer(object["files_changed"]) ?? 0,
            filesUnmodified: integer(object["files_unmodified"]) ?? 0,
            totalFilesProcessed: integer(object["total_files_processed"]) ?? 0,
            totalBytesProcessed: int64(object["total_bytes_processed"]) ?? 0,
            dataAdded: int64(object["data_added"]),
            dataBlobs: integer(object["data_blobs"]),
            snapshotID: string(object["snapshot_id"])
        )
    }

    private static func genericSummaryMessage(from object: [String: Any]) -> String {
        var parts = ["Operation summary"]
        if let files = integer(object["total_files_processed"]) ?? integer(object["total_files"]) {
            parts.append("\(files.formatted()) items")
        }
        if let bytes = int64(object["total_bytes_processed"]) ?? int64(object["total_bytes"]) {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private static func errorMessage(from object: [String: Any]) -> String {
        if let issue = backupIssue(from: object) {
            return issue.displayMessage
        }
        let message = nestedErrorMessage(from: object) ?? "A backup item could not be processed."
        if let item = object["item"] as? String, !item.isEmpty {
            return "\(message): \(item)"
        }
        return message
    }

    private static func backupIssue(from object: [String: Any]) -> BackupIssue? {
        guard
            object["message_type"] as? String == "error",
            let path = object["item"] as? String,
            !path.isEmpty
        else {
            return nil
        }
        return BackupIssue(
            path: SensitiveLogRedactor.redact(path),
            reason: SensitiveLogRedactor.redact(nestedErrorMessage(from: object) ?? "The item could not be read."),
            operation: (object["during"] as? String).map(SensitiveLogRedactor.redact)
        )
    }

    private static func nestedErrorMessage(from object: [String: Any]) -> String? {
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        if let message = object["error"] as? String, !message.isEmpty {
            return message
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }
        return nil
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

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let value as Int:
            return Int64(value)
        case let value as Int64:
            return value
        case let value as Double:
            return Int64(value)
        case let value as NSNumber:
            return value.int64Value
        default:
            return nil
        }
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

public enum SensitiveLogRedactor {
    public static func redact(_ message: String) -> String {
        var redacted = replace(
            pattern: #"\b([A-Za-z][A-Za-z0-9+.-]*://)([^/\s:@]+):([^@\s/]+)@"#,
            in: message,
            with: "$1<redacted>@"
        )
        redacted = replace(
            pattern: #"\b(AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|B2_ACCOUNT_KEY|AZURE_ACCOUNT_KEY|AZURE_ACCOUNT_SAS|GOOGLE_ACCESS_TOKEN|OS_PASSWORD|OS_APPLICATION_CREDENTIAL_SECRET|OS_AUTH_TOKEN|ST_KEY|RESTIC_REST_PASSWORD|RCLONE_CONFIG_PASS)\s*([=:])\s*([^,\s;]+)"#,
            in: redacted,
            with: "$1$2<redacted>",
            options: [.caseInsensitive]
        )
        return redacted
    }

    private static func replace(
        pattern: String,
        in message: String,
        with replacement: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return message
        }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        return expression.stringByReplacingMatches(in: message, range: range, withTemplate: replacement)
    }
}
