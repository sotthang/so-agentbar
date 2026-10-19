import CoreGraphics
import Foundation

// SPEC-004 Dock Pin — 순수 값 타입 (arch §2.1)
// 이 파일은 CoreGraphics / Foundation 만 import 한다 (AC13.1).

/// R2.1 — 고정 대상. 저장은 UUID 문자열 하나(nil = .main).
enum DockPinTarget: Hashable, Sendable {
    case main
    case display(uuid: String)

    /// nil 또는 "" → .main
    init(storedUUID: String?) {
        if let uuid = storedUUID, !uuid.isEmpty {
            self = .display(uuid: uuid)
        } else {
            self = .main
        }
    }

    /// .main → nil
    var storedUUID: String? {
        switch self {
        case .main: return nil
        case .display(let uuid): return uuid
        }
    }
}

/// R3.2 — 좌표는 전부 CG 전역(CGDisplayBounds). 화면 객체의 frame 좌표는 어디에도 쓰지 않는다(F11).
struct DockPinDisplay: Equatable, Sendable {
    let id: CGDirectDisplayID
    let uuid: String
    let bounds: CGRect
    /// CGDisplayMirrorsDisplay != kCGNullDirectDisplay 이면 그 원본
    let mirrorOf: CGDirectDisplayID?
    /// 표시용(화면 객체의 localizedName). 계산·비교 판정에 쓰지 않는다
    let name: String
}

enum DockPinSide: Equatable, Sendable { case left, right }

enum DockPinOrientation: Equatable, Sendable {
    case bottom, left, right

    /// R4.6 / AC4.5 — nil, "bottom", 알 수 없는 값 → .bottom
    static func parse(_ raw: Any?) -> DockPinOrientation {
        switch raw as? String {
        case "left": return .left
        case "right": return .right
        default: return .bottom
        }
    }
}

enum DockPinInactiveReason: Equatable, Sendable {
    case off, needsPermission, singleDisplay, spacesOff, dockNotBottom(DockPinSide)
}

enum DockPinActivation: Equatable, Sendable {
    case active
    case inactive(DockPinInactiveReason)
}

/// R4.1 — Spaces 상태는 입력값으로만 받는다(F15). 순수 테스트는 화면 API를 직접 읽지 않는다.
struct DockPinActivationInputs: Equatable, Sendable {
    var enabled: Bool
    var hasPermission: Bool
    var activeDisplayCount: Int
    var separateSpaces: Bool
    var orientation: DockPinOrientation
}

/// R6.7 — Dock 창이 있는 화면. (규칙 네임스페이스는 DockPinPlacementRules)
enum DockPinPlacement: Equatable, Sendable {
    case display(CGDirectDisplayID)
    case unknown
}

enum DockPinWaitReason: Equatable, Sendable { case asleep, locked, notOnConsole, buttonDown, userActive }

enum DockPinSkipReason: Equatable, Sendable {
    case inactive, dockNotFound, alreadyPinned, failedUntilEvent, retryScheduled, userOverride, noFreeEdge
}

enum DockPinRelocationDecision: Equatable, Sendable {
    case go
    case wait(DockPinWaitReason)
    case skip(DockPinSkipReason)
}

/// R8.2 (리뷰 v2 C7) — 판정을 일으킨 계기
enum DockPinTrigger: Equatable, Sendable { case event, retryTimer, poll }

/// R8.1 — 단계. 스냅숏 플래그는 이 값에서만 나온다(AC8.10).
enum DockPinRelocationPhase: Equatable, Sendable {
    case idle
    case waiting(DockPinWaitReason)
    case driving
    case verifying
    case failed(attempts: Int)

    /// driving, verifying — AC8.10
    var isRelocating: Bool {
        switch self {
        case .driving, .verifying: return true
        case .idle, .waiting, .failed: return false
        }
    }

    /// driving — AC8.10
    var isDriving: Bool { self == .driving }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// R4.4 tapState 입력
enum DockPinTapState: Equatable, Sendable { case none, running, retrying(attempt: Int) }

/// R4.4 — 반복 타이머 집합의 원소
enum DockPinRepeatingTimer: Hashable, Sendable {
    case permissionPoll, dockPoll, prefsPoll, tapWatchdog, tapRetry
    case freshTrustCheck                        // (r5) R9.6 — 5초 새 프로세스 확인
}

/// 스케줄러 예약 종류. 가짜 스케줄러가 종류별로 센다(AC1.2·AC4.2·AC9.2 등).
enum DockPinTimerKind: Hashable, Sendable {
    case repeating(DockPinRepeatingTimer)
    case displayDebounce, permissionRecheck, sessionSettle, optionCheck
    case waitRecheck, relocationRetry, driveTick, finalScanTimeout, scanRateLimit
    case freshTrustTimeout                      // (r5) R9.6 5번 — 2초 시한
}

/// R11.2 / R11.7 — 사용자에게 보이는 상태(리뷰 v2 N14: .checking 연관값 없음)
enum DockPinStatus: Equatable, Sendable {
    case off
    case needsPermission
    case inactive(DockPinInactiveReason)          // singleDisplay / spacesOff / dockNotBottom 만
    case tapFailed(attempt: Int)                  // R5.9
    case checking
    case dockNotFound
    case noFreeEdge(displayName: String)
    case pinned(displayName: String)
    case waiting(DockPinWaitReason, displayName: String)
    case relocating(displayName: String)
    case movedByUser(displayName: String)
    case failed(attempts: Int)
}

struct DockPinSessionState: Equatable, Sendable {
    var asleep = false
    var locked = false
    var onConsole = true
}

/// (r6) R9.6 7번 — 새 프로세스 확인을 시작한 이유(로그·테스트 구분용). 주기 / 7-1 셋째 행 / R9.5 N21
enum DockPinFreshCheckOrigin: Equatable, Sendable { case periodic, latchDoubt, notifyAdvance }

/// R13.3 — 조정 숫자. 각 상수 옆 주석: 단위 — 근거(SPEC "조정 숫자" 표의 근거 열 그대로).
enum DockPinTuning {
    static let triggerRowHeight: CGFloat = 1                    // pt — 참고 실측: 맨 아래 1px 줄만 트리거
    static let adjacencyTolerance: CGFloat = 0.5                // pt — 화면 맞닿음 판정
    static let minFreeSpan: CGFloat = 8                         // pt — 빈 구간이 너무 짧으면 되돌리기가 불안정 (B5)
    static let displayDebounce: TimeInterval = 0.5              // s — 디스플레이 변경은 몰려서 온다
    static let tapWatchdogInterval: TimeInterval = 2            // s — 탭 꺼짐 안전망
    static let tapRetryDelays: [TimeInterval] = [1, 2, 5, 10]   // s — B2
    static let tapRetryTail: TimeInterval = 30                  // s — B2 (이후 30 s)
    static let permissionPollInterval: TimeInterval = 1         // s — 권한 감시(R4.4 표의 상태에서만)
    static let permissionNotifyRecheckDelays: [TimeInterval] = [1.0, 3.0] // s — (r5) R9.5, F22 (알림 뒤 +1초·+3초)
    static let freshTrustCheckInterval: TimeInterval = 5              // s — (r5) R9.6, F20 (약 65ms/회)
    static let freshTrustCheckTimeout: TimeInterval = 2               // s — (r5) R9.6 5번 (초과 → 결과 nil)
    static let dockProbeTimeout: Float = 0.25                         // s — (r6) R9.1 2번, C13. AXUIElementSetMessagingTimeout 인자(Float). 측정 없음(D5, A24)
    static let dockPollInterval: TimeInterval = 3               // s — 평소 위치 확인
    static let prefsPollInterval: TimeInterval = 3              // s — 비활성(방향) 중 설정·권한 재확인
    static let optionOverrideWindow: TimeInterval = 10          // s — B1 (확인 주기 3초의 3배 이상)
    static let optionCheckDelays: [TimeInterval] = [0.5, 1.0, 2.0] // s — B1 즉시 확인
    static let settleRetryInterval: TimeInterval = 0.020        // s — DockClone 0.10–0.25 s, B6 상한
    static let settleMaxReads = 50                              // 회 — DockClone 0.10–0.25 s, B6 상한
    static let scanBackoff: [TimeInterval] = [3, 6, 12, 24, 48, 60] // s — B6
    static let eventScanMinInterval: TimeInterval = 1           // s — 이벤트 계기 조회 상한(R6.6)
    static let driveInterval: TimeInterval = 0.016              // s — 참고 실측 방법
    static let approachHeight: CGFloat = 40                     // pt — 참고 실측(위에서 다가가기)
    static let approachStep: CGFloat = 3                        // pt — 참고 실측. 마지막 걸음은 목표 줄로 맞춤
    static let verifyEveryTicks = 6                             // 틱(약 100 ms) — 매 틱 조회는 과함
    static let relocationTimeout: TimeInterval = 2.0            // s — 실측 0.33–1.00 s에 여유. 지나면 마지막 전체 조회(R8.3-5)
    static let finalScanTimeout: TimeInterval = 1.2             // s — R6.4 재읽기 50회 × 20ms = 1.0 s + 여유 (리뷰 v2 N9)
    static let relocationDeadlineMargin: TimeInterval = 0.5     // s — (r6.2) VULN-002. 틱 지연·확인 조회 여유
    /// (r6.2) VULN-002 — 스냅숏 시한 = 되돌리기 시작 시각 + 이 값. 다가가기(15점 × 16 ms = 0.24 s)
    /// + relocationTimeout + finalScanTimeout + 여유 ≈ 3.94 s. 메인이 멈춰도 입력 차단은 이 상한을 넘지 않는다
    static let relocationGuardWindow: TimeInterval =
        Double(DockPinDrivePath.approach(to: .zero).count) * driveInterval
        + relocationTimeout + finalScanTimeout + relocationDeadlineMargin
    static let optionPassSlots = 32                             // 칸 — R7.2, 활성 디스플레이 목록 상한과 같은 수(리뷰 v2 N11). SIMD32 폭과 같아야 한다
    static let suppressibleButtonCount = 32                     // 개(0…31) — 제스처 억제 UInt32 비트마스크(R5.5)
    static let idleBeforeRelocation: TimeInterval = 0.5         // s — P3
    static let waitRecheckInterval: TimeInterval = 0.5          // s — .wait 재판정
    static let retryDelays: [TimeInterval] = [1, 3, 10]         // s — 참고 구현과 같음
    static let maxAttempts = 4                                  // 회 — 참고 구현과 같음
    static let settleAfterSessionChange: TimeInterval = 1       // s — 깨어남·잠금 해제 직후
    static let minEventTriggerInterval: TimeInterval = 10       // s — (r6.3) VULN-003. 잠금 해제 계기 상한(위조 알림이 백오프·4회 상한을 무력화하지 못하게)
    static let eventMarker: Int64 = 0x534F_4450                 // 'SODP' — 앱이 보낸 이벤트 표식(F8)
    static let tapStartTimeout: TimeInterval = 1.0              // s — Architect 추가: 탭 스레드 시작 대기 상한(arch §2.7)
    static let tapStopTimeout: TimeInterval = 1.0               // s — Architect 추가: 탭 스레드 종료 대기 상한
}
