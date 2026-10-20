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

// MARK: - 공유 ISO8601 파서 (고정 포맷 빠른 경로 + 포매터 폴백)

enum SessionDateUtil {
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// 이벤트 timestamp 파싱. 모든 JSONL 이벤트마다 호출되는 핫패스(PERF-005).
    /// 실데이터(Claude/Codex) 포맷은 고정 포맷 빠른 경로로 처리하고,
    /// 그 외 포맷만 포매터로 폴백한다 — 결과는 포매터 단독일 때와 동일하다.
    static func parseISO8601(_ str: String) -> Date? {
        parseFixedUTCMillis(str) ?? iso8601.date(from: str)
    }

    /// "YYYY-MM-DDTHH:MM:SS.sssZ" (24바이트, UTC, 밀리초 3자리) 전용 파서.
    /// 포맷이 정확히 일치하고 필드가 유효 범위일 때만 Date를 반환하고, 아니면 nil(→ 포매터가 판단).
    /// `timeIntervalSince1970: 초 + ms/1000` 계산은 ISO8601DateFormatter 결과와 비트 단위로 일치한다
    /// (SessionDateUtilTests에서 무작위 시각으로 검증). 상태 없는 순수 함수라 스레드 안전.
    static func parseFixedUTCMillis(_ str: String) -> Date? {
        var s = str
        return s.withUTF8 { b -> Date? in
            guard b.count == 24,
                  b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-"),
                  b[10] == UInt8(ascii: "T"), b[13] == UInt8(ascii: ":"),
                  b[16] == UInt8(ascii: ":"), b[19] == UInt8(ascii: "."),
                  b[23] == UInt8(ascii: "Z") else { return nil }

            func num(_ from: Int, _ len: Int) -> Int? {
                var v = 0
                for i in from..<(from + len) {
                    let d = Int(b[i]) &- 48
                    guard d >= 0, d <= 9 else { return nil }
                    v = v * 10 + d
                }
                return v
            }
            guard let year = num(0, 4), let month = num(5, 2), let day = num(8, 2),
                  let hour = num(11, 2), let minute = num(14, 2), let second = num(17, 2),
                  let millis = num(20, 3),
                  (1...12).contains(month), hour < 24, minute < 60, second < 60,
                  day >= 1, day <= daysInMonth(year: year, month: month) else { return nil }

            let secs = daysSinceUnixEpoch(year: year, month: month, day: day) * 86_400
                + hour * 3_600 + minute * 60 + second
            return Date(timeIntervalSince1970: Double(secs) + Double(millis) / 1000)
        }
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// 그레고리력 날짜 → 1970-01-01 기준 일수 (Howard Hinnant의 days_from_civil)
    private static func daysSinceUnixEpoch(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
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
