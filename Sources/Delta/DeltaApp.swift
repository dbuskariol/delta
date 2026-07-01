import SwiftUI

@main
struct DeltaApp: App {
    @StateObject private var model = DeltaAppModel()
    @StateObject private var softwareUpdateController = SoftwareUpdateController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(softwareUpdateController)
                .frame(minWidth: 1120, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("Delta", systemImage: "externaldrive.badge.checkmark") {
            Button("Run Due Backups") {
                model.runDueBackups()
            }
            Button("Refresh") {
                model.reload()
            }
            Button("Check for Updates...") {
                softwareUpdateController.checkForUpdates()
            }
            Divider()
            Button("Quit Delta") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
