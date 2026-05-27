import UIKit

protocol ProximityDevice {
    var isProximityMonitoringEnabled: Bool { get set }
}

extension UIDevice: ProximityDevice {}

final class ProximitySensorProvider {
    let managesProximity: Bool
    private var device: any ProximityDevice
    private var enabledCount: Int

    init(managesProximity: Bool, device: any ProximityDevice = UIDevice.current) {
        self.managesProximity = managesProximity
        self.device = device
        self.enabledCount = 0
    }
}

extension ProximitySensorProvider: ProximitySensorProviderProtocol {
    var isMonitoringEnabled: Bool {
        return enabledCount > 0
    }

    func incrementEnabledCount() {
        assert(Thread.isMainThread)
        guard managesProximity else { return }
        enabledCount += 1
        if enabledCount == 1 {
            device.isProximityMonitoringEnabled = true
        }
    }

    func decrementEnabledCount() {
        assert(Thread.isMainThread)
        guard managesProximity, enabledCount > 0 else { return }
        enabledCount -= 1
        if enabledCount == 0 {
            device.isProximityMonitoringEnabled = false
        }
    }
}
