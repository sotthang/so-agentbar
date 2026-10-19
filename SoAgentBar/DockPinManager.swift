import Combine
import CoreGraphics
import Foundation

// SPEC-004 Dock Pin — 조정자 (arch §2.10, §3, 커밋 8)
// @MainActor ObservableObject. 설정 소유(R1), 활성화·자동 on/off(R4), 탭 수명(R5.8–5.11), Option 존중(R7),
// 되돌리기 조정(R8), 권한(R9), 세션(R10), 상태 발행(R11, S1, S5), 종료(R12), Sidecar(R15).
//
// 모든 신호는 reconcile()/publish() 두 곳을 거친다(R10.5). 판정은 전부 순수 함수(DockPinPolicy, DockPinDisplayMap)이고
// 이 파일은 입력을 모으고 결과를 적용·예약만 한다. 시스템 접점은 주입한 DockPinDependencies뿐이다.

@MainActor
final class DockPinManager: ObservableObject {
    // R1.1 — 설정 소유
    @Published private(set) var isEnabled: Bool
    @Published private(set) var target: DockPinTarget
    @Published private(set) var targetDisplayName: String?
    // R11.1 — 표시
    @Published private(set) var status: DockPinStatus = .off
    @Published private(set) var usingFallbackAnchor = false
    // S1 — 피커 선택지. isEnabled 동안 디스플레이 재계산마다 갱신, 꺼지면 []
    @Published private(set) var targetChoices: [DockPinTargetChoice] = []

    private enum Keys {
        static let enabled = "dockPinEnabled"
        static let targetUUID = "dockPinTargetDisplayUUID"
        static let targetName = "dockPinTargetDisplayName"
    }

    private let defaults: UserDefaults
    private let deps: DockPinDependencies
    private let isInert: Bool
    private var isShutDown = false
    private var observing = false

    // 입력 캐시
    private var hasPermission = false
    private var allDisplays: [DockPinDisplay] = []
    private var mainID: CGDirectDisplayID = 0
    private var separateSpaces = true
    private var orientation: DockPinOrientation = .bottom
    private var session = DockPinSessionState()

    // 파생
    private var activation: DockPinActivation = .inactive(.off)
    private var layout: DockPinLayout?
    private var lastFingerprint: DockPinConfigFingerprint?
    private var lastPushedSnapshot: DockPinGuardSnapshot?

    // 위치·되돌리기
    private var placement: DockPinPlacement?
    private var lastConfirmedOnAnchorAt: TimeInterval?
    private var optionPasses: [CGDirectDisplayID: TimeInterval] = [:]
    /// 오버라이드를 풀 때 그 화면의 Option 통과 기록을 버린 시각. 탭 칸은 지워지지 않으므로 이 시각 이전 값은 다시 합치지 않는다.
    private var optionPassFloor: [CGDirectDisplayID: TimeInterval] = [:]
    private var overrideDisplayID: CGDirectDisplayID?
    private var phase: DockPinRelocationPhase = .idle
    private var failureCount = 0
    private var tapState: DockPinTapState = .none

    // 타이머
    private var repeating: [DockPinRepeatingTimer: DockPinCancellable] = [:]
    private var retryToken: DockPinCancellable?            // != nil ⇔ retryScheduled
    private var debounceToken: DockPinCancellable?
    private var waitRecheckToken: DockPinCancellable?
    private var settleToken: DockPinCancellable?
    private var permissionRecheckToken: DockPinCancellable?
    private var optionCheckTokens: [DockPinCancellable] = []

    private lazy var relocator = DockPinRelocator(
        poster: deps.poster, locator: deps.locator, scheduler: deps.scheduler,
        userActivityCount: { [tap = deps.tap] in tap.userActivityCount },
        restorePoint: { [weak self] saved in self?.restorePoint(for: saved) })

    init(defaults: UserDefaults, dependencies: DockPinDependencies, isInert: Bool = false) {
        self.defaults = defaults
        self.deps = dependencies
        self.isInert = isInert
        isEnabled = defaults.bool(forKey: Keys.enabled)
        target = DockPinTarget(storedUUID: defaults.string(forKey: Keys.targetUUID))
        targetDisplayName = defaults.string(forKey: Keys.targetName)
    }

    /// R12.3 생산 연결 지점. 기본 인자가 실제 환경을 읽는다(NSClassFromString은 여기서만).
    static func makeLive(defaults: UserDefaults,
                         environment: [String: String] = ProcessInfo.processInfo.environment,
                         xcTestClassLoaded: Bool = NSClassFromString("XCTestCase") != nil) -> DockPinManager {
        let inert = DockPinPolicy.isTestHost(environment: environment, xcTestClassLoaded: xcTestClassLoaded)
        return DockPinManager(defaults: defaults, dependencies: .live(), isInert: inert)
    }

    // MARK: - 공개 동작

    /// R1.2, R1.5 — 프롬프트 없음
    func startIfEnabled() {
        guard !isInert, !isShutDown, isEnabled, !observing else { return }
        startObserving()
        readAll()
        reconcile()
    }

    /// R1.3, R1.6
    func setEnabled(_ enabled: Bool) {
        guard !isInert, !isShutDown else { return }
        if enabled {
            guard !(isEnabled && observing) else { return }
            defaults.set(true, forKey: Keys.enabled)
            isEnabled = true
            startObserving()
            readAll()
            if !hasPermission { deps.permission.requestTrustPrompt() }     // AC1.3 — 켜는 순간 1회
            reconcile()
        } else {
            defaults.set(false, forKey: Keys.enabled)
            isEnabled = false
            teardown()
            setStatus(.off)
            if !targetChoices.isEmpty { targetChoices = [] }
            if usingFallbackAnchor { usingFallbackAnchor = false }
        }
    }

    /// R1.1, R2.3 — 켜져 있으면 디바운스 없이 다시 계산한다(arch §12 I2)
    func setTarget(_ target: DockPinTarget, displayName: String?) {
        guard !isInert else { return }
        if let uuid = target.storedUUID {
            defaults.set(uuid, forKey: Keys.targetUUID)
        } else {
            defaults.removeObject(forKey: Keys.targetUUID)
        }
        if let displayName {
            defaults.set(displayName, forKey: Keys.targetName)
        } else {
            defaults.removeObject(forKey: Keys.targetName)
        }
        self.target = target
        targetDisplayName = displayName
        if isEnabled && observing && !isShutDown { recomputeDisplays() }
    }

    /// R8.8 — 오버라이드 해제 + 이벤트 계기
    func moveBackNow() {
        guard !isInert, !isShutDown, activation == .active, !phase.isRelocating else { return }
        releaseOverride()
        publish()
        eventTrigger()
    }

    /// R1.4
    func openPermissionSettings() {
        guard !isInert else { return }
        deps.permission.openPrivacySettings()
    }

    /// R12.1, R12.4 멱등
    func shutdown() {
        guard !isInert, !isShutDown else { return }
        isShutDown = true
        teardown()
        setStatus(.off)
    }

    // MARK: - 관찰·입력

    private func startObserving() {
        guard !observing else { return }
        observing = true
        deps.displayChanges.start { [weak self] signal in self?.handleDisplaySignal(signal) }
        deps.systemEvents.start { [weak self] event in self?.handleSystemEvent(event) }
        deps.tap.onOptionPassSignal = { [weak self] in
            MainActor.assumeIsolated { self?.handleOptionPassSignal() }
        }
    }

    /// 권한·디스플레이·Spaces·방향·세션 각 1회
    private func readAll() {
        hasPermission = deps.permission.isTrusted()
        allDisplays = deps.displays.allDisplays()
        mainID = deps.displays.mainDisplayID()
        separateSpaces = deps.dockPreferences.screensHaveSeparateSpaces()
        orientation = deps.dockPreferences.orientation()
        session.locked = deps.session.isScreenLocked()
        session.onConsole = deps.session.isOnConsole()
    }

    private var activationInputs: DockPinActivationInputs {
        DockPinActivationInputs(enabled: isEnabled, hasPermission: hasPermission,
                                activeDisplayCount: DockPinDisplayMap.activeDisplays(allDisplays).count,
                                separateSpaces: separateSpaces, orientation: orientation)
    }

    private var currentFingerprint: DockPinConfigFingerprint {
        DockPinConfigFingerprint(
            baseLayout: DockPinDisplayMap.layout(allDisplays: allDisplays, target: target,
                                                 mainID: mainID, overrideDisplayID: nil),
            inputs: activationInputs)
    }

    // MARK: - reconcile (arch §3.2)

    /// scanOnActivation == false면 비활성 → 활성 전환 때의 첫 조회를 호출측(이벤트 계기)에 맡긴다.
    private func reconcile(scanOnActivation: Bool = true) {
        activation = DockPinPolicy.activation(activationInputs)
        var scanAfter = false
        if activation != .active {
            if deps.tap.isRunning { deps.tap.stop() }           // R9.3 — 탭 제거가 먼저
            relocator.abort(.deactivated)
            phase = .idle
            failureCount = 0
            cancel(&retryToken)
            cancel(&waitRecheckToken)
            tapState = .none
            placement = nil
            overrideDisplayID = nil
            lastPushedSnapshot = nil
        } else if tapState == .none {
            placement = nil                                     // R11.7 6번 — 활성화 직후 .checking
            if deps.tap.start() {
                tapState = .running
                lastPushedSnapshot = nil
                scanAfter = scanOnActivation
            } else {
                tapState = .retrying(attempt: 1)
            }
        }
        publish()
        syncRepeatingTimers()
        lastFingerprint = currentFingerprint
        if scanAfter { activationScan() }
    }

    /// arch §12 I9 — 조회는 .event(백오프 무시), 판정 계기는 .poll
    private func activationScan() {
        locate(.event) { [weak self] outcome in self?.onPlacement(outcome, trigger: .poll) }
    }

    /// 레이아웃·선택지·스냅숏·상태
    private func publish() {
        layout = DockPinDisplayMap.layout(allDisplays: allDisplays, target: target,
                                          mainID: mainID, overrideDisplayID: overrideDisplayID)
        let fallback = layout?.anchor.usingFallbackAnchor ?? false
        if usingFallbackAnchor != fallback { usingFallbackAnchor = fallback }
        let choices = isEnabled
            ? DockPinDisplayMap.targetChoices(connected: layout?.displays ?? DockPinDisplayMap.activeDisplays(allDisplays),
                                              target: target, savedName: targetDisplayName)
            : []
        if targetChoices != choices { targetChoices = choices }
        pushSnapshotIfChanged()
        let overrideName = overrideDisplayID.flatMap { id in layout?.displays.first { $0.id == id }?.name }
        setStatus(DockPinPolicy.status(DockPinStatusInputs(
            activation: activation, tapState: tapState, phase: phase, placement: placement,
            anchorID: layout?.anchor.display.id, anchorName: layout?.anchor.display.name ?? "",
            overrideDisplayName: overrideName, hasRelocationTarget: layout?.relocationTarget != nil)))
    }

    private func setStatus(_ newValue: DockPinStatus) {
        if status != newValue { status = newValue }
    }

    private func pushSnapshotIfChanged() {
        guard deps.tap.isRunning else { return }
        let snapshot = DockPinGuardSnapshot(rows: activation == .active ? (layout?.rows ?? []) : [],
                                            isRelocating: phase.isRelocating,
                                            isDriving: phase.isDriving)
        guard snapshot != lastPushedSnapshot else { return }
        lastPushedSnapshot = snapshot
        deps.tap.update(snapshot: snapshot)
    }

    // MARK: - 반복 타이머 (R4.4)

    private func syncRepeatingTimers() {
        let required = isEnabled && !isShutDown
            ? DockPinPolicy.requiredTimers(activation: activation, tapState: tapState) : []
        for (kind, token) in repeating where !required.contains(kind) {
            token.cancel()
            repeating[kind] = nil
        }
        for kind in required where repeating[kind] == nil {
            scheduleRepeating(kind)
        }
    }

    private func interval(_ kind: DockPinRepeatingTimer) -> TimeInterval {
        switch kind {
        case .permissionPoll: return DockPinTuning.permissionPollInterval
        case .dockPoll: return DockPinTuning.dockPollInterval
        case .prefsPoll: return DockPinTuning.prefsPollInterval
        case .tapWatchdog: return DockPinTuning.tapWatchdogInterval
        case .tapRetry:
            if case .retrying(let attempt) = tapState { return DockPinPolicy.tapRetryDelay(attempt: attempt) }
            return DockPinPolicy.tapRetryDelay(attempt: 1)
        }
    }

    private func scheduleRepeating(_ kind: DockPinRepeatingTimer) {
        repeating[kind] = deps.scheduler.schedule(after: interval(kind), kind: .repeating(kind)) { [weak self] in
            self?.fireRepeating(kind)
        }
    }

    private func fireRepeating(_ kind: DockPinRepeatingTimer) {
        repeating[kind] = nil
        switch kind {
        case .permissionPoll: checkPermission()
        case .dockPoll: locate(.quick) { [weak self] outcome in self?.onPlacement(outcome, trigger: .poll) }
        case .prefsPoll:                                         // R4.5 — 방향과 권한만
            orientation = deps.dockPreferences.orientation()
            hasPermission = deps.permission.isTrusted()
            reconcile()
        case .tapWatchdog: _ = deps.tap.reenableIfNeeded()       // R5.8
        case .tapRetry: retryTap()
        }
        guard isEnabled, !isShutDown, repeating[kind] == nil,
              DockPinPolicy.requiredTimers(activation: activation, tapState: tapState).contains(kind) else { return }
        scheduleRepeating(kind)
    }

    /// AC5.11
    private func retryTap() {
        guard activation == .active, case .retrying(let attempt) = tapState else { return }
        if deps.tap.start() {
            tapState = .running
            lastPushedSnapshot = nil
            reconcile()
            activationScan()
        } else {
            tapState = .retrying(attempt: attempt + 1)
            publish()
        }
    }

    // MARK: - 권한 (R9)

    private func checkPermission() {
        let trusted = deps.permission.isTrusted()
        if hasPermission && !trusted {
            if deps.tap.isRunning { deps.tap.stop() }           // AC9.1 — 다른 어떤 처리보다 먼저
            tapState = .none
            relocator.abort(.permissionLost)
            hasPermission = false
            reconcile()
        } else if !hasPermission && trusted {
            hasPermission = true
            reconcile()
        }
    }

    // MARK: - 디스플레이 (R4.3, R4.8)

    private func handleDisplaySignal(_ signal: DockPinDisplaySignal) {
        if signal == .reconfigured && phase.isRelocating {      // R4.3 — 그 자리에서 중단, 횟수 그대로
            relocator.abort(.displayReconfigured)
            phase = .idle
            publish()
        }
        cancel(&debounceToken)
        debounceToken = deps.scheduler.schedule(after: DockPinTuning.displayDebounce, kind: .displayDebounce) { [weak self] in
            self?.debounceToken = nil
            self?.recomputeDisplays()
        }
    }

    private func recomputeDisplays() {
        allDisplays = deps.displays.allDisplays()
        mainID = deps.displays.mainDisplayID()
        hasPermission = deps.permission.isTrusted()
        separateSpaces = deps.dockPreferences.screensHaveSeparateSpaces()
        orientation = deps.dockPreferences.orientation()
        let changed = DockPinPolicy.isDisplayConfigChange(previous: lastFingerprint, current: currentFingerprint)
        reconcile(scanOnActivation: !changed)
        if changed { handleConfigChange() }
    }

    /// R4.8로 인정된 구성 변경 — 변하지 않았으면 부르지 않는다(AC4.10 a/b)
    private func handleConfigChange() {
        guard activation == .active else { return }
        if phase.isRelocating {                                  // arch §12 I4
            relocator.abort(.displayReconfigured)
            phase = .idle
        }
        releaseOverride()
        placement = nil
        publish()
        eventTrigger()
    }

    // MARK: - 세션·시스템 알림 (R10, R6.1, R9.5, R4.5)

    private func handleSystemEvent(_ event: DockPinSystemEvent) {
        switch event {
        case .willSleep:
            session.asleep = true
            interruptDrive(.sleep)
        case .didWake, .screensDidWake:
            session.asleep = false
            scheduleSettle(isEventTrigger: true)
        case .screenLocked:
            session.locked = true
            interruptDrive(.locked)
        case .screenUnlocked:
            session.locked = false
            scheduleSettle(isEventTrigger: true)
        case .sessionResignedActive:
            session.onConsole = false
            interruptDrive(.sessionInactive)
        case .sessionBecameActive:
            session.onConsole = true
            scheduleSettle(isEventTrigger: false)
        case .dockRelaunched:
            guard tapState == .running else { return }
            deps.locator.invalidateCache()
            activationScan()
        case .accessibilityChanged:                               // R9.5 — 즉시 + 0.5 s 뒤
            checkPermission()
            cancel(&permissionRecheckToken)
            permissionRecheckToken = deps.scheduler.schedule(after: DockPinTuning.permissionNotificationRecheck,
                                                             kind: .permissionRecheck) { [weak self] in
                self?.permissionRecheckToken = nil
                self?.checkPermission()
            }
        case .appBecameActive:
            separateSpaces = deps.dockPreferences.screensHaveSeparateSpaces()
            reconcile()
        }
    }

    /// 세션 신호로 진행 중 되돌리기를 멈추고(복원 1회) 다시 판정해 .waiting(사유)로 둔다
    private func interruptDrive(_ reason: DockPinDriveAbortReason) {
        relocator.abort(reason)
        guard activation == .active else { return }
        evaluateRelocation(.poll)
    }

    /// R10.2/R10.3 — 1 s 뒤 다시 읽고, 이벤트 계기면 오버라이드·실패 횟수를 초기화한다
    private func scheduleSettle(isEventTrigger: Bool) {
        cancel(&settleToken)
        settleToken = deps.scheduler.schedule(after: DockPinTuning.settleAfterSessionChange, kind: .sessionSettle) { [weak self] in
            guard let self else { return }
            self.settleToken = nil
            self.readAll()
            self.reconcile(scanOnActivation: !isEventTrigger)
            guard isEventTrigger, self.activation == .active, !self.phase.isRelocating else { return }
            self.releaseOverride()
            self.publish()
            self.eventTrigger()
        }
    }

    // MARK: - Option 통과 (R7)

    private func handleOptionPassSignal() {
        guard observing, !isShutDown else { return }
        let signals = deps.tap.drainSignals()
        for (id, time) in signals.optionPasses where time > (optionPassFloor[id] ?? -.infinity) {
            optionPasses[id] = max(optionPasses[id] ?? -.infinity, time)
        }
        guard signals.hadOptionPass else { return }
        optionCheckTokens.forEach { $0.cancel() }                // 새 통과의 확인 일정이 앞선 일정을 대신한다
        optionCheckTokens.removeAll()
        for delay in DockPinTuning.optionCheckDelays {          // R7.3 / AC7.5
            optionCheckTokens.append(deps.scheduler.schedule(after: delay, kind: .optionCheck) { [weak self] in
                self?.locate(.quick) { [weak self] outcome in self?.onPlacement(outcome, trigger: .poll) }
            })
        }
    }

    /// R7.6 — 오버라이드를 끄고 그 화면의 Option 통과 기록도 버린다(창 10 s는 켤 때만 본다)
    private func releaseOverride() {
        if let id = overrideDisplayID {
            optionPasses[id] = nil
            optionPassFloor[id] = deps.scheduler.now
        }
        overrideDisplayID = nil
    }

    // MARK: - 위치·되돌리기 (R8)

    private func locate(_ mode: DockPinLocateMode, _ completion: @escaping @MainActor (DockPinLocateOutcome) -> Void) {
        deps.locator.locate(mode, displays: layout?.displays ?? DockPinDisplayMap.activeDisplays(allDisplays),
                            completion: completion)
    }

    /// R8.7 이벤트 계기 — 실패 0, 재시도 취소, .failed → .idle, 백오프 무시 조회
    private func eventTrigger() {
        guard activation == .active, tapState == .running else { return }
        failureCount = 0
        cancel(&retryToken)
        if case .failed = phase { phase = .idle }
        locate(.event) { [weak self] outcome in self?.onPlacement(outcome, trigger: .event) }
    }

    private func onPlacement(_ outcome: DockPinLocateOutcome, trigger: DockPinTrigger) {
        guard activation == .active, case .placement(let newPlacement) = outcome else { return }
        placement = newPlacement
        if case .display(let id) = newPlacement, let anchorID = layout?.anchor.display.id {
            if id == anchorID {
                lastConfirmedOnAnchorAt = deps.scheduler.now
                overrideDisplayID = nil
                var wasFailed = false
                if case .failed = phase { wasFailed = true }
                if wasFailed || retryToken != nil {              // R8.7, AC8.12
                    phase = .idle
                    failureCount = 0
                    cancel(&retryToken)
                }
            } else if DockPinPolicy.isUserOverride(dockDisplay: id, anchor: anchorID, optionPasses: optionPasses,
                                                   lastConfirmedOnAnchorAt: lastConfirmedOnAnchorAt,
                                                   now: deps.scheduler.now) {
                overrideDisplayID = id
            }
        }
        publish()
        evaluateRelocation(trigger)
    }

    private func evaluateRelocation(_ trigger: DockPinTrigger) {
        guard !phase.isRelocating else { return }
        cancel(&waitRecheckToken)
        session.locked = deps.session.isScreenLocked()
        session.onConsole = deps.session.isOnConsole()
        let decision = DockPinPolicy.relocationDecision(DockPinRelocationInputs(
            activation: tapState == .running ? activation : .inactive(.off),
            placement: placement, anchorID: layout?.anchor.display.id, phase: phase,
            retryScheduled: retryToken != nil, trigger: trigger,
            isUserOverride: overrideDisplayID != nil,
            hasRelocationTarget: layout?.relocationTarget != nil, session: session,
            anyButtonDown: deps.session.isAnyButtonDown(),
            secondsSinceInput: deps.session.secondsSinceLastInput()))
        switch decision {
        case .go:
            startDrive()
        case .wait(let reason):
            phase = .waiting(reason)
            scheduleWaitRecheck()
            publish()
        case .skip:
            if case .waiting = phase { phase = .idle }
            publish()
        }
    }

    private func scheduleWaitRecheck() {
        cancel(&waitRecheckToken)
        waitRecheckToken = deps.scheduler.schedule(after: DockPinTuning.waitRecheckInterval, kind: .waitRecheck) { [weak self] in
            self?.waitRecheckToken = nil
            self?.evaluateRelocation(.poll)
        }
    }

    private func startDrive() {
        guard let layout, let point = layout.relocationTarget else { return }
        phase = .driving
        publish()
        relocator.start(DockPinDrivePlan(target: point, anchorID: layout.anchor.display.id, displays: layout.displays)) {
            [weak self] outcome in self?.handleDriveOutcome(outcome)
        }
    }

    private func handleDriveOutcome(_ outcome: DockPinDriveOutcome) {
        switch outcome {
        case .succeeded:                                         // arch §12 I7 — 확인 단일 조회
            phase = .verifying
            publish()
            locate(.quick) { [weak self] result in self?.onVerify(result) }
        case .failed:
            handleFailure()
        case .aborted(.userActivity):                            // AC8.5 — 횟수 그대로
            phase = .waiting(.userActive)
            scheduleWaitRecheck()
            publish()
        case .aborted:
            phase = .idle
            publish()
        }
    }

    private func onVerify(_ outcome: DockPinLocateOutcome) {
        guard phase == .verifying else {
            onPlacement(outcome, trigger: .poll)
            return
        }
        if let anchorID = layout?.anchor.display.id, outcome == .placement(.display(anchorID)) {
            phase = .idle
            onPlacement(outcome, trigger: .poll)
        } else {
            if case .placement(let p) = outcome { placement = p }
            handleFailure()
        }
    }

    /// AC8.6 — 1·3·10 s 뒤 재시도, 4번째 실패 뒤 .failed(4)
    private func handleFailure() {
        failureCount += 1
        if let delay = DockPinPolicy.relocationRetryDelay(afterFailures: failureCount) {
            phase = .idle
            cancel(&retryToken)
            retryToken = deps.scheduler.schedule(after: delay, kind: .relocationRetry) { [weak self] in
                guard let self else { return }
                self.retryToken = nil
                self.locate(.quick) { [weak self] outcome in self?.onPlacement(outcome, trigger: .retryTimer) }
            }
        } else {
            phase = .failed(attempts: failureCount)
        }
        publish()
    }

    /// R8.5 예외 1 — 복원 시점에 디스플레이를 다시 읽는다(캐시 없음)
    private func restorePoint(for saved: CGPoint) -> CGPoint? {
        DockPinDisplayMap.restorePoint(saved: saved, allDisplays: deps.displays.allDisplays(),
                                       target: target, mainID: deps.displays.mainDisplayID())
    }

    // MARK: - 정리 (arch §3.4)

    private func teardown() {
        relocator.abort(.shutdown)                               // 복원(진행 중일 때만)
        if deps.tap.isRunning { deps.tap.stop() }
        if observing {
            deps.displayChanges.stop()
            deps.systemEvents.stop()
            deps.tap.onOptionPassSignal = nil
            observing = false
        }
        for token in repeating.values { token.cancel() }
        repeating.removeAll()
        cancel(&retryToken)
        cancel(&debounceToken)
        cancel(&waitRecheckToken)
        cancel(&settleToken)
        cancel(&permissionRecheckToken)
        optionCheckTokens.forEach { $0.cancel() }
        optionCheckTokens.removeAll()
        deps.locator.cancelAll()
        activation = .inactive(.off)
        phase = .idle
        placement = nil
        overrideDisplayID = nil
        failureCount = 0
        tapState = .none
        lastFingerprint = nil
        lastPushedSnapshot = nil
        lastConfirmedOnAnchorAt = nil
        optionPasses = [:]
        optionPassFloor = [:]
        session.asleep = false
    }

    private func cancel(_ token: inout DockPinCancellable?) {
        token?.cancel()
        token = nil
    }
}
