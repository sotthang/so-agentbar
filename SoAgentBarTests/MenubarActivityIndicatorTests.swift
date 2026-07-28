import XCTest
import AppKit
@testable import SoAgentBar

// MARK: - MenubarActivityIndicatorTests
//
// SPEC-003 C2 — 순수 계층(MenubarActivityIndicator.swift) 단위 테스트.
// RED 확인 방법: 이 파일은 컴파일된다(so-tester가 MenubarActivityIndicator.swift에
// arch §4-1 시그니처에 맞춘 고정값 스텁을 추가했기 때문). 스텁은 전부 "틀린 값"을
// 반환하므로 아래 단정 대부분이 실패하는 것이 정상이다.
//
// ⚠️ 예외 — 고정값 스텁의 수학적 한계로 "우연히 GREEN"이 되는 테스트가 소수 있다
// (부울/enum을 상수로 고정 반환하면, 그 상수와 우연히 같은 기댓값을 가진 케이스는
// 스텁만으로도 통과한다). 아래 각 섹션에 해당 테스트를 명시했다. 이는 결함이 아니라
// "고정값 반환"이라는 스텁 전략 자체의 한계이며, Developer 구현 후에도 당연히 GREEN을
// 유지해야 하는 테스트다.
//
// 커버 AC: AC4, AC5, AC6, AC7, AC8, AC9, AC10, AC11, AC12, AC13, AC14, AC15, AC16, AC35, AC37, AC43

final class MenubarActivityIndicatorTests: XCTestCase {

    // MARK: - 헬퍼

    private func makeAgent(id: String, status: AgentStatus, subagents: [Agent] = []) -> Agent {
        var a = Agent(
            id: id,
            name: "T",
            status: status,
            currentTask: "",
            elapsedSeconds: 0,
            tokensByModel: [:],
            currentModel: "claude-sonnet-4-6",
            sessionID: id,
            projectDir: "/tmp",
            workingPath: "/tmp",
            lastActivity: Date(),
            source: .cli,
            lastResponse: "",
            permissionMode: "default",
            isSubagent: false
        )
        a.subagents = subagents
        return a
    }

    /// arch §6-2 — 상하 비대칭 무늬가 있는 더미 소스. 프레임 이동 여부를 픽셀로 감지하기 위함.
    private func makeDummySource(side: CGFloat = 40) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: side, height: side / 4).fill()
            return true
        }
    }

    // MARK: - AC4 — resolve(style:effectiveCount:)  (R6.1/R6.5)
    //
    // ⚠️ 스텁은 항상 `.still`을 반환한다. 아래 중 기댓값이 `.still`인 두 테스트
    // (count0, negativeCount)는 스텁만으로도 우연히 GREEN이다. 나머지는 RED다.

    func test_resolve_quotaSession_count0_returnsStill() {
        XCTAssertEqual(
            MenubarActivityIndicator.resolve(style: .quotaSession, effectiveCount: 0),
            .still
        )
    }

    func test_resolve_quotaSession_count1_returnsAnimatingSlow() {
        XCTAssertEqual(
            MenubarActivityIndicator.resolve(style: .quotaSession, effectiveCount: 1),
            .animating(.slow)
        )
    }

    func test_resolve_quotaSession_count2_returnsAnimatingNormal() {
        XCTAssertEqual(
            MenubarActivityIndicator.resolve(style: .quotaSession, effectiveCount: 2),
            .animating(.normal)
        )
    }

    func test_resolve_quotaSession_count3_returnsAnimatingFast() {
        XCTAssertEqual(
            MenubarActivityIndicator.resolve(style: .quotaSession, effectiveCount: 3),
            .animating(.fast)
        )
    }

    func test_resolve_quotaSession_count10_returnsAnimatingFast() {
        XCTAssertEqual(
            MenubarActivityIndicator.resolve(style: .quotaSession, effectiveCount: 10),
            .animating(.fast)
        )
    }

    func test_resolve_quotaSession_negativeCount_returnsStill() {
        XCTAssertEqual(
            MenubarActivityIndicator.resolve(style: .quotaSession, effectiveCount: -1),
            .still
        )
    }

    func test_resolve_quotaSessionAndWeekly_count1_returnsAnimatingSlow() {
        XCTAssertEqual(
            MenubarActivityIndicator.resolve(style: .quotaSessionAndWeekly, effectiveCount: 1),
            .animating(.slow)
        )
    }

    func test_resolve_emojiStyle_returnsDisabled() {
        XCTAssertEqual(
            MenubarActivityIndicator.resolve(style: .emoji, effectiveCount: 3),
            .disabled
        )
    }

    func test_resolve_emojiCountStyle_returnsDisabled() {
        XCTAssertEqual(
            MenubarActivityIndicator.resolve(style: .emojiCount, effectiveCount: 3),
            .disabled
        )
    }

    func test_resolve_countOnlyStyle_returnsDisabled() {
        XCTAssertEqual(
            MenubarActivityIndicator.resolve(style: .countOnly, effectiveCount: 3),
            .disabled
        )
    }

    // MARK: - AC5 — MenubarActivityTier.frameInterval  (R6.3)

    func test_frameInterval_slow_is0_40() {
        XCTAssertEqual(MenubarActivityTier.slow.frameInterval, 0.40, accuracy: 0.001)
    }

    func test_frameInterval_normal_is0_25() {
        XCTAssertEqual(MenubarActivityTier.normal.frameInterval, 0.25, accuracy: 0.001)
    }

    func test_frameInterval_fast_is0_14() {
        XCTAssertEqual(MenubarActivityTier.fast.frameInterval, 0.14, accuracy: 0.001)
    }

    // MARK: - AC6 — frameIndex(tick:frameCount:)  (R7.6)

    func test_frameIndex_sequentialTicks_cyclesThroughSixFrames() {
        let expected = [0, 1, 2, 3, 4, 5, 0, 1]
        for tick in 0...7 {
            XCTAssertEqual(
                MenubarActivityIndicator.frameIndex(tick: tick, frameCount: 6),
                expected[tick],
                "tick \(tick)"
            )
        }
    }

    func test_frameIndex_zeroFrameCount_returnsZero() {
        XCTAssertEqual(MenubarActivityIndicator.frameIndex(tick: 3, frameCount: 0), 0)
    }

    func test_frameIndex_negativeOne_returnsFive() {
        // ((tick % n) + n) % n — 음수 모듈로 보정. -1 → 5
        XCTAssertEqual(MenubarActivityIndicator.frameIndex(tick: -1, frameCount: 6), 5)
    }

    func test_frameIndex_negativeSeven_returnsFive() {
        // -7 → 5 (경계값)
        XCTAssertEqual(MenubarActivityIndicator.frameIndex(tick: -7, frameCount: 6), 5)
    }

    // MARK: - AC7 — runningCount(in:)  (R4.3)

    func test_runningCount_parentWorking_noSubagents_returns1() {
        let agents = [makeAgent(id: "p1", status: .working)]
        XCTAssertEqual(MenubarActivityIndicator.runningCount(in: agents), 1)
    }

    func test_runningCount_parentWorking_mirroredBySingleWorkingSubagent_returns1() {
        // 부모 .working (서브 상태를 미러링) + 서브 1개 .working → 1 (중복 집계 없음)
        let sub = makeAgent(id: "s1", status: .working)
        let parent = makeAgent(id: "p1", status: .working, subagents: [sub])
        XCTAssertEqual(MenubarActivityIndicator.runningCount(in: [parent]), 1)
    }

    func test_runningCount_parentWorking_threeSubagentsWorking_returns3() {
        let subs = (0..<3).map { makeAgent(id: "s\($0)", status: .working) }
        let parent = makeAgent(id: "p1", status: .working, subagents: subs)
        XCTAssertEqual(MenubarActivityIndicator.runningCount(in: [parent]), 3)
    }

    /// ⚠️ SPEC R4.3 주석: 부모가 비활성(.thinking)이고 서브가 활성이면 실제로는
    /// `displayOverride`가 부모 표시를 서브로 덮어써 부모의 `status`가 `.working`이
    /// 되므로, 이 조합("부모 .thinking + 서브 .working")은 production에서는
    /// 관측되지 않는다. 그러나 `runningCount(in:)` 자체의 방어적 정확성을 검증하는
    /// 픽스처로는 유효하다 — "동작 명세"로 오해하지 말 것 (동작 명세 아님, 단위 테스트 전용).
    func test_runningCount_parentThinking_twoSubagentsWorking_returns2_unitTestFixtureOnly() {
        let subs = (0..<2).map { makeAgent(id: "s\($0)", status: .working) }
        let parent = makeAgent(id: "p1", status: .thinking, subagents: subs)
        XCTAssertEqual(MenubarActivityIndicator.runningCount(in: [parent]), 2)
    }

    func test_runningCount_parentIdle_noSubagents_returns0() {
        let agents = [makeAgent(id: "p1", status: .idle)]
        XCTAssertEqual(MenubarActivityIndicator.runningCount(in: agents), 0)
    }

    func test_runningCount_parentWaitingApproval_noSubagents_returns0() {
        let agents = [makeAgent(id: "p1", status: .waitingApproval)]
        XCTAssertEqual(MenubarActivityIndicator.runningCount(in: agents), 0)
    }

    // MARK: - AC8 — runningCount: .thinking은 카운트에 포함되지 않는다  (R4.1)

    func test_runningCount_onlyThinkingAgents_returnsZero() {
        let agents = (0..<3).map { makeAgent(id: "a\($0)", status: .thinking) }
        XCTAssertEqual(MenubarActivityIndicator.runningCount(in: agents), 0)
    }

    // MARK: - AC43 — hasSustainingActivity(in:)  (R4.5)
    //
    // ⚠️ 스텁은 항상 false를 반환한다. 아래 네 번째 테스트(전부 유휴)만
    // 기댓값이 false이므로 스텁만으로도 우연히 GREEN이다. 나머지 세 개는 RED다.

    func test_hasSustainingActivity_parentThinking_subWorking_returnsTrue() {
        let sub = makeAgent(id: "s1", status: .working)
        let parent = makeAgent(id: "p1", status: .thinking, subagents: [sub])
        XCTAssertTrue(MenubarActivityIndicator.hasSustainingActivity(in: [parent]))
    }

    func test_hasSustainingActivity_parentWaitingApproval_noSubagents_returnsTrue() {
        let agents = [makeAgent(id: "p1", status: .waitingApproval)]
        XCTAssertTrue(MenubarActivityIndicator.hasSustainingActivity(in: agents))
    }

    func test_hasSustainingActivity_parentThinking_subWaitingApproval_returnsTrue() {
        let sub = makeAgent(id: "s1", status: .waitingApproval)
        let parent = makeAgent(id: "p1", status: .thinking, subagents: [sub])
        XCTAssertTrue(MenubarActivityIndicator.hasSustainingActivity(in: [parent]))
    }

    func test_hasSustainingActivity_allThinkingOrIdle_returnsFalse() {
        let agents = [
            makeAgent(id: "a1", status: .thinking),
            makeAgent(id: "a2", status: .idle)
        ]
        XCTAssertFalse(MenubarActivityIndicator.hasSustainingActivity(in: agents))
    }

    // MARK: - AC9 — isActive(...) hold 축  (R5.1/R5.6)
    //
    // ⚠️ 스텁은 항상 true를 반환한다. 기댓값이 true인 테스트(withinHold, clockRewind)는
    // 스텁만으로도 우연히 GREEN이다. false를 기대하는 나머지는 RED다.

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func test_isActive_bothNil_returnsFalse() {
        XCTAssertFalse(MenubarActivityIndicator.isActive(
            lastWorkingAt: nil, lastSustainAt: nil, now: t0, hold: 4, maxSustain: 90
        ))
    }

    func test_isActive_withinHold_returnsTrue() {
        let past = t0.addingTimeInterval(-3.9)
        XCTAssertTrue(MenubarActivityIndicator.isActive(
            lastWorkingAt: past, lastSustainAt: past, now: t0, hold: 4, maxSustain: 90
        ))
    }

    func test_isActive_atHoldBoundary_returnsFalse() {
        // strict < 이므로 정확히 4.0은 hold를 만족하지 못한다
        let past = t0.addingTimeInterval(-4.0)
        XCTAssertFalse(MenubarActivityIndicator.isActive(
            lastWorkingAt: past, lastSustainAt: past, now: t0, hold: 4, maxSustain: 90
        ))
    }

    func test_isActive_beyondHold_returnsFalse() {
        let past = t0.addingTimeInterval(-4.1)
        XCTAssertFalse(MenubarActivityIndicator.isActive(
            lastWorkingAt: past, lastSustainAt: past, now: t0, hold: 4, maxSustain: 90
        ))
    }

    func test_isActive_clockRewind_returnsTrueWithoutCrash() {
        // now가 lastWorkingAt/lastSustainAt보다 과거인 "시계 역행" — 경과시간이 음수
        let future = t0.addingTimeInterval(1.0)
        XCTAssertTrue(MenubarActivityIndicator.isActive(
            lastWorkingAt: future, lastSustainAt: future, now: t0, hold: 4, maxSustain: 90
        ))
    }

    // MARK: - AC35 — isActive(...) maxSustain 축  (R5.1/R5.2)
    //
    // ⚠️ 스텁은 항상 true다. 긴 MCP 호출 케이스(within)와 nil 폴백 케이스는
    // 스텁만으로도 우연히 GREEN이다. false를 기대하는 나머지 두 개는 RED다.

    func test_isActive_withinMaxSustain_longMCPCall_returnsTrue() {
        XCTAssertTrue(MenubarActivityIndicator.isActive(
            lastWorkingAt: t0.addingTimeInterval(-89.9),
            lastSustainAt: t0.addingTimeInterval(-0.1),
            now: t0, hold: 4, maxSustain: 90
        ))
    }

    func test_isActive_atMaxSustainBoundary_returnsFalse() {
        // strict < 이므로 정확히 90.0은 maxSustain을 만족하지 못한다
        XCTAssertFalse(MenubarActivityIndicator.isActive(
            lastWorkingAt: t0.addingTimeInterval(-90.0),
            lastSustainAt: t0.addingTimeInterval(-0.1),
            now: t0, hold: 4, maxSustain: 90
        ))
    }

    func test_isActive_beyondMaxSustain_overnightApproval_returnsFalse() {
        XCTAssertFalse(MenubarActivityIndicator.isActive(
            lastWorkingAt: t0.addingTimeInterval(-300),
            lastSustainAt: t0.addingTimeInterval(-0.1),
            now: t0, hold: 4, maxSustain: 90
        ))
    }

    func test_isActive_nilSustainAt_fallsBackToLastWorkingAt_returnsTrue() {
        // lastSustainAt == nil → sustain := lastWorkingAt (방어적 폴백, R5.1)
        XCTAssertTrue(MenubarActivityIndicator.isActive(
            lastWorkingAt: t0.addingTimeInterval(-1.0),
            lastSustainAt: nil,
            now: t0, hold: 4, maxSustain: 90
        ))
    }

    // MARK: - AC10 — timerPlan(current:desired:)  (R7.4)
    //
    // ⚠️ 스텁은 항상 .keep이다. nilToNil / slowToSlow(둘 다 기댓값 .keep)는
    // 스텁만으로도 우연히 GREEN이다. 나머지 세 개는 RED다.

    func test_timerPlan_nilToNil_returnsKeep() {
        XCTAssertEqual(MenubarActivityIndicator.timerPlan(current: nil, desired: nil), .keep)
    }

    func test_timerPlan_slowToSlow_returnsKeep() {
        XCTAssertEqual(MenubarActivityIndicator.timerPlan(current: .slow, desired: .slow), .keep)
    }

    func test_timerPlan_slowToNormal_returnsRestartNormal() {
        XCTAssertEqual(
            MenubarActivityIndicator.timerPlan(current: .slow, desired: .normal),
            .restart(.normal)
        )
    }

    func test_timerPlan_normalToNil_returnsStop() {
        XCTAssertEqual(MenubarActivityIndicator.timerPlan(current: .normal, desired: nil), .stop)
    }

    func test_timerPlan_nilToSlow_returnsRestartSlow() {
        XCTAssertEqual(
            MenubarActivityIndicator.timerPlan(current: nil, desired: .slow),
            .restart(.slow)
        )
    }

    // MARK: - AC11/AC12/AC13 — logoRect(frameIndex:)  (R2.8/R2.4/R2.6/R2.7)

    func test_logoRect_allFrames_containedInCanvasBounds() {
        let canvasBounds = NSRect(origin: .zero, size: MenubarActivityIndicator.canvasSize)
        for i in 0..<6 {
            let rect = MenubarActivityIndicator.logoRect(frameIndex: i)
            XCTAssertTrue(canvasBounds.contains(rect), "frame \(i) rect \(rect) not contained in \(canvasBounds)")
        }
    }

    func test_logoRect_frame0_isCenteredRestPose() {
        let rect = MenubarActivityIndicator.logoRect(frameIndex: 0)
        XCTAssertEqual(rect, NSRect(x: 0, y: 1.5, width: 18, height: 18))
        // 중심 y가 캔버스 정중앙과 같아야 한다 (= 현행 위치, R2.7)
        XCTAssertEqual(rect.midY, MenubarActivityIndicator.canvasSize.height / 2, accuracy: 0.001)
    }

    func test_logoRect_yRange_matchesTwiceAmplitude() {
        let ys = (0..<6).map { MenubarActivityIndicator.logoRect(frameIndex: $0).origin.y }
        let maxY = ys.max()!
        let minY = ys.min()!
        XCTAssertEqual(maxY, 3.0, accuracy: 0.001)   // frame 1/2, restY(1.5) + amplitude(1.5)
        XCTAssertEqual(minY, 0.0, accuracy: 0.001)   // frame 5, restY(1.5) - amplitude(1.5)
        XCTAssertEqual(maxY - minY, 2 * MenubarActivityIndicator.amplitude, accuracy: 0.001)
    }

    // MARK: - AC14 — canvasSize와 메뉴바 두께  (R2.5)
    //
    // 참고: 이 단정은 "아직 구현되지 않은 함수"가 아니라 S0에서 이미 확정된
    // 상수(canvasSize)에 대한 것이라 스텁 여부와 무관하게 처음부터 GREEN이다.
    // RED 판정에는 영향이 없다 — 실패할 로직이 없기 때문이다.

    func test_canvasSize_height_doesNotExceedStatusBarThickness() {
        XCTAssertLessThanOrEqual(
            MenubarActivityIndicator.canvasSize.height,
            NSStatusBar.system.thickness
        )
    }

    // MARK: - AC15/AC16 — makeFrame(index:source:)  (R3.7/R2.6)

    func test_makeFrame_allFrames_haveCanvasSizeAndNotTemplate() {
        let source = makeDummySource()
        for i in 0..<6 {
            let frame = MenubarActivityIndicator.makeFrame(index: i, source: source)
            XCTAssertEqual(frame.size, MenubarActivityIndicator.canvasSize, "frame \(i) size")
            XCTAssertFalse(frame.isTemplate, "frame \(i) isTemplate")
        }
    }

    func test_makeFrame_frame1VsFrame5_producesDifferentPixels() {
        // R2.6 표: dy[1] = +1.5, dy[5] = -1.5 — 실제로 이동이 일어났다면 픽셀이 달라야 한다.
        // 인덱스 0과 4는 dy가 같으므로(둘 다 0.0) 비교 대상으로 쓰지 않는다.
        let source = makeDummySource()
        let frame1 = MenubarActivityIndicator.makeFrame(index: 1, source: source)
        let frame5 = MenubarActivityIndicator.makeFrame(index: 5, source: source)
        XCTAssertNotEqual(frame1.tiffRepresentation, frame5.tiffRepresentation)
    }

    // MARK: - AC37 — 아이콘 티어와 툴팁 숫자가 갈라지지 않는다  (R1.2/NFR6)

    func test_runningCount_andResolve_agreeForParentWithThreeWorkingSubagents() {
        let subs = (0..<3).map { makeAgent(id: "s\($0)", status: .working) }
        let parent = makeAgent(id: "p1", status: .working, subagents: subs)
        let agents = [parent]

        XCTAssertEqual(MenubarActivityIndicator.runningCount(in: agents), 3)
        XCTAssertEqual(
            MenubarActivityIndicator.resolve(style: .quotaSession, effectiveCount: 3),
            .animating(.fast)
        )
    }
}
