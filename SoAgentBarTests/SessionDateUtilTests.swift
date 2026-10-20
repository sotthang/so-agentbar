import XCTest
@testable import SoAgentBar

// PERF-005: processEvent가 모든 이벤트의 timestamp를 ISO8601DateFormatter로 파싱해
// GB 단위 로그 파싱 시 CPU의 ~39%를 포매터가 차지했다.
// → 실데이터 고정 포맷("YYYY-MM-DDTHH:MM:SS.sssZ")은 바이트 단위로 직접 파싱하고,
//   그 외 포맷만 기존 포매터로 폴백한다. 결과 Date는 포매터와 비트 단위로 동일해야 한다.

final class SessionDateUtilTests: XCTestCase {

    /// 기존 동작 기준(오라클) — 변경 전 parseISO8601과 동일한 설정의 별도 인스턴스
    private let oracle: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - 고정 포맷 빠른 경로

    func test_fastPath_parsesCanonicalMillisZFormat_withoutFormatter() {
        let s = "2026-10-19T12:34:56.789Z"
        XCTAssertNotNil(SessionDateUtil.parseFixedUTCMillis(s),
                        "실데이터 포맷은 포매터 없이 빠른 경로에서 처리되어야 한다")
        XCTAssertEqual(SessionDateUtil.parseFixedUTCMillis(s), oracle.date(from: s))
    }

    func test_fastPath_matchesFormatterBitForBit_forFixtureStyleStrings() {
        let samples = [
            "2026-05-12T02:33:50.300Z",
            "1970-01-01T00:00:00.000Z",
            "2000-02-29T23:59:59.999Z",   // 윤년
            "2024-12-31T23:59:59.001Z",
            "2001-01-01T00:00:00.000Z",   // reference date
            "1999-03-01T00:00:00.500Z",
        ]
        for s in samples {
            let fast = SessionDateUtil.parseFixedUTCMillis(s)
            XCTAssertNotNil(fast, s)
            XCTAssertEqual(fast?.timeIntervalSinceReferenceDate,
                           oracle.date(from: s)?.timeIntervalSinceReferenceDate, s)
        }
    }

    func test_fastPath_matchesFormatter_forRandomInstants() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<5_000 {
            let ms = Int.random(in: 0..<4_102_444_800_000, using: &rng) // 1970 ~ 2100
            let s = oracle.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
            XCTAssertEqual(SessionDateUtil.parseFixedUTCMillis(s)?.timeIntervalSinceReferenceDate,
                           oracle.date(from: s)?.timeIntervalSinceReferenceDate, s)
        }
    }

    func test_fastPath_rejectsNonCanonicalFormats_soThatFormatterDecides() {
        let others = [
            "2026-10-19T12:34:56Z",            // 소수점 없음
            "2026-10-19T12:34:56.789+09:00",   // 오프셋
            "2026-10-19T12:34:56.7Z",          // 정밀도 다름
            "2026-10-19T12:34:56.789123Z",     // 마이크로초
            "2026-02-30T12:34:56.789Z",        // 존재하지 않는 날짜
            "2026-10-19T24:00:00.000Z",
            "2026-10-19T12:60:00.000Z",
            "2026-10-19T12:34:60.000Z",        // 윤초
            "2026-13-19T12:34:56.789Z",
            "2026-1a-19T12:34:56.789Z",
            "2026-10-19 12:34:56.789Z",
            "",
        ]
        for s in others {
            XCTAssertNil(SessionDateUtil.parseFixedUTCMillis(s), s)
        }
    }

    // MARK: - 공개 API: 기존 포매터 결과와 동일 (폴백 포함)

    func test_parseISO8601_matchesFormatter_forAllFormats() {
        let all = [
            "2026-10-19T12:34:56.789Z",
            "2026-10-19T12:34:56Z",
            "2026-10-19T12:34:56.789+09:00",
            "2026-10-19T12:34:56.7Z",
            "2026-10-19T12:34:56.789123Z",
            "2026-02-30T12:34:56.789Z",
            "garbage",
            "",
        ]
        for s in all {
            XCTAssertEqual(SessionDateUtil.parseISO8601(s), oracle.date(from: s), s)
        }
    }

    // MARK: - processEvent 의미 보존

    private func makeSession(lastActivity: Date) -> ClaudeSession {
        ClaudeSession(
            id: UUID().uuidString,
            projectDir: "/tmp/proj",
            source: .cli,
            workingPath: "/tmp/proj",
            lastModified: lastActivity,
            lastActivity: lastActivity,
            lastContentChange: lastActivity
        )
    }

    private func userEvent(_ ts: String) -> [String: Any] {
        ["type": "user", "timestamp": ts,
         "message": ["role": "user", "content": "hi"] as [String: Any]]
    }

    func test_processEvent_outOfOrderTimestamp_doesNotMoveLastActivityBackwards() {
        let monitor = ClaudeSessionMonitor()
        var session = makeSession(lastActivity: .distantPast)

        monitor.processEvent(userEvent("2026-10-19T12:00:05.000Z"), session: &session)
        monitor.processEvent(userEvent("2026-10-19T12:00:01.000Z"), session: &session)

        XCTAssertEqual(session.lastActivity, oracle.date(from: "2026-10-19T12:00:05.000Z"))
    }

    func test_processEvent_newerTimestamp_advancesLastActivity() {
        let monitor = ClaudeSessionMonitor()
        var session = makeSession(lastActivity: .distantPast)

        monitor.processEvent(userEvent("2026-10-19T12:00:01.000Z"), session: &session)
        monitor.processEvent(userEvent("2026-10-19T12:00:05.123Z"), session: &session)

        XCTAssertEqual(session.lastActivity, oracle.date(from: "2026-10-19T12:00:05.123Z"))
    }

    func test_processEvent_toolUse_recordsEventTimestampAsLastToolUseTime() {
        let monitor = ClaudeSessionMonitor()
        var session = makeSession(lastActivity: .distantPast)
        let ts = "2026-10-19T12:00:07.250Z"
        let event: [String: Any] = [
            "type": "assistant", "timestamp": ts,
            "message": [
                "role": "assistant",
                "stop_reason": "tool_use",
                "content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": [:]]]
            ] as [String: Any]
        ]

        monitor.processEvent(event, session: &session)

        XCTAssertEqual(session.lastToolUseTime, oracle.date(from: ts))
    }
}
