import Foundation

public enum RestorePointSelection {
    public static func reconciledSelection(currentID: String, availableIDs: [String]) -> String {
        if !currentID.isEmpty, availableIDs.contains(currentID) {
            return currentID
        }
        return availableIDs.first ?? ""
    }

    public static func scopedSummaryKey(destinationID: UUID, restorePointID: String) -> String {
        "\(destinationID.uuidString)|\(restorePointID)"
    }
}
