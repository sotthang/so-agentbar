import XCTest
import CoreGraphics
@testable import SoAgentBar

// MARK: - DockPinPlacementTests
//
// SPEC-004 커밋 3 — 순수 계층(DockPinPlacement.swift) 단위 테스트.
// 커버 AC: AC6.1–6.5, AC6.7, AC6.8 (AC6.6은 커밋 6에서 이 파일에 추가한다).
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
