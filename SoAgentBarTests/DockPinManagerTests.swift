import XCTest
import Combine
import CoreGraphics
@testable import SoAgentBar

// MARK: - DockPinManagerTests
//
// SPEC-004 커밋 8 — DockPinManager(arch §2.10, §3) 단위 테스트.
// 커버 AC: AC1.1–1.6, AC4.2–4.4, AC4.6, AC4.8, AC4.9, AC4.10(a–c), AC5.11(매니저), AC7.5, AC8.3(매니저 경로),
//          AC8.4c(매니저부), AC8.5–8.8, AC8.9(매니저부), AC8.10(매니저 스냅숏), AC8.11(b,c), AC8.12, AC9.1–9.5,
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
                                              userData: 0, buttonNumber: 0, snapshot: snapshot,
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

    func test_AC9_4_accessibilityNotification_stopsTapImmediately() {
        let h = harness("AC9_4")
        h.start()
        XCTAssertTrue(h.fakes.tap.isRunning, "사전 조건")
        h.fakes.permission.trusted = false
        h.fakes.systemEvents.send(.accessibilityChanged)
        XCTAssertEqual(h.fakes.tap.stopCount, 1, "폴링 틱을 기다리지 않는다")
        XCTAssertFalse(h.fakes.tap.isRunning)
        XCTAssertEqual(h.manager.status, .needsPermission)
    }

    func test_AC9_5_accessibilityNotification_checksNowAndAfter0_5s() {
        let h = harness("AC9_5")
        h.start()
        let checks = h.fakes.permission.checkCount
        h.fakes.systemEvents.send(.accessibilityChanged)
        XCTAssertEqual(h.fakes.permission.checkCount, checks + 1, "즉시 1회")
        XCTAssertEqual(h.fakes.scheduler.pendingCount(.permissionRecheck), 1)
        h.advance(0.5)
        XCTAssertEqual(h.fakes.permission.checkCount, checks + 2, "0.5 s 뒤 1회 더")
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
}
