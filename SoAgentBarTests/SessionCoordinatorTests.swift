import XCTest
@testable import SoAgentBar

// MARK: - SessionCoordinatorTests
// AC-R6.4, AC-R6.6 검증
// RED: SessionCoordinator, SessionMonitorProtocol 구현 심볼 없음 → 컴파일 에러 예상

final class SessionCoordinatorTests: XCTestCase {

    // MARK: - Mock Monitor

    final class MockMonitor: SessionMonitorProtocol {
        var onSessionsChanged: (([ClaudeSession]) -> Void)?
        var started = false
        var stopped = false

        func start() { started = true }
        func stop() { stopped = true }
        func updatePollInterval(_ interval: Double) {}

        /// 테스트에서 콜백을 직접 트리거
        func emit(_ sessions: [ClaudeSession]) {
            onSessionsChanged?(sessions)
        }
    }

    // MARK: - 헬퍼: ClaudeSession 빌더

    private func makeClaudeSession(id: String = UUID().uuidString, source: SessionSource = .cli) -> ClaudeSession {
        ClaudeSession(
            id: id,
            projectDir: "/tmp/project",
            source: source,
            workingPath: "/tmp/project",
            lastModified: Date(),
            lastActivity: Date(),
            lastContentChange: Date()
        )
    }

    private func makeCodexSession(id: String = UUID().uuidString) -> ClaudeSession {
        makeClaudeSession(id: id, source: .codexCLI)
    }

    // MARK: - AC-R5.1 / 기본 병합: 두 모니터 결과를 합산

    func test_mergesBothMonitors() {
        let claudeMock = MockMonitor()
        let codexMock = MockMonitor()
        let coordinator = SessionCoordinator(
            claudeMonitor: claudeMock,
            codexMonitor: codexMock,
            initialCodexEnabled: true
        )

        var received: [ClaudeSession] = []
        let exp = expectation(description: "merged sessions (count == 2)")
        coordinator.onSessionsChanged = { sessions in
            received = sessions
            // claude+codex 둘 다 emit된 후의 콜백에서만 fulfill (이전 부분 콜백 무시)
            if sessions.count == 2 {
                exp.fulfill()
            }
        }
        coordinator.start()

        // Claude 1개 + Codex 1개 emit
        let claudeSession = makeClaudeSession(source: .cli)
        let codexSession = makeCodexSession()
        claudeMock.emit([claudeSession])
        codexMock.emit([codexSession])

        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(received.count, 2,
                       "Claude 1 + Codex 1 = 합산 2개가 onSessionsChanged에 전달되어야 한다")
    }

    // MARK: - AC-R6.6: 토글 OFF 직후 첫 콜백에 Codex 세션 미포함

    func test_codexDisabled_filtersCodexSessionsImmediately() {
        let claudeMock = MockMonitor()
        let codexMock = MockMonitor()
        let coordinator = SessionCoordinator(
            claudeMonitor: claudeMock,
            codexMonitor: codexMock,
            initialCodexEnabled: true
        )

        var lastReceived: [ClaudeSession] = []
        coordinator.onSessionsChanged = { sessions in
            lastReceived = sessions
        }
        coordinator.start()

        // 먼저 둘 다 emit
        claudeMock.emit([makeClaudeSession(source: .cli)])
        codexMock.emit([makeCodexSession()])

        // Codex OFF
        coordinator.setCodexEnabled(false)

        // OFF 직후 발행된 결과에 Codex 세션이 없어야 함 (AC-R6.6)
        let codexInResult = lastReceived.filter { $0.source == .codexCLI || $0.source == .codexVSCode }
        XCTAssertTrue(codexInResult.isEmpty,
                      "setCodexEnabled(false) 직후 첫 콜백에는 Codex 세션이 포함되지 않아야 한다")
        XCTAssertFalse(lastReceived.isEmpty,
                       "Claude 세션은 Codex 토글 OFF 후에도 남아 있어야 한다")
    }

    // MARK: - AC-R6.4: 토글 ON 재활성 후 Codex 다시 포함

    func test_codexEnabledRestart_emitsCodexAgain() {
        let claudeMock = MockMonitor()
        let codexMock = MockMonitor()
        let coordinator = SessionCoordinator(
            claudeMonitor: claudeMock,
            codexMonitor: codexMock,
            initialCodexEnabled: true
        )

        var lastReceived: [ClaudeSession] = []
        coordinator.onSessionsChanged = { sessions in
            lastReceived = sessions
        }
        coordinator.start()

        // 초기 emit
        claudeMock.emit([makeClaudeSession(source: .cli)])
        codexMock.emit([makeCodexSession()])

        // OFF → ON
        coordinator.setCodexEnabled(false)
        coordinator.setCodexEnabled(true)

        // Codex mock이 다시 start되었고, 다음 emit 시 결과에 포함되어야 함
        let codexSession = makeCodexSession()
        codexMock.emit([codexSession])

        let codexInResult = lastReceived.filter { $0.source == .codexCLI || $0.source == .codexVSCode }
        XCTAssertFalse(codexInResult.isEmpty,
                       "setCodexEnabled(true) 후 Codex 세션이 다시 onSessionsChanged에 포함되어야 한다")
    }

    // MARK: - 기본값: monitorCodexSessions는 true

    func test_initialCodexEnabled_defaultIsTrue() {
        let claudeMock = MockMonitor()
        let codexMock = MockMonitor()
        let coordinator = SessionCoordinator(
            claudeMonitor: claudeMock,
            codexMonitor: codexMock
        )

        coordinator.start()

        XCTAssertTrue(codexMock.started,
                      "initialCodexEnabled 기본값 true이므로 start() 시 Codex monitor가 start되어야 한다")
    }

    // MARK: - stop() 전파

    func test_stop_stopsAllMonitors() {
        let claudeMock = MockMonitor()
        let codexMock = MockMonitor()
        let coordinator = SessionCoordinator(
            claudeMonitor: claudeMock,
            codexMonitor: codexMock,
            initialCodexEnabled: true
        )
        coordinator.start()
        coordinator.stop()

        XCTAssertTrue(claudeMock.stopped, "stop() 호출 시 Claude monitor가 stop되어야 한다")
        XCTAssertTrue(codexMock.stopped, "stop() 호출 시 Codex monitor가 stop되어야 한다")
    }
}
