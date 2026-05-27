import SwiftUI
import UIKit

final class DialerViewController: UIHostingController<DialerView> {

    private var resolvedStatusBarStyle: UIStatusBarStyle = .default
    private var statusBarBackgroundView: UIView?

    override var preferredStatusBarStyle: UIStatusBarStyle { resolvedStatusBarStyle }
    // Returning nil ensures UIKit queries this controller's preferredStatusBarStyle directly
    // rather than delegating to a SwiftUI-managed child inside UIHostingController.
    override var childForStatusBarStyle: UIViewController? { nil }

    init(config: Talk360BootConfig, eventDelegate: (any Talk360EventDelegate)?) {
        let relay = PurchaseFlowRelay()
        super.init(rootView: DialerView(config: config, purchaseFlowRelay: relay, eventDelegate: eventDelegate))
        relay.viewController = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func applyStatusBarStyle(backgroundColor: UIColor?, style: UIStatusBarStyle?) {
        if let color = backgroundColor {
            let bgView = statusBarBackgroundView ?? makeStatusBarBackgroundView()
            bgView.backgroundColor = color
        }
        if let style {
            resolvedStatusBarStyle = style
            setNeedsStatusBarAppearanceUpdate()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || isMovingFromParent {
            restoreStatusBar()
        }
    }

    private func makeStatusBarBackgroundView() -> UIView {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: view.topAnchor),
            v.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        ])
        statusBarBackgroundView = v
        return v
    }

    private func restoreStatusBar() {
        statusBarBackgroundView?.removeFromSuperview()
        statusBarBackgroundView = nil
    }
}
