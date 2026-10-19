import XCTest
import CoreGraphics
@testable import SoAgentBar

// MARK: - DockPinPlacementTests
//
// SPEC-004 커밋 3 — 순수 계층(DockPinPlacement.swift) 단위 테스트.
// 커버 AC: AC6.1–6.5, AC6.7, AC6.8.
// 커밋 6 — 같은 파일 아래 `DockPinDockLocatorTests`가 AC6.6과 조회기 규칙(R6.1–R6.6, I1)을 덮는다.
//
// RED 확인 방법: 이 파일은 컴파일된다(so-tester가 arch §2.4 시그니처의 고정값 스텁을 넣었다).
// 스텁은 일부러 틀린 값(placement → .unknown, selectDockWindow → .none, settle → (.none, 0),
// scanBackoff → -1)을 돌려주므로 아래 단정은 전부 실패하는 것이 정상이다.
// 기대값이 스텁 값과 겹치는 테스트(.unknown / .none 기대)는 같은 테스트 안에 짝 단정(양성 결과)을 둔다.
//
// 좌표는 모두 CG 전역(CGDisplayBounds, 주 화면 왼쪽 위 원점, 아래로 y 증가)이다(F11).
// 설정 저장소(standard 포함)는 쓰지 않는다 — 순수 함수만 부른다. 창 목록 IO는 가짜 클로저다.

@MainActor
final class DockPinPlacementTests: XCTestCase {

    // MARK: - 고정 배치 (DockPinFakes.swift의 DockPinFixtures는 커밋 6 — 이름 충돌을 피해 파일 전용으로 둔다)

    private enum Fixture {
        /// F1 — 이 Mac 내장 화면 (주 화면), CG bounds (0,0,1728,1117)
        static let builtIn = DockPinDisplay(id: 1, uuid: "BUILTIN-UUID",
                                            bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                            mirrorOf: nil, name: "Color LCD")
        /// F1 — 이 Mac Sidecar, CG bounds (1728,0,1149,802)
        static let sidecar = DockPinDisplay(id: 12, uuid: "BAB59A29-3097-4311-993B-57A74473F53E",
                                            bounds: CGRect(x: 1728, y: 0, width: 1149, height: 802),
                                            mirrorOf: nil, name: "Sidecar Display (AirPlay)")
        static var thisMac: [DockPinDisplay] { [builtIn, sidecar] }

        /// 캐시한 창 번호(F4 실측은 43, SPEC AC6.2·6.8 예시는 32)
        static let cachedNumber: CGWindowID = 32
        /// 새로 생긴 창 번호(SPEC의 "새 번호 A")
        static let newNumberA: CGWindowID = 77
        static let otherNumberB: CGWindowID = 78

        /// F11 — Dock 레이어 창 범위 = Dock이 있는 화면 전체 범위
        static func window(_ number: CGWindowID, on display: DockPinDisplay) -> DockPinWindowInfo {
            DockPinWindowInfo(number: number, bounds: display.bounds)
        }
    }

    /// 읽을 때마다 순서대로 돌려주고, 끝나면 마지막 값을 계속 돌려주는 가짜 창 목록.
    private final class FakeWindowReads {
        private let sequence: [[DockPinWindowInfo]]
        private(set) var readCount = 0
        private(set) var pauses: [TimeInterval] = []

        init(_ sequence: [[DockPinWindowInfo]]) { self.sequence = sequence }

        func read() -> [DockPinWindowInfo] {
            let index = min(readCount, sequence.count - 1)
            readCount += 1
            return sequence[index]
        }

        func pause(_ interval: TimeInterval) { pauses.append(interval) }
    }

    private func settle(_ fake: FakeWindowReads,
                        cachedNumber: CGWindowID?,
                        preferCached: Bool,
                        displays: [DockPinDisplay] = Fixture.thisMac,
                        maxReads: Int = DockPinTuning.settleMaxReads)
        -> (selection: DockPinWindowSelection, reads: Int) {
        DockPinPlacementRules.settle(cachedNumber: cachedNumber, preferCached: preferCached,
                                     displays: displays, maxReads: maxReads,
                                     interval: DockPinTuning.settleRetryInterval,
                                     read: { fake.read() }, pause: { fake.pause($0) })
    }

    private func select(_ candidates: [DockPinWindowInfo], cachedNumber: CGWindowID?,
                        preferCached: Bool = true) -> DockPinWindowSelection {
        DockPinPlacementRules.selectDockWindow(candidates: candidates, cachedNumber: cachedNumber,
                                               preferCached: preferCached, displays: Fixture.thisMac)
    }

    // MARK: - AC6.1 placement(of:in:) — 1pt 허용, 최대 겹침, 겹침 0

    func test_AC6_1_placement_windowWithinHalfPointOfDisplay_returnsThatDisplay() {
        // 네 변 모두 0.5pt 차이 (minX 0.5, minY 0.5, maxX 1728.5, maxY 1117.5)
        let bounds = CGRect(x: 0.5, y: 0.5, width: 1728, height: 1117)
        XCTAssertEqual(DockPinPlacementRules.placement(of: bounds, in: Fixture.thisMac), .display(1))
    }

    func test_AC6_1_placement_windowWithinHalfPointOfSidecar_returnsSidecar() {
        let bounds = CGRect(x: 1727.5, y: -0.5, width: 1149.5, height: 802.5)
        XCTAssertEqual(DockPinPlacementRules.placement(of: bounds, in: Fixture.thisMac), .display(12))
    }

    func test_AC6_1_placement_twoPointOffset_picksDisplayWithLargestOverlap() {
        // 2pt 어긋남 → 1pt 규칙 불일치. 내장과 1726×1115, Sidecar와 2×802 겹침 → 내장
        let bounds = CGRect(x: 2, y: 2, width: 1728, height: 1117)
        XCTAssertEqual(DockPinPlacementRules.placement(of: bounds, in: Fixture.thisMac), .display(1))
    }

    func test_AC6_1_placement_straddlingWindow_picksDisplayWithLargerOverlapArea() {
        // 내장과 28×802, Sidecar와 1121×802 겹침 → Sidecar
        let bounds = CGRect(x: 1700, y: 0, width: 1149, height: 802)
        XCTAssertEqual(DockPinPlacementRules.placement(of: bounds, in: Fixture.thisMac), .display(12))
    }

    func test_AC6_1_placement_noOverlapWithAnyDisplay_isUnknown() {
        let farAway = CGRect(x: 5000, y: 5000, width: 100, height: 100)
        XCTAssertEqual(DockPinPlacementRules.placement(of: farAway, in: Fixture.thisMac), .unknown)
        // 짝 단정: 같은 화면 목록에서 겹치는 창은 화면으로 판정된다(스텁 .unknown과 구분)
        XCTAssertEqual(DockPinPlacementRules.placement(of: Fixture.builtIn.bounds, in: Fixture.thisMac),
                       .display(1))
    }

    func test_AC6_1_placement_windowOnlyTouchingDisplayEdge_zeroAreaOverlap_isUnknown() {
        // 내장 화면만 있을 때 Sidecar 자리 창은 오른쪽 변에 맞닿기만 한다(겹친 넓이 0)
        let touching = CGRect(x: 1728, y: 0, width: 1149, height: 802)
        XCTAssertEqual(DockPinPlacementRules.placement(of: touching, in: [Fixture.builtIn]), .unknown)
        XCTAssertEqual(DockPinPlacementRules.placement(of: touching, in: Fixture.thisMac), .display(12))
    }

    func test_AC6_1_placement_noDisplays_isUnknown() {
        XCTAssertEqual(DockPinPlacementRules.placement(of: Fixture.builtIn.bounds, in: []), .unknown)
        XCTAssertEqual(DockPinPlacementRules.placement(of: Fixture.builtIn.bounds, in: [Fixture.builtIn]),
                       .display(1))
    }

    // MARK: - AC6.7 F11 배치

    func test_AC6_7_thisMacLayout_builtInBounds_isBuiltInDisplay() {
        let bounds = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        XCTAssertEqual(DockPinPlacementRules.placement(of: bounds, in: Fixture.thisMac), .display(1))
    }

    func test_AC6_7_thisMacLayout_sidecarBounds_isSidecarDisplay() {
        let bounds = CGRect(x: 1728, y: 0, width: 1149, height: 802)
        XCTAssertEqual(DockPinPlacementRules.placement(of: bounds, in: Fixture.thisMac), .display(12))
    }

    // MARK: - selectDockWindow 기본 (후보 0개 / 1개)

    func test_R6_4_select_noCandidates_isNone() {
        XCTAssertEqual(select([], cachedNumber: nil), .none)
        XCTAssertEqual(select([], cachedNumber: Fixture.cachedNumber), .none)
        // 짝 단정: 후보 1개면 고른다(스텁 .none과 구분)
        let only = Fixture.window(Fixture.cachedNumber, on: Fixture.builtIn)
        XCTAssertEqual(select([only], cachedNumber: nil), .chosen(only, .display(1)))
    }

    func test_R6_4_select_singleCandidate_isChosenWithItsPlacement() {
        let only = Fixture.window(Fixture.newNumberA, on: Fixture.sidecar)
        XCTAssertEqual(select([only], cachedNumber: nil), .chosen(only, .display(12)))
        XCTAssertEqual(select([only], cachedNumber: nil, preferCached: false), .chosen(only, .display(12)))
    }

    // MARK: - AC6.2 캐시 번호 우선 (1순위)

    func test_AC6_2_select_cachedNumberAmongCandidates_isChosenEvenOnOtherDisplay() {
        // 후보 [새 번호 A(이전 화면 범위 = 내장), 캐시 번호 32(새 화면 범위 = Sidecar)] → 32
        let newA = Fixture.window(Fixture.newNumberA, on: Fixture.builtIn)
        let cached = Fixture.window(Fixture.cachedNumber, on: Fixture.sidecar)
        XCTAssertEqual(select([newA, cached], cachedNumber: Fixture.cachedNumber, preferCached: true),
                       .chosen(cached, .display(12)))
    }

    func test_AC6_2_select_cachedNumberFirstInList_isStillChosen() {
        let cached = Fixture.window(Fixture.cachedNumber, on: Fixture.sidecar)
        let newA = Fixture.window(Fixture.newNumberA, on: Fixture.builtIn)
        XCTAssertEqual(select([cached, newA], cachedNumber: Fixture.cachedNumber, preferCached: true),
                       .chosen(cached, .display(12)))
    }

    // MARK: - AC6.3 모든 후보가 같은 화면 (2순위)

    func test_AC6_3_select_noCache_twoCandidatesOnSameDisplay_choosesThatDisplay() {
        let a = Fixture.window(Fixture.newNumberA, on: Fixture.builtIn)
        let b = DockPinWindowInfo(number: Fixture.otherNumberB,
                                  bounds: CGRect(x: 0.5, y: 0, width: 1728, height: 1117))
        let selection = select([a, b], cachedNumber: nil)
        guard case let .chosen(info, placement) = selection else {
            return XCTFail("같은 화면 후보 둘이면 고른다. 실제: \(selection)")
        }
        XCTAssertEqual(placement, .display(1))
        XCTAssertTrue([a, b].contains(info), "고른 창은 후보 중 하나여야 한다: \(info)")
    }

    func test_AC6_3_select_cacheNotAmongCandidates_sameDisplay_choosesThatDisplay() {
        let a = Fixture.window(Fixture.newNumberA, on: Fixture.sidecar)
        let b = Fixture.window(Fixture.otherNumberB, on: Fixture.sidecar)
        let selection = select([a, b], cachedNumber: Fixture.cachedNumber)
        guard case let .chosen(info, placement) = selection else {
            return XCTFail("캐시 번호가 없어도 같은 화면 후보면 고른다. 실제: \(selection)")
        }
        XCTAssertEqual(placement, .display(12))
        XCTAssertTrue([a, b].contains(info))
    }

    // MARK: - AC6.4 서로 다른 화면 → 다시 읽기 (3순위)

    func test_AC6_4_select_noCache_candidatesOnDifferentDisplays_isAmbiguous() {
        let a = Fixture.window(Fixture.newNumberA, on: Fixture.builtIn)
        let b = Fixture.window(Fixture.otherNumberB, on: Fixture.sidecar)
        XCTAssertEqual(select([a, b], cachedNumber: nil), .ambiguous)
    }

    func test_AC6_4_select_cacheNotAmongCandidates_differentDisplays_isAmbiguous() {
        let a = Fixture.window(Fixture.newNumberA, on: Fixture.builtIn)
        let b = Fixture.window(Fixture.otherNumberB, on: Fixture.sidecar)
        XCTAssertEqual(select([a, b], cachedNumber: Fixture.cachedNumber), .ambiguous)
    }

    func test_AC6_4_settle_alwaysTwoCandidatesOnDifferentDisplays_readsExactly50Times_thenUnresolved() {
        let fake = FakeWindowReads([[Fixture.window(Fixture.newNumberA, on: Fixture.builtIn),
                                     Fixture.window(Fixture.otherNumberB, on: Fixture.sidecar)]])
        let result = settle(fake, cachedNumber: nil, preferCached: true)

        XCTAssertEqual(result.selection, .ambiguous, "50회 뒤에도 결정 못 하면 .ambiguous(→ 호출자가 .unknown)")
        XCTAssertEqual(result.reads, 50)
        XCTAssertEqual(fake.readCount, 50, "첫 읽기 포함 정확히 50회 읽는다")
    }

    func test_AC6_4_settle_pausesSettleIntervalBetweenReads_notAfterLast() {
        let fake = FakeWindowReads([[Fixture.window(Fixture.newNumberA, on: Fixture.builtIn),
                                     Fixture.window(Fixture.otherNumberB, on: Fixture.sidecar)]])
        _ = settle(fake, cachedNumber: nil, preferCached: true)

        XCTAssertEqual(fake.pauses.count, 49, "읽기 사이마다 한 번 → 50회 읽기에 49번 쉰다")
        XCTAssertEqual(fake.pauses, Array(repeating: 0.020, count: 49))
    }

    func test_R6_4_settle_respectsCustomMaxReads() {
        let fake = FakeWindowReads([[Fixture.window(Fixture.newNumberA, on: Fixture.builtIn),
                                     Fixture.window(Fixture.otherNumberB, on: Fixture.sidecar)]])
        let result = settle(fake, cachedNumber: nil, preferCached: true, maxReads: 3)

        XCTAssertEqual(result.selection, .ambiguous)
        XCTAssertEqual(result.reads, 3)
        XCTAssertEqual(fake.readCount, 3)
        XCTAssertEqual(fake.pauses.count, 2)
    }

    func test_R6_4_settle_maxReadsOne_readsOnceWithoutPause() {
        let fake = FakeWindowReads([[Fixture.window(Fixture.newNumberA, on: Fixture.builtIn),
                                     Fixture.window(Fixture.otherNumberB, on: Fixture.sidecar)]])
        let result = settle(fake, cachedNumber: nil, preferCached: true, maxReads: 1)

        XCTAssertEqual(result.selection, .ambiguous)
        XCTAssertEqual(result.reads, 1)
        XCTAssertEqual(fake.pauses, [])
    }

    func test_R6_4_settle_resolvedOnFirstRead_readsOnce_noPause() {
        let only = Fixture.window(Fixture.cachedNumber, on: Fixture.builtIn)
        let fake = FakeWindowReads([[only]])
        let result = settle(fake, cachedNumber: Fixture.cachedNumber, preferCached: true)

        XCTAssertEqual(result.selection, .chosen(only, .display(1)))
        XCTAssertEqual(result.reads, 1)
        XCTAssertEqual(fake.readCount, 1)
        XCTAssertEqual(fake.pauses, [])
    }

    func test_R6_4_settle_dockCloneDisappearsOnSecondRead_choosesRemainingWindow() {
        // DockClone: 0.10–0.25s 동안 같은 레이어 창이 하나 더 있다가 사라진다
        let real = Fixture.window(Fixture.newNumberA, on: Fixture.sidecar)
        let clone = Fixture.window(Fixture.otherNumberB, on: Fixture.builtIn)
        let fake = FakeWindowReads([[real, clone], [real]])
        let result = settle(fake, cachedNumber: nil, preferCached: true)

        XCTAssertEqual(result.selection, .chosen(real, .display(12)))
        XCTAssertEqual(result.reads, 2)
        XCTAssertEqual(fake.pauses, [0.020])
    }

    func test_R6_4_settle_noCandidates_stopsWithoutRereading() {
        // 해석(arch §2.4 enum 주석): .none(후보 0개)은 다시 읽지 않고 곧바로 끝난다. .ambiguous만 다시 읽는다
        let fake = FakeWindowReads([[]])
        let result = settle(fake, cachedNumber: nil, preferCached: true)

        XCTAssertEqual(result.selection, .none)
        XCTAssertEqual(result.reads, 1)
        XCTAssertEqual(fake.readCount, 1)
        XCTAssertEqual(fake.pauses, [])
    }

    // MARK: - AC6.8 preferCached: false (리뷰 v2 N9, R6.4 예외)

    func test_AC6_8_select_preferCachedTrue_choosesCachedOnOldDisplay() {
        // 후보 [캐시 번호 32(이전 화면 = 내장), 새 번호 A(고정 화면 = Sidecar)] → preferCached true면 32
        let cached = Fixture.window(Fixture.cachedNumber, on: Fixture.builtIn)
        let newA = Fixture.window(Fixture.newNumberA, on: Fixture.sidecar)
        XCTAssertEqual(select([cached, newA], cachedNumber: Fixture.cachedNumber, preferCached: true),
                       .chosen(cached, .display(1)))
    }

    func test_AC6_8_select_preferCachedFalse_doesNotPickCached_rereads() {
        let cached = Fixture.window(Fixture.cachedNumber, on: Fixture.builtIn)
        let newA = Fixture.window(Fixture.newNumberA, on: Fixture.sidecar)
        XCTAssertEqual(select([cached, newA], cachedNumber: Fixture.cachedNumber, preferCached: false),
                       .ambiguous)
    }

    func test_AC6_8_select_preferCachedFalse_sameDisplayCandidates_stillChooseByRule2() {
        let cached = Fixture.window(Fixture.cachedNumber, on: Fixture.sidecar)
        let newA = Fixture.window(Fixture.newNumberA, on: Fixture.sidecar)
        let selection = select([cached, newA], cachedNumber: Fixture.cachedNumber, preferCached: false)
        guard case let .chosen(_, placement) = selection else {
            return XCTFail("preferCached false여도 2순위(같은 화면)는 쓴다. 실제: \(selection)")
        }
        XCTAssertEqual(placement, .display(12))
    }

    func test_AC6_8_settle_preferCachedTrue_choosesCachedOnFirstRead() {
        let cached = Fixture.window(Fixture.cachedNumber, on: Fixture.builtIn)
        let newA = Fixture.window(Fixture.newNumberA, on: Fixture.sidecar)
        let fake = FakeWindowReads([[cached, newA], [newA]])
        let result = settle(fake, cachedNumber: Fixture.cachedNumber, preferCached: true)

        XCTAssertEqual(result.selection, .chosen(cached, .display(1)))
        XCTAssertEqual(result.reads, 1)
    }

    func test_AC6_8_settle_preferCachedFalse_nextReadOnlyA_isPinnedDisplay() {
        let cached = Fixture.window(Fixture.cachedNumber, on: Fixture.builtIn)
        let newA = Fixture.window(Fixture.newNumberA, on: Fixture.sidecar)
        let fake = FakeWindowReads([[cached, newA], [newA]])
        let result = settle(fake, cachedNumber: Fixture.cachedNumber, preferCached: false)

        XCTAssertEqual(result.selection, .chosen(newA, .display(12)), "다시 읽어 A 하나면 고정 화면(Sidecar)")
        XCTAssertEqual(result.reads, 2)
        XCTAssertEqual(fake.pauses, [0.020])
    }

    func test_AC6_8_settle_preferCachedFalse_alwaysBoth_unresolvedAfter50Reads() {
        let cached = Fixture.window(Fixture.cachedNumber, on: Fixture.builtIn)
        let newA = Fixture.window(Fixture.newNumberA, on: Fixture.sidecar)
        let fake = FakeWindowReads([[cached, newA]])
        let result = settle(fake, cachedNumber: Fixture.cachedNumber, preferCached: false)

        XCTAssertEqual(result.selection, .ambiguous)
        XCTAssertEqual(result.reads, 50)
        XCTAssertEqual(fake.readCount, 50)
    }

    // MARK: - AC6.5 scanBackoff

    func test_AC6_5_scanBackoff_consecutiveFailures1to7_is3_6_12_24_48_60_60() {
        let delays = (1...7).map { DockPinPlacementRules.scanBackoff(consecutiveFailures: $0) }
        XCTAssertEqual(delays, [3, 6, 12, 24, 48, 60, 60])
    }

    func test_AC6_5_scanBackoff_zeroOrNegativeFailures_isZero() {
        XCTAssertEqual(DockPinPlacementRules.scanBackoff(consecutiveFailures: 0), 0)
        XCTAssertEqual(DockPinPlacementRules.scanBackoff(consecutiveFailures: -1), 0)
        // 짝 단정: 1회 실패는 0이 아니다(스텁과 구분되도록 양성 값도 확인)
        XCTAssertEqual(DockPinPlacementRules.scanBackoff(consecutiveFailures: 1), 3)
    }

    func test_AC6_5_scanBackoff_manyFailures_capsAt60() {
        XCTAssertEqual(DockPinPlacementRules.scanBackoff(consecutiveFailures: 100), 60)
        XCTAssertEqual(DockPinPlacementRules.scanBackoff(consecutiveFailures: Int.max), 60)
    }

    func test_AC6_5_scanBackoff_matchesTuningTable() {
        for (index, expected) in DockPinTuning.scanBackoff.enumerated() {
            XCTAssertEqual(DockPinPlacementRules.scanBackoff(consecutiveFailures: index + 1), expected,
                           "연속 실패 \(index + 1)회")
        }
    }
}

// MARK: - DockPinDockLocatorTests (커밋 6)
//
// 커버: AC6.6(조회는 메인 밖, 결과는 메인) + arch §2.8 조회기 규칙
//   R6.1 PID 없음·캐시 비우기, R6.2 PID + 레이어 20, R6.3 단일 조회/승격, R6.4 재읽기(주입 pause)·N9 preferCached,
//   R6.5 진행 중 합치기(가장 센 모드)·동시 조회 0, R6.6 백오프 3/6초·성공 초기화·이벤트 계기 무시,
//   I1 이벤트 계기 1초 속도 제한은 버리지 않고 `scanRateLimit`으로 미룬다, cancelAll 세대.
//
// 실제 DockPinDockLocator + 실제 조회 큐(.utility)를 쓰고, 창 목록·Dock 설정·스케줄러·pause는 가짜다.
// 안전: 실제 CGWindowList·이벤트 탭·이벤트 전송·커서 이동 0. 시간은 가짜 스케줄러의 now/advance로만 흐르고
// pause는 기록만 한다. 실제 대기는 큐 → 메인 왕복뿐이다(expectation 상한 1초).
//
// RED 확인 방법: 스텁 locate는 조회 없이 그 자리에서 .deferred를 돌려주므로 아래 단정은 전부 실패한다.
// 기대값이 .deferred인 단정에는 같은 테스트 안에 양성 단정(.placement·조회 횟수)을 짝으로 둔다.

@MainActor
final class DockPinDockLocatorTests: XCTestCase {

    private static let timeout: TimeInterval = 1.0

    private struct SUT {
        let locator: DockPinDockLocator
        let listing: FakeDockPinWindowListing
        let preferences: FakeDockPinDockPreferences
        let scheduler: FakeDockPinScheduler
        let pause: FakeDockPinPause
    }

    /// 요청 하나의 completion 기록
    private final class Completions {
        private(set) var outcomes: [DockPinLocateOutcome] = []
        private(set) var onMainThread: [Bool] = []
        let expectation: XCTestExpectation

        init(_ expectation: XCTestExpectation) { self.expectation = expectation }

        func record(_ outcome: DockPinLocateOutcome) {
            outcomes.append(outcome)
            onMainThread.append(Thread.isMainThread)
            expectation.fulfill()
        }
    }

    private func makeSUT(script: [[DockPinWindowInfo]] = [],
                         singleWindows: [CGWindowID: DockPinWindowInfo] = [:]) -> SUT {
        let listing = FakeDockPinWindowListing(script: script, singleWindows: singleWindows)
        let preferences = FakeDockPinDockPreferences()
        let scheduler = FakeDockPinScheduler()
        let pause = FakeDockPinPause()
        let locator = DockPinDockLocator(listing: listing, dockPreferences: preferences,
                                         scheduler: scheduler, pause: pause.closure)
        return SUT(locator: locator, listing: listing, preferences: preferences,
                   scheduler: scheduler, pause: pause)
    }

    @discardableResult
    private func request(_ sut: SUT, _ mode: DockPinLocateMode,
                         displays: [DockPinDisplay] = DockPinFixtures.thisMac) -> Completions {
        // 등록하지 않는 expectation — 취소 테스트처럼 끝내 기다리지 않는 요청도 실패로 남지 않게 한다
        let expectation = XCTestExpectation(description: "locate(\(mode))")
        expectation.assertForOverFulfill = false     // 두 번 불리면 outcomes.count로 잡는다
        let completions = Completions(expectation)
        sut.locator.locate(mode, displays: displays) { completions.record($0) }
        return completions
    }

    private func waitFor(_ completions: Completions...) {
        wait(for: completions.map(\.expectation), timeout: Self.timeout)
    }

    /// 요청 1개를 보내고 결과를 기다린다. completion은 정확히 1번이어야 한다.
    private func locateAndWait(_ sut: SUT, _ mode: DockPinLocateMode,
                               file: StaticString = #filePath, line: UInt = #line) -> DockPinLocateOutcome? {
        let completions = request(sut, mode)
        waitFor(completions)
        XCTAssertEqual(completions.outcomes.count, 1, "completion은 정확히 1번", file: file, line: line)
        return completions.outcomes.first
    }

    private let builtInID = DockPinFixtures.builtIn.id
    private let sidecarID = DockPinFixtures.sidecar.id
    private let cached = DockPinFixtures.dockWindowNumber

    // MARK: - AC6.6 조회 스레드

    func test_AC6_6_fullScan_listingCalledOffMainThread_completionOnMain() {
        let sut = makeSUT(script: [[DockPinFixtures.window(cached, on: DockPinFixtures.sidecar)]])

        let completions = request(sut, .full)
        waitFor(completions)

        XCTAssertEqual(completions.outcomes, [.placement(.display(sidecarID))])
        XCTAssertFalse(sut.listing.calledOnMainThread.isEmpty, "창 목록이 한 번은 불려야 한다")
        XCTAssertEqual(sut.listing.calledOnMainThread, [false], "창 목록은 조회 큐(메인 아님)에서만")
        XCTAssertEqual(completions.onMainThread, [true], "결과는 메인으로 돌아온다")
    }

    func test_AC6_6_quickSingleLookup_alsoOffMainThread() {
        let sut = makeSUT(script: [[DockPinFixtures.window(cached, on: DockPinFixtures.sidecar)]],
                          singleWindows: [cached: DockPinFixtures.window(cached, on: DockPinFixtures.builtIn)])

        XCTAssertEqual(locateAndWait(sut, .full), .placement(.display(sidecarID)))
        let quick = request(sut, .quick)
        waitFor(quick)

        XCTAssertEqual(quick.outcomes, [.placement(.display(builtInID))])
        XCTAssertEqual(sut.listing.windowCalls, [cached])
        XCTAssertEqual(sut.listing.calledOnMainThread, [false, false])
        XCTAssertEqual(quick.onMainThread, [true])
    }

    // MARK: - R6.1 / R6.2 PID와 레이어

    func test_R6_2_fullScan_queriesDockPIDAtDockLayer20() {
        let sut = makeSUT(script: [[DockPinFixtures.window(cached, on: DockPinFixtures.sidecar)]])

        XCTAssertEqual(locateAndWait(sut, .full), .placement(.display(sidecarID)))
        XCTAssertEqual(sut.listing.dockWindowsCalls,
                       [.init(pid: DockPinFixtures.dockPID, layer: 20)])
        XCTAssertGreaterThanOrEqual(sut.preferences.pidReadCount, 1, "PID는 메인에서 dockPID()로 읽는다(R6.1)")
    }

    func test_R6_1_noDockPID_unknownWithoutListing() {
        let sut = makeSUT(script: [[DockPinFixtures.window(cached, on: DockPinFixtures.sidecar)]])
        sut.preferences.pid = nil

        XCTAssertEqual(locateAndWait(sut, .full), .placement(.unknown))
        XCTAssertEqual(sut.listing.totalCallCount, 0, "PID가 없으면 창 목록을 읽지 않는다")

        // 짝 단정: Dock이 다시 뜨면(PID 있음) 같은 조회기로 찾는다. 이벤트 계기라 백오프와 무관하다.
        sut.preferences.pid = DockPinFixtures.dockPID
        XCTAssertEqual(locateAndWait(sut, .event), .placement(.display(sidecarID)))
    }

    func test_R6_1_invalidateCache_nextQuickDoesFullScan() {
        let sut = makeSUT(script: [[DockPinFixtures.window(cached, on: DockPinFixtures.sidecar)]],
                          singleWindows: [cached: DockPinFixtures.window(cached, on: DockPinFixtures.builtIn)])

        XCTAssertEqual(locateAndWait(sut, .full), .placement(.display(sidecarID)))
        sut.locator.invalidateCache()
        XCTAssertEqual(locateAndWait(sut, .quick), .placement(.display(sidecarID)))

        XCTAssertEqual(sut.listing.windowCalls, [], "캐시를 비웠으므로 단일 조회를 하지 않는다")
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 2)
    }

    // MARK: - R6.3 단일 조회와 승격

    func test_R6_3_quickWithoutCache_promotesToFullScan() {
        let sut = makeSUT(script: [[DockPinFixtures.window(cached, on: DockPinFixtures.sidecar)]])

        XCTAssertEqual(locateAndWait(sut, .quick), .placement(.display(sidecarID)))
        XCTAssertEqual(sut.listing.windowCalls, [])
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 1)
    }

    func test_R6_3_quickWithCache_usesSingleLookupOnly() {
        let sut = makeSUT(script: [[DockPinFixtures.window(cached, on: DockPinFixtures.sidecar)]],
                          singleWindows: [cached: DockPinFixtures.window(cached, on: DockPinFixtures.sidecar)])

        XCTAssertEqual(locateAndWait(sut, .full), .placement(.display(sidecarID)))
        XCTAssertEqual(locateAndWait(sut, .quick), .placement(.display(sidecarID)))
        XCTAssertEqual(locateAndWait(sut, .quick), .placement(.display(sidecarID)))

        XCTAssertEqual(sut.listing.windowCalls, [cached, cached])
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 1, "캐시가 있으면 전체 목록을 다시 읽지 않는다")
    }

    func test_R6_3_fullWithCache_stillScansFullList() {
        // 단일 조회라면 내장 화면을 돌려줄 창 — .full이 이것을 쓰면 안 된다
        let sut = makeSUT(script: [[DockPinFixtures.window(cached, on: DockPinFixtures.sidecar)]],
                          singleWindows: [cached: DockPinFixtures.window(cached, on: DockPinFixtures.builtIn)])

        XCTAssertEqual(locateAndWait(sut, .full), .placement(.display(sidecarID)))     // 캐시 43
        XCTAssertEqual(locateAndWait(sut, .full), .placement(.display(sidecarID)),
                       ".full은 캐시가 있어도 전체 목록을 읽는다(단일 조회는 .quick만)")

        XCTAssertEqual(sut.listing.windowCalls, [])
        XCTAssertEqual(sut.listing.dockWindowsCalls,
                       [.init(pid: DockPinFixtures.dockPID, layer: 20),
                        .init(pid: DockPinFixtures.dockPID, layer: 20)])
    }

    /// 캐시 창이 사라졌는데 백오프 중이면 전체 조회로 넘어가지 않고 .deferred, 캐시는 비운다(R6.3 + R6.6).
    /// 캐시와 백오프가 함께 있으려면: 전체 조회가 창을 골랐지만 어느 화면에도 겹치지 않아 .unknown(실패 1, 캐시 설정).
    func test_R6_3_quickCachedWindowGoneDuringBackoff_deferredAndCacheCleared() {
        let offscreen = DockPinFixtures.window(cached, on: DockPinFixtures.external2560)   // thisMac 밖
        let sut = makeSUT(script: [[offscreen]], singleWindows: [:])
        sut.scheduler.now = 1000
        XCTAssertEqual(locateAndWait(sut, .full), .placement(.unknown))     // 캐시 43 + 백오프 3초

        sut.scheduler.now = 1001
        XCTAssertEqual(locateAndWait(sut, .quick), .deferred, "창이 사라졌고 백오프 중 — 전체 조회 없음")
        XCTAssertEqual(sut.listing.windowCalls, [cached])
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 1)

        // 캐시를 비웠다: 다음 .quick은 단일 조회 없이 .full로 승격 → 아직 백오프라 .deferred
        XCTAssertEqual(locateAndWait(sut, .quick), .deferred)
        XCTAssertEqual(sut.listing.windowCalls, [cached], "비운 캐시로 단일 조회를 다시 하지 않는다")
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 1)

        // 짝 단정: 백오프가 끝나면 같은 .quick이 전체 조회로 찾는다
        sut.listing.script = [[DockPinFixtures.window(cached, on: DockPinFixtures.sidecar)]]
        sut.scheduler.now = 1003
        XCTAssertEqual(locateAndWait(sut, .quick), .placement(.display(sidecarID)))
        XCTAssertEqual(sut.listing.windowCalls, [cached])
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 2)
    }

    func test_R6_3_quickCachedWindowGone_fallsBackToFullScan() {
        let replacement: CGWindowID = 44
        let sut = makeSUT(script: [[DockPinFixtures.window(cached, on: DockPinFixtures.sidecar)],
                                   [DockPinFixtures.window(replacement, on: DockPinFixtures.builtIn)]],
                          singleWindows: [:])

        XCTAssertEqual(locateAndWait(sut, .full), .placement(.display(sidecarID)))
        XCTAssertEqual(locateAndWait(sut, .quick), .placement(.display(builtInID)))

        XCTAssertEqual(sut.listing.windowCalls, [cached])
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 2)
    }

    // MARK: - R6.4 재읽기 (주입 pause) / N9 preferCached

    func test_R6_4_ambiguousCandidates_rereadWithInjectedPause() {
        let onBuiltIn = DockPinFixtures.window(50, on: DockPinFixtures.builtIn)
        let onSidecar = DockPinFixtures.window(51, on: DockPinFixtures.sidecar)
        let sut = makeSUT(script: [[onBuiltIn, onSidecar], [onSidecar]])

        XCTAssertEqual(locateAndWait(sut, .full), .placement(.display(sidecarID)))
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 2)
        XCTAssertEqual(sut.pause.intervals, [DockPinTuning.settleRetryInterval])
    }

    func test_AC6_4_locator_alwaysAmbiguous_unknownAfter50Reads() {
        let onBuiltIn = DockPinFixtures.window(50, on: DockPinFixtures.builtIn)
        let onSidecar = DockPinFixtures.window(51, on: DockPinFixtures.sidecar)
        let sut = makeSUT(script: [[onBuiltIn, onSidecar]])

        XCTAssertEqual(locateAndWait(sut, .full), .placement(.unknown))
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, DockPinTuning.settleMaxReads)
        XCTAssertEqual(sut.pause.intervals.count, DockPinTuning.settleMaxReads - 1)
    }

    /// 32(이전 화면) 캐시 + 새 번호 77(고정 화면)
    private func makeStaleCacheSUT() -> SUT {
        let stale = DockPinFixtures.window(32, on: DockPinFixtures.builtIn)
        let fresh = DockPinFixtures.window(77, on: DockPinFixtures.sidecar)
        return makeSUT(script: [[stale], [stale, fresh], [fresh]])
    }

    func test_AC6_8_locator_finalMode_skipsCachedPreference() {
        let sut = makeStaleCacheSUT()

        XCTAssertEqual(locateAndWait(sut, .full), .placement(.display(builtInID)))    // 32 캐시
        XCTAssertEqual(locateAndWait(sut, .final), .placement(.display(sidecarID)),
                       ".final은 preferCached: false — 32를 바로 고르지 않고 다시 읽는다")
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 3)
        XCTAssertEqual(sut.pause.intervals, [DockPinTuning.settleRetryInterval])
    }

    func test_AC6_8_locator_eventMode_keepsCachedPreference() {
        let sut = makeStaleCacheSUT()

        XCTAssertEqual(locateAndWait(sut, .full), .placement(.display(builtInID)))
        XCTAssertEqual(locateAndWait(sut, .event), .placement(.display(builtInID)),
                       ".event는 preferCached: true — 캐시 번호 32를 고른다(AC6.2)")
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 2)
        XCTAssertEqual(sut.pause.intervals, [])
    }

    // MARK: - R6.5 합치기 / 동시 조회 0

    func test_R6_5_requestsWhileInFlight_coalescedIntoOneFollowUpScan() {
        let sut = makeSUT(script: [[DockPinFixtures.window(cached, on: DockPinFixtures.sidecar)]])
        sut.listing.hold()
        defer { sut.listing.release() }

        let first = request(sut, .full)
        let quick = request(sut, .quick)
        let event = request(sut, .event)
        sut.listing.release()
        waitFor(first, quick, event)

        for completions in [first, quick, event] {
            XCTAssertEqual(completions.outcomes, [.placement(.display(sidecarID))])
            XCTAssertEqual(completions.onMainThread, [true])
        }
        XCTAssertEqual(sut.listing.totalCallCount, 2, "진행 중 1회 + 합친 1회(가장 센 .event → 전체 조회)")
        XCTAssertEqual(sut.listing.windowCalls, [], "합친 요청은 .quick이 아니라 .event로 돈다")
        XCTAssertEqual(sut.listing.maxConcurrentCalls, 1, "동시에 두 조회가 돌지 않는다")
    }

    func test_R6_5_pendingMerge_finalOutranksEvent() {
        let sut = makeStaleCacheSUT()
        sut.listing.hold()
        defer { sut.listing.release() }

        let first = request(sut, .full)
        let event = request(sut, .event)
        let final = request(sut, .final)
        sut.listing.release()
        waitFor(first, event, final)

        XCTAssertEqual(first.outcomes, [.placement(.display(builtInID))])
        XCTAssertEqual(event.outcomes, [.placement(.display(sidecarID))], "합친 모드는 .final(preferCached: false)")
        XCTAssertEqual(final.outcomes, [.placement(.display(sidecarID))])
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 3)
        XCTAssertEqual(sut.listing.maxConcurrentCalls, 1)
    }

    // MARK: - R6.6 백오프

    func test_R6_6_fullScanFailure_defersFullScansFor3s() {
        let sut = makeSUT(script: [[]])
        sut.scheduler.now = 1000

        XCTAssertEqual(locateAndWait(sut, .full), .placement(.unknown))
        sut.scheduler.now = 1002.9
        XCTAssertEqual(locateAndWait(sut, .full), .deferred)
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 1, "백오프 중 전체 조회 없음")

        sut.scheduler.now = 1003
        XCTAssertEqual(locateAndWait(sut, .full), .placement(.unknown))
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 2)
    }

    func test_R6_6_secondConsecutiveFailure_backoff6s() {
        let sut = makeSUT(script: [[]])
        sut.scheduler.now = 1000
        XCTAssertEqual(locateAndWait(sut, .full), .placement(.unknown))
        sut.scheduler.now = 1003
        XCTAssertEqual(locateAndWait(sut, .full), .placement(.unknown))

        sut.scheduler.now = 1008.9
        XCTAssertEqual(locateAndWait(sut, .full), .deferred)
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 2)

        sut.scheduler.now = 1009
        XCTAssertEqual(locateAndWait(sut, .full), .placement(.unknown))
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 3)
    }

    func test_R6_6_successResetsBackoff() {
        let sut = makeSUT(script: [[], [DockPinFixtures.window(cached, on: DockPinFixtures.sidecar)]])
        sut.scheduler.now = 1000
        XCTAssertEqual(locateAndWait(sut, .full), .placement(.unknown))
        sut.scheduler.now = 1003
        XCTAssertEqual(locateAndWait(sut, .full), .placement(.display(sidecarID)))

        sut.locator.invalidateCache()     // 전체 조회가 다시 돌게 캐시만 비운다
        XCTAssertEqual(locateAndWait(sut, .full), .placement(.display(sidecarID)), "성공 뒤 백오프 없음")
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 3)
    }

    func test_R6_6_eventIgnoresBackoff() {
        let sut = makeSUT(script: [[]])
        sut.scheduler.now = 1000
        XCTAssertEqual(locateAndWait(sut, .full), .placement(.unknown))

        sut.scheduler.now = 1000.5
        XCTAssertEqual(locateAndWait(sut, .event), .placement(.unknown))
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 2)
        XCTAssertEqual(sut.scheduler.pendingCount(.scanRateLimit), 0)
    }

    func test_R6_6_quickWithoutCacheDuringBackoff_isDeferred() {
        let sut = makeSUT(script: [[]])
        sut.scheduler.now = 1000
        XCTAssertEqual(locateAndWait(sut, .full), .placement(.unknown))

        sut.scheduler.now = 1001
        XCTAssertEqual(locateAndWait(sut, .quick), .deferred, "캐시 없는 .quick은 .full로 승격 — 백오프를 지킨다")
        XCTAssertEqual(sut.listing.totalCallCount, 1)
    }

    /// 실패 → 성공 → 실패: 성공이 연속 실패 횟수를 0으로 돌렸으므로 다음 실패는 1번째(3초), 그다음은 2번째(6초)다.
    func test_R6_6_failureAfterSuccess_restartsBackoffAt3s() {
        let sut = makeSUT(script: [[], [DockPinFixtures.window(cached, on: DockPinFixtures.sidecar)], []])
        sut.scheduler.now = 1000
        XCTAssertEqual(locateAndWait(sut, .full), .placement(.unknown))                // 실패 1
        sut.scheduler.now = 1003
        XCTAssertEqual(locateAndWait(sut, .full), .placement(.display(sidecarID)))     // 성공 → 초기화
        XCTAssertEqual(locateAndWait(sut, .full), .placement(.unknown))                // 다시 실패 1 (6초 아님)
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 3)

        sut.scheduler.now = 1005.9
        XCTAssertEqual(locateAndWait(sut, .full), .deferred, "성공 뒤 첫 실패의 백오프는 3초")
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 3)
        sut.scheduler.now = 1006
        XCTAssertEqual(locateAndWait(sut, .full), .placement(.unknown), "+3초에 전체 조회 허용")
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 4)

        // 연속 실패 횟수도 다시 셌다: 이번이 2번째 → 6초
        sut.scheduler.now = 1011.9
        XCTAssertEqual(locateAndWait(sut, .full), .deferred)
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 4)
        sut.scheduler.now = 1012
        XCTAssertEqual(locateAndWait(sut, .full), .placement(.unknown))
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 5)
    }

    // MARK: - I1 이벤트 계기 1초 속도 제한 (버리지 않고 미룬다)

    func test_I1_eventWithin1s_deferredViaScanRateLimit_thenRuns() {
        let sut = makeSUT(script: [[DockPinFixtures.window(cached, on: DockPinFixtures.sidecar)]])
        sut.scheduler.now = 1000
        XCTAssertEqual(locateAndWait(sut, .event), .placement(.display(sidecarID)))

        sut.scheduler.now = 1000.3
        let second = request(sut, .event)
        XCTAssertEqual(sut.scheduler.pendingCount(.scanRateLimit), 1, "1초 안의 이벤트 계기 조회는 예약으로 미룬다")
        XCTAssertEqual(sut.scheduler.timeUntilNext(.scanRateLimit) ?? -1, 0.7, accuracy: 1e-6)
        XCTAssertEqual(second.outcomes, [], "버리지 않는다 — 아직 결과 없음(.deferred 아님)")

        sut.scheduler.advance(by: 0.7)
        waitFor(second)
        XCTAssertEqual(second.outcomes, [.placement(.display(sidecarID))])
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 2)
    }

    func test_I1_finalWithin1s_alsoRateLimited() {
        let sut = makeSUT(script: [[DockPinFixtures.window(cached, on: DockPinFixtures.sidecar)]])
        sut.scheduler.now = 1000
        XCTAssertEqual(locateAndWait(sut, .event), .placement(.display(sidecarID)))

        sut.scheduler.now = 1000.4
        let final = request(sut, .final)
        XCTAssertEqual(sut.scheduler.pendingCount(.scanRateLimit), 1)
        XCTAssertEqual(sut.scheduler.timeUntilNext(.scanRateLimit) ?? -1, 0.6, accuracy: 1e-6)

        sut.scheduler.advance(by: 0.6)
        waitFor(final)
        XCTAssertEqual(final.outcomes, [.placement(.display(sidecarID))])
    }

    func test_I1_eventAfter1s_runsImmediately() {
        let sut = makeSUT(script: [[DockPinFixtures.window(cached, on: DockPinFixtures.sidecar)]])
        sut.scheduler.now = 1000
        XCTAssertEqual(locateAndWait(sut, .event), .placement(.display(sidecarID)))

        sut.scheduler.now = 1001
        XCTAssertEqual(locateAndWait(sut, .event), .placement(.display(sidecarID)))
        XCTAssertEqual(sut.scheduler.pendingCount(.scanRateLimit), 0)
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 2)
    }

    // MARK: - cancelAll (세대)

    func test_cancelAll_inFlightResultDropped_cacheNotUpdated() {
        let sut = makeSUT(script: [[DockPinFixtures.window(cached, on: DockPinFixtures.sidecar)]],
                          singleWindows: [cached: DockPinFixtures.window(cached, on: DockPinFixtures.builtIn)])
        sut.listing.hold()
        defer { sut.listing.release() }

        let cancelled = request(sut, .full)
        sut.locator.cancelAll()
        sut.listing.release()

        let next = request(sut, .quick)
        waitFor(next)

        XCTAssertEqual(cancelled.outcomes, [], "취소된 요청의 completion은 0번")
        XCTAssertEqual(next.outcomes, [.placement(.display(sidecarID))])
        XCTAssertEqual(sut.listing.windowCalls, [], "버린 결과로 캐시를 채우지 않는다")
        XCTAssertEqual(sut.listing.dockWindowsCalls.count, 2)
    }

    func test_cancelAll_pendingCompletionsDropped() {
        let sut = makeSUT(script: [[DockPinFixtures.window(cached, on: DockPinFixtures.sidecar)]])
        sut.listing.hold()
        defer { sut.listing.release() }

        let inFlight = request(sut, .full)
        let pending = request(sut, .quick)
        sut.locator.cancelAll()
        sut.listing.release()

        let next = request(sut, .event)
        waitFor(next)

        XCTAssertEqual(inFlight.outcomes, [])
        XCTAssertEqual(pending.outcomes, [])
        XCTAssertEqual(next.outcomes, [.placement(.display(sidecarID))])
    }
}
