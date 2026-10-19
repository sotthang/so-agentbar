import Combine
import CoreGraphics
import Foundation
import os

// SPEC-004 Dock Pin — 조정자 (arch §2.10, §3)
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
    /// (r6.2) VULN-002 — 되돌리기 시작 때 정한 탭 시계 시한. 스냅숏에는 phase.isRelocating일 때만 싣는다
    private var relocationDeadline: TimeInterval?
    private var failureCount = 0
    /// (r6.4) VULN-004 — 연속 사용자 입력 중단 횟수. 실패 횟수와 따로 센다(AC8.5). 고정 확인·이벤트 계기에서 0
    private var userActivityAbortCount = 0
    private var tapState: DockPinTapState = .none

    // 타이머
    private var repeating: [DockPinRepeatingTimer: DockPinCancellable] = [:]
    private var retryToken: DockPinCancellable?            // != nil ⇔ retryScheduled
    private var debounceToken: DockPinCancellable?
    private var waitRecheckToken: DockPinCancellable?
    private var settleToken: DockPinCancellable?
    private var permissionRecheckTokens: [DockPinCancellable] = []
    private var optionCheckTokens: [DockPinCancellable] = []
    // (r5·r6) R9.6 새 프로세스 확인 — 동시에 1개. 시한·정리 때 세대를 올리고 두 토큰을 cancel·nil(arch §12 I13)
    private var freshCheckToken: DockPinCancellable?        // != nil ⇔ 진행 중
    private var freshTimeoutToken: DockPinCancellable?
    private var freshGeneration = 0
    // (r6) R9.6 7번 — 래치 L. 새 프로세스 결과가 프로세스 안 판정과 달랐던 값(7-2).
    // 7-4: reconcile 뒤 requiredTimers에 freshTrustCheck가 없거나 정리하면 nil. 권한 알림으로는 바뀌지 않는다
    private var trustLatch: Bool?
    /// (r6.5) VULN-006 — .needsPermission 진입(또는 초기화) 시각. 아니면 nil. 주기 확인 간격을 늘리는 기준
    private var needsPermissionSince: TimeInterval?
    /// (r6.5) VULN-006 — 대기 중인 freshTrustCheck 반복 예약의 간격
    private var freshTimerInterval: TimeInterval?
    // (r6.3) VULN-003 — 분산 잠금 알림은 누구나 보낼 수 있다. 세션을 직접 읽어 본 잠김만 믿는다
    /// 세션 읽기로 잠김을 본 뒤 아직 실제 해제로 소비하지 않았다
    private var observedLocked = false
    /// 마지막으로 이벤트 계기로 인정한 잠금 해제 시각(minEventTriggerInterval 상한)
    private var lastUnlockTriggerAt: TimeInterval?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.sotthang.soagentbar",
                                       category: "DockPin")

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
        releaseOverrideAndRecheck()
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
        readConfiguration()
        refreshSessionState()
    }

    /// 활성화 입력과 디스플레이 맵의 원천(권한·디스플레이·Spaces·방향)을 각 1회 읽는다
    /// 권한은 R9.6 7-1 단일 진입점으로 적용하고, reconcile은 호출측 한 번으로 합친다(arch §12 I11)
    private func readConfiguration() {
        allDisplays = deps.displays.allDisplays()
        mainID = deps.displays.mainDisplayID()
        separateSpaces = deps.dockPreferences.screensHaveSeparateSpaces()
        orientation = deps.dockPreferences.orientation()
        applyInProcess(readTrust(), reconcile: false)
    }

    private func refreshSessionState() {
        session.locked = deps.session.isScreenLocked()
        if session.locked { observedLocked = true }
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
            abortDrive(.deactivated)
            failureCount = 0
            userActivityAbortCount = 0
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
        let leftNeedsPermission = trackNeedsPermission()
        publish()
        if !syncRepeatingTimers().contains(.freshTrustCheck) {
            trustLatch = nil                                    // R9.6 7-4. 진행 중 확인은 applyFresh 가드가 버린다(arch §12 I12)
        }
        if leftNeedsPermission { resetFreshCadence() }          // VULN-006 — 떠나면 5 s 주기로
        lastFingerprint = currentFingerprint
        if scanAfter { activationScan() }
    }

    /// arch §12 I9 — 조회는 .event(백오프 무시), 판정 계기는 .poll
    private func activationScan() {
        locateAndEvaluate(.event, trigger: .poll)
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
                                            isDriving: phase.isDriving,
                                            relocationDeadline: phase.isRelocating ? relocationDeadline : nil)
        guard snapshot != lastPushedSnapshot else { return }
        lastPushedSnapshot = snapshot
        deps.tap.update(snapshot: snapshot)
    }

    // MARK: - 반복 타이머 (R4.4)

    @discardableResult
    private func syncRepeatingTimers() -> Set<DockPinRepeatingTimer> {
        let required = isEnabled && !isShutDown
            ? DockPinPolicy.requiredTimers(activation: activation, tapState: tapState) : []
        for (kind, token) in repeating where !required.contains(kind) {
            token.cancel()
            repeating[kind] = nil
        }
        for kind in required where repeating[kind] == nil {
            scheduleRepeating(kind)
        }
        return required
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
        case .freshTrustCheck:                                   // VULN-006 — .needsPermission에서만 늘어난다
            return DockPinPolicy.freshTrustCheckInterval(
                elapsedInNeedsPermission: needsPermissionSince.map { deps.scheduler.now - $0 })
        }
    }

    /// VULN-006 — .needsPermission 진입 시각을 기록·해제한다. 반환값 = 이번에 .needsPermission을 떠났는지
    private func trackNeedsPermission() -> Bool {
        if activation == .inactive(.needsPermission) {
            if needsPermissionSince == nil { needsPermissionSince = deps.scheduler.now }
            return false
        }
        guard needsPermissionSince != nil else { return false }
        needsPermissionSince = nil
        return true
    }

    /// VULN-006 — 확인 간격을 5 s부터 다시 센다(접근성 알림·앱 활성화·.needsPermission 떠남).
    /// 대기 중 예약이 더 긴 간격이면 지금부터 새 간격으로 다시 잡는다
    private func resetFreshCadence() {
        if needsPermissionSince != nil { needsPermissionSince = deps.scheduler.now }
        guard let token = repeating[.freshTrustCheck],
              freshTimerInterval != interval(.freshTrustCheck) else { return }
        token.cancel()
        scheduleRepeating(.freshTrustCheck)
    }

    private func scheduleRepeating(_ kind: DockPinRepeatingTimer) {
        if kind == .freshTrustCheck { freshTimerInterval = interval(kind) }
        repeating[kind] = deps.scheduler.schedule(after: interval(kind), kind: .repeating(kind)) { [weak self] in
            self?.fireRepeating(kind)
        }
    }

    private func fireRepeating(_ kind: DockPinRepeatingTimer) {
        repeating[kind] = nil
        switch kind {
        case .permissionPoll: applyInProcess(readTrust())
        case .dockPoll: locateAndEvaluate(.quick, trigger: .poll)
        case .prefsPoll:                                         // R4.5 — 방향과 권한만
            orientation = deps.dockPreferences.orientation()
            applyInProcess(readTrust(), reconcile: false)
            reconcile()
        case .tapWatchdog: _ = deps.tap.reenableIfNeeded()       // R5.8
        case .tapRetry: retryTap()
        case .freshTrustCheck:                                   // R9.6, AC9.8 b — 진행 중이면 이번 회차 건너뜀
            if freshCheckToken == nil { startFreshCheck(.periodic) }
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

    /// R9.1 프로세스 안 판정 = AXIsProcessTrusted AND Dock AX 프로브(PID 없으면 프로세스 판정만). PID는 매번 새로 읽는다.
    private func readTrust() -> Bool {
        DockPinPolicy.combinedTrust(
            process: deps.permission.isTrusted(),
            dockProbe: deps.dockPreferences.dockPID().map { deps.permission.dockProbeTrusted(dockPID: $0) })
    }

    /// R9.2·R9.3 — H를 바꾼다. true→false면 탭 제거가 다른 어떤 처리보다 먼저다(AC9.1). 반환값 = H가 바뀌었는지
    @discardableResult
    private func setPermission(_ trusted: Bool, reconcile shouldReconcile: Bool = true) -> Bool {
        guard trusted != hasPermission else { return false }
        if !trusted {
            if deps.tap.isRunning { deps.tap.stop() }
            tapState = .none
            relocator.abort(.permissionLost)
        }
        hasPermission = trusted
        if shouldReconcile { reconcile() }
        return true
    }

    /// R9.6 7-1 — 프로세스 안 판정(t)을 적용하는 유일한 진입점(폴링·재확인·prefsPoll·디바운스·readAll)
    private func applyInProcess(_ trusted: Bool, reconcile shouldReconcile: Bool = true) {
        switch trustLatch {
        case nil:
            if setPermission(trusted, reconcile: shouldReconcile) {
                invalidateFreshCheck()                           // 7-3 — 늦게 온 결과를 버린다(AC9.10)
            }
        case trusted?:
            trustLatch = nil                                     // L == t → 래치 해제, H 그대로(AC9.7 e)
        case true?:                                              // t == false — 확인만 부른다(AC9.7 b·c)
            if freshCheckToken == nil { startFreshCheck(.latchDoubt) }
        case false?:                                             // t == true — 다음 주기 확인까지 무시(AC9.7 a)
            break
        }
    }

    // MARK: - 새 프로세스 확인 (R9.6, arch §3.3)

    /// 주기·주기 밖 공통. 동시에 1개. 시한(2 s)이 지나면 확인을 취소하고 결과 nil로 처리한다(AC9.8 a)
    private func startFreshCheck(_ origin: DockPinFreshCheckOrigin) {
        guard freshCheckToken == nil else { return }
        freshGeneration += 1
        let generation = freshGeneration
        freshTimeoutToken = deps.scheduler.schedule(after: DockPinTuning.freshTrustCheckTimeout,
                                                    kind: .freshTrustTimeout) { [weak self] in
            guard let self else { return }
            self.freshTimeoutToken = nil
            self.invalidateFreshCheck()
            self.applyFresh(nil, reason: "timeout", origin: origin)
        }
        let token = deps.permission.freshTrustCheck { [weak self] result in
            guard let self, generation == self.freshGeneration else { return }
            self.cancel(&self.freshTimeoutToken)
            self.freshCheckToken = nil
            let reason = result == nil ? self.deps.permission.lastFreshFailure.map { "\($0)" } ?? "-" : "-"
            self.applyFresh(result, reason: reason, origin: origin)
        }
        // completion이 동기로 왔으면 시한 토큰이 이미 치워졌다 — 그때는 대입하지 않는다
        if generation == freshGeneration, freshTimeoutToken != nil { freshCheckToken = token }
    }

    /// 세대 규칙(arch §3.3, §12 I13) — 진행 중 확인·시한을 cancel하고 두 토큰을 nil로 만든 뒤 세대를 올린다
    private func invalidateFreshCheck() {
        cancel(&freshCheckToken)
        cancel(&freshTimeoutToken)
        freshGeneration += 1
    }

    /// R9.6 7-2 — 새 프로세스 결과(r) 적용. 세대가 맞을 때만 온다. 이 경로의 setPermission은 세대를 올리지 않는다
    private func applyFresh(_ result: Bool?, reason: String, origin: DockPinFreshCheckOrigin) {
        let r = result.map { $0 ? "1" : "0" } ?? "nil(\(reason))"
        guard isEnabled, !isShutDown,
              DockPinPolicy.requiredTimers(activation: activation, tapState: tapState).contains(.freshTrustCheck) else {
            Self.logger.debug("fresh r=\(r, privacy: .public) dropped (not required)")           // arch §12 I12
            return
        }
        let latchBefore = Self.describe(trustLatch)
        var inProcess: Bool?
        if let result {
            let trusted = readTrust()
            inProcess = trusted
            trustLatch = result == trusted ? nil : result
            setPermission(result)                                // false면 탭부터 제거(R9.3), true면 R9.2
        } else if trustLatch == true {                           // AC9.7 d — 래치를 풀고 프로세스 안 판정으로
            trustLatch = nil
            let trusted = readTrust()
            inProcess = trusted
            applyInProcess(trusted)
        }
        let t = Self.describe(inProcess)
        let latchAfter = Self.describe(trustLatch)
        Self.logger.debug("fresh r=\(r, privacy: .public) t=\(t, privacy: .public) L=\(latchBefore, privacy: .public)->\(latchAfter, privacy: .public) origin=\("\(origin)", privacy: .public)")
        if let result, let inProcess, result != inProcess {
            Self.logger.debug("fresh-mismatch r=\(r, privacy: .public) t=\(t, privacy: .public)")
        }
    }

    /// 로그용 표기: true → "1", false → "0", nil → "-"
    private static func describe(_ value: Bool?) -> String {
        value.map { $0 ? "1" : "0" } ?? "-"
    }

    // MARK: - 디스플레이 (R4.3, R4.8)

    private func handleDisplaySignal(_ signal: DockPinDisplaySignal) {
        if signal == .reconfigured && phase.isRelocating {      // R4.3 — 그 자리에서 중단, 횟수 그대로
            abortDrive(.displayReconfigured)
            publish()
        }
        cancel(&debounceToken)
        debounceToken = deps.scheduler.schedule(after: DockPinTuning.displayDebounce, kind: .displayDebounce) { [weak self] in
            self?.debounceToken = nil
            self?.recomputeDisplays()
        }
    }

    private func recomputeDisplays() {
        readConfiguration()
        let changed = DockPinPolicy.isDisplayConfigChange(previous: lastFingerprint, current: currentFingerprint)
        reconcile(scanOnActivation: !changed)
        if changed { handleConfigChange() }
    }

    /// R4.8로 인정된 구성 변경 — 변하지 않았으면 부르지 않는다(AC4.10 a/b)
    private func handleConfigChange() {
        guard activation == .active else { return }
        if phase.isRelocating {                                  // arch §12 I4
            abortDrive(.displayReconfigured)
        }
        placement = nil
        releaseOverrideAndRecheck()
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
        case .screenLocked:                                       // VULN-003 — 세션이 실제로 잠겼을 때만 멈춘다
            refreshSessionState()
            guard session.locked else { return }
            interruptDrive(.locked)
        case .screenUnlocked:                                     // VULN-003 — 실제 잠김 → 해제인지는 settle 때 판정
            scheduleSettle(isEventTrigger: true, fromUnlock: true)
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
        case .accessibilityChanged:                               // R9.5 (r5) — 즉시 확인 없음, +1.0·+3.0 s 뒤
            resetFreshCadence()                                   // VULN-006
            schedulePermissionRechecks()
        case .appBecameActive:
            resetFreshCadence()                                   // VULN-006
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

    /// R10.2/R10.3 — 1 s 뒤 다시 읽고, 이벤트 계기면 오버라이드·실패 횟수를 초기화한다.
    /// (r6.3) VULN-003 — 잠금 해제발은 실제 잠김 → 해제가 확인되고 상한 창 밖일 때만 이벤트 계기다. 아니면 다시 읽기만 한다
    private func scheduleSettle(isEventTrigger: Bool, fromUnlock: Bool = false) {
        cancel(&settleToken)
        settleToken = deps.scheduler.schedule(after: DockPinTuning.settleAfterSessionChange, kind: .sessionSettle) { [weak self] in
            guard let self else { return }
            self.settleToken = nil
            self.readAll()
            let isEvent = isEventTrigger && (!fromUnlock || self.consumeGenuineUnlock())
            self.reconcile(scanOnActivation: !isEvent)
            guard isEvent, self.activation == .active, !self.phase.isRelocating else { return }
            self.releaseOverrideAndRecheck()
        }
    }

    /// VULN-003 — 세션 읽기로 잠김을 본 적이 있고 지금은 풀렸으면 그 잠김을 소비한다.
    /// 소비한 해제도 직전 인정 해제로부터 minEventTriggerInterval 안이면 이벤트 계기가 아니다
    private func consumeGenuineUnlock() -> Bool {
        guard observedLocked, !session.locked else { return false }
        observedLocked = false
        let now = deps.scheduler.now
        if let last = lastUnlockTriggerAt, now - last < DockPinTuning.minEventTriggerInterval { return false }
        lastUnlockTriggerAt = now
        return true
    }

    // MARK: - Option 통과 (R7)

    private func handleOptionPassSignal() {
        guard observing, !isShutDown else { return }
        let signals = deps.tap.drainSignals()
        for (id, time) in signals.optionPasses where time > (optionPassFloor[id] ?? -.infinity) {
            optionPasses[id] = max(optionPasses[id] ?? -.infinity, time)
        }
        guard signals.hadOptionPass else { return }
        cancelOptionChecks()                                     // 새 통과의 확인 일정이 앞선 일정을 대신한다
        for delay in DockPinTuning.optionCheckDelays {          // R7.3 / AC7.5
            optionCheckTokens.append(deps.scheduler.schedule(after: delay, kind: .optionCheck) { [weak self] in
                self?.locateAndEvaluate(.quick, trigger: .poll)
            })
        }
    }

    /// R9.5 / AC9.5 — 알림 순간 읽으면 tccd 기록 전 낡은 false가 캐시된다(F22). 새 알림은 대기 중 확인을 대신한다
    private func schedulePermissionRechecks() {
        cancelPermissionRechecks()
        for (index, delay) in DockPinTuning.permissionNotifyRecheckDelays.enumerated() {
            let advanceFresh = index == 0                        // N21 — +1.0 재확인만 확인을 앞당긴다(AC9.14)
            permissionRecheckTokens.append(deps.scheduler.schedule(after: delay, kind: .permissionRecheck) { [weak self] in
                guard let self else { return }
                self.applyInProcess(self.readTrust())
                if advanceFresh, self.trustLatch == false, self.freshCheckToken == nil {
                    self.startFreshCheck(.notifyAdvance)
                }
            })
        }
    }

    private func cancelPermissionRechecks() {
        permissionRecheckTokens.forEach { $0.cancel() }
        permissionRecheckTokens.removeAll()
    }

    private func cancelOptionChecks() {
        optionCheckTokens.forEach { $0.cancel() }
        optionCheckTokens.removeAll()
    }

    /// R7.6 — 오버라이드를 끄고 그 화면의 Option 통과 기록도 버린다(창 10 s는 켤 때만 본다)
    private func releaseOverride() {
        if let id = overrideDisplayID {
            optionPasses[id] = nil
            optionPassFloor[id] = deps.scheduler.now
        }
        overrideDisplayID = nil
    }

    /// 오버라이드를 풀고 발행한 뒤 이벤트 계기로 바로 다시 조회한다(R8.7)
    private func releaseOverrideAndRecheck() {
        releaseOverride()
        publish()
        eventTrigger()
    }

    // MARK: - 위치·되돌리기 (R8)

    private func locate(_ mode: DockPinLocateMode, _ completion: @escaping @MainActor (DockPinLocateOutcome) -> Void) {
        deps.locator.locate(mode, displays: layout?.displays ?? DockPinDisplayMap.activeDisplays(allDisplays),
                            completion: completion)
    }

    private func locateAndEvaluate(_ mode: DockPinLocateMode, trigger: DockPinTrigger) {
        locate(mode) { [weak self] outcome in self?.onPlacement(outcome, trigger: trigger) }
    }

    /// 진행 중인 되돌리기를 멈추고(복원 1회) 단계를 .idle로 둔다. 실패 횟수는 그대로다.
    private func abortDrive(_ reason: DockPinDriveAbortReason) {
        relocator.abort(reason)
        phase = .idle
    }

    /// R8.7 이벤트 계기 — 실패 0, 재시도 취소, .failed → .idle, 백오프 무시 조회
    private func eventTrigger() {
        guard activation == .active, tapState == .running else { return }
        failureCount = 0
        userActivityAbortCount = 0
        cancel(&retryToken)
        if phase.isFailed { phase = .idle }
        locateAndEvaluate(.event, trigger: .event)
    }

    private func onPlacement(_ outcome: DockPinLocateOutcome, trigger: DockPinTrigger) {
        guard activation == .active, case .placement(let newPlacement) = outcome else { return }
        placement = newPlacement
        if case .display(let id) = newPlacement, let anchorID = layout?.anchor.display.id {
            if id == anchorID {
                lastConfirmedOnAnchorAt = deps.scheduler.now
                overrideDisplayID = nil
                userActivityAbortCount = 0
                if phase.isFailed || retryToken != nil {         // R8.7, AC8.12
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
        refreshSessionState()
        let decision = DockPinPolicy.relocationDecision(DockPinRelocationInputs(
            activation: tapState == .running ? activation : .inactive(.off),
            placement: placement, anchorID: layout?.anchor.display.id, phase: phase,
            retryScheduled: retryToken != nil, trigger: trigger,
            isUserOverride: overrideDisplayID != nil,
            hasRelocationTarget: layout?.relocationTarget != nil, session: session,
            anyButtonDown: deps.session.isAnyButtonDown(),
            secondsSinceInput: deps.session.secondsSinceLastInput(),
            requiredIdle: DockPinPolicy.requiredIdleBeforeRelocation(afterUserActivityAborts: userActivityAbortCount)))
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
        let startedAt = deps.scheduler.now
        relocationDeadline = startedAt + DockPinTuning.relocationGuardWindow   // 스케줄러 시계 == 탭 시계(V5)
        publish()
        // (r6.6) NEW-1 — 실행기 벽시계 상한도 같은 시작 시각 기준(시한 − 여유)
        relocator.start(DockPinDrivePlan(target: point, anchorID: layout.anchor.display.id, displays: layout.displays),
                        startedAt: startedAt) {
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
        case .aborted(.userActivity):                            // AC8.5 — 실패 횟수 그대로
            userActivityAbortCount += 1                          // (r6.4) VULN-004 — 다음 유휴 기준을 늘린다
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
                self.locateAndEvaluate(.quick, trigger: .retryTimer)
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
        cancelPermissionRechecks()
        cancelOptionChecks()
        invalidateFreshCheck()                                   // 자식 종료 + 늦은 결과 버림(AC9.8 c)
        trustLatch = nil                                         // R9.6 7-4
        needsPermissionSince = nil                               // VULN-006 — 다시 켜면 5 s부터
        deps.locator.cancelAll()
        activation = .inactive(.off)
        phase = .idle
        placement = nil
        overrideDisplayID = nil
        failureCount = 0
        userActivityAbortCount = 0
        tapState = .none
        lastFingerprint = nil
        lastPushedSnapshot = nil
        lastConfirmedOnAnchorAt = nil
        optionPasses = [:]
        optionPassFloor = [:]
        session.asleep = false
        observedLocked = false
        lastUnlockTriggerAt = nil
    }

    private func cancel(_ token: inout DockPinCancellable?) {
        token?.cancel()
        token = nil
    }
}
