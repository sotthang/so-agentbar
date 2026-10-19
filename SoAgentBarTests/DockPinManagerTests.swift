import XCTest
import Combine
import CoreGraphics
@testable import SoAgentBar

// MARK: - DockPinManagerTests
//
// SPEC-004 커밋 8 — DockPinManager(arch §2.10, §3) 단위 테스트.
// 커버 AC: AC1.1–1.6, AC4.2–4.4, AC4.6, AC4.8, AC4.9, AC4.10(a–c), AC5.11(매니저), AC7.5, AC8.3(매니저 경로),
//          AC8.4c(매니저부), AC8.5–8.8, AC8.9(매니저부), AC8.10(매니저 스냅숏), AC8.11(b,c), AC8.12, AC9.1–9.5, AC9.6(매니저부, 11c),
//          AC9.7(a–e), AC9.8(a–c), AC9.9, AC9.10, AC9.11, AC9.12, AC9.14(11e·11f),
//          AC10.1–10.3, AC12.1, AC12.2, AC12.3(makeLive 연결), AC12.4, AC15.1–15.4
//          + R4.4 매니저 수준 타이머 집합, R4.5 prefsPoll, R5.8 watchdog, R6.1 Dock 재시작, R8.8 지금 되돌리기,
//          R10.1–10.4 세션 신호, S1 targetChoices, arch §12 I2(setTarget 즉시 재계산), I4, I9, I10.
//
// 안전: 가짜만 쓴다. UserDefaults.standard를 읽거나 쓰지 않는다(R1.7 — 테스트마다 고유 suite, 끝나면 지운다).
// 실제 탭·이벤트 전송·커서 이동·창 조회·디스플레이 콜백·알림 등록이 0이다. 시간은 FakeDockPinScheduler.advance(by:)로만 흐른다.
// makeLive 테스트만 Live 의존성을 "만들기만" 한다(arch §2.6: Live 어댑터 init은 시스템 호출·등록이 없다).
// 그 테스트는 dockPinEnabled == false인 suite에서 setTarget만 부른다(시스템을 건드리는 경로가 없다).
//
// RED 확인: 이 파일은 컴파일된다(DockPinManager는 arch §2.10 시그니처의 스텁). 스텁은 발행값이 틀린 값
// (isEnabled = true, status = .failed(attempts: -1) 등)이고 모든 메서드가 무동작이다 → 아래 테스트는 전부 실패하는 것이 정상이다.
// "0회" 같은 단정이 스텁과 겹치는 테스트에는 양성 짝 단정(상태 값, 시작 횟수 등)을 같은 테스트 안에 둔다.
// 스텁에서도 크래시하지 않도록 강제 언래핑·범위 밖 인덱싱을 쓰지 않는다.
//
// 시각 기준(개발자 메모): 활성화 = t0(가짜 시계 1000). Dock이 다른 화면에서 확인되면 그 자리에서 되돌리기가 시작되고
// (가짜 조회기는 동기 응답), 첫 이동은 t0, 목표 줄 도달은 t0+0.224, 마지막 전체 조회(.final)는 t0+2.224다.
// .final이 동기로 "다른 화면"을 돌려주면 1차 실패도 t0+2.224, 재시도는 t0+3.224, dockPoll은 t0+3, 6, 9 …에 돈다.

@MainActor
final class DockPinManagerTests: XCTestCase {

    // MARK: - 고정값

    private enum Keys {
        static let enabled = "dockPinEnabled"
        static let targetUUID = "dockPinTargetDisplayUUID"
        static let targetName = "dockPinTargetDisplayName"
    }

    private enum Fixture {
        static let builtIn = DockPinFixtures.builtIn          // id 1, (0,0,1728,1117), "Color LCD"
        static let sidecar = DockPinFixtures.sidecar          // id 12, (1728,0,1149,802)
        static let external = DockPinFixtures.external2560    // id 5, 내장 왼쪽
        /// AC8.8 — 내장 화면 아래쪽 가로 전체에 맞닿은 화면
        static let below = DockPinFixtures.display(7, "BELOW-UUID", 0, 1117, 1728, 1000, name: "Below")
        /// 되돌리기 시작 때 커서(내장 화면 안)
        static let cursorOnBuiltIn = CGPoint(x: 500, y: 500)
        /// AC15.4 — Sidecar 안
        static let cursorOnSidecar = CGPoint(x: 2000, y: 400)
        /// AC8.9 / AC15.4 — 내장 화면 가운데
        static let builtInCenter = CGPoint(x: 864, y: 558.5)
        /// AC3.10 목표점 (864, 1116)의 다가가기 첫 점
        static let firstApproach = CGPoint(x: 864, y: 1076)
        /// AC3.11 목표점 (2302.5, 801)의 다가가기 첫 점
        static let firstApproachToSidecar = CGPoint(x: 2302.5, y: 761)
        /// AC3.10 — 이 Mac, 대상 .main → Sidecar 줄 한 조각
        static let sidecarRow = DockPinTriggerRow(displayID: 12, minX: 1728, maxX: 2877, minY: 801, maxY: 802)
        static let tick = DockPinTuning.driveInterval                     // 0.016
        /// 첫 이동부터 .final 요청까지(0.224 + 2.0)
        static let finalAt: TimeInterval = 0.224 + DockPinTuning.relocationTimeout
        static let onBuiltIn = DockPinLocateOutcome.placement(.display(1))
        static let onSidecar = DockPinLocateOutcome.placement(.display(12))
    }

    // MARK: - 하네스

    /// 가짜 10개 + 고유 suite + 매니저. 조회기 응답은 `dockOn`(nil = .unknown)을 따르고,
    /// `silentModes`의 모드는 응답하지 않는다(나중에 fakes.locator.completePending). `custom`이 있으면 그것이 이긴다.
    @MainActor
    private final class Harness {
        let defaults: UserDefaults
        let deps: DockPinDependencies
        let fakes: DockPinFakeSet
        let manager: DockPinManager

        var dockOn: CGDirectDisplayID? = DockPinFixtures.builtIn.id
        var silentModes: [DockPinLocateMode] = []
        var custom: ((DockPinLocateMode) -> DockPinLocateOutcome?)?
        private(set) var statusHistory: [DockPinStatus] = []
        private var cancellables = Set<AnyCancellable>()

        init(suite: String, enabled: Bool, targetUUID: String?, targetName: String?, isInert: Bool) {
            defaults = makeDockPinSuite(suite)
            if enabled { defaults.set(true, forKey: Keys.enabled) }
            if let targetUUID { defaults.set(targetUUID, forKey: Keys.targetUUID) }
            if let targetName { defaults.set(targetName, forKey: Keys.targetName) }
            let made = makeDockPinTestDependencies()
            deps = made.0
            fakes = made.1
            manager = DockPinManager(defaults: defaults, dependencies: deps, isInert: isInert)

            let scheduler = fakes.scheduler
            fakes.poster.clock = { scheduler.now }
            fakes.poster.cursor = Fixture.cursorOnBuiltIn
            fakes.locator.respond = { [unowned self] mode, _ in self.answer(mode) }
            manager.$status
                .sink { [unowned self] status in
                    self.statusHistory.append(status)
                    self.fakes.log.add("status:\(status)")
                }
                .store(in: &cancellables)
        }

        private func answer(_ mode: DockPinLocateMode) -> DockPinLocateOutcome? {
            if let custom { return custom(mode) }
            if silentModes.contains(mode) { return nil }
            return .placement(dockOn.map { .display($0) } ?? .unknown)
        }

        func start() { manager.startIfEnabled() }
        func advance(_ seconds: TimeInterval) { fakes.scheduler.advance(by: seconds) }
        var now: TimeInterval { fakes.scheduler.now }
        var moves: [CGPoint] { fakes.poster.moves }
        func requestCount(_ mode: DockPinLocateMode) -> Int { fakes.locator.requests.filter { $0 == mode }.count }
        var retryDelays: [TimeInterval] { fakes.scheduler.scheduledDelays(.relocationRetry) }
        var pendingRetries: Int { fakes.scheduler.pendingCount(.relocationRetry) }
        var lastSnapshot: DockPinGuardSnapshot? { fakes.tap.snapshots.last }

        /// 어떤 의존성도 불리지 않았다(AC1.1, AC1.2, AC4.9, AC12.4)
        func assertNoDependencyCalls(_ context: String, file: StaticString = #filePath, line: UInt = #line) {
            let f = fakes
            let counts: [(String, Int)] = [
                ("permission.check", f.permission.checkCount),
                ("permission.probe", f.permission.probeCount),
                ("permission.prompt", f.permission.promptCount),
                ("permission.open", f.permission.openCount),
                ("tap.start", f.tap.startCount),
                ("tap.stop", f.tap.stopCount),
                ("tap.update", f.tap.snapshots.count),
                ("tap.reenable", f.tap.reenableCount),
                ("tap.drain", f.tap.drainCount),
                ("displayChanges.start", f.displayChanges.startCount),
                ("displayChanges.stop", f.displayChanges.stopCount),
                ("systemEvents.start", f.systemEvents.startCount),
                ("systemEvents.stop", f.systemEvents.stopCount),
                ("scheduler.created", f.scheduler.createdCount),
                ("displays.read", f.displays.readCount),
                ("prefs.spaces", f.dockPreferences.spacesReadCount),
                ("prefs.orientation", f.dockPreferences.orientationReadCount),
                ("prefs.pid", f.dockPreferences.pidReadCount),
                ("locator.locate", f.locator.requests.count),
                ("locator.invalidate", f.locator.invalidateCount),
                ("locator.cancelAll", f.locator.cancelCount),
                ("poster.move", f.poster.moves.count),
                ("poster.cursorRead", f.poster.cursorReadCount),
            ]
            for (name, count) in counts {
                XCTAssertEqual(count, 0, "\(context): \(name) 호출이 0회여야 한다", file: file, line: line)
            }
        }
    }

    private func harness(_ name: String, enabled: Bool = true, targetUUID: String? = nil,
                         targetName: String? = nil, isInert: Bool = false) -> Harness {
        let suite = "Manager.\(name)"
        let h = Harness(suite: suite, enabled: enabled, targetUUID: targetUUID, targetName: targetName, isInert: isInert)
        let fullName = dockPinSuiteName(suite)
        addTeardownBlock {
            UserDefaults(suiteName: fullName)?.removePersistentDomain(forName: fullName)
        }
        return h
    }

    /// Dock이 Sidecar에 있는 상태로 활성화 → 그 자리에서 되돌리기가 시작된다(사전 조건 단정 포함).
    private func drivingHarness(_ name: String, cursor: CGPoint = Fixture.cursorOnBuiltIn,
                                file: StaticString = #filePath, line: UInt = #line) -> Harness {
        let h = harness(name)
        h.dockOn = Fixture.sidecar.id
        h.fakes.poster.cursor = cursor
        h.start()
        XCTAssertEqual(h.moves.first, Fixture.firstApproach,
                       "사전 조건: Dock이 다른 화면이면 활성화 직후 되돌리기가 시작돼 다가가기 첫 점으로 이동해야 한다",
                       file: file, line: line)
        XCTAssertEqual(h.manager.status, .relocating(displayName: Fixture.builtIn.name),
                       "사전 조건: 되돌리는 중 상태", file: file, line: line)
        return h
    }

    /// 4번 모두 실패해 .failed(attempts: 4)가 된 상태(t0+25)
    private func failedFourTimesHarness(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> Harness {
        let h = drivingHarness(name, file: file, line: line)
        h.advance(25)
        XCTAssertEqual(h.manager.status, .failed(attempts: 4), "사전 조건: 4회 실패", file: file, line: line)
        XCTAssertEqual(h.retryDelays, [1, 3, 10], "사전 조건: 재시도 1·3·10초", file: file, line: line)
        return h
    }

    /// Option 통과로 Sidecar로 옮겨 오버라이드된 상태(t0+3.1, Option 통과 t0+1)
    private func overrideHarness(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> Harness {
        let h = harness(name)
        h.start()
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name),
                       "사전 조건: 처음에는 고정 화면에서 확인", file: file, line: line)
        h.advance(1)
        h.dockOn = Fixture.sidecar.id
        h.fakes.tap.emitOptionPass(Fixture.sidecar.id, at: h.now)
        h.advance(2.1)                    // Option 확인 0.5/1.0/2.0 s + dockPoll(t0+3) 모두 지난다
        XCTAssertEqual(h.manager.status, .movedByUser(displayName: Fixture.sidecar.name),
                       "사전 조건: Option으로 옮긴 오버라이드", file: file, line: line)
        XCTAssertTrue(h.moves.isEmpty, "사전 조건: 오버라이드 중에는 되돌리지 않는다", file: file, line: line)
        return h
    }

    // MARK: - AC1 설정·옵트인

    func test_AC1_1_freshSuite_defaultsOffMainNoName_andTouchesNothing() {
        let h = harness("AC1_1", enabled: false)
        XCTAssertFalse(h.manager.isEnabled, "키가 없으면 기본 OFF")
        XCTAssertEqual(h.manager.target, .main)
        XCTAssertNil(h.manager.targetDisplayName)
        XCTAssertEqual(h.manager.status, .off)
        XCTAssertFalse(h.manager.usingFallbackAnchor)
        XCTAssertEqual(h.manager.targetChoices, [], "꺼져 있으면 선택지 없음(S1)")
        h.assertNoDependencyCalls("init")
    }

    func test_AC1_1_initReadsStoredKeys() {
        let h = harness("AC1_1_stored", enabled: true, targetUUID: "X", targetName: "Some Display")
        XCTAssertTrue(h.manager.isEnabled)
        XCTAssertEqual(h.manager.target, .display(uuid: "X"))
        XCTAssertEqual(h.manager.targetDisplayName, "Some Display")
        XCTAssertEqual(h.manager.status, .off, "init은 아무것도 시작하지 않는다(R1.2)")
        h.assertNoDependencyCalls("init(enabled)")
    }

    func test_AC1_2_disabled_startIfEnabled_doesNothing() {
        let h = harness("AC1_2", enabled: false)
        h.start()
        h.advance(5)
        h.assertNoDependencyCalls("startIfEnabled(disabled)")
        XCTAssertEqual(h.manager.status, .off)
        // 양성 짝: 켜면 그때 관찰을 시작한다
        h.manager.setEnabled(true)
        XCTAssertEqual(h.fakes.displayChanges.startCount, 1, "켜는 순간 디스플레이 콜백 등록 1회")
        XCTAssertEqual(h.fakes.systemEvents.startCount, 1, "켜는 순간 알림 옵저버 등록 1회")
    }

    func test_AC1_3_enableWithoutPermission_promptsExactlyOnce_needsPermission() {
        let h = harness("AC1_3", enabled: false)
        h.fakes.permission.trusted = false
        h.manager.setEnabled(true)
        XCTAssertEqual(h.fakes.permission.promptCount, 1)
        XCTAssertEqual(h.manager.status, .needsPermission)
        XCTAssertTrue(h.manager.isEnabled, "토글은 켜진 채로 둔다")
        XCTAssertEqual(h.fakes.tap.startCount, 0, "권한 없이는 탭을 만들지 않는다(P4)")
        h.manager.setEnabled(true)
        XCTAssertEqual(h.fakes.permission.promptCount, 1, "이미 켜져 있으면 다시 묻지 않는다")
    }

    func test_AC1_3_enableWithPermission_noPrompt_startsTap() {
        let h = harness("AC1_3_trusted", enabled: false)
        h.manager.setEnabled(true)
        XCTAssertEqual(h.fakes.permission.promptCount, 0)
        XCTAssertEqual(h.fakes.tap.startCount, 1)
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
    }

    func test_AC1_4_relaunchEnabledWithoutPermission_noPrompt_needsPermission() {
        let h = harness("AC1_4", enabled: true)
        h.fakes.permission.trusted = false
        h.start()
        XCTAssertEqual(h.fakes.permission.promptCount, 0, "다시 시작할 때는 프롬프트를 띄우지 않는다(R1.5)")
        XCTAssertGreaterThanOrEqual(h.fakes.permission.checkCount, 1, "권한은 확인한다")
        XCTAssertEqual(h.manager.status, .needsPermission)
        XCTAssertEqual(h.fakes.tap.startCount, 0)
    }

    func test_AC1_5_setEnabledPersistsToSameSuite_andNewManagerReadsIt() {
        let h = harness("AC1_5", enabled: false)
        h.manager.setEnabled(true)
        XCTAssertEqual(h.defaults.object(forKey: Keys.enabled) as? Bool, true)
        let (deps2, _) = makeDockPinTestDependencies()
        XCTAssertTrue(DockPinManager(defaults: h.defaults, dependencies: deps2).isEnabled)

        h.manager.setEnabled(false)
        XCTAssertEqual(h.defaults.object(forKey: Keys.enabled) as? Bool, false)
        let (deps3, _) = makeDockPinTestDependencies()
        XCTAssertFalse(DockPinManager(defaults: h.defaults, dependencies: deps3).isEnabled)
    }

    func test_AC1_6_setTargetWritesBothKeys_mainRemovesThem() {
        let h = harness("AC1_6", enabled: false)
        h.manager.setTarget(.display(uuid: "X"), displayName: "Sidecar Display (AirPlay)")
        XCTAssertEqual(h.defaults.string(forKey: Keys.targetUUID), "X")
        XCTAssertEqual(h.defaults.string(forKey: Keys.targetName), "Sidecar Display (AirPlay)")
        XCTAssertEqual(h.manager.target, .display(uuid: "X"))
        XCTAssertEqual(h.manager.targetDisplayName, "Sidecar Display (AirPlay)")

        h.manager.setTarget(.main, displayName: nil)
        XCTAssertNil(h.defaults.object(forKey: Keys.targetUUID), ".main → UUID 키 없음")
        XCTAssertNil(h.defaults.object(forKey: Keys.targetName), "이름 nil → removeObject")
        XCTAssertEqual(h.manager.target, .main)
        XCTAssertNil(h.manager.targetDisplayName)
    }

    // MARK: - AC4 활성화·자동 on/off

    func test_AC4_2_twoToOneDisplay_afterDebounce_tapStopped_noRepeatingTimers_singleDisplay() {
        let h = harness("AC4_2")
        h.start()
        XCTAssertTrue(h.fakes.tap.isRunning, "사전 조건: 화면 2대 + 권한 → 탭 실행")
        XCTAssertEqual(h.fakes.scheduler.pendingRepeatingKinds, [.permissionPoll, .dockPoll, .tapWatchdog, .freshTrustCheck])

        h.fakes.displays.displays = [Fixture.builtIn]
        h.fakes.displayChanges.send(.screenParametersChanged)
        h.advance(0.4)
        XCTAssertEqual(h.fakes.tap.stopCount, 0, "디바운스(0.5 s) 전에는 재계산하지 않는다")
        h.advance(0.1)
        XCTAssertEqual(h.fakes.tap.stopCount, 1)
        XCTAssertFalse(h.fakes.tap.isRunning)
        XCTAssertEqual(h.fakes.scheduler.pendingRepeatingKinds, [], "권한 폴링을 포함한 반복 타이머 0개")
        XCTAssertEqual(h.manager.status, .inactive(.singleDisplay))
        let checks = h.fakes.permission.checkCount
        h.advance(10)
        XCTAssertEqual(h.fakes.permission.checkCount, checks, "1대 + 권한 있음이면 권한을 주기적으로 읽지 않는다(R9.1)")
    }

    func test_AC4_3_oneToTwoDisplays_afterDebounce_permissionReadOnce_tapStartedOnce() {
        let h = harness("AC4_3")
        h.fakes.displays.displays = [Fixture.builtIn]
        h.start()
        XCTAssertEqual(h.manager.status, .inactive(.singleDisplay), "사전 조건")
        XCTAssertEqual(h.fakes.tap.startCount, 0)
        let checks = h.fakes.permission.checkCount

        h.fakes.displays.displays = DockPinFixtures.thisMac
        h.fakes.displayChanges.send(.reconfigured)
        h.advance(0.5)
        XCTAssertEqual(h.fakes.permission.checkCount, checks + 1, "디바운스 뒤 권한을 1회 동기로 읽는다")
        XCTAssertEqual(h.fakes.tap.startCount, 1)
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name), ".checking 뒤 위치 확인 결과")
        XCTAssertTrue(h.manager.isEnabled, "토글은 건드리지 않는다")
        XCTAssertEqual(h.fakes.permission.promptCount, 0)
    }


    /// 비활성 → 활성 전환이 구성 변경이면 첫 조회는 이벤트 계기 한 번뿐이다(활성화 조회와 겹치지 않는다)
    func test_AC4_3_activationByConfigChange_issuesExactlyOneEventLocate() {
        let h = harness("AC4_3_oneEvent")
        h.fakes.displays.displays = [Fixture.builtIn]
        h.start()
        XCTAssertEqual(h.manager.status, .inactive(.singleDisplay), "사전 조건")
        XCTAssertEqual(h.fakes.locator.requests.count, 0, "사전 조건: 비활성 중 조회 0회")

        h.fakes.displays.displays = DockPinFixtures.thisMac
        h.fakes.displayChanges.send(.reconfigured)
        h.advance(0.5)
        XCTAssertEqual(h.fakes.tap.startCount, 1, "양성 짝: 활성화됐다")
        XCTAssertEqual(h.requestCount(.event), 1, "구성 변경으로 켜지면 .event 조회는 정확히 1회")
    }

    func test_AC4_4_fiveSignalsWithinDebounce_recomputeOnce_trailing() {
        let h = harness("AC4_4")
        h.start()
        let reads = h.fakes.displays.readCount
        for i in 0..<5 {
            h.fakes.displayChanges.send(i % 2 == 0 ? .screenParametersChanged : .reconfigured)
            if i < 4 { h.advance(0.1) }
        }
        h.advance(0.05)                                    // 마지막 신호 + 0.05 s
        XCTAssertEqual(h.fakes.scheduler.firedKinds.filter { $0 == .displayDebounce }.count, 0,
                       "뒤쪽 디바운스: 마지막 신호 0.5 s 뒤까지 재계산하지 않는다")
        XCTAssertEqual(h.fakes.displays.readCount, reads)
        h.advance(0.5)                                     // 마지막 신호 + 0.55 s
        XCTAssertEqual(h.fakes.scheduler.firedKinds.filter { $0 == .displayDebounce }.count, 1, "재계산 1번")
        XCTAssertEqual(h.fakes.displays.readCount, reads + 1, "디스플레이 다시 읽기 1번")
    }

    func test_AC4_6_setEnabledFalse_unregistersCallbackAndObserversOnce_cancelsEverything() {
        let h = harness("AC4_6")
        h.start()
        XCTAssertEqual(h.fakes.displayChanges.startCount, 1, "사전 조건")
        h.manager.setEnabled(false)
        XCTAssertEqual(h.fakes.displayChanges.stopCount, 1)
        XCTAssertEqual(h.fakes.systemEvents.stopCount, 1)
        XCTAssertEqual(h.fakes.tap.stopCount, 1, "탭 동기 제거(R1.6)")
        XCTAssertEqual(h.fakes.scheduler.totalPendingCount, 0, "타이머 모두 취소(P5)")
        XCTAssertEqual(h.manager.status, .off)
        XCTAssertEqual(h.manager.targetChoices, [])
        XCTAssertEqual(h.defaults.object(forKey: Keys.enabled) as? Bool, false)
        let checks = h.fakes.permission.checkCount
        h.advance(10)
        XCTAssertEqual(h.fakes.permission.checkCount, checks, "꺼진 뒤 권한 확인 0회")
    }

    func test_AC4_8_drivingReconfiguredCallback_abortsThatTick_restores_noFailureCount() {
        let h = drivingHarness("AC4_8_cg")
        h.advance(0.1)
        let before = h.moves.count
        h.fakes.displayChanges.send(.reconfigured)
        XCTAssertEqual(h.moves.count, before + 1, "디바운스를 기다리지 않고 그 자리에서 복원 1회")
        XCTAssertEqual(h.moves.last, Fixture.cursorOnBuiltIn, "저장 위치로 복원(R8.5)")
        h.advance(0.1)
        XCTAssertEqual(h.moves.count, before + 1, "그 뒤 이동 이벤트 0개")
        XCTAssertEqual(h.retryDelays, [], "즉시 중단은 실패 횟수에 넣지 않는다(재시도 예약 없음)")
        XCTAssertNotEqual(h.manager.status, .relocating(displayName: Fixture.builtIn.name))
    }

    func test_AC4_8_drivingScreenParametersNotification_doesNotAbort() {
        let h = drivingHarness("AC4_8_ns")
        h.advance(0.1)
        let before = h.moves.count
        h.fakes.displayChanges.send(.screenParametersChanged)
        XCTAssertEqual(h.moves.count, before, "알림 자체는 아무것도 보내지 않는다")
        h.advance(0.1)
        XCTAssertGreaterThan(h.moves.count, before + 3, "이동이 계속된다(디바운스 재계산만 예약)")
        XCTAssertFalse(h.moves.contains(Fixture.cursorOnBuiltIn), "복원(=중단)이 없다")
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.displayDebounce), 1)
        XCTAssertEqual(h.manager.status, .relocating(displayName: Fixture.builtIn.name))
    }

    func test_AC4_9_initDoesNotReadSpaces_startIfEnabledDoes_activeNotSpacesOff() {
        let h = harness("AC4_9")
        XCTAssertEqual(h.fakes.dockPreferences.spacesReadCount, 0, "만들기만 하면 Spaces 읽기 0회(F15)")
        h.assertNoDependencyCalls("init(enabled)")
        h.start()
        XCTAssertGreaterThanOrEqual(h.fakes.dockPreferences.spacesReadCount, 1, "첫 Spaces 읽기는 startIfEnabled 안")
        XCTAssertEqual(h.fakes.tap.startCount, 1, "활성화 == .active → 탭 생성")
        XCTAssertNotEqual(h.manager.status, .inactive(.spacesOff))
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
    }

    func test_AC4_10a_override_sameScreenParameters_keepsOverride_neverChecking_noEventScan() {
        let h = overrideHarness("AC4_10a_ns")
        XCTAssertEqual(h.lastSnapshot?.rows, [], "R3.5: 오버라이드 화면(Sidecar)의 줄을 막지 않는다")
        let events = h.requestCount(.event)
        let mark = h.statusHistory.count
        h.fakes.displayChanges.send(.screenParametersChanged)
        h.advance(0.6)
        XCTAssertEqual(h.manager.status, .movedByUser(displayName: Fixture.sidecar.name), "오버라이드 유지")
        XCTAssertFalse(h.statusHistory.dropFirst(mark).contains(.checking), ".checking으로 한 번도 바뀌지 않는다")
        XCTAssertEqual(h.requestCount(.event), events, "백오프 무시 조회 0회")
        XCTAssertTrue(h.moves.isEmpty)
        XCTAssertEqual(h.fakes.scheduler.firedKinds.filter { $0 == .displayDebounce }.count, 1, "디바운스 재계산은 돌았다")
    }

    func test_AC4_10a_override_sameReconfiguredWhileNotDriving_keepsOverride() {
        let h = overrideHarness("AC4_10a_cg")
        let events = h.requestCount(.event)
        let mark = h.statusHistory.count
        h.fakes.displayChanges.send(.reconfigured)
        h.advance(0.6)
        XCTAssertEqual(h.manager.status, .movedByUser(displayName: Fixture.sidecar.name))
        XCTAssertFalse(h.statusHistory.dropFirst(mark).contains(.checking))
        XCTAssertEqual(h.requestCount(.event), events)
        XCTAssertTrue(h.moves.isEmpty)
    }


    /// 내용이 같은 신호는 탭 스냅숏을 다시 보내지 않는다(R4.8)
    func test_AC4_10a_sameConfigSignal_doesNotResendTapSnapshot() {
        let h = harness("AC4_10a_snapshot")
        h.start()
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name), "사전 조건")
        let pushed = h.fakes.tap.snapshots.count
        XCTAssertGreaterThan(pushed, 0, "양성 짝: 활성화 때 스냅숏을 보냈다")
        h.fakes.displayChanges.send(.screenParametersChanged)
        h.advance(0.6)
        XCTAssertEqual(h.fakes.scheduler.firedKinds.filter { $0 == .displayDebounce }.count, 1, "사전 조건: 재계산은 돌았다")
        XCTAssertEqual(h.fakes.tap.snapshots.count, pushed, "같은 스냅숏은 다시 보내지 않는다")
    }

    func test_AC4_10b_retryWaiting_sameSignal_keepsFailureCountAndScheduledRetry() {
        let h = drivingHarness("AC4_10b")
        h.advance(2.3)                                    // 1차 실패 t0+2.224, 재시도 t0+3.224
        XCTAssertEqual(h.pendingRetries, 1, "사전 조건: 재시도 대기")
        XCTAssertEqual(h.retryDelays, [1])
        let events = h.requestCount(.event)
        let mark = h.statusHistory.count

        h.fakes.displayChanges.send(.screenParametersChanged)
        h.advance(0.6)                                    // 디바운스 t0+2.8, 재시도 전
        XCTAssertEqual(h.pendingRetries, 1, "예약된 재시도 그대로")
        XCTAssertEqual(h.retryDelays, [1], "다시 예약하지 않는다")
        XCTAssertEqual(h.requestCount(.event), events)
        XCTAssertFalse(h.statusHistory.dropFirst(mark).contains(.checking))

        h.advance(3.2)                                    // 재시도 t0+3.224 → 2차 실패 t0+5.448
        XCTAssertEqual(h.retryDelays, [1, 3], "실패 횟수 1이 유지됐으므로 2차 실패 뒤 3초")
    }

    func test_AC4_10c_override_displayListChanged_releasesOverride_checking() {
        let h = overrideHarness("AC4_10c_override")
        h.silentModes = [.event]
        let events = h.requestCount(.event)
        h.fakes.displays.displays = DockPinFixtures.threeWithSidecar
        h.fakes.displayChanges.send(.screenParametersChanged)
        h.advance(0.6)
        XCTAssertEqual(h.manager.status, .checking, "구성 변경 → 오버라이드 해제, 위치 조회 전")
        XCTAssertEqual(h.requestCount(.event), events + 1, "백오프 무시 조회 1회")
        XCTAssertNotEqual(h.lastSnapshot?.rows, [], "오버라이드가 풀려 Sidecar 줄을 다시 막는다")
    }

    func test_AC4_10c_retryWaiting_displayListChanged_resetsFailureCount_cancelsRetry_checking() {
        let h = drivingHarness("AC4_10c_retry")
        h.advance(2.3)
        XCTAssertEqual(h.pendingRetries, 1, "사전 조건")
        h.silentModes = [.event]
        h.fakes.displays.displays = DockPinFixtures.threeWithSidecar
        h.fakes.displayChanges.send(.screenParametersChanged)
        h.advance(0.6)
        XCTAssertEqual(h.pendingRetries, 0, "예약된 재시도 취소")
        XCTAssertEqual(h.manager.status, .checking)

        h.silentModes = []
        let before = h.moves.count
        h.fakes.locator.completePending(with: Fixture.onSidecar)
        XCTAssertGreaterThan(h.moves.count, before, "이벤트 계기로 다시 시도")
        h.advance(2.4)
        XCTAssertEqual(h.retryDelays, [1, 1], "실패 횟수가 0으로 초기화돼 다음 실패 뒤 다시 1초")
    }

    // MARK: - R4.4 / R4.5 / R5.8 매니저 수준 타이머

    func test_R4_4_noPermissionAndSingleDisplay_permissionPollAndFreshTrustCheck() {
        let h = harness("R4_4_np1")
        h.fakes.permission.trusted = false
        h.fakes.displays.displays = [Fixture.builtIn]
        h.start()
        XCTAssertEqual(h.manager.status, .needsPermission, "순위 2가 순위 3보다 먼저(N12)")
        XCTAssertEqual(h.fakes.scheduler.pendingRepeatingKinds, [.permissionPoll, .freshTrustCheck], "r5: R4.4 예외")
    }

    func test_R4_4_singleDisplayWithPermission_noRepeatingTimers() {
        let h = harness("R4_4_single")
        h.fakes.displays.displays = [Fixture.builtIn]
        h.start()
        XCTAssertEqual(h.manager.status, .inactive(.singleDisplay))
        XCTAssertEqual(h.fakes.scheduler.pendingRepeatingKinds, [])
        XCTAssertEqual(h.fakes.displayChanges.startCount, 1, "디스플레이 콜백은 남는다")
        XCTAssertEqual(h.fakes.systemEvents.startCount, 1, "알림 옵저버는 남는다")
    }


    /// 비활성(탭 없음) 동안 탭 스냅숏 갱신 0회
    func test_R4_4_inactive_tapStopped_neverUpdatesSnapshot() {
        let h = harness("R4_4_noUpdate")
        h.fakes.displays.displays = [Fixture.builtIn]
        h.start()
        XCTAssertEqual(h.manager.status, .inactive(.singleDisplay), "사전 조건")
        h.fakes.systemEvents.send(.appBecameActive)
        h.fakes.displayChanges.send(.screenParametersChanged)
        h.advance(5)
        XCTAssertFalse(h.fakes.tap.isRunning)
        XCTAssertEqual(h.fakes.tap.snapshots.count, 0, "탭이 없으면 update 0회")
    }

    func test_R4_5_spacesOff_prefsPollReadsOrientationAndPermission_notSpaces() {
        let h = harness("R4_5")
        h.fakes.dockPreferences.separateSpaces = false
        h.start()
        XCTAssertEqual(h.manager.status, .inactive(.spacesOff))
        XCTAssertEqual(h.fakes.scheduler.pendingRepeatingKinds, [.prefsPoll])
        XCTAssertEqual(h.fakes.tap.startCount, 0)
        let orientation = h.fakes.dockPreferences.orientationReadCount
        let checks = h.fakes.permission.checkCount
        let spaces = h.fakes.dockPreferences.spacesReadCount
        h.advance(3)
        XCTAssertEqual(h.fakes.dockPreferences.orientationReadCount, orientation + 1)
        XCTAssertEqual(h.fakes.permission.checkCount, checks + 1)
        XCTAssertEqual(h.fakes.dockPreferences.spacesReadCount, spaces, "prefsPoll은 Spaces를 읽지 않는다")
        XCTAssertEqual(h.fakes.locator.requests.count, 0, "창 조회 없음")

        h.fakes.dockPreferences.separateSpaces = true
        h.fakes.dockPreferences.orientationValue = .left
        h.advance(3)
        XCTAssertEqual(h.manager.status, .inactive(.spacesOff), "Spaces는 prefsPoll로 다시 읽지 않는다")
    }


    /// prefsPoll이 reconcile을 불러도 반복 타이머가 겹치지 않는다(종류당 1개)
    func test_R4_5_prefsPoll_reconcile_doesNotDuplicateRepeatingTimer() {
        let h = harness("R4_5_noDup")
        h.fakes.dockPreferences.separateSpaces = false
        h.start()
        XCTAssertEqual(h.manager.status, .inactive(.spacesOff), "사전 조건")
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.repeating(.prefsPoll)), 1)
        let orientation = h.fakes.dockPreferences.orientationReadCount
        h.advance(3)
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.repeating(.prefsPoll)), 1, "한 번 돈 뒤에도 1개")
        h.advance(3)
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.repeating(.prefsPoll)), 1, "두 번 돈 뒤에도 1개")
        XCTAssertEqual(h.fakes.dockPreferences.orientationReadCount, orientation + 2, "6 s 동안 3 s 주기 → 정확히 2회")
    }

    func test_R4_5_dockOnLeft_dockNotBottom_thenBottomReactivates() {
        let h = harness("R4_5_left")
        h.fakes.dockPreferences.orientationValue = .left
        h.start()
        XCTAssertEqual(h.manager.status, .inactive(.dockNotBottom(.left)))
        XCTAssertEqual(h.fakes.scheduler.pendingRepeatingKinds, [.prefsPoll])
        h.fakes.dockPreferences.orientationValue = .bottom
        h.advance(3)
        XCTAssertEqual(h.fakes.tap.startCount, 1)
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
    }

    func test_R4_5_appBecameActive_rereadsSpaces() {
        let h = harness("R4_5_appActive")
        h.fakes.dockPreferences.separateSpaces = false
        h.start()
        XCTAssertEqual(h.manager.status, .inactive(.spacesOff), "사전 조건")
        h.fakes.dockPreferences.separateSpaces = true
        h.fakes.systemEvents.send(.appBecameActive)
        XCTAssertEqual(h.fakes.tap.startCount, 1)
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
    }

    func test_R5_8_activeTapWatchdog_reenablesEvery2s() {
        let h = harness("R5_8")
        h.start()
        XCTAssertEqual(h.fakes.tap.reenableCount, 0)
        h.advance(2)
        XCTAssertEqual(h.fakes.tap.reenableCount, 1)
        h.advance(2)
        XCTAssertEqual(h.fakes.tap.reenableCount, 2)
    }

    // MARK: - AC5.11 탭 생성 실패

    func test_AC5_11_tapStartFails_tapFailed_retries1_2_5_10_30_30_thenStopsOnSuccess() {
        let h = harness("AC5_11")
        h.fakes.tap.startSucceeds = false
        h.start()
        XCTAssertEqual(h.manager.status, .tapFailed(attempt: 1), "\"Dock 고정됨\"으로 보이지 않는다(B2)")
        XCTAssertEqual(h.fakes.scheduler.pendingRepeatingKinds, [.permissionPoll, .tapRetry])
        for delay in [1.0, 2, 5, 10, 30, 30] { h.advance(delay) }
        XCTAssertEqual(Array(h.fakes.scheduler.scheduledDelays(.repeating(.tapRetry)).prefix(6)), [1, 2, 5, 10, 30, 30])
        XCTAssertEqual(h.fakes.tap.startCount, 7)
        XCTAssertEqual(h.manager.status, .tapFailed(attempt: 7))

        h.fakes.tap.startSucceeds = true
        h.advance(30)
        XCTAssertEqual(h.fakes.tap.startCount, 8)
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.repeating(.tapRetry)), 0, "성공하면 재시도가 멈춘다")
        XCTAssertEqual(h.fakes.scheduler.pendingRepeatingKinds, [.permissionPoll, .dockPoll, .tapWatchdog, .freshTrustCheck])
        if case .tapFailed = h.manager.status { XCTFail("성공 뒤 .tapFailed가 아니어야 한다") }
        let scheduled = h.fakes.scheduler.scheduledDelays(.repeating(.tapRetry)).count
        h.advance(60)
        XCTAssertEqual(h.fakes.scheduler.scheduledDelays(.repeating(.tapRetry)).count, scheduled)
        XCTAssertEqual(h.fakes.tap.startCount, 8)
    }

    // MARK: - AC7.5 Option 통과

    func test_AC7_5_optionPassSignal_schedulesChecksAt0_5_1_2() {
        let h = harness("AC7_5")
        h.start()
        let quick = h.requestCount(.quick)
        h.fakes.tap.emitOptionPass(Fixture.sidecar.id, at: h.now)
        XCTAssertGreaterThanOrEqual(h.fakes.tap.drainCount, 1, "알림을 받으면 신호 상자를 비운다")
        XCTAssertEqual(h.fakes.scheduler.scheduledDelays(.optionCheck), [0.5, 1.0, 2.0])
        h.advance(2.0)
        XCTAssertEqual(h.requestCount(.quick), quick + 3, "확인 3회")
    }

    // MARK: - 되돌리기 조정 (AC8.x)

    func test_I9_activationScanIsEventMode_driveStartsWithSnapshotFlags() {
        let h = drivingHarness("I9")
        XCTAssertEqual(h.fakes.locator.requests.first, .event, "활성화 직후 첫 조회는 백오프 무시(.event)")
        XCTAssertEqual(h.lastSnapshot?.isDriving, true)
        XCTAssertEqual(h.lastSnapshot?.isRelocating, true)
        XCTAssertEqual(h.lastSnapshot?.rows, [Fixture.sidecarRow], "되돌리는 중에도 트리거 줄은 그대로(P1)")
    }

    // MARK: - VULN-002 되돌리기 시한

    func test_VULN002_tuning_relocationGuardWindow_isApproachPlusTimeoutsPlusMargin_atMost4s() {
        let approach = Double(DockPinDrivePath.approach(to: .zero).count) * DockPinTuning.driveInterval
        XCTAssertEqual(approach, 0.24, accuracy: 1e-9, "다가가기 15점 × 16 ms")
        XCTAssertEqual(DockPinTuning.relocationDeadlineMargin, 0.5)
        XCTAssertEqual(DockPinTuning.relocationGuardWindow,
                       approach + DockPinTuning.relocationTimeout + DockPinTuning.finalScanTimeout
                       + DockPinTuning.relocationDeadlineMargin, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(DockPinTuning.relocationGuardWindow, 4.0, "입력 차단 상한 ≈ 3.94 s")
    }

    func test_VULN002_manager_driveStartSnapshot_hasDeadlineOnSchedulerClock() throws {
        let h = drivingHarness("VULN002_start")
        let startedAt = h.now                              // 활성화 직후 동기로 시작했다(시계 진행 없음)
        let snapshot = try XCTUnwrap(h.lastSnapshot)
        XCTAssertTrue(snapshot.isDriving)
        let deadline = try XCTUnwrap(snapshot.relocationDeadline, "driving 스냅숏은 시한을 가진다")
        XCTAssertEqual(deadline, startedAt + DockPinTuning.relocationGuardWindow, accuracy: 1e-9)

        // 메인이 멈춰 스냅숏이 그대로여도 탭 시계로 시한이 지나면 클릭·스크롤이 통과한다
        // (r6.6) NEW-1 — 버리지는 않되 사용자 입력 신호는 낸다
        var suppression = DockPinGestureSuppression()
        let click = DockPinEdgeRule.decide(type: .leftMouseDown, location: CGPoint(x: 864, y: 1116), flags: [],
                                           userData: 0, buttonNumber: 0, snapshot: snapshot,
                                           now: deadline + 0.001, suppression: &suppression)
        XCTAssertEqual(click, .pass(signal: .userActivity))
        let scroll = DockPinEdgeRule.decide(type: .scrollWheel, location: CGPoint(x: 864, y: 1116), flags: [],
                                            userData: 0, buttonNumber: 0, snapshot: snapshot,
                                            now: deadline + 0.001, suppression: &suppression)
        XCTAssertEqual(scroll, .pass(signal: .userActivity))
    }

    func test_VULN002_manager_deadlineKeptThroughVerifying_clearedWhenDriveEnds() throws {
        let h = drivingHarness("VULN002_end")
        let deadline = try XCTUnwrap(h.lastSnapshot?.relocationDeadline)
        var relocatorConfirmed = false
        h.custom = { mode in
            if relocatorConfirmed { return nil }
            if mode == .quick { relocatorConfirmed = true; return Fixture.onBuiltIn }
            return Fixture.onSidecar
        }
        h.advance(0.5)
        XCTAssertEqual(h.lastSnapshot?.isDriving, false, "사전 조건: verifying")
        XCTAssertEqual(h.lastSnapshot?.isRelocating, true)
        XCTAssertEqual(h.lastSnapshot?.relocationDeadline, deadline, "verifying 동안 같은 시한")

        h.custom = nil
        h.fakes.locator.completePending(with: Fixture.onBuiltIn)
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
        XCTAssertEqual(h.lastSnapshot?.isRelocating, false)
        XCTAssertNil(h.lastSnapshot?.relocationDeadline, "되돌리기가 끝나면 시한 nil")
    }

    func test_VULN002_manager_userActivityAbort_clearsDeadline() {
        let h = drivingHarness("VULN002_abort")
        XCTAssertNotNil(h.lastSnapshot?.relocationDeadline)
        h.fakes.tap.userActivityCount += 1
        h.advance(Fixture.tick)
        XCTAssertEqual(h.manager.status, .waiting(.userActive, displayName: Fixture.builtIn.name))
        XCTAssertEqual(h.lastSnapshot?.isDriving, false)
        XCTAssertNil(h.lastSnapshot?.relocationDeadline)
    }

    // MARK: - (r6.6) NEW-1 시한 뒤 입력도 되돌리기를 멈춘다 / 실행기 벽시계 상한

    /// 탭 스레드처럼: 마지막 스냅숏으로 판정해 .userActivity 신호면 가짜 탭 카운터를 올린다
    private func feedTap(_ h: Harness, _ type: CGEventType, at location: CGPoint, now: TimeInterval) -> DockPinTapDecision? {
        guard let snapshot = h.lastSnapshot else { return nil }
        var suppression = DockPinGestureSuppression()
        let decision = DockPinEdgeRule.decide(type: type, location: location, flags: [], userData: 0, buttonNumber: 0,
                                              snapshot: snapshot, now: now, suppression: &suppression)
        if decision.signal == .userActivity { h.fakes.tap.userActivityCount += 1 }
        return decision
    }

    func test_NEW1_manager_userClickAfterDeadline_stillAbortsDriveAtNextTick() throws {
        let h = drivingHarness("NEW1_click")
        let deadline = try XCTUnwrap(h.lastSnapshot?.relocationDeadline)
        h.advance(0.1)
        let movesBefore = h.moves.count

        // 메인이 멈춘 사이 시한이 지났고, 그때 사용자가 클릭했다(스냅숏은 driving 그대로)
        h.fakes.scheduler.now = deadline + 0.01
        let decision = feedTap(h, .leftMouseDown, at: CGPoint(x: 864, y: 1116), now: deadline + 0.01)
        XCTAssertEqual(decision, .pass(signal: .userActivity), "클릭은 통과하되 신호를 낸다")

        h.advance(0)    // 메인이 깨어나 밀린 틱을 돈다(밀린 다른 타이머도 함께 돌 수 있다)
        XCTAssertTrue(h.statusHistory.contains(.waiting(.userActive, displayName: Fixture.builtIn.name)),
                      "R8.6 — 시한 뒤 입력도 사용자 활동 중단")
        XCTAssertGreaterThan(h.moves.count, movesBefore)
        if h.moves.count > movesBefore {
            XCTAssertEqual(h.moves[movesBefore], Fixture.cursorOnBuiltIn, "밀린 틱은 이동 없이 바로 복원")
        }
        XCTAssertEqual(h.retryDelays, [], "사용자 활동 중단은 실패로 세지 않는다(상한 실패가 아니다)")
    }

    func test_NEW1_manager_userMoveAfterDeadline_stillAbortsDrive() throws {
        let h = drivingHarness("NEW1_move")
        let deadline = try XCTUnwrap(h.lastSnapshot?.relocationDeadline)
        h.advance(0.1)
        h.fakes.scheduler.now = deadline + 0.01
        XCTAssertEqual(feedTap(h, .mouseMoved, at: Fixture.cursorOnBuiltIn, now: deadline + 0.01),
                       .pass(signal: .userActivity))
        let movesBefore = h.moves.count
        h.advance(0)
        XCTAssertTrue(h.statusHistory.contains(.waiting(.userActive, displayName: Fixture.builtIn.name)))
        if h.moves.count > movesBefore { XCTAssertEqual(h.moves[movesBefore], Fixture.cursorOnBuiltIn) }
        XCTAssertEqual(h.retryDelays, [])
    }

    func test_NEW1_manager_relocatorLimit_sharesSnapshotDeadlineBasis_failsBeforeDeadline() throws {
        let h = drivingHarness("NEW1_limit")
        let deadline = try XCTUnwrap(h.lastSnapshot?.relocationDeadline)
        h.advance(0.1)
        let movesBefore = h.moves.count

        // 입력 없이 메인만 늦었다 — 실행기 상한(시한 − 여유)을 넘긴 뒤 틱
        h.fakes.scheduler.now = deadline - DockPinTuning.relocationDeadlineMargin + 0.01
        h.advance(0)

        XCTAssertEqual(h.retryDelays, [DockPinTuning.retryDelays[0]], "시간 초과처럼 실패 1회 → 재시도 예약")
        XCTAssertEqual(h.moves.count, movesBefore + 1, "더 보낸 이동은 복원 1번뿐")
        XCTAssertEqual(h.moves.last, Fixture.cursorOnBuiltIn)
        XCTAssertEqual(h.lastSnapshot?.isRelocating, false)
        XCTAssertNil(h.lastSnapshot?.relocationDeadline)
    }

    func test_NEW1_manager_atRelocatorLimitMinusEpsilon_driveContinues() throws {
        let h = drivingHarness("NEW1_limit_edge")
        let deadline = try XCTUnwrap(h.lastSnapshot?.relocationDeadline)
        h.silentModes = [.final]    // 유지 구간이 끝나 마지막 조회를 요청하되 응답은 없다
        h.advance(0.1)
        h.fakes.scheduler.now = deadline - DockPinTuning.relocationDeadlineMargin - 0.01
        h.advance(0)
        XCTAssertEqual(h.manager.status, .relocating(displayName: Fixture.builtIn.name), "상한 전에는 계속")
        XCTAssertEqual(h.retryDelays, [])
    }

    func test_AC8_3_manager_dockReturnsDuringDrive_verifiesThenPinned_restoresLast() {
        let h = drivingHarness("AC8_3")
        h.advance(0.5)
        h.dockOn = Fixture.builtIn.id
        h.advance(0.3)
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
        XCTAssertEqual(h.moves.last, Fixture.cursorOnBuiltIn, "마지막 이벤트는 저장 위치로의 복원")
        XCTAssertEqual(h.retryDelays, [])
        XCTAssertEqual(h.lastSnapshot?.isRelocating, false)
        let count = h.moves.count
        h.advance(3.5)
        XCTAssertEqual(h.moves.count, count, "고정 화면이면 다시 움직이지 않는다")
    }

    func test_AC8_10_manager_verifyingSnapshot_isRelocatingOnly() {
        let h = drivingHarness("AC8_10_verify")
        var relocatorConfirmed = false
        h.custom = { mode in
            if relocatorConfirmed { return nil }                    // 매니저의 확인 조회는 응답 보류
            if mode == .quick { relocatorConfirmed = true; return Fixture.onBuiltIn }
            return Fixture.onSidecar
        }
        h.advance(0.5)
        XCTAssertTrue(relocatorConfirmed, "사전 조건: Relocator의 단일 조회가 고정 화면을 받았다")
        XCTAssertEqual(h.lastSnapshot?.isRelocating, true, "verifying: isRelocating == true")
        XCTAssertEqual(h.lastSnapshot?.isDriving, false, "verifying: isDriving == false")
        XCTAssertEqual(h.manager.status, .relocating(displayName: Fixture.builtIn.name))

        h.custom = nil
        h.fakes.locator.completePending(with: Fixture.onBuiltIn)
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
        XCTAssertEqual(h.lastSnapshot?.isRelocating, false)
    }

    func test_AC8_10_manager_waitingSnapshot_bothFalse_thenDrivingBothTrue() {
        let h = harness("AC8_10_wait")
        h.dockOn = Fixture.sidecar.id
        h.fakes.session.idle = 0.1
        h.start()
        XCTAssertEqual(h.manager.status, .waiting(.userActive, displayName: Fixture.builtIn.name))
        XCTAssertTrue(h.moves.isEmpty, "P3: 최근 입력이 있으면 기다린다")
        XCTAssertEqual(h.lastSnapshot?.isRelocating, false)
        XCTAssertEqual(h.lastSnapshot?.isDriving, false)
        XCTAssertEqual(h.lastSnapshot?.rows, [Fixture.sidecarRow], "waiting 동안 줄 차단은 평소대로")

        h.fakes.session.idle = 10
        h.advance(0.5)                                     // waitRecheck
        XCTAssertEqual(h.moves.first, Fixture.firstApproach)
        XCTAssertEqual(h.lastSnapshot?.isDriving, true)
        XCTAssertEqual(h.lastSnapshot?.isRelocating, true)
    }

    func test_AC8_4c_manager_finalPending_isDrivingSnapshot_dropsClick_userActivityAbortsToWaiting() throws {
        let h = drivingHarness("AC8_4c_activity")
        h.silentModes = [.final]
        h.advance(Fixture.finalAt + 0.05)
        XCTAssertEqual(h.requestCount(.final), 1, "사전 조건: 마지막 전체 조회 요청")
        let atFinal = h.moves.count
        h.advance(0.5)                                     // 2.0–3.2 s 구간
        XCTAssertEqual(h.moves.count, atFinal, "이동 이벤트 0개")
        let snapshot = try XCTUnwrap(h.lastSnapshot)
        XCTAssertTrue(snapshot.isDriving, "마지막 조회 대기 중에도 driving 유지(N9)")
        var suppression = DockPinGestureSuppression()
        let decision = DockPinEdgeRule.decide(type: .leftMouseDown, location: CGPoint(x: 864, y: 1116), flags: [],
                                              userData: 0, buttonNumber: 0, snapshot: snapshot, now: h.now,
                                              suppression: &suppression)
        XCTAssertEqual(decision, .drop(signal: .userActivity), "D1: 그 스냅숏으로 클릭을 버린다")

        h.fakes.tap.userActivityCount += 1
        h.advance(Fixture.tick)
        XCTAssertEqual(h.moves.count, atFinal + 1, "그 틱에 복원 1회")
        XCTAssertEqual(h.moves.last, Fixture.cursorOnBuiltIn)
        XCTAssertEqual(h.retryDelays, [], "실패 횟수가 늘지 않는다")
        XCTAssertEqual(h.manager.status, .waiting(.userActive, displayName: Fixture.builtIn.name))
        let times = h.fakes.poster.moveTimes
        if let first = times.first, let last = times.last {
            XCTAssertLessThanOrEqual(last - first, 3.5, "커서 이탈 상한 3.5 s")
        } else {
            XCTFail("이동 시각 기록 없음")
        }
    }

    func test_AC8_4c_manager_finalNoResponse_failsAt3_2s_restoresOnce_schedulesRetry() {
        let h = drivingHarness("AC8_4c_timeout")
        h.silentModes = [.final]
        h.advance(Fixture.finalAt + 0.05)
        let atFinal = h.moves.count
        h.advance(1.1)                                     // 시간 초과 직전
        XCTAssertEqual(h.moves.count, atFinal, "2.0–3.2 s 사이 이동 0개")
        XCTAssertEqual(h.lastSnapshot?.isDriving, true)
        XCTAssertEqual(h.retryDelays, [])
        h.advance(0.1)                                     // t0+3.424 시간 초과 지남
        XCTAssertEqual(h.moves.count, atFinal + 1, "실패 판정 뒤 복원 1회")
        XCTAssertEqual(h.moves.last, Fixture.cursorOnBuiltIn)
        XCTAssertEqual(h.retryDelays, [1], "실패 1회 → 1초 뒤 재시도")
        XCTAssertEqual(h.lastSnapshot?.isDriving, false)
        let times = h.fakes.poster.moveTimes
        if let first = times.first, let last = times.last {
            XCTAssertLessThanOrEqual(last - first, 3.5)
        } else {
            XCTFail("이동 시각 기록 없음")
        }
    }

    func test_AC8_5_manager_userActivityDuringApproach_stopsRestoresOnce_waitingUserActive() {
        let h = drivingHarness("AC8_5")
        h.advance(Fixture.tick * 3)
        let before = h.moves.count
        h.fakes.tap.userActivityCount += 1
        h.advance(Fixture.tick)
        XCTAssertEqual(h.moves.count, before + 1, "다음 틱에 복원 1회")
        XCTAssertEqual(h.moves.last, Fixture.cursorOnBuiltIn)
        h.advance(0.3)                                     // waitRecheck(0.5 s) 전
        XCTAssertEqual(h.moves.count, before + 1, "그 뒤 이동 0개")
        XCTAssertEqual(h.retryDelays, [])
        XCTAssertEqual(h.manager.status, .waiting(.userActive, displayName: Fixture.builtIn.name))
        XCTAssertEqual(h.lastSnapshot?.isRelocating, false)
    }


    /// 사용자 입력 중단은 실패 횟수에 넣지 않는다: 그 뒤 첫 실패의 재시도는 1 s
    func test_AC8_5_userActivityAbort_thenFailure_firstRetryDelayIs1s() {
        let h = drivingHarness("AC8_5_count")
        h.advance(Fixture.tick * 3)
        h.fakes.tap.userActivityCount += 1
        h.advance(Fixture.tick)
        XCTAssertEqual(h.manager.status, .waiting(.userActive, displayName: Fixture.builtIn.name), "사전 조건: 입력으로 중단")
        let afterAbort = h.moves.count
        h.advance(0.5)                                     // waitRecheck → 다시 시도
        XCTAssertGreaterThan(h.moves.count, afterAbort, "사전 조건: 다시 시도")
        h.advance(2.4)                                     // Dock은 Sidecar 그대로 → 실패
        XCTAssertEqual(h.retryDelays, [1], "중단이 횟수에 들어가지 않았으므로 첫 실패 뒤 1초(3초 아님)")
    }

    // MARK: - r6.4 (VULN-004) 사용자 입력 중단 연속 → 필요한 유휴 시간 0.5 → 2 → 5 → 15 s(상한)

    /// 되돌리는 중에 사용자 입력으로 중단시킨다(사전 조건 단정 포함)
    private func abortByUserActivity(_ h: Harness, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(h.manager.status, .relocating(displayName: Fixture.builtIn.name),
                       "사전 조건: 되돌리는 중", file: file, line: line)
        h.fakes.tap.userActivityCount += 1
        h.advance(Fixture.tick)
        XCTAssertEqual(h.manager.status, .waiting(.userActive, displayName: Fixture.builtIn.name),
                       "사전 조건: 입력으로 중단", file: file, line: line)
    }

    /// 유휴가 required 바로 밑이면 기다리고, required가 되면 다시 시도한다
    private func assertRequiresIdle(_ h: Harness, _ required: TimeInterval,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let before = h.moves.count
        h.fakes.session.idle = required - 0.1
        h.advance(DockPinTuning.waitRecheckInterval)
        XCTAssertEqual(h.moves.count, before, "유휴 \(required - 0.1) s면 아직 기다린다", file: file, line: line)
        XCTAssertEqual(h.manager.status, .waiting(.userActive, displayName: Fixture.builtIn.name), file: file, line: line)
        h.fakes.session.idle = required
        h.advance(DockPinTuning.waitRecheckInterval)
        XCTAssertGreaterThan(h.moves.count, before, "유휴 \(required) s면 다시 시도", file: file, line: line)
        XCTAssertEqual(h.manager.status, .relocating(displayName: Fixture.builtIn.name), file: file, line: line)
    }

    func test_VULN004_consecutiveUserActivityAborts_escalateRequiredIdle_2_5_15_cap() {
        let h = drivingHarness("VULN004_escalate")
        for required in [2.0, 5, 15, 15] as [TimeInterval] {
            abortByUserActivity(h)
            assertRequiresIdle(h, required)
        }
        XCTAssertEqual(h.retryDelays, [], "입력 중단은 실패 횟수에 들어가지 않는다(AC8.5)")
    }

    func test_VULN004_dockConfirmedOnAnchor_resetsRequiredIdle() {
        let h = drivingHarness("VULN004_anchor")
        abortByUserActivity(h)
        assertRequiresIdle(h, 2)
        abortByUserActivity(h)
        assertRequiresIdle(h, 5)
        h.dockOn = Fixture.builtIn.id                      // 이번 되돌리기는 성공
        h.advance(0.8)                                     // 목표 줄 도달(0.224) 뒤 확인 조회
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name), "사전 조건: 고정 화면에서 확인")

        h.dockOn = Fixture.sidecar.id                      // 다시 다른 화면으로 넘어감
        h.fakes.session.idle = 0.6
        let before = h.moves.count
        h.advance(3.1)                                     // dockPoll이 Sidecar를 본다
        XCTAssertGreaterThan(h.moves.count, before, "고정 확인으로 횟수 0 → P3(0.5 s)면 다시 시도")
        XCTAssertEqual(h.moves.dropFirst(before).first, Fixture.firstApproach, "새 되돌리기의 다가가기 첫 점")
    }

    func test_VULN004_moveBackNow_resetsRequiredIdle() {
        let h = drivingHarness("VULN004_moveBack")
        abortByUserActivity(h)
        assertRequiresIdle(h, 2)
        abortByUserActivity(h)
        assertRequiresIdle(h, 5)
        abortByUserActivity(h)                             // 이제 15 s 필요
        h.fakes.session.idle = 0.6
        h.advance(DockPinTuning.waitRecheckInterval)
        let before = h.moves.count
        XCTAssertEqual(h.manager.status, .waiting(.userActive, displayName: Fixture.builtIn.name), "사전 조건: 기다리는 중")
        h.manager.moveBackNow()
        XCTAssertGreaterThan(h.moves.count, before, "지금 되돌리기(이벤트 계기) → 횟수 0 → 0.6 s 유휴로 시작")
        XCTAssertEqual(h.manager.status, .relocating(displayName: Fixture.builtIn.name))
    }

    func test_VULN004_displayConfigChange_resetsRequiredIdle() {
        let h = drivingHarness("VULN004_config")
        abortByUserActivity(h)
        assertRequiresIdle(h, 2)
        abortByUserActivity(h)                             // 이제 5 s 필요
        h.fakes.session.idle = 0.6
        h.advance(DockPinTuning.waitRecheckInterval)
        let before = h.moves.count
        XCTAssertEqual(h.moves.count, before)
        h.fakes.displays.displays = DockPinFixtures.threeWithSidecar
        h.fakes.displayChanges.send(.screenParametersChanged)
        h.advance(0.5)
        XCTAssertGreaterThan(h.moves.count, before, "구성 변경(이벤트 계기) → 횟수 0 → 0.6 s 유휴로 시작")
        XCTAssertEqual(h.manager.status, .relocating(displayName: Fixture.builtIn.name))
    }

    func test_AC8_6_retrySchedule_1_3_10_thenFailed4_noMoreSchedules() {
        let h = drivingHarness("AC8_6")
        h.advance(2.3)
        XCTAssertEqual(h.retryDelays, [1])
        h.advance(22.7)                                    // t0+25: 4차 실패 t0+22.896
        XCTAssertEqual(h.retryDelays, [1, 3, 10])
        XCTAssertEqual(h.manager.status, .failed(attempts: 4))
        XCTAssertEqual(h.pendingRetries, 0, "4회 실패 뒤 예약 0개")
        XCTAssertEqual(h.requestCount(.final), 4, "시도 4번")
    }

    func test_AC8_7_failed_displayConfigChange_resetsCountAndRetries() {
        let h = failedFourTimesHarness("AC8_7")
        let before = h.moves.count
        h.fakes.displays.displays = DockPinFixtures.threeWithSidecar
        h.fakes.displayChanges.send(.screenParametersChanged)
        h.advance(0.5)
        XCTAssertGreaterThan(h.moves.count, before, "구성 변경(이벤트 계기) → 다시 시도")
        XCTAssertEqual(h.manager.status, .relocating(displayName: Fixture.builtIn.name))
        h.advance(2.3)
        XCTAssertEqual(h.retryDelays, [1, 3, 10, 1], "횟수 0으로 초기화 → 다음 실패 뒤 1초")
    }

    func test_AC8_7_failed_sameDisplaySignal_staysFailed() {
        let h = failedFourTimesHarness("AC8_7_same")
        let before = h.moves.count
        h.fakes.displayChanges.send(.screenParametersChanged)
        h.advance(0.6)
        XCTAssertEqual(h.moves.count, before, "내용이 같은 신호는 이벤트 계기가 아니다(R4.8)")
        XCTAssertEqual(h.manager.status, .failed(attempts: 4))
    }

    func test_AC8_8_noFreeEdge_noEvents_status() {
        let h = harness("AC8_8")
        h.fakes.displays.displays = [Fixture.builtIn, Fixture.below]
        h.dockOn = Fixture.below.id
        h.start()
        XCTAssertEqual(h.fakes.tap.startCount, 1, "사전 조건: 활성")
        XCTAssertEqual(h.manager.status, .noFreeEdge(displayName: Fixture.builtIn.name))
        h.advance(6.1)
        h.manager.moveBackNow()
        h.advance(1)
        XCTAssertTrue(h.moves.isEmpty, "전송 이벤트 0개")
        XCTAssertEqual(h.manager.status, .noFreeEdge(displayName: Fixture.builtIn.name))
    }

    func test_AC8_9_manager_activeDisplaysZeroAtAbort_noRestoreEvent() {
        let h = drivingHarness("AC8_9_zero")
        h.advance(0.1)
        let before = h.moves.count
        h.fakes.displays.displays = []
        h.fakes.displayChanges.send(.reconfigured)
        XCTAssertEqual(h.moves.count, before, "다시 읽은 활성 디스플레이 0대 → 복원 이벤트 0개")
        h.advance(0.1)
        XCTAssertEqual(h.moves.count, before, "이동도 멈췄다")
        XCTAssertGreaterThanOrEqual(h.fakes.displays.readCount, 2, "복원 시점에 디스플레이를 다시 읽는다")
    }

    func test_AC8_11b_failed4_dockPollResultsOtherDisplay_noEvents() {
        let h = failedFourTimesHarness("AC8_11b")
        let before = h.moves.count
        let quick = h.requestCount(.quick)
        h.advance(30)
        XCTAssertGreaterThan(h.requestCount(.quick), quick, "사전 조건: dockPoll 위치 결과가 들어왔다")
        XCTAssertEqual(h.moves.count, before, "전송 이벤트 0개(.skip(.failedUntilEvent))")
        XCTAssertEqual(h.manager.status, .failed(attempts: 4))
    }

    func test_AC8_11c_retryWaiting_dockPollDoesNotStart_retryTimerDoes() {
        let h = drivingHarness("AC8_11c")
        h.advance(2.3)                                     // 1차 실패, 재시도 t0+3.224
        let afterFail = h.moves.count
        let quick = h.requestCount(.quick)
        h.advance(0.9)                                     // t0+3.2 — dockPoll(t0+3) 지남
        XCTAssertGreaterThan(h.requestCount(.quick), quick, "사전 조건: dockPoll 위치 결과가 들어왔다")
        XCTAssertEqual(h.moves.count, afterFail, "재시도 대기 중 .poll은 시작하지 못한다")
        h.advance(0.1)                                     // t0+3.3 — 재시도 타이머 지남
        XCTAssertGreaterThan(h.moves.count, afterFail, "재시도 타이머가 울릴 때 시도 시작")
    }

    func test_AC8_12_failed4_anchorConfirmed_pinned_countReset() {
        let h = failedFourTimesHarness("AC8_12_failed")
        h.dockOn = Fixture.builtIn.id
        h.advance(3.1)                                     // dockPoll
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
        h.dockOn = Fixture.sidecar.id
        h.advance(5.5)                                     // 다음 dockPoll → 시도 → 실패
        XCTAssertEqual(h.retryDelays, [1, 3, 10, 1], "실패 횟수 0에서 다시 시작")
    }

    func test_AC8_12_retryWaiting_anchorConfirmed_cancelsRetry_countReset() {
        let h = drivingHarness("AC8_12_retry")
        h.advance(2.3)
        XCTAssertEqual(h.pendingRetries, 1, "사전 조건")
        h.dockOn = Fixture.builtIn.id
        h.advance(0.8)                                     // dockPoll t0+3 (재시도 t0+3.224 전)
        XCTAssertEqual(h.pendingRetries, 0, "예약된 재시도 0개")
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
        h.dockOn = Fixture.sidecar.id
        h.advance(5.5)                                     // dockPoll t0+6 → 시도 → 실패 t0+8.224
        XCTAssertEqual(h.retryDelays, [1, 1], "실패 횟수 0에서 다시 시작")
    }

    // MARK: - R8.8 지금 되돌리기 / arch I2·I4 / R6.1

    func test_R8_8_moveBackNow_fromOverride_releasesAndRelocates() {
        let h = overrideHarness("R8_8_override")
        let events = h.requestCount(.event)
        h.manager.moveBackNow()
        XCTAssertEqual(h.requestCount(.event), events + 1, "백오프 무시 조회")
        XCTAssertEqual(h.moves.first, Fixture.firstApproach, "오버라이드를 끄고 되돌리기 시작")
        XCTAssertEqual(h.manager.status, .relocating(displayName: Fixture.builtIn.name))
    }


    /// 오버라이드를 푼 뒤 다른 화면의 Option 통과가 와도 옛 화면의 남은 탭 칸을 다시 합치지 않는다
    func test_R8_8_moveBackNow_thenOptionPassOnOtherDisplay_doesNotRevivePriorOverride() {
        let h = overrideHarness("R8_8_floor")
        h.manager.moveBackNow()
        XCTAssertEqual(h.manager.status, .relocating(displayName: Fixture.builtIn.name), "사전 조건: 오버라이드 해제 후 되돌리는 중")
        h.fakes.tap.emitOptionPass(Fixture.builtIn.id, at: h.now)   // 탭의 Sidecar 칸(t0+1)은 그대로 남아 있다
        h.advance(0.6)                                     // Option 확인 0.5 s — Dock은 아직 Sidecar
        XCTAssertEqual(h.lastSnapshot?.rows, [Fixture.sidecarRow], "Sidecar 오버라이드가 되살아나지 않아 줄을 계속 막는다")
        h.advance(2.0)                                     // 되돌리기 실패(.final) → 재시도 예약
        XCTAssertNotEqual(h.manager.status, .movedByUser(displayName: Fixture.sidecar.name), "옛 화면 오버라이드 없음")
        XCTAssertEqual(h.retryDelays, [1], "실패로 처리돼 재시도 1초")
    }

    func test_R8_8_moveBackNow_dockNotFound_rescans() {
        let h = harness("R8_8_notFound")
        h.dockOn = nil
        h.start()
        XCTAssertEqual(h.manager.status, .dockNotFound)
        let events = h.requestCount(.event)
        h.manager.moveBackNow()
        XCTAssertEqual(h.requestCount(.event), events + 1)
    }

    func test_R8_8_moveBackNow_whenInactive_doesNothing() {
        let h = harness("R8_8_inactive")
        h.fakes.displays.displays = [Fixture.builtIn]
        h.start()
        XCTAssertEqual(h.manager.status, .inactive(.singleDisplay), "사전 조건")
        h.manager.moveBackNow()
        XCTAssertEqual(h.fakes.locator.requests.count, 0)
        XCTAssertTrue(h.moves.isEmpty)
    }

    func test_R8_8_moveBackNow_whileDriving_ignored() {
        let h = drivingHarness("R8_8_driving")
        let events = h.requestCount(.event)
        h.manager.moveBackNow()
        XCTAssertEqual(h.requestCount(.event), events, "되돌리는 중에는 무시")
        XCTAssertEqual(h.manager.status, .relocating(displayName: Fixture.builtIn.name))
    }

    func test_I2_setTarget_recomputesImmediately_newAnchorChecking_thenRelocatesToIt() {
        let h = harness("I2")
        h.start()
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name), "사전 조건")
        h.silentModes = [.event]
        let events = h.requestCount(.event)
        h.manager.setTarget(.display(uuid: DockPinFixtures.sidecarUUID), displayName: Fixture.sidecar.name)
        XCTAssertEqual(h.manager.status, .checking, "디바운스 없이 새 고정 화면 기준으로 다시 계산")
        XCTAssertEqual(h.requestCount(.event), events + 1)
        XCTAssertEqual(h.lastSnapshot?.rows,
                       [DockPinTriggerRow(displayID: 1, minX: 0, maxX: 1728, minY: 1116, maxY: 1117)],
                       "AC3.11: 고정 화면이 Sidecar면 내장 화면 줄")

        h.silentModes = []
        h.fakes.locator.completePending(with: Fixture.onBuiltIn)
        XCTAssertEqual(h.moves.first, Fixture.firstApproachToSidecar, "목표점 (2302.5, 801)로 다가간다")
        XCTAssertEqual(h.manager.status, .relocating(displayName: Fixture.sidecar.name))
    }

    func test_I4_drivingScreenParametersWithRealChange_abortsAtDebounce_thenEventRescan() {
        let h = drivingHarness("I4")
        h.fakes.displays.displays = DockPinFixtures.threeWithSidecar
        h.fakes.displayChanges.send(.screenParametersChanged)
        h.advance(0.1)
        XCTAssertFalse(h.moves.contains(Fixture.cursorOnBuiltIn), "디바운스 전에는 중단하지 않는다")
        let events = h.requestCount(.event)
        h.advance(0.45)
        XCTAssertTrue(h.moves.contains(Fixture.cursorOnBuiltIn), "구성 변경 인정 → 중단·복원")
        XCTAssertEqual(h.requestCount(.event), events + 1, "이벤트 계기로 다시 판정")
        XCTAssertEqual(h.retryDelays, [], "중단은 실패 횟수에 넣지 않는다")
    }

    func test_R6_1_dockRelaunched_invalidatesCache_eventScan() {
        let h = harness("R6_1")
        h.start()
        let events = h.requestCount(.event)
        h.fakes.systemEvents.send(.dockRelaunched)
        XCTAssertEqual(h.fakes.locator.invalidateCount, 1)
        XCTAssertEqual(h.requestCount(.event), events + 1)
    }

    // MARK: - AC9 권한

    func test_AC9_1_permissionLostWhileDriving_tapStopFirst_thenAbortRestore_thenStatus() {
        let h = drivingHarness("AC9_1")
        h.advance(0.5)
        h.fakes.log.clear()
        h.fakes.permission.trusted = false
        h.advance(0.6)                                     // permissionPoll t0+1
        let entries = h.fakes.log.entries
        guard let stopIndex = entries.firstIndex(of: "tap.stop") else {
            return XCTFail("tap.stop 기록 없음: \(entries)")
        }
        let after = entries[(stopIndex + 1)...]
        XCTAssertEqual(after.filter { $0 == "move" }.count, 1, "stop 뒤에는 복원 이동 1개뿐(되돌리기 중단이 stop보다 뒤)")
        XCTAssertTrue(after.contains("status:needsPermission"), "상태 변경이 stop보다 뒤")
        XCTAssertFalse(entries[..<stopIndex].contains("status:needsPermission"))
        XCTAssertEqual(h.moves.last, Fixture.cursorOnBuiltIn, "복원 이벤트는 보낸다(R8.5 예외 2)")
        XCTAssertEqual(h.manager.status, .needsPermission)
        XCTAssertEqual(h.fakes.tap.stopCount, 1)
    }

    func test_AC9_2_disabled_noPermissionPoll_noChecks() {
        let h = harness("AC9_2", enabled: false)
        h.start()
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.checkCount, 0)
        XCTAssertEqual(h.fakes.scheduler.pendingRepeatingKinds, [])
        XCTAssertEqual(h.manager.status, .off)
        h.manager.setEnabled(true)
        XCTAssertTrue(h.fakes.scheduler.pendingRepeatingKinds.contains(.permissionPoll), "양성 짝: 켜면 권한 폴링")
    }

    func test_AC9_3_permissionGranted_tapStartsOnce() {
        let h = harness("AC9_3")
        h.fakes.permission.trusted = false
        h.start()
        XCTAssertEqual(h.manager.status, .needsPermission, "사전 조건")
        XCTAssertEqual(h.fakes.scheduler.pendingRepeatingKinds, [.permissionPoll, .freshTrustCheck])
        h.fakes.permission.trusted = true
        h.advance(1)
        XCTAssertEqual(h.fakes.tap.startCount, 1)
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
        XCTAssertEqual(h.fakes.permission.promptCount, 0)
    }

    // MARK: AC9.4 · AC9.5 (r5) — 권한 알림: 즉시 확인 없음, +1.0·+3.0초 재확인

    /// `permissionRecheck` 예약이 실행되며 권한을 읽은 시각(t0 기준 상대값). 폴링 틱 몫은 빼고 센다.
    private func recordRecheckReads(_ h: Harness, from t0: TimeInterval) -> () -> [TimeInterval] {
        var times: [TimeInterval] = []
        let scheduler = h.fakes.scheduler
        h.fakes.permission.onCheck = {
            if scheduler.currentKind == .permissionRecheck { times.append(scheduler.now - t0) }
        }
        return { times }
    }

    func test_AC9_4_accessibilityNotification_noCheckAtNotification_tapStopsAfterOneSecond() {
        let h = harness("AC9_4")
        h.start()
        XCTAssertTrue(h.fakes.tap.isRunning, "사전 조건")
        let checks = h.fakes.permission.checkCount
        h.fakes.log.clear()
        h.fakes.permission.trusted = false
        h.fakes.systemEvents.send(.accessibilityChanged)
        XCTAssertEqual(h.fakes.permission.checkCount, checks, "알림을 처리한 그 자리에서는 권한 확인 0회(R9.5 r5)")
        XCTAssertEqual(h.fakes.tap.stopCount, 0, "알림 순간에는 stop 0회")
        XCTAssertTrue(h.fakes.tap.isRunning)

        h.advance(1.0)
        XCTAssertEqual(h.fakes.tap.stopCount, 1, "+1.0초까지 stop 정확히 1회(폴링 틱이 먼저 와도 합계 1회)")
        XCTAssertFalse(h.fakes.tap.isRunning)
        XCTAssertEqual(h.manager.status, .needsPermission)
        let entries = h.fakes.log.entries
        guard let stopIndex = entries.firstIndex(of: "tap.stop") else {
            return XCTFail("tap.stop 기록 없음: \(entries)")
        }
        XCTAssertFalse(entries[..<stopIndex].contains("status:needsPermission"), "AC9.1 순서: stop이 상태 변경보다 먼저")
        h.advance(3.0)
        XCTAssertEqual(h.fakes.tap.stopCount, 1, "+3.0초 재확인도 stop을 더 부르지 않는다")
    }

    func test_AC9_5_accessibilityNotification_noImmediateCheck_schedulesOneAndThreeSeconds() {
        let h = harness("AC9_5")
        h.start()
        let checks = h.fakes.permission.checkCount
        h.fakes.systemEvents.send(.accessibilityChanged)
        XCTAssertEqual(h.fakes.permission.checkCount, checks, "즉시 확인 0회")
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.permissionRecheck), 2, "재확인 예약 2개")
        XCTAssertEqual(h.fakes.scheduler.scheduledDelays(.permissionRecheck), DockPinTuning.permissionNotifyRecheckDelays)
        XCTAssertEqual(h.fakes.scheduler.scheduledDelays(.permissionRecheck), [1.0, 3.0])
    }

    func test_AC9_5_accessibilityNotification_readsOnceAtPlusOneAndPlusThree() {
        let h = harness("AC9_5_reads")
        h.start()
        let reads = recordRecheckReads(h, from: h.now)
        h.fakes.systemEvents.send(.accessibilityChanged)
        h.advance(0.99)
        XCTAssertEqual(reads(), [], "+1.0초 전에는 재확인 읽기 없음")
        h.advance(0.01)
        XCTAssertEqual(reads().count, 1, "+1.0초에 1회")
        h.advance(1.99)
        XCTAssertEqual(reads().count, 1, "+3.0초 전에는 더 없음")
        h.advance(0.01)
        XCTAssertEqual(reads().count, 2, "+3.0초에 1회")
        for (actual, expected) in zip(reads(), [1.0, 3.0]) {
            XCTAssertEqual(actual, expected, accuracy: 1e-6)
        }
        h.advance(10)
        XCTAssertEqual(reads().count, 2, "그 뒤 재확인은 더 없다(폴링 틱 몫 제외)")
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.permissionRecheck), 0)
    }

    func test_AC9_5_secondNotificationAtHalfSecond_cancelsPending_reschedulesFromSecond() {
        let h = harness("AC9_5_renotify")
        h.start()
        let t0 = h.now
        h.fakes.systemEvents.send(.accessibilityChanged)
        h.advance(0.5)
        let checks = h.fakes.permission.checkCount
        let reads = recordRecheckReads(h, from: t0)
        h.fakes.systemEvents.send(.accessibilityChanged)
        XCTAssertEqual(h.fakes.permission.checkCount, checks, "두 번째 알림도 즉시 확인 0회")
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.permissionRecheck), 2,
                       "앞의 예약은 취소되고 두 번째 알림 기준 2개만 대기")
        XCTAssertEqual(h.fakes.scheduler.timeUntilNext(.permissionRecheck) ?? -1, 1.0, accuracy: 1e-6)
        h.advance(5)
        XCTAssertEqual(reads().count, 2, "취소된 첫 알림 예약(+1.0, +3.0)은 실행되지 않는다")
        for (actual, expected) in zip(reads(), [1.5, 3.5]) {
            XCTAssertEqual(actual, expected, accuracy: 1e-6, "첫 알림 기준 +1.5, +3.5")
        }
    }

    func test_AC9_5_disable_cancelsBothPendingRechecks() {
        let h = harness("AC9_5_teardown")
        h.start()
        h.fakes.systemEvents.send(.accessibilityChanged)
        h.manager.setEnabled(false)
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.permissionRecheck), 0, "정리 때 대기 중 재확인 모두 취소")
        let checks = h.fakes.permission.checkCount
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.checkCount, checks)
    }

    func test_AC9_5_grantNotification_reflectedAfterOneSecond_withoutRestart() {
        let h = harness("AC9_5_grant")
        h.fakes.permission.trusted = false
        h.start()
        XCTAssertEqual(h.manager.status, .needsPermission, "사전 조건")
        h.fakes.permission.trusted = true
        h.fakes.systemEvents.send(.accessibilityChanged)
        XCTAssertEqual(h.manager.status, .needsPermission, "알림 순간에는 읽지 않으므로 아직 그대로")
        XCTAssertEqual(h.fakes.tap.startCount, 0)
        h.advance(1.0)
        XCTAssertEqual(h.fakes.tap.startCount, 1, "+1.0초 뒤 탭 시작 1회(재시작 없이)")
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
        h.advance(3.0)
        XCTAssertEqual(h.fakes.tap.startCount, 1, "+3.0초 재확인은 추가 시작 없음")
    }

    /// r5 실기기 버그 회귀: 알림 순간 읽으면 tccd 기록 전의 낡은 false가 프로세스에 다시 캐시되어 영영 안 바뀐다.
    func test_AC9_5_regression_staleFalseIfReadAtNotificationInstant_endsTrusted() {
        let h = harness("AC9_5_regression")
        h.fakes.permission.trusted = false
        h.start()
        XCTAssertEqual(h.manager.status, .needsPermission, "사전 조건")

        var granted = false
        var atNotificationInstant = false
        var poisoned = false                    // 알림 순간 읽힘 → 낡은 false가 캐시됨(8분간 안 바뀐 증상)
        h.fakes.permission.respond = {
            if atNotificationInstant { poisoned = true }
            return granted && !poisoned
        }
        granted = true                          // 사용자가 시스템 설정에서 허용
        atNotificationInstant = true
        h.fakes.systemEvents.send(.accessibilityChanged)
        atNotificationInstant = false

        h.advance(3.5)
        XCTAssertFalse(poisoned, "알림 순간에 권한을 읽지 않아야 한다")
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name), "앱 재시작 없이 신뢰됨으로 끝난다")
        XCTAssertEqual(h.fakes.tap.startCount, 1)
    }

    // MARK: AC9.6 매니저부 (r5·r6, 커밋 11c) — 프로세스 판정 AND Dock AX 프로브

    // 매니저의 권한 읽기는 모두 DockPinPolicy.combinedTrust(process: isTrusted(), dockProbe: dockPID().map(probe))다.
    // 11c에서는 applyInProcess 단일 진입점이 아직 없다(11f). readAll·checkPermission·prefsPoll·디바운스 재계산이
    // 각자 이 결합 판정을 읽는다. 가짜 프로브 `dockProbe = false`는 kAXErrorAPIDisabled를 뜻한다.

    func test_AC9_6_manager_processTrueProbeFalse_atStart_needsPermission_noTap() {
        let h = harness("AC9_6_start")
        h.fakes.permission.dockProbe = false
        h.start()
        XCTAssertGreaterThanOrEqual(h.fakes.permission.probeCount, 1, "Dock PID가 있으면 시작 때 프로브를 부른다")
        XCTAssertEqual(h.manager.status, .needsPermission, "프로세스 true + 프로브 false → untrusted(R9.1 AND, X1 쪽)")
        XCTAssertEqual(h.fakes.tap.startCount, 0, "권한 없음이면 탭을 만들지 않는다")
        XCTAssertEqual(h.fakes.scheduler.pendingRepeatingKinds, [.permissionPoll, .freshTrustCheck])
        XCTAssertEqual(h.fakes.permission.promptCount, 0, "다시 시작할 때는 프롬프트 없음(R1.5)")
    }

    func test_AC9_6_manager_setEnabledTrue_processTrueProbeFalse_promptsOnce_needsPermission() {
        let h = harness("AC9_6_enable", enabled: false)
        h.fakes.permission.dockProbe = false
        h.manager.setEnabled(true)
        XCTAssertEqual(h.fakes.permission.promptCount, 1, "결합 판정이 untrusted면 켜는 순간 프롬프트 1회(R1.3)")
        XCTAssertEqual(h.manager.status, .needsPermission)
        XCTAssertEqual(h.fakes.tap.startCount, 0)
    }

    func test_AC9_6_manager_processTrueProbeTrue_trusted_probedWithCurrentDockPID() {
        let h = harness("AC9_6_pid")
        h.start()
        XCTAssertEqual(h.fakes.tap.startCount, 1, "양쪽 다 true면 trusted")
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
        XCTAssertEqual(h.fakes.permission.probedPIDs.last, DockPinFixtures.dockPID, "프로브는 현재 Dock PID로 부른다")

        let newPID: pid_t = DockPinFixtures.dockPID + 111            // Dock 재시작으로 PID가 바뀜
        h.fakes.dockPreferences.pid = newPID
        let probes = h.fakes.permission.probeCount
        h.advance(1)                                                 // permissionPoll
        XCTAssertGreaterThan(h.fakes.permission.probeCount, probes, "폴링 틱마다 프로브한다")
        XCTAssertEqual(h.fakes.permission.probedPIDs.last, newPID, "PID를 캐시하지 않고 매번 새로 읽은 PID를 쓴다")
        XCTAssertEqual(h.fakes.tap.stopCount, 0)
    }

    func test_AC9_6_manager_noDockPID_probeNotCalled_processAloneDecides() {
        let h = harness("AC9_6_noPID")
        h.fakes.dockPreferences.pid = nil
        h.fakes.permission.dockProbe = false          // 불리면 untrusted가 되므로 "안 불림"이 드러난다
        h.start()
        XCTAssertEqual(h.fakes.permission.probeCount, 0, "Dock PID가 없으면 프로브 0회")
        XCTAssertEqual(h.fakes.tap.startCount, 1, "프로세스 판정 true만으로 trusted")
        XCTAssertNotEqual(h.manager.status, .needsPermission)
        h.advance(1)
        XCTAssertEqual(h.fakes.permission.probeCount, 0, "폴링 틱에서도 프로브 0회")
        XCTAssertEqual(h.fakes.tap.stopCount, 0)

        h.fakes.dockPreferences.pid = DockPinFixtures.dockPID   // Dock이 다시 뜸 → 프로브가 판정에 들어온다
        h.advance(1)
        XCTAssertGreaterThanOrEqual(h.fakes.permission.probeCount, 1, "PID가 생기면 프로브한다")
        XCTAssertEqual(h.fakes.permission.probedPIDs.last, DockPinFixtures.dockPID)
        XCTAssertEqual(h.fakes.tap.stopCount, 1, "프로브 false → untrusted → 탭 제거")
        XCTAssertEqual(h.manager.status, .needsPermission)
    }

    func test_AC9_6_manager_noDockPID_processFalse_untrusted() {
        let h = harness("AC9_6_noPID_false")
        h.fakes.dockPreferences.pid = nil
        h.fakes.permission.trusted = false
        h.start()
        XCTAssertEqual(h.manager.status, .needsPermission, "(false, nil) → false")
        XCTAssertEqual(h.fakes.permission.probeCount, 0)
        XCTAssertEqual(h.fakes.tap.startCount, 0)
        h.fakes.permission.trusted = true
        h.advance(1)
        XCTAssertEqual(h.fakes.tap.startCount, 1, "(true, nil) → true")
        XCTAssertEqual(h.fakes.permission.probeCount, 0)
    }

    func test_AC9_6_manager_processFalseProbeTrue_untrusted_thenProcessTrueProbeFalse_stillUntrusted() {
        let h = harness("AC9_6_mixed")
        h.fakes.permission.trusted = false
        h.fakes.permission.dockProbe = true
        h.start()
        XCTAssertEqual(h.manager.status, .needsPermission, "(false, true) → false")
        XCTAssertEqual(h.fakes.tap.startCount, 0)

        h.fakes.permission.trusted = true
        h.fakes.permission.dockProbe = false
        h.advance(1)
        XCTAssertEqual(h.manager.status, .needsPermission, "(true, false) → false: 프로세스만 true로 바뀌어도 탭을 켜지 않는다")
        XCTAssertEqual(h.fakes.tap.startCount, 0)

        h.fakes.permission.dockProbe = true
        h.advance(1)
        XCTAssertEqual(h.fakes.tap.startCount, 1, "(true, true) → true가 되면 탭 시작 1회(R9.2)")
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
    }

    /// AC9.6 본문: 프로세스 판정 true + 프로브 false인 채 탭 실행 중에 폴링 틱 → stop 1회, .needsPermission
    func test_AC9_6_manager_probeFlipsFalse_processStillTrue_pollTick_stopsTap_needsPermission() {
        let h = harness("AC9_6_revoke")
        h.start()
        XCTAssertTrue(h.fakes.tap.isRunning, "사전 조건")
        h.fakes.permission.dockProbe = false               // 프로세스 안 AXIsProcessTrusted는 낡은 true 그대로
        h.advance(1)
        XCTAssertEqual(h.fakes.tap.stopCount, 1)
        XCTAssertFalse(h.fakes.tap.isRunning)
        XCTAssertEqual(h.manager.status, .needsPermission)
        XCTAssertTrue(h.fakes.permission.trusted, "프로세스 판정은 끝까지 true였다")
        h.advance(3)
        XCTAssertEqual(h.fakes.tap.stopCount, 1, "그 뒤 틱은 stop을 더 부르지 않는다")
    }

    /// 프로브로 감지한 철회도 R9.3 순서(탭 stop → 되돌리기 중단·복원 → 상태)를 지킨다(AC9.1과 같은 순서)
    func test_AC9_6_manager_probeRevokeWhileDriving_tapStopFirst_thenAbortRestore_thenStatus() {
        let h = drivingHarness("AC9_6_order")
        h.advance(0.5)
        h.fakes.log.clear()
        h.fakes.permission.dockProbe = false
        h.advance(0.6)                                     // permissionPoll t0+1
        let entries = h.fakes.log.entries
        guard let stopIndex = entries.firstIndex(of: "tap.stop") else {
            return XCTFail("tap.stop 기록 없음: \(entries)")
        }
        let after = entries[(stopIndex + 1)...]
        XCTAssertEqual(after.filter { $0 == "move" }.count, 1, "stop 뒤에는 복원 이동 1개뿐(되돌리기 중단이 stop보다 뒤)")
        XCTAssertTrue(after.contains("status:needsPermission"), "상태 변경이 stop보다 뒤")
        XCTAssertFalse(entries[..<stopIndex].contains("status:needsPermission"))
        XCTAssertEqual(h.moves.last, Fixture.cursorOnBuiltIn, "복원 이벤트는 보낸다(R8.5 예외 2)")
        XCTAssertEqual(h.manager.status, .needsPermission)
        XCTAssertEqual(h.fakes.tap.stopCount, 1)
    }

    func test_AC9_6_manager_prefsPoll_probeFalse_needsPermission() {
        let h = harness("AC9_6_prefsPoll")
        h.fakes.dockPreferences.separateSpaces = false
        h.start()
        XCTAssertEqual(h.manager.status, .inactive(.spacesOff), "사전 조건")
        h.fakes.permission.dockProbe = false
        h.advance(3)                                       // prefsPoll
        XCTAssertEqual(h.manager.status, .needsPermission, "prefsPoll의 권한 읽기도 결합 판정(R4.5·R9.1)")
    }

    func test_AC9_6_manager_debounceRecompute_probeFalse_needsPermission_noTapStart() {
        let h = harness("AC9_6_debounce")
        h.fakes.displays.displays = [Fixture.builtIn]
        h.start()
        XCTAssertEqual(h.manager.status, .inactive(.singleDisplay), "사전 조건")
        h.fakes.permission.dockProbe = false
        h.fakes.displays.displays = DockPinFixtures.thisMac
        h.fakes.displayChanges.send(.reconfigured)
        h.advance(0.5)
        XCTAssertEqual(h.fakes.tap.startCount, 0, "디바운스 재계산의 동기 읽기도 결합 판정이다")
        XCTAssertEqual(h.manager.status, .needsPermission)
    }

    /// 모든 권한 읽기 경로가 프로브를 거친다: 1초 폴링, R9.5 재확인(+1.0·+3.0), prefsPoll, 디바운스 재계산
    func test_AC9_6_manager_everyPermissionReadPath_probesDock() {
        let h = harness("AC9_6_paths")
        var kinds: [DockPinTimerKind?] = []
        let scheduler = h.fakes.scheduler
        h.fakes.permission.onProbe = { kinds.append(scheduler.currentKind) }
        h.start()
        XCTAssertTrue(kinds.contains(where: { $0 == nil }), "readAll(시작) 경로에서 프로브")

        kinds = []
        h.advance(1)
        XCTAssertTrue(kinds.contains(.repeating(.permissionPoll)), "1초 폴링 경로에서 프로브: \(kinds)")

        kinds = []
        h.fakes.systemEvents.send(.accessibilityChanged)
        h.advance(3.0)
        XCTAssertEqual(kinds.filter { $0 == .permissionRecheck }.count, 2, "R9.5 재확인 +1.0·+3.0에서 각 1회: \(kinds)")

        kinds = []
        h.fakes.displayChanges.send(.screenParametersChanged)
        h.advance(0.5)
        XCTAssertTrue(kinds.contains(.displayDebounce), "디바운스 재계산 경로에서 프로브: \(kinds)")

        kinds = []
        h.fakes.dockPreferences.orientationValue = .left       // .dockNotBottom → prefsPoll만 돈다
        h.fakes.displayChanges.send(.screenParametersChanged)
        h.advance(0.5)
        XCTAssertEqual(h.manager.status, .inactive(.dockNotBottom(.left)), "사전 조건")
        kinds = []
        h.advance(3)
        XCTAssertTrue(kinds.contains(.repeating(.prefsPoll)), "prefsPoll 경로에서 프로브: \(kinds)")
    }

    // MARK: AC9.8 a–c · AC9.9 · AC12.4 (r5·r6, 커밋 11e) — 새 프로세스 확인: 주기·시한·동시성·세대

    // 11e 범위: freshTrustCheck 5초 반복 타이머 → permission.freshTrustCheck 1회, 2초 시한(.freshTrustTimeout),
    // 한 번에 하나, 정리 때 세대 올림 + 토큰 cancel·nil(I13), N20 로그. applyFresh는 세대 확인과 로그만 하고
    // H(hasPermission)를 바꾸지 않았다(래치·적용은 11f). (11f) 결과 적용 단정은 7-2 래치 규칙으로 고쳤다
    // (test_11f_active_*, test_11f_needsPermission_*, test_AC9_8c_disableWhileInFlight_thenReEnable_*).
    // 가짜 확인은 기본 무응답(보류)이다. 활성화 = t0, 첫 확인 = t0+5, 그 시한 = t0+7, 다음 확인 = t0+10.

    /// AC9.9 — .active + 탭 실행 중: 5초마다 정확히 1회, 그 전에는 0회
    func test_AC9_9_active_freshCheckFiresEvery5s_exactlyOncePerTick() {
        let h = harness("AC9_9_active")
        h.start()
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name), "사전 조건")
        XCTAssertEqual(h.fakes.permission.freshCount, 0, "시작 순간에는 확인하지 않는다(주기 타이머만)")
        h.advance(4.9)
        XCTAssertEqual(h.fakes.permission.freshCount, 0, "5초 전에는 0회")
        h.advance(0.1)
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "t0+5에 1회")
        XCTAssertTrue(h.fakes.permission.isFreshPending, "확인이 진행 중")
        h.fakes.permission.completeFresh(true)
        XCTAssertFalse(h.fakes.permission.isFreshPending)
        h.advance(4.9)
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "다음 주기 전")
        h.advance(0.1)
        XCTAssertEqual(h.fakes.permission.freshCount, 2, "t0+10에 1회 더(응답 뒤 토큰이 치워졌다)")
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.repeating(.freshTrustCheck)), 1, "반복 타이머는 종류당 1개")
    }

    /// AC9.9 — 권한 없음 + 화면 1대(.needsPermission)에서도 돈다(R4.4 예외)
    func test_AC9_9_needsPermissionSingleDisplay_freshCheckRuns() {
        let h = harness("AC9_9_np1")
        h.fakes.permission.trusted = false
        h.fakes.displays.displays = [Fixture.builtIn]
        h.start()
        XCTAssertEqual(h.manager.status, .needsPermission, "사전 조건")
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "t0+5에 1회")
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.freshCount, 2, "10초 동안 2회(첫 확인은 t0+7 시한으로 끝났다)")
        XCTAssertEqual(h.fakes.permission.freshCancelCount, 1, "응답 없는 첫 확인은 시한에 취소")
    }

    /// AC9.9 — 꺼짐·.singleDisplay(권한 있음)·.dockNotBottom·.spacesOff에서는 0회. 양성 짝: 같은 하네스로 켜거나 조건을 풀면 돈다
    func test_AC9_9_disabled_zeroFreshChecks_thenEnabled_runs() {
        let h = harness("AC9_9_off", enabled: false)
        h.start()
        h.advance(10)
        XCTAssertEqual(h.fakes.permission.freshCount, 0, "isEnabled == false → 0")
        XCTAssertEqual(h.manager.status, .off)
        h.manager.setEnabled(true)
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "양성 짝: 켜면 5초 뒤 1회")
    }

    func test_AC9_9_singleDisplayWithPermission_zeroFreshChecks_thenSecondDisplay_runs() {
        let h = harness("AC9_9_single")
        h.fakes.displays.displays = [Fixture.builtIn]
        h.start()
        XCTAssertEqual(h.manager.status, .inactive(.singleDisplay), "사전 조건")
        h.advance(10)
        XCTAssertEqual(h.fakes.permission.freshCount, 0, ".singleDisplay(권한 있음) → 0")
        h.fakes.displays.displays = DockPinFixtures.thisMac
        h.fakes.displayChanges.send(.reconfigured)
        h.advance(0.5)
        XCTAssertTrue(h.fakes.tap.isRunning, "사전 조건: 화면 2대 → 탭 실행")
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "양성 짝: 탭 실행 중이면 5초 뒤 1회")
    }

    func test_AC9_9_dockNotBottom_zeroFreshChecks_thenBottom_runs() {
        let h = harness("AC9_9_left")
        h.fakes.dockPreferences.orientationValue = .left
        h.start()
        XCTAssertEqual(h.manager.status, .inactive(.dockNotBottom(.left)), "사전 조건")
        h.advance(10)
        XCTAssertEqual(h.fakes.permission.freshCount, 0, ".dockNotBottom → 0")
        h.fakes.dockPreferences.orientationValue = .bottom
        h.advance(3)                                          // prefsPoll → 활성(t0+12)
        XCTAssertTrue(h.fakes.tap.isRunning, "사전 조건: 아래쪽 → 탭 실행")
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "양성 짝: 활성 뒤 5초에 1회")
    }

    func test_AC9_9_spacesOff_zeroFreshChecks() {
        let h = harness("AC9_9_spaces")
        h.fakes.dockPreferences.separateSpaces = false
        h.start()
        XCTAssertEqual(h.manager.status, .inactive(.spacesOff), "사전 조건")
        h.advance(10)
        XCTAssertEqual(h.fakes.permission.freshCount, 0, ".spacesOff → 0")
    }

    /// AC9.9 — 탭 재시도 중(.active + .retrying)에는 돌지 않는다
    func test_AC9_9_tapRetrying_zeroFreshChecks_thenRunning_runs() {
        let h = harness("AC9_9_retry")
        h.fakes.tap.startSucceeds = false
        h.start()
        XCTAssertEqual(h.fakes.scheduler.pendingRepeatingKinds, [.permissionPoll, .tapRetry], "사전 조건: 재시도 중")
        h.advance(0.9)
        h.fakes.tap.startSucceeds = true
        h.advance(0.1)                                        // tapRetry 1초 → 실행 중(t0+1)
        XCTAssertTrue(h.fakes.tap.isRunning, "사전 조건")
        XCTAssertEqual(h.fakes.permission.freshCount, 0, "재시도 중에는 0")
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "양성 짝: 실행 중이 되고 5초 뒤 1회")
    }

    /// AC9.8(a) — 무응답이면 2.0초 뒤 취소 1회, start/stop 0회, 상태 그대로(L = nil)
    func test_AC9_8a_noResponse_timeoutAt2s_cancelsOnce_noStateChange() {
        let h = harness("AC9_8a")
        h.start()
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "사전 조건: 확인 시작")
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.freshTrustTimeout), 1, "시한 1개 예약")
        XCTAssertEqual(h.fakes.scheduler.timeUntilNext(.freshTrustTimeout) ?? -1, DockPinTuning.freshTrustCheckTimeout,
                       accuracy: 1e-9, "시한 2.0초")
        let starts = h.fakes.tap.startCount, stops = h.fakes.tap.stopCount
        let status = h.manager.status
        h.advance(1.9)
        XCTAssertEqual(h.fakes.permission.freshCancelCount, 0, "2초 전에는 취소 없음")
        XCTAssertTrue(h.fakes.permission.isFreshPending)
        h.advance(0.1)
        XCTAssertEqual(h.fakes.permission.freshCancelCount, 1, "2.0초에 취소 1회")
        XCTAssertFalse(h.fakes.permission.isFreshPending)
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.freshTrustTimeout), 0, "시한 예약이 남지 않는다")
        XCTAssertEqual(h.fakes.tap.startCount, starts, "start 0회")
        XCTAssertEqual(h.fakes.tap.stopCount, stops, "stop 0회")
        XCTAssertEqual(h.manager.status, status, "상태 그대로")
    }

    /// AC9.8(a) — 시한 뒤 늦게 온 결과는 버린다. I13: 시한이 토큰을 치웠으므로 다음 주기 확인은 정상 시작
    func test_AC9_8a_resultAfterTimeoutIgnored_nextTickStartsNewCheck() {
        let h = harness("AC9_8a_late")
        h.start()
        h.advance(7)                                          // t0+5 시작, t0+7 시한
        XCTAssertEqual(h.fakes.permission.freshCancelCount, 1, "사전 조건: 시한 취소")
        let starts = h.fakes.tap.startCount, stops = h.fakes.tap.stopCount
        h.fakes.permission.completeFresh(false)
        XCTAssertEqual(h.fakes.tap.stopCount, stops, "늦은 결과 → stop 0회")
        XCTAssertEqual(h.fakes.tap.startCount, starts)
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name), "상태 그대로")
        h.advance(3)
        XCTAssertEqual(h.fakes.permission.freshCount, 2, "t0+10에 새 확인(시한이 토큰을 nil로 만들었다, I13)")
        XCTAssertTrue(h.fakes.permission.isFreshPending)
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.freshTrustTimeout), 1, "새 시한 1개")
    }

    /// AC9.8(a) — 결과 nil도 변화 없음. 응답하면 시한 예약이 치워지고 확인을 취소하지 않는다
    func test_AC9_8a_resultNil_noStateChange_timeoutCleared() {
        let h = harness("AC9_8a_nil")
        h.start()
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "사전 조건")
        let starts = h.fakes.tap.startCount, stops = h.fakes.tap.stopCount
        h.fakes.permission.completeFresh(nil)
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.freshTrustTimeout), 0, "응답 → 시한 cancel")
        h.advance(2)
        XCTAssertEqual(h.fakes.permission.freshCancelCount, 0, "응답한 확인은 취소하지 않는다")
        XCTAssertEqual(h.fakes.tap.startCount, starts)
        XCTAssertEqual(h.fakes.tap.stopCount, stops)
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
        h.advance(3)
        XCTAssertEqual(h.fakes.permission.freshCount, 2, "다음 주기 확인")
    }

    /// (11f로 갱신, 옛 11e "상태 그대로") 활성 + t = true + r = false → R9.3 순서로 탭부터 제거, .needsPermission(L = false).
    /// 다음 폴링 t = true는 무시된다(7-1 넷째 행).
    func test_11f_active_freshFalse_whileInProcessTrue_stopsTapFirst_needsPermission() {
        let h = harness("11e_active_false")
        h.start()
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "사전 조건")
        let stops = h.fakes.tap.stopCount
        h.fakes.log.clear()
        h.fakes.permission.completeFresh(false)
        XCTAssertEqual(h.fakes.tap.stopCount, stops + 1, "11f: r = false가 이긴다 → stop 1회")
        XCTAssertFalse(h.fakes.tap.isRunning)
        XCTAssertEqual(h.manager.status, .needsPermission, "11f: .needsPermission")
        assertStopBeforeNeedsPermission(h)
        h.advance(1)                                          // 다음 폴링 틱(t = true) — L = false라 무시
        XCTAssertEqual(h.manager.status, .needsPermission, "L = false + t = true → 무시(다음 주기 확인까지)")
        XCTAssertEqual(h.fakes.tap.startCount, 1, "다시 켜지지 않는다")
    }

    /// (11f로 갱신, 옛 11e "상태 그대로") .needsPermission + t = false + r = true → 탭 시작(L = true). 사용자 r5 버그의 해결 지점
    func test_11f_needsPermission_freshTrue_whileInProcessFalse_startsTap_pinned() {
        let h = harness("11e_np_true")
        h.fakes.permission.trusted = false
        h.start()
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "사전 조건")
        h.fakes.permission.completeFresh(true)
        XCTAssertEqual(h.fakes.tap.startCount, 1, "11f: r = true가 이긴다 → start 1회(R9.2)")
        XCTAssertTrue(h.fakes.tap.isRunning)
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name), "11f: 고정 상태")
    }

    /// AC9.8(b) — 한 번에 하나. 새 확인이 시작될 때 이전 확인이 끝나 있어야 한다(20초, 무응답·응답 섞음)
    func test_AC9_8b_atMostOneFreshCheckInFlight() {
        let h = harness("AC9_8b")
        h.start()
        var overlaps = 0
        h.fakes.permission.onFresh = { [unowned h] in
            if h.fakes.permission.isFreshPending { overlaps += 1 }
        }
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "사전 조건")
        h.advance(5)                                          // 무응답 → t0+7 시한 → t0+10 새 확인
        h.fakes.permission.completeFresh(true)
        h.advance(10)
        XCTAssertEqual(h.fakes.permission.freshCount, 4, "t0+5, 10, 15, 20")
        XCTAssertEqual(overlaps, 0, "진행 중인 확인이 있는 채로 새 확인을 시작하지 않는다")
        XCTAssertLessThanOrEqual(h.fakes.scheduler.pendingCount(.freshTrustTimeout), 1, "시한 예약도 1개 이하")
    }

    /// AC9.8(c) — 진행 중 setEnabled(false): 확인·시한 cancel, 늦은 결과는 아무것도 바꾸지 않는다
    func test_AC9_8c_disableWhileInFlight_cancelsCheckAndTimeout_lateResultIgnored() {
        let h = harness("AC9_8c")
        h.start()
        h.advance(5)
        XCTAssertTrue(h.fakes.permission.isFreshPending, "사전 조건")
        h.manager.setEnabled(false)
        XCTAssertEqual(h.fakes.permission.freshCancelCount, 1, "정리 → 확인 cancel(자식 종료)")
        XCTAssertFalse(h.fakes.permission.isFreshPending)
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.freshTrustTimeout), 0, "시한 예약 cancel")
        let starts = h.fakes.tap.startCount, stops = h.fakes.tap.stopCount
        h.fakes.permission.completeFresh(true)
        XCTAssertEqual(h.fakes.tap.startCount, starts, "늦은 결과 → 아무것도 안 바뀐다")
        XCTAssertEqual(h.fakes.tap.stopCount, stops)
        XCTAssertEqual(h.manager.status, .off)
        h.advance(10)
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "꺼진 뒤 새 확인 0회")
        XCTAssertEqual(h.fakes.scheduler.totalPendingCount, 0, "남은 예약 0")
    }

    /// AC9.8(c) + I13 — 정리가 토큰을 nil로 만들어서, 다시 켜면 주기 확인이 정상 시작된다(건너뛰기 고착 없음)
    func test_AC9_8c_disableWhileInFlight_thenReEnable_freshChecksResume() {
        let h = harness("AC9_8c_reenable")
        h.start()
        h.advance(5)
        XCTAssertTrue(h.fakes.permission.isFreshPending, "사전 조건")
        h.manager.setEnabled(false)
        h.manager.setEnabled(true)
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.freshCount, 2, "다시 켜고 5초 뒤 새 확인")
        XCTAssertTrue(h.fakes.permission.isFreshPending)
        let stops = h.fakes.tap.stopCount
        h.fakes.permission.completeFresh(false)
        // (11f로 갱신) 다시 켠 뒤의 확인은 새 세대다 → 결과가 적용된다. r = false, t = true → 탭부터 제거, L = false
        XCTAssertEqual(h.fakes.tap.stopCount, stops + 1, "11f: 새 세대의 r = false → stop 1회")
        XCTAssertEqual(h.manager.status, .needsPermission, "11f: 결과가 적용된다(정리 전 세대만 버린다)")
    }

    /// R12 shutdown도 같은 정리: 확인·시한 cancel, 늦은 결과 무시
    func test_AC9_8c_shutdownWhileInFlight_cancelsCheckAndTimeout() {
        let h = harness("AC9_8c_shutdown")
        h.start()
        h.advance(5)
        XCTAssertTrue(h.fakes.permission.isFreshPending, "사전 조건")
        h.manager.shutdown()
        XCTAssertEqual(h.fakes.permission.freshCancelCount, 1)
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.freshTrustTimeout), 0)
        h.fakes.permission.completeFresh(false)
        h.advance(10)
        XCTAssertEqual(h.fakes.permission.freshCount, 1)
        XCTAssertEqual(h.fakes.scheduler.totalPendingCount, 0)
        XCTAssertEqual(h.manager.status, .off)
    }

    /// 진행 중 화면 1대(권한 있음)로 전환: 주기 확인이 멈추고, 늦은 결과는 아무것도 바꾸지 않는다.
    /// (arch I12: reconcile은 확인을 취소하지 않을 수 있다 — 그래서 취소 시점은 단정하지 않고, 시한이 지난 뒤
    /// 진행 중 확인·시한 예약이 남지 않는다는 것만 단정한다)
    func test_11e_singleDisplayTransitionWhileInFlight_noMoreChecks_lateResultIgnored() {
        let h = harness("11e_toSingle")
        h.start()
        h.advance(5)
        XCTAssertTrue(h.fakes.permission.isFreshPending, "사전 조건")
        h.fakes.displays.displays = [Fixture.builtIn]
        h.fakes.displayChanges.send(.reconfigured)
        h.advance(0.5)                                        // t0+5.5
        XCTAssertEqual(h.manager.status, .inactive(.singleDisplay), "사전 조건")
        XCTAssertEqual(h.fakes.scheduler.pendingRepeatingKinds, [], "반복 타이머 0개")
        let starts = h.fakes.tap.startCount, stops = h.fakes.tap.stopCount
        h.fakes.permission.completeFresh(false)
        XCTAssertEqual(h.fakes.tap.startCount, starts, "늦은 결과 → 변화 없음")
        XCTAssertEqual(h.fakes.tap.stopCount, stops)
        XCTAssertEqual(h.manager.status, .inactive(.singleDisplay))
        h.advance(10)
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "화면 1대(권한 있음) 동안 새 확인 0회")
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.freshTrustTimeout), 0, "시한 예약이 남지 않는다")
        XCTAssertEqual(h.fakes.scheduler.totalPendingCount, 0, "화면 1대 → 예약 0개")
    }

    /// 무응답 상태로 화면 1대 전환 → 시한이 지나면 진행 중 확인이 남지 않고, 다시 2대가 되면 확인이 재개된다(I13)
    func test_11e_singleDisplayTransitionNoResponse_thenDual_freshChecksResume() {
        let h = harness("11e_toSingleBack")
        h.start()
        h.advance(5)
        XCTAssertTrue(h.fakes.permission.isFreshPending, "사전 조건")
        h.fakes.displays.displays = [Fixture.builtIn]
        h.fakes.displayChanges.send(.reconfigured)
        h.advance(0.5)
        XCTAssertEqual(h.manager.status, .inactive(.singleDisplay), "사전 조건")
        h.advance(5)                                          // t0+10.5 — 시한(t0+7) 지남
        XCTAssertFalse(h.fakes.permission.isFreshPending, "진행 중 확인이 남지 않는다")
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.freshTrustTimeout), 0)
        h.fakes.displays.displays = DockPinFixtures.thisMac
        h.fakes.displayChanges.send(.reconfigured)
        h.advance(0.5)                                        // t0+11 활성
        XCTAssertTrue(h.fakes.tap.isRunning, "사전 조건")
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.freshCount, 2, "다시 활성 → 5초 뒤 새 확인")
    }

    /// AC12.4 — 무동작 매니저: 새 프로세스 확인 0회(10초 진행 포함). 양성 짝: 같은 설정의 일반 매니저는 돈다
    func test_AC12_4_inertManager_zeroFreshChecks() {
        let h = harness("AC12_4_fresh", enabled: true, isInert: true)
        h.manager.startIfEnabled()
        h.manager.setEnabled(true)
        h.manager.moveBackNow()
        h.advance(10)
        h.manager.shutdown()
        h.advance(10)
        XCTAssertEqual(h.fakes.permission.freshCount, 0, "무동작 → 새 프로세스 확인 0회")
        XCTAssertEqual(h.fakes.permission.freshCancelCount, 0)
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.freshTrustTimeout), 0)

        let live = harness("AC12_4_fresh_live", enabled: true)
        live.start()
        live.advance(10)
        XCTAssertGreaterThanOrEqual(live.fakes.permission.freshCount, 1, "양성 짝: 일반 매니저는 10초에 1회 이상")
    }

    // MARK: AC9.7 · AC9.10 · AC9.11 · AC9.12 · AC9.14 (r6, 커밋 11f) — 비대칭 래치, applyInProcess 단일 진입점

    // 용어(SPEC R9.6 7번): H = 매니저의 "권한 있음", L = 래치(nil | true | false), t = 프로세스 안 판정, r = 새 프로세스 결과.
    // 래치는 공개되지 않으므로 행동으로 관찰한다:
    //   L = nil   → t = false 폴링이 그 자리에서 탭을 끈다(주기 밖 확인 없음).
    //   L = true  → t = false 폴링은 탭을 끄지 않고 주기 밖 확인(.latchDoubt)만 부른다.
    //   L = false → t = true 폴링은 무시된다(탭 시작 0회).
    // 시각: 활성화 = t0, 첫 주기 확인 = t0+5(응답 보류), 폴링 t0+6, 7, …, 다음 주기 확인 t0+10, 시한 = 시작 + 2초.

    /// 사용자 r5 버그 재현으로 L = true를 만든다: 프로세스 안 판정이 낡은 false로 고정된 채(t = false) 첫 주기 확인이 r = true.
    /// 반환 시각 t0+5, 진행 중 확인 없음, 탭 실행 중, 다음 폴링 t0+6.
    private func latchedTrueHarness(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> Harness {
        let h = harness(name)
        h.fakes.permission.trusted = false
        h.start()
        XCTAssertEqual(h.manager.status, .needsPermission, "사전 조건: 낡은 false → 권한 대기", file: file, line: line)
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "사전 조건: t0+5 주기 확인", file: file, line: line)
        h.fakes.permission.completeFresh(true)
        XCTAssertEqual(h.fakes.tap.startCount, 1, "사전 조건: r = true(t = false) → 탭 시작(L = true)", file: file, line: line)
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name),
                       "사전 조건: 고정 상태(L = true)", file: file, line: line)
        XCTAssertFalse(h.fakes.permission.isFreshPending, "사전 조건: 진행 중 확인 없음", file: file, line: line)
        return h
    }

    /// 탭 실행 중(t = true) 첫 주기 확인이 r = false → L = false, .needsPermission. 반환 시각 t0+5, t = true 그대로.
    private func latchedFalseHarness(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> Harness {
        let h = harness(name)
        h.start()
        XCTAssertTrue(h.fakes.tap.isRunning, "사전 조건", file: file, line: line)
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "사전 조건: t0+5 주기 확인", file: file, line: line)
        h.fakes.permission.completeFresh(false)
        XCTAssertEqual(h.fakes.tap.stopCount, 1, "사전 조건: r = false(t = true) → 탭 제거(L = false)", file: file, line: line)
        XCTAssertEqual(h.manager.status, .needsPermission, "사전 조건: 권한 대기(L = false)", file: file, line: line)
        XCTAssertFalse(h.fakes.permission.isFreshPending, "사전 조건: 진행 중 확인 없음", file: file, line: line)
        return h
    }

    /// R9.3/AC9.1 순서: 로그에서 tap.stop이 status:needsPermission보다 먼저다
    private func assertStopBeforeNeedsPermission(_ h: Harness, file: StaticString = #filePath, line: UInt = #line) {
        let entries = h.fakes.log.entries
        guard let stopIndex = entries.firstIndex(of: "tap.stop") else {
            return XCTFail("tap.stop 기록 없음: \(entries)", file: file, line: line)
        }
        XCTAssertFalse(entries[..<stopIndex].contains("status:needsPermission"),
                       "AC9.1 순서: stop이 상태 변경보다 먼저", file: file, line: line)
        XCTAssertTrue(entries[(stopIndex + 1)...].contains("status:needsPermission"),
                      "stop 뒤에 .needsPermission", file: file, line: line)
    }

    /// 새 프로세스 확인이 어느 예약 안에서 시작됐는지(nil = 예약 밖) 기록한다
    private func recordFreshOrigins(_ h: Harness) -> () -> [DockPinTimerKind?] {
        var kinds: [DockPinTimerKind?] = []
        let scheduler = h.fakes.scheduler
        h.fakes.permission.onFresh = { kinds.append(scheduler.currentKind) }
        return { kinds }
    }

    // MARK: AC9.7 (a) — L = nil, t = true, r = false → stop → 중단 → .needsPermission, L = false

    func test_AC9_7a_activeDriving_freshFalse_inProcessTrue_stopFirst_thenAbortRestore_thenNeedsPermission() {
        let h = drivingHarness("AC9_7a_order")
        h.advance(5)                                       // 1차 실패 t0+2.224 → 재시도 t0+3.224에 2차 되돌리기 진행 중
        XCTAssertEqual(h.manager.status, .relocating(displayName: Fixture.builtIn.name), "사전 조건: t0+5에 되돌리는 중")
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "사전 조건: t0+5 주기 확인")
        h.fakes.log.clear()
        h.fakes.permission.completeFresh(false)
        let entries = h.fakes.log.entries
        guard let stopIndex = entries.firstIndex(of: "tap.stop") else {
            return XCTFail("tap.stop 기록 없음(r = false가 탭을 꺼야 한다): \(entries)")
        }
        let after = entries[(stopIndex + 1)...]
        XCTAssertEqual(after.filter { $0 == "move" }.count, 1, "stop 뒤에는 복원 이동 1개뿐(되돌리기 중단이 stop보다 뒤)")
        XCTAssertTrue(after.contains("status:needsPermission"), "상태 변경이 stop보다 뒤")
        XCTAssertFalse(entries[..<stopIndex].contains("status:needsPermission"))
        XCTAssertEqual(h.moves.last, Fixture.cursorOnBuiltIn, "복원 이벤트는 보낸다(R8.5 예외 2)")
        XCTAssertEqual(h.manager.status, .needsPermission)
        XCTAssertEqual(h.fakes.tap.stopCount, 1)
    }

    func test_AC9_7a_latchFalse_inProcessTruePollsIgnored_noOutOfCycleCheck_untilPeriodicTrue() {
        let h = latchedFalseHarness("AC9_7a_latch")
        let starts = h.fakes.tap.startCount
        h.advance(4)                                       // t0+6…9 폴링 t = true ×4
        XCTAssertEqual(h.fakes.tap.startCount, starts, "L = false + t = true → 무시(start 0회)")
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "L = false에서 폴링은 주기 밖 확인을 부르지 않는다")
        XCTAssertEqual(h.manager.status, .needsPermission)

        h.advance(1)                                       // t0+10 주기 확인
        XCTAssertEqual(h.fakes.permission.freshCount, 2, "다음 주기 확인")
        h.fakes.permission.completeFresh(true)             // r = true, t = true → L = nil
        XCTAssertEqual(h.fakes.tap.startCount, starts + 1, "주기 확인 r = true → start 1회")
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))

        h.fakes.permission.trusted = false                 // L = nil 확인: t = false 폴링이 그 자리에서 탭을 끈다
        h.advance(1)
        XCTAssertEqual(h.fakes.tap.stopCount, 2, "L = nil → 프로세스 안 false가 바로 적용")
        XCTAssertEqual(h.fakes.permission.freshCount, 2, "L = nil → 주기 밖 확인 없음")
    }

    // MARK: AC9.7 (b) — 사용자 버그: L = true, 낡은 false는 확인만 부른다

    func test_AC9_7b_userBug_freshTrue_latchTrue_pollFalse_doubtCheck_trueKeeps_falseStopsInOrder() {
        let h = latchedTrueHarness("AC9_7b")
        let starts = h.fakes.tap.startCount
        let origins = recordFreshOrigins(h)
        h.advance(1)                                       // t0+6 폴링 t = false
        XCTAssertEqual(h.fakes.tap.stopCount, 0, "L = true: 낡은 false 혼자서는 탭을 끄지 않는다")
        XCTAssertEqual(h.fakes.permission.freshCount, 2, "주기 밖 확인 즉시 1회(7-1 셋째 행)")
        XCTAssertEqual(origins(), [.repeating(.permissionPoll)], "폴링 틱 안에서 시작된 주기 밖 확인")
        XCTAssertTrue(h.fakes.permission.isFreshPending)
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name), "H 그대로(true)")

        h.fakes.permission.completeFresh(true)             // 확인이 true → 아무 일도 없다, L = true 유지
        XCTAssertEqual(h.fakes.tap.startCount, starts, "start 0회")
        XCTAssertEqual(h.fakes.tap.stopCount, 0, "stop 0회")
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))

        h.advance(1)                                       // t0+7 — L = true 유지 → 또 확인
        XCTAssertEqual(h.fakes.permission.freshCount, 3, "L = true 유지 → 다음 폴링도 확인 1회")
        XCTAssertEqual(h.fakes.tap.stopCount, 0)

        h.fakes.log.clear()
        h.fakes.permission.completeFresh(false)            // 실제 철회: r = false(= t) → L = nil, 탭부터 제거
        XCTAssertEqual(h.fakes.tap.stopCount, 1, "확인 false → stop 1회")
        XCTAssertFalse(h.fakes.tap.isRunning)
        XCTAssertEqual(h.manager.status, .needsPermission)
        assertStopBeforeNeedsPermission(h)

        h.advance(1)                                       // t0+8 — L = nil이면 더 확인하지 않는다
        XCTAssertEqual(h.fakes.permission.freshCount, 3, "L = nil → 폴링 false가 주기 밖 확인을 부르지 않는다")
        XCTAssertEqual(h.fakes.tap.startCount, starts)
    }

    /// 7-6 덧붙임 — 흔들림 없음: 낡은 false가 10초 동안 매초 와도(확인은 매번 true) 탭이 꺼졌다 켜지지 않는다
    func test_AC9_7b_userBug_noFlapping_staleFalseEverySecond_tapStaysOnPinned() {
        let h = latchedTrueHarness("AC9_7b_noflap")
        h.fakes.permission.autoRespondFresh = true
        let historyStart = h.statusHistory.count
        let freshBefore = h.fakes.permission.freshCount
        h.advance(10)
        XCTAssertEqual(h.fakes.tap.stopCount, 0, "stop 0회")
        XCTAssertEqual(h.fakes.tap.startCount, 1, "start 추가 0회")
        XCTAssertTrue(h.fakes.tap.isRunning)
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
        XCTAssertFalse(h.statusHistory.dropFirst(historyStart).contains(.needsPermission), "상태가 권한 대기로 튀지 않는다")
        XCTAssertGreaterThanOrEqual(h.fakes.permission.freshCount - freshBefore, 10, "낡은 false마다 확인만 불렀다")
    }

    /// 7-6 — L = true에서 실제 철회: 다음 폴링(≤1초) + 확인 1회 안에 탭부터 제거하고, 그 뒤 L = nil
    func test_AC9_7b_latchTrue_realRevoke_detectedAtNextPoll_tapStopFirst() {
        let h = latchedTrueHarness("AC9_7b_revoke")
        h.fakes.permission.autoRespondFresh = false        // ground truth도 철회
        h.fakes.log.clear()
        h.advance(1)                                       // t0+6
        XCTAssertEqual(h.fakes.tap.stopCount, 1, "1초 안에 stop 1회")
        XCTAssertFalse(h.fakes.tap.isRunning)
        XCTAssertEqual(h.manager.status, .needsPermission)
        assertStopBeforeNeedsPermission(h)
        let fresh = h.fakes.permission.freshCount
        h.advance(3)                                       // t0+9 — L = nil
        XCTAssertEqual(h.fakes.permission.freshCount, fresh, "L = nil → 주기 밖 확인 없음")
        XCTAssertEqual(h.fakes.tap.stopCount, 1)
    }

    // MARK: AC9.7 (c) — L = true + 확인 진행 중: 프로세스 안 false가 여러 번 와도 확인이 늘지 않고, 그 결과가 정한다

    func test_AC9_7c_latchTrue_checkInFlight_threeInProcessFalseReads_noNewCheck_resultDecides() {
        let h = latchedTrueHarness("AC9_7c")
        h.advance(1)                                       // t0+6 — 주기 밖 확인 #2 시작(보류)
        XCTAssertEqual(h.fakes.permission.freshCount, 2, "사전 조건: 주기 밖 확인 진행 중")
        XCTAssertTrue(h.fakes.permission.isFreshPending)

        var readKinds: [DockPinTimerKind?] = []
        let scheduler = h.fakes.scheduler
        h.fakes.permission.onCheck = { readKinds.append(scheduler.currentKind) }
        h.fakes.displayChanges.send(.screenParametersChanged)   // 디바운스 t0+6.5
        h.fakes.systemEvents.send(.accessibilityChanged)        // 재확인 t0+7, t0+9
        h.advance(1.5)                                          // t0+7.5 — 디바운스·폴링·재확인 = 프로세스 안 false 3번
        XCTAssertTrue(readKinds.contains(.displayDebounce), "디바운스 읽기: \(readKinds)")
        XCTAssertTrue(readKinds.contains(.repeating(.permissionPoll)), "폴링 읽기: \(readKinds)")
        XCTAssertTrue(readKinds.contains(.permissionRecheck), "재확인 읽기: \(readKinds)")
        XCTAssertEqual(h.fakes.permission.freshCount, 2, "진행 중이면 확인 시작이 늘지 않는다")
        XCTAssertEqual(h.fakes.tap.stopCount, 0, "그 사이 stop 0회")
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))

        h.fakes.log.clear()
        h.fakes.permission.completeFresh(false)            // 진행 중이던 확인의 결과가 정한다
        XCTAssertEqual(h.fakes.tap.stopCount, 1)
        XCTAssertEqual(h.manager.status, .needsPermission)
        assertStopBeforeNeedsPermission(h)
    }

    // MARK: AC9.7 (d) — L = true에서 시한 초과·결과 nil → L = nil, 프로세스 안 판정으로 판단

    func test_AC9_7d_latchTrue_doubtCheckTimesOut_tInProcessFalse_stopsTapFirst() {
        let h = latchedTrueHarness("AC9_7d_timeout")
        h.advance(1)                                       // t0+6 주기 밖 확인(시한 t0+8)
        XCTAssertTrue(h.fakes.permission.isFreshPending, "사전 조건")
        h.fakes.log.clear()
        h.advance(1.9)                                     // t0+7.9
        XCTAssertEqual(h.fakes.tap.stopCount, 0, "시한 전에는 stop 0회")
        XCTAssertEqual(h.fakes.permission.freshCount, 2)
        h.advance(0.1)                                     // t0+8 시한
        XCTAssertEqual(h.fakes.permission.freshCancelCount, 1, "시한 → 확인 취소 1회")
        XCTAssertEqual(h.fakes.tap.stopCount, 1, "L = nil로 풀고 t = false 적용 → stop 1회")
        XCTAssertEqual(h.manager.status, .needsPermission)
        assertStopBeforeNeedsPermission(h)
    }

    func test_AC9_7d_latchTrue_doubtCheckNil_tInProcessFalse_stopsTap_thenLatchCleared() {
        let h = latchedTrueHarness("AC9_7d_nil")
        h.advance(1)                                       // t0+6
        XCTAssertTrue(h.fakes.permission.isFreshPending, "사전 조건")
        h.fakes.log.clear()
        h.fakes.permission.completeFresh(nil)
        XCTAssertEqual(h.fakes.tap.stopCount, 1, "결과 nil + L = true → 래치 풀고 t = false → stop 1회")
        XCTAssertEqual(h.manager.status, .needsPermission)
        assertStopBeforeNeedsPermission(h)
        h.advance(1)                                       // t0+7 — L = nil
        XCTAssertEqual(h.fakes.permission.freshCount, 2, "L = nil → 주기 밖 확인 없음")
    }

    /// 7-2 — L = true + 결과 nil인데 그 순간 t = true → 래치만 풀리고 H 그대로. 그 뒤 t = false는 바로 적용된다(L = nil)
    func test_AC9_7d_latchTrue_doubtCheckNil_tInProcessTrue_latchCleared_inProcessDecides() {
        let h = latchedTrueHarness("AC9_7d_nil_true")
        h.advance(1)                                       // t0+6 주기 밖 확인
        XCTAssertTrue(h.fakes.permission.isFreshPending, "사전 조건")
        h.fakes.permission.trusted = true
        h.fakes.permission.completeFresh(nil)
        XCTAssertEqual(h.fakes.tap.stopCount, 0, "t = true → stop 0회")
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
        h.fakes.permission.trusted = false
        h.advance(1)                                       // t0+7
        XCTAssertEqual(h.fakes.tap.stopCount, 1, "L = nil이므로 t = false가 그 자리에서 탭을 끈다")
        XCTAssertEqual(h.fakes.permission.freshCount, 2, "주기 밖 확인 없음")
        XCTAssertEqual(h.manager.status, .needsPermission)
    }

    // MARK: AC9.7 (e) — L = true에서 t = true 1회 → L = nil

    func test_AC9_7e_latchTrue_inProcessTrueOnce_clearsLatch_thenFalseStopsImmediately() {
        let h = latchedTrueHarness("AC9_7e")
        h.fakes.permission.trusted = true
        h.advance(1)                                       // t0+6 — L == t → L = nil, H 그대로
        XCTAssertEqual(h.fakes.tap.startCount, 1, "start 추가 0회")
        XCTAssertEqual(h.fakes.tap.stopCount, 0, "stop 0회")
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "주기 밖 확인 0회")
        h.fakes.permission.trusted = false
        h.advance(1)                                       // t0+7
        XCTAssertEqual(h.fakes.tap.stopCount, 1, "L = nil → stop 1회")
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "주기 밖 확인 0회")
        XCTAssertEqual(h.manager.status, .needsPermission)
    }

    // MARK: AC9.10 (C12, 7-3) — 프로세스 안 경로로 H가 바뀌면 진행 중 확인의 세대를 올린다

    func test_AC9_10_active_inFlight_pollFalse_stops_lateFreshTrueCannotReEnable() {
        let h = harness("AC9_10_revoke")
        h.start()
        h.advance(5)                                       // 주기 확인 진행 중(L = nil, H = true)
        XCTAssertTrue(h.fakes.permission.isFreshPending, "사전 조건")
        h.fakes.permission.trusted = false
        h.advance(1)                                       // t0+6 폴링 t = false
        XCTAssertEqual(h.fakes.tap.stopCount, 1, "stop 1회")
        XCTAssertEqual(h.manager.status, .needsPermission)
        XCTAssertEqual(h.fakes.permission.freshCancelCount, 1, "H 변경 → 진행 중 확인 cancel(세대 올림, 7-3)")
        XCTAssertFalse(h.fakes.permission.isFreshPending)
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.freshTrustTimeout), 0, "시한 예약도 cancel(I13)")

        h.fakes.permission.completeFresh(true)             // 늦은 결과 — 버려진다
        XCTAssertEqual(h.fakes.tap.startCount, 1, "늦은 r = true로 탭이 다시 켜지지 않는다")
        XCTAssertEqual(h.manager.status, .needsPermission)
        h.advance(1)                                       // t0+7 — L = nil 확인(t = false 폴링 → 주기 밖 확인 없음)
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "L = nil")
        h.advance(3)                                       // t0+10 — 토큰이 치워져 다음 주기 확인이 정상 시작(I13)
        XCTAssertEqual(h.fakes.permission.freshCount, 2)
    }

    func test_AC9_10_needsPermission_inFlight_pollTrue_starts_lateFreshFalseCannotStop() {
        let h = harness("AC9_10_grant")
        h.fakes.permission.trusted = false
        h.start()
        h.advance(5)                                       // 주기 확인 진행 중(L = nil, H = false)
        XCTAssertTrue(h.fakes.permission.isFreshPending, "사전 조건")
        h.fakes.permission.trusted = true
        h.advance(1)                                       // t0+6 폴링 t = true
        XCTAssertEqual(h.fakes.tap.startCount, 1, "start 1회")
        XCTAssertEqual(h.fakes.permission.freshCancelCount, 1, "H 변경 → 진행 중 확인 cancel(세대 올림, 7-3)")
        XCTAssertFalse(h.fakes.permission.isFreshPending)

        h.fakes.permission.completeFresh(false)            // 늦은 결과 — 버려진다
        XCTAssertEqual(h.fakes.tap.stopCount, 0, "늦은 r = false로 탭이 꺼지지 않는다")
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
        h.advance(4)                                       // t0+10
        XCTAssertEqual(h.fakes.permission.freshCount, 2, "다음 주기 확인 정상 시작(I13)")
    }

    // MARK: AC9.11 (C11, 7-1·7-4) — 모든 읽기는 applyInProcess, 래치 수명

    /// (a) L = true에서 .dockNotBottom → L = nil. 진행 중이던 확인의 결과는 버린다(I12). 이어 prefsPoll t = false → .needsPermission
    func test_AC9_11a_latchTrue_dockNotBottom_clearsLatch_thenPrefsPollFalse_needsPermission() {
        let h = latchedTrueHarness("AC9_11a")
        h.fakes.dockPreferences.orientationValue = .left
        h.fakes.displayChanges.send(.screenParametersChanged)
        h.advance(0.5)                                     // t0+5.5 디바운스: 방향 left → .dockNotBottom
        XCTAssertEqual(h.manager.status, .inactive(.dockNotBottom(.left)), "사전 조건: 탭 없음 상태")
        XCTAssertFalse(h.fakes.tap.isRunning)
        h.fakes.permission.completeFresh(true)             // 디바운스 읽기가 부른 확인이 있었다면 그 결과는 버린다(I12)
        XCTAssertEqual(h.manager.status, .inactive(.dockNotBottom(.left)))
        h.advance(3)                                       // t0+8.5 prefsPoll: t = false, L = nil → H = false
        XCTAssertEqual(h.manager.status, .needsPermission, "freshTrustCheck 없는 상태로 가면 L = nil → t = false 적용")
        XCTAssertEqual(h.fakes.tap.startCount, 1, "탭은 다시 켜지지 않는다")
    }

    /// (a 보강) L = true에서 화면 1대(.singleDisplay) → L = nil. 다시 2대 → 디바운스 t = false로 .needsPermission(탭 시작 0회)
    func test_AC9_11a_latchTrue_singleDisplay_clearsLatch_thenDual_inProcessFalse_needsPermission() {
        let h = latchedTrueHarness("AC9_11a_single")
        h.fakes.displays.displays = [Fixture.builtIn]
        h.fakes.displayChanges.send(.reconfigured)
        h.advance(0.5)                                     // t0+5.5
        XCTAssertEqual(h.manager.status, .inactive(.singleDisplay), "사전 조건: H = true + 화면 1대")
        h.fakes.permission.completeFresh(true)             // 있었다면 버린다(I12)
        h.fakes.displays.displays = DockPinFixtures.thisMac
        h.fakes.displayChanges.send(.reconfigured)
        h.advance(0.5)                                     // t0+6 디바운스(화면 1대 동안 폴링 없음)
        XCTAssertEqual(h.manager.status, .needsPermission, "L이 풀렸으므로 디바운스 읽기 t = false가 적용된다")
        XCTAssertEqual(h.fakes.tap.startCount, 1, "다시 2대가 돼도 탭을 켜지 않는다")
    }

    /// (7-4) 정리 때 L = nil — 끄고 다시 켜면 t = false가 그대로 적용된다
    func test_AC9_11_latchTrue_disableThenEnable_latchCleared_needsPermission() {
        let h = latchedTrueHarness("AC9_11_teardown")
        h.manager.setEnabled(false)
        h.manager.setEnabled(true)
        XCTAssertEqual(h.manager.status, .needsPermission, "정리 → L = nil → readAll t = false 적용")
        XCTAssertEqual(h.fakes.tap.startCount, 1, "다시 켤 때 탭 시작 0회")
        h.advance(1)
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "L = nil → 폴링 false가 주기 밖 확인을 부르지 않는다")
    }

    /// (b) L = true에서 디스플레이 디바운스 재계산의 동기 읽기 t = false → stop 0회, 주기 밖 확인 1회
    func test_AC9_11b_latchTrue_debounceRecomputeReadsFalse_noStop_oneDoubtCheck() {
        let h = latchedTrueHarness("AC9_11b")
        let origins = recordFreshOrigins(h)
        h.fakes.displayChanges.send(.screenParametersChanged)
        h.advance(0.5)                                     // t0+5.5 — 폴링 전
        XCTAssertEqual(h.fakes.tap.stopCount, 0, "디바운스 읽기도 applyInProcess(L = true) → stop 0회")
        XCTAssertEqual(origins(), [.displayDebounce], "디바운스에서 주기 밖 확인 1회")
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
    }

    /// (b 보강) readAll 경로(잠금 해제 → sessionSettle)도 applyInProcess(reconcile: false)다 — L = true면 탭을 끄지 않는다
    func test_AC9_11b_latchTrue_sessionSettleReadAll_falseRead_noStop_doubtCheck() {
        let h = latchedTrueHarness("AC9_11b_settle")
        h.fakes.permission.autoRespondFresh = true
        let origins = recordFreshOrigins(h)
        h.advance(0.2)                                     // t0+5.2
        h.fakes.systemEvents.send(.screenUnlocked)         // settle t0+6.2
        h.advance(1.0)                                     // t0+6.2
        XCTAssertTrue(origins().contains(.sessionSettle), "readAll 읽기도 주기 밖 확인을 부른다: \(origins())")
        XCTAssertEqual(h.fakes.tap.stopCount, 0, "stop 0회")
        XCTAssertTrue(h.fakes.tap.isRunning)
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
    }

    /// (c) L = true에서 권한 알림은 L을 바꾸지 않는다 — 알림 뒤에도 낡은 false가 탭을 끄지 않는다
    func test_AC9_11c_latchTrue_accessibilityNotification_latchUnchanged_noStop() {
        let h = latchedTrueHarness("AC9_11c_true")
        h.fakes.permission.autoRespondFresh = true         // 확인은 계속 true
        h.fakes.systemEvents.send(.accessibilityChanged)
        h.advance(4)                                       // t0+9 — 재확인 +1.0·+3.0 + 폴링
        XCTAssertEqual(h.fakes.tap.stopCount, 0, "알림이 래치를 풀었다면 t0+6 폴링이 탭을 껐다")
        XCTAssertEqual(h.fakes.tap.startCount, 1)
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
    }

    /// (c) L = false에서 권한 알림도 L을 바꾸지 않는다 — 재확인 t = true가 탭을 켜지 않는다
    func test_AC9_11c_latchFalse_accessibilityNotification_latchUnchanged_noStart() {
        let h = latchedFalseHarness("AC9_11c_false")
        let starts = h.fakes.tap.startCount
        h.fakes.systemEvents.send(.accessibilityChanged)
        h.advance(3.5)                                     // t0+8.5 — 재확인 +1.0·+3.0(N21 확인은 응답 없이 시한)
        XCTAssertEqual(h.fakes.tap.startCount, starts, "L = false 유지 → t = true 재확인 무시")
        XCTAssertEqual(h.manager.status, .needsPermission)
    }

    // MARK: AC9.12 (7-5, D4) — L = true 동안 비용 상한

    func test_AC9_12_latchTrue_staleFalseFixed_autoTrue_tenSeconds_atMost12Checks_noStop() {
        let h = latchedTrueHarness("AC9_12")
        h.fakes.permission.autoRespondFresh = true
        let before = h.fakes.permission.freshCount
        h.advance(10)
        let started = h.fakes.permission.freshCount - before
        XCTAssertLessThanOrEqual(started, 12, "10초에 확인 12회 이하(약 1회/초 + 주기)")
        XCTAssertGreaterThanOrEqual(started, 10, "양성 짝: 낡은 false 폴링마다 주기 밖 확인 1회")
        XCTAssertEqual(h.fakes.tap.stopCount, 0, "stop 0회")
    }

    // MARK: AC9.14 (R9.5 N21) — L = false에서 알림 뒤 +1.0초 재확인에 확인 1회 앞당김

    func test_AC9_14_latchFalse_notification_plusOne_advancesOneCheck_thenTrueStarts() {
        let h = latchedFalseHarness("AC9_14")
        let starts = h.fakes.tap.startCount
        let origins = recordFreshOrigins(h)
        h.fakes.systemEvents.send(.accessibilityChanged)
        XCTAssertEqual(h.fakes.permission.freshCount, 1, "알림 처리 자리에서 확인 시작 0회")
        h.advance(1.0)                                     // t0+6 재확인 +1.0
        XCTAssertEqual(h.fakes.permission.freshCount, 2, "+1.0 재확인 뒤 주기 밖 확인 1회")
        XCTAssertEqual(origins(), [.permissionRecheck], "재확인 예약 안에서 시작")
        XCTAssertEqual(h.fakes.tap.startCount, starts, "L = false 그대로 → start 0회")
        XCTAssertEqual(h.manager.status, .needsPermission)
        h.fakes.permission.completeFresh(true)             // r = true, t = true → L = nil
        XCTAssertEqual(h.fakes.tap.startCount, starts + 1, "start 1회")
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
    }

    /// +3.0 재확인에서는 앞당기지 않는다. 결과 false면 L = false 그대로(start 0회)
    func test_AC9_14_latchFalse_plusThreeRecheck_doesNotAdvance() {
        let h = latchedFalseHarness("AC9_14_plus3")
        let starts = h.fakes.tap.startCount
        h.fakes.systemEvents.send(.accessibilityChanged)
        h.advance(1.0)                                     // t0+6 — 앞당긴 확인 #2
        XCTAssertEqual(h.fakes.permission.freshCount, 2, "사전 조건: +1.0 앞당김")
        h.fakes.permission.completeFresh(false)            // r = false ≠ t → L = false 유지
        h.advance(2.0)                                     // t0+8 — +3.0 재확인
        XCTAssertEqual(h.fakes.permission.freshCount, 2, "+3.0에서는 앞당기지 않는다")
        XCTAssertEqual(h.fakes.tap.startCount, starts, "L = false → start 0회")
        XCTAssertEqual(h.manager.status, .needsPermission)
    }

    /// +1.0 시점에 확인이 진행 중이면 새로 시작하지 않는다
    func test_AC9_14_latchFalse_checkInFlightAtPlusOne_noAdvance() {
        let h = latchedFalseHarness("AC9_14_inflight")
        h.advance(4.2)                                     // t0+9.2
        XCTAssertEqual(h.fakes.tap.startCount, 1, "사전 조건: L = false 유지(폴링 t = true 무시)")
        h.fakes.systemEvents.send(.accessibilityChanged)   // +1.0 = t0+10.2
        h.advance(1.0)                                     // t0+10 주기 확인 시작(보류) → t0+10.2 재확인
        XCTAssertTrue(h.fakes.permission.isFreshPending, "사전 조건: 주기 확인 진행 중")
        XCTAssertEqual(h.fakes.permission.freshCount, 2, "진행 중이면 앞당김 0회(주기 확인 1회만)")
        XCTAssertEqual(h.fakes.tap.startCount, 1)
    }

    /// L = nil에서는 같은 알림이 +1.0에 주기 밖 확인을 부르지 않는다(회귀 가드)
    func test_AC9_14_latchNil_notification_noAdvance() {
        let h = harness("AC9_14_nil")
        h.fakes.permission.trusted = false
        h.start()
        XCTAssertEqual(h.manager.status, .needsPermission, "사전 조건: L = nil, H = false")
        h.fakes.systemEvents.send(.accessibilityChanged)
        h.advance(3.0)                                     // +1.0·+3.0 재확인(주기 확인 t0+5 전)
        XCTAssertEqual(h.fakes.permission.freshCount, 0, "L = nil → 앞당김 0회")
    }

    // MARK: - AC10 세션

    func test_AC10_1_lockedAtStart_noEvents_waitingLocked_unlockResumes() {
        let h = harness("AC10_1")
        h.dockOn = Fixture.sidecar.id
        h.fakes.session.locked = true
        h.start()
        XCTAssertEqual(h.manager.status, .waiting(.locked, displayName: Fixture.builtIn.name))
        h.advance(2)
        XCTAssertTrue(h.moves.isEmpty, "잠김 → 전송 이벤트 0개")
        h.fakes.session.locked = false
        h.fakes.systemEvents.send(.screenUnlocked)
        h.advance(1.1)                                     // 잠금 해제 1 s 뒤 재확인
        XCTAssertEqual(h.moves.first, Fixture.firstApproach, "해제 뒤 되돌리기")
    }

    func test_R10_3_screenLockedWhileDriving_abortsWithRestore_thenWaitsLocked() {
        let h = drivingHarness("R10_3_lock")
        h.advance(0.1)
        let before = h.moves.count
        h.fakes.session.locked = true
        h.fakes.systemEvents.send(.screenLocked)
        XCTAssertEqual(h.moves.count, before + 1)
        XCTAssertEqual(h.moves.last, Fixture.cursorOnBuiltIn)
        h.advance(3.1)                                     // dockPoll t0+3
        XCTAssertEqual(h.moves.count, before + 1)
        XCTAssertEqual(h.manager.status, .waiting(.locked, displayName: Fixture.builtIn.name))
        XCTAssertEqual(h.retryDelays, [])
    }

    func test_AC10_2_sleepWhileDriving_stopsAndRestoresOnce() {
        let h = drivingHarness("AC10_2")
        h.advance(0.1)
        let before = h.moves.count
        h.fakes.systemEvents.send(.willSleep)
        XCTAssertEqual(h.moves.count, before + 1, "복원 이벤트 1회")
        XCTAssertEqual(h.moves.last, Fixture.cursorOnBuiltIn)
        h.advance(3.1)
        XCTAssertEqual(h.moves.count, before + 1, "잠자기 중에는 움직이지 않는다")
        XCTAssertEqual(h.manager.status, .waiting(.asleep, displayName: Fixture.builtIn.name))
        XCTAssertEqual(h.fakes.tap.stopCount, 0, "탭은 그대로 둔다(R10.1)")
    }

    func test_AC10_3_wake_after1s_eventScanOnce_overrideReleased() {
        let h = overrideHarness("AC10_3")
        let events = h.requestCount(.event)
        h.fakes.systemEvents.send(.didWake)
        h.advance(0.9)
        XCTAssertEqual(h.requestCount(.event), events, "1 s 전에는 확인하지 않는다")
        h.advance(0.2)
        XCTAssertEqual(h.requestCount(.event), events + 1, "1 s 뒤 위치 확인 1회")
        XCTAssertNotEqual(h.manager.status, .movedByUser(displayName: Fixture.sidecar.name), "오버라이드 false")
        XCTAssertEqual(h.moves.first, Fixture.firstApproach, "오버라이드가 풀려 되돌린다")
    }

    func test_R10_4_sessionResignedWhileDriving_abortsWithRestore_waitsNotOnConsole() {
        let h = drivingHarness("R10_4")
        h.advance(0.1)
        let before = h.moves.count
        h.fakes.session.onConsole = false
        h.fakes.systemEvents.send(.sessionResignedActive)
        XCTAssertEqual(h.moves.count, before + 1)
        h.advance(3.1)
        XCTAssertEqual(h.moves.count, before + 1)
        XCTAssertEqual(h.manager.status, .waiting(.notOnConsole, displayName: Fixture.builtIn.name))
    }

    // MARK: - VULN-003 (r6.3) — 분산 잠금 알림 위조 방어

    /// 실제로 잠긴 적 없이 온 잠금 해제 알림은 오버라이드를 풀지 않는다
    func test_VULN003_spoofedUnlock_withoutRealLock_keepsOverride() {
        let h = overrideHarness("VULN003_unlock_override")
        let events = h.requestCount(.event)
        h.fakes.systemEvents.send(.screenUnlocked)        // 세션은 계속 잠기지 않음
        h.advance(1.1)
        XCTAssertEqual(h.manager.status, .movedByUser(displayName: Fixture.sidecar.name), "오버라이드 유지")
        XCTAssertTrue(h.moves.isEmpty, "되돌리기 0회")
        XCTAssertEqual(h.requestCount(.event), events, "이벤트 계기 조회 0회")
    }

    /// 위조 해제는 실패 횟수·예약된 재시도를 건드리지 않는다
    func test_VULN003_spoofedUnlock_keepsFailureCountAndScheduledRetry() {
        let h = drivingHarness("VULN003_unlock_retry")
        h.advance(1.5)
        h.fakes.systemEvents.send(.screenUnlocked)        // settle t0+2.5 — 1차 실패(t0+2.224) 뒤 재시도 대기 중
        h.advance(1.0)
        XCTAssertEqual(h.pendingRetries, 1, "예약된 재시도 그대로")
        XCTAssertEqual(h.retryDelays, [1])
        h.advance(3.2)                                     // 재시도 t0+3.224 → 2차 실패
        XCTAssertEqual(h.retryDelays, [1, 3], "실패 횟수 1 유지 → 2차 실패 뒤 3초")
    }

    /// 위조 해제를 반복해도 .failed(4) 상한이 풀리지 않는다
    func test_VULN003_repeatedSpoofedUnlocks_failedStaysFailed() {
        let h = failedFourTimesHarness("VULN003_unlock_failed")
        let before = h.moves.count
        for _ in 0..<5 {
            h.fakes.systemEvents.send(.screenUnlocked)
            h.advance(1.1)
        }
        XCTAssertEqual(h.moves.count, before, "커서 이동 0회")
        XCTAssertEqual(h.manager.status, .failed(attempts: 4))
        XCTAssertEqual(h.retryDelays, [1, 3, 10])
    }

    /// 실제 잠금 → 해제는 기존 동작(오버라이드 해제 + 되돌리기)
    func test_VULN003_realLockThenUnlock_releasesOverride() {
        let h = overrideHarness("VULN003_real_unlock")
        h.fakes.session.locked = true
        h.fakes.systemEvents.send(.screenLocked)
        h.advance(0.5)
        h.fakes.session.locked = false
        h.fakes.systemEvents.send(.screenUnlocked)
        h.advance(1.1)
        XCTAssertNotEqual(h.manager.status, .movedByUser(displayName: Fixture.sidecar.name), "오버라이드 해제")
        XCTAssertEqual(h.moves.first, Fixture.firstApproach, "되돌린다")
    }

    /// 잠금 알림 없이 주기 읽기로만 잠김을 본 경우에도 실제 해제로 인정한다
    func test_VULN003_lockObservedByPeriodicRead_unlockIsGenuine() {
        let h = failedFourTimesHarness("VULN003_poll_lock")
        h.fakes.session.locked = true
        h.advance(3.1)                                     // dockPoll이 세션을 읽는다
        h.fakes.session.locked = false
        let before = h.moves.count
        h.fakes.systemEvents.send(.screenUnlocked)
        h.advance(1.1)
        XCTAssertGreaterThan(h.moves.count, before, "실제 해제 → 이벤트 계기로 다시 시도")
    }

    /// 해제 알림 처리 시점에 아직 잠겨 있으면 이벤트 계기가 아니다
    func test_VULN003_unlockWhileStillLocked_notEventTrigger() {
        let h = overrideHarness("VULN003_still_locked")
        h.fakes.session.locked = true
        h.fakes.systemEvents.send(.screenLocked)
        h.fakes.systemEvents.send(.screenUnlocked)        // 위조 — 세션은 여전히 잠김
        h.advance(1.1)
        XCTAssertTrue(h.moves.isEmpty)
        XCTAssertNotEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name))
        h.fakes.session.locked = false                     // 이후 실제 해제는 정상 처리
        h.fakes.systemEvents.send(.screenUnlocked)
        h.advance(1.1)
        XCTAssertEqual(h.moves.first, Fixture.firstApproach, "실제 해제 → 되돌린다")
    }

    /// 잠금 해제 계기는 minEventTriggerInterval 안에 1회만 효과가 있다
    func test_VULN003_unlockTriggers_rateLimited() {
        let h = harness("VULN003_rate")
        h.start()
        func cycle() {
            h.fakes.session.locked = true
            h.fakes.systemEvents.send(.screenLocked)
            h.fakes.session.locked = false
            h.fakes.systemEvents.send(.screenUnlocked)
            h.advance(1.1)
        }
        let events = h.requestCount(.event)
        cycle()
        XCTAssertEqual(h.requestCount(.event), events + 1, "첫 해제 → 이벤트 조회 1회")
        cycle()
        cycle()
        XCTAssertEqual(h.requestCount(.event), events + 1, "창 안의 해제는 효과 없음")
        h.advance(DockPinTuning.minEventTriggerInterval)
        cycle()
        XCTAssertEqual(h.requestCount(.event), events + 2, "창이 지나면 다시 1회")
    }

    /// 세션이 잠기지 않았는데 온 잠금 알림은 되돌리기를 멈추지 않는다
    func test_VULN003_spoofedLockWhileDriving_noAbort() {
        let h = drivingHarness("VULN003_lock")
        h.advance(0.1)
        let before = h.moves.count
        h.fakes.systemEvents.send(.screenLocked)          // 세션은 잠기지 않음
        h.advance(0.1)
        XCTAssertFalse(h.moves.dropFirst(before).contains(Fixture.cursorOnBuiltIn), "복원 이동 없음")
        XCTAssertGreaterThan(h.moves.count, before, "다가가기 계속")
        XCTAssertEqual(h.manager.status, .relocating(displayName: Fixture.builtIn.name))
    }

    // MARK: - AC12 종료·테스트 호스트

    func test_AC12_1_shutdownWhileDriving_restoreThenTapThenCallbackThenObservers() {
        let h = drivingHarness("AC12_1")
        h.advance(0.1)
        h.fakes.log.clear()
        let before = h.moves.count
        h.manager.shutdown()
        let ordered = h.fakes.log.entries.filter {
            ["move", "tap.stop", "displayChanges.stop", "systemEvents.stop"].contains($0)
        }
        XCTAssertEqual(ordered, ["move", "tap.stop", "displayChanges.stop", "systemEvents.stop"], "R12.1 순서")
        XCTAssertEqual(h.moves.count, before + 1, "복원 1회")
        XCTAssertEqual(h.moves.last, Fixture.cursorOnBuiltIn)
        XCTAssertEqual(h.fakes.tap.stopCount, 1)
        XCTAssertEqual(h.fakes.displayChanges.stopCount, 1)
        h.advance(5)
        XCTAssertEqual(h.moves.count, before + 1, "그 뒤 전송 이벤트 0개")
        XCTAssertEqual(h.fakes.scheduler.totalPendingCount, 0)
        XCTAssertEqual(h.manager.status, .off)
    }

    func test_AC12_2_shutdownTwice_stopOnce_laterCallsIgnored() {
        let h = harness("AC12_2")
        h.start()
        h.manager.shutdown()
        h.manager.shutdown()
        XCTAssertEqual(h.fakes.tap.stopCount, 1)
        XCTAssertEqual(h.fakes.displayChanges.stopCount, 1)
        h.manager.startIfEnabled()
        h.manager.setEnabled(true)
        XCTAssertEqual(h.fakes.tap.startCount, 1, "shutdown 뒤 startIfEnabled/setEnabled는 무동작(R12.4)")
        XCTAssertEqual(h.fakes.displayChanges.startCount, 1)
        XCTAssertEqual(h.manager.status, .off)
    }

    func test_AC12_4_inertManager_touchesNoDependency_noDefaultsWrite() {
        let h = harness("AC12_4", enabled: true, isInert: true)
        h.manager.startIfEnabled()
        h.manager.setEnabled(true)
        h.manager.moveBackNow()
        h.manager.setTarget(.display(uuid: "Z"), displayName: "Z")
        h.manager.openPermissionSettings()
        h.manager.setEnabled(false)
        h.manager.shutdown()
        h.advance(10)
        h.assertNoDependencyCalls("inert")
        XCTAssertEqual(h.defaults.object(forKey: Keys.enabled) as? Bool, true, "suite 값 불변")
        XCTAssertNil(h.defaults.object(forKey: Keys.targetUUID))
        XCTAssertNil(h.defaults.object(forKey: Keys.targetName))
        XCTAssertTrue(h.manager.isEnabled, "I10: init에서 읽은 값 그대로")
        XCTAssertEqual(h.manager.target, .main)
        XCTAssertEqual(h.manager.status, .off, "I10: 무동작 매니저 상태는 .off")
    }

    func test_R1_4_openPermissionSettings_opensOnce() {
        let h = harness("R1_4")
        h.fakes.permission.trusted = false
        h.start()
        h.manager.openPermissionSettings()
        XCTAssertEqual(h.fakes.permission.openCount, 1)
        XCTAssertEqual(h.manager.status, .needsPermission)
    }

    /// makeLive 연결(R12.3): 테스트 호스트 신호마다 무동작 → setTarget이 suite에 쓰지 않는다.
    /// 안전: dockPinEnabled == false인 suite + setTarget만. 시스템을 건드리는 경로가 없다.
    func test_AC12_3_makeLive_eachTestHostSignal_isInert() {
        let signals: [([String: String], Bool)] = [
            (["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"], false),
            (["XCTestBundlePath": "/tmp/x.xctest"], false),
            (["XCTestSessionIdentifier": "abc"], false),
            ([:], true),
        ]
        for (index, signal) in signals.enumerated() {
            let suite = "Manager.AC12_3_live\(index)"
            let defaults = makeDockPinSuite(suite)
            let fullName = dockPinSuiteName(suite)
            addTeardownBlock { UserDefaults(suiteName: fullName)?.removePersistentDomain(forName: fullName) }
            let manager = DockPinManager.makeLive(defaults: defaults, environment: signal.0, xcTestClassLoaded: signal.1)
            manager.setTarget(.display(uuid: "Z"), displayName: "Z")
            XCTAssertNil(defaults.object(forKey: Keys.targetUUID), "신호 \(index): 무동작 → UserDefaults 쓰기 없음")
            XCTAssertEqual(manager.status, .off, "신호 \(index)")
            XCTAssertFalse(manager.isEnabled, "신호 \(index): init에서 읽은 값")
        }
    }

    func test_AC12_3_makeLive_noTestHostSignal_isLive() {
        let suite = "Manager.AC12_3_prod"
        let defaults = makeDockPinSuite(suite)
        let fullName = dockPinSuiteName(suite)
        addTeardownBlock { UserDefaults(suiteName: fullName)?.removePersistentDomain(forName: fullName) }
        let manager = DockPinManager.makeLive(defaults: defaults, environment: [:], xcTestClassLoaded: false)
        manager.setTarget(.display(uuid: "Z"), displayName: "Z")       // 꺼져 있으므로 저장만 한다
        XCTAssertEqual(defaults.string(forKey: Keys.targetUUID), "Z", "신호가 없으면 일반 매니저")
        XCTAssertEqual(manager.status, .off)
    }

    // MARK: - S1 선택지

    func test_S1_targetChoices_publishedWhileEnabled_clearedWhenOff() {
        let h = harness("S1")
        h.start()
        XCTAssertEqual(h.manager.targetChoices.map(\.id), ["main", "BUILTIN-UUID", DockPinFixtures.sidecarUUID])
        h.manager.setEnabled(false)
        XCTAssertEqual(h.manager.targetChoices, [])
    }

    // MARK: - AC15 Sidecar

    func test_AC15_1_singleToSidecarAdded_startsTap_rowsMatchAC3_10() {
        let h = harness("AC15_1")
        h.fakes.displays.displays = [Fixture.builtIn]
        h.start()
        XCTAssertEqual(h.manager.status, .inactive(.singleDisplay), "사전 조건")
        h.fakes.displays.displays = DockPinFixtures.thisMac
        h.fakes.displayChanges.send(.reconfigured)
        h.advance(0.4)
        XCTAssertEqual(h.fakes.tap.startCount, 0, "디바운스 전")
        h.advance(0.1)
        XCTAssertEqual(h.fakes.tap.startCount, 1)
        XCTAssertEqual(h.lastSnapshot?.rows, [Fixture.sidecarRow])
    }

    func test_AC15_2_sidecarBecomesMirror_singleDisplay_tapStopped() {
        let h = harness("AC15_2")
        h.start()
        XCTAssertTrue(h.fakes.tap.isRunning, "사전 조건")
        h.fakes.displays.displays = [Fixture.builtIn, DockPinFixtures.sidecarMirrored]
        h.fakes.displayChanges.send(.reconfigured)
        h.advance(0.5)
        XCTAssertEqual(h.manager.status, .inactive(.singleDisplay))
        XCTAssertEqual(h.fakes.tap.stopCount, 1)
    }

    func test_AC15_3_sidecarTargetRemoved_fallbackToMain_thenReturns() {
        let h = harness("AC15_3", targetUUID: DockPinFixtures.sidecarUUID, targetName: Fixture.sidecar.name)
        h.fakes.displays.displays = DockPinFixtures.threeWithSidecar
        h.dockOn = Fixture.sidecar.id
        h.start()
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.sidecar.name), "사전 조건: 고정 화면 Sidecar")
        XCTAssertFalse(h.manager.usingFallbackAnchor)

        h.fakes.displays.displays = [Fixture.builtIn, Fixture.external]
        h.dockOn = Fixture.builtIn.id
        h.fakes.displayChanges.send(.reconfigured)
        h.advance(0.5)
        XCTAssertTrue(h.manager.usingFallbackAnchor)
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name), "고정 화면이 내장 화면")
        XCTAssertEqual(h.manager.target, .display(uuid: DockPinFixtures.sidecarUUID), "저장된 대상은 그대로")
        XCTAssertEqual(h.defaults.string(forKey: Keys.targetUUID), DockPinFixtures.sidecarUUID)
        XCTAssertEqual(h.manager.targetChoices.count, 4)
        XCTAssertEqual(h.manager.targetChoices.last?.kind,
                       DockPinTargetChoice.Kind.disconnected(lastName: Fixture.sidecar.name))

        h.fakes.displays.displays = DockPinFixtures.threeWithSidecar
        h.dockOn = Fixture.sidecar.id
        h.fakes.displayChanges.send(.reconfigured)
        h.advance(0.5)
        XCTAssertFalse(h.manager.usingFallbackAnchor)
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.sidecar.name), "고정 화면이 Sidecar로 돌아온다")
        XCTAssertEqual(h.manager.targetChoices.map(\.id),
                       ["main", "BUILTIN-UUID", "LG-UUID", DockPinFixtures.sidecarUUID])
    }

    func test_AC15_4_drivingSidecarRemoved_cgCallback_abortsThatTick_restoresToAnchorCenter() {
        let h = drivingHarness("AC15_4", cursor: Fixture.cursorOnSidecar)
        h.advance(0.1)
        let before = h.moves.count
        h.fakes.displays.displays = [Fixture.builtIn]
        h.fakes.displayChanges.send(.reconfigured)
        XCTAssertEqual(h.moves.count, before + 1, "디바운스 없이 그 자리에서 복원 1회")
        XCTAssertEqual(h.moves.last, Fixture.builtInCenter, "저장 위치가 분리된 화면 → 고정 화면 가운데(N10)")
        h.advance(0.1)
        XCTAssertEqual(h.moves.count, before + 1, "이동이 멈췄다")
        XCTAssertEqual(h.retryDelays, [], "실패 횟수 증가 없음")
    }

    // MARK: - (r6.5) VULN-006 — .needsPermission 새 프로세스 확인 백오프(R9.6)
    //
    // 권한을 끝내 주지 않으면 5초마다 자식 프로세스를 띄워 하루 약 1.7만 회가 된다(EDR 소음·배터리).
    // 규칙: .needsPermission에 들어온(또는 초기화된) 뒤 1분 미만 5 s, 10분 미만 30 s, 그 뒤 60 s.
    // 초기화: 접근성 알림(R9.5), 앱 활성화, setEnabled(true), .needsPermission을 떠남. 활성 주기는 5 s 그대로.

    private func needsPermissionHarness(_ name: String) -> Harness {
        let h = harness(name)
        h.fakes.permission.trusted = false
        h.fakes.permission.autoRespondFresh = .some(false)   // 새 프로세스 확인도 늘 "권한 없음"
        h.start()
        XCTAssertEqual(h.manager.status, .needsPermission, "사전 조건")
        return h
    }

    func test_VULN006_needsPermission_freshAlwaysFalse_5sForOneMinute_then30s_then60s() {
        let h = needsPermissionHarness("VULN006_backoff")
        h.advance(60)
        XCTAssertEqual(h.fakes.permission.freshCount, 12, "첫 1분은 5초마다(t0+5 … t0+60)")
        h.advance(30)
        XCTAssertEqual(h.fakes.permission.freshCount, 13, "그 뒤 30초 간격(t0+90)")
        h.advance(510)
        XCTAssertEqual(h.fakes.permission.freshCount, 30, "t0+600까지 30초 간격 18회")
        h.advance(120)
        XCTAssertEqual(h.fakes.permission.freshCount, 32, "10분 뒤 60초 간격(t0+660, t0+720)")
        let delays = h.fakes.scheduler.scheduledDelays(.repeating(.freshTrustCheck))
        let expected: [TimeInterval] = Array(repeating: 5, count: 12) + Array(repeating: 30, count: 18) + [60, 60]
        XCTAssertEqual(Array(delays.prefix(32)), expected)
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.repeating(.freshTrustCheck)), 1, "반복 타이머는 종류당 1개")
        XCTAssertEqual(h.fakes.permission.promptCount, 0, "프롬프트 없음")
        XCTAssertEqual(h.manager.status, .needsPermission)
    }

    func test_VULN006_accessibilityNotification_resetsCadenceTo5s() {
        let h = needsPermissionHarness("VULN006_ax")
        h.advance(700)                                        // 60초 간격 구간(다음 확인 t0+720)
        let before = h.fakes.permission.freshCount
        h.fakes.systemEvents.send(.accessibilityChanged)
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.freshCount, before + 1, "알림 뒤 5초 안에 확인")
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.freshCount, before + 2, "다시 5초 간격")
        h.advance(50)
        XCTAssertEqual(h.fakes.permission.freshCount, before + 12, "알림부터 1분은 5초 간격")
        h.advance(30)
        XCTAssertEqual(h.fakes.permission.freshCount, before + 13, "그 뒤 다시 30초 간격")
    }

    func test_VULN006_appBecameActive_resetsCadenceTo5s() {
        let h = needsPermissionHarness("VULN006_app")
        h.advance(700)
        let before = h.fakes.permission.freshCount
        h.fakes.systemEvents.send(.appBecameActive)
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.freshCount, before + 1, "앱 활성화 뒤 5초 안에 확인")
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.freshCount, before + 2, "다시 5초 간격")
    }

    func test_VULN006_reEnable_resetsCadenceTo5s() {
        let h = needsPermissionHarness("VULN006_enable")
        h.advance(700)
        h.manager.setEnabled(false)
        h.manager.setEnabled(true)
        XCTAssertEqual(h.manager.status, .needsPermission, "사전 조건")
        let before = h.fakes.permission.freshCount
        h.advance(60)
        XCTAssertEqual(h.fakes.permission.freshCount, before + 12, "다시 켜면 첫 1분은 5초 간격")
    }

    func test_VULN006_grantWhileBackedOff_activeCadenceBackTo5s() {
        let h = needsPermissionHarness("VULN006_grant")
        h.advance(700)                                        // 다음 확인 t0+720
        h.fakes.permission.trusted = true
        h.fakes.permission.autoRespondFresh = .some(true)
        h.advance(1)                                          // permissionPoll → 활성
        XCTAssertTrue(h.fakes.tap.isRunning, "사전 조건: 권한 → 탭 실행")
        let before = h.fakes.permission.freshCount
        h.advance(5)
        XCTAssertEqual(h.fakes.permission.freshCount, before + 1, "활성이 되면 5초 간격으로 돌아온다")
        h.advance(100)
        XCTAssertEqual(h.fakes.permission.freshCount, before + 21, "활성 주기는 계속 5초")
    }

    func test_VULN006_freshTrueGrantWhileBackedOff_activeCadenceBackTo5s() {
        let h = needsPermissionHarness("VULN006_freshGrant")
        h.advance(700)                                        // 다음 확인 t0+720
        h.fakes.permission.autoRespondFresh = .some(true)
        h.fakes.systemEvents.send(.accessibilityChanged)      // 5초 안 확인 → 새 프로세스 true → 활성(래치 true)
        h.advance(5)
        XCTAssertTrue(h.fakes.tap.isRunning, "사전 조건: 새 프로세스 확인 true → 탭 실행")
        h.fakes.permission.trusted = true                      // 이후 프로세스 안 판정도 true(래치 해제)
        let before = h.fakes.permission.freshCount
        h.advance(100)
        XCTAssertEqual(h.fakes.permission.freshCount, before + 20, "활성 주기 5초")
    }

    func test_VULN006_activeCadence_staysEvery5s_beyondTenMinutes() {
        let h = harness("VULN006_active")
        h.fakes.permission.autoRespondFresh = .some(true)
        h.start()
        XCTAssertEqual(h.manager.status, .pinned(displayName: Fixture.builtIn.name), "사전 조건")
        h.advance(720)
        XCTAssertEqual(h.fakes.permission.freshCount, 144, "활성 중에는 백오프 없음(5초마다)")
        XCTAssertEqual(Set(h.fakes.scheduler.scheduledDelays(.repeating(.freshTrustCheck))), [5])
    }
}
