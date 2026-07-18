import Combine
import Foundation

@MainActor
public final class SystemMonitor: ObservableObject {
    @Published public private(set) var snapshot = MetricSnapshot.placeholder

    private let provider = SystemMetricsProvider()
    private var timer: Timer?
    private var isRunning = false

    public init(snapshot: MetricSnapshot = .placeholder) {
        self.snapshot = snapshot
    }

    public func start() {
        guard !isRunning else {
            return
        }

        isRunning = true
        refresh()

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard self?.isRunning == true else {
                    return
                }

                self?.refresh()
            }
        }
        timer.tolerance = 0.2
        // Common mode keeps the sampling alive while a menu tracks the run loop, so the metrics
        // don't freeze for as long as the tray item's context menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    public func refresh() {
        snapshot = provider.sample()
    }
}
