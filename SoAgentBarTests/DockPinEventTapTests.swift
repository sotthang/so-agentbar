import XCTest
import CoreGraphics
@testable import SoAgentBar

// MARK: - DockPinEventTapTests
//
// SPEC-004 커밋 5 — 부작용 계층(DockPinEventTap.swift)의 "시작하지 않은 탭" 단위 테스트.
// arch §8은 커밋 5에 단위 테스트를 두지 않고 AC13.1·AC13.3(grep)만 둔다. 이 파일은 Tester가 덧붙인
// 안전한 범위의 검증이다: 시계(V5, R5.6 마지막 줄·R7.4)와 시작 전 탭의 멱등·빈 상태(R4.2, R5.8, R8.6).
//
// 안전 규칙(R12.3, 오케스트레이터 지시):
// - start()를 절대 부르지 않는다 → 실제 CGEventTap·탭 스레드·런루프 소스가 생기지 않는다.
// - 이벤트를 post하지 않고 커서를 움직이지 않는다. Live 어댑터(DockPinLive*)는 부르지 않는다.
// - 설정 저장소(standard 포함)는 쓰지 않는다.
//
// RED 확인 방법: 스텁은 uptime -1, isRunning true, reenableIfNeeded true, 비어 있지 않은 drain,
// userActivityCount 1, onOptionPassSignal 항상 non-nil을 돌려주므로 아래 테스트는 전부 실패하는 것이 정상이다.

@MainActor
final class DockPinEventTapTests: XCTestCase {

    private static let emptySignals = DockPinTapSignals(userActivityCount: 0, optionPasses: [:], hadOptionPass: false)

    // MARK: - 시계 (V5)

    func test_uptime_matchesProcessSystemUptime() {
        let before = ProcessInfo.processInfo.systemUptime
        let value = DockPinEventTap.uptime()
        let after = ProcessInfo.processInfo.systemUptime

        // 같은 시계(CLOCK_UPTIME_RAW)라 두 읽기 사이에 있어야 한다. 반올림 여유 1ms.
        XCTAssertGreaterThanOrEqual(value, before - 0.001)
        XCTAssertLessThanOrEqual(value, after + 0.001)
    }

    func test_uptime_isMonotonicNonDecreasing() {
        let first = DockPinEventTap.uptime()
        let second = DockPinEventTap.uptime()
        XCTAssertGreaterThan(first, 0)
        XCTAssertGreaterThanOrEqual(second, first)
    }

    // MARK: - 시작 전 상태

    func test_newTap_isNotRunning() {
        let tap = DockPinEventTap(clock: { 42 })
        XCTAssertFalse(tap.isRunning)
    }

    func test_newTap_userActivityCount_isZero() {
        let tap = DockPinEventTap(clock: { 42 })
        XCTAssertEqual(tap.userActivityCount, 0)
    }

    func test_newTap_drainSignals_isEmpty() {
        let tap = DockPinEventTap(clock: { 42 })
        XCTAssertEqual(tap.drainSignals(), Self.emptySignals)
    }

    func test_newTap_drainSignals_twice_bothEmpty() {
        let tap = DockPinEventTap(clock: { 42 })
        XCTAssertEqual(tap.drainSignals(), Self.emptySignals)
        XCTAssertEqual(tap.drainSignals(), Self.emptySignals)
    }

    /// R5.8 — 탭이 없으면 다시 켤 것도 없다.
    func test_reenableIfNeeded_whenNeverStarted_returnsFalse() {
        let tap = DockPinEventTap(clock: { 42 })
        XCTAssertFalse(tap.reenableIfNeeded())
        XCTAssertFalse(tap.isRunning)
    }

    // MARK: - stop 멱등 (R4.2, R12.2)

    func test_stop_whenNeverStarted_isNoOp() {
        let tap = DockPinEventTap(clock: { 42 })
        tap.stop()
        XCTAssertFalse(tap.isRunning)
        XCTAssertEqual(tap.drainSignals(), Self.emptySignals)
    }

    func test_stop_calledTwice_isIdempotent() {
        let tap = DockPinEventTap(clock: { 42 })
        tap.stop()
        tap.stop()
        XCTAssertFalse(tap.isRunning)
        XCTAssertEqual(tap.userActivityCount, 0)
    }

    // MARK: - update(snapshot:)는 신호를 만들지 않는다 (R5.3: 신호는 콜백만 기록)

    func test_updateSnapshot_whenNotRunning_doesNotRecordSignals() {
        let tap = DockPinEventTap(clock: { 42 })
        var snapshot = DockPinGuardSnapshot()
        snapshot.isRelocating = true
        snapshot.isDriving = true
        snapshot.rows = [DockPinTriggerRow(displayID: 7, minX: 0, maxX: 100, minY: 99, maxY: 100)]

        tap.update(snapshot: snapshot)

        XCTAssertFalse(tap.isRunning)
        XCTAssertEqual(tap.userActivityCount, 0)
        XCTAssertEqual(tap.drainSignals(), Self.emptySignals)
    }

    // MARK: - onOptionPassSignal 저장

    func test_onOptionPassSignal_defaultsToNil_andStoresAssignment() {
        let tap = DockPinEventTap(clock: { 42 })
        XCTAssertNil(tap.onOptionPassSignal)

        var calls = 0
        tap.onOptionPassSignal = { calls += 1 }
        XCTAssertNotNil(tap.onOptionPassSignal)
        tap.onOptionPassSignal?()
        XCTAssertEqual(calls, 1)

        tap.onOptionPassSignal = nil
        XCTAssertNil(tap.onOptionPassSignal)
    }

    // MARK: - 프로토콜 적합 (매니저는 DockPinEventTapping 으로만 본다)

    func test_eventTap_usableThroughProtocol_beforeStart() {
        let tapping: DockPinEventTapping = DockPinEventTap(clock: { 42 })
        tapping.stop()
        XCTAssertFalse(tapping.isRunning)
        XCTAssertFalse(tapping.reenableIfNeeded())
        XCTAssertEqual(tapping.userActivityCount, 0)
    }
}
