import DeltaCore
import Foundation
import Sparkle
import SwiftUI

@MainActor
final class SoftwareUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    typealias ReadinessProvider = @MainActor () -> DeltaSoftwareUpdateReadiness
    typealias BlockedHandler = @MainActor (DeltaSoftwareUpdateReadiness, String) -> Void

    private var updaterController: SPUStandardUpdaterController!
    private let readinessProvider: ReadinessProvider
    private let blockedHandler: BlockedHandler
    private var postponedInstallHandler: (() -> Void)?
    private var timeMachineTransitionIsReserved = false
    @Published private(set) var automaticUpdateReadyForInstall = false

    init(
        readinessProvider: @escaping ReadinessProvider,
        blockedHandler: @escaping BlockedHandler
    ) {
        self.readinessProvider = readinessProvider
        self.blockedHandler = blockedHandler
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
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

    var automaticallyDownloadsUpdates: Bool {
        get {
            updaterController.updater.automaticallyDownloadsUpdates
        }
        set {
            updaterController.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    var allowsAutomaticUpdates: Bool {
        updaterController.updater.allowsAutomaticUpdates
    }

    var canCheckForUpdates: Bool {
        readinessProvider().allowsUpdate
            && !timeMachineTransitionIsReserved
            && updaterController.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        let readiness = readinessProvider()
        guard readiness.allowsUpdate, !timeMachineTransitionIsReserved else {
            presentBlocked(readiness)
            return
        }
        updaterController.checkForUpdates(nil)
    }

    var updateSafetyDetail: String? {
        let readiness = readinessProvider()
        guard !readiness.allowsUpdate else { return nil }
        return message(for: readiness)
    }

    var timeMachineConnectionBlockMessage: String? {
        if automaticUpdateReadyForInstall || postponedInstallHandler != nil {
            return "A verified Delta update is ready to install. Quit and reopen Delta to finish the update before connecting a Time Machine disk."
        }
        if updaterController.updater.sessionInProgress {
            return "Wait for Delta's current update check or download to finish before connecting a Time Machine disk."
        }
        return nil
    }

    /// Closes the main-actor gap between a button action and the model's
    /// persisted `.preparing` / `.disconnecting` state. Sparkle consults the
    /// same reservation before beginning an update session.
    func reserveTimeMachineSystemTransition() {
        timeMachineTransitionIsReserved = true
        objectWillChange.send()
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.timeMachineTransitionIsReserved = false
            self.applicationSafetyDidChange()
        }
    }

    func applicationSafetyDidChange() {
        objectWillChange.send()
        guard
            readinessProvider().allowsUpdate,
            !timeMachineTransitionIsReserved,
            let installHandler = postponedInstallHandler
        else {
            return
        }
        postponedInstallHandler = nil
        installHandler()
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        let readiness = readinessProvider()
        guard readiness.allowsUpdate, !timeMachineTransitionIsReserved else {
            throw NSError(
                domain: "com.delta.backup.software-update",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message(for: readiness)]
            )
        }
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        let readiness = readinessProvider()
        guard !readiness.allowsUpdate || timeMachineTransitionIsReserved else {
            return false
        }
        postponedInstallHandler = installHandler
        presentBlocked(readiness)
        return true
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        // Connection is blocked while this flag is set. Returning false keeps
        // Sparkle's normal install-on-quit behavior instead of surprising the
        // user with an immediate relaunch.
        automaticUpdateReadyForInstall = true
        return false
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

    private func presentBlocked(_ readiness: DeltaSoftwareUpdateReadiness) {
        blockedHandler(readiness, message(for: readiness))
    }

    private func message(for readiness: DeltaSoftwareUpdateReadiness) -> String {
        switch readiness {
        case .ready:
            return "Finish the current Time Machine system transition before updating Delta."
        case .applicationStateUnavailable:
            return "Delta cannot verify that backups are idle because its local state is unavailable. Repair local data access before updating."
        case .operationInProgress:
            return "Finish the current backup, restore, or maintenance operation before updating Delta."
        case .timeMachineDestinationsConnected:
            return "Safely disconnect every Time Machine disk before checking for or installing a Delta update."
        }
    }
}
