import AVFoundation
import Shared
import WebRTC

// Public methods must be called on the main thread. This is guaranteed by the bridge
// call paths (WKScriptMessageHandler delivers on main) and the notification observer
// being registered with queue: .main. stop() called from deinit is tolerant of
// off-main execution in practice (removeObserver and setActive are thread-safe).
//
// When the user explicitly requests RECEIVER, it stays on RECEIVER even if a Bluetooth
// headset connects mid-call. Auto-switch to BT only applies when no explicit preference
// has been set.
//
// When callKitEnabled is true, setActive(true/false) is never called directly — CallKit
// owns the audio session and signals activation via didActivate / didDeactivate callbacks,
// which call activateAudioSession / deactivateAudioSession respectively.
final class IosTalk360AudioDeviceManager {

    private let callKitEnabled: Bool

    private var listener: ((NativeAudioDeviceState) -> Void)?
    private var interruptionListener: ((String) -> Void)?
    private var resumedListener: (() -> Void)?
    private var started = false
    private var isInterrupted = false
    private var requestedDeviceType: String?
    private var currentState: NativeAudioDeviceState?
    private var routeChangeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    init(callKitEnabled: Bool) {
        self.callKitEnabled = callKitEnabled
    }

    func setListener(_ listener: ((NativeAudioDeviceState) -> Void)?) {
        self.listener = listener
    }

    func setInterruptionListener(_ listener: ((String) -> Void)?) {
        self.interruptionListener = listener
    }

    func setResumedListener(_ listener: (() -> Void)?) {
        self.resumedListener = listener
    }

    func start() {
        guard !started else { return }
        started = true

        let session = AVAudioSession.sharedInstance()
        tryAudio("setCategory") { try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth]) }

        if !callKitEnabled {
            tryAudio("setActive(true)") { try session.setActive(true) }
        }
        // CallKit-enabled path: setActive(true) is deferred to activateAudioSession(),
        // called from CXProviderDelegate.provider(_:didActivate:).

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        requestedDeviceType = nil
        currentState = nil

        if !callKitEnabled {
            applyDevice(pickInitialRoute())
            emit(force: true)
        }
        // CallKit-enabled path: routing is applied inside activateAudioSession().
    }

    /// Called when the CXStartCallAction transaction is rejected so audio works despite CallKit failing.
    func activateAudioFallback() {
        guard started else { return }
        isInterrupted = false
        let session = AVAudioSession.sharedInstance()
        tryAudio("setActive(true) fallback") { try session.setActive(true) }
        RTCAudioSession.sharedInstance().audioSessionDidActivate(session)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
        applyDevice(requestedDeviceType ?? pickInitialRoute())
        emit(force: true)
    }

    /// Called from CXProviderDelegate.provider(_:didActivate:) when CallKit grants the audio session.
    func activateAudioSession(_ audioSession: AVAudioSession) {
        guard started else { return }
        RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
        applyDevice(requestedDeviceType ?? pickInitialRoute())
        emit(force: true)
        if isInterrupted {
            isInterrupted = false
            resumedListener?()
        }
    }

    /// Called from CXProviderDelegate.provider(_:didDeactivate:) when CallKit releases the audio session.
    func deactivateAudioSession(_ audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
    }

    func stop() {
        guard started else { return }
        started = false
        isInterrupted = false

        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }

        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }

        requestedDeviceType = nil
        currentState = nil

        if !callKitEnabled {
            tryAudio("setActive(false)") {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
        // CallKit-enabled path: setActive(false) is handled by CallKit via didDeactivate.
    }

    func setAudioDevice(_ deviceType: String) {
        guard started else { return }
        let types = Talk360DialerJSBridgeHandler.AudioDeviceType.shared
        guard deviceType == types.SPEAKER || deviceType == types.RECEIVER || deviceType == types.BLUETOOTH else { return }
        requestedDeviceType = deviceType
        applyDevice(deviceType)
        emit(force: true)
    }

    // MARK: - Private

    private func pickInitialRoute() -> String {
        let types = Talk360DialerJSBridgeHandler.AudioDeviceType.shared
        return hasBluetoothDevice() ? types.BLUETOOTH : types.RECEIVER
    }

    private func applyDevice(_ deviceType: String) {
        let types = Talk360DialerJSBridgeHandler.AudioDeviceType.shared
        let session = AVAudioSession.sharedInstance()
        switch deviceType {
        case types.SPEAKER:
            tryAudio("overrideOutputAudioPort(.speaker)") { try session.overrideOutputAudioPort(.speaker) }
        case types.RECEIVER:
            tryAudio("overrideOutputAudioPort(.none)") { try session.overrideOutputAudioPort(.none) }
            tryAudio("setPreferredInput(nil)") { try session.setPreferredInput(nil) }
        case types.BLUETOOTH:
            tryAudio("overrideOutputAudioPort(.none)") { try session.overrideOutputAudioPort(.none) }
            if let btInput = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
                tryAudio("setPreferredInput(bt)") { try session.setPreferredInput(btInput) }
            }
        default:
            break
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard started else { return }
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            isInterrupted = true
            interruptionListener?(Talk360DialerJSBridgeHandler.AudioInterruptionReason.shared.DEFAULT)
        case .ended:
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
            guard options.contains(.shouldResume) else { return }
            // CallKit path: didActivate will re-grant the session; activateAudioSession() handles resume.
            guard !callKitEnabled else { return }
            isInterrupted = false
            tryAudio("setActive(true) after interruption") {
                try AVAudioSession.sharedInstance().setActive(true)
            }
            resumedListener?()
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard started else { return }
        guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange:
            reconcileAfterSystemChange()
        case .override:
            // Route settled after applyDevice()'s async overrideOutputAudioPort/setPreferredInput — don't re-apply (loop).
            emit()
        default:
            break
        }
    }

    private func reconcileAfterSystemChange() {
        let types = Talk360DialerJSBridgeHandler.AudioDeviceType.shared

        let target: String
        switch requestedDeviceType {
        case types.SPEAKER:
            target = types.SPEAKER
        case types.RECEIVER:
            target = types.RECEIVER
        case types.BLUETOOTH:
            target = hasBluetoothDevice() ? types.BLUETOOTH : types.RECEIVER
        default:
            target = hasBluetoothDevice() ? types.BLUETOOTH : types.RECEIVER
        }

        applyDevice(target)
        emit()
    }

    private func effectiveDeviceType() -> String {
        let types = Talk360DialerJSBridgeHandler.AudioDeviceType.shared
        for output in AVAudioSession.sharedInstance().currentRoute.outputs {
            switch output.portType {
            case .bluetoothHFP:
                return types.BLUETOOTH
            case .builtInSpeaker:
                return types.SPEAKER
            default:
                continue
            }
        }
        return types.RECEIVER
    }

    private func currentAudioState() -> NativeAudioDeviceState {
        NativeAudioDeviceState(
            deviceType: effectiveDeviceType(),
            bluetoothAvailable: hasBluetoothDevice()
        )
    }

    private func emit(force: Bool = false) {
        let state = currentAudioState()
        guard force || state != currentState else { return }
        currentState = state
        listener?(state)
    }

    // HFP inputs are preferred for voice calls; also check current route outputs for BT.
    private func hasBluetoothDevice() -> Bool {
        let session = AVAudioSession.sharedInstance()
        let hasHfpInput = session.availableInputs?.contains { $0.portType == .bluetoothHFP } ?? false
        let hasBtOutput = session.currentRoute.outputs.contains {
            $0.portType == .bluetoothHFP || $0.portType == .bluetoothA2DP || $0.portType == .bluetoothLE
        }
        return hasHfpInput || hasBtOutput
    }

    private func tryAudio(_ op: String, _ block: () throws -> Void) {
        do { try block() } catch {
            #if DEBUG
            print("[Talk360SDK] AVAudioSession \(op) failed: \(error)")
            #endif
        }
    }
}
