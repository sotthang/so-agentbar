import Foundation
import UserNotifications

// MARK: - 모델

struct ClaudeUsage {
    var planName: String?              // "Max 5x", "Pro", etc.
    var sessionUtilization: Double     // 0-100
    var sessionResetsAt: Date?
    var weeklyUtilization: Double      // 0-100
    var weeklyResetsAt: Date?
    var extraEnabled: Bool
    var extraSpentCents: Double
    var extraLimitCents: Double
    var lastUpdated: Date = Date()

    var extraSpentDollars: Double { extraSpentCents / 100 }
    var extraLimitDollars: Double { extraLimitCents / 100 }
}

/// 키체인 `Claude Code-credentials`에서 읽어온 OAuth 자격증명.
struct OAuthCredentials: Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
}

/// OAuth 토큰 갱신 응답.
struct RefreshedToken: Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: TimeInterval?   // 초 단위
}

enum UsageError: LocalizedError {
    case noToken, httpError(Int), parseError

    var errorDescription: String? {
        switch self {
        case .noToken:             return "OAuth 토큰을 찾을 수 없음 (claude login 필요)"
        case .httpError(let code): return "API 오류: HTTP \(code)"
        case .parseError:          return "응답 파싱 실패"
        }
    }
}

// MARK: - UsageMonitor

@MainActor
class UsageMonitor: ObservableObject, UsageProviderProtocol {
    @Published var usage: ClaudeUsage?
    @Published var errorMessage: String?
    @Published var needsLogin: Bool = false    // 키체인에 자격증명 없음 → claude login 필요

    // isLoading은 computed property로 - @Published 변경 없이 뷰가 usage/errorMessage로 상태 파악
    var isLoading: Bool { usage == nil && errorMessage == nil }

    // MARK: - UsageProviderProtocol 적합 (R0.4)
    nonisolated var id: ProviderID { .claude }
    var onUsageChanged: ((ProviderUsage) -> Void)?
    var currentUsage: ProviderUsage {
        Self.toProviderUsage(usage: usage, errorMessage: errorMessage, needsLogin: needsLogin)
    }
    func updatePollInterval(_ interval: Double) { /* Claude uses fixed 5min polling */ }

    // 알림 설정 (AgentStore가 주입)
    var alertThreshold: Double = 80
    var notifyOnThreshold: Bool = true
    var notifyOnReset: Bool = true
    var localizer: ((String, String) -> String) = { ko, _ in ko }

    // AgentStore가 주입하는 알림 클로저 (Quiet Hours + DND 체크 포함)
    var sendNotificationHandler: ((String, String) -> Void)?

    private var pollingTimer: Timer?
    private let pollInterval: TimeInterval = 300  // 5분
    private var hasNotifiedThreshold = false       // 이번 사이클 알림 여부
    private var cachedPlanName: String?            // 플랜 정보 캐시

    func start() {
        Task { await fetch() }
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { await self?.fetch() }
        }
    }

    func stop() {
        pollingTimer?.invalidate()
    }

    func fetch() async {
        do {
            let token = try await validAccessToken()
            needsLogin = false
            // 플랜 정보는 한 번만 조회
            if cachedPlanName == nil {
                cachedPlanName = await fetchPlanName(token: token)
            }
            var newUsage = try await fetchUsage(token: token)
            newUsage.planName = cachedPlanName
            checkThresholdAndNotify(prev: usage, new: newUsage)
            usage = newUsage
            errorMessage = nil
        } catch UsageError.noToken {
            needsLogin = true
            errorMessage = localizer("Claude Code 로그인이 필요합니다 (claude login)",
                                     "Claude Code login required (claude login)")
        } catch {
            errorMessage = error.localizedDescription
        }
        // 변경된 상태를 coordinator로 발행
        onUsageChanged?(currentUsage)
    }

    // MARK: - 알림 로직

    private func checkThresholdAndNotify(prev: ClaudeUsage?, new: ClaudeUsage) {
        let newUtil = new.sessionUtilization
        let prevUtil = prev?.sessionUtilization

        // 1) 쿼터 충전 감지: 이전에 임계값 초과했었고, 지금 임계값 미만으로 내려옴
        if notifyOnReset,
           hasNotifiedThreshold,
           newUtil < alertThreshold {
            notifyUser(
                title: localizer("세션 쿼터 충전됨", "Session Quota Refilled"),
                body:  localizer("세션 쿼터가 \(Int(newUtil))%로 충전됐습니다", "Session quota refilled to \(Int(newUtil))%")
            )
            hasNotifiedThreshold = false
        }

        // 2) 임계값 초과 감지: 이번 사이클에 아직 알림 안 보냈고, 처음으로 초과
        if notifyOnThreshold,
           !hasNotifiedThreshold,
           newUtil >= alertThreshold,
           (prevUtil ?? 0) < alertThreshold || prevUtil == nil {
            notifyUser(
                title: localizer("세션 쿼터 경고", "Session Quota Alert"),
                body:  localizer("세션 쿼터 \(Int(newUtil))% 사용 중 (임계값: \(Int(alertThreshold))%)",
                                 "Session quota at \(Int(newUtil))% (threshold: \(Int(alertThreshold))%)")
            )
            hasNotifiedThreshold = true
        }
    }

    private func notifyUser(title: String, body: String) {
        sendNotificationHandler?(title, body)
    }

    // MARK: - ProviderUsage 매핑 순수 함수 (AC-0.1 TDD 대상)

    /// ClaudeUsage/errorMessage/needsLogin → ProviderUsage 변환.
    /// nonisolated static: 단위 테스트 가능.
    nonisolated static func toProviderUsage(
        usage: ClaudeUsage?,
        errorMessage: String?,
        needsLogin: Bool
    ) -> ProviderUsage {
        if needsLogin {
            return ProviderUsage(id: .claude, state: .needsSetup, isEstimate: false, quota: nil, estimate: nil)
        }
        if let err = errorMessage, usage == nil {
            return ProviderUsage(id: .claude, state: .error(err), isEstimate: false, quota: nil, estimate: nil)
        }
        guard let u = usage else {
            return ProviderUsage.loading(.claude, isEstimate: false)
        }
        let quota = QuotaInfo(
            sessionUtilization: u.sessionUtilization,
            sessionResetsAt: u.sessionResetsAt,
            weeklyUtilization: u.weeklyUtilization,
            weeklyResetsAt: u.weeklyResetsAt,
            planName: u.planName,
            extra: u.extraEnabled ? ExtraInfo(
                enabled: true,
                spentDollars: u.extraSpentDollars,
                limitDollars: u.extraLimitDollars
            ) : nil
        )
        return ProviderUsage(id: .claude, state: .data, isEstimate: false, quota: quota, estimate: nil)
    }

    // MARK: - Keychain 토큰 로드
    // SecItemCopyMatching 대신 security CLI를 사용:
    // Claude Code가 만든 Keychain 항목의 ACL에는 security 도구가 신뢰된 앱으로 등록되어 있어
    // 직접 API 접근 시 매번 암호 승인 팝업이 뜨는 문제를 방지

    /// 키체인에서 원본 자격증명 JSON 데이터를 읽는다.
    private func loadCredentialsData() throws -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()

        let raw = outPipe.fileHandleForReading.readDataToEndOfFile()
        let trimmed = raw.filter { $0 != UInt8(ascii: "\n") && $0 != UInt8(ascii: "\r") }
        guard !trimmed.isEmpty else { throw UsageError.noToken }
        return trimmed
    }

    /// 키체인 자격증명을 파싱해 반환. 없거나 형식이 틀리면 noToken.
    private func loadCredentials() throws -> OAuthCredentials {
        let data = try loadCredentialsData()
        guard let creds = Self.parseCredentials(from: data) else {
            throw UsageError.noToken
        }
        return creds
    }

    /// 유효한 access token을 돌려준다. 만료(임박)됐고 refresh token이 있으면 갱신을 시도한다.
    private func validAccessToken() async throws -> String {
        let creds = try loadCredentials()
        guard Self.isTokenExpired(expiresAt: creds.expiresAt, now: Date()),
              let refresh = creds.refreshToken else {
            return creds.accessToken
        }

        let req = Self.buildRefreshRequest(refreshToken: refresh)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let refreshed = Self.parseRefreshResponse(from: data) else {
            // 갱신 실패 → 기존(만료) 토큰을 그대로 반환해 하위 호출의 오류로 표면화
            return creds.accessToken
        }

        // best-effort 영속화: 재시작 후에도 살아남도록 키체인 갱신
        if let original = try? loadCredentialsData(),
           let merged = Self.mergedCredentialsJSON(original: original, refreshed: refreshed, now: Date()) {
            saveCredentials(json: merged)
        }
        return refreshed.accessToken
    }

    /// 갱신된 자격증명 JSON을 키체인에 in-place 업데이트(-U)한다. 실패해도 무시(best-effort).
    private func saveCredentials(json: Data) {
        guard let str = String(data: json, encoding: .utf8) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["add-generic-password", "-U",
                          "-a", NSUserName(),
                          "-s", "Claude Code-credentials",
                          "-w", str]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }

    // MARK: - 토큰 파싱/갱신 순수 함수 (단위 테스트 가능)

    nonisolated static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    nonisolated static let tokenRefreshURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    /// 키체인 JSON → OAuthCredentials. accessToken 없으면 nil.
    nonisolated static func parseCredentials(from data: Data) -> OAuthCredentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String else {
            return nil
        }
        let expMs = oauth["expiresAt"] as? Double
        return OAuthCredentials(
            accessToken: access,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: expMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    /// 만료 시각이 now + skew 안쪽이면 만료로 본다. 만료 시각을 모르면(nil) 갱신하지 않는다.
    nonisolated static func isTokenExpired(expiresAt: Date?, now: Date, skew: TimeInterval = 300) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(skew) >= expiresAt
    }

    /// refresh_token 그랜트 요청 생성.
    nonisolated static func buildRefreshRequest(refreshToken: String) -> URLRequest {
        var req = URLRequest(url: tokenRefreshURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauthClientID
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// 토큰 갱신 응답 파싱. access_token 없으면 nil.
    nonisolated static func parseRefreshResponse(from data: Data) -> RefreshedToken? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            return nil
        }
        return RefreshedToken(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String,
            expiresIn: json["expires_in"] as? Double
        )
    }

    /// 갱신된 토큰을 원본 자격증명 JSON에 병합(organizationUuid·scopes 등 보존). 키체인 저장용.
    nonisolated static func mergedCredentialsJSON(original: Data, refreshed: RefreshedToken, now: Date) -> Data? {
        guard var json = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any],
              var oauth = json["claudeAiOauth"] as? [String: Any] else {
            return nil
        }
        oauth["accessToken"] = refreshed.accessToken
        if let rt = refreshed.refreshToken { oauth["refreshToken"] = rt }
        if let exp = refreshed.expiresIn {
            oauth["expiresAt"] = (now.timeIntervalSince1970 + exp) * 1000
        }
        json["claudeAiOauth"] = oauth
        return try? JSONSerialization.data(withJSONObject: json)
    }

    // MARK: - API 호출

    private func fetchPlanName(token: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/account")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let memberships = json["memberships"] as? [[String: Any]]
        else { return nil }

        // 구독형 조직에서 플랜 추출
        for membership in memberships {
            guard let org = membership["organization"] as? [String: Any],
                  let billing = org["billing_type"] as? String,
                  billing == "stripe_subscription",
                  let tier = org["rate_limit_tier"] as? String
            else { continue }

            if tier.contains("max_20x") { return "Max 20x" }
            if tier.contains("max_5x")  { return "Max 5x" }
            if tier.contains("max")     { return "Max" }
            if tier.contains("team")    { return "Team" }
            return "Pro"
        }
        return nil
    }

    private func fetchUsage(token: String) async throws -> ClaudeUsage {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UsageError.httpError(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.parseError
        }
        return parseUsage(json)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func parseUsage(_ json: [String: Any]) -> ClaudeUsage {
        func date(_ dict: [String: Any]?) -> Date? {
            guard let s = dict?["resets_at"] as? String else { return nil }
            return Self.iso8601Formatter.date(from: s)
        }
        let five  = json["five_hour"]   as? [String: Any]
        let seven = json["seven_day"]   as? [String: Any]
        let extra = json["extra_usage"] as? [String: Any]
        return ClaudeUsage(
            sessionUtilization: five?["utilization"]  as? Double ?? 0,
            sessionResetsAt:    date(five),
            weeklyUtilization:  seven?["utilization"] as? Double ?? 0,
            weeklyResetsAt:     date(seven),
            extraEnabled:       extra?["is_enabled"]   as? Bool   ?? false,
            extraSpentCents:    extra?["used_credits"] as? Double ?? 0,
            extraLimitCents:    extra?["monthly_limit"] as? Double ?? 0
        )
    }
}
