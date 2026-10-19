import CoreGraphics
import Foundation

// SPEC-004 Dock Pin — 디스플레이 맵 (arch §2.2, 커밋 1)
// 활성 디스플레이, 고정 화면, 트리거 줄, 빈 구간·목표점, 피커 선택지, 복원점 (R2, R3, R8.5 예외 1)
// 이 파일은 CoreGraphics / Foundation 만 import 한다 (AC13.1). 모든 함수는 순수 함수다.

struct DockPinAnchor: Equatable, Sendable {
    let display: DockPinDisplay
    /// AC2.3 (리뷰 v2 N14 이름)
    let usingFallbackAnchor: Bool
}

/// 트리거 줄 한 조각. 포함 판정: x ∈ [minX, maxX), y ∈ [minY, maxY] (y 양끝 포함, R3.3).
struct DockPinTriggerRow: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let minX: CGFloat, maxX: CGFloat
    /// minY = D.maxY − 1, maxY = D.maxY
    let minY: CGFloat, maxY: CGFloat

    /// CGRect.contains 금지(반열린 구간)
    func contains(_ p: CGPoint) -> Bool {
        p.x >= minX && p.x < maxX && p.y >= minY && p.y <= maxY
    }
}

struct DockPinSpan: Equatable, Sendable {
    /// [minX, maxX)
    let minX: CGFloat, maxX: CGFloat

    var length: CGFloat { maxX - minX }
}

/// 디스플레이 구성 한 벌의 계산 결과(R3.7 결정적).
struct DockPinLayout: Equatable, Sendable {
    /// 미러 제외 활성 목록
    let displays: [DockPinDisplay]
    let mainID: CGDirectDisplayID
    let anchor: DockPinAnchor
    let rows: [DockPinTriggerRow]
    /// nil = .noFreeEdge (R3.6)
    let relocationTarget: CGPoint?
}

/// S1 — 피커 선택지(언어 무관). 제목 문자열은 DockPinPolicy.choiceTitle이 만든다.
struct DockPinTargetChoice: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case main
        case connected(name: String)
        /// S2: nil → "알 수 없는 모니터 (연결 안 됨)"
        case disconnected(lastName: String?)
    }

    /// "main" 또는 UUID
    let id: String
    let target: DockPinTarget
    let kind: Kind

    /// main → nil, connected → name, disconnected → lastName
    var displayNameToSave: String? {
        switch kind {
        case .main: return nil
        case .connected(let name): return name
        case .disconnected(let lastName): return lastName
        }
    }
}

enum DockPinDisplayMap {
    /// R3.1, AC3.6
    static func activeDisplays(_ all: [DockPinDisplay]) -> [DockPinDisplay] {
        all.filter { $0.mirrorOf == nil }
    }

    /// AC2.1–2.4
    static func resolveAnchor(displays: [DockPinDisplay], target: DockPinTarget,
                              mainID: CGDirectDisplayID) -> DockPinAnchor? {
        if case .display(let uuid) = target,
           let chosen = displays.first(where: { $0.uuid == uuid }) {
            return DockPinAnchor(display: chosen, usingFallbackAnchor: false)
        }
        guard let main = displays.first(where: { $0.id == mainID }) ?? displays.first else { return nil }
        return DockPinAnchor(display: main, usingFallbackAnchor: target != .main)
    }

    /// R3.4/R3.6 공용 — display 아래 끝에서 바로 아래 맞닿은 화면들이 덮는 x 구간을 뺀 나머지
    static func bottomFreeSpans(of display: DockPinDisplay,
                                among displays: [DockPinDisplay]) -> [DockPinSpan] {
        let d = display.bounds
        let covered = displays
            .filter { $0.id != display.id }
            .compactMap { other -> DockPinSpan? in
                let e = other.bounds
                guard abs(e.minY - d.maxY) <= DockPinTuning.adjacencyTolerance else { return nil }
                let lo = max(d.minX, e.minX), hi = min(d.maxX, e.maxX)
                return hi - lo > 0 ? DockPinSpan(minX: lo, maxX: hi) : nil
            }
            .sorted { $0.minX < $1.minX }

        var spans: [DockPinSpan] = []
        var cursor = d.minX
        for c in covered {
            if c.minX > cursor { spans.append(DockPinSpan(minX: cursor, maxX: c.minX)) }
            cursor = max(cursor, c.maxX)
        }
        if d.maxX > cursor { spans.append(DockPinSpan(minX: cursor, maxX: d.maxX)) }
        return spans
    }

    /// R3.3–3.5
    static func triggerRows(displays: [DockPinDisplay], anchorID: CGDirectDisplayID,
                            overrideDisplayID: CGDirectDisplayID?) -> [DockPinTriggerRow] {
        displays
            .filter { $0.id != anchorID && $0.id != overrideDisplayID }
            .flatMap { d in
                bottomFreeSpans(of: d, among: displays).map {
                    DockPinTriggerRow(displayID: d.id, minX: $0.minX, maxX: $0.maxX,
                                      minY: d.bounds.maxY - DockPinTuning.triggerRowHeight,
                                      maxY: d.bounds.maxY)
                }
            }
    }

    /// R3.6
    static func relocationTarget(anchor: DockPinDisplay,
                                 displays: [DockPinDisplay]) -> CGPoint? {
        // 앞쪽(작은 x)이 이기도록 더 길 때만 교체한다
        var longest: DockPinSpan?
        for span in bottomFreeSpans(of: anchor, among: displays) where span.length > (longest?.length ?? 0) {
            longest = span
        }
        guard let best = longest, best.length >= DockPinTuning.minFreeSpan else { return nil }
        return CGPoint(x: (best.minX + best.maxX) / 2, y: anchor.bounds.maxY - 1)
    }

    /// 활성 0대 → nil
    static func layout(allDisplays: [DockPinDisplay], target: DockPinTarget,
                       mainID: CGDirectDisplayID,
                       overrideDisplayID: CGDirectDisplayID?) -> DockPinLayout? {
        let active = activeDisplays(allDisplays)
        guard let anchor = resolveAnchor(displays: active, target: target, mainID: mainID) else { return nil }
        return DockPinLayout(
            displays: active,
            mainID: mainID,
            anchor: anchor,
            rows: triggerRows(displays: active, anchorID: anchor.display.id, overrideDisplayID: overrideDisplayID),
            relocationTarget: relocationTarget(anchor: anchor.display, displays: active))
    }

    /// R2.5, AC2.5
    static func targetChoices(connected: [DockPinDisplay], target: DockPinTarget,
                              savedName: String?) -> [DockPinTargetChoice] {
        var choices = [DockPinTargetChoice(id: "main", target: .main, kind: .main)]
        choices += connected.map {
            DockPinTargetChoice(id: $0.uuid, target: .display(uuid: $0.uuid), kind: .connected(name: $0.name))
        }
        if case .display(let uuid) = target, !connected.contains(where: { $0.uuid == uuid }) {
            choices.append(DockPinTargetChoice(id: uuid, target: target, kind: .disconnected(lastName: savedName)))
        }
        return choices
    }

    /// R8.5 예외 1 (리뷰 v2 N10) — saved가 활성 화면 어디에 있으면 saved, 없으면 다시 정한 고정 화면의
    /// (midX, midY), 활성 화면이 0대면 nil(복원 이벤트 없음). 화면 안 판정은 bounds 반열린 구간.
    /// AC8.9 순수부
    static func restorePoint(saved: CGPoint, allDisplays: [DockPinDisplay], target: DockPinTarget,
                             mainID: CGDirectDisplayID) -> CGPoint? {
        let active = activeDisplays(allDisplays)
        let onActiveDisplay = active.contains {
            let b = $0.bounds
            return saved.x >= b.minX && saved.x < b.maxX && saved.y >= b.minY && saved.y < b.maxY
        }
        if onActiveDisplay { return saved }
        guard let anchor = resolveAnchor(displays: active, target: target, mainID: mainID) else { return nil }
        return CGPoint(x: anchor.display.bounds.midX, y: anchor.display.bounds.midY)
    }
}
