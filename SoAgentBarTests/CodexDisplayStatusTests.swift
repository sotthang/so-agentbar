import XCTest
@testable import SoAgentBar

// MARK: - CodexDisplayStatusTests
// AC-R4.x 검증 (source-aware displayStatus 상태 판정)
// RED: ClaudeSession.displayStatus, codexSawResultEvent, codexSawErrorEvent 등 없음 → 컴파일 에러 예상

final class CodexDisplayStatusTests: XCTestCase {

    // MARK: - 헬퍼: Codex 세션 빌더

    private func makeCodexSession(
        source: SessionSource = .codexCLI,
        lastEventType: String = "",
        sawResultEvent: Bool = false,
        sawErrorEvent: Bool = false,
        lastContentAge: TimeInterval = 1.0,   // 초 전
        approvalPolicy: String? = nil,
        lastToolUseAge: TimeInterval? = nil
    ) -> ClaudeSession {
        let now = Date()
        let lastChange = now.addingTimeInterval(-lastContentAge)
        var session = ClaudeSession(
            id: UUID().uuidString,
            projectDir: "/tmp/codex-fixture",
            source: source,
            workingPath: "/tmp/codex-fixture",
            lastModified: lastChange,
            lastActivity: lastChange,
            lastContentChange: lastChange
        )
        session.lastEventType = lastEventType
        // [NEW Codex 필드들 — Developer가 ClaudeSession에 추가해야 컴파일 가능]
        session.codexSawResultEvent = sawResultEvent
        session.codexSawErrorEvent = sawErrorEvent
        session.codexApprovalPolicy = approvalPolicy
        if let toolAge = lastToolUseAge {
            session.lastToolUseTime = now.addingTimeInterval(-toolAge)
        }
        return session
    }

    // MARK: - AC-R4.1: agent_message + 6초 이상 정적 → .responded

    func test_responseItemAfter6s_isResponded() {
        let session = makeCodexSession(
            lastEventType: "assistant",
            lastContentAge: 6.0
        )
        XCTAssertEqual(session.displayStatus, .responded,
                       "agent_message(assistant) 이벤트 6초 후 → .responded")
    }

    // MARK: - AC-R4.2: 마지막 이벤트 5분 이상 정적 → .idle

    func test_anyEventOver5min_isIdle() {
        let session = makeCodexSession(
            lastEventType: "assistant",
            lastContentAge: 301.0    // 5분 1초
        )
        XCTAssertEqual(session.displayStatus, .idle,
                       "5분(300초) 이상 정적 → .idle")
    }

    // MARK: - AC-R4.3: task_started + 2초 이내 → .running

    func test_userEventWithin2s_isRunning() {
        let session = makeCodexSession(
            lastEventType: "task_started",
            lastContentAge: 2.0
        )
        XCTAssertEqual(session.displayStatus, .running,
                       "task_started 이벤트 2초 이내 → .running")
    }

    // MARK: - AC-R4.4: displayStatus 출력값은 항상 6원소 집합 중 하나 (양성형)

    func test_displayStatus_alwaysInAllowedSet() {
        let allowedStatuses: Set<SessionStatus> = [
            .idle, .running, .responded, .waitingForApproval, .completed, .error
        ]
        let testCases: [ClaudeSession] = [
            makeCodexSession(lastEventType: "task_started", lastContentAge: 1.0),
            makeCodexSession(lastEventType: "assistant", lastContentAge: 6.0),
            makeCodexSession(lastEventType: "user", lastContentAge: 3.0),
            makeCodexSession(lastEventType: "", lastContentAge: 301.0),
            makeCodexSession(sawResultEvent: true, sawErrorEvent: false, lastContentAge: 1.0),
            makeCodexSession(sawResultEvent: true, sawErrorEvent: true, lastContentAge: 1.0),
            makeCodexSession(lastEventType: "assistant", sawResultEvent: false, sawErrorEvent: false,
                             lastContentAge: 10.0, approvalPolicy: "on-request", lastToolUseAge: 10.0),
        ]

        for (i, session) in testCases.enumerated() {
            let status = session.displayStatus
            XCTAssertTrue(allowedStatuses.contains(status),
                          "케이스 \(i): displayStatus=\(status)은 허용 집합 외의 값이다")
        }
    }

    // MARK: - AC-R4.5: task_complete 이벤트 마지막 → .completed

    func test_taskComplete_lastEvent_isCompleted() {
        let session = makeCodexSession(
            lastEventType: "task_complete",
            sawResultEvent: true,
            sawErrorEvent: false
        )
        XCTAssertEqual(session.displayStatus, .completed,
                       "task_complete 이벤트가 마지막 → .completed")
    }

    // MARK: - AC-R4.6: error 이벤트 마지막 → .error (+ codexErrorInfo 보존)

    func test_error_lastEvent_isError() {
        var session = makeCodexSession(
            lastEventType: "error",
            sawResultEvent: true,
            sawErrorEvent: true
        )
        session.codexErrorInfo = "other"

        XCTAssertEqual(session.displayStatus, .error,
                       "error 이벤트 → .error")
        XCTAssertEqual(session.codexErrorInfo, "other",
                       "codexErrorInfo에 codex_error_info 값이 보존되어야 한다")
    }

    // MARK: - AC-R4.7: task_started resume → 직전 .completed 리셋 후 .running

    func test_taskStartedAfterComplete_resetsToRunning() {
        // task_complete 후 task_started 도착 → sawResultEvent=false로 리셋되어야 함
        // 이 테스트는 CodexSessionMonitor가 task_started 처리 시 플래그를 리셋하는 것을 검증
        // sawResultEvent=false: task_started 도착 시 리셋된 상태
        let session = makeCodexSession(
            lastEventType: "task_started",
            sawResultEvent: false,
            sawErrorEvent: false,
            lastContentAge: 1.0
        )
        XCTAssertEqual(session.displayStatus, .running,
                       "task_started 도착으로 완료 플래그 리셋 후 → .running")
    }

    // MARK: - Claude 세션은 기존 sessionStatus 사용 (회귀 보호)

    func test_claudeSession_usesExistingSessionStatus() {
        var session = ClaudeSession(
            id: UUID().uuidString,
            projectDir: "/tmp/project",
            source: .cli,
            workingPath: "/tmp/project",
            lastModified: Date(),
            lastActivity: Date(),
            lastContentChange: Date()
        )
        session.sawResultEvent = true
        session.sawErrorEvent = false

        // Claude 세션에서 displayStatus는 sessionStatus로 위임 → .completed
        XCTAssertEqual(session.displayStatus, .completed,
                       "Claude 세션의 displayStatus는 기존 sessionStatus로 위임되어야 한다")
    }
}
