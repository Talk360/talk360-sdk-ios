import SwiftUI
import Shared

struct DialerView: View {

    let config: Talk360BootConfig
    let purchaseFlowRelay: PurchaseFlowRelay
    let eventDelegate: (any Talk360EventDelegate)?
    @Environment(\.dismiss) private var dismiss
    @State private var state: ScreenState = .loading
    @State private var viewModel: DialerViewModel?

    private let strings = StringProvider()

    init(config: Talk360BootConfig, purchaseFlowRelay: PurchaseFlowRelay, eventDelegate: (any Talk360EventDelegate)?) {
        self.config = config
        self.purchaseFlowRelay = purchaseFlowRelay
        self.eventDelegate = eventDelegate
    }

    private enum ScreenState {
        case loading
        case ready(session: Session)
        case error
    }

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()
            Group {
                switch state {
                case .loading:
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(primaryColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready(let session):
                    WebViewRepresentable(
                        config: config,
                        session: session,
                        dismiss: { dismiss() },
                        purchaseFlowRelay: purchaseFlowRelay,
                        eventDelegate: eventDelegate
                    )
                case .error:
                    Text(strings.string(.sdkErrorLoadingFailed))
                        .foregroundColor(textPrimaryColor)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { await loadSession() }
        .onDisappear { viewModel?.close() }
    }

    private var primaryColor: Color? {
        config.brandColors?.primary.map { Color($0) }
    }

    private var backgroundColor: Color {
        config.brandColors?.background.map { Color($0) } ?? .clear
    }

    private var textPrimaryColor: Color? {
        config.brandColors?.textPrimary.map { Color($0) }
    }

    private func loadSession() async {
        guard viewModel == nil else { return }
        let vm = Talk360SessionModuleKt.createDialerViewModel(environment: config.environment)
        viewModel = vm
        vm.initialize(jwt: config.jwt)

        do {
            guard let result = try await vm.awaitReady() as? DialerInitState.Ready else {
                state = .error
                return
            }
            state = .ready(session: result.session)
        } catch {
            state = .error
        }
    }
}
