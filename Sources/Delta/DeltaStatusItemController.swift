import AppKit
import Combine
import DeltaCore
import SwiftUI

@MainActor
final class DeltaStatusItemController: NSObject, ObservableObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var model: DeltaAppModel?
    private var softwareUpdateController: SoftwareUpdateController?
    private var openApp: ((DeltaAppModel.Section) -> Void)?
    private var modelSubscription: AnyCancellable?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    override init() {
        super.init()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
    }

    func configure(
        model: DeltaAppModel,
        softwareUpdateController: SoftwareUpdateController,
        isVisible: Bool,
        openApp: @escaping (DeltaAppModel.Section) -> Void
    ) {
        self.model = model
        self.softwareUpdateController = softwareUpdateController
        self.openApp = openApp

        if isVisible {
            installStatusItemIfNeeded()
            installPopoverContent()
            subscribeToModelChanges(model)
            updateStatusButton()
        } else {
            removeStatusItem()
        }
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    private func removeStatusItem() {
        closePopover()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    private func installPopoverContent() {
        guard let model, let softwareUpdateController else { return }

        let rootView = DeltaMenuBarView { [weak self] section in
            self?.closePopover()
            self?.openApp?(section)
        }
        .environmentObject(model)
        .environmentObject(softwareUpdateController)

        popover.contentViewController = NSHostingController(rootView: rootView)
    }

    private func subscribeToModelChanges(_ model: DeltaAppModel) {
        guard modelSubscription == nil else { return }
        modelSubscription = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateStatusButton()
            }
        }
    }

    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        let image = NSImage(
            systemSymbolName: statusSymbolName,
            accessibilityDescription: accessibilityLabel
        )
        image?.isTemplate = true
        button.image = image
        button.toolTip = accessibilityLabel
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            installDismissalEventMonitors()
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        removeDismissalEventMonitors()
    }

    private func installDismissalEventMonitors() {
        removeDismissalEventMonitors()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.isEventInsidePopoverOrStatusItem(event) {
                    self.closePopover()
                }
            }
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover()
            }
        }
    }

    private func removeDismissalEventMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removeDismissalEventMonitors()
    }

    private func isEventInsidePopoverOrStatusItem(_ event: NSEvent) -> Bool {
        guard let eventWindow = event.window else {
            return false
        }
        if eventWindow == popover.contentViewController?.view.window {
            return true
        }
        if eventWindow == statusItem?.button?.window {
            return true
        }
        return false
    }

    private var statusSymbolName: String {
        statusPresentation.symbolName
    }

    private var accessibilityLabel: String {
        statusPresentation.accessibilityLabel
    }

    private var statusPresentation: MenuBarStatusPresentation {
        MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: model?.isPersistentStoreAvailable ?? false,
            isWorking: model?.isWorking ?? false,
            activeJobKind: model?.activeOperation?.kind,
            latestBackupStatus: latestBackupRun?.status,
            acknowledgedOmissionCount: latestBackupRun.flatMap { model?.acknowledgedWarningIssueCounts[$0.id] }
        )
    }

    private var latestBackupRun: JobRun? {
        model?.jobs
            .filter { $0.kind == .backup }
            .max { $0.startedAt < $1.startedAt }
    }
}

struct DeltaStatusItemInstaller: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var controller: DeltaStatusItemController
    @ObservedObject var model: DeltaAppModel
    @ObservedObject var softwareUpdateController: SoftwareUpdateController
    var isVisible: Bool

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear(perform: configure)
            .onChange(of: isVisible) { _, _ in
                configure()
            }
    }

    private func configure() {
        controller.configure(
            model: model,
            softwareUpdateController: softwareUpdateController,
            isVisible: isVisible
        ) { section in
            model.selectedSection = section
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}
