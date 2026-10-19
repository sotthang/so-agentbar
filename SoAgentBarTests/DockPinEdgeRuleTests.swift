import XCTest
import CoreGraphics
@testable import SoAgentBar

// MARK: - DockPinEdgeRuleTests
//
// SPEC-004 커밋 2 — 순수 계층(DockPinEdgeRule.swift) 단위 테스트.
// 커버 AC: AC5.1–5.10, AC5.9b, AC5.9c, AC5.12–5.14 + R5.2 이벤트 마스크, R5.4 판정 생성자, R5.5 비트마스크.
//
// RED 확인 방법: 이 파일은 컴파일된다(so-tester가 arch §2.3 시그니처의 고정값 스텁을 넣었다).
// 스텁은 일부러 틀린 값(뒤바뀐 .pass/.drop 상수, 표식 판정, 무동작 mutating, 빈 타입 목록,
// occupiedCount -1, 빈 칸 포함 사전 등)을 돌려주므로 아래 테스트는 전부 실패하는 것이 정상이다.
// 기대값이 스텁 기본값과 겹치는 단정(false, 0, 빈 마스크 등)은 같은 테스트 안에 짝 단정을 둔다.
//
// 좌표는 모두 CG 전역(주 화면 왼쪽 위 원점, 아래로 y 증가)이다. 트리거 줄은 DisplayMap을 거치지 않고
// 스냅숏에 직접 넣는다 — decide는 스냅숏만 보고 판정해야 한다(R5.3).
// 설정 저장소(standard 포함)는 쓰지 않는다 — 순수 값 타입만 부른다.

@MainActor
final class DockPinEdgeRuleTests: XCTestCase {

    // MARK: - 고정 배치 (AC3.1 좌우 3대: 가운데 3008×1692 주 화면이 고정 화면)

    private enum Fixture {
        static let centerID: CGDirectDisplayID = 1
        static let leftID: CGDirectDisplayID = 2
        static let rightID: CGDirectDisplayID = 3

        /// 오른쪽 2560×1440 (x 3008…5568, maxY 1440) 아래 줄
        static let rightRow = DockPinTriggerRow(displayID: rightID, minX: 3008, maxX: 5568, minY: 1439, maxY: 1440)
        /// 왼쪽 1728×1117 (x −1728…0, maxY 1117) 아래 줄
        static let leftRow = DockPinTriggerRow(displayID: leftID, minX: -1728, maxX: 0, minY: 1116, maxY: 1117)

        /// 고정 화면(가운데) 아래 줄 위의 점 — 트리거 줄이 아니다(R3.3: 고정 화면은 막지 않는다)
        static let anchorBottomEdge = CGPoint(x: 1500, y: 1691.5)
        /// 어느 줄에도 없는 점
        static let outside = CGPoint(x: 500, y: 500)
        /// 오른쪽 줄 안의 점
        static let inRightRow = CGPoint(x: 4000, y: 1439.5)
        /// 왼쪽 줄 안의 점
        static let inLeftRow = CGPoint(x: -800, y: 1116.5)

        static let idle = DockPinGuardSnapshot(rows: [rightRow, leftRow], isRelocating: false, isDriving: false,
                                               marker: DockPinTuning.eventMarker)
        /// R8.1 verifying 등 — 되돌리는 중이지만 커서를 움직이지는 않음
        static let relocatingNotDriving = DockPinGuardSnapshot(rows: [rightRow, leftRow], isRelocating: true,
                                                               isDriving: false, marker: DockPinTuning.eventMarker)
        /// R8.1 driving — isDriving이면 isRelocating도 참
        static let driving = DockPinGuardSnapshot(rows: [rightRow, leftRow], isRelocating: true, isDriving: true,
                                                  marker: DockPinTuning.eventMarker)
    }

    private enum Button {
        static let left: Int64 = 0
        static let right: Int64 = 1
        static let middle: Int64 = 2
        static let beyondMask: Int64 = 40   // 31 초과 → 억제 규칙(1a·2·3행) 미적용
    }

    // MARK: - 헬퍼

    /// 억제 상태를 이어 쓰는 판정(순서열 테스트용)
    private func decide(_ type: CGEventType, at location: CGPoint = Fixture.outside,
                        flags: CGEventFlags = [], userData: Int64 = 0, button: Int64 = Button.left,
                        snapshot: DockPinGuardSnapshot,
                        suppression: inout DockPinGestureSuppression) -> DockPinTapDecision {
        DockPinEdgeRule.decide(type: type, location: location, flags: flags,
                               userData: userData, buttonNumber: button,
                               snapshot: snapshot, suppression: &suppression)
    }

    /// 새 억제 상태(빈 마스크)로 한 번 판정
    private func decideFresh(_ type: CGEventType, at location: CGPoint = Fixture.outside,
                             flags: CGEventFlags = [], userData: Int64 = 0, button: Int64 = Button.left,
                             snapshot: DockPinGuardSnapshot = Fixture.idle) -> DockPinTapDecision {
        var suppression = DockPinGestureSuppression()
        return decide(type, at: location, flags: flags, userData: userData, button: button,
                      snapshot: snapshot, suppression: &suppression)
    }

    private static let moveAndDragTypes: [CGEventType] = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    ]

    // MARK: - R5.4 판정 생성자 (struct + static 멤버)

    func test_R5_4_tapDecision_staticPassAndDrop_haveNoSignal() {
        XCTAssertEqual(DockPinTapDecision.pass.action, .pass)
        XCTAssertNil(DockPinTapDecision.pass.signal)
        XCTAssertEqual(DockPinTapDecision.drop.action, .drop)
        XCTAssertNil(DockPinTapDecision.drop.signal)
        XCTAssertNotEqual(DockPinTapDecision.pass, DockPinTapDecision.drop)
    }

    func test_R5_4_tapDecision_signalFactories_carryActionAndSignal() {
        let passing = DockPinTapDecision.pass(signal: .optionPass(7))
        XCTAssertEqual(passing.action, .pass)
        XCTAssertEqual(passing.signal, .optionPass(7))

        let dropping = DockPinTapDecision.drop(signal: .userActivity)
        XCTAssertEqual(dropping.action, .drop)
        XCTAssertEqual(dropping.signal, .userActivity)
    }

    // MARK: - R5.2 이벤트 마스크

    func test_R5_2_blockableTypes_areMouseMovedAndThreeDraggedTypes() {
        XCTAssertEqual(Set(DockPinEdgeRule.blockableTypes.map(\.rawValue)),
                       Set(Self.moveAndDragTypes.map(\.rawValue)))
        XCTAssertEqual(DockPinEdgeRule.blockableTypes.count, 4)
    }

    func test_R5_2_observedTypes_areDownUpForThreeButtonsAndScrollWheel() {
        let expected: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel,
        ]
        XCTAssertEqual(Set(DockPinEdgeRule.observedTypes.map(\.rawValue)), Set(expected.map(\.rawValue)))
        XCTAssertEqual(DockPinEdgeRule.observedTypes.count, 7)
    }

    func test_R5_2_eventMask_isUnionOfBlockableAndObservedBits() {
        let all: [CGEventType] = Self.moveAndDragTypes + [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel,
        ]
        let expected = all.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        XCTAssertEqual(DockPinEdgeRule.eventMask, expected)
    }

    func test_R5_2_eventMask_excludesKeyboardEvents() {
        let mask = DockPinEdgeRule.eventMask
        XCTAssertNotEqual(mask, 0, "마스크가 비어 있으면 안 된다")
        for keyboard: CGEventType in [.keyDown, .keyUp, .flagsChanged] {
            XCTAssertEqual(mask & (CGEventMask(1) << CGEventMask(keyboard.rawValue)), 0,
                           "키보드 이벤트 \(keyboard.rawValue)는 받지 않는다")
        }
    }

    // MARK: - AC5.1 트리거 줄 y 경계 (오른쪽 화면 maxY 1440)

    func test_AC5_1_mouseMoved_insideRightRow_yFrom1439To1440Inclusive_drops() {
        for y: CGFloat in [1439.0, 1439.5, 1440.0] {
            XCTAssertEqual(decideFresh(.mouseMoved, at: CGPoint(x: 4000, y: y)), .drop, "y = \(y)")
        }
    }

    func test_AC5_1_mouseMoved_justAboveRightRow_y1438_99_passes() {
        XCTAssertEqual(decideFresh(.mouseMoved, at: CGPoint(x: 4000, y: 1438.99)), .pass)
    }

    // MARK: - AC5.2 트리거 줄 x 경계 (반열린 구간)

    func test_AC5_2_mouseMoved_atRowMinXAndMaxXMinusOne_drops() {
        XCTAssertEqual(decideFresh(.mouseMoved, at: CGPoint(x: 3008, y: 1439.5)), .drop)
        XCTAssertEqual(decideFresh(.mouseMoved, at: CGPoint(x: 5567, y: 1439.5)), .drop)
    }

    func test_AC5_2_mouseMoved_atRowMaxX_passes() {
        XCTAssertEqual(decideFresh(.mouseMoved, at: CGPoint(x: 5568, y: 1439.5)), .pass)
    }

    // MARK: - AC5.3 앱이 보낸 이벤트(표식)

    func test_AC5_3_taggedMouseMoved_insideRow_passes() {
        XCTAssertEqual(decideFresh(.mouseMoved, at: Fixture.inRightRow, userData: DockPinTuning.eventMarker), .pass)
    }

    func test_AC5_3_taggedEvent_whileDriving_passesWithoutSignal_andDoesNotSuppress() {
        // R5.4 1행이 2행보다 먼저다 — 되돌리기가 보낸 이벤트는 사용자 활동이 아니다
        var suppression = DockPinGestureSuppression()
        let moved = decide(.mouseMoved, at: Fixture.inRightRow, userData: DockPinTuning.eventMarker,
                           snapshot: Fixture.driving, suppression: &suppression)
        let down = decide(.leftMouseDown, userData: DockPinTuning.eventMarker,
                          snapshot: Fixture.driving, suppression: &suppression)
        XCTAssertEqual(moved, .pass)
        XCTAssertEqual(down, .pass)
        XCTAssertEqual(suppression.mask, 0)
    }

    func test_AC5_3_markerComparison_usesSnapshotMarker() {
        // 표식 값은 스냅숏에서 읽는다(R5.3). 다른 표식이면 일반 이벤트로 판정한다.
        var snapshot = Fixture.idle
        snapshot.marker = 42
        XCTAssertEqual(decideFresh(.mouseMoved, at: Fixture.inRightRow, userData: 42, snapshot: snapshot), .pass)
        XCTAssertEqual(decideFresh(.mouseMoved, at: Fixture.inRightRow, userData: DockPinTuning.eventMarker,
                                   snapshot: snapshot), .drop)
    }

    // MARK: - AC5.4 Option 통과

    func test_AC5_4_optionHeld_insideRightRow_passesWithOptionPassSignalForThatDisplay() {
        XCTAssertEqual(decideFresh(.mouseMoved, at: Fixture.inRightRow, flags: .maskAlternate),
                       .pass(signal: .optionPass(Fixture.rightID)))
    }

    func test_AC5_4_optionHeld_insideLeftRow_reportsLeftDisplayID() {
        XCTAssertEqual(decideFresh(.mouseMoved, at: Fixture.inLeftRow, flags: .maskAlternate),
                       .pass(signal: .optionPass(Fixture.leftID)))
    }

    func test_AC5_4_optionWithOtherModifiers_insideRow_stillOptionPass() {
        XCTAssertEqual(decideFresh(.leftMouseDragged, at: Fixture.inRightRow, flags: [.maskAlternate, .maskShift]),
                       .pass(signal: .optionPass(Fixture.rightID)))
    }

    func test_AC5_4_optionHeld_outsideRows_plainPass() {
        XCTAssertEqual(decideFresh(.mouseMoved, at: Fixture.outside, flags: .maskAlternate), .pass)
    }

    func test_AC5_4_nonOptionModifier_insideRow_stillDrops() {
        XCTAssertEqual(decideFresh(.mouseMoved, at: Fixture.inRightRow, flags: [.maskShift, .maskCommand]), .drop)
    }

    // MARK: - AC5.5 드래그도 막는다

    func test_AC5_5_leftMouseDragged_insideRow_drops() {
        XCTAssertEqual(decideFresh(.leftMouseDragged, at: Fixture.inRightRow), .drop)
    }

    func test_AC5_5_rightAndOtherMouseDragged_insideRow_drop() {
        XCTAssertEqual(decideFresh(.rightMouseDragged, at: Fixture.inRightRow, button: Button.right), .drop)
        XCTAssertEqual(decideFresh(.otherMouseDragged, at: Fixture.inRightRow, button: Button.middle), .drop)
    }

    func test_R5_4_row9_moveAndDrag_outsideRows_pass() {
        for type in Self.moveAndDragTypes {
            XCTAssertEqual(decideFresh(type, at: Fixture.outside), .pass, "type \(type.rawValue)")
        }
    }

    func test_R5_4_emptyRows_insideFormerRowArea_passes() {
        // 줄이 없으면(오버라이드·비활성 등) 어디서든 통과
        var snapshot = Fixture.idle
        snapshot.rows = []
        XCTAssertEqual(decideFresh(.mouseMoved, at: Fixture.inRightRow, snapshot: snapshot), .pass)
    }

    // MARK: - AC5.6 되돌리는 중(isRelocating)

    func test_AC5_6a_relocating_moveInsideRow_dropsWithUserActivity() {
        XCTAssertEqual(decideFresh(.mouseMoved, at: Fixture.inRightRow, snapshot: Fixture.relocatingNotDriving),
                       .drop(signal: .userActivity))
        XCTAssertEqual(decideFresh(.leftMouseDragged, at: Fixture.inRightRow, snapshot: Fixture.driving),
                       .drop(signal: .userActivity))
    }

    func test_AC5_6b_relocating_moveOutsideRow_passesWithUserActivity() {
        XCTAssertEqual(decideFresh(.mouseMoved, at: Fixture.outside, snapshot: Fixture.relocatingNotDriving),
                       .pass(signal: .userActivity))
        XCTAssertEqual(decideFresh(.mouseMoved, at: Fixture.outside, snapshot: Fixture.driving),
                       .pass(signal: .userActivity))
    }

    func test_AC5_6_relocating_optionInsideRow_dropsWithUserActivity_notOptionPass() {
        // 6행이 7행보다 먼저다 — 되돌리는 중에는 Option도 줄을 열지 않는다(P1 유지)
        XCTAssertEqual(decideFresh(.mouseMoved, at: Fixture.inRightRow, flags: .maskAlternate,
                                   snapshot: Fixture.relocatingNotDriving),
                       .drop(signal: .userActivity))
    }

    // MARK: - AC5.7 driving 중 Down

    func test_AC5_7_driving_untaggedLeftMouseDown_dropsWithUserActivity() {
        XCTAssertEqual(decideFresh(.leftMouseDown, snapshot: Fixture.driving), .drop(signal: .userActivity))
    }

    func test_AC5_7_notDriving_leftMouseDown_passes() {
        XCTAssertEqual(decideFresh(.leftMouseDown, snapshot: Fixture.idle), .pass)
    }

    func test_AC5_7_relocatingButNotDriving_leftMouseDown_passesWithoutSignal() {
        // 2·5행은 isDriving만 본다(R8.1 verifying 구간은 클릭을 막지 않는다)
        XCTAssertEqual(decideFresh(.leftMouseDown, snapshot: Fixture.relocatingNotDriving), .pass)
    }

    func test_AC5_7_driving_down_insertsButtonIntoSuppression() {
        var suppression = DockPinGestureSuppression()
        _ = decide(.rightMouseDown, button: Button.right, snapshot: Fixture.driving, suppression: &suppression)
        XCTAssertTrue(suppression.contains(button: Button.right))
        XCTAssertFalse(suppression.contains(button: Button.left))
    }

    func test_R5_4_row5_upAndDown_notDriving_passWithoutSignal() {
        for type: CGEventType in [.leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp] {
            XCTAssertEqual(decideFresh(type, button: Button.middle), .pass, "type \(type.rawValue)")
        }
    }

    // MARK: - AC5.8 스크롤

    func test_AC5_8_scrollWheel_whileDriving_dropsWithUserActivity() {
        XCTAssertEqual(decideFresh(.scrollWheel, snapshot: Fixture.driving), .drop(signal: .userActivity))
    }

    func test_AC5_8_scrollWheel_notDriving_passes() {
        XCTAssertEqual(decideFresh(.scrollWheel, snapshot: Fixture.idle), .pass)
        XCTAssertEqual(decideFresh(.scrollWheel, snapshot: Fixture.relocatingNotDriving), .pass)
    }

    // MARK: - AC5.9 제스처 억제 순서열 (같은 억제 상태를 이어 쓴다)

    func test_AC5_9_downDuringDrive_suppressesDragsAndUpAfterDriveEnds_thenReleases() {
        var s = DockPinGestureSuppression()

        XCTAssertEqual(decide(.leftMouseDown, snapshot: Fixture.driving, suppression: &s),
                       .drop(signal: .userActivity), "driving 중 Down")

        // isDriving 해제 → 줄 밖 드래그 3개와 Up은 모두 버린다
        for i in 1...3 {
            XCTAssertEqual(decide(.leftMouseDragged, at: Fixture.outside, snapshot: Fixture.idle, suppression: &s),
                           .drop, "억제 중 Dragged #\(i)")
        }
        XCTAssertEqual(decide(.leftMouseUp, snapshot: Fixture.idle, suppression: &s), .drop, "억제 중 Up")

        // Up으로 억제가 끝났다
        XCTAssertEqual(decide(.leftMouseDragged, at: Fixture.outside, snapshot: Fixture.idle, suppression: &s), .pass)
        XCTAssertEqual(decide(.leftMouseUp, snapshot: Fixture.idle, suppression: &s), .pass)
        XCTAssertEqual(s.mask, 0)
    }

    func test_AC5_9_suppressedDragAndUp_whileStillDriving_dropWithUserActivity() {
        var s = DockPinGestureSuppression()
        _ = decide(.leftMouseDown, snapshot: Fixture.driving, suppression: &s)
        XCTAssertEqual(decide(.leftMouseDragged, snapshot: Fixture.driving, suppression: &s),
                       .drop(signal: .userActivity))
        XCTAssertEqual(decide(.leftMouseUp, snapshot: Fixture.driving, suppression: &s),
                       .drop(signal: .userActivity))
        XCTAssertFalse(s.contains(button: Button.left), "Up이 억제를 끝낸다")
    }

    // MARK: - AC5.9b 억제되지 않은 버튼

    func test_AC5_9b_downBeforeDrive_upDuringDrive_passesWithUserActivity() {
        var s = DockPinGestureSuppression()
        XCTAssertEqual(decide(.rightMouseDown, button: Button.right, snapshot: Fixture.idle, suppression: &s), .pass)
        XCTAssertEqual(decide(.rightMouseUp, button: Button.right, snapshot: Fixture.driving, suppression: &s),
                       .pass(signal: .userActivity))
    }

    func test_AC5_9b_leftSuppressed_rightDragged_isNotSuppressed() {
        var s = DockPinGestureSuppression()
        _ = decide(.leftMouseDown, snapshot: Fixture.driving, suppression: &s)
        XCTAssertTrue(s.contains(button: Button.left))

        XCTAssertEqual(decide(.rightMouseDragged, at: Fixture.outside, button: Button.right,
                              snapshot: Fixture.idle, suppression: &s), .pass)
        XCTAssertTrue(s.contains(button: Button.left), "오른쪽 버튼 이벤트가 왼쪽 억제를 건드리지 않는다")
    }

    // MARK: - AC5.9c Up을 놓친 억제 (리뷰 v2 C9)

    func test_AC5_9c_missedUp_nextDownAfterDrive_releasesSuppression_andWholeClickPasses() {
        var s = DockPinGestureSuppression()
        XCTAssertEqual(decide(.leftMouseDown, snapshot: Fixture.driving, suppression: &s),
                       .drop(signal: .userActivity))
        XCTAssertTrue(s.contains(button: Button.left))

        // (Up 없음) isDriving 해제 뒤 새 클릭
        XCTAssertEqual(decide(.leftMouseDown, snapshot: Fixture.idle, suppression: &s), .pass, "1a행")
        XCTAssertEqual(decide(.leftMouseDragged, at: Fixture.outside, snapshot: Fixture.idle, suppression: &s), .pass)
        XCTAssertEqual(decide(.leftMouseUp, snapshot: Fixture.idle, suppression: &s), .pass)
        XCTAssertEqual(s.mask, 0)
    }

    func test_AC5_9c_missedUp_downWhileDrivingAgain_followsRow2() {
        var s = DockPinGestureSuppression()
        _ = decide(.leftMouseDown, snapshot: Fixture.driving, suppression: &s)
        // (Up 없음) 다시 driving 중 Down → 1a가 아니라 2행
        XCTAssertEqual(decide(.leftMouseDown, snapshot: Fixture.driving, suppression: &s),
                       .drop(signal: .userActivity))
        XCTAssertTrue(s.contains(button: Button.left))
    }

    // MARK: - R5.5 31 초과 버튼은 억제 규칙 미적용 (5행)

    func test_R5_5_buttonBeyond31_downWhileDriving_passesWithUserActivity_andIsNotSuppressed() {
        var s = DockPinGestureSuppression()
        XCTAssertEqual(decide(.otherMouseDown, button: Button.beyondMask, snapshot: Fixture.driving, suppression: &s),
                       .pass(signal: .userActivity))
        XCTAssertEqual(s.mask, 0)
        XCTAssertEqual(decide(.otherMouseUp, button: Button.beyondMask, snapshot: Fixture.idle, suppression: &s),
                       .pass)
    }

    // MARK: - AC5.10 고정 화면 아래 줄은 언제나 통과

    func test_AC5_10_anchorBottomEdge_moveAndDrag_alwaysPassAction() {
        for type in Self.moveAndDragTypes {
            XCTAssertEqual(decideFresh(type, at: Fixture.anchorBottomEdge, snapshot: Fixture.idle), .pass,
                           "idle type \(type.rawValue)")
            XCTAssertEqual(decideFresh(type, at: Fixture.anchorBottomEdge, flags: .maskAlternate,
                                       snapshot: Fixture.idle), .pass,
                           "option type \(type.rawValue)")
            XCTAssertEqual(decideFresh(type, at: Fixture.anchorBottomEdge, snapshot: Fixture.driving).action, .pass,
                           "driving type \(type.rawValue)")
        }
    }

    func test_AC5_10_anchorBottomEdge_whileRelocating_passesWithUserActivity() {
        XCTAssertEqual(decideFresh(.mouseMoved, at: Fixture.anchorBottomEdge, snapshot: Fixture.relocatingNotDriving),
                       .pass(signal: .userActivity))
    }

    // MARK: - R5.5 DockPinGestureSuppression 비트마스크

    func test_R5_5_suppression_insertContainsRemove_singleBit() {
        var s = DockPinGestureSuppression()
        s.insert(button: 3)
        XCTAssertTrue(s.contains(button: 3))
        XCTAssertEqual(s.mask, 1 << 3)
        XCTAssertFalse(s.contains(button: 2))
        s.remove(button: 3)
        XCTAssertFalse(s.contains(button: 3))
        XCTAssertEqual(s.mask, 0)
    }

    func test_R5_5_suppression_boundaryButtons0And31_useLowestAndHighestBits() {
        var s = DockPinGestureSuppression()
        s.insert(button: 0)
        s.insert(button: 31)
        XCTAssertEqual(s.mask, UInt32(1) | (UInt32(1) << 31))
        XCTAssertTrue(s.contains(button: 0))
        XCTAssertTrue(s.contains(button: 31))
    }

    func test_R5_5_suppression_outOfRangeButtons_areIgnored() {
        var s = DockPinGestureSuppression()
        s.insert(button: 5)
        s.insert(button: 32)
        s.insert(button: -1)
        s.insert(button: Int64.max)
        XCTAssertEqual(s.mask, 1 << 5, "범위 밖 번호는 비트를 바꾸지 않는다")
        XCTAssertFalse(s.contains(button: 32))
        XCTAssertFalse(s.contains(button: -1))
        s.remove(button: 37)   // 범위 밖 제거도 무시(크래시 없음)
        XCTAssertTrue(s.contains(button: 5))
    }

    func test_R5_5_suppression_reset_clearsAllBits() {
        var s = DockPinGestureSuppression()
        s.insert(button: 0)
        s.insert(button: 1)
        XCTAssertNotEqual(s.mask, 0)
        s.reset()
        XCTAssertEqual(s.mask, 0)
        XCTAssertEqual(s, DockPinGestureSuppression())
    }

    // MARK: - AC5.12 탭 수명

    func test_AC5_12_disabledEvent_whenArmedAndNotStopping_reenablesOnce() {
        var life = DockPinTapLifecycle()
        life.arm()
        XCTAssertTrue(life.isArmed)
        XCTAssertFalse(life.isStopping)
        XCTAssertTrue(life.handleDisabledEvent())
        XCTAssertEqual(life.reenableCount, 1)
    }

    func test_AC5_12_disabledEvent_afterBeginStop_doesNotReenable() {
        var life = DockPinTapLifecycle()
        life.arm()
        life.beginStop()
        XCTAssertTrue(life.isStopping)
        XCTAssertFalse(life.isArmed)
        XCTAssertFalse(life.handleDisabledEvent())
        XCTAssertEqual(life.reenableCount, 0)
    }

    func test_AC5_12_disabledEvent_beforeArm_doesNotReenable_butAfterArmDoes() {
        var life = DockPinTapLifecycle()
        XCTAssertFalse(life.handleDisabledEvent())
        XCTAssertEqual(life.reenableCount, 0)
        life.arm()
        XCTAssertTrue(life.handleDisabledEvent())
        XCTAssertEqual(life.reenableCount, 1)
    }

    func test_AC5_12_reenableCount_accumulates_andRearmAfterStopClearsStopping() {
        var life = DockPinTapLifecycle()
        life.arm()
        _ = life.handleDisabledEvent()
        _ = life.handleDisabledEvent()
        XCTAssertEqual(life.reenableCount, 2)

        life.beginStop()
        life.arm()   // 탭 재생성(start) — 정리 상태가 풀린다
        XCTAssertTrue(life.isArmed)
        XCTAssertFalse(life.isStopping)
        XCTAssertTrue(life.handleDisabledEvent())
        XCTAssertEqual(life.reenableCount, 3)
    }

    // MARK: - AC5.13 신호 상자

    func test_AC5_13_threeOptionPassesInARow_onlyFirstRequestsNotify() {
        var box = DockPinSignalBox()
        XCTAssertTrue(box.record(.optionPass(3), at: 100))
        XCTAssertFalse(box.record(.optionPass(3), at: 101))
        XCTAssertFalse(box.record(.optionPass(2), at: 102))
        XCTAssertTrue(box.notifyPending)
    }

    func test_AC5_13_afterDrain_nextOptionPassRequestsNotifyAgain() {
        var box = DockPinSignalBox()
        _ = box.record(.optionPass(3), at: 100)
        let drained = box.drain()
        XCTAssertTrue(drained.hadOptionPass)
        XCTAssertFalse(box.notifyPending)
        XCTAssertTrue(box.record(.optionPass(3), at: 105))
    }

    func test_AC5_13_userActivity_returnsFalse_andOnlyIncrementsCounter() {
        var box = DockPinSignalBox()
        XCTAssertFalse(box.record(.userActivity, at: 100))
        XCTAssertFalse(box.record(.userActivity, at: 101))
        XCTAssertEqual(box.userActivityCount, 2)
        XCTAssertFalse(box.notifyPending)
        XCTAssertEqual(box.optionPasses.occupiedCount, 0)
    }

    func test_AC5_13_drain_returnsCountsAndLatestOptionPassTimes() {
        var box = DockPinSignalBox()
        _ = box.record(.userActivity, at: 99)
        _ = box.record(.optionPass(3), at: 100)
        _ = box.record(.optionPass(3), at: 103.5)
        _ = box.record(.optionPass(2), at: 101)
        let drained = box.drain()
        XCTAssertEqual(drained, DockPinTapSignals(userActivityCount: 1,
                                                  optionPasses: [3: 103.5, 2: 101],
                                                  hadOptionPass: true))
    }

    func test_AC5_13_drain_keepsSlotsAndCounter_onlyLowersPendingFlag() {
        var box = DockPinSignalBox()
        _ = box.record(.userActivity, at: 99)
        _ = box.record(.optionPass(3), at: 100)
        _ = box.drain()
        let second = box.drain()
        XCTAssertEqual(second, DockPinTapSignals(userActivityCount: 1, optionPasses: [3: 100], hadOptionPass: false),
                       "칸은 지우지 않고(멱등 합치기), 카운터는 단조 증가, 대기 플래그만 내려간다")
    }

    func test_AC5_13_drain_onEmptyBox_isEmpty() {
        var box = DockPinSignalBox()
        XCTAssertEqual(box.drain(), DockPinTapSignals(userActivityCount: 0, optionPasses: [:], hadOptionPass: false))
        XCTAssertTrue(box.record(.optionPass(1), at: 1), "짝 단정: 빈 상자 뒤 첫 Option 통과는 알림 필요")
    }

    // MARK: - AC5.14 Option 통과 고정 칸

    func test_AC5_14_sameDisplayRecordedTwice_overwritesOneSlotWithLatestTime() {
        var slots = DockPinOptionPassSlots()
        slots.record(3, at: 100)
        slots.record(3, at: 104)
        XCTAssertEqual(slots.occupiedCount, 1)
        XCTAssertEqual(slots.toDictionary(), [3: 104])
    }

    func test_AC5_14_fortyDistinctDisplays_keepsThirtyTwoSlots_mostRecent32Remain() {
        var slots = DockPinOptionPassSlots()
        for id in 1...40 {
            slots.record(CGDirectDisplayID(id), at: TimeInterval(id))
        }
        XCTAssertEqual(slots.occupiedCount, DockPinTuning.optionPassSlots)
        XCTAssertEqual(slots.occupiedCount, 32)

        var expected: [CGDirectDisplayID: TimeInterval] = [:]
        for id in 9...40 { expected[CGDirectDisplayID(id)] = TimeInterval(id) }
        XCTAssertEqual(slots.toDictionary(), expected, "가장 오래된 칸(1…8)부터 덮인다")
    }

    func test_AC5_14_whenFull_evictsOldestTime_tieGoesToLowestIndex() {
        var slots = DockPinOptionPassSlots()
        for id in 1...32 {
            slots.record(CGDirectDisplayID(id), at: 50)   // 모두 같은 시각
        }
        slots.record(33, at: 60)
        XCTAssertEqual(slots.ids[0], 33, "동률이면 낮은 인덱스(0번 칸)를 덮는다")
        XCTAssertEqual(slots.times[0], 60)
        XCTAssertEqual(slots.occupiedCount, 32)
        XCTAssertNil(slots.toDictionary()[1])
    }

    func test_AC5_14_recordFillsFirstEmptySlotInOrder() {
        var slots = DockPinOptionPassSlots()
        slots.record(7, at: 1)
        slots.record(9, at: 2)
        XCTAssertEqual(slots.ids[0], 7)
        XCTAssertEqual(slots.ids[1], 9)
        XCTAssertEqual(slots.times[1], 2)
        XCTAssertEqual(slots.ids[2], 0)
    }

    func test_AC5_14_toDictionary_excludesEmptySlots() {
        let empty = DockPinOptionPassSlots()
        XCTAssertEqual(empty.toDictionary(), [:])
        XCTAssertEqual(empty.occupiedCount, 0)

        var one = DockPinOptionPassSlots()
        one.record(5, at: 42)
        XCTAssertEqual(one.toDictionary(), [5: 42])
        XCTAssertNil(one.toDictionary()[0], "빈 칸(id 0)은 넣지 않는다")
    }

    func test_AC5_14_slotStorageWidth_matchesTuningConstant() {
        let slots = DockPinOptionPassSlots()
        XCTAssertEqual(slots.ids.scalarCount, DockPinTuning.optionPassSlots)
        XCTAssertEqual(slots.times.scalarCount, DockPinTuning.optionPassSlots)
        XCTAssertEqual(slots.occupiedCount, 0, "짝 단정: 새 저장소는 빈 칸뿐이다")
    }
}
