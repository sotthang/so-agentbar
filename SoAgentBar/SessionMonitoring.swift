import Foundation

// MARK: - SessionMonitorProtocol

/// ClaudeSessionMonitor와 CodexSessionMonitor가 공통으로 노출하는 계약.
/// SessionCoordinator는 이 프로토콜만 알면 두 모니터를 합성할 수 있다.
protocol SessionMonitorProtocol: AnyObject {
    /// 모니터가 새 세션 목록을 발견할 때마다 메인 큐에서 호출됨.
    var onSessionsChanged: (([ClaudeSession]) -> Void)? { get set }

    func start()
    func stop()
    func updatePollInterval(_ interval: Double)
}

// MARK: - 공유 ISO8601 포매터

enum SessionDateUtil {
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseISO8601(_ str: String) -> Date? { iso8601.date(from: str) }
}

// MARK: - 그룹 키 정규화 (R5)

enum ProjectGroupKey {
    /// 절대 cwd 경로를 그룹 키로 정규화.
    /// - Claude: workingPath가 절대 경로 (이미 readCWD()로 cwd를 채움)
    /// - Codex: session_meta.cwd / turn_context.cwd
    /// - 누락 시: displayName(파일명 폴백)을 키로 사용 → 다른 세션과 묶이지 않음
    static func key(for session: ClaudeSession) -> String {
        let cwd = session.workingPath
        if cwd.isEmpty || cwd.contains("/.claude/projects/") {
            return "__nogroup__:\(session.displayName)"
        }
        return URL(fileURLWithPath: cwd).standardizedFileURL.path
    }
}
