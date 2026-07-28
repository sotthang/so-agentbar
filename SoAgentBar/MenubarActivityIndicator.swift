import AppKit
import Foundation

// MARK: - MenubarActivityIndicator
//
// SPEC-003 C2 — 순수 계층(상태 없음). 메뉴바 로고 바운스 애니메이션의
// 기하/집계/판정 로직을 순수 함수로 분리한다.
//
// 상수(frameCount/logoSide/amplitude/canvasSize/restY/yOffsets/defaultHold/defaultMaxSustain)는
// S0 스파이크에서 이미 확정된 값이므로 스텁이 아니라 최종값이다 (R2.4, 폴백 R2.9 미채택).

// MARK: - 타입 (R6/R7)

enum MenubarActivityTier: Equatable {
    case slow, normal, fast

    /// R6.3 — 별도 함수가 아니라 computed property.
    var frameInterval: TimeInterval {
        switch self {
        case .slow:   return 0.40
        case .normal: return 0.25
        case .fast:   return 0.14
        }
    }
}

enum MenubarIndicatorState: Equatable {
    case disabled                              // 레거시 스타일 — 인디케이터 미개입
    case still                                 // quota + 유효 실행 0 — 프레임 0 고정, 타이머 없음
    case animating(MenubarActivityTier)

    /// timerPlan 입력용. `.disabled` / `.still` 은 nil.
    /// 단순 연관값 추출이므로 스텁 대상이 아니다(테스트 대상 로직 아님).
    var tier: MenubarActivityTier? {
        if case .animating(let t) = self { return t }
        return nil
    }
}

enum TimerPlan: Equatable {
    case keep
    case stop
    case restart(MenubarActivityTier)
}

// MARK: - 순수 네임스페이스 (인스턴스 없음 · 상태 없음)

enum MenubarActivityIndicator {

    // MARK: 상수 — S0 실측 결과로 확정 (R2.4). 폴백(R2.9)은 채택하지 않았다.
    nonisolated static let frameCount: Int = 6
    nonisolated static let logoSide: CGFloat = 18
    nonisolated static let amplitude: CGFloat = 1.5
    nonisolated static let canvasSize = NSSize(width: 18, height: 21)
    nonisolated static let restY: CGFloat = 1.5
    nonisolated static let yOffsets: [CGFloat] = [0.0, 1.5, 1.5, 1.0, 0.0, -1.5]
    nonisolated static let defaultHold: TimeInterval = 4.0
    nonisolated static let defaultMaxSustain: TimeInterval = 90.0

    // MARK: 순수 함수 9개

    /// R4.3 — 트리 단위 집계. 평탄화 금지 — 부모 status와 서브의 working 수를 함께 본다.
    nonisolated static func runningCount(in agents: [Agent]) -> Int {
        agents.reduce(0) { acc, agent in
            let subs = agent.subagents.filter { $0.status == .working }.count
            let treeActive = (agent.status == .working) || subs > 0
            return acc + (treeActive ? max(1, subs) : 0)
        }
    }

    /// R4.5 — 트리 어디든(최상위 또는 서브) .working 또는 .waitingApproval 이 하나라도 있으면 true.
    nonisolated static func hasSustainingActivity(in agents: [Agent]) -> Bool {
        agents.contains { agent in
            let sustaining: (AgentStatus) -> Bool = { $0 == .working || $0 == .waitingApproval }
            return sustaining(agent.status) || agent.subagents.contains { sustaining($0.status) }
        }
    }

    /// R6.5 — 파라미터명은 반드시 `effectiveCount` (홀드를 우회한 원시 카운트 주입을 막기 위함).
    nonisolated static func resolve(style: MenubarStyle, effectiveCount: Int) -> MenubarIndicatorState {
        guard style == .quotaSession || style == .quotaSessionAndWeekly else { return .disabled }
        switch effectiveCount {
        case ..<1:  return .still            // 0 및 음수 (R6.2)
        case 1:     return .animating(.slow)
        case 2:     return .animating(.normal)
        default:    return .animating(.fast)
        }
    }

    /// R7.6 — 프레임 인덱스 순환. 음수 tick도 정상 순환한다.
    nonisolated static func frameIndex(tick: Int, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        return ((tick % frameCount) + frameCount) % frameCount
    }

    /// R5.1 — 이중 신호 홀드 판정. 경계는 전부 strict `<`.
    nonisolated static func isActive(
        lastWorkingAt: Date?,
        lastSustainAt: Date?,
        now: Date,
        hold: TimeInterval,
        maxSustain: TimeInterval
    ) -> Bool {
        guard let working = lastWorkingAt else { return false }
        let sustain = lastSustainAt ?? working
        return now.timeIntervalSince(sustain) < hold
            && now.timeIntervalSince(working) < maxSustain
    }

    /// R7.4 — 타이머 계획.
    nonisolated static func timerPlan(
        current: MenubarActivityTier?,
        desired: MenubarActivityTier?
    ) -> TimerPlan {
        switch (current, desired) {
        case (nil, nil):
            return .keep
        case (_, nil):
            return .stop
        case (let c?, let d?) where c == d:
            return .keep
        case (_, let d?):
            return .restart(d)
        }
    }

    /// R2.8 — 로고 사각형.
    nonisolated static func logoRect(frameIndex i: Int) -> NSRect {
        let dy = (i >= 0 && i < yOffsets.count) ? yOffsets[i] : 0
        return NSRect(x: 0, y: restY + dy, width: logoSide, height: logoSide)
    }

    /// R3.1 / R3.2 / R3.8 — handler는 (불변 소스, 목적지 rect)만 캡처한다.
    /// `self` / 가변 상태 / 화면 스케일 / `Date()` 를 handler 안에서 참조하지 않는다.
    nonisolated static func makeFrame(index: Int, source: NSImage) -> NSImage {
        let rect = logoRect(frameIndex: index)
        let image = NSImage(size: canvasSize, flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .high        // R3.8
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)  // R3.5
            return true
        }
        image.isTemplate = false                                          // R3.7 / R2.2
        return image
    }

    /// R3.3 — 프레임 캐시 구성용 루프. `MenubarAnimationController.init`이 호출한다.
    nonisolated static func makeFrames(source: NSImage) -> [NSImage] {
        (0..<frameCount).map { makeFrame(index: $0, source: source) }
    }
}
