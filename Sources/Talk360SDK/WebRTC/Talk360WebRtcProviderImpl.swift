import Foundation
import Shared

// MARK: - Provider

/// Bridge adapter implementing the KMP Talk360WebRtcProvider protocol.
@MainActor
final class Talk360WebRtcProviderImpl: NSObject, Talk360WebRtcProvider {

    // MARK: - Properties

    private let sessionFactory: () -> any WebRTCSessionProtocol
    private let offerTimeoutSeconds: Double
    private let iceFailureRetrySeconds: Double

    private var session: (any WebRTCSessionProtocol)?
    private var callbacks: (any Talk360WebRtcCallbacks)?
    private var offerTimeoutTask: Task<Void, Never>?
    private var networkMonitor: IosNetworkChangeMonitor?

    private var lastIceServers: [BridgeIceServer] = []
    private var reattachInProgress = false

    private var pendingNetworkChangeReattachTask: Task<Void, Never>?
    private var pendingIceFailureReattachTask: Task<Void, Never>?

    // MARK: - Init

    init(
        sessionFactory: @escaping () -> any WebRTCSessionProtocol = { WebRTCSession() },
        offerTimeoutSeconds: Double = 10,
        iceFailureRetrySeconds: Double = Double(Talk360WebRtcTimings.shared.ICE_FAILURE_RETRY_DELAY_MS) / 1000.0
    ) {
        self.sessionFactory = sessionFactory
        self.offerTimeoutSeconds = offerTimeoutSeconds
        self.iceFailureRetrySeconds = iceFailureRetrySeconds
    }

    // MARK: - Talk360WebRtcProvider

    /// Swift name of the KMP `initWebRTC` method (renamed by SKIE because `init` is reserved).
    func doInitWebRTC(iceServersJson: String, callbacks: any Talk360WebRtcCallbacks) {
        offerTimeoutTask?.cancel()
        offerTimeoutTask = nil
        // Nil the listener before dispose so any in-flight async close events on the
        // old session don't reach the new caller's callbacks.
        session?.listener = nil
        session?.dispose()
        networkMonitor?.stop()
        self.callbacks = callbacks
        reattachInProgress = false
        cancelPendingNetworkChangeReattach()
        cancelPendingIceFailureReattach()

        let servers = BridgeJsonParser.shared.parseIceServers(iceServersJson: iceServersJson)
        lastIceServers = servers

        let s = sessionFactory()
        s.listener = self
        session = s

        let monitor = IosNetworkChangeMonitor { [weak self] in
            self?.scheduleNetworkChangeReattach()
        }
        monitor.start()
        networkMonitor = monitor

        // iOS-only safeguard: WebRTC 124 on iOS can stall before calling the offer callback when
        // the peer connection factory initialises for the first time. Android's PeerConnectionFactory
        // is synchronous and does not need this guard.
        let timeoutNanos = UInt64(offerTimeoutSeconds * 1_000_000_000)
        let capturedCallbacks = callbacks
        offerTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanos)
            guard !Task.isCancelled, let self else { return }
            capturedCallbacks.onError(errorMessage: "Offer generation timed out")
            self.disposeWebRTC()
        }

        s.start(iceServers: servers)
    }

    func reattachWebRTC(iceServersJson: String, callId: String) {
        let parsed = BridgeJsonParser.shared.parseIceServers(iceServersJson: iceServersJson)
        let effective = parsed.isEmpty ? lastIceServers : parsed
        if effective.isEmpty {
            #if DEBUG
            print("[Talk360SDK][Reattach] reattachWebRTC: no ICE servers available; skipping (callId=\(callId))")
            #endif
            return
        }
        triggerReattach(iceServers: effective, reason: "web_request(callId=\(callId))")
    }

    func processAnswer(sdpAnswer: String) {
        // Mirrors Android's `isBlank()` — whitespace-only SDP is also invalid.
        guard !sdpAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session?.applyRemoteAnswer(sdpAnswer)
    }

    func addIceCandidate(candidateJson: String) {
        guard let candidate = BridgeJsonParser.shared.parseIceCandidate(candidateJson: candidateJson) else { return }
        session?.addRemoteIceCandidate(candidate)
    }

    func setMuted(muted: Bool) {
        session?.setMuted(muted)
    }

    func disposeWebRTC() {
        offerTimeoutTask?.cancel()
        offerTimeoutTask = nil
        cancelPendingNetworkChangeReattach()
        cancelPendingIceFailureReattach()
        networkMonitor?.stop()
        networkMonitor = nil
        session?.dispose()
        session = nil
        callbacks = nil
        lastIceServers = []
        reattachInProgress = false
    }

    // MARK: - Reattach triggers

    /// Debounces network-change reattach so a freshly-activated cellular link has time to
    /// establish NAT bindings / TURN reachability before ICE candidate pairing starts.
    private func scheduleNetworkChangeReattach() {
        cancelPendingNetworkChangeReattach()
        #if DEBUG
        print("[Talk360SDK][Reattach] network change detected; reattaching in \(Talk360WebRtcTimings.shared.NETWORK_CHANGE_DEBOUNCE_MS)ms")
        #endif
        let nanos = UInt64(Talk360WebRtcTimings.shared.NETWORK_CHANGE_DEBOUNCE_MS) * 1_000_000
        pendingNetworkChangeReattachTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            self.pendingNetworkChangeReattachTask = nil
            self.triggerNativeReattach(reason: "network_change")
        }
    }

    private func cancelPendingNetworkChangeReattach() {
        pendingNetworkChangeReattachTask?.cancel()
        pendingNetworkChangeReattachTask = nil
    }

    /// Small delay lets the network settle before we rebuild the peer connection, and avoids
    /// a tight failure-retry loop when the network is still unusable.
    private func scheduleIceFailureReattach(reason: String) {
        cancelPendingIceFailureReattach()
        #if DEBUG
        print("[Talk360SDK][Reattach] ICE failure received (reason=\(reason)); scheduling reattach in \(Int(iceFailureRetrySeconds * 1000))ms")
        #endif
        let nanos = UInt64(iceFailureRetrySeconds * 1_000_000_000)
        pendingIceFailureReattachTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            self.pendingIceFailureReattachTask = nil
            self.triggerNativeReattach(reason: reason)
        }
    }

    private func cancelPendingIceFailureReattach() {
        pendingIceFailureReattachTask?.cancel()
        pendingIceFailureReattachTask = nil
    }

    /// Called when native detects a recovery trigger (ICE failure or transport change).
    /// Falls back to `lastIceServers` because the web isn't in the loop here.
    private func triggerNativeReattach(reason: String) {
        guard let currentSession = session else { return }
        if lastIceServers.isEmpty {
            #if DEBUG
            print("[Talk360SDK][Reattach] triggerNativeReattach(\(reason)): no ICE servers cached; skipping")
            #endif
            return
        }
        if currentSession.isIceChecking() {
            #if DEBUG
            print("[Talk360SDK][Reattach] triggerNativeReattach(\(reason)): ICE state CHECKING; skipping")
            #endif
            return
        }
        triggerReattach(iceServers: lastIceServers, reason: reason)
    }

    private func triggerReattach(iceServers: [BridgeIceServer], reason: String) {
        if reattachInProgress {
            #if DEBUG
            print("[Talk360SDK][Reattach] already in progress; skipping trigger=\(reason)")
            #endif
            return
        }
        guard let currentSession = session else { return }
        offerTimeoutTask?.cancel()
        offerTimeoutTask = nil
        reattachInProgress = true
        lastIceServers = iceServers
        #if DEBUG
        print("[Talk360SDK][Reattach] triggering WebRTC reattach: \(reason)")
        #endif
        currentSession.reattach(iceServers: iceServers)
    }
}

// MARK: - WebRTCSessionListener

extension Talk360WebRtcProviderImpl: WebRTCSessionListener {

    func onLocalSdpOffer(_ sdp: String) {
        offerTimeoutTask?.cancel()
        offerTimeoutTask = nil
        callbacks?.onOfferReady(sdpOffer: sdp)
    }

    func onLocalIceCandidate(_ candidate: BridgeIceCandidate) {
        callbacks?.onIceCandidate(candidateJson: BridgeJsonParser.shared.serializeIceCandidate(candidate: candidate))
    }

    func onIceConnectionStateChanged(_ state: String) {
        let cs = Talk360DialerJSBridgeHandler.ConnectionState.shared
        // Clear the guard on every terminal state so a subsequent reattach can run after failure.
        if state == cs.CONNECTED || state == cs.COMPLETED || state == cs.FAILED || state == cs.CLOSED {
            reattachInProgress = false
        }
        callbacks?.onConnectionStateChanged(state: state)
    }

    func onCallQuality(_ quality: String, score: Double, timestampMs: Int64) {
        callbacks?.onCallQuality(quality: quality, score: KotlinDouble(value: score), timestampMs: timestampMs)
    }

    func onError(_ message: String) {
        callbacks?.onError(errorMessage: message)
    }

    func onIceFailure(_ reason: String) {
        scheduleIceFailureReattach(reason: reason)
    }
}
