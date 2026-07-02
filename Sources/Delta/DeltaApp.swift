import DeltaCore
import SwiftUI

@main
struct DeltaApp: App {
    @StateObject private var model = DeltaAppModel()
    @StateObject private var softwareUpdateController = SoftwareUpdateController()
    @StateObject private var statusItemController = DeltaStatusItemController()
    @AppStorage(
        DeltaAppPreferenceKeys.showsMenuBarExtra,
        store: DeltaAppPreferences.sharedStore()
    ) private var showsMenuBarExtra = true

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(softwareUpdateController)
                .frame(minWidth: 1120, minHeight: 720)
                .background(
                    DeltaStatusItemInstaller(
                        controller: statusItemController,
                        model: model,
                        softwareUpdateController: softwareUpdateController,
                        isVisible: showsMenuBarExtra
                    )
                )
        }
        .windowStyle(.hiddenTitleBar)
    }
}
