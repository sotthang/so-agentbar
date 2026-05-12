import XCTest
@testable import SoAgentBar

// extended thinking이 켜진 Opus 세션에서는 한 턴이
//   1) stop_reason=end_turn + content=[thinking]   ← thinking 종료 (응답 아님)
//   2) stop_reason=end_turn + content=[text]       ← 실제 최종 응답
// 두 이벤트로 끝난다. 1번을 응답 완료로 오인하면 알람이 9~수십초 일찍 울리고
// 본문에 이전 턴의 응답 텍스트가 표시된다.

final class SessionMonitorThinkingEndTurnTests: XCTestCase {

    private func makeClaudeSession() -> ClaudeSession {
        let now = Date()
        return ClaudeSession(
            id: UUID().uuidString,
            projectDir: "/tmp/proj",
            source: .cli,
            workingPath: "/tmp/proj",
            lastModified: now,
            lastActivity: now,
            lastContentChange: now
        )
    }

    private func thinkingEndTurn() -> [String: Any] {
        [
            "type": "assistant",
            "timestamp": "2026-05-12T02:33:50.300Z",
            "message": [
                "role": "assistant",
                "model": "claude-opus-4-7",
                "stop_reason": "end_turn",
                "content": [["type": "thinking", "thinking": "..."]]
            ] as [String: Any]
        ]
    }

    private func textEndTurn(_ text: String = "최종 응답") -> [String: Any] {
        [
            "type": "assistant",
            "timestamp": "2026-05-12T02:33:59.304Z",
            "message": [
                "role": "assistant",
                "model": "claude-opus-4-7",
                "stop_reason": "end_turn",
                "content": [["type": "text", "text": text]]
            ] as [String: Any]
        ]
    }

    // MARK: - RED: thinking-only end_turn은 응답 완료가 아니다

    func test_thinkingOnlyEndTurn_doesNotMarkAsResponded() {
        let monitor = ClaudeSessionMonitor()
        var session = makeClaudeSession()

        monitor.processEvent(thinkingEndTurn(), session: &session)

        XCTAssertNotEqual(session.sessionStatus, .responded,
                          "thinking 블록만 있는 end_turn 이벤트는 응답 완료(.responded)로 처리되면 안 된다")
    }

    // MARK: - 회귀 보호: 실제 text end_turn은 응답 완료로 처리된다

    func test_textEndTurn_marksAsResponded() {
        let monitor = ClaudeSessionMonitor()
        var session = makeClaudeSession()

        monitor.processEvent(textEndTurn(), session: &session)

        XCTAssertEqual(session.sessionStatus, .responded,
                       "텍스트 블록을 가진 end_turn 이벤트는 응답 완료(.responded)로 처리되어야 한다")
    }

    // MARK: - 실제 시퀀스: thinking-only end_turn 직후 text end_turn → .responded

    func test_thinkingThenText_endsInResponded() {
        let monitor = ClaudeSessionMonitor()
        var session = makeClaudeSession()

        monitor.processEvent(thinkingEndTurn(), session: &session)
        monitor.processEvent(textEndTurn("응답 본문"), session: &session)

        XCTAssertEqual(session.sessionStatus, .responded,
                       "thinking-only end_turn 다음의 text end_turn에서 .responded가 되어야 한다")
        XCTAssertEqual(session.lastAssistantText, "응답 본문",
                       "최종 응답 텍스트가 저장되어야 한다")
    }
}
