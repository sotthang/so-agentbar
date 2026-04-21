import XCTest
@testable import SoAgentBar

// =============================================================================
// MARK: - Test-only Fake Provider
// =============================================================================

/// FakeSystemMetricsProvider: 테스트에서 결정적(deterministic) 값을 주입하기 위한 fake.
/// SystemMetricsProvider 프로토콜 준수 확인 겸 Monitor 테스트에 사용.
final class FakeSystemMetricsProvider: SystemMetricsProvider {
    var nextSample: SystemMetrics

    init(_ initial: SystemMetrics) {
        self.nextSample = initial
    }

    func sample() -> SystemMetrics {
        return nextSample
    }
}

// =============================================================================
// MARK: - SystemMetrics 구조체 테스트
// AC1 / AC2 관련 — 모델 계층
// =============================================================================

final class SystemMetricsModelTests: XCTestCase {

    // Happy path: SystemMetrics 초기화 후 각 필드 값이 올바르게 저장된다
    func test_SystemMetrics_init_happyPath_fieldsStoredCorrectly() {
        // Given / When
        let metrics = SystemMetrics(
            cpuPercent: 42.5,
            memoryPercent: 70.0,
            diskPercent: 85.3,
            diskFreeGB: 240.0
        )
        // Then
        XCTAssertEqual(metrics.cpuPercent, 42.5, accuracy: 0.001)
        XCTAssertEqual(metrics.memoryPercent, 70.0, accuracy: 0.001)
        XCTAssertEqual(metrics.diskPercent, 85.3, accuracy: 0.001)
        XCTAssertEqual(metrics.diskFreeGB, 240.0, accuracy: 0.001)
    }

    // Happy path: cpuPercent = 0, memoryPercent = 0 (경계값)
    func test_SystemMetrics_init_edgeCase_zeroValues() {
        let metrics = SystemMetrics(
            cpuPercent: 0,
            memoryPercent: 0,
            diskPercent: 0,
            diskFreeGB: 0
        )
        XCTAssertEqual(metrics.cpuPercent, 0, accuracy: 0.001)
        XCTAssertEqual(metrics.memoryPercent, 0, accuracy: 0.001)
        XCTAssertEqual(metrics.diskPercent, 0, accuracy: 0.001)
        XCTAssertEqual(metrics.diskFreeGB, 0, accuracy: 0.001)
    }

    // Edge case: 100% 경계값
    func test_SystemMetrics_init_edgeCase_hundredPercent() {
        let metrics = SystemMetrics(
            cpuPercent: 100,
            memoryPercent: 100,
            diskPercent: 100,
            diskFreeGB: 0
        )
        XCTAssertEqual(metrics.cpuPercent, 100, accuracy: 0.001)
        XCTAssertEqual(metrics.memoryPercent, 100, accuracy: 0.001)
        XCTAssertEqual(metrics.diskPercent, 100, accuracy: 0.001)
    }

    // Happy path: Equatable 준수 — 같은 값은 equal
    func test_SystemMetrics_equatable_sameValues_areEqual() {
        let a = SystemMetrics(cpuPercent: 50, memoryPercent: 60, diskPercent: 70, diskFreeGB: 100)
        let b = SystemMetrics(cpuPercent: 50, memoryPercent: 60, diskPercent: 70, diskFreeGB: 100)
        XCTAssertEqual(a, b)
    }

    // Happy path: Equatable 준수 — 다른 값은 not equal
    func test_SystemMetrics_equatable_differentValues_areNotEqual() {
        let a = SystemMetrics(cpuPercent: 50, memoryPercent: 60, diskPercent: 70, diskFreeGB: 100)
        let b = SystemMetrics(cpuPercent: 51, memoryPercent: 60, diskPercent: 70, diskFreeGB: 100)
        XCTAssertNotEqual(a, b)
    }
}

// =============================================================================
// MARK: - FakeSystemMetricsProvider 프로토콜 준수 테스트
// R15 — 프로토콜 분리 및 Fake 주입 가능
// =============================================================================

final class FakeSystemMetricsProviderTests: XCTestCase {

    // Happy path: FakeSystemMetricsProvider가 SystemMetricsProvider 프로토콜을 준수한다
    func test_fakeProvider_conformsToProtocol_isAssignableToProtocolType() {
        let fake: SystemMetricsProvider = FakeSystemMetricsProvider(
            SystemMetrics(cpuPercent: 10, memoryPercent: 20, diskPercent: 30, diskFreeGB: 50)
        )
        XCTAssertNotNil(fake)
    }

    // Happy path: sample()이 주입된 nextSample 값을 반환한다
    func test_fakeProvider_sample_returnsInjectedValue() {
        // Given
        let expected = SystemMetrics(cpuPercent: 33, memoryPercent: 44, diskPercent: 55, diskFreeGB: 200)
        let fake = FakeSystemMetricsProvider(expected)

        // When
        let result = fake.sample()

        // Then
        XCTAssertEqual(result, expected)
    }

    // Happy path: nextSample 변경 후 sample()이 새 값을 반환한다
    func test_fakeProvider_sample_afterMutation_returnsNewValue() {
        // Given
        let initial = SystemMetrics(cpuPercent: 0, memoryPercent: 0, diskPercent: 0, diskFreeGB: 0)
        let fake = FakeSystemMetricsProvider(initial)

        // When
        let updated = SystemMetrics(cpuPercent: 99, memoryPercent: 88, diskPercent: 77, diskFreeGB: 10)
        fake.nextSample = updated

        // Then
        XCTAssertEqual(fake.sample(), updated)
    }
}

// =============================================================================
// MARK: - SystemMetricsMonitor 테스트
// AC2 — 5초 주기 @Published 업데이트 (tickForTesting으로 결정적 검증)
// AC13 — start() 직후 metrics != nil
// =============================================================================

final class SystemMetricsMonitorTests: XCTestCase {

    // AC13: start() 호출 즉시 1회 샘플링 → metrics != nil
    // Given: FakeProvider 주입 / When: start() 호출 / Then: metrics != nil
    @MainActor
    func test_monitor_start_immediatelySamples_metricsIsNotNil() {
        // Given
        let fake = FakeSystemMetricsProvider(
            SystemMetrics(cpuPercent: 10, memoryPercent: 20, diskPercent: 30, diskFreeGB: 100)
        )
        let monitor = SystemMetricsMonitor(provider: fake, pollInterval: 60.0)

        // When
        monitor.start()

        // Then — AC13: 첫 팝오버 열기 전에 이미 값이 있어야 한다
        XCTAssertNotNil(monitor.metrics, "start() 호출 후 즉시 metrics가 채워져야 한다 (AC13)")
    }

    // Happy path: tickForTesting() 호출 시 provider.sample() 값이 @Published metrics에 반영된다
    @MainActor
    func test_monitor_tickForTesting_reflectsProviderValue_inMetrics() {
        // Given
        let fake = FakeSystemMetricsProvider(
            SystemMetrics(cpuPercent: 55, memoryPercent: 66, diskPercent: 77, diskFreeGB: 150)
        )
        let monitor = SystemMetricsMonitor(provider: fake, pollInterval: 60.0)

        // When
        monitor.tickForTesting()

        // Then
        XCTAssertEqual(monitor.metrics?.cpuPercent, 55, accuracy: 0.001)
        XCTAssertEqual(monitor.metrics?.memoryPercent, 66, accuracy: 0.001)
        XCTAssertEqual(monitor.metrics?.diskPercent, 77, accuracy: 0.001)
        XCTAssertEqual(monitor.metrics?.diskFreeGB, 150, accuracy: 0.001)
    }

    // Happy path: tickForTesting() 두 번 호출 시 두 번째 결과가 반영된다 (AC2 단위 검증)
    @MainActor
    func test_monitor_tickForTesting_twice_updatesMetricsToLatestSample() {
        // Given
        let fake = FakeSystemMetricsProvider(
            SystemMetrics(cpuPercent: 10, memoryPercent: 10, diskPercent: 10, diskFreeGB: 500)
        )
        let monitor = SystemMetricsMonitor(provider: fake, pollInterval: 60.0)
        monitor.tickForTesting()

        // When — 두 번째 샘플 주입
        let secondSample = SystemMetrics(cpuPercent: 90, memoryPercent: 80, diskPercent: 50, diskFreeGB: 100)
        fake.nextSample = secondSample
        monitor.tickForTesting()

        // Then — 최신 샘플이 반영되어야 한다
        XCTAssertEqual(monitor.metrics?.cpuPercent, 90, accuracy: 0.001)
        XCTAssertEqual(monitor.metrics?.memoryPercent, 80, accuracy: 0.001)
    }

    // Edge case: stop() 후 tickForTesting() 호출해도 metrics가 이전 값에서 업데이트되지 않는다
    // (stop()은 Timer를 해제하지만 tickForTesting은 Timer와 무관한 수동 훅이므로,
    //  stop() 후에도 tickForTesting은 동작할 수 있다 — 단, 타이머 기반 자동 업데이트는 멈춘다.
    //  이 테스트는 stop() 후 metrics 값이 stop() 시점 값으로 유지됨을 검증한다)
    @MainActor
    func test_monitor_stop_metricsRetainsLastValue() {
        // Given
        let fake = FakeSystemMetricsProvider(
            SystemMetrics(cpuPercent: 50, memoryPercent: 50, diskPercent: 50, diskFreeGB: 200)
        )
        let monitor = SystemMetricsMonitor(provider: fake, pollInterval: 60.0)
        monitor.start()
        let metricsAfterStart = monitor.metrics

        // When
        monitor.stop()

        // Then — stop() 후에도 마지막 샘플 값이 유지된다
        XCTAssertNotNil(monitor.metrics, "stop() 후 metrics 값은 유지되어야 한다")
        XCTAssertEqual(monitor.metrics, metricsAfterStart, "stop() 후 metrics는 start 시점 값과 동일해야 한다")
    }

    // Edge case: start() 중복 호출이 안전해야 한다 (크래시 없이 no-op)
    @MainActor
    func test_monitor_start_calledTwice_doesNotCrash() {
        // Given
        let fake = FakeSystemMetricsProvider(
            SystemMetrics(cpuPercent: 20, memoryPercent: 30, diskPercent: 40, diskFreeGB: 300)
        )
        let monitor = SystemMetricsMonitor(provider: fake, pollInterval: 60.0)

        // When / Then — 두 번 start() 해도 크래시 없어야 한다
        monitor.start()
        monitor.start()
        XCTAssertNotNil(monitor.metrics)
    }

    // Error case: provider가 첫 샘플에서 CPU=0 반환 — AC13 보조 검증
    // (HostSystemMetricsProvider는 첫 sample에서 CPU=0일 수 있다. Fake에서도 동일하게 동작해야 함)
    @MainActor
    func test_monitor_start_cpuZeroOnFirstSample_metricsIsStillNonNil() {
        // Given: CPU 첫 샘플 = 0 (tick diff 미존재 상황 모사)
        let fake = FakeSystemMetricsProvider(
            SystemMetrics(cpuPercent: 0, memoryPercent: 50, diskPercent: 60, diskFreeGB: 400)
        )
        let monitor = SystemMetricsMonitor(provider: fake, pollInterval: 60.0)

        // When
        monitor.start()

        // Then — CPU 0이어도 metrics는 nil이 아니어야 한다
        XCTAssertNotNil(monitor.metrics)
        XCTAssertEqual(monitor.metrics?.cpuPercent, 0, accuracy: 0.001)
    }
}
