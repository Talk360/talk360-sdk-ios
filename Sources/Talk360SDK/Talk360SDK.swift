import UIKit

public final class Talk360SDK {

    private init() {}

    public static func presentDialer(
        from viewController: UIViewController,
        config: Talk360BootConfig,
        eventDelegate: (any Talk360EventDelegate)? = nil
    ) {
        let dialer = DialerViewController(config: config, eventDelegate: eventDelegate)
        dialer.modalPresentationStyle = .fullScreen
        viewController.present(dialer, animated: true)
    }
}
