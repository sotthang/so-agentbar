import AppKit
import ApplicationServices
import CoreGraphics
import os
import Security

// SPEC-004 Dock Pin — 시스템 접점 프로토콜 + Live 어댑터 (arch §2.6)
// 부작용 파일. 순수 판정은 DockPinModels/DisplayMap/EdgeRule/Placement/Policy 에 있다(R13.1).
//
// 모든 Live 어댑터의 init은 시스템 호출·등록을 하지 않는다(등록은 start에서만). 테스트는 Live 어댑터를 부르지 않는다.
// 좌표는 전부 CG 전역(CGDisplayBounds, CGEvent.location). NSScreen은 이름과 Spaces 읽기에만 쓴다(F11).
// `DockPinDependencies.live()`는 실제 어댑터 + DockPinDockLocator를 묶는다.

protocol DockPinCancellable: AnyObject { func cancel() }

/// 시계 + 일회성 예약. 반복은 매니저가 다시 예약해서 만든다(가짜에서 종류별 계수).
@MainActor protocol DockPinScheduling: AnyObject {
    var now: TimeInterval { get }                                   // systemUptime (V5)
    @discardableResult
    func schedule(after delay: TimeInterval, kind: DockPinTimerKind,
                  _ work: @escaping @MainActor () -> Void) -> DockPinCancellable
}

@MainActor protocol DockPinDisplayProviding: AnyObject {
    func allDisplays() -> [DockPinDisplay]      // CGGetActiveDisplayList + CGDisplayBounds + MirrorsDisplay + UUID + NSScreen 이름
    func mainDisplayID() -> CGDirectDisplayID
}

enum DockPinDisplaySignal: Equatable, Sendable {
    case reconfigured                           // Begin 플래그만이 아닌 CG 재구성 콜백 (즉시 중단 대상, R4.3)
    case screenParametersChanged                // didChangeScreenParametersNotification (디바운스만)
}

@MainActor protocol DockPinDisplayChangeObserving: AnyObject {
    func start(_ handler: @escaping @MainActor (DockPinDisplaySignal) -> Void)   // Begin-only 콜백은 어댑터에서 거른다
    func stop()                                                                    // CGDisplayRemoveReconfigurationCallback + 옵저버 해제
}

@MainActor protocol DockPinDockPreferencesProviding: AnyObject {
    func orientation() -> DockPinOrientation    // CFPreferencesAppSynchronize → CopyAppValue → parse
    func screensHaveSeparateSpaces() -> Bool    // NSScreen. NSApplication 초기화 뒤에만(F15)
    func dockPID() -> pid_t?                    // NSRunningApplication (메인)
}

@MainActor protocol DockPinPermissionProviding: AnyObject {
    func isTrusted() -> Bool                    // AXIsProcessTrusted (R9.1 1번)
    /// (r5) R9.1 2번 — AXUIElementCreateApplication(pid) + AXUIElementCopyAttributeValue(kAXRoleAttribute).
    /// (r6, C13) 호출 전에 그 앱 요소에 메시징 시한 DockPinTuning.dockProbeTimeout(0.25초)을 건다.
    /// 결과 오류 코드 → DockPinPolicy.dockProbeTrusted(axError:): kAXErrorAPIDisabled만 false,
    /// 성공·kAXErrorCannotComplete(시한 초과)·그 밖 → true. 메인에서 동기.
    func dockProbeTrusted(dockPID: pid_t) -> Bool
    /// (r5) R9.6 — 자기 실행 파일 + trustCheckArgument를 메인 밖에서 실행. completion은 메인에서 최대 1번
    /// (parseFreshTrustOutput 결과, 실행 실패 = nil). cancel() → 자식 terminate + completion 0번. 시한은 매니저가 잰다.
    /// (r6) 자식 environment = [:], stdin·stderr = nullDevice(N16). (r6.1 VULN-001) 매 실행 전 코드 신원 확인:
    /// 디스크 cdhash ≠ 시작 때 기록한 자기 cdhash, 또는 자기 지정 요구사항 서명 검증 실패면 run() 없이 completion(nil).
    /// 결과 사유는 lastFreshFailure로 남긴다(로그용, N20).
    func freshTrustCheck(completion: @escaping @MainActor (Bool?) -> Void) -> DockPinCancellable
    /// (r6) N20 — 직전 completion(nil)의 사유. nil이면 정상 결과. 매니저가 로그에만 쓴다
    var lastFreshFailure: DockPinFreshFailure? { get }
    func requestTrustPrompt()                   // AXIsProcessTrustedWithOptions(prompt: true)
    func openPrivacySettings()                  // x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility
}

/// (r6) N20 — 새 프로세스 결과가 nil인 사유(로그 문자열용). 시한 초과는 매니저가 정하므로 여기 없다
enum DockPinFreshFailure: Equatable, Sendable { case launchFailed, unparsable, executableChanged }

/// (r5) R9.6 2번 — main.swift 단축 경로. NSApplication·AgentStore·UserDefaults를 건드리지 않는다.
/// AXIsProcessTrusted() 1회 → stdout "1\n"/"0\n" → exit(0).
enum DockPinTrustCheckCommand {
    /// 테스트 이음새: `trusted`를 정확히 1번 읽고, `output`에 "1\n" 또는 "0\n"을 정확히 1번 쓰고, 종료 코드 0을 돌려준다.
    static func run(trusted: () -> Bool, output: (String) -> Void) -> Int32 {
        output(trusted() ? "1\n" : "0\n")
        return 0
    }

    /// run(trusted: AXIsProcessTrusted, output: 표준 출력에 버퍼 없이 쓰기) → exit(코드).
    static func runAndExit() -> Never {
        let code = run(trusted: { AXIsProcessTrusted() },
                       output: { FileHandle.standardOutput.write(Data($0.utf8)) })
        exit(code)
    }
}

@MainActor protocol DockPinSessionProviding: AnyObject {
    func isScreenLocked() -> Bool               // CGSessionCopyCurrentDictionary → DockPinPolicy.isScreenLocked
    func isOnConsole() -> Bool                  // kCGSSessionOnConsoleKey
    func isAnyButtonDown() -> Bool              // buttonState(.hidSystemState) 왼·오·가운데
    func secondsSinceLastInput() -> TimeInterval  // secondsSinceLastEventType(.hidSystemState, ~0)
}

enum DockPinSystemEvent: Equatable, Sendable {
    case willSleep, didWake, screensDidWake
    case screenLocked, screenUnlocked           // 분산 com.apple.screenIsLocked / Unlocked
    case sessionResignedActive, sessionBecameActive
    case dockRelaunched                         // didLaunchApplication, bundleID == com.apple.dock (R6.1)
    case accessibilityChanged                   // 분산 com.apple.accessibility.api (R9.5)
    case appBecameActive                        // Spaces 재읽기(R4.5)
}

@MainActor protocol DockPinSystemEventObserving: AnyObject {
    func start(_ handler: @escaping @MainActor (DockPinSystemEvent) -> Void)
    func stop()
}

/// 앱이 보내는 이벤트. warp 메서드는 일부러 없다(R8.5, AC13.3 구조적 금지).
@MainActor protocol DockPinEventPosting: AnyObject {
    func cursorLocation() -> CGPoint?           // CGEvent(source: nil)?.location
    func postTaggedMouseMove(to point: CGPoint) // CGEventSource(.hidSystemState).userData = marker, post(.cghidEventTap)
}

/// 조회 큐(메인 아님)에서 불린다. 상태 없음.
protocol DockPinWindowListing: Sendable {
    func dockWindows(pid: pid_t, layer: Int) -> [DockPinWindowInfo]   // CGWindowListCopyWindowInfo
    func window(number: CGWindowID) -> DockPinWindowInfo?             // CGWindowListCreateDescriptionFromArray(포인터 값 CFArray)
}

/// 탭 수명. 액터 없음(콜백 스레드에서 쓰는 구현체가 메인 액터를 상속받지 않게).
protocol DockPinEventTapping: AnyObject {
    var isRunning: Bool { get }
    var onOptionPassSignal: (() -> Void)? { get set }   // 메인 런루프 perform에서 불린다
    func start() -> Bool                                // false = tapCreate nil 또는 시작 시간 초과 (R5.9)
    func stop()                                         // 동기·멱등 (R4.2, R9.3 순서)
    func update(snapshot: DockPinGuardSnapshot)
    func reenableIfNeeded() -> Bool                     // R5.8
    func drainSignals() -> DockPinTapSignals
    var userActivityCount: UInt64 { get }               // 되돌리기 틱이 매 틱 읽는다(R8.6)
}

enum DockPinLocateMode: Equatable, Sendable {
    case quick      // 캐시 창 1개 단일 조회. 캐시 없음/창 사라짐 → full로 승격(백오프 지킴)
    case full       // 전체 조회, 백오프 지킴
    case event      // 전체 조회, 백오프 무시, 1초 속도 제한(R6.6)
    case final      // event + preferCached: false (R8.3-5, R6.4 예외)
}

enum DockPinLocateOutcome: Equatable, Sendable {
    case placement(DockPinPlacement)
    case deferred   // 백오프 중이라 전체 조회를 하지 않음 → 직전 값 유지
}

@MainActor protocol DockPinDockLocating: AnyObject {
    /// completion은 메인에서 정확히 1번(취소되면 0번). 가짜는 동기로 부를 수 있으므로 호출측은 재진입 안전해야 한다.
    func locate(_ mode: DockPinLocateMode, displays: [DockPinDisplay],
                completion: @escaping @MainActor (DockPinLocateOutcome) -> Void)
    func invalidateCache()                     // Dock 재시작
    func cancelAll()                           // 세대 번호 증가 → 진행 중 결과 버림
}

@MainActor struct DockPinDependencies {
    var scheduler: DockPinScheduling
    var displays: DockPinDisplayProviding
    var displayChanges: DockPinDisplayChangeObserving
    var dockPreferences: DockPinDockPreferencesProviding
    var permission: DockPinPermissionProviding
    var session: DockPinSessionProviding
    var systemEvents: DockPinSystemEventObserving
    var poster: DockPinEventPosting
    var tap: DockPinEventTapping
    var locator: DockPinDockLocating

    /// 실제 어댑터 묶음. 어떤 init도 시스템 등록을 하지 않는다(등록은 start에서만).
    /// 스케줄러와 Dock 설정은 조회기와 같은 인스턴스를 나눠 쓴다.
    static func live() -> DockPinDependencies {
        let scheduler = DockPinLiveScheduler()
        let dockPreferences = DockPinLiveDockPreferences()
        return DockPinDependencies(scheduler: scheduler,
                                   displays: DockPinLiveDisplays(),
                                   displayChanges: DockPinLiveDisplayChanges(),
                                   dockPreferences: dockPreferences,
                                   permission: DockPinLivePermission(),
                                   session: DockPinLiveSession(),
                                   systemEvents: DockPinLiveSystemEvents(),
                                   poster: DockPinLiveEventPoster(),
                                   tap: DockPinEventTap(),
                                   locator: DockPinDockLocator(listing: DockPinLiveWindowListing(),
                                                               dockPreferences: dockPreferences,
                                                               scheduler: scheduler))
    }
}

// MARK: - Live 어댑터

/// DispatchWorkItem 래퍼.
final class DockPinLiveWorkItem: DockPinCancellable {
    private let item: DispatchWorkItem

    init(_ item: DispatchWorkItem) {
        self.item = item
    }

    func cancel() {
        item.cancel()
    }
}

/// DispatchWorkItem + DispatchQueue.main.asyncAfter (메인 큐는 common 모드에서도 돈다).
@MainActor final class DockPinLiveScheduler: DockPinScheduling {
    /// 탭 시계(DockPinEventTap.uptime)와 같은 시계(V5)
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    @discardableResult
    func schedule(after delay: TimeInterval, kind: DockPinTimerKind,
                  _ work: @escaping @MainActor () -> Void) -> DockPinCancellable {
        let item = DispatchWorkItem {
            MainActor.assumeIsolated { work() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: item)
        return DockPinLiveWorkItem(item)
    }
}

/// CGGetActiveDisplayList + CGDisplayBounds + CGDisplayMirrorsDisplay + UUID + NSScreen 이름.
@MainActor final class DockPinLiveDisplays: DockPinDisplayProviding {
    func allDisplays() -> [DockPinDisplay] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        let names = screenNames()
        return ids.prefix(Int(count)).map { id in
            let mirror = CGDisplayMirrorsDisplay(id)
            return DockPinDisplay(id: id,
                                  uuid: Self.uuidString(of: id),
                                  bounds: CGDisplayBounds(id),
                                  mirrorOf: mirror == kCGNullDirectDisplay ? nil : mirror,
                                  name: names[id] ?? "Display \(id)")
        }
    }

    func mainDisplayID() -> CGDirectDisplayID {
        CGMainDisplayID()
    }

    /// 표시용 이름만 NSScreen에서 가져온다(frame은 읽지 않는다, F11).
    private func screenNames() -> [CGDirectDisplayID: String] {
        var result: [CGDirectDisplayID: String] = [:]
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[key] as? NSNumber {
                result[number.uint32Value] = screen.localizedName
            }
        }
        return result
    }

    private static func uuidString(of id: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let string = CFUUIDCreateString(kCFAllocatorDefault, uuid) else { return "" }
        return string as String
    }
}

/// C 콜백 → Unmanaged userInfo → 메인 전달. Begin-only 콜백은 여기서 거른다(R4.3).
@MainActor final class DockPinLiveDisplayChanges: DockPinDisplayChangeObserving {
    private var handler: (@MainActor (DockPinDisplaySignal) -> Void)?
    private var callbackRegistered = false
    private var screenObserver: NSObjectProtocol?

    func start(_ handler: @escaping @MainActor (DockPinDisplaySignal) -> Void) {
        stop()
        self.handler = handler
        let info = Unmanaged.passUnretained(self).toOpaque()
        callbackRegistered = CGDisplayRegisterReconfigurationCallback(Self.reconfigurationCallback, info) == .success
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.deliver(.screenParametersChanged) }
        }
    }

    func stop() {
        if callbackRegistered {
            let info = Unmanaged.passUnretained(self).toOpaque()
            CGDisplayRemoveReconfigurationCallback(Self.reconfigurationCallback, info)
            callbackRegistered = false
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        handler = nil
    }

    private func deliver(_ signal: DockPinDisplaySignal) {
        handler?(signal)
    }

    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard flags != .beginConfigurationFlag, let userInfo else { return }
        let observer = Unmanaged<DockPinLiveDisplayChanges>.fromOpaque(userInfo).takeUnretainedValue()
        if Thread.isMainThread {
            MainActor.assumeIsolated { observer.deliver(.reconfigured) }
        } else {
            DispatchQueue.main.async { observer.deliver(.reconfigured) }
        }
    }
}

/// Dock 설정(com.apple.dock), Spaces(NSApplication 초기화 뒤에만, F15), Dock PID.
@MainActor final class DockPinLiveDockPreferences: DockPinDockPreferencesProviding {
    /// Dock의 번들 ID = 설정 도메인
    nonisolated static let dockBundleID = "com.apple.dock"
    private static let dockDomain = dockBundleID as CFString

    func orientation() -> DockPinOrientation {
        CFPreferencesAppSynchronize(Self.dockDomain)
        return DockPinOrientation.parse(CFPreferencesCopyAppValue("orientation" as CFString, Self.dockDomain))
    }

    /// F15 — 호출측(매니저)은 startIfEnabled/setEnabled(true) 경로에서만 부른다.
    func screensHaveSeparateSpaces() -> Bool {
        NSScreen.screensHaveSeparateSpaces
    }

    func dockPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID)
            .first { !$0.isTerminated }?.processIdentifier
    }
}

/// (r6.1, VULN-001) 새 프로세스 확인 실행 전 코드 신원 확인 이음새. 자식은 부모의 TCC 책임으로 돌아 앱의
/// 손쉬운 사용 권한을 쓰므로, 디스크의 실행 파일이 지금 돌고 있는 코드와 같을 때만 실행한다.
/// 클로저는 메인 밖(freshQueue)에서 불린다. 테스트는 가짜 값을 넣고, 실제 구현은 `live`다.
struct DockPinCodeSigning: Sendable {
    /// 프로세스 시작 때 기록한 자기 자신의 cdhash(kSecCodeInfoUnique). nil = 기록 실패 → 실행하지 않는다
    var runningCDHash: @Sendable () -> Data?
    /// 디스크 파일의 cdhash. 서명이 없거나 읽지 못하면 nil
    var diskCDHash: @Sendable (URL) -> Data?
    /// 디스크 파일이 서명 검증(코드 페이지·중첩 코드 포함)을 통과하고 자기 지정 요구사항을 만족하는가
    var diskSatisfiesRunningRequirement: @Sendable (URL) -> Bool

    static let live = DockPinCodeSigning(
        runningCDHash: { DockPinRunningCodeBaseline.recorded?.cdhash },
        diskCDHash: { url in DockPinRunningCodeBaseline.cdhash(ofFileAt: url) },
        diskSatisfiesRunningRequirement: { url in DockPinRunningCodeBaseline.fileSatisfiesRequirement(url) })
}

/// (r6.1, VULN-001) 실행 중인 자기 코드의 기준값. `SecCodeCopySelf` + 서명 정보는 디스크를 다시 읽으므로
/// (바꿔치기 뒤에 부르면 새 파일 값을 돌려준다 — 세션 안 실측) 반드시 프로세스 시작 때 한 번 기록한다.
/// main.swift가 NSApplication 전에 `recordAtLaunch()`를 부른다.
enum DockPinRunningCodeBaseline {
    struct Baseline: @unchecked Sendable {       // SecRequirement는 불변 CF 객체
        let cdhash: Data
        let requirement: SecRequirement
    }

    /// 첫 접근 때 한 번 계산(Swift 전역 lazy, 스레드 안전)
    static let recorded: Baseline? = capture()

    /// 실행 직후의 기준을 고정한다. 단축 경로(--dockpin-trust-check) 뒤, NSApplication 전에 부른다
    static func recordAtLaunch() { _ = recorded }

    /// 커널이 기록한 실행 코드와 디스크가 같음을 확인(SecCodeCheckValidity)한 뒤에만 기준으로 삼는다
    private static func capture() -> Baseline? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              let cdhash = cdhash(of: staticCode) else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        return Baseline(cdhash: cdhash, requirement: requirement)
    }

    static func cdhash(ofFileAt url: URL) -> Data? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return cdhash(of: staticCode)
    }

    private static func cdhash(of staticCode: SecStaticCode) -> Data? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              !hash.isEmpty else { return nil }
        return hash
    }

    /// cdhash가 같아도 코드 디렉터리만 남기고 페이지를 바꾼 파일은 여기서 걸린다(실측 -67061).
    /// 중첩 코드(Debug의 *.debug.dylib, Sparkle.framework)도 검증한다. 실측 약 10–20 ms
    static func fileSatisfiesRequirement(_ url: URL) -> Bool {
        guard let requirement = recorded?.requirement else { return false }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
    }
}

/// AX 권한 확인·요청·설정 열기.
@MainActor final class DockPinLivePermission: DockPinPermissionProviding {
    /// 실행할 파일. nil이면 확인 때 Bundle.main.executableURL을 쓴다(테스트는 임시 스크립트를 넣는다).
    /// init은 시스템 호출을 하지 않는다(코드 신원 기준은 main.swift가 프로세스 시작 때 기록한다, VULN-001).
    private let executableURL: URL?

    /// (r6) N20 — 직전 completion(nil)의 사유
    private(set) var lastFreshFailure: DockPinFreshFailure?

    /// R9.6 4번 — 자식 실행·대기는 메인 밖 직렬 큐에서
    nonisolated private static let freshQueue = DispatchQueue(label: "com.sotthang.soagentbar.dockpin.fresh",
                                                              qos: .utility)
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.sotthang.soagentbar",
                                       category: "DockPin")

    /// (r6.1) VULN-001 — 매 실행 전 코드 신원 확인
    private let codeSigning: DockPinCodeSigning

    init(executableURL: URL? = nil, codeSigning: DockPinCodeSigning = .live) {
        self.executableURL = executableURL
        self.codeSigning = codeSigning
    }

    /// (r5·r6·r6.1) R9.6 1번·3번·4번, N16, VULN-001 — arch §2.6
    func freshTrustCheck(completion: @escaping @MainActor (Bool?) -> Void) -> DockPinCancellable {
        let handle = DockPinFreshCheckHandle()
        let url = executableURL ?? Bundle.main.executableURL
        let codeSigning = codeSigning
        Self.freshQueue.async {
            let outcome = Self.performFreshCheck(url: url, codeSigning: codeSigning, handle: handle)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard handle.finish() else { return }       // 취소됐으면 completion 0번
                    self.apply(outcome, completion: completion)
                }
            }
        }
        return handle
    }

    private func apply(_ outcome: DockPinFreshOutcome, completion: @MainActor (Bool?) -> Void) {
        lastFreshFailure = outcome.failure
        let reason = outcome.failure.map { "\($0)" } ?? "-"
        let result = outcome.result.map { $0 ? "1" : "0" } ?? "nil"
        Self.logger.debug("fresh-check r=\(result, privacy: .public) reason=\(reason, privacy: .public)")
        completion(outcome.result)
    }

    /// 메인 밖(freshQueue). 코드 신원 확인 → 실행 → 출력 해석. 취소 표시가 있으면 실행하지 않거나 자식을 끝낸다.
    nonisolated private static func performFreshCheck(url: URL?, codeSigning: DockPinCodeSigning,
                                                      handle: DockPinFreshCheckHandle) -> DockPinFreshOutcome {
        guard let url else { return DockPinFreshOutcome(result: nil, failure: .launchFailed) }
        // VULN-001: cdhash 비교(싸다) → 서명·요구사항 검증(코드 페이지까지). 하나라도 아니면 실행하지 않는다
        guard DockPinPolicy.shouldLaunchFreshCheck(runningCDHash: codeSigning.runningCDHash(),
                                                   diskCDHash: codeSigning.diskCDHash(url)),
              codeSigning.diskSatisfiesRunningRequirement(url) else {
            return DockPinFreshOutcome(result: nil, failure: .executableChanged)
        }

        let process = Process()
        process.executableURL = url
        process.arguments = [DockPinPolicy.trustCheckArgument]
        process.environment = [:]                                   // N16
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }      // waitUntilExit의 런루프 폴링 지연을 피한다

        guard !handle.isCancelled else { return DockPinFreshOutcome(result: nil, failure: nil) }
        do {
            try process.run()
        } catch {
            return DockPinFreshOutcome(result: nil, failure: .launchFailed)
        }
        handle.attach(process)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        let output = String(decoding: data, as: UTF8.self)
        let result = DockPinPolicy.parseFreshTrustOutput(exitStatus: process.terminationStatus, stdout: output)
        return DockPinFreshOutcome(result: result, failure: result == nil ? .unparsable : nil)
    }

    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// R9.1 2번 — 앱 요소 생성 → 메시징 시한(C13) → role 속성 읽기 → 오류 코드 판정(kAXErrorAPIDisabled만 false)
    func dockProbeTrusted(dockPID: pid_t) -> Bool {
        let dockApp = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dockApp, DockPinTuning.dockProbeTimeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(dockApp, kAXRoleAttribute as CFString, &value)
        return DockPinPolicy.dockProbeTrusted(axError: error.rawValue)
    }

    func requestTrustPrompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary   // kAXTrustedCheckOptionPrompt
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 새 프로세스 확인 1건의 결과(메인으로 넘기는 값)
private struct DockPinFreshOutcome: Sendable {
    var result: Bool?
    var failure: DockPinFreshFailure?
}

/// freshTrustCheck 핸들. cancel() → 취소 표시 + 실행 중인 자식 terminate. 응답 뒤 cancel()은 아무 일도 하지 않는다.
private final class DockPinFreshCheckHandle: DockPinCancellable, @unchecked Sendable {
    private struct State {
        var cancelled = false
        var finished = false
        var process: Process?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    /// 실행된 자식을 붙인다. 그사이 취소됐으면 바로 끝낸다.
    func attach(_ process: Process) {
        let cancelled = state.withLock { s -> Bool in
            s.process = process
            return s.cancelled
        }
        if cancelled { process.terminate() }
    }

    /// 메인에서 completion 직전에 부른다. 취소됐으면 false.
    func finish() -> Bool {
        state.withLock { s -> Bool in
            guard !s.cancelled else { return false }
            s.finished = true
            s.process = nil
            return true
        }
    }

    func cancel() {
        let process = state.withLock { s -> Process? in
            guard !s.cancelled, !s.finished else { return nil }
            s.cancelled = true
            return s.process
        }
        if let process, process.isRunning { process.terminate() }
    }
}

/// 세션 딕셔너리(잠금·콘솔), 버튼 상태, 마지막 입력 뒤 시간.
@MainActor final class DockPinLiveSession: DockPinSessionProviding {
    /// F3 — 키 없음 = 잠기지 않음 (판정은 DockPinPolicy.isScreenLocked)
    func isScreenLocked() -> Bool {
        DockPinPolicy.isScreenLocked(sessionInfo: Self.sessionInfo())
    }

    /// kCGSessionOnConsoleKey. 키가 없으면 콘솔로 본다(DockPinSessionState 기본값과 같다).
    func isOnConsole() -> Bool {
        (Self.sessionInfo()?[kCGSessionOnConsoleKey] as? NSNumber)?.boolValue ?? true
    }

    /// 왼·오·가운데
    func isAnyButtonDown() -> Bool {
        [CGMouseButton.left, .right, .center].contains {
            CGEventSource.buttonState(.hidSystemState, button: $0)
        }
    }

    /// kCGAnyInputEventType(~0)
    func secondsSinceLastInput() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return .greatestFiniteMagnitude }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }

    private static func sessionInfo() -> [String: Any]? {
        CGSessionCopyCurrentDictionary() as? [String: Any]
    }
}

/// NSWorkspace + 분산 + NSApplication 알림 토큰 보관, stop()에서 해제.
@MainActor final class DockPinLiveSystemEvents: DockPinSystemEventObserving {
    private var workspaceTokens: [NSObjectProtocol] = []
    private var appTokens: [NSObjectProtocol] = []
    private var distributedRelay: DockPinDistributedRelay?

    private static let distributedEvents: [(String, DockPinSystemEvent)] = [
        ("com.apple.screenIsLocked", .screenLocked),
        ("com.apple.screenIsUnlocked", .screenUnlocked),
        ("com.apple.accessibility.api", .accessibilityChanged),   // R9.5 빠른 경로
    ]

    func start(_ handler: @escaping @MainActor (DockPinSystemEvent) -> Void) {
        stop()

        let workspace = NSWorkspace.shared.notificationCenter
        let workspaceEvents: [(Notification.Name, DockPinSystemEvent)] = [
            (NSWorkspace.willSleepNotification, .willSleep),
            (NSWorkspace.didWakeNotification, .didWake),
            (NSWorkspace.screensDidWakeNotification, .screensDidWake),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionResignedActive),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionBecameActive),
        ]
        for (name, event) in workspaceEvents {
            workspaceTokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler(event) }
            })
        }
        // R6.1 — Dock 재시작
        workspaceTokens.append(workspace.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == DockPinLiveDockPreferences.dockBundleID else { return }
            MainActor.assumeIsolated { handler(.dockRelaunched) }
        })
        // R4.5 — 앱 활성화 때 Spaces 재읽기
        appTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler(.appBecameActive) }
        })

        // 분산 알림: 메뉴바 앱은 대부분 비활성이므로 즉시 전달(.deliverImmediately)로 등록한다.
        let relay = DockPinDistributedRelay(events: Self.distributedEvents, handler: handler)
        let center = DistributedNotificationCenter.default()
        for (name, _) in Self.distributedEvents {
            center.addObserver(relay, selector: #selector(DockPinDistributedRelay.received(_:)),
                               name: Notification.Name(name), object: nil,
                               suspensionBehavior: .deliverImmediately)
        }
        distributedRelay = relay
    }

    func stop() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceTokens.forEach { workspace.removeObserver($0) }
        workspaceTokens.removeAll()
        appTokens.forEach { NotificationCenter.default.removeObserver($0) }
        appTokens.removeAll()
        if let distributedRelay {
            DistributedNotificationCenter.default().removeObserver(distributedRelay)
            self.distributedRelay = nil
        }
    }
}

/// 분산 알림 selector 수신자(suspensionBehavior 지정은 selector 방식에만 있다).
private final class DockPinDistributedRelay: NSObject {
    private let events: [(String, DockPinSystemEvent)]
    private let handler: @MainActor (DockPinSystemEvent) -> Void

    init(events: [(String, DockPinSystemEvent)], handler: @escaping @MainActor (DockPinSystemEvent) -> Void) {
        self.events = events
        self.handler = handler
    }

    @objc func received(_ note: Notification) {
        guard let event = events.first(where: { $0.0 == note.name.rawValue })?.1 else { return }
        let handler = handler
        if Thread.isMainThread {
            MainActor.assumeIsolated { handler(event) }
        } else {
            DispatchQueue.main.async { handler(event) }
        }
    }
}

/// 태그 단 mouseMoved 전송. warp는 없다(R8.5, AC13.3).
@MainActor final class DockPinLiveEventPoster: DockPinEventPosting {
    func cursorLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    /// R5.10 / F8 — CGEventSource(.hidSystemState).userData = 표식, post(.cghidEventTap)
    func postTaggedMouseMove(to point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        source.userData = DockPinTuning.eventMarker
        guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: DockPinTuning.eventMarker)
        event.post(tap: .cghidEventTap)
    }
}

/// CGWindowList 조회(조회 큐에서 불린다, 상태 없음).
struct DockPinLiveWindowListing: DockPinWindowListing {
    /// R6.2 — PID 소유 + 레이어. 창 이름·onscreen은 조건이 아니다(.optionAll).
    func dockWindows(pid: pid_t, layer: Int) -> [DockPinWindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == layer else { return nil }
            return Self.windowInfo(entry)
        }
    }

    /// R6.3 / F4 — 입력 CFArray는 포인터 크기 정수 값(콜백 없는 CFArrayCreate). [NSNumber]는 결과 0개다.
    func window(number: CGWindowID) -> DockPinWindowInfo? {
        guard let raw = UnsafeRawPointer(bitPattern: UInt(number)) else { return nil }
        var values: [UnsafeRawPointer?] = [raw]
        guard let array = CFArrayCreate(kCFAllocatorDefault, &values, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]],
              let entry = list.first else { return nil }
        return Self.windowInfo(entry)
    }

    private static func windowInfo(_ entry: [String: Any]) -> DockPinWindowInfo? {
        guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
        return DockPinWindowInfo(number: number, bounds: bounds)
    }
}
