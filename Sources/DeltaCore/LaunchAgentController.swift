import Foundation

#if canImport(ServiceManagement)
import ServiceManagement
#endif

public enum LaunchAgentController {
    public static let defaultPlistName = "com.delta.backup.agent.plist"

    public static func register(plistName: String = defaultPlistName) throws {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            try SMAppService.agent(plistName: plistName).register()
        }
        #endif
    }

    public static func unregister(plistName: String = defaultPlistName) throws {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            try SMAppService.agent(plistName: plistName).unregister()
        }
        #endif
    }

    public static func status(plistName: String = defaultPlistName) -> String {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            return "\(SMAppService.agent(plistName: plistName).status)"
        }
        #endif
        return "unavailable"
    }
}

public enum FullDiskAccessGuide {
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
