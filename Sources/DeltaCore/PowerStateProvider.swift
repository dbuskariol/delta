import Foundation

#if canImport(IOKit)
import IOKit.ps
#endif

public struct PowerState: Equatable, Sendable {
    public var isOnBatteryPower: Bool
    public var isLowPowerModeEnabled: Bool

    public init(isOnBatteryPower: Bool, isLowPowerModeEnabled: Bool) {
        self.isOnBatteryPower = isOnBatteryPower
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }
}

public struct PowerStateProvider: Sendable {
    private var currentPowerState: @Sendable () -> PowerState

    public init(currentPowerState: (@Sendable () -> PowerState)? = nil) {
        self.currentPowerState = currentPowerState ?? {
            PowerState(
                isOnBatteryPower: Self.isOnBatteryPower(),
                isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
        }
    }

    public func current() -> PowerState { currentPowerState() }

    private static func isOnBatteryPower() -> Bool {
        #if canImport(IOKit)
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return false
        }

        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                let state = description[kIOPSPowerSourceStateKey] as? String,
                state == kIOPSBatteryPowerValue
            else {
                continue
            }
            return true
        }
        #endif
        return false
    }
}
