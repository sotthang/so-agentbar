import CoreGraphics
import Foundation

// SPEC-004 Dock Pin — 되돌리기 실행기 (arch §2.9)
// 주입형 파일. 다가가기(15점) → 목표 줄 유지(6틱마다 단일 조회) → 2.0 s 뒤 이동 중단 + 마지막 전체 조회(.final, 상한 1.2 s)
// → 결과 뒤 복원(R8.3–R8.6, D2). 전송기·조회기·스케줄러·활동 카운터·복원점 계산은 모두 주입한다.
// warp 경로는 없다(DockPinEventPosting에 warp 메서드가 없다, AC13.3).
//
// 시간 기준: 15번째 이동(목표 줄 도달) 시각 reachedAt. 첫 이동은 start() 안에서 바로 보낸다(틱 0).
// 늦게 온 조회 결과·시간 초과는 시도 세대(generation)로 버린다. 끝나면 대기 중 틱·시간 초과 예약을 취소한다.
// (r6.6) NEW-1 — 틱 수와 별개로 시작 시각 기준 벽시계 상한(wallClockLimit)을 넘긴 틱은 이동 없이 .failed로 끝낸다.

/// R8.3 — 한 번의 되돌리기 계획
struct DockPinDrivePlan: Equatable, Sendable {
    let target: CGPoint                         // R3.6 목표점
    let anchorID: CGDirectDisplayID
    let displays: [DockPinDisplay]              // locate 입력
}

enum DockPinDriveAbortReason: Equatable, Sendable {
    case userActivity, displayReconfigured, sleep, locked, sessionInactive,
         permissionLost, deactivated, shutdown, cursorUnavailable
}

enum DockPinDriveOutcome: Equatable, Sendable { case succeeded, failed, aborted(DockPinDriveAbortReason) }

/// AC8.2 — y 오프셋 −40, −37, …, −4, −1, 0 (15점), x는 모두 target.x
enum DockPinDrivePath {
    static func approach(to target: CGPoint, height: CGFloat = DockPinTuning.approachHeight,
                         step: CGFloat = DockPinTuning.approachStep) -> [CGPoint] {
        var points: [CGPoint] = []
        if step > 0 {
            var offset = -height
            while offset < 0 {
                points.append(CGPoint(x: target.x, y: target.y + offset))
                offset += step
            }
        }
        points.append(target)      // 마지막 걸음은 목표 줄(리뷰 N3)
        return points
    }
}

@MainActor
final class DockPinRelocator {
    private let poster: DockPinEventPosting
    private let locator: DockPinDockLocating
    private let scheduler: DockPinScheduling
    private let userActivityCount: @MainActor () -> UInt64
    private let restorePoint: @MainActor (CGPoint) -> CGPoint?

    init(poster: DockPinEventPosting, locator: DockPinDockLocating, scheduler: DockPinScheduling,
         userActivityCount: @escaping @MainActor () -> UInt64,
         restorePoint: @escaping @MainActor (CGPoint) -> CGPoint?) {
        self.poster = poster
        self.locator = locator
        self.scheduler = scheduler
        self.userActivityCount = userActivityCount
        self.restorePoint = restorePoint
    }

    private(set) var isActive: Bool = false

    private enum Phase { case approaching(next: Int), holding, finalWait }

    private var generation: UInt64 = 0
    private var phase: Phase = .holding
    private var plan: DockPinDrivePlan?
    private var path: [CGPoint] = []
    private var saved: CGPoint = .zero
    private var baseline: UInt64 = 0
    private var reachedAt: TimeInterval = 0
    /// (r6.6) NEW-1 — 벽시계 상한의 기준(매니저 스냅숏 시한과 같은 시각)
    private var startAt: TimeInterval = 0
    private var holdTicks = 0
    private var completion: (@MainActor (DockPinDriveOutcome) -> Void)?
    private var tickToken: DockPinCancellable?
    private var timeoutToken: DockPinCancellable?

    /// 부동소수 누적 오차 흡수용
    private static let timeEpsilon: TimeInterval = 1e-9
    /// (r6.6) NEW-1 — 시작 뒤 이 시간이 지나면 틱 수와 무관하게 .failed로 끝낸다. 탭 시한(guardWindow)보다
    /// 여유만큼 먼저라 메인이 늦어도 탭이 입력을 막지 않게 된 뒤에는 이동을 보내지 않는다.
    /// 정상 최악(도달 0.224 + 유지 2.0 + 틱 0.016 + 마지막 조회 1.2 = 3.44 s) 이하라 정상 경로에는 영향이 없다.
    static let wallClockLimit: TimeInterval =
        DockPinTuning.relocationGuardWindow - DockPinTuning.relocationDeadlineMargin

    /// completion은 정확히 1번. 커서를 못 읽으면 이벤트 없이 .aborted(.cursorUnavailable)
    /// 진행 중에 다시 부르면 무시한다(매니저는 진행 중에 start하지 않는다).
    /// startedAt = 벽시계 상한 기준(매니저는 스냅숏 시한과 같은 값을 넘긴다). nil이면 scheduler.now
    func start(_ plan: DockPinDrivePlan, startedAt: TimeInterval? = nil,
               completion: @escaping @MainActor (DockPinDriveOutcome) -> Void) {
        guard !isActive else { return }
        guard let cursor = poster.cursorLocation() else {      // R8.3-1 — 커서는 여기서 한 번만 읽는다
            completion(.aborted(.cursorUnavailable))
            return
        }
        generation &+= 1
        isActive = true
        self.plan = plan
        self.completion = completion
        saved = cursor
        startAt = startedAt ?? scheduler.now
        baseline = userActivityCount()
        path = DockPinDrivePath.approach(to: plan.target)
        phase = .approaching(next: 0)
        holdTicks = 0
        runTick(generation)
    }

    /// 진행 중일 때만: 즉시 멈추고 복원(있으면 1번) 후 completion(.aborted(reason)). 아니면 무동작
    func abort(_ reason: DockPinDriveAbortReason) {
        finish(.aborted(reason))
    }

    // MARK: - 틱

    private func runTick(_ gen: UInt64) {
        guard isActive, gen == generation, let plan else { return }
        if userActivityCount() > baseline {                    // R8.6 — 맨 먼저, 마지막 조회 대기 중에도
            finish(.aborted(.userActivity))
            return
        }
        let now = scheduler.now
        if now - startAt > Self.wallClockLimit {               // NEW-1 — 메인 지연·App Nap. 시간 초과처럼 실패, 이동 없음
            finish(.failed)
            return
        }
        switch phase {
        case .approaching(let index):
            poster.postTaggedMouseMove(to: path[index])
            if index + 1 < path.count {
                phase = .approaching(next: index + 1)
            } else {
                reachedAt = now
                phase = .holding
            }
        case .holding:
            if now - reachedAt >= DockPinTuning.relocationTimeout - Self.timeEpsilon {
                beginFinalScan(plan, gen)                       // R8.3-5 — 이동·단일 조회 중지
            } else {
                poster.postTaggedMouseMove(to: plan.target)
                holdTicks += 1
                if holdTicks % DockPinTuning.verifyEveryTicks == 0 {
                    locator.locate(.quick, displays: plan.displays) { [weak self] outcome in
                        guard let self, gen == self.generation, case .holding = self.phase else { return }
                        if outcome == .placement(.display(plan.anchorID)) { self.finish(.succeeded) }
                    }
                }
            }
        case .finalWait:
            break                                               // 활동 카운터만 본다
        }
        // completion이 동기로 왔을 수 있으니 다시 확인한다
        guard isActive, gen == generation else { return }
        tickToken = scheduler.schedule(after: DockPinTuning.driveInterval, kind: .driveTick) { [weak self] in
            self?.runTick(gen)
        }
    }

    private func beginFinalScan(_ plan: DockPinDrivePlan, _ gen: UInt64) {
        phase = .finalWait
        timeoutToken = scheduler.schedule(after: DockPinTuning.finalScanTimeout, kind: .finalScanTimeout) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.finish(.failed)
        }
        locator.locate(.final, displays: plan.displays) { [weak self] outcome in
            guard let self, gen == self.generation else { return }
            self.finish(outcome == .placement(.display(plan.anchorID)) ? .succeeded : .failed)
        }
    }

    // MARK: - 끝

    /// 진행 중일 때만: 틱·시간 초과 취소 → 복원(있으면 1번, D2) → completion 1번
    private func finish(_ outcome: DockPinDriveOutcome) {
        guard isActive else { return }
        isActive = false
        generation &+= 1
        tickToken?.cancel()
        tickToken = nil
        timeoutToken?.cancel()
        timeoutToken = nil
        plan = nil
        if let point = restorePoint(saved) {
            poster.postTaggedMouseMove(to: point)
        }
        let done = completion
        completion = nil
        done?(outcome)
    }
}
