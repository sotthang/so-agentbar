import Foundation

// MARK: - 중간 데이터 모델

/// parseUsageSummaryResponse 결과 — usage-summary 엔드포인트 응답 파싱 모델.
struct CursorUsageSummaryResponse: Equatable {
    var totalPercentUsed: Double     // individualUsage.plan.totalPercentUsed
    var billingCycleEnd: Date?       // billingCycleEnd (리셋일)
    var membershipType: String?      // "free" / "pro" 등
}

/// 폴백 분기용 에러 타입 (메시지는 사용자 표시용 — 토큰/식별자 미포함, R7.2)
enum CursorFetchError: Equatable, Error {
    case http(Int)        // 비정상 상태코드 (204/403/4xx/5xx)
    case parse            // 응답 파싱 실패
    case transport        // 네트워크 전송 실패
}

// MARK: - 순수 함수 네임스페이스 (TDD GREEN)

/// Cursor 사용량 조회 관련 순수 함수 집합.
/// nonisolated static 함수들은 모두 단위 테스트 가능하다 (NFR2).
enum CursorUsage {

    // MARK: 상수

    /// 기본 폴링 간격: 5분 (R1.3, Q3 확정)
    static let defaultPollInterval: TimeInterval = 300
    /// Cursor API 호스트 (www → cursor.com 308 회피, 주의1)
    static let usageHost = "cursor.com"
    /// 인증 쿠키 이름
    static let cookieName = "WorkosCursorSessionToken"

    // MARK: R3.1 — JWT sub(userId) 추출

    /// accessToken(JWT) → payload.sub 클레임 문자열 (예: "google-oauth2|user_01J...") 추출 (R3.1, AC1).
    /// 파이프라인: JWT 3-segment 분리 → 2번째 segment(payload) base64url 디코딩 → JSON 파싱 → "sub" 필드.
    /// 형식 오류/세그먼트 부족/sub 부재 → nil (크래시 없음).
    /// 서명 검증 없음 (토큰은 읽기 전용이고 소유자 자신이 사용, 중간자 공격 리스크 없음).
    /// 보안: 반환값(sub)은 절대 로그/에러/UI에 노출하지 않음 (R7.2, AC10).
    nonisolated static func parseUserId(fromJWT token: String) -> String? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 3 else { return nil }

        // 2번째 세그먼트(index 1) = payload
        let payloadSegment = String(segments[1])

        // base64url → base64 변환 (패딩 추가)
        var base64 = payloadSegment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String else {
            return nil
        }

        return sub
    }

    // MARK: R3.2 — 쿠키 값 생성

    /// "<sub>::<accessToken>" 형식. (인증: Cookie 방식만 동작 — Bearer는 204)
    nonisolated static func buildCookieValue(sub: String, accessToken: String) -> String {
        return "\(sub)::\(accessToken)"
    }

    // MARK: R3.3 — usage-summary 요청 생성

    /// GET https://cursor.com/api/usage-summary?user=<userId> URLRequest 생성.
    /// 헤더: Cookie: WorkosCursorSessionToken=<cookieValue> (쿠키 방식만 동작, Bearer 헤더는 204 응답).
    /// userId는 URLComponents의 queryItems로 percent-encoding 자동 처리.
    /// 보안: GET 읽기 전용만 사용, 토큰/쿠키는 cursor.com 도메인에만 전송 (R7.1, R7.3).
    nonisolated static func buildUsageRequest(userId: String, cookie: String) -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = usageHost
        components.path = "/api/usage-summary"
        components.queryItems = [URLQueryItem(name: "user", value: userId)]

        let url = components.url!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("\(cookieName)=\(cookie)", forHTTPHeaderField: "Cookie")
        return request
    }

    // MARK: R3.4 — usage-summary 응답 파싱 → 중간 모델

    /// cursor.com/api/usage-summary JSON 응답 → CursorUsageSummaryResponse 파싱.
    /// JSON 구조:
    ///   {
    ///     "billingCycleEnd": "2026-06-20T02:01:11.666Z",
    ///     "membershipType": "free",
    ///     "individualUsage": {
    ///       "plan": {
    ///         "totalPercentUsed": 6
    ///       }
    ///     }
    ///   }
    /// totalPercentUsed 필드 미존재 또는 JSON 형식 오류 → nil (크래시 없음).
    nonisolated static func parseUsageSummaryResponse(from data: Data) -> CursorUsageSummaryResponse? {
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // individualUsage.plan.totalPercentUsed 추출
        guard let individualUsage = json["individualUsage"] as? [String: Any],
              let plan = individualUsage["plan"] as? [String: Any] else {
            return nil
        }

        // totalPercentUsed는 Int 또는 Double로 올 수 있음
        let totalPercentUsed: Double
        if let v = plan["totalPercentUsed"] as? Double {
            totalPercentUsed = v
        } else if let v = plan["totalPercentUsed"] as? Int {
            totalPercentUsed = Double(v)
        } else {
            return nil
        }

        // billingCycleEnd 파싱 (ISO8601)
        var billingCycleEnd: Date?
        if let endStr = json["billingCycleEnd"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: endStr) {
                billingCycleEnd = date
            } else {
                let formatter2 = ISO8601DateFormatter()
                billingCycleEnd = formatter2.date(from: endStr)
            }
        }

        let membershipType = json["membershipType"] as? String

        return CursorUsageSummaryResponse(
            totalPercentUsed: totalPercentUsed,
            billingCycleEnd: billingCycleEnd,
            membershipType: membershipType
        )
    }

    // MARK: R3.5 — ProviderUsage 매핑 (state 분기, 퍼센트 모델)

    /// 토큰 부재/파싱 오류/네트워크 실패 등 경우의 수별로 ProviderUsage(state: .needsSetup / .error / .data)로 매핑.
    /// - tokenPresent=false → .needsSetup ("Cursor 로그인 필요", R6.1, AC6)
    /// - fetchError != nil → .error (메시지: "Cursor 사용량을 불러오지 못했습니다" 등, 토큰/userId 미포함 R7.2, AC10)
    /// - response 정상 → .data + CursorPercentInfo(totalPercentUsed, billingCycleEnd, membershipType)
    nonisolated static func toProviderUsage(
        summaryResponse: CursorUsageSummaryResponse?,
        tokenPresent: Bool,
        fetchError: CursorFetchError?,
        now: Date
    ) -> ProviderUsage {
        // 토큰 없음 → needsSetup
        guard tokenPresent else {
            return ProviderUsage(id: .cursor, state: .needsSetup, isEstimate: false)
        }

        // 에러 → error (메시지에 민감값 미포함, R7.2, AC10)
        if let error = fetchError {
            let message: String
            switch error {
            case .http:
                // HTTP 상태코드도 노출하지 않음 (일반 문구만)
                message = "Cursor 사용량을 불러오지 못했습니다"
            case .parse:
                message = "Cursor 응답을 처리할 수 없습니다"
            case .transport:
                message = "Cursor 서버에 연결할 수 없습니다"
            }
            return ProviderUsage(id: .cursor, state: .error(message), isEstimate: false)
        }

        // 응답 없음 → 방어적 처리
        guard let response = summaryResponse else {
            return ProviderUsage(id: .cursor, state: .error("Cursor 사용량을 불러오지 못했습니다"), isEstimate: false)
        }

        // 정상 → data + CursorPercentInfo
        let percentInfo = CursorPercentInfo(
            totalPercentUsed: response.totalPercentUsed,
            billingCycleEnd: response.billingCycleEnd,
            membershipType: response.membershipType
        )

        return ProviderUsage(
            id: .cursor,
            state: .data,
            isEstimate: false,  // 정확치
            quota: nil,
            estimate: nil,      // 비용 없음 (R4.3)
            cursorPercent: percentInfo
        )
    }

}

// MARK: - CursorUsageProvider (@MainActor)

/// Cursor 사용량 프로바이더 (SPEC-002, 퍼센트 쿼터 방식).
/// 로컬 Cursor 세션 토큰(state.vscdb)을 읽어 cursor.com/api/usage-summary를 조회하여
/// 퍼센트 사용량(totalPercentUsed)을 추적한다.
/// - 데이터 소스: ~/Library/Application Support/Cursor/.../state.vscdb (SQLite 읽기 전용)
/// - API: GET https://cursor.com/api/usage-summary?user=<userId> (WorkosCursorSessionToken 쿠키 방식)
/// - 사용자 메트릭: totalPercentUsed (%), billingCycleEnd (리셋일), membershipType (보조)
/// - 비용: Cursor가 단가를 공개하지 않으므로 "비용 정보 없음"으로 고정 표시
/// - 경고: 비공식 엔드포인트 사용 — Cursor 업데이트로 API 변경 가능성 있음.
/// SQLite 읽기는 CursorTokenStore (별도 파일)에 위임한다.
@MainActor
final class CursorUsageProvider: UsageProviderProtocol {
    nonisolated var id: ProviderID { .cursor }

    var onUsageChanged: ((ProviderUsage) -> Void)?

    private(set) var currentUsage: ProviderUsage

    private let databaseURL: URL
    private let session: URLSession
    private var pollingTimer: Timer?
    private var pollInterval: TimeInterval = CursorUsage.defaultPollInterval

    init(
        databaseURL: URL = CursorTokenStore.defaultDatabaseURL(),
        session: URLSession = .shared
    ) {
        self.databaseURL = databaseURL
        self.session = session
        self.currentUsage = ProviderUsage(id: .cursor, state: .loading, isEstimate: false)
    }

    func start() {
        // 즉시 1회 fetch
        Task { await fetch() }
        // 폴링 타이머 시작
        scheduleTimer(interval: pollInterval)
    }

    func stop() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    func updatePollInterval(_ interval: Double) {
        self.pollInterval = interval
        // 타이머가 실행 중인 경우에만 재시작 (stop 상태면 start 호출 전까지 유지)
        if pollingTimer != nil {
            scheduleTimer(interval: interval)
        }
    }

    // MARK: - 내부 타이머 헬퍼

    /// 기존 타이머를 무효화하고 새 간격으로 재시작. (start/updatePollInterval 공통 경로)
    private func scheduleTimer(interval: TimeInterval) {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.fetch() }
        }
    }

    /// Cursor 사용량을 폴링 간격(기본 5분)으로 조회. UI 스레드 블로킹 방지를 위해 SQLite/네트워크 I/O는 백그라운드 task에서 실행.
    /// 파이프라인:
    /// 1. state.vscdb에서 accessToken 읽기 (SQLite 읽기 전용, R2)
    /// 2. JWT sub 클레임으로 userId 추출 (R3.1)
    /// 3. cursor.com/api/usage-summary 호출 (쿠키 인증, R3.3)
    /// 4. 응답 파싱 → CursorPercentInfo 매핑 (R3.4, R3.5)
    /// 5. onUsageChanged 콜백 발행 (UsageCoordinator 구독, 메인 액터)
    /// 토큰 부재/파싱 실패/HTTP 오류 등은 .needsSetup/.error 상태로 폴백.
    /// 에러 메시지는 민감값(토큰/userId) 미포함 (R7.2, AC10).
    func fetch() async {
        // 1) 백그라운드에서 SQLite 토큰 읽기 (R2.3, NFR4 — 메인 액터 블로킹 금지)
        let dbURL = databaseURL
        let token = await Task.detached(priority: .utility) {
            CursorTokenStore.loadAccessToken(databaseURL: dbURL)
        }.value

        // 2) 토큰 없음 → needsSetup
        guard let accessToken = token, !accessToken.isEmpty else {
            let usage = CursorUsage.toProviderUsage(
                summaryResponse: nil,
                tokenPresent: false,
                fetchError: nil,
                now: Date()
            )
            publish(usage)
            return
        }

        // 3) JWT에서 userId(sub) 파싱
        guard let sub = CursorUsage.parseUserId(fromJWT: accessToken) else {
            let usage = ProviderUsage(id: .cursor, state: .needsSetup, isEstimate: false)
            publish(usage)
            return
        }

        // 4) 쿠키 + 요청 생성 (usage-summary 엔드포인트)
        let cookie = CursorUsage.buildCookieValue(sub: sub, accessToken: accessToken)
        let request = CursorUsage.buildUsageRequest(userId: sub, cookie: cookie)

        // 5) 네트워크 요청 (백그라운드, NFR4)
        let result = await Task.detached(priority: .utility) { [session = self.session] () -> Result<Data, CursorFetchError> in
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    return .failure(.transport)
                }
                guard httpResponse.statusCode == 200 else {
                    return .failure(.http(httpResponse.statusCode))
                }
                return .success(data)
            } catch {
                return .failure(.transport)
            }
        }.value

        // 6) 결과 처리 — usage-summary 파싱
        let fetchResult: Result<CursorUsageSummaryResponse, CursorFetchError> = result.flatMap { data in
            guard let response = CursorUsage.parseUsageSummaryResponse(from: data) else {
                return .failure(.parse)
            }
            return .success(response)
        }

        let usage: ProviderUsage
        switch fetchResult {
        case .failure(let fetchError):
            usage = CursorUsage.toProviderUsage(
                summaryResponse: nil,
                tokenPresent: true,
                fetchError: fetchError,
                now: Date()
            )
        case .success(let response):
            usage = CursorUsage.toProviderUsage(
                summaryResponse: response,
                tokenPresent: true,
                fetchError: nil,
                now: Date()
            )
        }

        // 7) 메인 액터에서 발행
        publish(usage)
    }

    // MARK: - 내부

    private func publish(_ usage: ProviderUsage) {
        currentUsage = usage
        onUsageChanged?(usage)
    }
}
