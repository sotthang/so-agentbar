import CoreGraphics
import Foundation

// SPEC-004 Dock Pin — Dock 위치 조회기 (arch §2.8)
// 부작용 파일. 창 번호 캐시, 직렬 조회 큐(.utility), 합치기, 백오프·속도 제한(R6.1–R6.6).
// 판정 자체는 DockPinPlacementRules(순수)에 있고, 창 목록 IO는 DockPinWindowListing 뒤에 있다.
//
// 스레드: 상태는 모두 메인 액터에 있다. 조회 큐에는 값(PID, 캐시 번호, preferCached, 디스플레이)만 넘기고,
// 큐는 값만 돌려준다(DispatchQueue.main.async). 결과는 세대 번호가 같을 때만 반영한다(cancelAll).

@MainActor
final class DockPinDockLocator: DockPinDockLocating {
    /// R6.2 — Dock 레이어(이 Mac에서 20, F4)
    private nonisolated static let dockLayer = Int(CGWindowLevelForKey(.dockWindow))

    private typealias Completion = @MainActor (DockPinLocateOutcome) -> Void

    /// 진행 중이거나 속도 제한으로 미뤄진 동안 모인 요청(가장 센 모드 + completion 목록)
    private struct Pending {
        var mode: DockPinLocateMode
        var displays: [DockPinDisplay]
        var completions: [Completion]
    }

    /// 조회 큐 작업의 입력(값만)
    private enum Job: Sendable {
        case single(CGWindowID, fullFallbackAllowed: Bool, preferCached: Bool)
        case full(preferCached: Bool)
    }

    private enum CacheUpdate: Sendable {
        case keep, set(CGWindowID), clear
    }

    /// 조회 큐 작업의 결과(값만)
    private struct JobResult: Sendable {
        let outcome: DockPinLocateOutcome
        let cache: CacheUpdate
        let fullScanned: Bool
    }

    private let listing: DockPinWindowListing
    private let dockPreferences: DockPinDockPreferencesProviding
    private let scheduler: DockPinScheduling
    private let queue: DispatchQueue
    private let pause: @Sendable (TimeInterval) -> Void

    private var cachedNumber: CGWindowID?
    private var consecutiveFailures = 0
    private var nextFullScanAllowedAt: TimeInterval?
    private var lastEventScanAt: TimeInterval?
    private var inFlight = false
    private var pending: Pending?
    private var rateLimitWait: DockPinCancellable?
    private var generation = 0

    init(listing: DockPinWindowListing,
         dockPreferences: DockPinDockPreferencesProviding,
         scheduler: DockPinScheduling,
         queue: DispatchQueue = DispatchQueue(label: "so-agentbar.dockpin.locate", qos: .utility),
         pause: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.listing = listing
        self.dockPreferences = dockPreferences
        self.scheduler = scheduler
        self.queue = queue
        self.pause = pause
    }

    func locate(_ mode: DockPinLocateMode, displays: [DockPinDisplay],
                completion: @escaping @MainActor (DockPinLocateOutcome) -> Void) {
        // R6.5 — 진행 중(또는 속도 제한 대기 중)이면 합친다. 동시에 두 조회가 돌지 않는다.
        if inFlight || rateLimitWait != nil {
            merge(mode, displays: displays, completion: completion)
            return
        }
        start(mode, displays: displays, completions: [completion], rateLimitPassed: false)
    }

    /// R6.1 — Dock 재시작
    func invalidateCache() {
        cachedNumber = nil
    }

    /// 세대 번호 증가 → 진행 중 결과·대기 중 completion을 버린다(0번 호출).
    func cancelAll() {
        generation += 1
        inFlight = false
        pending = nil
        rateLimitWait?.cancel()
        rateLimitWait = nil
    }

    // MARK: - 내부

    private func merge(_ mode: DockPinLocateMode, displays: [DockPinDisplay], completion: @escaping Completion) {
        guard var merged = pending else {
            pending = Pending(mode: mode, displays: displays, completions: [completion])
            return
        }
        if Self.strength(mode) > Self.strength(merged.mode) { merged.mode = mode }
        merged.displays = displays
        merged.completions.append(completion)
        pending = merged
    }

    /// final > event > full > quick
    private static func strength(_ mode: DockPinLocateMode) -> Int {
        switch mode {
        case .quick: return 0
        case .full: return 1
        case .event: return 2
        case .final: return 3
        }
    }

    private func start(_ mode: DockPinLocateMode, displays: [DockPinDisplay],
                       completions: [Completion], rateLimitPassed: Bool) {
        guard let pid = dockPreferences.dockPID() else {
            deliver(.placement(.unknown), to: completions)
            return
        }
        let now = scheduler.now
        let fullScanAllowed = now >= (nextFullScanAllowedAt ?? -.infinity)
        let job: Job
        switch mode {
        case .quick, .full:
            if mode == .quick, let cachedNumber {
                job = .single(cachedNumber, fullFallbackAllowed: fullScanAllowed, preferCached: true)
            } else if fullScanAllowed {
                job = .full(preferCached: true)
            } else {
                deliver(.deferred, to: completions)   // R6.6 백오프 중
                return
            }
        case .event, .final:
            // I1 — 백오프는 무시하되 1초에 한 번. 버리지 않고 그 시각까지 미룬다.
            if !rateLimitPassed, let last = lastEventScanAt,
               now < last + DockPinTuning.eventScanMinInterval {
                pending = Pending(mode: mode, displays: displays, completions: completions)
                rateLimitWait = scheduler.schedule(after: last + DockPinTuning.eventScanMinInterval - now,
                                                   kind: .scanRateLimit) { [weak self] in
                    self?.runRateLimited()
                }
                return
            }
            lastEventScanAt = now
            job = .full(preferCached: mode != .final)
        }
        run(job, pid: pid, displays: displays, completions: completions)
    }

    private func runRateLimited() {
        rateLimitWait = nil
        startPending(rateLimitPassed: true)
    }

    /// 합쳐 둔 요청을 꺼내 시작한다
    private func startPending(rateLimitPassed: Bool) {
        guard let next = pending else { return }
        pending = nil
        start(next.mode, displays: next.displays, completions: next.completions, rateLimitPassed: rateLimitPassed)
    }

    private func run(_ job: Job, pid: pid_t, displays: [DockPinDisplay], completions: [Completion]) {
        inFlight = true
        let jobGeneration = generation
        let cached = cachedNumber
        let listing = listing
        let pause = pause
        queue.async { [weak self] in
            let result = Self.perform(job, pid: pid, cachedNumber: cached, displays: displays,
                                      listing: listing, pause: pause)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finish(result, generation: jobGeneration, completions: completions)
                }
            }
        }
    }

    /// 조회 큐에서 돈다. 상태 없음 — 값만 받고 값만 돌려준다.
    private nonisolated static func perform(_ job: Job, pid: pid_t, cachedNumber: CGWindowID?,
                                            displays: [DockPinDisplay], listing: DockPinWindowListing,
                                            pause: (TimeInterval) -> Void) -> JobResult {
        switch job {
        case let .single(number, fullFallbackAllowed, preferCached):
            if let window = listing.window(number: number) {
                return JobResult(outcome: .placement(DockPinPlacementRules.placement(of: window.bounds, in: displays)),
                                 cache: .keep, fullScanned: false)
            }
            // R6.3 — 캐시 창이 사라졌으면 전체 조회(백오프 지킴)
            guard fullFallbackAllowed else {
                return JobResult(outcome: .deferred, cache: .clear, fullScanned: false)
            }
            return fullScan(pid: pid, cachedNumber: cachedNumber, preferCached: preferCached,
                            displays: displays, listing: listing, pause: pause)
        case let .full(preferCached):
            return fullScan(pid: pid, cachedNumber: cachedNumber, preferCached: preferCached,
                            displays: displays, listing: listing, pause: pause)
        }
    }

    private nonisolated static func fullScan(pid: pid_t, cachedNumber: CGWindowID?, preferCached: Bool,
                                             displays: [DockPinDisplay], listing: DockPinWindowListing,
                                             pause: (TimeInterval) -> Void) -> JobResult {
        let settled = DockPinPlacementRules.settle(cachedNumber: cachedNumber, preferCached: preferCached,
                                                   displays: displays,
                                                   maxReads: DockPinTuning.settleMaxReads,
                                                   interval: DockPinTuning.settleRetryInterval,
                                                   read: { listing.dockWindows(pid: pid, layer: dockLayer) },
                                                   pause: pause)
        switch settled.selection {
        case let .chosen(window, placement):
            return JobResult(outcome: .placement(placement), cache: .set(window.number), fullScanned: true)
        case .ambiguous, .none:
            return JobResult(outcome: .placement(.unknown), cache: .clear, fullScanned: true)
        }
    }

    private func finish(_ result: JobResult, generation jobGeneration: Int, completions: [Completion]) {
        guard jobGeneration == generation else { return }   // cancelAll 뒤 늦은 결과
        switch result.cache {
        case .keep: break
        case .set(let number): cachedNumber = number
        case .clear: cachedNumber = nil
        }
        if result.fullScanned { updateBackoff(after: result.outcome) }

        // 전달 중 재진입한 요청은 pending에 합쳐지도록 inFlight를 유지한다.
        deliver(result.outcome, to: completions)
        guard jobGeneration == generation else { return }   // completion 안에서 cancelAll
        inFlight = false
        if rateLimitWait == nil { startPending(rateLimitPassed: false) }
    }

    /// R6.6 — 전체 조회 결과 .unknown이 연달아 나오면 다음 전체 조회 간격을 늘린다. 성공하면 초기화.
    private func updateBackoff(after outcome: DockPinLocateOutcome) {
        if outcome == .placement(.unknown) {
            consecutiveFailures += 1
            nextFullScanAllowedAt = scheduler.now
                + DockPinPlacementRules.scanBackoff(consecutiveFailures: consecutiveFailures)
        } else {
            consecutiveFailures = 0
            nextFullScanAllowedAt = nil
        }
    }

    private func deliver(_ outcome: DockPinLocateOutcome, to completions: [Completion]) {
        let deliveryGeneration = generation
        for completion in completions {
            guard deliveryGeneration == generation else { return }
            completion(outcome)
        }
    }
}
