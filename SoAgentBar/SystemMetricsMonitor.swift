import Foundation
import Combine

// MARK: - SystemMetricsMonitor

@MainActor
final class SystemMetricsMonitor: ObservableObject {

    @Published private(set) var metrics: SystemMetrics?

    private let provider: SystemMetricsProvider
    private let pollInterval: TimeInterval
    private var pollingTimer: Timer?

    /// 테스트에서 fake provider + 짧은 interval 주입 가능.
    init(provider: SystemMetricsProvider = HostSystemMetricsProvider(),
         pollInterval: TimeInterval = 5.0) {
        self.provider = provider
        self.pollInterval = pollInterval
    }

    /// 즉시 1회 샘플 + Timer 등록. 중복 호출 안전.
    func start() {
        tickForTesting()
        guard pollingTimer == nil else { return }
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickForTesting()
            }
        }
    }

    /// Timer 해제. metrics 값은 유지.
    func stop() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    /// 테스트에서 시간 경과 시뮬레이션 — Timer 와 무관하게 1회 샘플링.
    func tickForTesting() {
        metrics = provider.sample()
    }
}
