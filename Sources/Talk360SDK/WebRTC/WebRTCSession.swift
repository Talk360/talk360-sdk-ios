import Foundation
import WebRTC
import Shared

// MARK: - Listener

internal protocol WebRTCSessionListener: AnyObject {
    func onLocalSdpOffer(_ sdp: String)
    func onLocalIceCandidate(_ candidate: BridgeIceCandidate)
    /// State is already mapped to a bridge string ("new", "connecting", "connected", etc.)
    func onIceConnectionStateChanged(_ state: String)
    func onCallQuality(_ quality: String, score: Double, timestampMs: Int64)
    func onError(_ message: String)
    func onIceFailure(_ reason: String)
}

// MARK: - Protocol (enables mocking in tests)

internal protocol WebRTCSessionProtocol: AnyObject {
    var listener: (any WebRTCSessionListener)? { get set }
    func start(iceServers: [BridgeIceServer])
    func reattach(iceServers: [BridgeIceServer])
    func applyRemoteAnswer(_ sdp: String)
    func addRemoteIceCandidate(_ candidate: BridgeIceCandidate)
    func setMuted(_ muted: Bool)
    func isIceChecking() -> Bool
    func dispose()
}

// MARK: - Session

/// Owns one RTCPeerConnection for the duration of a single call.
/// All methods are safe to call from any thread — operations dispatch to DispatchQueue.main internally.
internal final class WebRTCSession: NSObject, WebRTCSessionProtocol {

    // MARK: - Constants

    private static let audioTrackId = "ARDAMSa0"
    private static let mediaStreamId = "ARDAMS"

    private static let offerConstraints: RTCMediaConstraints = {
        let mandatory = [
            kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
            kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueFalse,
        ]
        let optional = ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue]
        return RTCMediaConstraints(mandatoryConstraints: mandatory, optionalConstraints: optional)
    }()

    // One-time SSL init, thread-safe via static let.
    private static let sslInit: Void = { RTCInitializeSSL() }()

    // MARK: - State (main-thread only)

    weak var listener: (any WebRTCSessionListener)?

    private var factory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var remoteDescriptionSet = false
    private var remoteDescriptionPending = false
    private var disposed = false
    private var muted = false

    private var currentIceState: RTCIceConnectionState?

    private let callQualityMonitor = CallQualityMonitor()
    private var statsPollingActive = false
    private var statsTimer: DispatchSourceTimer?

    // MARK: - WebRTCSessionProtocol

    func start(iceServers: [BridgeIceServer]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.peerConnection == nil else {
                assertionFailure("WebRTCSession.start() called while a session is already active")
                return
            }
            self.disposed = false
            self.remoteDescriptionSet = false
            self.remoteDescriptionPending = false
            self.pendingRemoteCandidates.removeAll()

            do {
                try self.createFactory()
                try self.createPeerConnection(iceServers: iceServers)
                try self.attachAudioTrack()
                self.createOffer()
            } catch {
                self.listener?.onError("WebRTC init failed: \(error.localizedDescription)")
                self.disposeInternal()
            }
        }
    }

    func applyRemoteAnswer(_ sdp: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let pc = self.peerConnection, !self.disposed else { return }
            // Web has been observed firing processAnswer twice per offer during reattach.
            // Both calls arrive within a few ms — the setRemoteDescription completion for the
            // first hasn't fired yet, so we can't rely on `remoteDescriptionSet`. Latch a
            // synchronous `remoteDescriptionPending` flag the moment we initiate the call.
            if self.remoteDescriptionSet || self.remoteDescriptionPending {
                return
            }
            let description = RTCSessionDescription(type: .answer, sdp: sdp)
            self.remoteDescriptionPending = true
            pc.setRemoteDescription(description) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.remoteDescriptionPending = false
                    if let error {
                        self.listener?.onError("Failed to set remote description: \(error.localizedDescription)")
                        return
                    }
                    self.remoteDescriptionSet = true
                    let drained = self.pendingRemoteCandidates
                    self.pendingRemoteCandidates.removeAll()
                    drained.forEach { pc.add($0) }
                }
            }
        }
    }

    func addRemoteIceCandidate(_ candidate: BridgeIceCandidate) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.disposed else { return }
            let sdpMidBlank = candidate.sdpMid?.isEmpty ?? true
            guard !sdpMidBlank || candidate.sdpMLineIndex != nil else { return }
            // sdpMLineIndex is Kotlin Int? — SKIE exposes nullable Int as KotlinInt?.
            // Default to 0 when absent but sdpMid is present, matching Android's IceCandidate(sdpMid ?: "", ..., index ?: 0).
            let lineIndex = Int32(candidate.sdpMLineIndex?.intValue ?? 0)
            let iceCandidate = RTCIceCandidate(
                sdp: candidate.candidate,
                sdpMLineIndex: lineIndex,
                sdpMid: candidate.sdpMid ?? ""  // normalize nil to "" to match Android
            )
            if !self.remoteDescriptionSet {
                self.pendingRemoteCandidates.append(iceCandidate)
            } else {
                self.peerConnection?.add(iceCandidate)
            }
        }
    }

    func setMuted(_ muted: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.muted = muted
            self.audioTrack?.isEnabled = !muted
        }
    }

    func dispose() {
        DispatchQueue.main.async { [self] in
            self.disposeInternal()
        }
    }

    func isIceChecking() -> Bool {
        currentIceState == .checking
    }

    /// Tears down the current peer connection and audio track and rebuilds both with `iceServers`.
    /// The factory is preserved across the rebuild.
    func reattach(iceServers: [BridgeIceServer]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.disposed else { return }
            self.stopStatsPolling()
            self.currentIceState = nil
            self.remoteDescriptionSet = false
            self.remoteDescriptionPending = false
            self.pendingRemoteCandidates.removeAll()

            self.peerConnection?.close()
            self.peerConnection = nil
            self.audioTrack = nil

            do {
                if self.factory == nil { try self.createFactory() }
                try self.createPeerConnection(iceServers: iceServers)
                try self.attachAudioTrack()
                self.createOffer()
            } catch {
                self.listener?.onError("WebRTC reattach failed: \(error.localizedDescription)")
                self.disposeInternal()
            }
        }
    }

    // MARK: - Private setup

    private func createFactory() throws {
        _ = Self.sslInit
        let f = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        factory = f
    }

    private func createPeerConnection(iceServers: [BridgeIceServer]) throws {
        guard let f = factory else { throw WebRTCSessionError.noFactory }

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        // audioJitterBufferFastAccelerate is an iOS-only RTCConfiguration property absent in Android's
        // PeerConnectionFactory.RTCConfiguration. It reduces audio buffering delay on mobile networks.
        config.audioJitterBufferFastAccelerate = true
        config.iceServers = iceServers.map { server in
            guard let username = server.username, !username.isEmpty,
                  let credential = server.credential, !credential.isEmpty else {
                return RTCIceServer(urlStrings: server.urls)
            }
            return RTCIceServer(urlStrings: server.urls, username: username, credential: credential)
        }

        let pcConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = f.peerConnection(with: config, constraints: pcConstraints, delegate: self) else {
            throw WebRTCSessionError.peerConnectionNil
        }
        peerConnection = pc
    }

    private func attachAudioTrack() throws {
        guard let f = factory, let pc = peerConnection else { return }
        let source = f.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let track = f.audioTrack(with: source, trackId: Self.audioTrackId)
        track.isEnabled = !muted
        guard pc.add(track, streamIds: [Self.mediaStreamId]) != nil else {
            throw WebRTCSessionError.addTrackFailed
        }
        audioTrack = track
    }

    private func createOffer() {
        peerConnection?.offer(for: Self.offerConstraints) { [weak self] sdp, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.listener?.onError("SDP offer creation failed: \(error.localizedDescription)")
                    return
                }
                guard let sdp else {
                    self.listener?.onError("SDP offer was nil")
                    return
                }
                self.peerConnection?.setLocalDescription(sdp) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let error {
                            self.listener?.onError("Failed to set local description: \(error.localizedDescription)")
                            return
                        }
                        self.listener?.onLocalSdpOffer(sdp.sdp)
                    }
                }
            }
        }
    }

    private func disposeInternal() {
        guard !disposed else { return }
        disposed = true
        remoteDescriptionSet = false
        remoteDescriptionPending = false
        pendingRemoteCandidates.removeAll()
        stopStatsPolling()
        peerConnection?.close()
        peerConnection = nil
        audioTrack = nil
        factory = nil
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCSession: RTCPeerConnectionDelegate {

    func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCIceConnectionState) {
        let mapped = state.toBridgeString()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            #if DEBUG
            print("[Talk360SDK][ICE] state=\(mapped)")
            #endif
            self.currentIceState = state
            self.listener?.onIceConnectionStateChanged(mapped)
            switch state {
            case .connected, .completed:
                self.startStatsPolling()
                // Re-enable WebRTC's audio session in case iOS interrupted it during the drop.
                // This is only effective when an interruption actually fired; the deeper
                // DTLS/SRTP-after-network-change problem needs a full reattach.
                RTCAudioSession.sharedInstance().isAudioEnabled = true
            case .failed:
                self.stopStatsPolling()
                self.listener?.onIceFailure("ice_failed")
            case .closed:
                self.stopStatsPolling()
            default:
                break
            }
        }
    }

    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // RTCIceCandidate.sdpMLineIndex is Int32; BridgeIceCandidate.sdpMLineIndex is Kotlin Int?
        // KotlinInt(value:) wraps Int32 for SKIE's KotlinInt? bridge.
        let bridge = BridgeIceCandidate(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: KotlinInt(value: candidate.sdpMLineIndex)
        )
        DispatchQueue.main.async { [weak self] in self?.listener?.onLocalIceCandidate(bridge) }
    }

    func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen channel: RTCDataChannel) {}
}

// MARK: - Stats polling

private extension WebRTCSession {

    func startStatsPolling() {
        guard !statsPollingActive, !disposed else { return }
        statsPollingActive = true
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.pollStats() }
        timer.resume()
        statsTimer = timer
    }

    func stopStatsPolling() {
        statsPollingActive = false
        statsTimer?.cancel()
        statsTimer = nil
    }

    func pollStats() {
        peerConnection?.statistics { [weak self] report in
            DispatchQueue.main.async { self?.handleStatsReport(report) }
        }
    }

    func handleStatsReport(_ report: RTCStatisticsReport) {
        guard statsPollingActive else { return }
        let iceState = report.statistics.values
            .first { $0.type == "transport" }
            .flatMap { $0.values["iceState"] as? String }
        guard let update = callQualityMonitor.onStatsReport(report: report.toCommon(), iceState: iceState) else { return }
        let score = Foundation.round(update.score * 10) / 10
        listener?.onCallQuality(update.quality.value, score: score, timestampMs: Int64(Date().timeIntervalSince1970 * 1000))
    }
}

// MARK: - RTCStatisticsReport → RtcStatsReportCommon

private extension RTCStatisticsReport {
    func toCommon() -> RtcStatsReportCommon {
        let stats = statistics.values.map { stat in
            RtcStatCommon(id: stat.id, type: stat.type, members: stat.values as [String: Any])
        }
        return RtcStatsReportCommon(stats: stats)
    }
}

// MARK: - RTCIceConnectionState → bridge string

private extension RTCIceConnectionState {
    func toBridgeString() -> String {
        let cs = Talk360DialerJSBridgeHandler.ConnectionState.shared
        switch self {
        case .new:          return cs.NEW
        case .checking:     return cs.CONNECTING
        case .connected:    return cs.CONNECTED
        case .completed:    return cs.COMPLETED
        case .failed:       return cs.FAILED
        case .disconnected: return cs.DISCONNECTED
        case .closed:       return cs.CLOSED
        case .count:        return "unknown"  // Obj-C bridge sentinel, not a real ICE state
        @unknown default:   return "unknown"
        }
    }
}

// MARK: - Errors

private enum WebRTCSessionError: Error {
    case noFactory
    case peerConnectionNil
    case addTrackFailed
}
