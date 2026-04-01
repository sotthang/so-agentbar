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
class UsageMonitor: ObservableObject {
    @Published var usage: ClaudeUsage?
    @Published var errorMessage: String?

    // isLoading은 computed property로 - @Published 변경 없이 뷰가 usage/errorMessage로 상태 파악
    var isLoading: Bool { usage == nil && errorMessage == nil }

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
            let token = try loadOAuthToken()
            // 플랜 정보는 한 번만 조회
            if cachedPlanName == nil {
                cachedPlanName = await fetchPlanName(token: token)
            }
            var newUsage = try await fetchUsage(token: token)
            newUsage.planName = cachedPlanName
            checkThresholdAndNotify(prev: usage, new: newUsage)
            usage = newUsage
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
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

    // MARK: - Keychain 토큰 로드
    // SecItemCopyMatching 대신 security CLI를 사용:
    // Claude Code가 만든 Keychain 항목의 ACL에는 security 도구가 신뢰된 앱으로 등록되어 있어
    // 직접 API 접근 시 매번 암호 승인 팝업이 뜨는 문제를 방지

    private func loadOAuthToken() throws -> String {
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
        guard let json = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            throw UsageError.noToken
        }
        return token
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
