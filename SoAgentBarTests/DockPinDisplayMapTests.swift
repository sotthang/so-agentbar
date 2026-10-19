import XCTest
import CoreGraphics
@testable import SoAgentBar

// MARK: - DockPinDisplayMapTests
//
// SPEC-004 커밋 1 — 순수 계층(DockPinModels.swift, DockPinDisplayMap.swift) 단위 테스트.
// 커버 AC: AC2.1–2.5, AC3.1–3.11, AC4.5, AC8.9(순수부) + R2.1 저장 형식, R3.3 포함 판정, R3.7 결정성.
//
// RED 확인 방법: 이 파일은 컴파일된다(so-tester가 arch §2.1–2.2 시그니처의 고정값 스텁을 넣었다).
// 스텁은 일부러 틀린 값(nil, [], 의미 없는 조각, (-1,-1), .left, .main 등)을 돌려주므로
// 아래 단정은 전부 실패하는 것이 정상이다. 빈 결과·nil 기대 테스트도 스텁 값과 겹치지 않게
// 짝 단정(같은 테스트 안의 non-nil/non-empty 단정)을 함께 둔다.
//
// 좌표는 모두 CG 전역(CGDisplayBounds, 주 화면 왼쪽 위 원점, 아래로 y 증가)이다.
// 설정 저장소(standard 포함)는 쓰지 않는다 — 순수 함수만 부른다.

@MainActor
final class DockPinDisplayMapTests: XCTestCase {

    // MARK: - 고정 배치 (DockPinFakes.swift의 DockPinFixtures는 커밋 6 — 이름 충돌을 피해 파일 전용으로 둔다)

    private enum Fixture {
        static let sidecarUUID = "BAB59A29-3097-4311-993B-57A74473F53E"

        /// F1 — 이 Mac 내장 화면 (주 화면)
        static let builtIn = display(1, "BUILTIN-UUID", 0, 0, 1728, 1117, name: "Color LCD")
        /// F1 — 이 Mac Sidecar
        static let sidecar = display(12, sidecarUUID, 1728, 0, 1149, 802, name: "Sidecar Display (AirPlay)")

        /// AC3.1 — 좌우 3대, 위쪽 끝 정렬. 가운데가 주 화면.
        static let center3008 = display(1, "CENTER-UUID", 0, 0, 3008, 1692, name: "Center")
        static let left1728 = display(2, "LEFT-UUID", -1728, 0, 1728, 1117, name: "Left")
        static let right2560 = display(3, "RIGHT-UUID", 3008, 0, 2560, 1440, name: "Right")
        static var threeSideBySide: [DockPinDisplay] { [center3008, left1728, right2560] }

        static func display(_ id: CGDirectDisplayID, _ uuid: String,
                            _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                            mirrorOf: CGDirectDisplayID? = nil, name: String? = nil) -> DockPinDisplay {
            DockPinDisplay(id: id, uuid: uuid, bounds: CGRect(x: x, y: y, width: w, height: h),
                           mirrorOf: mirrorOf, name: name ?? "Display \(id)")
        }
    }

    private func row(_ id: CGDirectDisplayID, x: (CGFloat, CGFloat), y: (CGFloat, CGFloat)) -> DockPinTriggerRow {
        DockPinTriggerRow(displayID: id, minX: x.0, maxX: x.1, minY: y.0, maxY: y.1)
    }

    /// 조각 순서에 기대지 않도록 (displayID, minX) 순으로 정렬해 비교한다.
    private func sorted(_ rows: [DockPinTriggerRow]) -> [DockPinTriggerRow] {
        rows.sorted { ($0.displayID, $0.minX) < ($1.displayID, $1.minX) }
    }

    // MARK: - R2.1 DockPinTarget 저장 형식

    func test_R2_1_target_initFromNilOrEmptyStoredUUID_isMain() {
        XCTAssertEqual(DockPinTarget(storedUUID: nil), .main)
        XCTAssertEqual(DockPinTarget(storedUUID: ""), .main)
    }

    func test_R2_1_target_initFromNonEmptyStoredUUID_isDisplay() {
        XCTAssertEqual(DockPinTarget(storedUUID: Fixture.sidecarUUID), .display(uuid: Fixture.sidecarUUID))
    }

    func test_R2_1_target_storedUUID_mainIsNil_displayIsUUID() {
        XCTAssertNil(DockPinTarget.main.storedUUID)
        XCTAssertEqual(DockPinTarget.display(uuid: "ABC").storedUUID, "ABC")
    }

    // MARK: - AC2.1–2.4 resolveAnchor

    func test_AC2_1_resolveAnchor_mainTarget_returnsMainIDDisplay_withoutFallback() {
        let anchor = DockPinDisplayMap.resolveAnchor(displays: [Fixture.builtIn, Fixture.sidecar],
                                                     target: .main, mainID: 1)
        XCTAssertEqual(anchor, DockPinAnchor(display: Fixture.builtIn, usingFallbackAnchor: false))
    }

    func test_AC2_1_resolveAnchor_mainTarget_followsCurrentMainID() {
        // R2.2 — 사용자가 주 모니터를 바꾸면 고정 화면도 따라간다.
        let anchor = DockPinDisplayMap.resolveAnchor(displays: [Fixture.builtIn, Fixture.sidecar],
                                                     target: .main, mainID: 12)
        XCTAssertEqual(anchor?.display, Fixture.sidecar)
        XCTAssertEqual(anchor?.usingFallbackAnchor, false)
    }

    func test_AC2_2_resolveAnchor_connectedDisplayUUID_returnsThatDisplay_withoutFallback() {
        let anchor = DockPinDisplayMap.resolveAnchor(displays: [Fixture.builtIn, Fixture.sidecar],
                                                     target: .display(uuid: Fixture.sidecarUUID), mainID: 1)
        XCTAssertEqual(anchor, DockPinAnchor(display: Fixture.sidecar, usingFallbackAnchor: false))
    }

    func test_AC2_3_resolveAnchor_disconnectedDisplayUUID_fallsBackToMain_withFallbackFlag() {
        let anchor = DockPinDisplayMap.resolveAnchor(displays: [Fixture.builtIn],
                                                     target: .display(uuid: Fixture.sidecarUUID), mainID: 1)
        XCTAssertEqual(anchor, DockPinAnchor(display: Fixture.builtIn, usingFallbackAnchor: true))
    }

    func test_AC2_4_resolveAnchor_mainIDNotInList_returnsFirstDisplay() {
        // mainID 99가 미러 제외 목록에 없다 → 목록의 첫 화면
        let anchor = DockPinDisplayMap.resolveAnchor(displays: [Fixture.sidecar, Fixture.builtIn],
                                                     target: .main, mainID: 99)
        XCTAssertEqual(anchor?.display, Fixture.sidecar)
    }

    func test_AC2_4_resolveAnchor_emptyList_returnsNil() {
        XCTAssertNil(DockPinDisplayMap.resolveAnchor(displays: [], target: .main, mainID: 1))
        XCTAssertNil(DockPinDisplayMap.resolveAnchor(displays: [], target: .display(uuid: "X"), mainID: 1))
        // 스텁(nil 고정)과 구분되도록 비어 있지 않은 입력은 non-nil이어야 한다
        XCTAssertNotNil(DockPinDisplayMap.resolveAnchor(displays: [Fixture.builtIn], target: .main, mainID: 1))
    }

    // MARK: - AC2.5 targetChoices (S1, S2)

    func test_AC2_5_targetChoices_twoConnectedAndSavedTargetDisconnected_returnsFourInOrder() {
        let external = Fixture.display(5, "LG-UUID", 1728, 0, 2560, 1440, name: "LG UltraFine")
        let choices = DockPinDisplayMap.targetChoices(connected: [Fixture.builtIn, Fixture.sidecar],
                                                      target: .display(uuid: external.uuid),
                                                      savedName: "LG UltraFine")
        XCTAssertEqual(choices, [
            DockPinTargetChoice(id: "main", target: .main, kind: .main),
            DockPinTargetChoice(id: "BUILTIN-UUID", target: .display(uuid: "BUILTIN-UUID"),
                                kind: .connected(name: "Color LCD")),
            DockPinTargetChoice(id: Fixture.sidecarUUID, target: .display(uuid: Fixture.sidecarUUID),
                                kind: .connected(name: "Sidecar Display (AirPlay)")),
            DockPinTargetChoice(id: "LG-UUID", target: .display(uuid: "LG-UUID"),
                                kind: .disconnected(lastName: "LG UltraFine")),
        ])
    }

    func test_AC2_5_targetChoices_savedTargetConnected_returnsThree_noDisconnectedEntry() {
        let choices = DockPinDisplayMap.targetChoices(connected: [Fixture.builtIn, Fixture.sidecar],
                                                      target: .display(uuid: Fixture.sidecarUUID),
                                                      savedName: "Sidecar Display (AirPlay)")
        XCTAssertEqual(choices.count, 3)
        XCTAssertEqual(choices.map(\.id), ["main", "BUILTIN-UUID", Fixture.sidecarUUID])
    }

    func test_AC2_5_targetChoices_mainTarget_returnsThree_noDisconnectedEntry() {
        let choices = DockPinDisplayMap.targetChoices(connected: [Fixture.builtIn, Fixture.sidecar],
                                                      target: .main, savedName: nil)
        XCTAssertEqual(choices.map(\.id), ["main", "BUILTIN-UUID", Fixture.sidecarUUID])
        XCTAssertEqual(choices.first?.kind, .main)
    }

    func test_S2_targetChoices_disconnectedWithoutSavedName_hasNilLastName() {
        let choices = DockPinDisplayMap.targetChoices(connected: [Fixture.builtIn],
                                                      target: .display(uuid: "GONE"), savedName: nil)
        XCTAssertEqual(choices.count, 3)
        XCTAssertEqual(choices.last, DockPinTargetChoice(id: "GONE", target: .display(uuid: "GONE"),
                                                         kind: .disconnected(lastName: nil)))
    }

    func test_AC2_5_choice_displayNameToSave_mainNil_connectedName_disconnectedLastName() {
        XCTAssertNil(DockPinTargetChoice(id: "main", target: .main, kind: .main).displayNameToSave)
        XCTAssertEqual(DockPinTargetChoice(id: "A", target: .display(uuid: "A"),
                                           kind: .connected(name: "Studio Display")).displayNameToSave,
                       "Studio Display")
        XCTAssertEqual(DockPinTargetChoice(id: "B", target: .display(uuid: "B"),
                                           kind: .disconnected(lastName: "Old")).displayNameToSave, "Old")
        XCTAssertNil(DockPinTargetChoice(id: "C", target: .display(uuid: "C"),
                                         kind: .disconnected(lastName: nil)).displayNameToSave)
    }

    // MARK: - R3.3 트리거 줄 포함 판정 (y 양끝 포함, x 반열린)

    func test_R3_3_triggerRow_contains_yClosedInterval_xHalfOpen() {
        let r = row(12, x: (1728, 2877), y: (801, 802))
        XCTAssertTrue(r.contains(CGPoint(x: 1728, y: 801)), "왼쪽 아래 모서리 포함")
        XCTAssertTrue(r.contains(CGPoint(x: 1728, y: 802)), "y 위 끝(maxY) 포함 — 양끝 포함(리뷰 N7)")
        XCTAssertTrue(r.contains(CGPoint(x: 2876.5, y: 801.5)))
        XCTAssertFalse(r.contains(CGPoint(x: 2877, y: 801.5)), "x maxX는 제외(반열린)")
        XCTAssertFalse(r.contains(CGPoint(x: 1727.9, y: 801.5)))
        XCTAssertFalse(r.contains(CGPoint(x: 1800, y: 800.99)))
        XCTAssertFalse(r.contains(CGPoint(x: 1800, y: 802.01)))
    }

    func test_R3_6_span_length_isMaxMinusMin() {
        XCTAssertEqual(DockPinSpan(minX: 2000, maxX: 3008).length, 1008)
        XCTAssertEqual(DockPinSpan(minX: -1728, maxX: 0).length, 1728)
    }

    // MARK: - AC3.1–3.5, 3.9 triggerRows

    func test_AC3_1_threeSideBySide_topAligned_rowsCoverLeftAndRightFullWidth() {
        let rows = DockPinDisplayMap.triggerRows(displays: Fixture.threeSideBySide, anchorID: 1,
                                                 overrideDisplayID: nil)
        XCTAssertEqual(sorted(rows), [
            row(2, x: (-1728, 0), y: (1116, 1117)),
            row(3, x: (3008, 5568), y: (1439, 1440)),
        ])
    }

    func test_AC3_2_stacked_topFullyAdjacentToPinnedBottom_topHasNoRows() {
        let top = Fixture.display(1, "TOP", 0, 0, 1728, 1117)
        let bottom = Fixture.display(2, "BOTTOM", 0, 1117, 1728, 1117)
        let rows = DockPinDisplayMap.triggerRows(displays: [top, bottom], anchorID: 2, overrideDisplayID: nil)
        XCTAssertEqual(rows, [])
        XCTAssertEqual(DockPinDisplayMap.bottomFreeSpans(of: top, among: [top, bottom]), [])
    }

    func test_AC3_3_stepped_partialOverlap_topRowIsOnlyNonAdjacentPiece() {
        let top = Fixture.display(1, "TOP", 0, 0, 2000, 1000)
        let bottom = Fixture.display(2, "BOTTOM", 1000, 1000, 2000, 1000)
        let rows = DockPinDisplayMap.triggerRows(displays: [top, bottom], anchorID: 2, overrideDisplayID: nil)
        XCTAssertEqual(rows, [row(1, x: (0, 1000), y: (999, 1000))])
    }

    func test_AC3_4_adjacencyGap0_4_isAdjacent_rowExcluded() {
        let top = Fixture.display(1, "TOP", 0, 0, 1000, 1000)
        let bottom = Fixture.display(2, "BOTTOM", 0, 1000.4, 1000, 800)
        let rows = DockPinDisplayMap.triggerRows(displays: [top, bottom], anchorID: 2, overrideDisplayID: nil)
        XCTAssertEqual(rows, [])
    }

    func test_AC3_4_adjacencyGapExactly0_5_isAdjacent_inclusiveTolerance() {
        let top = Fixture.display(1, "TOP", 0, 0, 1000, 1000)
        let bottom = Fixture.display(2, "BOTTOM", 0, 1000.5, 1000, 800)
        XCTAssertEqual(DockPinDisplayMap.triggerRows(displays: [top, bottom], anchorID: 2,
                                                     overrideDisplayID: nil), [])
    }

    func test_AC3_4_adjacencyGap0_6_isNotAdjacent_fullRowKept() {
        let top = Fixture.display(1, "TOP", 0, 0, 1000, 1000)
        let bottom = Fixture.display(2, "BOTTOM", 0, 1000.6, 1000, 800)
        let rows = DockPinDisplayMap.triggerRows(displays: [top, bottom], anchorID: 2, overrideDisplayID: nil)
        XCTAssertEqual(rows, [row(1, x: (0, 1000), y: (999, 1000))])
    }

    func test_AC3_4_adjacencyNegativeGap0_4_isAdjacent() {
        // |E.minY − D.maxY| — 절댓값이므로 위로 0.4 겹쳐도 맞닿음
        let top = Fixture.display(1, "TOP", 0, 0, 1000, 1000)
        let bottom = Fixture.display(2, "BOTTOM", 0, 999.6, 1000, 800)
        XCTAssertEqual(DockPinDisplayMap.triggerRows(displays: [top, bottom], anchorID: 2,
                                                     overrideDisplayID: nil), [])
    }

    func test_AC3_4_horizontalTouchOnlyAtCorner_isNotAdjacent() {
        // x 범위 겹침이 0이면(모서리만 닿음) 맞닿음이 아니다 → 위 화면 줄 전체 유지
        let top = Fixture.display(1, "TOP", 0, 0, 1000, 1000)
        let bottom = Fixture.display(2, "BOTTOM", 1000, 1000, 1000, 800)
        let rows = DockPinDisplayMap.triggerRows(displays: [top, bottom], anchorID: 2, overrideDisplayID: nil)
        XCTAssertEqual(rows, [row(1, x: (0, 1000), y: (999, 1000))])
    }

    func test_AC3_5_singleDisplay_noRows() {
        XCTAssertEqual(DockPinDisplayMap.triggerRows(displays: [Fixture.builtIn], anchorID: 1,
                                                     overrideDisplayID: nil), [])
    }

    func test_AC3_9_overrideDisplay_rowsOfThatDisplayRemoved() {
        let rows = DockPinDisplayMap.triggerRows(displays: Fixture.threeSideBySide, anchorID: 1,
                                                 overrideDisplayID: 3)
        XCTAssertEqual(rows, [row(2, x: (-1728, 0), y: (1116, 1117))])
    }

    // MARK: - AC3.6 미러 제외 (B4)

    func test_AC3_6_activeDisplays_excludesMirrorCopy_keepsOriginalAndNormal() {
        let original = Fixture.display(1, "ORIG", 0, 0, 1728, 1117)
        let mirror = Fixture.display(2, "MIRROR", 0, 0, 1728, 1117, mirrorOf: 1)
        let normal = Fixture.display(3, "NORMAL", 1728, 0, 2560, 1440)
        let active = DockPinDisplayMap.activeDisplays([original, mirror, normal])
        XCTAssertEqual(active, [original, normal])
    }

    func test_AC3_6_layout_mirrorCopyNeverGetsTriggerRow() {
        let original = Fixture.display(1, "ORIG", 0, 0, 1728, 1117)
        let mirror = Fixture.display(2, "MIRROR", 0, 0, 1728, 1117, mirrorOf: 1)
        let normal = Fixture.display(3, "NORMAL", 1728, 0, 2560, 1440)
        let layout = DockPinDisplayMap.layout(allDisplays: [original, mirror, normal], target: .main,
                                              mainID: 1, overrideDisplayID: nil)
        XCTAssertEqual(layout?.displays.map(\.id), [1, 3])
        XCTAssertEqual(layout?.rows, [row(3, x: (1728, 4288), y: (1439, 1440))])
    }

    // MARK: - AC3.7–3.8 빈 구간과 목표점 (B5)

    func test_AC3_7_pinnedBottomFullyCovered_relocationTargetNil() {
        let anchor = Fixture.display(1, "A", 0, 0, 1000, 1000)
        let below = Fixture.display(2, "E", 0, 1000, 1000, 500)
        XCTAssertNil(DockPinDisplayMap.relocationTarget(anchor: anchor, displays: [anchor, below]))
        XCTAssertEqual(DockPinDisplayMap.bottomFreeSpans(of: anchor, among: [anchor, below]), [])
    }

    func test_AC3_7_freeSpanOf7pt_relocationTargetNil() {
        let anchor = Fixture.display(1, "A", 0, 0, 1000, 1000)
        let below = Fixture.display(2, "E", 7, 1000, 993, 500)
        XCTAssertEqual(DockPinDisplayMap.bottomFreeSpans(of: anchor, among: [anchor, below]),
                       [DockPinSpan(minX: 0, maxX: 7)])
        XCTAssertNil(DockPinDisplayMap.relocationTarget(anchor: anchor, displays: [anchor, below]))
    }

    func test_AC3_7_freeSpanOf8pt_relocationTargetIsItsCenter() {
        let anchor = Fixture.display(1, "A", 0, 0, 1000, 1000)
        let below = Fixture.display(2, "E", 8, 1000, 992, 500)
        XCTAssertEqual(DockPinDisplayMap.relocationTarget(anchor: anchor, displays: [anchor, below]),
                       CGPoint(x: 4, y: 999))
    }

    func test_AC3_7_layout_fullyCoveredPinnedBottom_layoutHasNilTarget() {
        // B5 — layout에도 nil(.noFreeEdge 근거)이 실린다
        let anchor = Fixture.display(1, "A", 0, 0, 1000, 1000)
        let below = Fixture.display(2, "E", 0, 1000, 1000, 500)
        let layout = DockPinDisplayMap.layout(allDisplays: [anchor, below], target: .main,
                                              mainID: 1, overrideDisplayID: nil)
        XCTAssertNotNil(layout)
        XCTAssertNil(layout?.relocationTarget ?? nil)
    }

    func test_AC3_8_middleAdjacent_twoFreeSpans_targetIsCenterOfLonger() {
        let anchor = Fixture.display(1, "A", 0, 0, 3008, 1692)
        let below = Fixture.display(2, "E", 1000, 1692, 1000, 800)
        XCTAssertEqual(DockPinDisplayMap.bottomFreeSpans(of: anchor, among: [anchor, below]),
                       [DockPinSpan(minX: 0, maxX: 1000), DockPinSpan(minX: 2000, maxX: 3008)])
        XCTAssertEqual(DockPinDisplayMap.relocationTarget(anchor: anchor, displays: [anchor, below]),
                       CGPoint(x: 2504, y: 1691))
    }

    func test_R3_6_equalLengthSpans_tieBreaksToSmallerX() {
        let anchor = Fixture.display(1, "A", 0, 0, 3000, 1000)
        let below = Fixture.display(2, "E", 1000, 1000, 1000, 800)
        XCTAssertEqual(DockPinDisplayMap.relocationTarget(anchor: anchor, displays: [anchor, below]),
                       CGPoint(x: 500, y: 999))
    }

    func test_R3_6_noDisplayBelow_wholeBottomIsFree_targetIsBottomCenter() {
        XCTAssertEqual(DockPinDisplayMap.bottomFreeSpans(of: Fixture.builtIn, among: [Fixture.builtIn]),
                       [DockPinSpan(minX: 0, maxX: 1728)])
        XCTAssertEqual(DockPinDisplayMap.relocationTarget(anchor: Fixture.builtIn, displays: [Fixture.builtIn]),
                       CGPoint(x: 864, y: 1116))
    }

    // MARK: - AC3.10–3.11 이 Mac 배치 (F1: 내장 + Sidecar)

    func test_AC3_10_thisMacLayout_mainTarget_onlySidecarRow_targetBottomCenterOfBuiltIn() {
        let layout = DockPinDisplayMap.layout(allDisplays: [Fixture.builtIn, Fixture.sidecar],
                                              target: .main, mainID: 1, overrideDisplayID: nil)
        XCTAssertEqual(layout?.anchor, DockPinAnchor(display: Fixture.builtIn, usingFallbackAnchor: false))
        XCTAssertEqual(layout?.mainID, 1)
        XCTAssertEqual(layout?.displays, [Fixture.builtIn, Fixture.sidecar])
        XCTAssertEqual(layout?.rows, [row(12, x: (1728, 2877), y: (801, 802))])
        XCTAssertEqual(layout?.relocationTarget ?? nil, CGPoint(x: 864, y: 1116))
    }

    func test_AC3_11_thisMacLayout_sidecarTarget_onlyBuiltInRow_targetBottomCenterOfSidecar() {
        let layout = DockPinDisplayMap.layout(allDisplays: [Fixture.builtIn, Fixture.sidecar],
                                              target: .display(uuid: Fixture.sidecarUUID), mainID: 1,
                                              overrideDisplayID: nil)
        XCTAssertEqual(layout?.anchor, DockPinAnchor(display: Fixture.sidecar, usingFallbackAnchor: false))
        XCTAssertEqual(layout?.rows, [row(1, x: (0, 1728), y: (1116, 1117))])
        XCTAssertEqual(layout?.relocationTarget ?? nil, CGPoint(x: 2302.5, y: 801))
    }

    func test_AC3_10_thisMacLayout_triggerRowsAndTargetDirectly() {
        XCTAssertEqual(DockPinDisplayMap.triggerRows(displays: [Fixture.builtIn, Fixture.sidecar],
                                                     anchorID: 1, overrideDisplayID: nil),
                       [row(12, x: (1728, 2877), y: (801, 802))])
        XCTAssertEqual(DockPinDisplayMap.relocationTarget(anchor: Fixture.builtIn,
                                                          displays: [Fixture.builtIn, Fixture.sidecar]),
                       CGPoint(x: 864, y: 1116))
    }

    func test_AC3_11_thisMacLayout_sidecarAnchor_triggerRowsAndTargetDirectly() {
        XCTAssertEqual(DockPinDisplayMap.triggerRows(displays: [Fixture.builtIn, Fixture.sidecar],
                                                     anchorID: 12, overrideDisplayID: nil),
                       [row(1, x: (0, 1728), y: (1116, 1117))])
        XCTAssertEqual(DockPinDisplayMap.relocationTarget(anchor: Fixture.sidecar,
                                                          displays: [Fixture.builtIn, Fixture.sidecar]),
                       CGPoint(x: 2302.5, y: 801))
    }

    func test_AC3_10_thisMacLayout_triggerRowContainsSidecarBottomEdgeOnly() {
        // 실제 판정 지점: Sidecar 맨 아래 줄은 포함, 내장 화면 맨 아래 줄은 고정 화면이라 제외
        let rows = DockPinDisplayMap.triggerRows(displays: [Fixture.builtIn, Fixture.sidecar],
                                                 anchorID: 1, overrideDisplayID: nil)
        XCTAssertTrue(rows.contains { $0.contains(CGPoint(x: 2000, y: 801.5)) })
        XCTAssertFalse(rows.contains { $0.contains(CGPoint(x: 864, y: 1116.5)) })
    }

    // MARK: - layout 기타 (R2.4 대신 고정, 0대, R3.7 결정성, R3.5 오버라이드)

    func test_AC2_3_layout_disconnectedTarget_fallsBackToMain_flagCarried() {
        let layout = DockPinDisplayMap.layout(allDisplays: [Fixture.builtIn, Fixture.sidecar],
                                              target: .display(uuid: "GONE"), mainID: 1, overrideDisplayID: nil)
        XCTAssertEqual(layout?.anchor, DockPinAnchor(display: Fixture.builtIn, usingFallbackAnchor: true))
        XCTAssertEqual(layout?.rows, [row(12, x: (1728, 2877), y: (801, 802))])
    }

    func test_layout_noActiveDisplays_returnsNil() {
        XCTAssertNil(DockPinDisplayMap.layout(allDisplays: [], target: .main, mainID: 1, overrideDisplayID: nil))
        XCTAssertNotNil(DockPinDisplayMap.layout(allDisplays: [Fixture.builtIn], target: .main, mainID: 1,
                                                 overrideDisplayID: nil))
    }

    func test_R3_7_layout_sameInputs_equalResults() {
        let a = DockPinDisplayMap.layout(allDisplays: Fixture.threeSideBySide, target: .main, mainID: 1,
                                         overrideDisplayID: nil)
        let b = DockPinDisplayMap.layout(allDisplays: Fixture.threeSideBySide, target: .main, mainID: 1,
                                         overrideDisplayID: nil)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }

    func test_AC3_9_layout_overrideDisplay_rowsExcludeIt() {
        let layout = DockPinDisplayMap.layout(allDisplays: [Fixture.builtIn, Fixture.sidecar], target: .main,
                                              mainID: 1, overrideDisplayID: 12)
        XCTAssertEqual(layout?.rows, [])
        XCTAssertNotNil(layout)
    }

    // MARK: - AC4.5 DockPinOrientation.parse

    func test_AC4_5_orientationParse_nilBottomLeftRightUnknown() {
        XCTAssertEqual(DockPinOrientation.parse(nil), .bottom)
        XCTAssertEqual(DockPinOrientation.parse("bottom"), .bottom)
        XCTAssertEqual(DockPinOrientation.parse("left"), .left)
        XCTAssertEqual(DockPinOrientation.parse("right"), .right)
        XCTAssertEqual(DockPinOrientation.parse("weird"), .bottom)
    }

    func test_AC4_5_orientationParse_nonStringValue_isBottom() {
        XCTAssertEqual(DockPinOrientation.parse(5), .bottom)
        XCTAssertEqual(DockPinOrientation.parse("left" as NSString), .left)
    }

    // MARK: - AC8.9 순수부 restorePoint (리뷰 v2 N10)

    func test_AC8_9_restorePoint_savedOnActiveDisplay_returnsSaved() {
        let saved = CGPoint(x: 100, y: 200)
        XCTAssertEqual(DockPinDisplayMap.restorePoint(saved: saved, allDisplays: [Fixture.builtIn, Fixture.sidecar],
                                                      target: .main, mainID: 1), saved)
    }

    func test_AC8_9_restorePoint_savedOnStillConnectedSidecar_returnsSaved() {
        let saved = CGPoint(x: 2000, y: 500)
        XCTAssertEqual(DockPinDisplayMap.restorePoint(saved: saved, allDisplays: [Fixture.builtIn, Fixture.sidecar],
                                                      target: .main, mainID: 1), saved)
    }

    func test_AC8_9_restorePoint_savedOnDetachedSidecar_returnsAnchorCenter() {
        // Sidecar가 분리된 뒤 다시 읽은 목록 = 내장 1대 → 내장 화면 가운데 (864, 558.5)
        XCTAssertEqual(DockPinDisplayMap.restorePoint(saved: CGPoint(x: 2000, y: 500),
                                                      allDisplays: [Fixture.builtIn],
                                                      target: .main, mainID: 1),
                       CGPoint(x: 864, y: 558.5))
    }

    func test_AC8_9_restorePoint_detachedTargetDisplay_reresolvesAnchorToMainCenter() {
        // 고정 대상이 Sidecar였는데 분리됨 → R2 규칙으로 다시 정한 고정 화면(주 화면) 가운데
        XCTAssertEqual(DockPinDisplayMap.restorePoint(saved: CGPoint(x: 2000, y: 500),
                                                      allDisplays: [Fixture.builtIn],
                                                      target: .display(uuid: Fixture.sidecarUUID), mainID: 1),
                       CGPoint(x: 864, y: 558.5))
    }

    func test_AC8_9_restorePoint_savedOnRightEdgeOfBuiltIn_isOutside_halfOpen() {
        // x = 1728은 내장 화면 bounds 반열린 구간 밖 → Sidecar가 없으면 가운데로
        XCTAssertEqual(DockPinDisplayMap.restorePoint(saved: CGPoint(x: 1728, y: 500),
                                                      allDisplays: [Fixture.builtIn],
                                                      target: .main, mainID: 1),
                       CGPoint(x: 864, y: 558.5))
    }

    func test_AC8_9_restorePoint_savedOnMirrorCopyOnly_isNotActive_returnsAnchorCenter() {
        // 미러 사본은 활성 디스플레이가 아니다(R3.1) → 그 위의 점은 "어디에도 없음"
        let mirror = Fixture.display(2, "MIRROR", 1728, 0, 1149, 802, mirrorOf: 1)
        XCTAssertEqual(DockPinDisplayMap.restorePoint(saved: CGPoint(x: 2000, y: 500),
                                                      allDisplays: [Fixture.builtIn, mirror],
                                                      target: .main, mainID: 1),
                       CGPoint(x: 864, y: 558.5))
    }

    func test_AC8_9_restorePoint_noActiveDisplays_returnsNil() {
        XCTAssertNil(DockPinDisplayMap.restorePoint(saved: CGPoint(x: 100, y: 100), allDisplays: [],
                                                    target: .main, mainID: 1))
    }
}
