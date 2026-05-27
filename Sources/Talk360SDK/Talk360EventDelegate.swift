import UIKit

/// The SDK holds this delegate weakly — the caller must retain it for the
/// lifetime of the dialer presentation.
public protocol Talk360EventDelegate: AnyObject {
    /// Called on the main thread when the web dialer requests a top-up.
    /// Present your purchase screen from the provided view controller and call
    /// `onComplete` when the flow finishes — the dialer refreshes the balance automatically.
    /// `onComplete` is safe to call from any thread.
    func onPurchaseFlowRequested(from viewController: UIViewController, onComplete: @escaping () -> Void)
}
