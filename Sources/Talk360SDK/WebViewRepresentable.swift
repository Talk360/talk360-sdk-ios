import SwiftUI
import WebKit
import Shared

struct WebViewRepresentable: UIViewRepresentable {

    let config: Talk360BootConfig
    let session: Session
    let dismiss: () -> Void
    let purchaseFlowRelay: PurchaseFlowRelay
    let eventDelegate: (any Talk360EventDelegate)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            dismiss: dismiss,
            brandColors: config.brandColors,
            purchaseFlowRelay: purchaseFlowRelay,
            eventDelegate: eventDelegate
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let webConfig = WKWebViewConfiguration()
        webConfig.allowsInlineMediaPlayback = true

        let bootScript = BootScriptBuilder.shared.build(
            tenantId: config.tenantId,
            accountId: session.accountId,
            sipToken: session.sipToken,
            locale: config.locale,
            theme: config.theme.value,
            destination: config.destination,
            brandColors: config.brandColors?.toKmp()
        )
        #if DEBUG
        print("[Talk360SDK] Boot config — tenantId: \(config.tenantId), locale: \(config.locale), theme: \(config.theme.value)")
        #endif

        webConfig.userContentController.addUserScript(WKUserScript(
            source: bootScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        webConfig.userContentController.addUserScript(WKUserScript(
            source: Talk360DeviceShim.script(for: context.coordinator.registeredMethods()),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        webConfig.userContentController.add(context.coordinator, name: Talk360DeviceShim.handlerName)

        let webView = WKWebView(frame: .zero, configuration: webConfig)
        if let color = config.brandColors?.background {
            webView.isOpaque = false
            webView.backgroundColor = color
        }
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView

        #if DEBUG
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        #endif

        guard let url = URL(string: config.environment.dialerBaseUrl + config.tenantId) else {
            assertionFailure("Invalid dialer URL")
            return webView
        }
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(
            forName: Talk360DeviceShim.handlerName
        )
        uiView.uiDelegate = nil
        coordinator.webView = nil
    }
}

extension WebViewRepresentable {

    final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate {

        private let bridgeHandler = Talk360DialerJSBridgeHandler()
        private let webRtcProvider = Talk360WebRtcProviderImpl()
        private let nativeProvider: IosTalk360NativeProvider
        private var dialerManager: Talk360DialerManager?
        private let purchaseFlowRelay: PurchaseFlowRelay
        private weak var eventDelegate: (any Talk360EventDelegate)?
        weak var webView: WKWebView?

        init(
            dismiss: @escaping () -> Void,
            brandColors: Talk360BrandColors? = nil,
            purchaseFlowRelay: PurchaseFlowRelay,
            eventDelegate: (any Talk360EventDelegate)?
        ) {
            self.purchaseFlowRelay = purchaseFlowRelay
            self.eventDelegate = eventDelegate
            let provider = IosTalk360NativeProvider(onClose: dismiss, brandColors: brandColors)
            nativeProvider = provider
            super.init()

            bridgeHandler.setPurchaseFlowHandler { [weak self] in
                guard let self else { return }
                guard let delegate = self.eventDelegate else {
                    print("[Talk360SDK] triggerPurchaseFlow received but no eventDelegate is set — onPurchaseFlowRequested will not be called")
                    return
                }
                guard let vc = purchaseFlowRelay.viewController else {
                    print("[Talk360SDK] triggerPurchaseFlow received but the dialer VC is no longer available — onPurchaseFlowRequested will not be called")
                    return
                }
                delegate.onPurchaseFlowRequested(from: vc) { [weak self] in
                    self?.bridgeHandler.onNativeLifecycleResumed()
                }
            }

            provider.onPresent = { [weak self] vc in
                #if DEBUG
                if self?.webView?.window == nil {
                    print("[Talk360SDK] onPresent called but webView has no window — VC may not present")
                }
                #endif
                self?.webView?.parentViewController?.present(vc, animated: true)
            }

            provider.onSetStatusBarStyle = { [weak self] backgroundColor, style in
                if let vc = self?.webView?.parentViewController as? DialerViewController {
                    vc.applyStatusBarStyle(backgroundColor: backgroundColor, style: style)
                }
            }

            bridgeHandler.registerCallMethodHandler { [weak self] name, params in
                self?.evaluateCallback(name: name, params: params)
            }

            dialerManager = Talk360DialerManager(
                jsBridgeHandler: bridgeHandler,
                nativeProvider: nativeProvider,
                webRtcProvider: webRtcProvider
            )
        }

        deinit {
            let provider = webRtcProvider
            DispatchQueue.main.async { provider.disposeWebRTC() }
        }

        func registeredMethods() -> [String] {
            bridgeHandler.getAllMethods()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let functionName = body["function"] as? String else { return }
            let arguments = body["arguments"] as? [Any] ?? []
            #if DEBUG
            let argKeys: String
            if let firstArg = arguments.first as? [String: Any] {
                argKeys = firstArg.keys.sorted().joined(separator: ",")
            } else {
                argKeys = "<no args>"
            }
            print("[Talk360SDK][JS\u{2192}Native] \(functionName) args=[\(argKeys)]")
            #endif
            let array = KotlinArray<AnyObject>(size: Int32(arguments.count)) { i in
                arguments[Int(truncating: i)] as AnyObject
            }
            bridgeHandler.callMethod(name: functionName, arguments: array)
        }

        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            guard type == .microphone else {
                decisionHandler(.deny)
                return
            }
            if nativeProvider.isMicrophonePermissionGranted {
                decisionHandler(.grant)
            } else {
                decisionHandler(.deny)
            }
        }

        private func evaluateCallback(name: String, params: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: params),
                  let json = String(data: data, encoding: .utf8) else { return }
            #if DEBUG
            print("[Talk360SDK][Native\u{2192}JS] \(name)")
            #endif
            let safeName = name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            (function() {
              if (typeof window["\(safeName)"] === "function") {
                window["\(safeName)"](\(json));
              }
            })();
            """
            DispatchQueue.main.async { [weak self] in
                self?.webView?.evaluateJavaScript(script) { _, error in
                    if let error {
                        print("[Talk360SDK] JS callback '\(name)' failed: \(error)")
                    }
                }
            }
        }
    }
}

private extension Talk360BrandColors {
    func toKmp() -> BrandColors {
        BrandColors(
            primary: primary?.cssHexString,
            secondary: secondary?.cssHexString,
            background: background?.cssHexString,
            textOnPrimary: textOnPrimary?.cssHexString,
            textPrimary: textPrimary?.cssHexString
        )
    }
}

private extension UIView {
    var parentViewController: UIViewController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return nil
    }
}
