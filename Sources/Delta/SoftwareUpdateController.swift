import DeltaCore
import Foundation
import Sparkle
import SwiftUI

@MainActor
final class SoftwareUpdateController: ObservableObject {
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        applyStoredPreferences()
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            updaterController.updater.automaticallyChecksForUpdates
        }
        set {
            updaterController.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var updateCheckInterval: TimeInterval {
        get {
            updaterController.updater.updateCheckInterval
        }
        set {
            updaterController.updater.updateCheckInterval = newValue
        }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    private func applyStoredPreferences() {
        let intervalRawValue = DeltaAppPreferences.integer(
            for: DeltaAppPreferenceKeys.updateCheckIntervalSeconds,
            default: AppUpdateCheckInterval.daily.rawValue
        )
        updaterController.updater.updateCheckInterval = TimeInterval(
            AppUpdateCheckInterval.normalized(intervalRawValue).rawValue
        )
    }
}
