import AppKit
import Combine
import DeltaCore
import SwiftUI

@MainActor
final class DeltaStatusItemController: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var model: DeltaAppModel?
    private var softwareUpdateController: SoftwareUpdateController?
    private var openApp: ((DeltaAppModel.Section) -> Void)?
    private var modelSubscription: AnyCancellable?

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = true
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
        popover.performClose(nil)
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    private func installPopoverContent() {
        guard let model, let softwareUpdateController else { return }

        let rootView = DeltaMenuBarView { [weak self] section in
            self?.popover.performClose(nil)
            self?.openApp?(section)
        }
        .environmentObject(model)
        .environmentObject(softwareUpdateController)
        .frame(width: 340)

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
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private var statusSymbolName: String {
        guard let model, model.isPersistentStoreAvailable else {
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

    private var accessibilityLabel: String {
        guard let model, model.isPersistentStoreAvailable else {
            return "Delta, storage unavailable"
        }
        if model.isWorking {
            return "Delta, backup running"
        }
        guard let latestBackupStatus else {
            return "Delta, ready"
        }
        return "Delta, last backup \(latestBackupStatus.displayName)"
    }

    private var latestBackupStatus: JobStatus? {
        model?.jobs
            .filter { $0.kind == .backup }
            .max { $0.startedAt < $1.startedAt }?
            .status
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
