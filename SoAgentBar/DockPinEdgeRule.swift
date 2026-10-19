import CoreGraphics
import Foundation

// SPEC-004 Dock Pin — 탭 판정 규칙 (arch §2.3)
// 스냅숏, 판정 decide, 제스처 억제, Option 고정 칸, 신호 상자, 탭 수명 (R5, R7.2)
// 이 파일은 CoreGraphics / Foundation 만 import 한다 (AC13.1). 모든 타입은 순수 값 타입이다.
//
// 탭 경로(decide, 억제, 신호 상자 record, 칸 record)는 Dictionary·Set·가변 Array에 쓰지 않는다(N11).

/// R5.3 — 탭 스레드가 읽는 유일한 판정 입력.
struct DockPinGuardSnapshot: Equatable, Sendable {
    var rows: [DockPinTriggerRow] = []
    var isRelocating = false
    var isDriving = false
    var marker: Int64 = DockPinTuning.eventMarker
    /// VULN-002 — 되돌리기 시한(탭 시계 uptime, s). now > 시한이면 isRelocating·isDriving을 거짓으로 본다.
    /// 메인이 멈춰 스냅숏을 못 내려도 사용자 입력을 시한 뒤에는 버리지 않는다. nil = 시한 없음(옛 동작)
    var relocationDeadline: TimeInterval?
}

enum DockPinTapSignal: Equatable, Sendable {
    case userActivity
    case optionPass(CGDirectDisplayID)
}

/// R5.4 (아키 9-1) — struct + static 멤버. V2에서 컴파일 확인.
struct DockPinTapDecision: Equatable, Sendable {
    enum Action: Equatable, Sendable { case pass, drop }
    let action: Action
    let signal: DockPinTapSignal?

    static let pass = DockPinTapDecision(action: .pass, signal: nil)
    static let drop = DockPinTapDecision(action: .drop, signal: nil)

    static func pass(signal: DockPinTapSignal) -> DockPinTapDecision {
        DockPinTapDecision(action: .pass, signal: signal)
    }

    static func drop(signal: DockPinTapSignal) -> DockPinTapDecision {
        DockPinTapDecision(action: .drop, signal: signal)
    }
}

/// R5.5 — UInt32 비트마스크(버튼 0…31). 힙 컬렉션 없음(N11).
struct DockPinGestureSuppression: Equatable, Sendable {
    private(set) var mask: UInt32 = 0

    /// 0…31 이면 그 비트, 밖이면 nil
    private static func bit(_ button: Int64) -> UInt32? {
        guard button >= 0, button < Int64(DockPinTuning.suppressibleButtonCount) else { return nil }
        return UInt32(1) << UInt32(button)
    }

    /// 0…31 밖이면 false
    func contains(button: Int64) -> Bool {
        guard let bit = Self.bit(button) else { return false }
        return mask & bit != 0
    }

    /// 0…31 밖이면 무시
    mutating func insert(button: Int64) {
        guard let bit = Self.bit(button) else { return }
        mask |= bit
    }

    mutating func remove(button: Int64) {
        guard let bit = Self.bit(button) else { return }
        mask &= ~bit
    }

    mutating func reset() {
        mask = 0
    }
}

enum DockPinEdgeRule {
    /// mouseMoved, left/right/otherMouseDragged
    static let blockableTypes: [CGEventType] = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    ]
    /// left/right/other Down·Up, scrollWheel
    static let observedTypes: [CGEventType] = [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .scrollWheel,
    ]
    /// 키보드 없음(R5.2)
    static let eventMask: CGEventMask =
        (blockableTypes + observedTypes).reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }

    /// R5.4 표 1–9행 그대로(1a행 포함). 버튼 번호 > 31이면 1a·2·3행을 건너뛰고 5행.
    /// now = 탭 시계(uptime). 스냅숏 시한이 지났으면(VULN-002) 되돌리는 중이 아닌 것으로 판정하고,
    /// 억제된 버튼의 Dragged·Up은 통과시키며 억제를 푼다.
    /// (r6.6) NEW-1 — 시한 뒤에도 원래 스냅숏 기준으로 신호를 냈을 사용자 입력이면, 신호 칸이 빈 판정에
    /// .userActivity를 싣는다(버리기는 늘리지 않는다). 메인이 늦어 아직 이동을 보내는 실행기가 멈추게 한다(R8.6).
    static func decide(type: CGEventType, location: CGPoint, flags: CGEventFlags,
                       userData: Int64, buttonNumber: Int64,
                       snapshot: DockPinGuardSnapshot, now: TimeInterval,
                       suppression: inout DockPinGestureSuppression) -> DockPinTapDecision {
        // 1행 — 앱이 보낸 이벤트
        if userData == snapshot.marker { return .pass }

        // VULN-002 — 할당 없는 비교
        var expired = false
        if let deadline = snapshot.relocationDeadline, now > deadline { expired = true }
        let decision = decideUser(type: type, location: location, flags: flags, buttonNumber: buttonNumber,
                                  snapshot: snapshot, expired: expired, suppression: &suppression)
        if expired, decision.signal == nil, wouldSignalUserActivity(type: type, snapshot: snapshot) {
            return DockPinTapDecision(action: decision.action, signal: .userActivity)
        }
        return decision
    }

    /// NEW-1 — 시한 전이었다면 .userActivity를 냈을 종류인가(버튼·스크롤은 driving, 이동·드래그는 relocating)
    private static func wouldSignalUserActivity(type: CGEventType, snapshot: DockPinGuardSnapshot) -> Bool {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseUp, .rightMouseUp, .otherMouseUp, .scrollWheel:
            return snapshot.isDriving
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return snapshot.isRelocating
        default:
            return false
        }
    }

    /// 2–9행(사용자 이벤트)
    private static func decideUser(type: CGEventType, location: CGPoint, flags: CGEventFlags, buttonNumber: Int64,
                                   snapshot: DockPinGuardSnapshot, expired: Bool,
                                   suppression: inout DockPinGestureSuppression) -> DockPinTapDecision {
        let driving = snapshot.isDriving && !expired
        let relocating = snapshot.isRelocating && !expired
        // contains/insert 는 0…31 밖이면 false/무시 → 31 초과 버튼은 1a·2·3행을 건너뛴다
        let suppressible = buttonNumber >= 0 && buttonNumber < Int64(DockPinTuning.suppressibleButtonCount)

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if suppressible {
                if driving {
                    // 2행
                    suppression.insert(button: buttonNumber)
                    return .drop(signal: .userActivity)
                }
                // 1a행 — 놓친 Up으로 남은 억제를 푼다
                suppression.remove(button: buttonNumber)
            }
            return observed(driving: driving)

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            // 3행 (Up)
            if suppression.contains(button: buttonNumber) {
                suppression.remove(button: buttonNumber)
                if !expired { return suppressedDrop(driving: driving) }
            }
            return observed(driving: driving)

        case .scrollWheel:
            // 4행
            if driving { return .drop(signal: .userActivity) }
            return observed(driving: driving)

        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            // 3행 (Dragged)
            if suppression.contains(button: buttonNumber) {
                if !expired { return suppressedDrop(driving: driving) }
                suppression.remove(button: buttonNumber)    // VULN-002 — 시한 뒤에는 남은 제스처를 통과
            }
            return moveOrDrag(location: location, flags: flags, rows: snapshot.rows, relocating: relocating)

        case .mouseMoved:
            return moveOrDrag(location: location, flags: flags, rows: snapshot.rows, relocating: relocating)

        default:
            // 9행
            return .pass
        }
    }

    /// 3행 결과
    private static func suppressedDrop(driving: Bool) -> DockPinTapDecision {
        driving ? .drop(signal: .userActivity) : .drop
    }

    /// 5행 — 그 밖의 관찰용 이벤트
    private static func observed(driving: Bool) -> DockPinTapDecision {
        driving ? .pass(signal: .userActivity) : .pass
    }

    /// 6–9행 — 이동·드래그
    private static func moveOrDrag(location: CGPoint, flags: CGEventFlags,
                                   rows: [DockPinTriggerRow], relocating: Bool) -> DockPinTapDecision {
        let row = triggerRow(containing: location, in: rows)
        if relocating {
            return row == nil ? .pass(signal: .userActivity) : .drop(signal: .userActivity)   // 6행
        }
        guard let row else { return .pass }                                                   // 9행
        if flags.contains(.maskAlternate) { return .pass(signal: .optionPass(row.displayID)) } // 7행
        return .drop                                                                          // 8행
    }

    /// 읽기만 한다(할당 없음)
    private static func triggerRow(containing p: CGPoint, in rows: [DockPinTriggerRow]) -> DockPinTriggerRow? {
        for row in rows where row.contains(p) { return row }
        return nil
    }
}

/// R7.2 (N11) — 미리 할당된 32칸. SIMD는 인라인 저장이라 쓰기에 힙 할당·CoW가 없다(V2).
struct DockPinOptionPassSlots: Equatable, Sendable {
    /// 0 = 빈 칸 (kCGNullDirectDisplay)
    private(set) var ids: SIMD32<UInt32>
    /// uptime
    private(set) var times: SIMD32<Double>

    init() {
        ids = SIMD32<UInt32>()
        times = SIMD32<Double>()
    }

    /// 같은 id 칸 → 덮어쓰기, 아니면 첫 빈 칸, 없으면 times가 가장 작은 칸(동률은 낮은 인덱스)
    mutating func record(_ id: CGDirectDisplayID, at uptime: TimeInterval) {
        guard id != 0 else { return }   // 0은 빈 칸 표식
        var firstEmpty = -1
        var oldest = 0
        for i in 0..<ids.scalarCount {
            if ids[i] == id {
                times[i] = uptime
                return
            }
            if ids[i] == 0 {
                if firstEmpty < 0 { firstEmpty = i }
            } else if times[i] < times[oldest] {
                oldest = i
            }
        }
        let slot = firstEmpty >= 0 ? firstEmpty : oldest
        ids[slot] = id
        times[slot] = uptime
    }

    /// AC5.14 "칸 수 그대로" 검증용
    var occupiedCount: Int {
        var count = 0
        for i in 0..<ids.scalarCount where ids[i] != 0 { count += 1 }
        return count
    }

    /// 메인 전용(할당 허용). 빈 칸 제외
    func toDictionary() -> [CGDirectDisplayID: TimeInterval] {
        var result: [CGDirectDisplayID: TimeInterval] = [:]
        for i in 0..<ids.scalarCount where ids[i] != 0 { result[ids[i]] = times[i] }
        return result
    }
}

/// R5.6 — 콜백이 쌓고 메인이 비우는 상자. 콜백 쪽 메서드는 할당하지 않는다.
struct DockPinSignalBox: Equatable, Sendable {
    /// 단조 증가(&+=)
    private(set) var userActivityCount: UInt64 = 0
    private(set) var optionPasses = DockPinOptionPassSlots()
    private(set) var notifyPending = false

    /// .userActivity → 카운터만 올리고 false. .optionPass → 칸 기록 후, 대기 중이 아니면 플래그를 켜고 true
    mutating func record(_ signal: DockPinTapSignal, at uptime: TimeInterval) -> Bool {
        switch signal {
        case .userActivity:
            userActivityCount &+= 1
            return false
        case .optionPass(let id):
            optionPasses.record(id, at: uptime)
            if notifyPending { return false }
            notifyPending = true
            return true
        }
    }

    /// 메인에서 호출. 대기 플래그를 내린다. 칸은 지우지 않는다(화면별 최신값이라 합치기가 멱등)
    mutating func drain() -> DockPinTapSignals {
        let had = notifyPending
        notifyPending = false
        return DockPinTapSignals(userActivityCount: userActivityCount,
                                 optionPasses: optionPasses.toDictionary(),
                                 hadOptionPass: had)
    }
}

struct DockPinTapSignals: Equatable, Sendable {
    let userActivityCount: UInt64
    let optionPasses: [CGDirectDisplayID: TimeInterval]
    /// drain 직전 notifyPending
    let hadOptionPass: Bool
}

/// R5.7 / AC5.12 — 재활성화 판단. 실제 탭은 CF 핸들과 같은 잠금 안에 둔다.
struct DockPinTapLifecycle: Equatable, Sendable {
    private(set) var isArmed = false
    private(set) var isStopping = false
    private(set) var reenableCount = 0

    /// isArmed = true, isStopping = false
    mutating func arm() {
        isArmed = true
        isStopping = false
    }

    /// isStopping = true, isArmed = false
    mutating func beginStop() {
        isStopping = true
        isArmed = false
    }

    /// isArmed && !isStopping 이면 count += 1, true
    mutating func handleDisabledEvent() -> Bool {
        guard isArmed, !isStopping else { return false }
        reenableCount += 1
        return true
    }
}
