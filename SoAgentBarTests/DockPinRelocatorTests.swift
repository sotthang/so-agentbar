import XCTest
import CoreGraphics
@testable import SoAgentBar

// MARK: - DockPinRelocatorTests
//
// SPEC-004 커밋 7 — DockPinRelocator(arch §2.9) + DockPinDrivePath 단위 테스트.
// 커버 AC: AC8.2, AC8.3, AC8.4, AC8.4b, AC8.4c(Relocator부), AC8.5, AC8.9(Relocator부) + R8.3-1(커서 못 읽음),
//          abort 계약(진행 중일 때만, completion 정확히 1번), 틱 종류(.driveTick 16 ms / .finalScanTimeout 1.2 s).
//
// 안전: 실제 이벤트 전송·탭·커서 이동·창 조회가 없다. 가짜 전송기·조회기·스케줄러만 쓰고,
// 시간은 FakeDockPinScheduler.advance(by:)로만 흐른다(실제 sleep 없음).
//
// RED 확인 방법: 이 파일은 컴파일된다(so-tester가 arch §2.9 시그니처의 스텁을 넣었다).
// 스텁은 approach가 빈 배열, start·abort가 무동작, isActive가 항상 false다 → 아래 테스트는 전부 실패하는 것이 정상이다.
// 기대값이 스텁 결과와 겹치는 단정(이벤트 0, completion 0 등)은 같은 테스트 안에 양성 짝 단정을 둔다.
//
// 시각 해석(개발자 메모): 다가가기 첫 이벤트가 start() 안에서 바로 나가든 첫 틱(16 ms 뒤)에 나가든 통과하도록
// 시각은 모두 "15번째 이동(목표 줄 도달) 시각 reachedAt"을 기준으로 잰다.

@MainActor
final class DockPinRelocatorTests: XCTestCase {

    // MARK: - 고정값

    private enum Fixture {
        static let anchor = DockPinFixtures.builtIn           // id 1, (0,0,1728,1117)
        static let sidecar = DockPinFixtures.sidecar          // id 12
        /// AC3.10 — 이 Mac, 대상 .main의 목표점
        static let target = CGPoint(x: 864, y: 1116)
        /// 되돌리기 시작 때 커서(Sidecar 위)
        static let saved = CGPoint(x: 2000, y: 400)
        /// AC8.9 — 내장 화면 가운데
        static let anchorCenter = CGPoint(x: 864, y: 558.5)
        static var plan: DockPinDrivePlan {
            DockPinDrivePlan(target: target, anchorID: anchor.id, displays: DockPinFixtures.thisMac)
        }
        /// AC8.2 — 목표 y=1116의 다가가기 y 값(15점)
        static let approachYs: [CGFloat] = [1076, 1079, 1082, 1085, 1088, 1091, 1094, 1097,
                                            1100, 1103, 1106, 1109, 1112, 1115, 1116]
        static let tick = DockPinTuning.driveInterval        // 0.016
        static let eps: TimeInterval = 1e-6
        static let onAnchor = DockPinLocateOutcome.placement(.display(anchor.id))
        static let onSidecar = DockPinLocateOutcome.placement(.display(sidecar.id))
    }

    // MARK: - 하네스

    /// 가짜 의존성과 기록을 묶는다. 조회 응답은 모드별 클로저(시작 뒤 경과 시간을 받는다, nil = 응답 안 함).
    @MainActor
    private final class Harness {
        let scheduler = FakeDockPinScheduler()
        let log = DockPinCallLog()
        let poster: FakeDockPinPoster
        let locator: FakeDockPinLocator
        private(set) var relocator: DockPinRelocator!

        var activity: UInt64 = 0
        var restoreResult: (CGPoint) -> CGPoint? = { $0 }
        private(set) var restoreArgs: [CGPoint] = []

        /// .quick 응답(기본: 계속 Sidecar)
        var quickAnswer: (TimeInterval) -> DockPinLocateOutcome? = { _ in Fixture.onSidecar }
        /// .final 응답(기본: 응답 안 함 — 테스트가 completePending으로 답한다)
        var finalAnswer: (TimeInterval) -> DockPinLocateOutcome? = { _ in nil }
        private(set) var quickTimes: [TimeInterval] = []
        private(set) var finalTimes: [TimeInterval] = []
        private(set) var otherModes: [DockPinLocateMode] = []

        private(set) var startedAt: TimeInterval = 0
        private(set) var outcomes: [DockPinDriveOutcome] = []
        private(set) var completionTimes: [TimeInterval] = []
        private(set) var lastMoveAtCompletion: [CGPoint?] = []
        private(set) var moveCountAtCompletion: [Int] = []

        init() {
            poster = FakeDockPinPoster(log: log)
            locator = FakeDockPinLocator(scheduler: scheduler, log: log)
            poster.cursor = Fixture.saved
            let scheduler = self.scheduler
            poster.clock = { scheduler.now }
            locator.respond = { [unowned self] mode, now in self.answer(mode, now) }
            relocator = DockPinRelocator(poster: poster, locator: locator, scheduler: scheduler,
                                         userActivityCount: { [unowned self] in self.activity },
                                         restorePoint: { [unowned self] saved in
                                             self.restoreArgs.append(saved)
                                             return self.restoreResult(saved)
                                         })
        }

        private func answer(_ mode: DockPinLocateMode, _ now: TimeInterval) -> DockPinLocateOutcome? {
            switch mode {
            case .quick:
                quickTimes.append(now)
                return quickAnswer(now - startedAt)
            case .final:
                finalTimes.append(now)
                return finalAnswer(now - startedAt)
            case .full, .event:
                otherModes.append(mode)
                return .placement(.unknown)
            }
        }

        func start(_ plan: DockPinDrivePlan = Fixture.plan) {
            startedAt = scheduler.now
            relocator.start(plan) { [unowned self] outcome in
                self.outcomes.append(outcome)
                self.completionTimes.append(self.scheduler.now)
                self.lastMoveAtCompletion.append(self.poster.moves.last)
                self.moveCountAtCompletion.append(self.poster.moves.count)
            }
        }

        func advance(_ seconds: TimeInterval) { scheduler.advance(by: seconds) }
        func ticks(_ n: Int) { scheduler.advance(by: Double(n) * Fixture.tick) }

        /// 15번째 이동(목표 줄 도달) 시각
        var reachedAt: TimeInterval? { poster.moveTimes.count >= 15 ? poster.moveTimes[14] : nil }
        var finalRequestCount: Int { locator.requests.filter { $0 == .final }.count }
    }

    // MARK: - AC8.2 다가가기 경로 (순수)

    func test_AC8_2_approachPath_targetY1116_fifteenPointsEndingOnRow() {
        let path = DockPinDrivePath.approach(to: Fixture.target)

        XCTAssertEqual(path.count, 15)
        XCTAssertEqual(path.map(\.y), Fixture.approachYs)
        XCTAssertTrue(path.allSatisfy { $0.x == Fixture.target.x }, "x는 모두 목표 x")
        XCTAssertEqual(path.last, Fixture.target, "마지막 걸음은 목표 줄(리뷰 N3)")
    }

    func test_AC8_2_approachPath_defaultsAreTuningValues() {
        let explicit = DockPinDrivePath.approach(to: Fixture.target,
                                                 height: DockPinTuning.approachHeight,
                                                 step: DockPinTuning.approachStep)
        XCTAssertEqual(explicit.count, 15)
        XCTAssertEqual(DockPinDrivePath.approach(to: Fixture.target), explicit)
    }

    func test_AC8_2_approachPath_lastStepSnapsToRow_withoutDuplicate() {
        // 높이가 걸음으로 나누어떨어지면 0이 한 번만 나온다
        let even = DockPinDrivePath.approach(to: CGPoint(x: 10, y: 100), height: 9, step: 3)
        XCTAssertEqual(even.map(\.y), [91, 94, 97, 100])

        // 나누어떨어지지 않으면 마지막 걸음만 짧아진다
        let uneven = DockPinDrivePath.approach(to: CGPoint(x: 10, y: 100), height: 10, step: 4)
        XCTAssertEqual(uneven.map(\.y), [90, 94, 98, 100])
        XCTAssertTrue(uneven.allSatisfy { $0.x == 10 })
    }

    // MARK: - AC8.2 전송 기록

    func test_AC8_2_driving_postsApproachThenRepeatsTarget() {
        let h = Harness()
        h.start()
        h.ticks(15 + 30)

        let moves = h.poster.moves
        XCTAssertGreaterThanOrEqual(moves.count, 40, "다가가기 15점 + 목표 줄 유지")
        XCTAssertEqual(Array(moves.prefix(15)).map(\.y), Fixture.approachYs)
        XCTAssertTrue(moves.prefix(15).allSatisfy { $0.x == Fixture.target.x })
        XCTAssertTrue(moves.dropFirst(15).allSatisfy { $0 == Fixture.target }, "목표 줄 도달 뒤에는 목표점 반복")
        // 모든 이벤트는 태그 단 mouseMoved(전송 프로토콜에 드래그·warp 메서드가 없다 → 드래그 0개, AC13.3)
        XCTAssertEqual(h.log.entries(prefix: "move").count, moves.count)
        XCTAssertTrue(h.outcomes.isEmpty, "아직 끝나지 않았다")
        XCTAssertTrue(h.relocator.isActive)
        XCTAssertTrue(h.restoreArgs.isEmpty, "진행 중에는 복원하지 않는다")
    }

    func test_AC8_2_ticksAre16msDriveTicks_onlyOneCursorRead() {
        let h = Harness()
        h.start()
        h.ticks(20)

        let delays = h.scheduler.scheduledDelays(.driveTick)
        XCTAssertFalse(delays.isEmpty, "틱은 스케줄러(.driveTick)로 돈다 — 메인을 막지 않는다(R8.4)")
        XCTAssertTrue(delays.allSatisfy { abs($0 - Fixture.tick) < Fixture.eps }, "틱 간격 16 ms: \(delays)")

        let times = h.poster.moveTimes
        XCTAssertGreaterThanOrEqual(times.count, 15)
        if times.count >= 15 {
            for i in 1..<15 {
                XCTAssertEqual(times[i] - times[i - 1], Fixture.tick, accuracy: Fixture.eps, "다가가기 걸음 \(i)")
            }
        }
        XCTAssertEqual(h.poster.cursorReadCount, 1, "커서는 시작 때 한 번만 저장한다(R8.3-1)")
    }

    // MARK: - AC8.3 단일 조회 성공

    func test_AC8_3_quickConfirmsAnchorAfter0_7s_succeedsAndRestoresLast() {
        let h = Harness()
        h.quickAnswer = { elapsed in elapsed >= 0.7 ? Fixture.onAnchor : Fixture.onSidecar }
        h.start()
        h.advance(2.0)

        XCTAssertEqual(h.outcomes, [.succeeded])
        XCTAssertEqual(h.lastMoveAtCompletion, [Fixture.saved], "복원 뒤에 completion")
        XCTAssertEqual(h.poster.moves.last, Fixture.saved, "마지막 이벤트는 저장 위치로의 복원")
        XCTAssertEqual(h.restoreArgs, [Fixture.saved])
        XCTAssertEqual(h.poster.moves.filter { $0 == Fixture.saved }.count, 1, "복원은 1번")
        if let doneAt = h.completionTimes.first {
            XCTAssertGreaterThanOrEqual(doneAt - h.startedAt, 0.7 - Fixture.eps)
            XCTAssertLessThanOrEqual(doneAt - h.startedAt,
                                     0.7 + Double(DockPinTuning.verifyEveryTicks) * Fixture.tick + Fixture.eps,
                                     "0.7 s 뒤 첫 6틱 조회에서 성공")
        }
        XCTAssertEqual(h.finalRequestCount, 0, "성공하면 마지막 전체 조회는 없다")
        XCTAssertFalse(h.relocator.isActive)
        XCTAssertEqual(h.scheduler.pendingCount(.driveTick), 0, "틱 중지")

        let count = h.poster.moves.count
        h.advance(3.0)
        XCTAssertEqual(h.poster.moves.count, count, "끝난 뒤 이벤트 0")
        XCTAssertEqual(h.outcomes.count, 1, "completion은 정확히 1번")
    }

    func test_AC8_3_quickCheckEverySixTicks_onlyWhileHoldingRow() {
        let h = Harness()
        h.start()
        h.advance(2.2)    // 마지막 조회 전(reachedAt + 2.0 ≥ 2.224)까지는 가지 않아도 유지 구간 대부분을 덮는다

        guard let reachedAt = h.reachedAt else { return XCTFail("목표 줄에 닿지 않았다") }
        XCTAssertGreaterThanOrEqual(h.quickTimes.count, 15, "유지 구간 약 2 s / 96 ms")
        XCTAssertTrue(h.quickTimes.allSatisfy { $0 >= reachedAt - Fixture.eps }, "다가가기 중에는 조회하지 않는다")
        for i in stride(from: 1, to: h.quickTimes.count, by: 1) {
            XCTAssertEqual(h.quickTimes[i] - h.quickTimes[i - 1],
                           Double(DockPinTuning.verifyEveryTicks) * Fixture.tick, accuracy: Fixture.eps)
        }
        XCTAssertTrue(h.locator.requestDisplays.allSatisfy { $0 == DockPinFixtures.thisMac }, "계획의 디스플레이로 조회")
        XCTAssertTrue(h.otherModes.isEmpty, "유지 구간 조회는 .quick뿐")
    }

    // MARK: - AC8.4 마지막 전체 조회 → 실패

    func test_AC8_4_bothScansOtherDisplay_stopsAt2s_finalOnce_failsAfterResult_thenRestores() {
        let h = Harness()
        h.start()
        h.advance(3.0)    // 마지막 조회 요청 뒤, 시간 초과(요청 + 1.2 s) 전

        guard let reachedAt = h.reachedAt else { return XCTFail("목표 줄에 닿지 않았다") }
        XCTAssertEqual(h.finalRequestCount, 1, "전체 조회 1회, preferCached: false(= .final)")
        if let finalAt = h.finalTimes.first {
            XCTAssertGreaterThanOrEqual(finalAt - reachedAt, DockPinTuning.relocationTimeout - Fixture.eps)
            XCTAssertLessThanOrEqual(finalAt - reachedAt, DockPinTuning.relocationTimeout + Fixture.tick + Fixture.eps)
        }
        XCTAssertTrue(h.otherModes.isEmpty, ".full/.event가 아니라 .final")
        XCTAssertTrue(h.poster.moveTimes.allSatisfy { $0 <= reachedAt + DockPinTuning.relocationTimeout + Fixture.eps },
                      "목표 줄 도달 2.0 s 뒤부터 이동 이벤트 0")
        XCTAssertTrue(h.poster.moveTimes.contains { $0 >= reachedAt + DockPinTuning.relocationTimeout - Fixture.tick - Fixture.eps },
                      "2.0 s 직전까지는 계속 보낸다")
        XCTAssertTrue(h.outcomes.isEmpty, "결과 전에는 판정하지 않는다")
        XCTAssertTrue(h.restoreArgs.isEmpty, "복원은 조회 결과 뒤")
        XCTAssertTrue(h.relocator.isActive)

        let before = h.poster.moves.count
        h.locator.completePending(with: Fixture.onSidecar)

        XCTAssertEqual(h.outcomes, [.failed])
        XCTAssertEqual(h.poster.moves.count, before + 1, "복원 1회")
        XCTAssertEqual(h.poster.moves.last, Fixture.saved)
        XCTAssertEqual(h.lastMoveAtCompletion, [Fixture.saved], "복원 뒤에 completion")

        // 순서: 마지막 이동 → 전체 조회 요청 → 조회 결과 → 복원
        let entries = h.log.entries
        guard let fi = entries.lastIndex(of: "locate(final)") else { return XCTFail("locate(final) 없음") }
        XCTAssertTrue(entries[..<fi].contains("move"))
        XCTAssertEqual(Array(entries[(fi + 1)...]), ["result", "move"])

        h.advance(3.0)
        XCTAssertEqual(h.outcomes.count, 1, "시간 초과가 두 번째 completion을 만들지 않는다")
        XCTAssertEqual(h.poster.moves.count, before + 1)
        XCTAssertEqual(h.scheduler.pendingCount(.driveTick), 0)
        XCTAssertEqual(h.scheduler.pendingCount(.finalScanTimeout), 0)
    }

    func test_AC8_4b_quickKeepsOtherButFinalFindsAnchor_succeeds() {
        let h = Harness()
        h.finalAnswer = { _ in Fixture.onAnchor }
        h.start()
        h.advance(3.0)

        XCTAssertEqual(h.outcomes, [.succeeded])
        XCTAssertEqual(h.finalRequestCount, 1)
        XCTAssertGreaterThan(h.quickTimes.count, 0, "단일 조회는 했지만 계속 다른 화면")
        XCTAssertEqual(h.poster.moves.last, Fixture.saved)
        XCTAssertEqual(h.lastMoveAtCompletion, [Fixture.saved])
        XCTAssertEqual(h.restoreArgs, [Fixture.saved])
    }

    // MARK: - AC8.4c 마지막 조회 무응답 / 그 사이 사용자 활동

    func test_AC8_4c_finalNoResponse_failsAt1_2sAfterRequest_restoresOnce_within3_5s() {
        let h = Harness()
        h.start()
        h.advance(4.0)

        guard let reachedAt = h.reachedAt else { return XCTFail("목표 줄에 닿지 않았다") }
        XCTAssertEqual(h.outcomes, [.failed])
        XCTAssertEqual(h.scheduler.scheduledDelays(.finalScanTimeout), [DockPinTuning.finalScanTimeout])
        if let finalAt = h.finalTimes.first, let doneAt = h.completionTimes.first {
            XCTAssertEqual(doneAt - finalAt, DockPinTuning.finalScanTimeout, accuracy: Fixture.tick + Fixture.eps)
            XCTAssertGreaterThanOrEqual(doneAt - reachedAt,
                                        DockPinTuning.relocationTimeout + DockPinTuning.finalScanTimeout - Fixture.eps,
                                        "2.0 + 1.2 s 전에는 실패로 보지 않는다")
        } else {
            XCTFail("마지막 조회 요청 또는 completion 없음")
        }
        let late = h.poster.moveTimes.filter { $0 > reachedAt + DockPinTuning.relocationTimeout + Fixture.eps }
        XCTAssertEqual(late.count, 1, "2.0–3.2 s 사이 이동 0, 복원 1")
        XCTAssertEqual(h.poster.moves.last, Fixture.saved)
        if let first = h.poster.moveTimes.first, let last = h.poster.moveTimes.last {
            XCTAssertLessThanOrEqual(last - first, 3.5 + Fixture.eps, "다가가기 첫 이벤트부터 복원까지 ≤ 3.5 s")
        }

        // 늦은 결과는 버린다
        let count = h.poster.moves.count
        h.locator.completePending(with: Fixture.onAnchor)
        h.advance(2.0)
        XCTAssertEqual(h.outcomes, [.failed])
        XCTAssertEqual(h.poster.moves.count, count)
    }

    func test_AC8_4c_userActivityDuringFinalWait_abortsThatTick_ignoresLateResult() {
        let h = Harness()
        h.start()
        h.advance(2.6)    // 마지막 조회 대기 중(요청 ≈ 2.24–2.26 s, 시간 초과 ≥ 3.42 s)

        XCTAssertEqual(h.finalRequestCount, 1)
        XCTAssertTrue(h.outcomes.isEmpty)
        let before = h.poster.moves.count

        h.activity += 1
        h.ticks(1)

        XCTAssertEqual(h.outcomes, [.aborted(.userActivity)], "그 틱에 중단(실패 아님 → 실패 횟수 미포함)")
        XCTAssertEqual(h.poster.moves.count, before + 1, "복원 1회")
        XCTAssertEqual(h.poster.moves.last, Fixture.saved)
        XCTAssertFalse(h.relocator.isActive)

        h.locator.completePending(with: Fixture.onAnchor)
        h.advance(2.0)
        XCTAssertEqual(h.outcomes, [.aborted(.userActivity)], "늦은 결과·시간 초과는 무시")
        XCTAssertEqual(h.poster.moves.count, before + 1)
        XCTAssertEqual(h.scheduler.pendingCount(.finalScanTimeout), 0)
        XCTAssertEqual(h.scheduler.pendingCount(.driveTick), 0)
    }

    // MARK: - AC8.5 사용자 활동 중단

    func test_AC8_5_userActivityDuringApproach_nextTickStopsAndRestoresOnce() {
        let h = Harness()
        h.start()
        h.ticks(5)
        let before = h.poster.moves.count
        XCTAssertGreaterThan(before, 0, "다가가기 중")

        h.activity = 1
        h.ticks(1)

        XCTAssertEqual(h.poster.moves.count, before + 1, "다음 틱은 이동 대신 복원")
        XCTAssertEqual(h.poster.moves.last, Fixture.saved)
        XCTAssertEqual(h.outcomes, [.aborted(.userActivity)])
        XCTAssertEqual(h.lastMoveAtCompletion, [Fixture.saved])

        h.advance(3.0)
        XCTAssertEqual(h.poster.moves.count, before + 1, "그 뒤 이동 0")
        XCTAssertEqual(h.outcomes.count, 1)
        XCTAssertTrue(h.locator.requests.isEmpty, "조회도 하지 않는다")
        XCTAssertEqual(h.scheduler.pendingCount(.driveTick), 0)
    }

    func test_AC8_5_userActivityWhileHoldingRow_stopsAndRestoresOnce() {
        let h = Harness()
        h.start()
        h.advance(1.0)
        let before = h.poster.moves.count
        XCTAssertGreaterThan(before, 15, "목표 줄 유지 중")

        h.activity += 3
        h.ticks(1)
        h.advance(3.0)

        XCTAssertEqual(h.outcomes, [.aborted(.userActivity)])
        XCTAssertEqual(h.poster.moves.count, before + 1)
        XCTAssertEqual(h.poster.moves.last, Fixture.saved)
        XCTAssertEqual(h.finalRequestCount, 0)
    }

    func test_AC8_5_baselineIsCounterAtStart_existingCountDoesNotAbort() {
        let h = Harness()
        h.activity = 7          // 시작 전 활동은 기준값
        h.start()
        h.advance(0.5)

        XCTAssertTrue(h.outcomes.isEmpty, "시작 때 값과 같으면 중단하지 않는다")
        XCTAssertGreaterThanOrEqual(h.poster.moves.count, 25)
        XCTAssertTrue(h.relocator.isActive)

        h.activity = 8
        h.ticks(1)
        XCTAssertEqual(h.outcomes, [.aborted(.userActivity)])
    }

    // MARK: - AC8.9 Relocator부 — 복원점 주입

    func test_AC8_9_restorePointCenter_restoresThereOnce() {
        let h = Harness()
        h.restoreResult = { _ in Fixture.anchorCenter }
        h.start()
        h.advance(0.3)
        let before = h.poster.moves.count
        XCTAssertGreaterThan(before, 0)

        h.relocator.abort(.displayReconfigured)

        XCTAssertEqual(h.outcomes, [.aborted(.displayReconfigured)])
        XCTAssertEqual(h.poster.moves.count, before + 1)
        XCTAssertEqual(h.poster.moves.last, Fixture.anchorCenter, "분리된 화면 → 고정 화면 가운데")
        XCTAssertEqual(h.restoreArgs, [Fixture.saved], "복원점 계산에는 시작 때 저장한 위치를 넘긴다")

        h.advance(2.0)
        XCTAssertEqual(h.poster.moves.count, before + 1, "중단 뒤 이동 0")
        XCTAssertFalse(h.relocator.isActive)
    }

    func test_AC8_9_restorePointNil_noRestoreEvent_completionStillOnce() {
        let h = Harness()
        h.restoreResult = { _ in nil }
        h.start()
        h.advance(0.3)
        let before = h.poster.moves.count
        XCTAssertGreaterThan(before, 0)

        h.relocator.abort(.displayReconfigured)
        h.advance(2.0)

        XCTAssertEqual(h.outcomes, [.aborted(.displayReconfigured)])
        XCTAssertEqual(h.poster.moves.count, before, "활성 화면 0대 → 복원 이벤트 0")
        XCTAssertEqual(h.restoreArgs, [Fixture.saved])
    }

    func test_AC8_9_restorePointAppliesToFailureToo() {
        let h = Harness()
        h.restoreResult = { _ in Fixture.anchorCenter }
        h.finalAnswer = { _ in Fixture.onSidecar }
        h.start()
        h.advance(3.0)

        XCTAssertEqual(h.outcomes, [.failed])
        XCTAssertEqual(h.poster.moves.last, Fixture.anchorCenter)
        XCTAssertEqual(h.restoreArgs, [Fixture.saved])
    }

    // MARK: - R8.3-1 커서를 못 읽음

    func test_R8_3_cursorUnavailable_abortsWithoutAnyEvent() {
        let h = Harness()
        h.poster.cursor = nil
        h.start()
        h.advance(1.0)

        XCTAssertEqual(h.outcomes, [.aborted(.cursorUnavailable)])
        XCTAssertTrue(h.poster.moves.isEmpty, "이벤트 0")
        XCTAssertTrue(h.locator.requests.isEmpty)
        XCTAssertTrue(h.restoreArgs.isEmpty, "저장 위치가 없으니 복원도 없다")
        XCTAssertFalse(h.relocator.isActive)
        XCTAssertEqual(h.scheduler.pendingCount(.driveTick), 0)
    }

    // MARK: - abort 계약

    func test_abort_whenIdle_isNoOp_thenStartStillWorks() {
        let h = Harness()
        h.relocator.abort(.shutdown)
        h.advance(0.5)
        XCTAssertTrue(h.poster.moves.isEmpty)
        XCTAssertTrue(h.outcomes.isEmpty)
        XCTAssertTrue(h.restoreArgs.isEmpty)

        h.start()
        h.advance(0.3)
        XCTAssertGreaterThan(h.poster.moves.count, 0, "앞선 무동작 abort가 다음 시작을 막지 않는다")
        XCTAssertTrue(h.relocator.isActive)
    }

    func test_abort_twice_completionExactlyOnce_restoreOnce() {
        let h = Harness()
        h.start()
        h.advance(0.5)
        let before = h.poster.moves.count
        XCTAssertGreaterThan(before, 0)

        h.relocator.abort(.sleep)
        h.relocator.abort(.locked)
        h.advance(1.0)

        XCTAssertEqual(h.outcomes, [.aborted(.sleep)])
        XCTAssertEqual(h.poster.moves.count, before + 1)
        XCTAssertEqual(h.poster.moves.last, Fixture.saved)
    }

    func test_abort_whileFinalPending_restoresOnce_ignoresLateResultAndTimeout() {
        let h = Harness()
        h.start()
        h.advance(2.6)
        XCTAssertEqual(h.finalRequestCount, 1)
        let before = h.poster.moves.count

        h.relocator.abort(.permissionLost)

        XCTAssertEqual(h.outcomes, [.aborted(.permissionLost)])
        XCTAssertEqual(h.poster.moves.count, before + 1, "권한 철회여도 복원 이벤트는 보낸다(R8.5 예외 2)")

        h.locator.completePending(with: Fixture.onAnchor)
        h.advance(2.0)
        XCTAssertEqual(h.outcomes, [.aborted(.permissionLost)])
        XCTAssertEqual(h.poster.moves.count, before + 1)
    }

    // MARK: - R8.3-5 / AC8.4 마지막 조회 결과 해석 — 고정 화면이 아니면 모두 실패

    func test_AC8_4_finalDeferred_isFailure_notSuccess() {
        let h = Harness()
        h.start()
        h.advance(3.0)
        XCTAssertEqual(h.finalRequestCount, 1)
        XCTAssertTrue(h.outcomes.isEmpty)

        h.locator.completePending(with: .deferred)

        XCTAssertEqual(h.outcomes, [.failed], "백오프(.deferred)는 고정 화면 확인이 아니다 → 실패")
        XCTAssertEqual(h.poster.moves.last, Fixture.saved)
    }

    func test_AC8_4_finalUnknownPlacement_isFailure() {
        let h = Harness()
        h.start()
        h.advance(3.0)
        XCTAssertEqual(h.finalRequestCount, 1)

        h.locator.completePending(with: .placement(.unknown))

        XCTAssertEqual(h.outcomes, [.failed], "위치 모름은 고정 화면 확인이 아니다 → 실패")
        XCTAssertEqual(h.poster.moves.last, Fixture.saved)
    }

    // MARK: - R8.3-5 2.0 s 경계 — 그 틱은 이동하지 않는다(엄격히 미만)

    func test_AC8_4_noMoveAtOrAfterReachedPlus2s_beforeRestore() {
        let h = Harness()
        h.start()
        h.advance(3.0)    // 마지막 조회 대기 중(무응답), 시간 초과 전

        guard let reachedAt = h.reachedAt, let finalAt = h.finalTimes.first else {
            return XCTFail("목표 줄 도달 또는 마지막 조회 요청 없음")
        }
        let boundary = reachedAt + DockPinTuning.relocationTimeout - Fixture.tick / 2
        XCTAssertEqual(h.poster.moveTimes.filter { $0 >= boundary }.count, 0,
                       "2.0 s 틱(마지막 조회 요청 틱)에는 이동을 보내지 않는다")
        XCTAssertTrue(h.poster.moveTimes.allSatisfy { $0 < finalAt - Fixture.eps },
                      "모든 이동은 마지막 조회 요청 시각보다 앞선다")
        // 유지 구간 이동 수: reachedAt + 16 ms … reachedAt + 1.984 s → 124번
        XCTAssertEqual(h.poster.moves.count, 15 + 124)
    }

    // MARK: - 끝나는 즉시 대기 예약 취소(스케줄러를 진행시키지 않고 확인)

    func test_finish_abortWhileHolding_cancelsDriveTickImmediately() {
        let h = Harness()
        h.start()
        h.advance(1.0)
        XCTAssertEqual(h.scheduler.pendingCount(.driveTick), 1, "진행 중에는 다음 틱 1개가 대기")

        h.relocator.abort(.sleep)

        XCTAssertEqual(h.outcomes, [.aborted(.sleep)])
        XCTAssertEqual(h.scheduler.pendingCount(.driveTick), 0, "틱 예약 취소")
        XCTAssertEqual(h.scheduler.pendingCount(.finalScanTimeout), 0)
    }

    func test_finish_abortWhileFinalPending_cancelsTickAndTimeoutImmediately() {
        let h = Harness()
        h.start()
        h.advance(2.6)
        XCTAssertEqual(h.scheduler.pendingCount(.finalScanTimeout), 1, "마지막 조회 시간 초과 예약 대기")
        XCTAssertEqual(h.scheduler.pendingCount(.driveTick), 1, "활동 확인용 틱 대기")

        h.relocator.abort(.locked)

        XCTAssertEqual(h.outcomes, [.aborted(.locked)])
        XCTAssertEqual(h.scheduler.pendingCount(.finalScanTimeout), 0, "시간 초과 예약 취소")
        XCTAssertEqual(h.scheduler.pendingCount(.driveTick), 0, "틱 예약 취소")
    }

    func test_finish_finalResultFailure_cancelsTickAndTimeoutImmediately() {
        let h = Harness()
        h.start()
        h.advance(2.6)
        XCTAssertEqual(h.scheduler.pendingCount(.finalScanTimeout), 1)
        XCTAssertEqual(h.scheduler.pendingCount(.driveTick), 1)

        h.locator.completePending(with: Fixture.onSidecar)

        XCTAssertEqual(h.outcomes, [.failed])
        XCTAssertEqual(h.scheduler.pendingCount(.finalScanTimeout), 0, "시간 초과 예약 취소")
        XCTAssertEqual(h.scheduler.pendingCount(.driveTick), 0, "틱 예약 취소")
    }

    func test_finish_finalResultSuccess_cancelsTickAndTimeoutImmediately() {
        let h = Harness()
        h.start()
        h.advance(2.6)

        h.locator.completePending(with: Fixture.onAnchor)

        XCTAssertEqual(h.outcomes, [.succeeded])
        XCTAssertEqual(h.scheduler.pendingCount(.finalScanTimeout), 0)
        XCTAssertEqual(h.scheduler.pendingCount(.driveTick), 0)
    }

    func test_finish_finalSyncSuccess_cancelsTimeoutScheduledInSameTick() {
        let h = Harness()
        h.finalAnswer = { _ in Fixture.onAnchor }    // 마지막 조회가 그 자리에서 성공
        h.start()
        h.advance(2.3)    // 마지막 조회 틱(≈ 2.24 s) 직후, 시간 초과 전

        XCTAssertEqual(h.outcomes, [.succeeded])
        XCTAssertEqual(h.scheduler.scheduledDelays(.finalScanTimeout).count, 1, "시간 초과는 예약됐었다")
        XCTAssertEqual(h.scheduler.pendingCount(.finalScanTimeout), 0, "같은 틱에 끝났으면 시간 초과 예약 취소")
        XCTAssertEqual(h.scheduler.pendingCount(.driveTick), 0)
    }

    func test_finish_quickSuccess_leavesNoPendingTick() {
        let h = Harness()
        h.quickAnswer = { elapsed in elapsed >= 0.5 ? Fixture.onAnchor : Fixture.onSidecar }
        h.start()
        h.advance(0.7)

        XCTAssertEqual(h.outcomes, [.succeeded])
        XCTAssertEqual(h.scheduler.pendingCount(.driveTick), 0)
        XCTAssertEqual(h.scheduler.pendingCount(.finalScanTimeout), 0)
    }

    // MARK: - 유지 구간이 끝난 뒤 도착한 .quick 결과는 버린다

    /// 모드별로 completion을 따로 쥐고 있는 조회기(.quick 결과를 .final과 다르게 답하기 위해)
    @MainActor
    private final class ModeSplitLocator: DockPinDockLocating {
        private(set) var pendingQuick: [@MainActor (DockPinLocateOutcome) -> Void] = []
        private(set) var pendingFinal: [@MainActor (DockPinLocateOutcome) -> Void] = []

        func locate(_ mode: DockPinLocateMode, displays: [DockPinDisplay],
                    completion: @escaping @MainActor (DockPinLocateOutcome) -> Void) {
            switch mode {
            case .quick: pendingQuick.append(completion)
            case .final: pendingFinal.append(completion)
            case .full, .event: completion(.placement(.unknown))
            }
        }

        func completeQuick(with outcome: DockPinLocateOutcome) {
            let completions = pendingQuick
            pendingQuick.removeAll()
            completions.forEach { $0(outcome) }
        }

        func completeFinal(with outcome: DockPinLocateOutcome) {
            let completions = pendingFinal
            pendingFinal.removeAll()
            completions.forEach { $0(outcome) }
        }

        func invalidateCache() {}
        func cancelAll() {}
    }

    func test_lateQuickResultAfterHoldingEnded_isIgnored_finalDecides() {
        let scheduler = FakeDockPinScheduler()
        let poster = FakeDockPinPoster()
        poster.cursor = Fixture.saved
        let locator = ModeSplitLocator()
        let relocator = DockPinRelocator(poster: poster, locator: locator, scheduler: scheduler,
                                         userActivityCount: { 0 }, restorePoint: { $0 })
        var outcomes: [DockPinDriveOutcome] = []
        relocator.start(Fixture.plan) { outcomes.append($0) }

        scheduler.advance(by: 2.6)    // 단일 조회는 모두 무응답으로 쌓이고, 마지막 조회 대기 중
        XCTAssertGreaterThan(locator.pendingQuick.count, 0, "유지 구간에 단일 조회를 했다")
        XCTAssertEqual(locator.pendingFinal.count, 1, "마지막 조회 요청 1회")
        XCTAssertTrue(outcomes.isEmpty)

        locator.completeQuick(with: Fixture.onAnchor)    // 유지 구간이 끝난 뒤 늦게 온 단일 조회 성공
        XCTAssertTrue(outcomes.isEmpty, "유지 구간 밖의 .quick 결과로는 판정하지 않는다")
        XCTAssertTrue(relocator.isActive)

        locator.completeFinal(with: Fixture.onSidecar)
        XCTAssertEqual(outcomes, [.failed], "판정은 마지막 전체 조회 결과로만")
        XCTAssertFalse(relocator.isActive)
    }

    // MARK: - isActive

    func test_isActive_trueWhileDriving_falseAfterFailure() {
        let h = Harness()
        h.start()
        XCTAssertTrue(h.relocator.isActive, "start 직후 진행 중")
        h.advance(1.0)
        XCTAssertTrue(h.relocator.isActive)

        h.advance(3.0)    // 마지막 조회 무응답 → 시간 초과 실패
        XCTAssertEqual(h.outcomes, [.failed])
        XCTAssertFalse(h.relocator.isActive)
    }
}
