import SwiftUI

@main
struct DeltaApp: App {
    @StateObject private var model = DeltaAppModel()
    @StateObject private var softwareUpdateController = SoftwareUpdateController()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(softwareUpdateController)
                .frame(minWidth: 1120, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            DeltaMenuBarView()
                .environmentObject(model)
                .environmentObject(softwareUpdateController)
                .frame(width: 340)
        } label: {
            Label("Delta", systemImage: model.isWorking ? "arrow.triangle.2.circlepath" : "externaldrive.badge.checkmark")
        }
        .menuBarExtraStyle(.window)
    }
}
