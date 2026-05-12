import XCTest
@testable import SoAgentBar

// "응답했습니다" 알람은 즉시가 아닌 지연 후 발사된다.
// 이유: extended thinking 환경에서 모델이 text end_turn 후 곧바로 다음 작업을 재개하는
// 패턴(중간 체크포인트)이 흔함. 즉시 발사하면 매 phase마다 알람이 울려 산만.
// 사용자가 원하는 알람:
//   1) 최종 응답이 끝났을 때 (모델이 완전히 정지)
//   2) HITL — AskUserQuestion 등은 별도 "승인 필요" 알람 경로(영향 없음)

final class CompletionAlarmDelayTests: XCTestCase {

    private func makeSession(
        id: String,
        lastEventType: String,
        lastAssistantHasToolUse: Bool,
        contentAge: TimeInterval = 1.0
    ) -> ClaudeSession {
        let now = Date()
        let stamp = now.addingTimeInterval(-contentAge)
        var s = ClaudeSession(
            id: id,
            projectDir: "/tmp/proj",
            source: .cli,
            workingPath: "/tmp/proj",
            lastModified: stamp,
            lastActivity: stamp,
            lastContentChange: stamp
        )
        s.lastEventType = lastEventType
        s.lastAssistantHasToolUse = lastAssistantHasToolUse
        return s
    }

    // working → thinking 전이 시 thinkingSince 기록 + 즉시 알람 X
    func test_workingToThinking_recordsThinkingTimestamp() {
        let store = AgentStore()
        store.notifyOnComplete = true
        store.completionAlarmDelay = 60

        let sessionId = "test-session-\(UUID().uuidString)"

        // 사전 상태: previousStatuses == .working, workingSince 11초 전
        store.previousStatuses[sessionId] = .working
        store.workingSince[sessionId] = Date(timeIntervalSinceNow: -11)

        // assistant + end_turn(no tool_use) → .thinking
        let thinking = makeSession(id: sessionId, lastEventType: "assistant", lastAssistantHasToolUse: false)
        store.updateAgents(from: [thinking])

        XCTAssertNotNil(store.thinkingSince[sessionId],
                        "working → thinking 전이 후 thinkingSince 가 기록되어야 한다 (지연 알람 시작)")
    }

    // thinking → working 전이 시 thinkingSince 클리어 (알람 취소)
    func test_thinkingToWorking_clearsThinkingTimestamp() {
        let store = AgentStore()
        store.notifyOnComplete = true
        store.completionAlarmDelay = 60

        let sessionId = "test-session-\(UUID().uuidString)"
        store.thinkingSince[sessionId] = Date()
        store.previousStatuses[sessionId] = .thinking

        // assistant + tool_use → .working
        let working = makeSession(id: sessionId, lastEventType: "assistant", lastAssistantHasToolUse: true)
        store.updateAgents(from: [working])

        XCTAssertNil(store.thinkingSince[sessionId],
                     "thinking → working(재개) 전이 시 thinkingSince 가 클리어되어 알람이 취소되어야 한다")
    }

    // thinking 지속 + 지연 경과 → 알람 발사 후 timestamp 클리어
    func test_thinkingDelayElapsed_firesAndClearsTimestamp() {
        let store = AgentStore()
        store.notifyOnComplete = true
        store.completionAlarmDelay = 0.01   // 매우 짧게 (테스트용)

        let sessionId = "test-session-\(UUID().uuidString)"
        store.thinkingSince[sessionId] = Date(timeIntervalSinceNow: -1.0)
        store.previousStatuses[sessionId] = .thinking

        // 여전히 thinking 상태 — poll 시뮬레이션
        let stillThinking = makeSession(id: sessionId, lastEventType: "assistant", lastAssistantHasToolUse: false)
        store.updateAgents(from: [stillThinking])

        XCTAssertNil(store.thinkingSince[sessionId],
                     "지연 경과 후 알람 발사되며 thinkingSince 가 클리어되어야 한다")
    }
}
