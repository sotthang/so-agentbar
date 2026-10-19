import CoreGraphics
import Foundation
import os

// SPEC-004 Dock Pin — 전용 스레드 CGEventTap (arch §2.7)
// 잠금 2개(shared, handles) + 탭 스레드 전용 suppression, 메인 깨우기 CFRunLoopSource (R5).
//
// 스레드 규칙
// - 메인: init, start, stop, update, reenableIfNeeded, drainSignals, userActivityCount, onOptionPassSignal.
// - 탭 스레드: 콜백(handle)과 스레드 본문(runTapThread)만. suppression은 탭 스레드 전용이다.
//   메인은 start()에서 스레드를 띄우기 전에만 reset()한다(Thread.start가 happens-before).
// - 콜백은 할당·로그·ObjC 메시지·클로저 디스패치를 하지 않는다(R5.6). 잠금 body는 값만 반환한다(V4).
// - init은 시스템 호출을 하지 않는다. 스레드·탭·런루프 소스는 start()에서만 만든다.

final class DockPinEventTap: DockPinEventTapping, @unchecked Sendable {

    /// 탭 스레드와 메인이 함께 쓰는 값(R5.3).
    private struct Shared: Sendable {
        var snapshot = DockPinGuardSnapshot()
        var signals = DockPinSignalBox()
    }

    /// CF 핸들 + 탭 수명. 재활성화 판단과 정리가 같은 잠금을 쓴다(R5.7).
    private struct Handles {
        var port: CFMachPort?
        var source: CFRunLoopSource?
        var runLoop: CFRunLoop?
        var lifecycle = DockPinTapLifecycle()
        /// 메인 깨우기 소스(F6). 콜백은 잠금 안에서 참조만 복사한다.
        var wake: CFRunLoopSource?
        /// start/stop마다 올린다. 늦게 끝난 탭 스레드가 낡은 세대면 스스로 정리한다.
        var generation: UInt64 = 0
    }

    private let clock: @Sendable () -> TimeInterval
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let handles = OSAllocatedUnfairLock(uncheckedState: Handles())

    /// 탭 스레드 전용(잠금 밖).
    private var suppression = DockPinGestureSuppression()

    /// 메인 전용. 탭 스레드 종료 신호.
    private var threadExited: DispatchSemaphore?

    /// 메인 런루프 perform에서 불린다(메인 전용).
    var onOptionPassSignal: (() -> Void)?

    init(clock: @escaping @Sendable () -> TimeInterval = { DockPinEventTap.uptime() }) {
        self.clock = clock
    }

    /// 안전망: stop() 없이 놓아도 깨우기 소스가 해제된 self를 가리킨 채 남지 않게 한다.
    /// (탭 스레드는 살아 있는 동안 self를 붙잡으므로 여기 올 때 탭은 이미 없다.)
    deinit {
        if let wake = handles.withLockUnchecked({ $0.wake }) {
            Self.removeWakeSource(wake)
        }
    }

    /// clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9 (V5, 할당 없음) == ProcessInfo.systemUptime
    static func uptime() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    var isRunning: Bool {
        handles.withLockUnchecked { $0.port != nil }
    }

    var userActivityCount: UInt64 {
        shared.withLock { $0.signals.userActivityCount }
    }

    func update(snapshot: DockPinGuardSnapshot) {
        shared.withLock { $0.snapshot = snapshot }
    }

    func drainSignals() -> DockPinTapSignals {
        shared.withLock { $0.signals.drain() }
    }

    /// R5.8 — 살아 있는 탭이 꺼져 있으면 다시 켠다. 다시 켰으면 true.
    func reenableIfNeeded() -> Bool {
        handles.withLockUnchecked { h -> Bool in
            guard let port = h.port, h.lifecycle.isArmed, !h.lifecycle.isStopping else { return false }
            if CGEvent.tapIsEnabled(tap: port) { return false }
            CGEvent.tapEnable(tap: port, enable: true)
            return true
        }
    }

    // MARK: - 시작 (메인, 동기)

    /// false = tapCreate nil 또는 시작 시간 초과 (R5.9)
    func start() -> Bool {
        if isRunning { return true }
        stop()   // 이전 시도의 잔여(시간 초과 스레드, 깨우기 소스)를 먼저 치운다

        suppression.reset()
        shared.withLock { $0.signals = DockPinSignalBox() }

        let wake = makeWakeSource()
        CFRunLoopAddSource(CFRunLoopGetMain(), wake, .commonModes)
        let generation = handles.withLockUnchecked { h -> UInt64 in
            h.generation &+= 1
            h.wake = wake
            return h.generation
        }

        let ready = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        threadExited = exited
        let thread = Thread { [self] in
            runTapThread(generation: generation, ready: ready)
            exited.signal()
        }
        thread.name = "so-agentbar.dockpin.tap"
        thread.qualityOfService = .userInteractive
        thread.start()

        let signaled = ready.wait(timeout: .now() + DockPinTuning.tapStartTimeout) == .success
        if signaled && isRunning { return true }
        stop()
        return false
    }

    /// 탭 스레드 본문. tapCreate → 자기 런루프에 붙임 → 핸들 저장 → 성공 신호 → CFRunLoopRun.
    private func runTapThread(generation: UInt64, ready: DispatchSemaphore) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: DockPinEdgeRule.eventMask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<DockPinEventTap>.fromOpaque(refcon).takeUnretainedValue()
                return tap.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            ready.signal()
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            ready.signal()
            return
        }
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)

        // 메인이 이미 포기했으면(시간 초과 → stop) 세대가 달라져 있다 → 스스로 정리하고 끝낸다.
        let adopted = handles.withLockUnchecked { h -> Bool in
            guard h.generation == generation else { return false }
            h.port = port
            h.source = source
            h.runLoop = runLoop
            h.lifecycle.arm()
            CGEvent.tapEnable(tap: port, enable: true)
            return true
        }
        ready.signal()
        guard adopted else {
            CGEvent.tapEnable(tap: port, enable: false)
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFMachPortInvalidate(port)
            return
        }
        // stop()이 소스를 떼고 CFRunLoopStop을 부르면 돌아온다(소스가 없으면 즉시 Finished).
        CFRunLoopRun()
    }

    // MARK: - 콜백 (탭 스레드, R5.6: 할당·로그·ObjC·디스패치 없음)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // R5.7 — 정리 중이 아니고 핸들이 남아 있을 때만, 같은 잠금 안에서 다시 켠다.
            // 억제는 비우지 않는다(arch I5).
            handles.withLockUnchecked { h in
                if h.lifecycle.handleDisabledEvent(), let port = h.port {
                    CGEvent.tapEnable(tap: port, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        let snapshot = shared.withLock { $0.snapshot }
        let now = clock()                                   // VULN-002 — 시한 비교와 신호 기록이 같은 탭 시계
        let decision = DockPinEdgeRule.decide(
            type: type,
            location: event.location,
            flags: event.flags,
            userData: event.getIntegerValueField(.eventSourceUserData),
            buttonNumber: event.getIntegerValueField(.mouseEventButtonNumber),
            snapshot: snapshot,
            now: now,
            suppression: &suppression)

        if let signal = decision.signal {
            let notify = shared.withLock { $0.signals.record(signal, at: now) }
            if notify, let wake = handles.withLockUnchecked({ $0.wake }) {
                CFRunLoopSourceSignal(wake)
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
        }
        return decision.action == .drop ? nil : Unmanaged.passUnretained(event)
    }

    // MARK: - 메인 깨우기 소스 (F6)

    private func makeWakeSource() -> CFRunLoopSource {
        var context = CFRunLoopSourceContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil, equal: nil, hash: nil,
            schedule: nil, cancel: nil,
            perform: { info in
                guard let info else { return }
                Unmanaged<DockPinEventTap>.fromOpaque(info).takeUnretainedValue().deliverOptionPassSignal()
            })
        return CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
    }

    /// 메인 런루프 perform. 소스는 메인 런루프에만 붙으므로 항상 메인이다.
    private func deliverOptionPassSignal() {
        MainActor.assumeIsolated {
            onOptionPassSignal?()
        }
    }

    // MARK: - 정리 (메인, 동기, 멱등, R9.3 순서)

    func stop() {
        // 1) 같은 잠금 안에서: 수명 정리 시작 → tapEnable(false) → 소스 제거 → 포트 무효화 → 런루프 정지 → 핸들 nil
        handles.withLockUnchecked { h in
            h.generation &+= 1
            guard h.port != nil || h.runLoop != nil else { return }
            h.lifecycle.beginStop()
            if let port = h.port { CGEvent.tapEnable(tap: port, enable: false) }
            if let runLoop = h.runLoop, let source = h.source {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
            if let port = h.port { CFMachPortInvalidate(port) }
            if let runLoop = h.runLoop { CFRunLoopStop(runLoop) }
            h.port = nil
            h.source = nil
            h.runLoop = nil
        }

        // 2) 잠금 밖에서 스레드 종료를 기다린다
        if let exited = threadExited {
            _ = exited.wait(timeout: .now() + DockPinTuning.tapStopTimeout)
            threadExited = nil
        }

        // 3) 깨우기 소스 무효화
        let wake = handles.withLockUnchecked { h -> CFRunLoopSource? in
            let w = h.wake
            h.wake = nil
            return w
        }
        if let wake {
            Self.removeWakeSource(wake)
        }
    }

    private static func removeWakeSource(_ wake: CFRunLoopSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), wake, .commonModes)
        CFRunLoopSourceInvalidate(wake)
    }
}
