import XCTest
import CoreGraphics
@testable import SoAgentBar

// MARK: - DockPinPolicyTests
//
// SPEC-004 커밋 4 — 순수 계층(DockPinPolicy.swift + DockPinModels의 단계 플래그) 단위 테스트.
// 커버 AC: AC4.1, AC4.7, AC4.10(d), AC5.11(일정 함수), AC7.1–7.4, AC8.1, AC8.6(일정 함수), AC8.10,
//          AC8.11(a), AC10.4, AC11.1–11.5, AC12.3, S5(설계 추가) + R2.5/S2 선택지 제목, S6 고정 문구.
//
// RED 확인 방법: 이 파일은 컴파일된다(so-tester가 arch §2.5 시그니처의 고정값 스텁을 넣었다).
// 스텁은 일부러 틀린 값(켜짐을 뒤집은 activation, 전체 타이머 집합, 뒤집은 구성 변경·잠금·테스트 호스트 판정,
// 활성이면 .skip(.inactive)인 relocationDecision, 일정 -1, 빈 문구, 모두 켜진 버튼 등)을 돌려주므로
// 아래 테스트는 전부 실패하는 것이 정상이다. isRelocating/isDriving(DockPinModels)도 커밋 1부터 false 스텁이다.
// 기대값이 스텁 값과 겹치는 단정(false, nil 등)은 같은 테스트 안에 짝 단정(양성 결과)을 둔다.
//
// 설정 저장소(standard 포함)는 쓰지 않는다 — 순수 함수만 부른다.

@MainActor
final class DockPinPolicyTests: XCTestCase {

    // MARK: - 고정 배치 · 입력

    private enum Fixture {
        static let builtInID: CGDirectDisplayID = 1
        static let sidecarID: CGDirectDisplayID = 12
        static let otherID: CGDirectDisplayID = 7

        /// F1 — 이 Mac 내장 화면 (주 화면), CG bounds (0,0,1728,1117)
        static let builtIn = DockPinDisplay(id: builtInID, uuid: "BUILTIN-UUID",
                                            bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                            mirrorOf: nil, name: "Color LCD")
        /// F1 — 이 Mac Sidecar, CG bounds (1728,0,1149,802)
        static let sidecar = DockPinDisplay(id: sidecarID, uuid: "BAB59A29-3097-4311-993B-57A74473F53E",
                                            bounds: CGRect(x: 1728, y: 0, width: 1149, height: 802),
                                            mirrorOf: nil, name: "Sidecar Display (AirPlay)")
        static var thisMac: [DockPinDisplay] { [builtIn, sidecar] }

        static let sampleName = "Sidecar Display (AirPlay)"

        /// F14 — 이 Mac 현재 입력(권한 있음): 기대값 .active
        static var activeInputs: DockPinActivationInputs {
            DockPinActivationInputs(enabled: true, hasPermission: true, activeDisplayCount: 2,
                                    separateSpaces: true, orientation: .bottom)
        }
    }

    // MARK: - 문구 표 (R11.2 = 디자인 계약 State 표)

    private struct StatusRow {
        let status: DockPinStatus
        let ko: String
        let en: String
        let tone: DockPinTone
        let moveBackEnabled: Bool
        /// S5 — 대체 고정 보조 줄을 붙일 수 있는 상태인가
        let allowsFallbackNote: Bool
    }

    /// R11.2 표의 14행. `.inactive(.dockNotBottom)`은 왼쪽·오른쪽 두 값으로 나눠 15개.
    private static func statusRows(name: String = Fixture.sampleName, attempts: Int = 4) -> [StatusRow] {
        [
            StatusRow(status: .off, ko: "꺼짐", en: "Off",
                      tone: .gray, moveBackEnabled: false, allowsFallbackNote: false),
            StatusRow(status: .needsPermission,
                      ko: "손쉬운 사용 권한이 필요해요", en: "Accessibility permission required",
                      tone: .orange, moveBackEnabled: false, allowsFallbackNote: false),
            StatusRow(status: .inactive(.singleDisplay),
                      ko: "대기 중 — 모니터가 하나뿐이에요. 연결하면 자동으로 켜져요",
                      en: "Waiting — only one display. Turns on automatically when you connect another",
                      tone: .gray, moveBackEnabled: false, allowsFallbackNote: false),
            StatusRow(status: .inactive(.spacesOff),
                      ko: "대기 중 — '디스플레이마다 별도의 Spaces'가 꺼져 있어요",
                      en: "Waiting — \"Displays have separate Spaces\" is off",
                      tone: .gray, moveBackEnabled: false, allowsFallbackNote: false),
            StatusRow(status: .inactive(.dockNotBottom(.left)),
                      ko: "대기 중 — Dock이 왼쪽에 있어요(아래쪽일 때만 동작)",
                      en: "Waiting — Dock is on the left (works only when it's at the bottom)",
                      tone: .gray, moveBackEnabled: false, allowsFallbackNote: false),
            StatusRow(status: .inactive(.dockNotBottom(.right)),
                      ko: "대기 중 — Dock이 오른쪽에 있어요(아래쪽일 때만 동작)",
                      en: "Waiting — Dock is on the right (works only when it's at the bottom)",
                      tone: .gray, moveBackEnabled: false, allowsFallbackNote: false),
            StatusRow(status: .tapFailed(attempt: 2),
                      ko: "오류 — 마우스 이벤트 감시를 시작하지 못했어요. 다시 시도 중… 계속되면 앱을 다시 시작해 보세요",
                      en: "Error — couldn't start watching pointer events. Retrying… Restart the app if this persists",
                      tone: .red, moveBackEnabled: false, allowsFallbackNote: true),
            StatusRow(status: .checking,
                      ko: "Dock 위치 확인 중…", en: "Checking where the Dock is…",
                      tone: .gray, moveBackEnabled: false, allowsFallbackNote: true),
            StatusRow(status: .dockNotFound,
                      ko: "Dock 위치를 확인할 수 없어요", en: "Can't find where the Dock is",
                      tone: .orange, moveBackEnabled: true, allowsFallbackNote: true),
            StatusRow(status: .noFreeEdge(displayName: name),
                      ko: "\(name) 아래쪽이 다른 모니터에 맞닿아 있어 Dock을 둘 수 없어요",
                      en: "The bottom of \(name) touches another display, so the Dock can't be placed there",
                      tone: .orange, moveBackEnabled: false, allowsFallbackNote: true),
            StatusRow(status: .pinned(displayName: name),
                      ko: "Dock이 \(name)에 고정됨", en: "Dock pinned to \(name)",
                      tone: .green, moveBackEnabled: false, allowsFallbackNote: true),
            StatusRow(status: .waiting(.userActive, displayName: name),
                      ko: "Dock을 \(name)(으)로 되돌릴 준비 중…", en: "Waiting to move the Dock back to \(name)…",
                      tone: .blue, moveBackEnabled: true, allowsFallbackNote: true),
            StatusRow(status: .relocating(displayName: name),
                      ko: "Dock을 \(name)(으)로 되돌리는 중…", en: "Moving the Dock back to \(name)…",
                      tone: .blue, moveBackEnabled: false, allowsFallbackNote: true),
            StatusRow(status: .movedByUser(displayName: name),
                      ko: "Option으로 \(name)에 옮겼어요 — '지금 되돌리기'로 돌아갈 수 있어요",
                      en: "Moved to \(name) with Option — use \"Move Dock back now\" to return",
                      tone: .blue, moveBackEnabled: true, allowsFallbackNote: true),
            StatusRow(status: .failed(attempts: attempts),
                      ko: "Dock을 되돌리지 못했어요(\(attempts)회 시도)", en: "Couldn't move the Dock back (\(attempts) tries)",
                      tone: .red, moveBackEnabled: true, allowsFallbackNote: true),
        ]
    }

    private static let fallbackNoteKo = "선택한 모니터가 연결돼 있지 않아 주 모니터를 쓰는 중"
    private static let fallbackNoteEn = "Selected display isn't connected — using the main display"

    private func present(_ status: DockPinStatus, fallback: Bool = false,
                         _ language: AppLanguage) -> DockPinPresentation {
        DockPinPolicy.presentation(for: status, usingFallbackAnchor: fallback, language: language)
    }

    // MARK: - AC4.1 activation (R4.1 표 6행 + 순위)

    func test_AC4_1_activation_disabled_isOff() {
        var inputs = Fixture.activeInputs
        inputs.enabled = false
        XCTAssertEqual(DockPinPolicy.activation(inputs), .inactive(.off))
    }

    func test_AC4_1_activation_noPermission_isNeedsPermission() {
        var inputs = Fixture.activeInputs
        inputs.hasPermission = false
        XCTAssertEqual(DockPinPolicy.activation(inputs), .inactive(.needsPermission))
    }

    func test_AC4_1_activation_fewerThanTwoDisplays_isSingleDisplay() {
        var inputs = Fixture.activeInputs
        inputs.activeDisplayCount = 1
        XCTAssertEqual(DockPinPolicy.activation(inputs), .inactive(.singleDisplay))
        inputs.activeDisplayCount = 0
        XCTAssertEqual(DockPinPolicy.activation(inputs), .inactive(.singleDisplay), "0대도 2대 미만이다")
    }

    func test_AC4_1_activation_separateSpacesOff_isSpacesOff() {
        var inputs = Fixture.activeInputs
        inputs.separateSpaces = false
        XCTAssertEqual(DockPinPolicy.activation(inputs), .inactive(.spacesOff))
    }

    func test_AC4_1_activation_dockOnLeftOrRight_isDockNotBottomWithSide() {
        var inputs = Fixture.activeInputs
        inputs.orientation = .left
        XCTAssertEqual(DockPinPolicy.activation(inputs), .inactive(.dockNotBottom(.left)))
        inputs.orientation = .right
        XCTAssertEqual(DockPinPolicy.activation(inputs), .inactive(.dockNotBottom(.right)))
    }

    func test_AC4_1_activation_thisMacInputsWithPermission_isActive() {
        // F14: 화면 2대, 별도 Spaces 켜짐, Dock 아래쪽, 권한 있음 → .active
        XCTAssertEqual(DockPinPolicy.activation(Fixture.activeInputs), .active)
        var three = Fixture.activeInputs
        three.activeDisplayCount = 3
        XCTAssertEqual(DockPinPolicy.activation(three), .active)
    }

    func test_AC4_1_activation_noPermissionAndOneDisplay_needsPermissionWins() {
        var inputs = Fixture.activeInputs
        inputs.hasPermission = false
        inputs.activeDisplayCount = 1
        XCTAssertEqual(DockPinPolicy.activation(inputs), .inactive(.needsPermission))
    }

    func test_AC4_1_activation_disabledWinsOverEveryOtherReason() {
        let inputs = DockPinActivationInputs(enabled: false, hasPermission: false, activeDisplayCount: 1,
                                             separateSpaces: false, orientation: .left)
        XCTAssertEqual(DockPinPolicy.activation(inputs), .inactive(.off))
    }

    func test_AC4_1_activation_rankOrder_singleDisplayThenSpacesOffThenDockSide() {
        var inputs = Fixture.activeInputs
        inputs.activeDisplayCount = 1
        inputs.separateSpaces = false
        inputs.orientation = .right
        XCTAssertEqual(DockPinPolicy.activation(inputs), .inactive(.singleDisplay), "순위 3 > 4 > 5")
        inputs.activeDisplayCount = 2
        XCTAssertEqual(DockPinPolicy.activation(inputs), .inactive(.spacesOff), "순위 4 > 5")
    }

    // MARK: - AC4.7 requiredTimers (R4.4 표 6행 + N12 예외)

    func test_AC4_7_requiredTimers_off_none() {
        XCTAssertEqual(DockPinPolicy.requiredTimers(activation: .inactive(.off), tapState: .none), [])
    }

    func test_AC4_7_requiredTimers_needsPermission_onlyPermissionPoll() {
        XCTAssertEqual(DockPinPolicy.requiredTimers(activation: .inactive(.needsPermission), tapState: .none),
                       [.permissionPoll])
    }

    func test_AC4_7_requiredTimers_singleDisplay_noneIncludingPermissionPoll() {
        XCTAssertEqual(DockPinPolicy.requiredTimers(activation: .inactive(.singleDisplay), tapState: .none), [])
    }

    func test_AC4_7_requiredTimers_spacesOffOrDockNotBottom_onlyPrefsPoll() {
        XCTAssertEqual(DockPinPolicy.requiredTimers(activation: .inactive(.spacesOff), tapState: .none),
                       [.prefsPoll])
        XCTAssertEqual(DockPinPolicy.requiredTimers(activation: .inactive(.dockNotBottom(.left)), tapState: .none),
                       [.prefsPoll])
        XCTAssertEqual(DockPinPolicy.requiredTimers(activation: .inactive(.dockNotBottom(.right)), tapState: .none),
                       [.prefsPoll])
    }

    func test_AC4_7_requiredTimers_activeTapRunning_permissionDockPollAndWatchdog() {
        XCTAssertEqual(DockPinPolicy.requiredTimers(activation: .active, tapState: .running),
                       [.permissionPoll, .dockPoll, .tapWatchdog])
    }

    func test_AC4_7_requiredTimers_activeTapRetrying_permissionPollAndTapRetry() {
        XCTAssertEqual(DockPinPolicy.requiredTimers(activation: .active, tapState: .retrying(attempt: 1)),
                       [.permissionPoll, .tapRetry])
        XCTAssertEqual(DockPinPolicy.requiredTimers(activation: .active, tapState: .retrying(attempt: 6)),
                       [.permissionPoll, .tapRetry], "시도 번호와 무관")
    }

    func test_AC4_7_requiredTimers_activeTapNone_definedAsPermissionPollOnly() {
        // arch §2.5: 매니저가 만들지 않는 조합이지만 전 함수로 정의한다
        XCTAssertEqual(DockPinPolicy.requiredTimers(activation: .active, tapState: .none), [.permissionPoll])
    }

    func test_AC4_7_requiredTimers_noPermissionAndOneDisplay_exactlyPermissionPoll() {
        // R4.4 예외(N12): activation 결과(.needsPermission)를 그대로 넘긴다
        var inputs = Fixture.activeInputs
        inputs.hasPermission = false
        inputs.activeDisplayCount = 1
        let activation = DockPinPolicy.activation(inputs)
        XCTAssertEqual(activation, .inactive(.needsPermission))
        XCTAssertEqual(DockPinPolicy.requiredTimers(activation: activation, tapState: .none), [.permissionPoll])
    }

    func test_AC4_7_requiredTimers_inactiveIgnoresTapState() {
        // 비활성 행은 "탭 없음"이다 — tapState가 무엇이든 활성화 행만 따른다
        XCTAssertEqual(DockPinPolicy.requiredTimers(activation: .inactive(.singleDisplay), tapState: .running), [])
        XCTAssertEqual(DockPinPolicy.requiredTimers(activation: .inactive(.needsPermission),
                                                    tapState: .retrying(attempt: 2)), [.permissionPoll])
    }

    // MARK: - AC4.10(d) isDisplayConfigChange (R4.8)

    private func fingerprint(_ displays: [DockPinDisplay],
                             inputs: DockPinActivationInputs = Fixture.activeInputs) -> DockPinConfigFingerprint {
        DockPinConfigFingerprint(
            baseLayout: DockPinDisplayMap.layout(allDisplays: displays, target: .main,
                                                 mainID: Fixture.builtInID, overrideDisplayID: nil),
            inputs: inputs)
    }

    func test_AC4_10d_isDisplayConfigChange_sameMapAndInputs_false() {
        let previous = fingerprint(Fixture.thisMac)
        let current = fingerprint(Fixture.thisMac)
        XCTAssertFalse(DockPinPolicy.isDisplayConfigChange(previous: previous, current: current))
        // 짝 단정: 같은 비교에서 직전 값이 없으면 구성 변경이다
        XCTAssertTrue(DockPinPolicy.isDisplayConfigChange(previous: nil, current: current))
    }

    func test_AC4_10d_isDisplayConfigChange_onlyOneDisplayBoundsDiffer_true() {
        let movedSidecar = DockPinDisplay(id: Fixture.sidecarID, uuid: Fixture.sidecar.uuid,
                                          bounds: CGRect(x: 1728, y: 100, width: 1149, height: 802),
                                          mirrorOf: nil, name: Fixture.sidecar.name)
        XCTAssertTrue(DockPinPolicy.isDisplayConfigChange(previous: fingerprint(Fixture.thisMac),
                                                          current: fingerprint([Fixture.builtIn, movedSidecar])))
    }

    func test_AC4_10d_isDisplayConfigChange_noPreviousResult_true() {
        XCTAssertTrue(DockPinPolicy.isDisplayConfigChange(previous: nil, current: fingerprint(Fixture.thisMac)))
    }

    func test_AC4_10d_isDisplayConfigChange_onlyActivationInputsDiffer_true() {
        var spacesOff = Fixture.activeInputs
        spacesOff.separateSpaces = false
        XCTAssertTrue(DockPinPolicy.isDisplayConfigChange(previous: fingerprint(Fixture.thisMac),
                                                          current: fingerprint(Fixture.thisMac, inputs: spacesOff)))
    }

    func test_AC4_10d_isDisplayConfigChange_displayRemoved_true() {
        var oneDisplay = Fixture.activeInputs
        oneDisplay.activeDisplayCount = 1
        XCTAssertTrue(DockPinPolicy.isDisplayConfigChange(previous: fingerprint(Fixture.thisMac),
                                                          current: fingerprint([Fixture.builtIn], inputs: oneDisplay)))
    }

    // MARK: - AC5.11 일정 함수 tapRetryDelay (R5.9)

    func test_AC5_11_tapRetryDelay_1_2_5_10_thenEvery30() {
        let delays = (1...7).map { DockPinPolicy.tapRetryDelay(attempt: $0) }
        XCTAssertEqual(delays, [1, 2, 5, 10, 30, 30, 30])
        XCTAssertEqual(DockPinPolicy.tapRetryDelay(attempt: 100), 30)
    }

    // MARK: - AC7.1–7.4 isUserOverride (R7.4)

    func test_AC7_1_isUserOverride_B1Regression_optionPassAfterLastConfirm_withinTenSeconds_true() {
        // 참고 구현(3초 창)으로는 false가 나오는 입력
        XCTAssertTrue(DockPinPolicy.isUserOverride(dockDisplay: Fixture.sidecarID, anchor: Fixture.builtInID,
                                                   optionPasses: [Fixture.sidecarID: 100.0],
                                                   lastConfirmedOnAnchorAt: 98.0, now: 103.5))
    }

    func test_AC7_2_isUserOverride_optionPassOnOtherDisplay_false() {
        XCTAssertFalse(DockPinPolicy.isUserOverride(dockDisplay: Fixture.sidecarID, anchor: Fixture.builtInID,
                                                    optionPasses: [Fixture.otherID: 100.0],
                                                    lastConfirmedOnAnchorAt: 98.0, now: 103.5))
        // 짝 단정: 같은 입력에서 Dock이 있는 화면의 통과면 true
        XCTAssertTrue(DockPinPolicy.isUserOverride(dockDisplay: Fixture.sidecarID, anchor: Fixture.builtInID,
                                                   optionPasses: [Fixture.otherID: 100.0, Fixture.sidecarID: 100.0],
                                                   lastConfirmedOnAnchorAt: 98.0, now: 103.5))
    }

    func test_AC7_3_isUserOverride_confirmedOnAnchorAfterOptionPass_false() {
        XCTAssertFalse(DockPinPolicy.isUserOverride(dockDisplay: Fixture.sidecarID, anchor: Fixture.builtInID,
                                                    optionPasses: [Fixture.sidecarID: 100.0],
                                                    lastConfirmedOnAnchorAt: 101.0, now: 105.0))
        // 짝 단정: 확인이 통과보다 앞이면 true
        XCTAssertTrue(DockPinPolicy.isUserOverride(dockDisplay: Fixture.sidecarID, anchor: Fixture.builtInID,
                                                   optionPasses: [Fixture.sidecarID: 100.0],
                                                   lastConfirmedOnAnchorAt: 99.0, now: 105.0))
    }

    func test_AC7_4_isUserOverride_windowBoundary_10_0_true_10_01_false() {
        XCTAssertTrue(DockPinPolicy.isUserOverride(dockDisplay: Fixture.sidecarID, anchor: Fixture.builtInID,
                                                   optionPasses: [Fixture.sidecarID: 100.0],
                                                   lastConfirmedOnAnchorAt: 98.0, now: 110.0))
        XCTAssertFalse(DockPinPolicy.isUserOverride(dockDisplay: Fixture.sidecarID, anchor: Fixture.builtInID,
                                                    optionPasses: [Fixture.sidecarID: 100.0],
                                                    lastConfirmedOnAnchorAt: 98.0, now: 110.01))
    }

    func test_AC7_isUserOverride_neverConfirmedOnAnchor_treatsAsMinusInfinity_true() {
        XCTAssertTrue(DockPinPolicy.isUserOverride(dockDisplay: Fixture.sidecarID, anchor: Fixture.builtInID,
                                                   optionPasses: [Fixture.sidecarID: 100.0],
                                                   lastConfirmedOnAnchorAt: nil, now: 101.0))
    }

    func test_AC7_isUserOverride_dockOnAnchorOrNoPass_false() {
        // Dock이 고정 화면에 있으면 오버라이드가 아니다
        XCTAssertFalse(DockPinPolicy.isUserOverride(dockDisplay: Fixture.builtInID, anchor: Fixture.builtInID,
                                                    optionPasses: [Fixture.builtInID: 100.0],
                                                    lastConfirmedOnAnchorAt: nil, now: 101.0))
        // Option 통과 기록이 없으면 오버라이드가 아니다
        XCTAssertFalse(DockPinPolicy.isUserOverride(dockDisplay: Fixture.sidecarID, anchor: Fixture.builtInID,
                                                    optionPasses: [:],
                                                    lastConfirmedOnAnchorAt: nil, now: 101.0))
        // 짝 단정
        XCTAssertTrue(DockPinPolicy.isUserOverride(dockDisplay: Fixture.sidecarID, anchor: Fixture.builtInID,
                                                   optionPasses: [Fixture.sidecarID: 100.0],
                                                   lastConfirmedOnAnchorAt: nil, now: 101.0))
    }

    func test_AC7_isUserOverride_passAtSameInstantAsConfirm_false() {
        // t > lastConfirmed 이어야 한다(같으면 false)
        XCTAssertFalse(DockPinPolicy.isUserOverride(dockDisplay: Fixture.sidecarID, anchor: Fixture.builtInID,
                                                    optionPasses: [Fixture.sidecarID: 100.0],
                                                    lastConfirmedOnAnchorAt: 100.0, now: 101.0))
        XCTAssertTrue(DockPinPolicy.isUserOverride(dockDisplay: Fixture.sidecarID, anchor: Fixture.builtInID,
                                                   optionPasses: [Fixture.sidecarID: 100.0],
                                                   lastConfirmedOnAnchorAt: 99.99, now: 101.0))
    }

    func test_AC7_isUserOverride_customWindowParameterIsHonored() {
        XCTAssertFalse(DockPinPolicy.isUserOverride(dockDisplay: Fixture.sidecarID, anchor: Fixture.builtInID,
                                                    optionPasses: [Fixture.sidecarID: 100.0],
                                                    lastConfirmedOnAnchorAt: nil, now: 104.0, window: 3))
        XCTAssertTrue(DockPinPolicy.isUserOverride(dockDisplay: Fixture.sidecarID, anchor: Fixture.builtInID,
                                                   optionPasses: [Fixture.sidecarID: 100.0],
                                                   lastConfirmedOnAnchorAt: nil, now: 103.0, window: 3))
    }

    // MARK: - AC8.1 / AC8.11(a) relocationDecision (R8.2 표)

    /// 모든 행을 통과해 .go가 나오는 기준 입력: 활성, Dock은 Sidecar, 고정 화면은 내장.
    private func goInputs() -> DockPinRelocationInputs {
        DockPinRelocationInputs(activation: .active,
                                placement: .display(Fixture.sidecarID),
                                anchorID: Fixture.builtInID,
                                phase: .idle,
                                retryScheduled: false,
                                trigger: .poll,
                                isUserOverride: false,
                                hasRelocationTarget: true,
                                session: DockPinSessionState(),
                                anyButtonDown: false,
                                secondsSinceInput: 5)
    }

    private func decide(_ edit: (inout DockPinRelocationInputs) -> Void) -> DockPinRelocationDecision {
        var inputs = goInputs()
        edit(&inputs)
        return DockPinPolicy.relocationDecision(inputs)
    }

    func test_AC8_1_relocationDecision_allConditionsMet_go() {
        XCTAssertEqual(DockPinPolicy.relocationDecision(goInputs()), .go)
    }

    func test_AC8_1_relocationDecision_notActive_skipInactive() {
        XCTAssertEqual(decide { $0.activation = .inactive(.singleDisplay) }, .skip(.inactive))
        XCTAssertEqual(decide { $0.activation = .inactive(.off) }, .skip(.inactive))
    }

    func test_AC8_1_relocationDecision_placementNotYetLocated_skipDockNotFound() {
        XCTAssertEqual(decide { $0.placement = nil }, .skip(.dockNotFound))
    }

    func test_AC8_1_relocationDecision_placementUnknown_skipDockNotFound() {
        XCTAssertEqual(decide { $0.placement = .unknown }, .skip(.dockNotFound))
    }

    func test_AC8_1_relocationDecision_dockOnAnchor_skipAlreadyPinned() {
        XCTAssertEqual(decide { $0.placement = .display(Fixture.builtInID) }, .skip(.alreadyPinned))
    }

    func test_AC8_1_relocationDecision_userOverride_skipUserOverride() {
        XCTAssertEqual(decide { $0.isUserOverride = true }, .skip(.userOverride))
    }

    func test_AC8_1_relocationDecision_noRelocationTarget_skipNoFreeEdge() {
        XCTAssertEqual(decide { $0.hasRelocationTarget = false }, .skip(.noFreeEdge))
    }

    func test_AC8_1_relocationDecision_asleep_waitAsleep() {
        XCTAssertEqual(decide { $0.session.asleep = true }, .wait(.asleep))
    }

    func test_AC8_1_relocationDecision_screenLocked_waitLocked() {
        XCTAssertEqual(decide { $0.session.locked = true }, .wait(.locked))
    }

    func test_AC8_1_relocationDecision_notOnConsole_waitNotOnConsole() {
        XCTAssertEqual(decide { $0.session.onConsole = false }, .wait(.notOnConsole))
    }

    func test_AC8_1_relocationDecision_buttonDown_waitButtonDown() {
        XCTAssertEqual(decide { $0.anyButtonDown = true }, .wait(.buttonDown))
    }

    func test_AC8_1_relocationDecision_idleBoundary_0_49_waitUserActive_0_5_go() {
        XCTAssertEqual(decide { $0.secondsSinceInput = 0.49 }, .wait(.userActive))
        XCTAssertEqual(decide { $0.secondsSinceInput = 0.5 }, .go)
        XCTAssertEqual(decide { $0.secondsSinceInput = 0 }, .wait(.userActive))
    }

    func test_AC8_1_relocationDecision_waitingPhaseDoesNotBlock_go() {
        // waiting(r)은 재판정 대상이다(R8.2 .wait → 0.5초 뒤 다시 판정)
        XCTAssertEqual(decide { $0.phase = .waiting(.userActive) }, .go)
    }

    func test_AC8_1_relocationDecision_rowOrder_firstMatchingRowWins() {
        // 1행 > 2행: 비활성이면 위치가 없어도 .inactive
        XCTAssertEqual(decide { $0.activation = .inactive(.needsPermission); $0.placement = nil }, .skip(.inactive))
        // 2행 > 3행 이하: 위치 미확인이면 오버라이드·목표점 없음보다 먼저
        XCTAssertEqual(decide { $0.placement = .unknown; $0.isUserOverride = true; $0.hasRelocationTarget = false },
                       .skip(.dockNotFound))
        // 3행 > failed: Dock이 고정 화면이면 failed여도 .alreadyPinned
        XCTAssertEqual(decide { $0.placement = .display(Fixture.builtInID); $0.phase = .failed(attempts: 4) },
                       .skip(.alreadyPinned))
        // failedUntilEvent > retryScheduled
        XCTAssertEqual(decide { $0.phase = .failed(attempts: 4); $0.retryScheduled = true }, .skip(.failedUntilEvent))
        // retryScheduled > userOverride
        XCTAssertEqual(decide { $0.retryScheduled = true; $0.isUserOverride = true }, .skip(.retryScheduled))
        // userOverride > noFreeEdge
        XCTAssertEqual(decide { $0.isUserOverride = true; $0.hasRelocationTarget = false }, .skip(.userOverride))
        // noFreeEdge > 세션 대기
        XCTAssertEqual(decide { $0.hasRelocationTarget = false; $0.session.locked = true }, .skip(.noFreeEdge))
        // 세션 대기 > 버튼 > 최근 입력
        XCTAssertEqual(decide { $0.session.locked = true; $0.anyButtonDown = true; $0.secondsSinceInput = 0 },
                       .wait(.locked))
        XCTAssertEqual(decide { $0.anyButtonDown = true; $0.secondsSinceInput = 0 }, .wait(.buttonDown))
        // 세션 사유 순서: 잠자기 > 잠김 > 콘솔 아님
        XCTAssertEqual(decide { $0.session.asleep = true; $0.session.locked = true; $0.session.onConsole = false },
                       .wait(.asleep))
        XCTAssertEqual(decide { $0.session.locked = true; $0.session.onConsole = false }, .wait(.locked))
    }

    func test_AC8_11a_relocationDecision_failedPhase_pollTrigger_skipFailedUntilEvent() {
        XCTAssertEqual(decide { $0.phase = .failed(attempts: 4); $0.trigger = .poll }, .skip(.failedUntilEvent))
    }

    func test_AC8_11a_relocationDecision_failedPhase_eventTrigger_go() {
        XCTAssertEqual(decide { $0.phase = .failed(attempts: 4); $0.trigger = .event }, .go)
    }

    func test_AC8_11a_relocationDecision_failedPhase_retryTimerTrigger_skipFailedUntilEvent() {
        // "이벤트 계기(.event)가 아님" 행 그대로: 재시도 타이머도 failed를 풀지 못한다
        XCTAssertEqual(decide { $0.phase = .failed(attempts: 4); $0.trigger = .retryTimer }, .skip(.failedUntilEvent))
    }

    func test_AC8_11a_relocationDecision_retryScheduled_pollTrigger_skipRetryScheduled() {
        XCTAssertEqual(decide { $0.retryScheduled = true; $0.trigger = .poll }, .skip(.retryScheduled))
    }

    func test_AC8_11a_relocationDecision_retryScheduled_retryTimerTrigger_go() {
        XCTAssertEqual(decide { $0.retryScheduled = true; $0.trigger = .retryTimer }, .go)
    }

    // MARK: - AC8.6 일정 함수 relocationRetryDelay (R8.7)

    func test_AC8_6_relocationRetryDelay_1_3_10_thenNil() {
        XCTAssertEqual(DockPinPolicy.relocationRetryDelay(afterFailures: 1), 1)
        XCTAssertEqual(DockPinPolicy.relocationRetryDelay(afterFailures: 2), 3)
        XCTAssertEqual(DockPinPolicy.relocationRetryDelay(afterFailures: 3), 10)
        XCTAssertNil(DockPinPolicy.relocationRetryDelay(afterFailures: 4), "4회 실패 → 자동 재시도 중단(maxAttempts)")
        XCTAssertNil(DockPinPolicy.relocationRetryDelay(afterFailures: 5))
    }

    // MARK: - AC8.10 단계 → 스냅숏 플래그 (R8.1 표, DockPinModels)

    func test_AC8_10_phaseFlags_matchR8_1Table() {
        let rows: [(DockPinRelocationPhase, isRelocating: Bool, isDriving: Bool)] = [
            (.idle, false, false),
            (.waiting(.userActive), false, false),
            (.waiting(.locked), false, false),
            (.failed(attempts: 4), false, false),
            (.driving, true, true),
            (.verifying, true, false),
        ]
        for row in rows {
            XCTAssertEqual(row.0.isRelocating, row.isRelocating, "\(row.0).isRelocating")
            XCTAssertEqual(row.0.isDriving, row.isDriving, "\(row.0).isDriving")
        }
    }

    // MARK: - AC10.4 isScreenLocked (R10.3, F3)

    func test_AC10_4_isScreenLocked_missingKeyOrNilDictionary_notLocked() {
        XCTAssertFalse(DockPinPolicy.isScreenLocked(sessionInfo: [:]))
        XCTAssertFalse(DockPinPolicy.isScreenLocked(sessionInfo: nil))
        XCTAssertFalse(DockPinPolicy.isScreenLocked(sessionInfo: ["kCGSSessionOnConsoleKey": true]))
    }

    func test_AC10_4_isScreenLocked_trueOrOne_locked() {
        XCTAssertTrue(DockPinPolicy.isScreenLocked(sessionInfo: ["CGSSessionScreenIsLocked": true]))
        XCTAssertTrue(DockPinPolicy.isScreenLocked(sessionInfo: ["CGSSessionScreenIsLocked": 1]))
        XCTAssertTrue(DockPinPolicy.isScreenLocked(sessionInfo: ["CGSSessionScreenIsLocked": NSNumber(value: 1)]))
    }

    func test_AC10_4_isScreenLocked_falseOrZero_notLocked() {
        XCTAssertFalse(DockPinPolicy.isScreenLocked(sessionInfo: ["CGSSessionScreenIsLocked": false]))
        XCTAssertFalse(DockPinPolicy.isScreenLocked(sessionInfo: ["CGSSessionScreenIsLocked": 0]))
        // 짝 단정
        XCTAssertTrue(DockPinPolicy.isScreenLocked(sessionInfo: ["CGSSessionScreenIsLocked": true]))
    }

    // MARK: - AC11.1 presentation 문구 (R11.2 표 × 두 언어)

    func test_AC11_1_presentation_korean_textMatchesTableExactly() {
        for row in Self.statusRows() {
            XCTAssertEqual(present(row.status, .korean).text, row.ko, "\(row.status)")
        }
    }

    func test_AC11_1_presentation_english_textMatchesTableExactly() {
        for row in Self.statusRows() {
            XCTAssertEqual(present(row.status, .english).text, row.en, "\(row.status)")
        }
    }

    func test_AC11_1_presentation_noEmptyStringsInEitherLanguage() {
        for language in AppLanguage.allCases {
            for row in Self.statusRows() {
                for fallback in [false, true] {
                    let p = present(row.status, fallback: fallback, language)
                    XCTAssertFalse(p.text.isEmpty, "\(row.status) \(language) text")
                    XCTAssertFalse(p.accessibilityLabel.isEmpty, "\(row.status) \(language) label")
                    if let note = p.fallbackNote { XCTAssertFalse(note.isEmpty) }
                }
            }
        }
    }

    func test_AC11_1_presentation_nameIsSubstitutedIntoNamedStatuses() {
        for name in ["Color LCD", "LG HDR 4K"] {
            let named: [DockPinStatus] = [
                .noFreeEdge(displayName: name), .pinned(displayName: name),
                .waiting(.buttonDown, displayName: name), .relocating(displayName: name),
                .movedByUser(displayName: name),
            ]
            for status in named {
                for language in AppLanguage.allCases {
                    let text = present(status, language).text
                    XCTAssertTrue(text.contains(name), "\(status) \(language): \(text)")
                    XCTAssertFalse(text.contains("{name}"))
                }
            }
        }
    }

    func test_AC11_1_presentation_failedShowsAttemptCount() {
        XCTAssertEqual(present(.failed(attempts: 4), .korean).text, "Dock을 되돌리지 못했어요(4회 시도)")
        XCTAssertEqual(present(.failed(attempts: 2), .english).text, "Couldn't move the Dock back (2 tries)")
    }

    func test_AC11_1_presentation_waitingTextIsSameForEveryReason() {
        let reasons: [DockPinWaitReason] = [.asleep, .locked, .notOnConsole, .buttonDown, .userActive]
        for language in AppLanguage.allCases {
            let texts = Set(reasons.map { present(.waiting($0, displayName: "Color LCD"), language).text })
            XCTAssertEqual(texts.count, 1, "\(language)")
            XCTAssertFalse(texts.first?.isEmpty ?? true)
        }
    }

    func test_AC11_1_presentation_tapFailedTextIsSameForEveryAttempt() {
        for language in AppLanguage.allCases {
            let a = present(.tapFailed(attempt: 1), language).text
            let b = present(.tapFailed(attempt: 6), language).text
            XCTAssertEqual(a, b)
            XCTAssertFalse(a.isEmpty)
        }
    }

    func test_AC11_1_presentation_toneMatchesDesignContract() {
        for language in AppLanguage.allCases {
            for row in Self.statusRows() {
                XCTAssertEqual(present(row.status, language).tone, row.tone, "\(row.status)")
            }
        }
    }

    // MARK: - AC11.2 "지금 되돌리기" 활성 (R11.2 14행)

    func test_AC11_2_presentation_moveBackEnabled_matchesAllRows() {
        for language in AppLanguage.allCases {
            for row in Self.statusRows() {
                for fallback in [false, true] {
                    XCTAssertEqual(present(row.status, fallback: fallback, language).moveBackEnabled,
                                   row.moveBackEnabled, "\(row.status) \(language) fallback=\(fallback)")
                }
            }
        }
    }

    // MARK: - AC11.3 "권한 설정 열기"는 .needsPermission에서만

    func test_AC11_3_presentation_openPermissionSettingsShownOnlyForNeedsPermission() {
        for language in AppLanguage.allCases {
            for row in Self.statusRows() {
                let expected = row.status == .needsPermission
                XCTAssertEqual(present(row.status, language).showsOpenPermissionSettings, expected,
                               "\(row.status) \(language)")
            }
        }
    }

    // MARK: - S5 (설계 추가) 대체 고정 보조 줄

    func test_S5_presentation_fallbackNote_nilForOffNeedsPermissionInactive_presentForOthers() {
        for row in Self.statusRows() {
            let ko = present(row.status, fallback: true, .korean).fallbackNote
            let en = present(row.status, fallback: true, .english).fallbackNote
            if row.allowsFallbackNote {
                XCTAssertEqual(ko, Self.fallbackNoteKo, "\(row.status)")
                XCTAssertEqual(en, Self.fallbackNoteEn, "\(row.status)")
            } else {
                XCTAssertNil(ko, "\(row.status)")
                XCTAssertNil(en, "\(row.status)")
            }
        }
        // 9개 상태(+ 이름 있는 상태)에서 붙고, 6개(off·needsPermission·inactive 4종)에서 붙지 않는다
        XCTAssertEqual(Self.statusRows().filter(\.allowsFallbackNote).count, 9)
    }

    func test_S5_presentation_fallbackNote_nilWhenNotUsingFallbackAnchor() {
        for language in AppLanguage.allCases {
            for row in Self.statusRows() {
                XCTAssertNil(present(row.status, fallback: false, language).fallbackNote, "\(row.status)")
            }
        }
        // 짝 단정
        XCTAssertNotNil(present(.pinned(displayName: "Color LCD"), fallback: true, .korean).fallbackNote)
    }

    // MARK: - 접근성 레이블 (디자인 Accessibility: "Dock 고정 상태: {문구}. {보조 줄}")

    func test_presentation_accessibilityLabel_withFallbackNote() {
        XCTAssertEqual(present(.pinned(displayName: "Color LCD"), fallback: true, .korean).accessibilityLabel,
                       "Dock 고정 상태: Dock이 Color LCD에 고정됨. \(Self.fallbackNoteKo)")
        XCTAssertEqual(present(.pinned(displayName: "Color LCD"), fallback: true, .english).accessibilityLabel,
                       "Dock Pin status: Dock pinned to Color LCD. \(Self.fallbackNoteEn)")
    }

    func test_presentation_accessibilityLabel_withoutFallbackNote_hasNoTrailingSentence() {
        // 해석: 보조 줄이 없으면 ". {보조 줄}" 부분을 붙이지 않는다
        XCTAssertEqual(present(.pinned(displayName: "Color LCD"), .korean).accessibilityLabel,
                       "Dock 고정 상태: Dock이 Color LCD에 고정됨")
        XCTAssertEqual(present(.needsPermission, fallback: true, .english).accessibilityLabel,
                       "Dock Pin status: Accessibility permission required")
    }

    // MARK: - AC11.4 status 우선순위 9단계 (R11.7)

    /// 모든 단계를 통과해 9번(.waiting(.userActive))에 닿는 기준 입력
    private func statusInputs(_ edit: (inout DockPinStatusInputs) -> Void = { _ in }) -> DockPinStatusInputs {
        var inputs = DockPinStatusInputs(activation: .active,
                                         tapState: .running,
                                         phase: .idle,
                                         placement: .display(Fixture.sidecarID),
                                         anchorID: Fixture.builtInID,
                                         anchorName: "Color LCD",
                                         overrideDisplayName: nil,
                                         hasRelocationTarget: true)
        edit(&inputs)
        return inputs
    }

    func test_AC11_4_status_step1_inactiveMapping() {
        XCTAssertEqual(DockPinPolicy.status(statusInputs { $0.activation = .inactive(.off) }), .off)
        XCTAssertEqual(DockPinPolicy.status(statusInputs { $0.activation = .inactive(.needsPermission) }),
                       .needsPermission)
        XCTAssertEqual(DockPinPolicy.status(statusInputs { $0.activation = .inactive(.singleDisplay) }),
                       .inactive(.singleDisplay))
        XCTAssertEqual(DockPinPolicy.status(statusInputs { $0.activation = .inactive(.spacesOff) }),
                       .inactive(.spacesOff))
        XCTAssertEqual(DockPinPolicy.status(statusInputs { $0.activation = .inactive(.dockNotBottom(.left)) }),
                       .inactive(.dockNotBottom(.left)))
    }

    func test_AC11_4_status_step1_inactiveWinsOverEverythingElse() {
        let inputs = statusInputs {
            $0.activation = .inactive(.singleDisplay)
            $0.tapState = .retrying(attempt: 3)
            $0.phase = .driving
            $0.placement = nil
        }
        XCTAssertEqual(DockPinPolicy.status(inputs), .inactive(.singleDisplay))
    }

    func test_AC11_4_status_step2_tapRetrying_tapFailedWithAttempt() {
        XCTAssertEqual(DockPinPolicy.status(statusInputs { $0.tapState = .retrying(attempt: 3) }),
                       .tapFailed(attempt: 3))
        // 2 > 3: 단계가 있어도 탭 실패가 먼저
        XCTAssertEqual(DockPinPolicy.status(statusInputs { $0.tapState = .retrying(attempt: 1); $0.phase = .failed(attempts: 4) }),
                       .tapFailed(attempt: 1))
    }

    func test_AC11_4_status_step3_phaseMapping() {
        XCTAssertEqual(DockPinPolicy.status(statusInputs { $0.phase = .driving }), .relocating(displayName: "Color LCD"))
        XCTAssertEqual(DockPinPolicy.status(statusInputs { $0.phase = .verifying }), .relocating(displayName: "Color LCD"))
        XCTAssertEqual(DockPinPolicy.status(statusInputs { $0.phase = .waiting(.locked) }),
                       .waiting(.locked, displayName: "Color LCD"))
        XCTAssertEqual(DockPinPolicy.status(statusInputs { $0.phase = .failed(attempts: 4) }), .failed(attempts: 4))
    }

    func test_AC11_4_status_step3_phaseWinsOverOverrideAndUnlocated() {
        let inputs = statusInputs {
            $0.phase = .failed(attempts: 4)
            $0.overrideDisplayName = "Sidecar Display (AirPlay)"
            $0.hasRelocationTarget = false
            $0.placement = nil
        }
        XCTAssertEqual(DockPinPolicy.status(inputs), .failed(attempts: 4))
    }

    func test_AC11_4_status_step4_override_movedByUserWithOverrideDisplayName() {
        let inputs = statusInputs {
            $0.overrideDisplayName = "Sidecar Display (AirPlay)"
            $0.hasRelocationTarget = false
        }
        XCTAssertEqual(DockPinPolicy.status(inputs), .movedByUser(displayName: "Sidecar Display (AirPlay)"))
    }

    func test_AC11_4_status_step5_noRelocationTarget_noFreeEdgeEvenWhenDockOnAnchor() {
        // SPEC 예: 목표점 없음 + Dock이 고정 화면 → .noFreeEdge (5번이 6·8번보다 앞)
        XCTAssertEqual(DockPinPolicy.status(statusInputs {
            $0.hasRelocationTarget = false
            $0.placement = .display(Fixture.builtInID)
        }), .noFreeEdge(displayName: "Color LCD"))
        XCTAssertEqual(DockPinPolicy.status(statusInputs {
            $0.hasRelocationTarget = false
            $0.placement = nil
        }), .noFreeEdge(displayName: "Color LCD"))
    }

    func test_AC11_4_status_step6_notYetLocatedAndActive_checkingNotPinned() {
        XCTAssertEqual(DockPinPolicy.status(statusInputs { $0.placement = nil }), .checking)
    }

    func test_AC11_4_status_step7_unknownPlacement_dockNotFound() {
        XCTAssertEqual(DockPinPolicy.status(statusInputs { $0.placement = .unknown }), .dockNotFound)
    }

    func test_AC11_4_status_step8_dockOnAnchor_pinnedWithAnchorName() {
        XCTAssertEqual(DockPinPolicy.status(statusInputs { $0.placement = .display(Fixture.builtInID) }),
                       .pinned(displayName: "Color LCD"))
    }

    func test_AC11_4_status_step9_dockElsewhereBeforeDecision_waitingUserActive() {
        XCTAssertEqual(DockPinPolicy.status(statusInputs()), .waiting(.userActive, displayName: "Color LCD"))
    }

    // MARK: - R2.5 / S2 선택지 제목

    func test_choiceTitle_main_isLocalizedDefault() {
        let main = DockPinTargetChoice(id: "main", target: .main, kind: .main)
        XCTAssertEqual(DockPinPolicy.choiceTitle(main, language: .korean), "주 모니터 (기본)")
        XCTAssertEqual(DockPinPolicy.choiceTitle(main, language: .english), "Main display (default)")
    }

    func test_choiceTitle_connected_isDisplayNameUntranslated() {
        let choice = DockPinTargetChoice(id: Fixture.sidecar.uuid, target: .display(uuid: Fixture.sidecar.uuid),
                                         kind: .connected(name: "Sidecar Display (AirPlay)"))
        XCTAssertEqual(DockPinPolicy.choiceTitle(choice, language: .korean), "Sidecar Display (AirPlay)")
        XCTAssertEqual(DockPinPolicy.choiceTitle(choice, language: .english), "Sidecar Display (AirPlay)")
    }

    func test_choiceTitle_disconnectedWithLastName_appendsNotConnected() {
        let choice = DockPinTargetChoice(id: "X", target: .display(uuid: "X"),
                                         kind: .disconnected(lastName: "Sidecar Display (AirPlay)"))
        XCTAssertEqual(DockPinPolicy.choiceTitle(choice, language: .korean), "Sidecar Display (AirPlay) (연결 안 됨)")
        XCTAssertEqual(DockPinPolicy.choiceTitle(choice, language: .english), "Sidecar Display (AirPlay) (not connected)")
    }

    func test_choiceTitle_S2_disconnectedWithoutName_unknownDisplay() {
        let choice = DockPinTargetChoice(id: "X", target: .display(uuid: "X"), kind: .disconnected(lastName: nil))
        XCTAssertEqual(DockPinPolicy.choiceTitle(choice, language: .korean), "알 수 없는 모니터 (연결 안 됨)")
        XCTAssertEqual(DockPinPolicy.choiceTitle(choice, language: .english), "Unknown display (not connected)")
    }

    // MARK: - DockPinText 고정 문구 (R11.3, 디자인 [A]–[D], S6)

    func test_text_t_picksLanguage() {
        XCTAssertEqual(DockPinText.t("한국어", "English", .korean), "한국어")
        XCTAssertEqual(DockPinText.t("한국어", "English", .english), "English")
    }

    func test_text_staticStrings_korean() {
        XCTAssertEqual(DockPinText.sectionTitle(.korean), "Dock 고정")
        XCTAssertEqual(DockPinText.toggleTitle(.korean), "Dock을 한 모니터에 고정")
        XCTAssertEqual(DockPinText.toggleDescription(.korean),
                       "보조 모니터 아래쪽에 마우스를 대도 Dock이 넘어가지 않아요. 손쉬운 사용 권한이 필요해요.")
        XCTAssertEqual(DockPinText.pickerTitle(.korean), "Dock을 둘 모니터")
        XCTAssertEqual(DockPinText.openPermissionSettings(.korean), "권한 설정 열기")
        XCTAssertEqual(DockPinText.moveBackNow(.korean), "지금 되돌리기")
        XCTAssertEqual(DockPinText.helpOption(.korean), "Option 키를 누른 채로 대면 Dock을 옮길 수 있어요")
        XCTAssertEqual(DockPinText.helpPermissionCaution(.korean),
                       "손쉬운 사용 권한을 끄기 전에 Dock 고정을 끄거나 앱을 종료하세요")
        XCTAssertEqual(DockPinText.fallbackNote(.korean), Self.fallbackNoteKo)
    }

    func test_text_staticStrings_english() {
        XCTAssertEqual(DockPinText.sectionTitle(.english), "Dock Pin")
        XCTAssertEqual(DockPinText.toggleTitle(.english), "Keep the Dock on one display")
        XCTAssertEqual(DockPinText.toggleDescription(.english),
                       "The Dock won't jump to other displays when you touch their bottom edge. Requires Accessibility permission.")
        XCTAssertEqual(DockPinText.pickerTitle(.english), "Keep the Dock on")
        XCTAssertEqual(DockPinText.openPermissionSettings(.english), "Open Permission Settings")
        XCTAssertEqual(DockPinText.moveBackNow(.english), "Move Dock back now")
        XCTAssertEqual(DockPinText.helpOption(.english), "Hold Option to let the Dock move")
        XCTAssertEqual(DockPinText.helpPermissionCaution(.english),
                       "Turn off Dock Pin or quit the app before turning off Accessibility permission")
        XCTAssertEqual(DockPinText.fallbackNote(.english), Self.fallbackNoteEn)
    }

    // MARK: - AC11.5 "고정"이 들어간 문구에는 "Dock"도 (R11.6, 리뷰 N8)

    private func staticStrings(_ l: AppLanguage) -> [String] {
        [DockPinText.sectionTitle(l), DockPinText.toggleTitle(l), DockPinText.toggleDescription(l),
         DockPinText.pickerTitle(l), DockPinText.openPermissionSettings(l), DockPinText.moveBackNow(l),
         DockPinText.helpOption(l), DockPinText.helpPermissionCaution(l), DockPinText.fallbackNote(l)]
    }

    func test_AC11_5_allUserFacingStrings_korean_enumeratesEveryCategory() {
        let all = DockPinText.allUserFacingStrings(.korean)
        // 정적 문구(토글·피커·버튼·안내·보조 줄)
        for s in staticStrings(.korean) {
            XCTAssertFalse(s.isEmpty)
            XCTAssertTrue(all.contains(s), "누락: \(s)")
        }
        // 이름 없는 상태 문구
        for row in Self.statusRows() where !row.ko.contains(Fixture.sampleName) && !row.ko.contains("회 시도") {
            XCTAssertTrue(all.contains(row.ko), "누락: \(row.ko)")
        }
        // 이름 있는 상태 문구(샘플 이름은 구현이 정한다)
        XCTAssertTrue(all.contains { $0.hasPrefix("Dock이 ") && $0.hasSuffix("에 고정됨") }, "누락: .pinned")
        XCTAssertTrue(all.contains { $0.hasPrefix("Dock을 되돌리지 못했어요(") }, "누락: .failed")
        XCTAssertTrue(all.contains { $0.hasSuffix("(으)로 되돌릴 준비 중…") }, "누락: .waiting")
        XCTAssertTrue(all.contains { $0.hasSuffix("(으)로 되돌리는 중…") }, "누락: .relocating")
        XCTAssertTrue(all.contains { $0.hasPrefix("Option으로 ") }, "누락: .movedByUser")
        XCTAssertTrue(all.contains { $0.hasSuffix(" 아래쪽이 다른 모니터에 맞닿아 있어 Dock을 둘 수 없어요") }, "누락: .noFreeEdge")
        // 선택지 제목(S2 포함)
        XCTAssertTrue(all.contains("주 모니터 (기본)"))
        XCTAssertTrue(all.contains("알 수 없는 모니터 (연결 안 됨)"))
        XCTAssertTrue(all.contains { $0.hasSuffix(" (연결 안 됨)") && !$0.hasPrefix("알 수 없는 모니터") },
                      "누락: '{마지막 이름} (연결 안 됨)'")
        // 접근성 레이블
        XCTAssertTrue(all.contains { $0.hasPrefix("Dock 고정 상태: ") }, "누락: 접근성 레이블")
    }

    func test_AC11_5_allUserFacingStrings_english_enumeratesEveryCategory() {
        let all = DockPinText.allUserFacingStrings(.english)
        for s in staticStrings(.english) {
            XCTAssertFalse(s.isEmpty)
            XCTAssertTrue(all.contains(s), "missing: \(s)")
        }
        for row in Self.statusRows() where !row.en.contains(Fixture.sampleName) && !row.en.contains(" tries)") {
            XCTAssertTrue(all.contains(row.en), "missing: \(row.en)")
        }
        XCTAssertTrue(all.contains { $0.hasPrefix("Dock pinned to ") }, "missing: .pinned")
        XCTAssertTrue(all.contains { $0.hasPrefix("Couldn't move the Dock back (") }, "missing: .failed")
        XCTAssertTrue(all.contains { $0.hasPrefix("Waiting to move the Dock back to ") }, "missing: .waiting")
        XCTAssertTrue(all.contains { $0.hasPrefix("Moving the Dock back to ") }, "missing: .relocating")
        XCTAssertTrue(all.contains { $0.hasPrefix("Moved to ") && $0.contains(" with Option") }, "missing: .movedByUser")
        XCTAssertTrue(all.contains { $0.hasPrefix("The bottom of ") }, "missing: .noFreeEdge")
        XCTAssertTrue(all.contains("Main display (default)"))
        XCTAssertTrue(all.contains("Unknown display (not connected)"))
        XCTAssertTrue(all.contains { $0.hasSuffix(" (not connected)") && !$0.hasPrefix("Unknown display") },
                      "missing: '{last name} (not connected)'")
        XCTAssertTrue(all.contains { $0.hasPrefix("Dock Pin status: ") }, "missing: accessibility label")
    }

    func test_AC11_5_allUserFacingStrings_noEmptyStrings() {
        for language in AppLanguage.allCases {
            let all = DockPinText.allUserFacingStrings(language)
            XCTAssertGreaterThanOrEqual(all.count, 30, "\(language): 정적 9 + 상태 15 + 선택지 + 레이블")
            XCTAssertFalse(all.contains(""), "\(language)")
        }
    }

    func test_AC11_5_korean_everyStringContainingGojeong_alsoContainsDock() {
        let all = DockPinText.allUserFacingStrings(.korean)
        XCTAssertFalse(all.isEmpty)
        let withGojeong = all.filter { $0.contains("고정") }
        XCTAssertGreaterThanOrEqual(withGojeong.count, 5,
                                    "섹션 제목·토글·.pinned·주의 문구·접근성 레이블에 '고정'이 있다")
        for s in withGojeong {
            XCTAssertTrue(s.contains("Dock"), "단독 '고정' 금지(R11.6): \(s)")
        }
    }

    func test_AC11_5_english_everyStringContainingPin_alsoContainsDock() {
        let all = DockPinText.allUserFacingStrings(.english)
        XCTAssertFalse(all.isEmpty)
        let withPin = all.filter { $0.lowercased().contains("pin") }
        XCTAssertGreaterThanOrEqual(withPin.count, 3, "Dock Pin·Dock pinned to·Dock Pin status")
        for s in withPin {
            XCTAssertTrue(s.contains("Dock"), "\(s)")
        }
    }

    func test_AC11_5_presentationOutputs_withGojeong_containDock() {
        // allUserFacingStrings와 독립적으로, presentation이 실제로 내는 모든 문자열을 검사한다
        for row in Self.statusRows() {
            for fallback in [false, true] {
                let p = present(row.status, fallback: fallback, .korean)
                XCTAssertFalse(p.text.isEmpty, "\(row.status)")
                for s in [p.text, p.accessibilityLabel] + (p.fallbackNote.map { [$0] } ?? []) where s.contains("고정") {
                    XCTAssertTrue(s.contains("Dock"), "\(s)")
                }
                XCTAssertTrue(p.accessibilityLabel.hasPrefix("Dock 고정 상태: "), "\(row.status)")
            }
        }
    }

    // MARK: - AC12.3 isTestHost (R12.3, N13)

    func test_AC12_3_isTestHost_eachEnvironmentKeyAlone_true() {
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"] {
            XCTAssertTrue(DockPinPolicy.isTestHost(environment: [key: "/tmp/x"], xcTestClassLoaded: false), key)
        }
    }

    func test_AC12_3_isTestHost_emptyEnvironmentButXCTestClassLoaded_true() {
        XCTAssertTrue(DockPinPolicy.isTestHost(environment: [:], xcTestClassLoaded: true))
    }

    func test_AC12_3_isTestHost_noKeysAndClassNotLoaded_false() {
        XCTAssertFalse(DockPinPolicy.isTestHost(environment: [:], xcTestClassLoaded: false))
    }

    func test_AC12_3_isTestHost_unrelatedEnvironmentKeysOnly_false() {
        XCTAssertFalse(DockPinPolicy.isTestHost(environment: ["PATH": "/usr/bin", "HOME": "/Users/x"],
                                                xcTestClassLoaded: false))
        // 짝 단정: 같은 딕셔너리에 키 하나가 더해지면 true
        XCTAssertTrue(DockPinPolicy.isTestHost(environment: ["PATH": "/usr/bin", "XCTestBundlePath": "/b"],
                                               xcTestClassLoaded: false))
    }
}
