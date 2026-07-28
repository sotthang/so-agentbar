import AppKit
import Foundation

// MARK: - MenubarAnimationController
//
// SPEC-003 C3 — 상태 계층. 메뉴바 로고 바운스 애니메이션의 타이머/프레임 진행/
// 슬립·웨이크 상태 전이를 관장한다.
//
// arch §4-3의 확정 설계를 그대로 구현한다. 판정 로직(isActive/resolve/timerPlan/
// frameIndex)은 전부 `MenubarActivityIndicator`(순수 계층)를 호출하며, 이 파일에서
// 새로운 판정 로직을 만들지 않는다(R5.7).

@MainActor
final class MenubarAnimationController {

    // MARK: 불변/캐시

    /// `NSImage(named: "logo")` 1회 취득 — 공유 캐시 인스턴스를 절대 변이시키지 않는다(R3.5).
    private let source: NSImage?
    /// 프레임 캐시 = 상태(R3.4). init에서 6프레임 즉시 생성(지연 생성 금지 — §8-3 함정).
    private var frames: [NSImage] = []

    // MARK: 내부 상태

    private var timer: Timer?
    /// suspend()에서 nil로 리셋된다(R7.3-1) — 버그 A(영구 정지) 방지의 핵심.
    private var currentTier: MenubarActivityTier?
    /// sticky 플래그(R7.3-2) — true인 동안 update(...)는 상태만 재평가하고 타이머는 만들지 않는다.
    private var isSuspended = false
    /// 초기값 = AgentStore 기본 스타일(.emoji) → 초기 state는 .disabled와 일치한다.
    private var currentStyle: MenubarStyle = .emoji
    private var lastWorkingAt: Date?
    private var lastSustainAt: Date?
    private var effectiveRunningCount = 0

    // MARK: 주입 훅

    /// R5.7/AC44 — 하강 구간 재평가용 시계. 테스트에서 교체한다.
    var nowProvider: () -> Date = { Date() }
    let hold: TimeInterval
    let maxSustain: TimeInterval

    /// button.image 교체 콜백. 호출부가 [weak self]로 설정한다(R7.9).
    var onFrame: ((NSImage) -> Void)?

    // MARK: 관측 가능한 상태 (R7.2)

    private(set) var state: MenubarIndicatorState = .disabled
    private(set) var tick: Int = 0
    /// 등록된 런루프 모드(R7.8). 항상 `.common`으로 등록한다.
    private(set) var timerMode: RunLoop.Mode = .common
    /// 타이머를 새로 만들 때마다 +1(AC38).
    private(set) var timerGeneration: Int = 0

    var isRunning: Bool { timer != nil }

    var currentImage: NSImage? {
        guard !frames.isEmpty else { return nil }          // R3.6 / AC23
        return frames[MenubarActivityIndicator.frameIndex(tick: tick, frameCount: frames.count)]
    }

    // MARK: 생성

    /// - Parameter source: 기본 `NSImage(named: "logo")`를 1회 로드한다.
    ///   테스트에서 로고 없는 경우(AC23)를 재현하려면 명시적으로 `nil`을 넘긴다.
    init(
        source: NSImage? = NSImage(named: "logo"),
        hold: TimeInterval = MenubarActivityIndicator.defaultHold,
        maxSustain: TimeInterval = MenubarActivityIndicator.defaultMaxSustain
    ) {
        self.source = source
        self.hold = hold
        self.maxSustain = maxSustain
        if let source {
            self.frames = MenubarActivityIndicator.makeFrames(source: source)
        }
    }

    // MARK: 공개 API

    /// R5.4/R8.4 — 유효 실행 카운트 갱신 + 재평가. onFrame은 발화하지 않는다(§4-4 계약 —
    /// 호출부가 곧바로 updateIcon()을 돌려 controller.currentImage를 대입한다).
    func update(style: MenubarStyle, runningCount: Int, isSustaining: Bool, now: Date) {
        currentStyle = style
        if runningCount > 0 {
            lastWorkingAt = now
            lastSustainAt = now
            effectiveRunningCount = runningCount
        } else if isSustaining {
            lastSustainAt = now                     // lastWorkingAt은 갱신하지 않는다(R4.4)
        }
        reevaluate(now: now)
    }

    /// R7.12 — tick 증가 → R5.7 재평가 → 방출.
    func advanceFrame() {
        tick += 1
        reevaluate(now: nowProvider())              // 하강 구간 자동 정지(AC44)
        emitCurrentFrame()
    }

    /// R7.3 — sticky suspend. 타이머 invalidate + currentTier nil 리셋(버그 A 방지).
    func suspend() {
        isSuspended = true
        stopTimer()
        currentTier = nil
        emitCurrentFrame()
    }

    /// R9.3 — 저장된 타임스탬프 기준 재평가로 복귀.
    func resume(now: Date) {
        isSuspended = false
        reevaluate(now: now)
        emitCurrentFrame()
    }

    // MARK: 내부

    /// R5.1/R5.4/R5.5 — 유일한 판정 지점. update / resume / advanceFrame이 모두 이걸 부른다.
    private func reevaluate(now: Date) {
        if !MenubarActivityIndicator.isActive(
            lastWorkingAt: lastWorkingAt,
            lastSustainAt: lastSustainAt,
            now: now,
            hold: hold,
            maxSustain: maxSustain
        ) {
            effectiveRunningCount = 0
        }
        apply(MenubarActivityIndicator.resolve(style: currentStyle, effectiveCount: effectiveRunningCount))
    }

    private func apply(_ newState: MenubarIndicatorState) {
        state = newState
        let desired = newState.tier
        if desired == nil { tick = 0 }               // R7.11 — .still/.disabled 진입 시 정지 포즈로 리셋
        guard !isSuspended else {                    // R7.3-2 — 이 guard가 currentTier 대입보다 앞이어야 한다
            stopTimer()
            return
        }
        switch MenubarActivityIndicator.timerPlan(current: currentTier, desired: desired) {
        case .keep:
            break
        case .stop:
            stopTimer()
        case .restart(let tier):
            startTimer(tier: tier)
        }
        currentTier = desired
    }

    private func startTimer(tier: MenubarActivityTier) {
        stopTimer()
        let interval = tier.frameInterval
        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in   // R7.9
            Task { @MainActor in self?.advanceFrame() }
        }
        newTimer.tolerance = interval * 0.1                                              // R7.10
        RunLoop.main.add(newTimer, forMode: .common)                                     // R7.8
        timer = newTimer
        timerMode = .common
        timerGeneration += 1                                                              // AC38
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil                                                                       // R7.11
    }

    private func emitCurrentFrame() {
        if let img = currentImage { onFrame?(img) }
    }

    /// `.common` 모드로 등록된 Timer 는 런루프가 강하게 잡는다. 현재는 이 컨트롤러가
    /// AppDelegate 수명과 같고 `applicationWillTerminate` 에서 `suspend()` 를 타지만,
    /// 그 가정에 기대지 않도록 여기서도 무효화한다.
    deinit {
        timer?.invalidate()
    }
}
