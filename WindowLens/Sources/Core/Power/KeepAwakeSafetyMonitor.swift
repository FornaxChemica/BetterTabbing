import AppKit
import Foundation
import IOKit
import IOKit.ps

/// Lid, battery, and thermal guards for Stay Awake.
@MainActor
final class KeepAwakeSafetyMonitor: ObservableObject {
    static let shared = KeepAwakeSafetyMonitor()

    @Published private(set) var isLidClosed = false
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var isOnACPower = true
    @Published private(set) var cpuTemperatureC: Double?
    @Published private(set) var isRunningHot = false

    private var timer: Timer?
    private var lastLidClosed = false
    private var onLidClosed: (() -> Void)?
    private var onBatteryUnsafe: ((String) -> Void)?
    private var onThermalChanged: ((Bool, String?) -> Void)?

    private let batteryFloorPercent: Int
    private let thermalHotC: Double = 95
    private let thermalCriticalC: Double = 100

    private init(batteryFloorPercent: Int = 20) {
        self.batteryFloorPercent = batteryFloorPercent
    }

    func start(
        onLidClosed: @escaping () -> Void,
        onBatteryUnsafe: @escaping (String) -> Void,
        onThermalChanged: @escaping (_ isHot: Bool, _ message: String?) -> Void
    ) {
        self.onLidClosed = onLidClosed
        self.onBatteryUnsafe = onBatteryUnsafe
        self.onThermalChanged = onThermalChanged
        stopTimersOnly()
        refresh()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        stopTimersOnly()
        onLidClosed = nil
        onBatteryUnsafe = nil
        onThermalChanged = nil
    }

    private func stopTimersOnly() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let lidClosed = Self.readClamshellClosed()
        if lidClosed && !lastLidClosed {
            onLidClosed?()
        }
        lastLidClosed = lidClosed
        isLidClosed = lidClosed

        let power = Self.readPowerState()
        batteryPercent = power.percent
        isOnACPower = power.onAC

        if let percent = power.percent, !power.onAC, percent <= batteryFloorPercent {
            onBatteryUnsafe?("Battery reached \(percent)%. Stay Awake ended to protect your Mac.")
            return
        }

        let thermal = ProcessResourceMonitor.shared.thermalInfo()
        cpuTemperatureC = thermal.temperature

        let hot: Bool
        var message: String?
        if let temp = thermal.temperature, temp >= thermalCriticalC {
            hot = true
            message = "CPU reached \(Int(temp))°C."
        } else if let temp = thermal.temperature, temp >= thermalHotC {
            hot = true
            message = "Mac is running hot (\(Int(temp))°C)."
        } else if thermal.state == .critical || thermal.state == .serious {
            hot = true
            message = "System thermal state is elevated."
        } else {
            hot = false
            message = nil
        }

        let changed = hot != isRunningHot
        isRunningHot = hot
        if changed || hot {
            onThermalChanged?(hot, message)
        }
    }

    private static func readClamshellClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return false
        }

        if let number = property as? NSNumber {
            return number.boolValue
        }
        if let bool = property as? Bool {
            return bool
        }
        return false
    }

    private static func readPowerState() -> (percent: Int?, onAC: Bool) {
        let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] ?? []
        var percent: Int?
        var onAC = true

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if let capacity = info[kIOPSCurrentCapacityKey] as? Int {
                percent = capacity
            }
            if let state = info[kIOPSPowerSourceStateKey] as? String {
                onAC = state == kIOPSACPowerValue
            }
        }

        return (percent, onAC)
    }
}
