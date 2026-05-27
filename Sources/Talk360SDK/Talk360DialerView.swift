import SwiftUI

public struct Talk360DialerView: UIViewControllerRepresentable {

    private let config: Talk360BootConfig
    private let eventDelegate: (any Talk360EventDelegate)?

    public init(config: Talk360BootConfig, eventDelegate: (any Talk360EventDelegate)? = nil) {
        self.config = config
        self.eventDelegate = eventDelegate
    }

    public func makeUIViewController(context: Context) -> UIViewController {
        DialerViewController(config: config, eventDelegate: eventDelegate)
    }

    public func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // Talk360BootConfig is consumed once at creation; mid-session updates are not supported.
    }
}
