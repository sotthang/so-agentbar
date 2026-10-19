import XCTest
import CoreGraphics
@testable import SoAgentBar

// MARK: - DockPinFakes
//
// SPEC-004 커밋 6(시작) — Dock 고정 테스트 기반(arch §5). 커밋 7·8에서 넓힌다.
// 앱 모듈의 프로토콜을 다시 선언하지 않고 바로 따른다(arch §5, V10 — 이름 그림자 방지).
//
// 안전 규칙: 어떤 가짜도 실제 시스템을 부르지 않는다. CGWindowList·이벤트 탭·이벤트 전송·커서 이동·
// 디스플레이/알림 등록·UserDefaults.standard 쓰기가 0이다. 시간은 FakeDockPinScheduler.advance(by:)로만 흐른다.
//
// arch §5와 다른 점(빌드 경고 0을 위해):
// - DockPinCallLog는 @MainActor가 아니다. 액터 없는 프로토콜(DockPinEventTapping)을 따르는 FakeDockPinTap이
//   동기 메서드 안에서 로그를 남겨야 하기 때문이다. 쓰기는 모두 메인(테스트 스레드)에서 일어난다.

// MARK: - 호출 순서 로그 (AC8.4, AC9.1, AC12.1)

final class DockPinCallLog {
    private(set) var entries: [String] = []

    func add(_ entry: String) { entries.append(entry) }

    func clear() { entries.removeAll() }

    /// 주어진 접두로 시작하는 항목만(순서 유지)
    func entries(prefix: String) -> [String] { entries.filter { $0.hasPrefix(prefix) } }
}

// MARK: - 가짜 스케줄러

/// 시계 + 일회성 예약. 실제로 기다리지 않는다. `advance(by:)`가 시각 순서대로(같은 시각은 예약 순서) 실행하고,
/// 실행 중에 새로 예약된 작업도 목표 시각 안이면 같은 호출에서 실행한다.
@MainActor final class FakeDockPinScheduler: DockPinScheduling {

    final class Token: DockPinCancellable {
        private(set) var isCancelled = false
        func cancel() { isCancelled = true }
    }

    private struct Entry {
        let id: Int
        let fireAt: TimeInterval
        let kind: DockPinTimerKind
        let work: @MainActor () -> Void
        let token: Token
    }

    var now: TimeInterval = 1000
    /// AC1.2 "타이머 생성 0회"
    private(set) var createdCount = 0
    /// 실행된 작업 종류(실행 순서)
    private(set) var firedKinds: [DockPinTimerKind] = []

    private var entries: [Entry] = []
    private var nextID = 0
    private var history: [DockPinTimerKind: [TimeInterval]] = [:]

    private static let epsilon: TimeInterval = 1e-9

    @discardableResult
    func schedule(after delay: TimeInterval, kind: DockPinTimerKind,
                  _ work: @escaping @MainActor () -> Void) -> DockPinCancellable {
        let token = Token()
        createdCount += 1
        history[kind, default: []].append(delay)
        entries.append(Entry(id: nextID, fireAt: now + max(0, delay), kind: kind, work: work, token: token))
        nextID += 1
        return token
    }

    /// 취소되지 않고 아직 실행되지 않은 예약 수
    func pendingCount(_ kind: DockPinTimerKind) -> Int {
        entries.filter { $0.kind == kind && !$0.token.isCancelled }.count
    }

    /// 취소되지 않은 전체 예약 수
    var totalPendingCount: Int { entries.filter { !$0.token.isCancelled }.count }

    /// AC4.2 "반복 타이머 0개", AC4.7 매니저 수준
    var pendingRepeatingKinds: Set<DockPinRepeatingTimer> {
        var kinds = Set<DockPinRepeatingTimer>()
        for entry in entries where !entry.token.isCancelled {
            if case .repeating(let timer) = entry.kind { kinds.insert(timer) }
        }
        return kinds
    }

    /// 지금까지 이 종류로 예약된 지연 값(예약 순서, 취소·실행 여부와 무관) — AC5.11, AC7.5, AC8.6
    func scheduledDelays(_ kind: DockPinTimerKind) -> [TimeInterval] {
        history[kind] ?? []
    }

    /// 가장 이른 대기 예약까지 남은 시간(없으면 nil)
    func timeUntilNext(_ kind: DockPinTimerKind) -> TimeInterval? {
        entries.filter { $0.kind == kind && !$0.token.isCancelled }.map { $0.fireAt - now }.min()
    }

    /// 시각을 seconds만큼 진행하며 그 사이 예약을 시각 순서대로 실행한다.
    func advance(by seconds: TimeInterval) {
        let target = now + max(0, seconds)
        while true {
            entries.removeAll { $0.token.isCancelled }
            let due = entries.filter { $0.fireAt <= target + Self.epsilon }
            guard let next = due.min(by: { ($0.fireAt, $0.id) < ($1.fireAt, $1.id) }) else { break }
            entries.removeAll { $0.id == next.id }
            now = max(now, next.fireAt)
            firedKinds.append(next.kind)
            next.work()
        }
        now = max(now, target)
    }
}

// MARK: - 디스플레이

@MainActor final class FakeDockPinDisplays: DockPinDisplayProviding {
    var displays: [DockPinDisplay]
    var mainID: CGDirectDisplayID
    private(set) var readCount = 0

    init(displays: [DockPinDisplay] = DockPinFixtures.thisMac, mainID: CGDirectDisplayID = DockPinFixtures.builtIn.id) {
        self.displays = displays
        self.mainID = mainID
    }

    func allDisplays() -> [DockPinDisplay] {
        readCount += 1
        return displays
    }

    func mainDisplayID() -> CGDirectDisplayID { mainID }
}

@MainActor final class FakeDockPinDisplayChanges: DockPinDisplayChangeObserving {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var handler: (@MainActor (DockPinDisplaySignal) -> Void)?
    private let log: DockPinCallLog?

    init(log: DockPinCallLog? = nil) { self.log = log }

    var isObserving: Bool { handler != nil }

    func start(_ handler: @escaping @MainActor (DockPinDisplaySignal) -> Void) {
        startCount += 1
        self.handler = handler
        log?.add("displayChanges.start")
    }

    func stop() {
        stopCount += 1
        handler = nil
        log?.add("displayChanges.stop")
    }

    /// 등록된 동안만 전달한다(실제 어댑터와 같다)
    func send(_ signal: DockPinDisplaySignal) { handler?(signal) }
}

// MARK: - Dock 설정·Spaces·PID

@MainActor final class FakeDockPinDockPreferences: DockPinDockPreferencesProviding {
    var orientationValue: DockPinOrientation = .bottom
    var separateSpaces = true
    var pid: pid_t? = DockPinFixtures.dockPID
    private(set) var orientationReadCount = 0
    /// AC4.9
    private(set) var spacesReadCount = 0
    private(set) var pidReadCount = 0

    func orientation() -> DockPinOrientation {
        orientationReadCount += 1
        return orientationValue
    }

    func screensHaveSeparateSpaces() -> Bool {
        spacesReadCount += 1
        return separateSpaces
    }

    func dockPID() -> pid_t? {
        pidReadCount += 1
        return pid
    }
}

// MARK: - 권한

@MainActor final class FakeDockPinPermission: DockPinPermissionProviding {
    var trusted = true
    private(set) var checkCount = 0
    private(set) var promptCount = 0
    private(set) var openCount = 0
    private let log: DockPinCallLog?

    init(log: DockPinCallLog? = nil) { self.log = log }

    func isTrusted() -> Bool {
        checkCount += 1
        return trusted
    }

    func requestTrustPrompt() {
        promptCount += 1
        log?.add("permission.prompt")
    }

    func openPrivacySettings() {
        openCount += 1
        log?.add("permission.open")
    }
}

// MARK: - 세션

@MainActor final class FakeDockPinSession: DockPinSessionProviding {
    var locked = false
    var onConsole = true
    var buttonDown = false
    /// 기본은 P3(0.5 s)를 넉넉히 넘긴 유휴
    var idle: TimeInterval = 10

    func isScreenLocked() -> Bool { locked }
    func isOnConsole() -> Bool { onConsole }
    func isAnyButtonDown() -> Bool { buttonDown }
    func secondsSinceLastInput() -> TimeInterval { idle }
}

// MARK: - 시스템 알림

@MainActor final class FakeDockPinSystemEvents: DockPinSystemEventObserving {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var handler: (@MainActor (DockPinSystemEvent) -> Void)?
    private let log: DockPinCallLog?

    init(log: DockPinCallLog? = nil) { self.log = log }

    var isObserving: Bool { handler != nil }

    func start(_ handler: @escaping @MainActor (DockPinSystemEvent) -> Void) {
        startCount += 1
        self.handler = handler
        log?.add("systemEvents.start")
    }

    func stop() {
        stopCount += 1
        handler = nil
        log?.add("systemEvents.stop")
    }

    func send(_ event: DockPinSystemEvent) { handler?(event) }
}

// MARK: - 이벤트 전송 (warp 없음 — AC8.3·AC13.3)

@MainActor final class FakeDockPinPoster: DockPinEventPosting {
    var cursor: CGPoint? = CGPoint(x: 500, y: 500)
    private(set) var moves: [CGPoint] = []
    private(set) var cursorReadCount = 0
    /// 커밋 7 — 시계를 주면 이동마다 그 시각을 moveTimes에 남긴다(AC8.4·AC8.4c 시각 검증). 없으면 기록 안 함
    var clock: (@MainActor () -> TimeInterval)?
    private(set) var moveTimes: [TimeInterval] = []
    private let log: DockPinCallLog?

    init(log: DockPinCallLog? = nil) { self.log = log }

    func cursorLocation() -> CGPoint? {
        cursorReadCount += 1
        return cursor
    }

    /// 실제 커서는 움직이지 않는다. 기록하고 가짜 커서만 옮긴다.
    func postTaggedMouseMove(to point: CGPoint) {
        moves.append(point)
        if let clock { moveTimes.append(clock()) }
        cursor = point
        log?.add("move")
    }
}

// MARK: - 이벤트 탭 (액터 없음 — 프로토콜과 같다)

final class FakeDockPinTap: DockPinEventTapping {
    var startSucceeds = true
    var reenableResult = false
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var reenableCount = 0
    private(set) var drainCount = 0
    private(set) var snapshots: [DockPinGuardSnapshot] = []
    var onOptionPassSignal: (() -> Void)?
    /// 테스트가 직접 올린다(AC8.5)
    var userActivityCount: UInt64 = 0

    private var pendingOptionPasses: [CGDirectDisplayID: TimeInterval] = [:]
    private var hadOptionPass = false
    private let log: DockPinCallLog?

    init(log: DockPinCallLog? = nil) { self.log = log }

    func start() -> Bool {
        startCount += 1
        isRunning = startSucceeds
        log?.add(startSucceeds ? "tap.start" : "tap.start(failed)")
        return startSucceeds
    }

    func stop() {
        stopCount += 1
        isRunning = false
        log?.add("tap.stop")
    }

    func update(snapshot: DockPinGuardSnapshot) {
        snapshots.append(snapshot)
        log?.add("tap.update")
    }

    func reenableIfNeeded() -> Bool {
        reenableCount += 1
        return reenableResult
    }

    /// 실제 신호 상자와 같다: 칸은 화면별 최신값으로 남기고(지우지 않음) 알림 플래그만 내린다(AC5.13)
    func drainSignals() -> DockPinTapSignals {
        drainCount += 1
        let signals = DockPinTapSignals(userActivityCount: userActivityCount,
                                        optionPasses: pendingOptionPasses,
                                        hadOptionPass: hadOptionPass)
        hadOptionPass = false
        return signals
    }

    /// Option 통과 1건을 기록하고 메인 깨우기(onOptionPassSignal)를 흉내 낸다(AC7.5)
    func emitOptionPass(_ id: CGDirectDisplayID, at uptime: TimeInterval) {
        pendingOptionPasses[id] = uptime
        hadOptionPass = true
        onOptionPassSignal?()
    }
}

// MARK: - Dock 위치 조회기 (매니저·Relocator 테스트용)

@MainActor final class FakeDockPinLocator: DockPinDockLocating {
    /// nil = 응답하지 않음(AC8.4c). 값이면 그 자리에서(동기) completion을 부른다.
    var respond: (DockPinLocateMode, TimeInterval) -> DockPinLocateOutcome? = { _, _ in .placement(.unknown) }
    private(set) var requests: [DockPinLocateMode] = []
    private(set) var requestDisplays: [[DockPinDisplay]] = []
    private(set) var invalidateCount = 0
    private(set) var cancelCount = 0

    private var pending: [@MainActor (DockPinLocateOutcome) -> Void] = []
    private let scheduler: FakeDockPinScheduler
    private let log: DockPinCallLog?

    init(scheduler: FakeDockPinScheduler, log: DockPinCallLog? = nil) {
        self.scheduler = scheduler
        self.log = log
    }

    var pendingCount: Int { pending.count }

    func locate(_ mode: DockPinLocateMode, displays: [DockPinDisplay],
                completion: @escaping @MainActor (DockPinLocateOutcome) -> Void) {
        requests.append(mode)
        requestDisplays.append(displays)
        log?.add("locate(\(mode))")
        if let outcome = respond(mode, scheduler.now) {
            log?.add("result")
            completion(outcome)
        } else {
            pending.append(completion)
        }
    }

    /// 응답하지 않았던 요청들에 나중에 답한다
    func completePending(with outcome: DockPinLocateOutcome) {
        let completions = pending
        pending.removeAll()
        for completion in completions {
            log?.add("result")
            completion(outcome)
        }
    }

    func invalidateCache() {
        invalidateCount += 1
        log?.add("locator.invalidateCache")
    }

    /// 실제 조회기와 같다: 진행 중 요청의 completion은 0번
    func cancelAll() {
        cancelCount += 1
        pending.removeAll()
        log?.add("locator.cancelAll")
    }
}

// MARK: - 창 목록 (조회 큐에서 불린다 — AC6.4/6.6/6.8)

/// 실제 DockPinDockLocator에 넣는 가짜 창 목록. 모든 상태는 NSCondition으로 보호한다.
/// `dockWindows`는 부를 때마다 `script`의 다음 원소를 돌려주고, 끝나면 마지막 원소를 계속 돌려준다(빈 script → []).
/// `window(number:)`는 `singleWindows`에서 찾는다.
/// `hold()` 뒤의 호출은 `release()`까지 조회 큐 안에서 막힌다(진행 중 요청 합치기·취소 테스트용).
final class FakeDockPinWindowListing: DockPinWindowListing, @unchecked Sendable {

    struct DockWindowsCall: Equatable {
        let pid: pid_t
        let layer: Int
    }

    private let condition = NSCondition()
    private var _script: [[DockPinWindowInfo]]
    private var _singleWindows: [CGWindowID: DockPinWindowInfo]
    private var _scriptIndex = 0
    private var _calledOnMainThread: [Bool] = []
    private var _dockWindowsCalls: [DockWindowsCall] = []
    private var _windowCalls: [CGWindowID] = []
    private var _active = 0
    private var _maxConcurrent = 0
    private var _held = false

    init(script: [[DockPinWindowInfo]] = [], singleWindows: [CGWindowID: DockPinWindowInfo] = [:]) {
        _script = script
        _singleWindows = singleWindows
    }

    var script: [[DockPinWindowInfo]] {
        get { locked { _script } }
        set { locked { _script = newValue; _scriptIndex = 0 } }
    }

    var singleWindows: [CGWindowID: DockPinWindowInfo] {
        get { locked { _singleWindows } }
        set { locked { _singleWindows = newValue } }
    }

    /// 호출마다(dockWindows·window 모두) Thread.isMainThread
    var calledOnMainThread: [Bool] { locked { _calledOnMainThread } }
    var dockWindowsCalls: [DockWindowsCall] { locked { _dockWindowsCalls } }
    var windowCalls: [CGWindowID] { locked { _windowCalls } }
    var totalCallCount: Int { locked { _calledOnMainThread.count } }
    /// 동시에 진행된 호출 수의 최대(R6.5 — 1이어야 한다)
    var maxConcurrentCalls: Int { locked { _maxConcurrent } }

    func hold() { locked { _held = true } }

    func release() {
        condition.lock()
        _held = false
        condition.broadcast()
        condition.unlock()
    }

    func dockWindows(pid: pid_t, layer: Int) -> [DockPinWindowInfo] {
        enter()
        defer { leave() }
        return locked {
            _dockWindowsCalls.append(DockWindowsCall(pid: pid, layer: layer))
            guard !_script.isEmpty else { return [] }
            let value = _script[min(_scriptIndex, _script.count - 1)]
            _scriptIndex += 1
            return value
        }
    }

    func window(number: CGWindowID) -> DockPinWindowInfo? {
        enter()
        defer { leave() }
        return locked {
            _windowCalls.append(number)
            return _singleWindows[number]
        }
    }

    private func enter() {
        let onMain = Thread.isMainThread
        condition.lock()
        _calledOnMainThread.append(onMain)
        while _held { condition.wait() }
        _active += 1
        _maxConcurrent = max(_maxConcurrent, _active)
        condition.unlock()
    }

    private func leave() {
        locked { _active -= 1 }
    }

    private func locked<T>(_ body: () -> T) -> T {
        condition.lock()
        defer { condition.unlock() }
        return body()
    }
}

/// 조회기에 넣는 pause 기록기. 실제로 자지 않는다.
final class FakeDockPinPause: @unchecked Sendable {
    private let lock = NSLock()
    private var _intervals: [TimeInterval] = []

    var intervals: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return _intervals
    }

    var closure: @Sendable (TimeInterval) -> Void {
        { [self] interval in
            lock.lock()
            _intervals.append(interval)
            lock.unlock()
        }
    }
}

// MARK: - 의존성 묶음

struct DockPinFakeSet {
    let scheduler: FakeDockPinScheduler
    let displays: FakeDockPinDisplays
    let displayChanges: FakeDockPinDisplayChanges
    let dockPreferences: FakeDockPinDockPreferences
    let permission: FakeDockPinPermission
    let session: FakeDockPinSession
    let systemEvents: FakeDockPinSystemEvents
    let poster: FakeDockPinPoster
    let tap: FakeDockPinTap
    let locator: FakeDockPinLocator
    let log: DockPinCallLog
}

/// 가짜 10개(로그 하나 공유)로 DockPinDependencies를 만든다.
@MainActor func makeDockPinTestDependencies() -> (DockPinDependencies, DockPinFakeSet) {
    let log = DockPinCallLog()
    let scheduler = FakeDockPinScheduler()
    let fakes = DockPinFakeSet(scheduler: scheduler,
                               displays: FakeDockPinDisplays(),
                               displayChanges: FakeDockPinDisplayChanges(log: log),
                               dockPreferences: FakeDockPinDockPreferences(),
                               permission: FakeDockPinPermission(log: log),
                               session: FakeDockPinSession(),
                               systemEvents: FakeDockPinSystemEvents(log: log),
                               poster: FakeDockPinPoster(log: log),
                               tap: FakeDockPinTap(log: log),
                               locator: FakeDockPinLocator(scheduler: scheduler, log: log),
                               log: log)
    let dependencies = DockPinDependencies(scheduler: fakes.scheduler,
                                           displays: fakes.displays,
                                           displayChanges: fakes.displayChanges,
                                           dockPreferences: fakes.dockPreferences,
                                           permission: fakes.permission,
                                           session: fakes.session,
                                           systemEvents: fakes.systemEvents,
                                           poster: fakes.poster,
                                           tap: fakes.tap,
                                           locator: fakes.locator)
    return (dependencies, fakes)
}

// MARK: - 설정 저장소 (AC1.7 — standard는 쓰지 않는다)

func dockPinSuiteName(_ name: String) -> String { "test.DockPin.\(name)" }

/// 빈 suite를 돌려준다. 테스트는 tearDown에서 removeDockPinSuite(_:)를 부른다.
@MainActor func makeDockPinSuite(_ name: String) -> UserDefaults {
    let suiteName = dockPinSuiteName(name)
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        preconditionFailure("UserDefaults(suiteName: \(suiteName)) == nil")
    }
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@MainActor func removeDockPinSuite(_ name: String) {
    let suiteName = dockPinSuiteName(name)
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
}

// MARK: - 고정 배치 (F1, AC3.1, AC15.x). 좌표는 모두 CG 전역(F11)

enum DockPinFixtures {
    static let sidecarUUID = "BAB59A29-3097-4311-993B-57A74473F53E"
    /// F4 실측 Dock 창 번호
    static let dockWindowNumber: CGWindowID = 43
    static let dockPID: pid_t = 777

    /// F1 — 내장, 주 화면 (0,0,1728,1117)
    static let builtIn = display(1, "BUILTIN-UUID", 0, 0, 1728, 1117, name: "Color LCD")
    /// F1 — Sidecar (1728,0,1149,802), 미러 아님
    static let sidecar = display(12, sidecarUUID, 1728, 0, 1149, 802, name: "Sidecar Display (AirPlay)")
    /// AC15.2 — 같은 Sidecar가 내장을 미러링
    static let sidecarMirrored = display(12, sidecarUUID, 0, 0, 1728, 1117, mirrorOf: 1,
                                         name: "Sidecar Display (AirPlay)")
    /// AC15.3 — 가짜 외장(내장 왼쪽)
    static let external2560 = display(5, "LG-UUID", -2560, 0, 2560, 1440, name: "LG UltraFine")

    /// AC3.1 — 좌우 3대, 위쪽 끝 정렬. 가운데가 주 화면
    static let external3008 = display(1, "CENTER-UUID", 0, 0, 3008, 1692, name: "Center")
    static let left1728 = display(2, "LEFT-UUID", -1728, 0, 1728, 1117, name: "Left")
    static let right2560 = display(3, "RIGHT-UUID", 3008, 0, 2560, 1440, name: "Right")

    static var thisMac: [DockPinDisplay] { [builtIn, sidecar] }
    static var threeWithSidecar: [DockPinDisplay] { [builtIn, external2560, sidecar] }
    static var sideBySide3: [DockPinDisplay] { [left1728, external3008, right2560] }

    static func display(_ id: CGDirectDisplayID, _ uuid: String,
                        _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                        mirrorOf: CGDirectDisplayID? = nil, name: String) -> DockPinDisplay {
        DockPinDisplay(id: id, uuid: uuid, bounds: CGRect(x: x, y: y, width: width, height: height),
                       mirrorOf: mirrorOf, name: name)
    }

    /// F11 — Dock 레이어 창 범위 = Dock이 있는 화면 전체 범위
    static func window(_ number: CGWindowID, on display: DockPinDisplay) -> DockPinWindowInfo {
        DockPinWindowInfo(number: number, bounds: display.bounds)
    }
}
