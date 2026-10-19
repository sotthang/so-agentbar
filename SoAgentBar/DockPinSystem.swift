import AppKit
import ApplicationServices
import CoreGraphics
import os

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
    func requestTrustPrompt()                   // AXIsProcessTrustedWithOptions(prompt: true)
    func openPrivacySettings()                  // x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility
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

/// AX 권한 확인·요청·설정 열기.
@MainActor final class DockPinLivePermission: DockPinPermissionProviding {
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
