import AppKit
import Observation

@MainActor
final class EngineRetryMenuSection: NSObject, MenuSection {
    private let host: EngineHost
    private let item = NSMenuItem(title: "Retry Speech Model", action: nil, keyEquivalent: "")
    var items: [NSMenuItem] { [item] }

    init(host: EngineHost) {
        self.host = host
        super.init()
        item.target = self
        item.action = #selector(retry)
        observe()
    }

    func refresh() {
        if case .failed = host.state { item.isHidden = false }
        else { item.isHidden = true }
    }

    private func observe() {
        withObservationTracking { refresh() } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    @objc private func retry() { host.start() }
}
