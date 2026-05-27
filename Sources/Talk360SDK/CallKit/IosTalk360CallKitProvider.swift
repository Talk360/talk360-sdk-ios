import AVFoundation
import CallKit
import WebRTC

final class IosTalk360CallKitProvider: NSObject {

    // MARK: - Static

    static var hasCallKitSupport: Bool {
        if #available(iOS 16, *) {
            return Locale.current.region?.identifier != "CN"
        } else {
            return Locale.current.regionCode != "CN"
        }
    }

    // MARK: - Properties

    let isEnabled: Bool

    var onCallEndedByCallKit: (() -> Void)?
    var onAudioActivated: ((AVAudioSession) -> Void)?
    var onAudioDeactivated: ((AVAudioSession) -> Void)?
    // Called when CXStartCallAction is rejected (e.g. missing entitlements, another active call).
    // The audio device manager falls back to direct session activation so audio still works.
    var onCallKitFailed: (() -> Void)?

    private let provider: CXProvider?
    private let controller: CXCallController?
    private let queue: DispatchQueue

    // Only read/written on main thread.
    private var currentCallUUID: UUID?

    // MARK: - Init

    init(isEnabled: Bool = IosTalk360CallKitProvider.hasCallKitSupport) {
        self.isEnabled = isEnabled

        let queue = DispatchQueue(label: "com.talk360.sdk.callkit", qos: .userInitiated)
        self.queue = queue

        if isEnabled {
            let config = CXProviderConfiguration()
            config.maximumCallGroups = 1
            config.maximumCallsPerCallGroup = 1
            config.supportedHandleTypes = [.phoneNumber]
            self.provider = CXProvider(configuration: config)
            self.controller = CXCallController(queue: queue)
            // Disable WebRTC's automatic audio engine so CallKit controls audio session
            // activation exclusively via didActivate / didDeactivate callbacks.
            // useManualAudio is intentionally never reset — it must stay true for the entire
            // process lifetime once set, as WebRTC does not support toggling it mid-session.
            // isAudioEnabled is re-enabled in audioSessionDidActivate / activateAudioFallback.
            RTCAudioSession.sharedInstance().useManualAudio = true
            RTCAudioSession.sharedInstance().isAudioEnabled = false
        } else {
            self.provider = nil
            self.controller = nil
        }

        super.init()

        provider?.setDelegate(self, queue: queue)
    }

    deinit {
        provider?.setDelegate(nil, queue: nil)
        provider?.invalidate()
    }

    // MARK: - Call lifecycle (must be called on main thread)

    func reportOutgoingCallStarted(phoneNumber: String) {
        guard isEnabled, let controller else { return }
        let uuid = UUID()
        currentCallUUID = uuid
        let handle = CXHandle(type: .phoneNumber, value: phoneNumber)
        let action = CXStartCallAction(call: uuid, handle: handle)
        controller.requestTransaction(with: action) { [weak self] error in
            guard let error else { return }
            #if DEBUG
            print("[Talk360SDK] CXStartCallAction failed: \(error) — falling back to direct audio activation")
            #endif
            DispatchQueue.main.async {
                guard self?.currentCallUUID == uuid else { return }
                self?.currentCallUUID = nil
                self?.onCallKitFailed?()
            }
        }
    }

    func reportOutgoingCallConnected() {
        guard isEnabled, let provider, let uuid = currentCallUUID else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: nil)
    }

    func reportCallFailed() {
        reportCallEnded(reason: .failed)
    }

    /// Call when reportCallState(ENDED) arrives and the local dialer UI initiated the hang-up.
    /// Clears currentCallUUID immediately so the CXEndCallAction delegate can distinguish
    /// app-initiated ends from CallKit-UI-initiated ends.
    /// Returns true if a CXEndCallAction was requested (didDeactivate will follow);
    /// false if CallKit had no record of the call (caller must deactivate audio manually).
    @discardableResult
    func endCallIfActive() -> Bool {
        guard isEnabled, let controller else { return false }
        guard let uuid = currentCallUUID else { return false }
        guard controller.callObserver.calls.contains(where: { $0.uuid == uuid }) else {
            currentCallUUID = nil
            return false
        }
        // Clear before requesting so the CXEndCallAction delegate knows this is app-initiated.
        currentCallUUID = nil
        controller.requestTransaction(with: CXEndCallAction(call: uuid)) { _ in }
        return true
    }

    // MARK: - State query

    var hasActiveCall: Bool { currentCallUUID != nil }

    // MARK: - Private

    private func reportCallEnded(reason: CXCallEndedReason) {
        guard let uuid = currentCallUUID else { return }
        currentCallUUID = nil
        provider?.reportCall(with: uuid, endedAt: nil, reason: reason)
    }
}

// MARK: - CXProviderDelegate

extension IosTalk360CallKitProvider: CXProviderDelegate {

    func providerDidReset(_ provider: CXProvider) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentCallUUID != nil else { return }
            self.currentCallUUID = nil
            self.onCallEndedByCallKit?()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
        // Use action.callUUID — reading currentCallUUID here would be off the main thread.
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        #if targetEnvironment(simulator)
        // iOS 17+ simulator bug: a spurious CXEndCallAction fires when starting a call.
        action.fail()
        return
        #endif

        action.fulfill()

        let uuid = action.callUUID
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // currentCallUUID is nil when we called endCallIfActive() ourselves (app hang-up).
            // If it still matches, the end came from the CallKit UI or system.
            if self.currentCallUUID == uuid {
                self.currentCallUUID = nil
                self.onCallEndedByCallKit?()
            }
        }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        DispatchQueue.main.async { [weak self] in
            self?.onAudioActivated?(audioSession)
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        DispatchQueue.main.async { [weak self] in
            self?.onAudioDeactivated?(audioSession)
        }
    }
}
