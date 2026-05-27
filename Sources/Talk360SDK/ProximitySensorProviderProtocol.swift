import Foundation

protocol ProximitySensorProviderProtocol {
    var isMonitoringEnabled: Bool { get }
    func incrementEnabledCount()
    func decrementEnabledCount()
}
