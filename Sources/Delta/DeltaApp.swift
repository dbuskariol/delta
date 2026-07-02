import DeltaCore
import SwiftUI

@main
struct DeltaApp: App {
    @StateObject private var model = DeltaAppModel()
    @StateObject private var softwareUpdateController = SoftwareUpdateController()
    @AppStorage(DeltaAppPreferenceKeys.showsMenuBarExtra) private var showsMenuBarExtra = true

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(softwareUpdateController)
                .frame(minWidth: 1120, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra(isInserted: $showsMenuBarExtra) {
            DeltaMenuBarView()
                .environmentObject(model)
                .environmentObject(softwareUpdateController)
                .frame(width: 340)
        } label: {
            Image(systemName: menuBarSystemImage)
                .accessibilityLabel(menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSystemImage: String {
        if !model.isPersistentStoreAvailable {
            return "externaldrive.badge.exclamationmark"
        }
        if model.isWorking {
            return "arrow.triangle.2.circlepath"
        }
        switch latestBackupStatus {
        case .failed, .warning:
            return "externaldrive.badge.exclamationmark"
        default:
            return "externaldrive.badge.checkmark"
        }
    }

    private var menuBarAccessibilityLabel: String {
        if !model.isPersistentStoreAvailable {
            return "Delta, storage unavailable"
        }
        if model.isWorking {
            return "Delta, backup running"
        }
        guard let latestBackupStatus else {
            return "Delta, ready"
        }
        return "Delta, last backup \(latestBackupStatus.rawValue)"
    }

    private var latestBackupStatus: JobStatus? {
        model.jobs
            .filter { $0.kind == .backup }
            .max { $0.startedAt < $1.startedAt }?
            .status
    }
}
