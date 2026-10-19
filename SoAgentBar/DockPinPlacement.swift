import CoreGraphics
import Foundation

// SPEC-004 Dock Pin — Dock 창 위치 판정 규칙 (arch §2.4, 커밋 3)
// placement(R6.7), selectDockWindow(preferCached)(R6.4 1–2순위, N9), settle(R6.4 3순위, 주입 IO), 스캔 백오프(R6.6)
// 이 파일은 CoreGraphics / Foundation 만 import 한다 (AC13.1). 창 목록 IO는 클로저로만 받는다.

/// Dock 레이어 창 하나(창 번호 + CG 전역 범위).
struct DockPinWindowInfo: Equatable, Sendable {
    let number: CGWindowID
    let bounds: CGRect
}

enum DockPinWindowSelection: Equatable, Sendable {
    case chosen(DockPinWindowInfo, DockPinPlacement)
    case ambiguous                               // 후보들이 서로 다른 화면 → 다시 읽기
    case none                                    // 후보 0개 → .unknown
}

enum DockPinPlacementRules {
    /// R6.7 — 네 변이 1pt 안에서 같은 화면 → 그 화면. 없으면 겹친 넓이가 가장 큰 화면. 겹침 0 → .unknown
    static func placement(of bounds: CGRect, in displays: [DockPinDisplay]) -> DockPinPlacement {
        if let match = displays.first(where: { edgesMatch(bounds, $0.bounds) }) {
            return .display(match.id)
        }
        var best: (id: CGDirectDisplayID, area: CGFloat)?
        for display in displays {
            let area = overlapArea(bounds, display.bounds)
            if area > (best?.area ?? 0) { best = (display.id, area) }
        }
        return best.map { .display($0.id) } ?? .unknown
    }

    /// R6.4 1–2순위. preferCached == false면 1순위(캐시 번호 우선)를 건너뛴다(N9, AC6.8)
    static func selectDockWindow(candidates: [DockPinWindowInfo], cachedNumber: CGWindowID?,
                                 preferCached: Bool, displays: [DockPinDisplay]) -> DockPinWindowSelection {
        guard let first = candidates.first else { return .none }
        if preferCached, let cachedNumber,
           let cached = candidates.first(where: { $0.number == cachedNumber }) {
            return .chosen(cached, placement(of: cached.bounds, in: displays))
        }
        let firstPlacement = placement(of: first.bounds, in: displays)
        let allSame = candidates.allSatisfy { placement(of: $0.bounds, in: displays) == firstPlacement }
        return allSame ? .chosen(first, firstPlacement) : .ambiguous
    }

    /// R6.4 3순위. read()를 최대 maxReads번(첫 읽기 포함), 사이마다 pause(interval). 순수(IO는 클로저)
    /// .ambiguous일 때만 다시 읽는다. maxReads번 뒤에도 .ambiguous면 그대로 돌려준다(호출자가 .unknown으로 본다)
    static func settle(cachedNumber: CGWindowID?, preferCached: Bool, displays: [DockPinDisplay],
                       maxReads: Int, interval: TimeInterval,
                       read: () -> [DockPinWindowInfo],
                       pause: (TimeInterval) -> Void) -> (selection: DockPinWindowSelection, reads: Int) {
        var reads = 0
        var selection = DockPinWindowSelection.ambiguous
        repeat {
            if reads > 0 { pause(interval) }
            selection = selectDockWindow(candidates: read(), cachedNumber: cachedNumber,
                                         preferCached: preferCached, displays: displays)
            reads += 1
        } while selection == .ambiguous && reads < maxReads
        return (selection, reads)
    }

    /// R6.6 / AC6.5 — 1…7 → 3, 6, 12, 24, 48, 60, 60. 0 이하 → 0
    static func scanBackoff(consecutiveFailures: Int) -> TimeInterval {
        let table = DockPinTuning.scanBackoff
        guard consecutiveFailures > 0, let last = table.last else { return 0 }
        return consecutiveFailures <= table.count ? table[consecutiveFailures - 1] : last
    }

    private static let edgeTolerance: CGFloat = 1

    private static func edgesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= edgeTolerance && abs(a.minY - b.minY) <= edgeTolerance
            && abs(a.maxX - b.maxX) <= edgeTolerance && abs(a.maxY - b.maxY) <= edgeTolerance
    }

    private static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = a.intersection(b)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }
}
