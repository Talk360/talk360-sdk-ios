import Foundation
import Network

/// Watches the active network transport (WiFi / cellular / wired) and notifies `onTransportChanged`
/// when it switches between transports **or** when the network recovers from a total loss.
///
/// The first observed transport is treated as the baseline and does not fire the callback.
/// Single-use: `NWPathMonitor` cannot be restarted after `cancel()`. Create a new instance instead of calling `start()` again after `stop()`.
internal final class IosNetworkChangeMonitor {

    private enum Transport: Equatable {
        case wifi
        case cellular
        case wired
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.talk360.sdk.network-monitor")
    private let onTransportChanged: () -> Void

    private var currentTransport: Transport?
    private var hasBaseline = false
    private var networkLost = false
    private var running = false

    init(onTransportChanged: @escaping () -> Void) {
        self.onTransportChanged = onTransportChanged
    }

    func start() {
        guard !running else { return }
        running = true
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path: path)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard running else { return }
        running = false
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        // Reset state on the monitor queue so any in-flight handle() completes first.
        queue.async { [weak self] in
            self?.currentTransport = nil
            self?.hasBaseline = false
            self?.networkLost = false
        }
    }

    private func handle(path: NWPath) {
        guard path.status == .satisfied else {
            if currentTransport != nil {
                #if DEBUG
                print("[Talk360SDK][NetMonitor] network lost (transport=\(String(describing: currentTransport)))")
                #endif
                networkLost = true
            }
            currentTransport = nil
            return
        }
        guard let transport = dominantTransport(in: path) else { return }

        let previous = currentTransport
        let wasLost = networkLost
        let isFirstObservation = !hasBaseline

        currentTransport = transport
        networkLost = false
        hasBaseline = true

        // Never fire on the very first network we observe — that's the baseline.
        if isFirstObservation { return }

        // Fire on recovery from full network loss, or on a real transport switch.
        if wasLost || (previous != nil && previous != transport) {
            #if DEBUG
            print("[Talk360SDK][NetMonitor] transport change: prev=\(String(describing: previous)) new=\(transport) wasLost=\(wasLost)")
            #endif
            Task { @MainActor [weak self] in
                self?.onTransportChanged()
            }
        }
    }

    private func dominantTransport(in path: NWPath) -> Transport? {
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return nil
    }
}
