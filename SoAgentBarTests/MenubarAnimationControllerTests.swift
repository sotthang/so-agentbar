import XCTest
import AppKit
@testable import SoAgentBar

// MARK: - MenubarAnimationControllerTests
//
// SPEC-003 C3 — MenubarAnimationController(상태 계층) 상태 전이 테스트.
//
// RED 확인 방법: MenubarAnimationController.swift는 컴파일된다(so-tester가 arch §4-3
// 시그니처에 맞춘 고정값 스텁을 작성했기 때문). 스텁은 `isRunning`/`currentImage`를
// 항상 false/nil로 고정 반환하고, `state`/`tick`/`timerGeneration`은 초기값에서
// 절대 변하지 않으며(모든 공개 메서드가 no-op), `update`/`advanceFrame`/`suspend`/
// `resume`은 아무 일도 하지 않는다. 아래 단정 대부분이 실패하는 것이 정상이다.
//
// ⚠️ 스텁 고정값과 우연히 일치해 GREEN으로 보일 수 있는 테스트 — 각 케이스에 명시:
//   - AC17(비변이 델타)은 스텁이든 실제 구현이든 항상 성립해야 하는 불변식이라 애초에
//     RED 대상이 아니다.
//   - AC21(레거시 전환 시 disabled): 스텁의 `state` 초기값이 이미 `.disabled`이고
//     `isRunning`이 항상 false이므로, 이 테스트는 스텁 단계에서도 우연히 GREEN이다.
//   - AC22의 두 번째 시나리오(maxSustain 초과 후 `!isRunning`)도 `isRunning`이 항상
//     false이므로 우연히 GREEN이다.
//   - AC23(source nil → currentImage nil)은 `currentImage`가 항상 nil을 반환하는
//     스텁이므로 우연히 GREEN이다.
//   - AC39(timerMode == .common)는 `timerMode`의 스텁 초기값 자체가 `.common`이므로
//     "실행 중" 여부와 무관하게 우연히 GREEN이다.
// 나머지 테스트는 상태가 실제로 바뀌어야 통과하므로 스텁 단계에서는 RED다.
//
// 커버 AC: AC17, AC18, AC19, AC20, AC21, AC22, AC23, AC36, AC38, AC39, AC42, AC44

@MainActor
final class MenubarAnimationControllerTests: XCTestCase {

    // MARK: - 헬퍼

    /// arch §6-2와 동일 — 상하 비대칭 무늬가 있는 더미 소스(프레임 이동 감지용).
    private func makeDummySource(side: CGFloat = 40) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: side, height: side / 4).fill()
            return true
        }
    }

    /// 주입 가능한 시계 상자. `nowProvider`가 이 상자를 읽도록 연결해 실시간 Date()에
    /// 의존하지 않고 결정론적으로 시간을 진행시킨다(R5.7/AC44).
    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// 모든 테스트에서 `nowProvider`를 반드시 주입한다 — 주입하지 않으면 advanceFrame()의
    /// R5.7 재평가가 실시간 Date()를 보게 되어 테스트가 실행 속도에 의존하게 된다.
    private func makeController(source: NSImage? = nil) -> (MenubarAnimationController, Box<Date>) {
        let clock = Box(t0)
        let controller = MenubarAnimationController(source: source ?? makeDummySource())
        controller.nowProvider = { clock.value }
        return (controller, clock)
    }

    // MARK: - AC17 — 공유 로고 인스턴스 비변이 (R3.5/R0.6)
    //
    // 절대값(예: 500x500) 단정 금지 — TEST_HOST 환경에서 호스트 앱이 이미 로고를
    // 변이시켜 놓았을 수 있다(R0.7). 생성 직전/직후 값이 "동일"한지 델타로만 검증한다.

    func test_init_doesNotMutateSharedLogoImageSize() {
        guard let before = NSImage(named: "logo")?.size else {
            XCTFail("logo.png should be loadable via NSImage(named:)")
            return
        }
        _ = MenubarAnimationController(source: NSImage(named: "logo"))
        guard let after = NSImage(named: "logo")?.size else {
            XCTFail("logo.png should still be loadable via NSImage(named:)")
            return
        }
        XCTAssertEqual(before, after)
    }

    // MARK: - AC18 — hold 초과 후 정지 (R7.11/R5.4)

    func test_update_runningThenZeroPastHold_stopsAndBecomesStill() {
        let (controller, _) = makeController()
        controller.update(style: .quotaSession, runningCount: 2, isSustaining: true, now: t0)
        XCTAssertTrue(controller.isRunning, "runningCount 2 이후에는 실행 중이어야 한다")

        controller.update(style: .quotaSession, runningCount: 0, isSustaining: false, now: t0.addingTimeInterval(5))
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(controller.state, .still)
    }

    // MARK: - AC19 — hold 이내 유지 (R5.4)

    func test_update_runningThenZeroWithinHold_keepsAnimating() {
        let (controller, _) = makeController()
        controller.update(style: .quotaSession, runningCount: 2, isSustaining: true, now: t0)

        controller.update(style: .quotaSession, runningCount: 0, isSustaining: false, now: t0.addingTimeInterval(1))
        XCTAssertTrue(controller.isRunning, "hold(4초) 이내이므로 깜빡이지 않고 유지되어야 한다")
        XCTAssertEqual(controller.state, .animating(.normal))
    }

    // MARK: - AC20 — 티어 변경 시 tick 유지 (R7.5)

    func test_tierChange_doesNotResetTick() {
        let (controller, _) = makeController()
        controller.update(style: .quotaSession, runningCount: 1, isSustaining: true, now: t0)
        controller.advanceFrame()
        controller.advanceFrame()
        controller.advanceFrame()
        XCTAssertEqual(controller.tick, 3)

        controller.update(style: .quotaSession, runningCount: 3, isSustaining: true, now: t0)
        XCTAssertEqual(controller.state, .animating(.fast))
        XCTAssertEqual(controller.tick, 3, "티어가 바뀌어도 tick은 리셋되면 안 된다")
    }

    // MARK: - AC21 — 레거시 스타일 전환 시 즉시 disabled (R1.5/R6.4)
    //
    // ⚠️ 스텁 단계에서 우연히 GREEN — state 초기값이 이미 .disabled, isRunning은 항상 false.

    func test_update_switchToLegacyStyle_becomesDisabledAndStops() {
        let (controller, _) = makeController()
        controller.update(style: .quotaSession, runningCount: 2, isSustaining: true, now: t0)
        XCTAssertTrue(controller.isRunning)

        controller.update(style: .emoji, runningCount: 0, isSustaining: false, now: t0)
        XCTAssertEqual(controller.state, .disabled)
        XCTAssertFalse(controller.isRunning)
    }

    // MARK: - AC22 — resume(now:)의 재평가 (R9.3)

    func test_resume_withinHold_resumesRunning() {
        let (controller, _) = makeController()
        controller.update(style: .quotaSession, runningCount: 1, isSustaining: true, now: t0)
        controller.suspend()
        XCTAssertFalse(controller.isRunning)

        controller.resume(now: t0.addingTimeInterval(1))
        XCTAssertTrue(controller.isRunning, "홀드 이내 웨이크는 애니메이션을 재개해야 한다")
    }

    /// ⚠️ 스텁 단계에서 우연히 GREEN — isRunning이 항상 false.
    func test_resume_beyondMaxSustain_staysStill() {
        let (controller, _) = makeController()
        controller.update(style: .quotaSession, runningCount: 1, isSustaining: true, now: t0)
        controller.suspend()

        controller.resume(now: t0.addingTimeInterval(200))
        XCTAssertFalse(controller.isRunning, "maxSustain을 넘겨 깨어나면 정지 상태를 유지해야 한다")
    }

    // MARK: - AC23 — 소스 없는 컨트롤러 (R3.6)
    //
    // ⚠️ 스텁 단계에서 우연히 GREEN — currentImage가 항상 nil.

    func test_noSourceController_currentImageIsNilAndNoCrash() {
        let controller = MenubarAnimationController(source: nil)
        XCTAssertNil(controller.currentImage)
        controller.update(style: .quotaSession, runningCount: 1, isSustaining: true, now: t0)
        XCTAssertNil(controller.currentImage)
    }

    // MARK: - AC36 — suspend() 시퀀스 (R7.3) — 버그 A(영구 정지) 안전망

    func test_suspendResumeSequence_stickyDuringSuspend_recoversOnResume() {
        let (controller, _) = makeController()

        // ⑴ 실행 중 진입
        controller.update(style: .quotaSession, runningCount: 1, isSustaining: true, now: t0)
        XCTAssertTrue(controller.isRunning, "⑴ update 직후 실행 중이어야 한다")

        // ⑵ suspend
        controller.suspend()
        XCTAssertFalse(controller.isRunning, "⑵ suspend 직후 정지해야 한다")

        // ⑶ 슬립 중 동일 카운트로 재호출해도 타이머가 되살아나면 안 된다(sticky)
        controller.update(style: .quotaSession, runningCount: 1, isSustaining: true, now: t0.addingTimeInterval(0.5))
        XCTAssertFalse(controller.isRunning, "⑶ suspend 중에는 update가 와도 타이머를 만들면 안 된다")

        // ⑷ resume 후 정상 복귀 — currentTier가 nil로 리셋되어 있지 않으면(버그 A)
        // timerPlan(.slow, .slow) == .keep이 되어 여기서 영원히 isRunning == false가 된다.
        controller.resume(now: t0.addingTimeInterval(1))
        XCTAssertTrue(controller.isRunning, "⑷ resume 후 정상적으로 재개되어야 한다(영구 정지 버그 A 안전망)")
    }

    // MARK: - AC38 — 동일 티어 반복 호출 시 타이머 churn 없음 (R8.1/R8.2)

    func test_sameTierRepeatedUpdate_doesNotResetTickOrRecreateTimer() {
        let (controller, _) = makeController()
        controller.update(style: .quotaSession, runningCount: 3, isSustaining: true, now: t0)
        controller.advanceFrame()
        controller.advanceFrame()
        XCTAssertEqual(controller.tick, 2)
        let generationBefore = controller.timerGeneration

        controller.update(style: .quotaSession, runningCount: 3, isSustaining: true, now: t0.addingTimeInterval(0.1))
        controller.update(style: .quotaSession, runningCount: 3, isSustaining: true, now: t0.addingTimeInterval(0.2))
        controller.update(style: .quotaSession, runningCount: 3, isSustaining: true, now: t0.addingTimeInterval(0.3))

        XCTAssertEqual(controller.tick, 2, "동일 티어 반복 호출은 tick을 리셋하면 안 된다 — 1초 타이머의 프레임 튐 방지")
        XCTAssertEqual(controller.timerGeneration, generationBefore, "동일 티어 반복 호출은 타이머를 재생성하면 안 된다")
    }

    // MARK: - AC39 — 타이머 RunLoop 모드 (R7.8)
    //
    // ⚠️ 스텁 단계에서 우연히 GREEN — timerMode 초기값 자체가 .common.

    func test_timerMode_whileRunning_isCommon() {
        let (controller, _) = makeController()
        controller.update(style: .quotaSession, runningCount: 1, isSustaining: true, now: t0)
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(controller.timerMode, .common)
    }

    // MARK: - AC42 — 유지 신호 반복으로 티어 유지, maxSustain 초과 시 정지 (R4.4/R5.4)

    func test_sustainingSignalRepeated_keepsTierUntilMaxSustainExceeded() {
        let (controller, _) = makeController()
        controller.update(style: .quotaSession, runningCount: 2, isSustaining: true, now: t0)

        controller.update(style: .quotaSession, runningCount: 0, isSustaining: true, now: t0.addingTimeInterval(8))
        XCTAssertEqual(controller.state, .animating(.normal), "8초 경과 — 유지 신호로 티어가 유지되어야 한다")

        controller.update(style: .quotaSession, runningCount: 0, isSustaining: true, now: t0.addingTimeInterval(16))
        XCTAssertEqual(controller.state, .animating(.normal), "16초 경과")

        controller.update(style: .quotaSession, runningCount: 0, isSustaining: true, now: t0.addingTimeInterval(24))
        XCTAssertEqual(controller.state, .animating(.normal), "24초 경과 — 긴 MCP 호출 동안 티어가 오르면 안 된다")

        controller.update(style: .quotaSession, runningCount: 0, isSustaining: true, now: t0.addingTimeInterval(91))
        XCTAssertFalse(controller.isRunning, "최초 .working 관측으로부터 90초를 넘기면 정지해야 한다")
        XCTAssertEqual(controller.state, .still)
    }

    // MARK: - AC44 — 하강 구간 자동 정지 (R5.7/R7.12) — 버그 B(헛뛰기) 안전망
    //
    // update(...)를 다시 호출하지 않고 nowProvider만 진행시키며 advanceFrame()만
    // 반복한다 — store.$agents 발행이 끊긴 하강 구간을 재현한다(AC18과의 차이).

    func test_advanceFrameOnly_pastHold_autoStopsWithoutReUpdate() {
        let (controller, clock) = makeController()
        controller.update(style: .quotaSession, runningCount: 2, isSustaining: true, now: t0)
        XCTAssertEqual(controller.state, .animating(.normal))

        clock.value = t0.addingTimeInterval(5)
        controller.advanceFrame()

        XCTAssertFalse(controller.isRunning, "advanceFrame()의 재평가가 하강 구간을 감지해 정지해야 한다")
        XCTAssertEqual(controller.state, .still)
    }
}
