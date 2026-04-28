import XCTest
@testable import SoAgentBar

/// 에러 세션이 일정 시간(기본 5분) 이상 지나면 픽셀 창에서 자동으로 사라지는지 검증.
final class AgentStoreErrorRetentionTests: XCTestCase {

    // MARK: - 헬퍼

    private func makeSession(
        id: String = UUID().uuidString,
        lastActivityOffset: TimeInterval = 0,
        markError: Bool = false,
        isSubagent: Bool = false
    ) -> ClaudeSession {
        var s = ClaudeSession(
            id: id,
            projectDir: "/tmp/p",
            source: .cli,
            workingPath: "/tmp/p",
            lastModified: Date(),
            lastActivity: Date(timeIntervalSinceNow: lastActivityOffset),
            lastContentChange: Date(timeIntervalSinceNow: lastActivityOffset)
        )
        if markError {
            s.sawResultEvent = true
            s.sawErrorEvent = true
        }
        s.isSubagent = isSubagent
        return s
    }

    // MARK: - 5분 초과 에러 세션 필터링

    func test_errorSession_olderThanRetention_isFiltered_whenShowIdle() {
        let stale = makeSession(lastActivityOffset: -360, markError: true)  // 6분 전
        let fresh = makeSession(lastActivityOffset: -60,  markError: true)  // 1분 전

        let result = AgentStore.filterSessionsForDisplay(
            [stale, fresh],
            showIdleSessions: true,
            errorRetention: 300,
            now: Date()
        )

        XCTAssertEqual(result.count, 1, "5분 초과한 에러 세션은 제외되어야 한다")
        XCTAssertEqual(result.first?.id, fresh.id)
    }

    func test_errorSession_withinRetention_isVisible_evenWhenShowIdleFalse() {
        let fresh = makeSession(lastActivityOffset: -60, markError: true)  // 1분 전

        let result = AgentStore.filterSessionsForDisplay(
            [fresh],
            showIdleSessions: false,
            errorRetention: 300,
            now: Date()
        )

        XCTAssertEqual(result.count, 1,
                       "유휴 표시 OFF여도 5분 이내 에러 세션은 사용자 인지를 위해 노출되어야 한다")
    }

    func test_errorSession_olderThanRetention_isFiltered_whenShowIdleFalse() {
        let stale = makeSession(lastActivityOffset: -360, markError: true)

        let result = AgentStore.filterSessionsForDisplay(
            [stale],
            showIdleSessions: false,
            errorRetention: 300,
            now: Date()
        )

        XCTAssertTrue(result.isEmpty, "유휴 표시 OFF + 5분 초과 에러는 모두 숨겨야 한다")
    }

    // MARK: - 서브에이전트도 동일 규칙 적용 (전체 적용)

    func test_subagentErrorSession_olderThanRetention_isFiltered() {
        let stale = makeSession(lastActivityOffset: -360, markError: true, isSubagent: true)

        let result = AgentStore.filterSessionsForDisplay(
            [stale],
            showIdleSessions: true,
            errorRetention: 300,
            now: Date()
        )

        XCTAssertTrue(result.isEmpty, "서브에이전트 에러 세션도 5분 초과 시 동일하게 제외되어야 한다")
    }

    // MARK: - 비-에러 세션은 retention 영향 받지 않음 (회귀 방지)

    func test_idleSession_olderThanRetention_unaffected_whenShowIdle() {
        let oldIdle = makeSession(lastActivityOffset: -3600, markError: false)  // 1시간 전, idle

        let result = AgentStore.filterSessionsForDisplay(
            [oldIdle],
            showIdleSessions: true,
            errorRetention: 300,
            now: Date()
        )

        XCTAssertEqual(result.count, 1,
                       "에러가 아닌 idle 세션은 retention 무관하게 showIdle=true면 노출되어야 한다")
    }

    func test_defaultRetention_is5Minutes() {
        XCTAssertEqual(AgentStore.errorSessionRetention, 300,
                       "에러 세션 기본 retention은 5분(300초)이어야 한다")
    }
}
