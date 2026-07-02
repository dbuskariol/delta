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

        MenuBarExtra("Delta", systemImage: "externaldrive.badge.checkmark", isInserted: $showsMenuBarExtra) {
            DeltaMenuBarView()
                .environmentObject(model)
                .environmentObject(softwareUpdateController)
                .frame(width: 340)
        }
        .menuBarExtraStyle(.window)
    }
}
