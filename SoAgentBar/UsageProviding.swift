import Foundation

// MARK: - 식별자

enum ProviderID: String, CaseIterable, Codable {
    case claude
    case codex
    case gemini

    /// 로컬라이즈 불필요한 고유명 (design.md displayName 계약)
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .gemini: return "Gemini"
        }
    }
}

// MARK: - 상태 머신 (design.md State Machine 5개 상태)

enum ProviderState: Equatable {
    case loading            // 첫 fetch 진행 중, 표시 데이터 없음
    case needsSetup         // 로그인/설정 필요 (Claude=login, Codex/Gemini=데이터 없음)
    case error(String)      // fetch 실패, 표시 데이터 없음
    case data               // 사용량 표시 가능
    case disabledFallback   // Gemini 데이터 소스 미지원 (R2.4)
}

// MARK: - 정확 쿼터 (Claude 계열)

struct QuotaInfo: Equatable {
    var sessionUtilization: Double      // 0-100
    var sessionResetsAt: Date?
    var weeklyUtilization: Double       // 0-100
    var weeklyResetsAt: Date?
    var planName: String?
    var extra: ExtraInfo?
}

struct ExtraInfo: Equatable {
    var enabled: Bool
    var spentDollars: Double
    var limitDollars: Double
}

// MARK: - 추정치 (Codex/Gemini 계열)

/// Codex/Gemini 등 로컬 로그 기반 사용량 추정치.
/// - totalTokens: 24시간 윈도우 내 집계된 토큰 수
/// - costDollars: nil이면 비용 추정 불가 (단가 미상/0 모델)
/// - windowHours: 24 (고정, R1.4)
struct EstimateInfo: Equatable {
    var totalTokens: Int
    var costDollars: Double?            // nil + totalTokens>0 → "비용 추정 불가" (C3)
    var windowHours: Int               // = 24 (R1.4)

    /// 비용 추정 불가 판별 (design.md 인계 메모: 별도 boolean 불필요)
    var isCostUnavailable: Bool { costDollars == nil && totalTokens > 0 }
}

// MARK: - 통합 사용량 모델 (R0.2)

/// 모든 프로바이더(Claude, Codex, Gemini)의 사용량을 표현하는 통합 모델.
/// - Claude: 정확한 OAuth 쿼터 (sessionUtilization, weeklyUtilization %)
/// - Codex/Gemini: 로컬 로그 기반 추정치 (토큰/비용)
/// 각 state별로 UI가 다른 섹션을 렌더한다.
struct ProviderUsage: Equatable {
    var id: ProviderID
    var state: ProviderState
    var isEstimate: Bool               // Claude=false, Codex/Gemini=true (R1.3, AC-1.3)
    var quota: QuotaInfo?              // state==.data && !isEstimate
    var estimate: EstimateInfo?        // state==.data && isEstimate

    var displayName: String { id.displayName }

    /// 초기/로딩 스냅샷 팩토리
    static func loading(_ id: ProviderID, isEstimate: Bool) -> ProviderUsage {
        ProviderUsage(id: id, state: .loading, isEstimate: isEstimate,
                      quota: nil, estimate: nil)
    }
}

// MARK: - 프로바이더 계약 (R0.1)

/// 모든 사용량 프로바이더(Claude, Codex, Gemini)가 노출하는 공통 계약.
/// UsageCoordinator는 이 프로토콜만 알고 프로바이더를 합성하여 장애 격리(NFR4)를 구현한다.
/// 각 프로바이더는 고유한 데이터 소스(OAuth API, 로컬 로그 등)를 가지나, 이 인터페이스로 통합된다.
@MainActor
protocol UsageProviderProtocol: AnyObject {
    var id: ProviderID { get }

    /// 새 ProviderUsage 스냅샷이 준비될 때마다 메인 액터에서 호출됨.
    /// UsageCoordinator가 이 콜백을 구독하여 UI 업데이트 트리거.
    var onUsageChanged: ((ProviderUsage) -> Void)? { get set }

    /// 현재 마지막 스냅샷 (코디네이터 초기화 및 팝오버 렌더용).
    var currentUsage: ProviderUsage { get }

    /// 폴링/모니터링 시작
    func start()
    /// 폴링/모니터링 중지
    func stop()
    /// 즉시 한 번 fetch (사용자 수동 새로고침)
    func fetch() async
    /// 폴링 간격 업데이트 (사용자 설정 변경 시)
    func updatePollInterval(_ interval: Double)
}
