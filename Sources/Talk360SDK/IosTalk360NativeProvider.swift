import AVFoundation
import Contacts
import ContactsUI
import UIKit
import Shared

final class IosTalk360NativeProvider: NSObject, Talk360NativeProvider {

    private let onClose: () -> Void
    private let strings = StringProvider()
    private let brandColors: Talk360BrandColors?
    var onPresent: ((UIViewController) -> Void)?
    var onSetStatusBarStyle: ((UIColor?, UIStatusBarStyle?) -> Void)?

    private let callKitProvider: IosTalk360CallKitProvider
    private let audioDeviceManager: IosTalk360AudioDeviceManager
    private let proximitySensorProvider: any ProximitySensorProviderProtocol
    private var contactPickerDelegate: ContactPickerDelegate?
    private var pendingMicrophonePermissionCallback: ((String) -> Void)?
    private var foregroundObserver: NSObjectProtocol?
    private var isPermissionAlertPresented = false
    private var endCallListener: (() -> Void)?

    init(onClose: @escaping () -> Void, brandColors: Talk360BrandColors? = nil) {
        self.brandColors = brandColors
        self.onClose = onClose
        let callKit = IosTalk360CallKitProvider()
        self.callKitProvider = callKit
        self.audioDeviceManager = IosTalk360AudioDeviceManager(callKitEnabled: callKit.isEnabled)
        self.proximitySensorProvider = ProximitySensorProvider(managesProximity: !callKit.isEnabled)
        super.init()
        callKit.onCallEndedByCallKit = { [weak self] in self?.endCallListener?() }
        callKit.onAudioActivated = { [weak self] session in self?.audioDeviceManager.activateAudioSession(session) }
        callKit.onAudioDeactivated = { [weak self] session in self?.audioDeviceManager.deactivateAudioSession(session) }
        callKit.onCallKitFailed = { [weak self] in self?.audioDeviceManager.activateAudioFallback() }
    }

    deinit {
        while proximitySensorProvider.isMonitoringEnabled {
            proximitySensorProvider.decrementEnabledCount()
        }
        audioDeviceManager.stop()
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        pendingMicrophonePermissionCallback = nil
    }

    func close() {
        onClose()
    }

    // MARK: - Contact Picker

    func openContactPicker(onSelected: @escaping (String, String?) -> Void) {
        guard let present = onPresent else {
            #if DEBUG
            print("[Talk360SDK] openContactPicker: onPresent is not set — picker will not be shown")
            #endif
            return
        }
        guard contactPickerDelegate == nil else { return }
        let picker = CNContactPickerViewController()
        let delegate = ContactPickerDelegate(
            onSelected: onSelected,
            onFinished: { [weak self] in self?.contactPickerDelegate = nil }
        )
        contactPickerDelegate = delegate
        picker.delegate = delegate
        present(picker)
    }

    // MARK: - Microphone Permission

    func requestMicrophonePermission(onResult: @escaping (String) -> Void) {
        let states = Talk360DialerJSBridgeHandler.MicrophonePermissionState.shared
        let status = microphonePermissionStatus()
        if status == states.GRANTED {
            DispatchQueue.main.async { onResult(status) }
        } else if status == states.DENIED {
            DispatchQueue.main.async { [weak self] in self?.showMicrophoneSettingsAlert(onResult: onResult) }
        } else {
            requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    onResult(granted ? states.GRANTED : states.DENIED)
                }
            }
        }
    }

    var isMicrophonePermissionGranted: Bool {
        microphonePermissionStatus() == Talk360DialerJSBridgeHandler.MicrophonePermissionState.shared.GRANTED
    }

    // MARK: - Audio Device

    func setAudioDevice(deviceType: String) {
        audioDeviceManager.setAudioDevice(deviceType)
    }

    func setAudioDeviceChangedListener(listener: @escaping (NativeAudioDeviceState) -> Void) {
        audioDeviceManager.setListener(listener)
    }

    func setAudioInterruptedListener(listener: @escaping (String) -> Void) {
        audioDeviceManager.setInterruptionListener(listener)
    }

    func setAudioResumedListener(listener: @escaping () -> Void) {
        audioDeviceManager.setResumedListener(listener)
    }

    func setEndCallListener(listener: @escaping () -> Void) {
        endCallListener = listener
    }

    // MARK: - Status Bar

    func setStatusBarStyle(backgroundColor: String?, iconColor: String?) {
        let parsedBackground = backgroundColor.flatMap { UIColor(cssHex: $0) }
        let parsedStyle = iconColor.flatMap { UIColor(cssHex: $0) }.map { luminanceBasedStyle(for: $0) }
        onSetStatusBarStyle?(parsedBackground, parsedStyle)
    }

    // MARK: - Private helpers

    // Maps a color to the status bar style that keeps icons readable against it.
    // iOS only supports two styles; the iconColor hex from the web dialer is a luminance hint,
    // not a directly applied color. Dark background → .lightContent (white icons).
    private func luminanceBasedStyle(for color: UIColor) -> UIStatusBarStyle {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: nil)
        let linearize: (CGFloat) -> CGFloat = { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
        // High luminance (bright color, e.g. white) → .lightContent (white icons).
        // Low luminance (dark color, e.g. black) → .darkContent (dark icons).
        return luminance > 0.5 ? .lightContent : .darkContent
    }

    private func microphonePermissionStatus() -> String {
        let states = Talk360DialerJSBridgeHandler.MicrophonePermissionState.shared
        if #available(iOS 17, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return states.GRANTED
            case .denied: return states.DENIED
            case .undetermined: return states.UNDETERMINED
            @unknown default: return states.UNDETERMINED
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted: return states.GRANTED
            case .denied: return states.DENIED
            case .undetermined: return states.UNDETERMINED
            @unknown default: return states.UNDETERMINED
            }
        }
    }

    private func requestRecordPermission(completion: @escaping (Bool) -> Void) {
        if #available(iOS 17, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: completion)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(completion)
        }
    }

    private func showMicrophoneSettingsAlert(onResult: @escaping (String) -> Void) {
        // Alert already on screen or Settings redirect in flight — discard duplicate.
        guard !isPermissionAlertPresented && pendingMicrophonePermissionCallback == nil else {
            onResult(microphonePermissionStatus())
            return
        }
        let states = Talk360DialerJSBridgeHandler.MicrophonePermissionState.shared
        guard let present = onPresent else {
            onResult(states.DENIED)
            return
        }
        isPermissionAlertPresented = true
        let alert = UIAlertController(
            title: strings.string(.sdkMicrophonePermissionAlertTitle),
            message: strings.string(.sdkMicrophonePermissionAlertMessage),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: strings.string(.sdkMicrophonePermissionAlertCancel), style: .cancel) { [weak self] _ in
            self?.isPermissionAlertPresented = false
            onResult(states.DENIED)
        })
        alert.addAction(UIAlertAction(title: strings.string(.sdkMicrophonePermissionAlertOpenSettings), style: .default) { [weak self] _ in
            self?.isPermissionAlertPresented = false
            self?.pendingMicrophonePermissionCallback = onResult
            self?.openAppSettings()
        })
        if let primaryColor = brandColors?.primary {
            alert.view.tintColor = primaryColor
        }
        present(alert)
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        // If the app is killed while the user is in Settings, pendingMicrophonePermissionCallback
        // is never invoked. This is acceptable — JS state resets on next launch.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleReturnFromSettings()
        }
        UIApplication.shared.open(url)
    }

    private func handleReturnFromSettings() {
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
        guard let callback = pendingMicrophonePermissionCallback else { return }
        pendingMicrophonePermissionCallback = nil
        callback(microphonePermissionStatus())
    }

    func reportCallState(state: String, phoneNumber: String?, reason: String?) {
        let callState = Talk360DialerJSBridgeHandler.CallState.shared
        switch state {
        case callState.INITIATING:
            if !proximitySensorProvider.isMonitoringEnabled {
                proximitySensorProvider.incrementEnabledCount()
            }
            audioDeviceManager.start()
            if let number = phoneNumber, !number.isEmpty {
                callKitProvider.reportOutgoingCallStarted(phoneNumber: number)
            } else if callKitProvider.isEnabled {
                // CallKit path but no phone number: can't register with CXStartCallAction,
                // so activate the audio session directly rather than waiting for didActivate.
                audioDeviceManager.activateAudioFallback()
            }
            // Non-CallKit path: start() already called setActive(true) — nothing more needed.

        case callState.ACCEPTED:
            callKitProvider.reportOutgoingCallConnected()

        case callState.ENDED:
            // When endCallIfActive returns false, CallKit has no record of the call and
            // didDeactivate will never fire — deactivate manually to avoid leaving the session open.
            if !callKitProvider.endCallIfActive() && callKitProvider.isEnabled {
                audioDeviceManager.deactivateAudioSession(AVAudioSession.sharedInstance())
            }
            audioDeviceManager.stop()
            proximitySensorProvider.decrementEnabledCount()

        case callState.FAILED:
            callKitProvider.reportCallFailed()
            audioDeviceManager.stop()
            proximitySensorProvider.decrementEnabledCount()

        default:
            break
        }
    }
}

// MARK: - Contact Picker Delegate

private final class ContactPickerDelegate: NSObject, CNContactPickerDelegate {

    private let onSelected: (String, String?) -> Void
    private let onFinished: () -> Void

    init(onSelected: @escaping (String, String?) -> Void, onFinished: @escaping () -> Void) {
        self.onSelected = onSelected
        self.onFinished = onFinished
    }

    func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
        defer { onFinished() }
        guard let phoneNumber = contact.phoneNumbers.first?.value.stringValue else { return }
        let name = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        onSelected(phoneNumber, name.isEmpty ? nil : name)
    }

    func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
        onFinished()
    }
}
