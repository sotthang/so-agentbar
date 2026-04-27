import XCTest
@testable import SoAgentBar

// MARK: - CodexSessionMonitorTests
// AC-R2.x, AC-R3.x 검증 (fixture 기반)
// RED: CodexSessionMonitor, SessionSource.codexCLI/codexVSCode 등 구현 심볼 없음 → 컴파일 에러 예상

final class CodexSessionMonitorTests: XCTestCase {

    var tempDir: URL!
    var monitor: CodexSessionMonitor!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexFixtureTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        monitor = CodexSessionMonitor(rolloutsRoot: tempDir)
    }

    override func tearDown() {
        monitor.stop()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Fixture 헬퍼

    private func fixtureURL(_ name: String) -> URL {
        // Bundle Resources phase 등록 없이도 동작하도록 소스 디렉토리 경로를 직접 사용.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Codex/\(name).jsonl")
    }

    private func copyFixture(_ name: String, intoDate date: String = "2026/04/27") -> URL {
        let dir = tempDir
            .appendingPathComponent(date, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = fixtureURL(name)
        let dst = dir.appendingPathComponent("rollout-\(name).jsonl")
        try! FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    // MARK: - AC-R3.1: session_meta originator=codex-tui → .codexCLI, cwd 반영

    func test_sessionMeta_codexTUI_setsSourceAndCwd() throws {
        let dst = copyFixture("task_complete")
        var sessions: [ClaudeSession] = []
        let exp = expectation(description: "onSessionsChanged called")
        monitor.onSessionsChanged = { s in
            sessions = s
            exp.fulfill()
        }
        monitor.start()
        wait(for: [exp], timeout: 5.0)

        guard let session = sessions.first else {
            XCTFail("No session found after parsing \(dst.lastPathComponent)")
            return
        }
        XCTAssertEqual(session.source, .codexCLI, "originator=codex-tui should map to .codexCLI")
        XCTAssertEqual(session.workingPath, "/tmp/codex-fixture")
    }

    // MARK: - AC-R3.2: originator=codex_vscode → .codexVSCode

    func test_sessionMeta_codexVSCode_mapsSource() throws {
        let vsCodeFixtureLine = """
        {"timestamp":"2026-04-27T07:31:28.396Z","type":"session_meta","payload":{"id":"fixture-vscode-0001","timestamp":"2026-04-27T07:31:23.000Z","cwd":"/tmp/codex-fixture","originator":"codex_vscode","cli_version":"0.125.0","source":"vscode","model_provider":"openai"}}
        """
        let dir = tempDir.appendingPathComponent("2026/04/27", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-vscode-fixture.jsonl")
        try! (vsCodeFixtureLine + "\n").write(to: file, atomically: true, encoding: .utf8)

        // 첫 콜백은 default(.codexCLI)일 수 있고, session_meta 파싱 후 .codexVSCode로 갱신됨.
        // 갱신된 콜백에서 fulfill.
        var sessions: [ClaudeSession] = []
        let exp = expectation(description: "onSessionsChanged with codexVSCode source")
        monitor.onSessionsChanged = { s in
            sessions = s
            if s.first?.source == .codexVSCode {
                exp.fulfill()
            }
        }
        monitor.start()
        wait(for: [exp], timeout: 5.0)

        guard let session = sessions.first else {
            XCTFail("No session found")
            return
        }
        XCTAssertEqual(session.source, .codexVSCode, "originator=codex_vscode should map to .codexVSCode")
    }

    // MARK: - AC-R3.3: turn_context model 갱신

    func test_turnContext_updatesCurrentModel() throws {
        copyFixture("task_complete")
        var sessions: [ClaudeSession] = []
        let exp = expectation(description: "session with model")
        monitor.onSessionsChanged = { s in
            if s.first?.currentModel.isEmpty == false {
                sessions = s
                exp.fulfill()
            }
        }
        monitor.start()
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(sessions.first?.currentModel, "gpt-5-codex",
                       "turn_context.model should update session.currentModel")
    }

    // MARK: - AC-R3.4: agent_message 500자 → lastAssistantText 200자 truncation

    func test_agentMessage_truncatesTextAt200() throws {
        let longMessage = String(repeating: "A", count: 500)
        let lines = """
        {"timestamp":"2026-04-27T07:31:28.396Z","type":"session_meta","payload":{"id":"fixture-trunc-001","timestamp":"2026-04-27T07:31:23.000Z","cwd":"/tmp/codex-fixture","originator":"codex-tui","cli_version":"0.125.0","source":"cli","model_provider":"openai"}}
        {"timestamp":"2026-04-27T07:31:28.400Z","type":"turn_context","payload":{"turn_id":"t1","cwd":"/tmp/codex-fixture","current_date":"2026-04-27","timezone":"UTC","approval_policy":"on-request","model":"gpt-5-codex"}}
        {"timestamp":"2026-04-27T07:31:30.000Z","type":"event_msg","payload":{"type":"agent_message","message":"\(longMessage)","phase":"final_answer","memory_citation":null}}
        """
        let dir = tempDir.appendingPathComponent("2026/04/27", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-trunc-test.jsonl")
        try! (lines + "\n").write(to: file, atomically: true, encoding: .utf8)

        var sessions: [ClaudeSession] = []
        let exp = expectation(description: "session with lastAssistantText")
        monitor.onSessionsChanged = { s in
            if s.first?.lastAssistantText.isEmpty == false {
                sessions = s
                exp.fulfill()
            }
        }
        monitor.start()
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(sessions.first?.lastAssistantText.count, 200,
                       "agent_message 500자 → lastAssistantText는 200자로 truncate")
    }

    // MARK: - AC-R3.5: user_message → lastEventType="user", lastToolUseTime=nil

    func test_userMessage_resetsLastEventType() throws {
        let lines = """
        {"timestamp":"2026-04-27T07:31:28.396Z","type":"session_meta","payload":{"id":"fixture-user-001","timestamp":"2026-04-27T07:31:23.000Z","cwd":"/tmp/codex-fixture","originator":"codex-tui","cli_version":"0.125.0","source":"cli","model_provider":"openai"}}
        {"timestamp":"2026-04-27T07:31:29.000Z","type":"event_msg","payload":{"type":"user_message","message":"do something","turn_id":"t1"}}
        """
        let dir = tempDir.appendingPathComponent("2026/04/27", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-user-msg.jsonl")
        try! (lines + "\n").write(to: file, atomically: true, encoding: .utf8)

        var sessions: [ClaudeSession] = []
        let exp = expectation(description: "session after user_message")
        monitor.onSessionsChanged = { s in
            if s.first?.lastEventType == "user" {
                sessions = s
                exp.fulfill()
            }
        }
        monitor.start()
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(sessions.first?.lastEventType, "user",
                       "user_message → lastEventType should be 'user'")
        XCTAssertNil(sessions.first?.lastToolUseTime,
                     "user_message → lastToolUseTime should be nil")
    }

    // MARK: - AC-R3.6: originator 누락 시 .codexCLI 기본값

    func test_missingOriginator_defaultsToCodexCLI() throws {
        let lines = """
        {"timestamp":"2026-04-27T07:31:28.396Z","type":"session_meta","payload":{"id":"fixture-noori-001","timestamp":"2026-04-27T07:31:23.000Z","cwd":"/tmp/codex-fixture","cli_version":"0.125.0","source":"cli","model_provider":"openai"}}
        """
        let dir = tempDir.appendingPathComponent("2026/04/27", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-no-originator.jsonl")
        try! (lines + "\n").write(to: file, atomically: true, encoding: .utf8)

        var sessions: [ClaudeSession] = []
        let exp = expectation(description: "session with default source")
        monitor.onSessionsChanged = { s in
            sessions = s
            exp.fulfill()
        }
        monitor.start()
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(sessions.first?.source, .codexCLI,
                       "originator 누락 시 .codexCLI를 기본값으로 사용해야 한다")
    }

    // MARK: - AC-R3.8: Codex invariant (isSubagent=false, etc.)

    func test_codexInvariant_isSubagentFalseAndNoPendingSpawns() throws {
        copyFixture("task_complete")
        var sessions: [ClaudeSession] = []
        let exp = expectation(description: "invariant check")
        monitor.onSessionsChanged = { s in
            sessions = s
            exp.fulfill()
        }
        monitor.start()
        wait(for: [exp], timeout: 5.0)

        guard let session = sessions.first else {
            XCTFail("No session to check invariants")
            return
        }
        XCTAssertFalse(session.isSubagent, "Codex session must have isSubagent=false")
        XCTAssertTrue(session.subagentMeta.isEmpty, "Codex session must have empty subagentMeta")
        XCTAssertNil(session.parentSessionId, "Codex session must have parentSessionId=nil")
        XCTAssertTrue(session.pendingAgentSpawns.isEmpty, "Codex session must have empty pendingAgentSpawns")
    }

    // MARK: - AC-R3.9: codexApprovalPolicy 추출

    func test_turnContext_extractsApprovalPolicy() throws {
        copyFixture("task_complete")
        var sessions: [ClaudeSession] = []
        let exp = expectation(description: "approval policy check")
        monitor.onSessionsChanged = { s in
            if s.first?.codexApprovalPolicy != nil {
                sessions = s
                exp.fulfill()
            }
        }
        monitor.start()
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(sessions.first?.codexApprovalPolicy, "on-request",
                       "codexApprovalPolicy는 turn_context.approval_policy 원본과 동일해야 한다")
    }

    // MARK: - AC-R3.10: token_count 덮어쓰기 (2회 이벤트 → 마지막 값 반영)

    func test_tokenCount_overridesPreviousValue() throws {
        copyFixture("token_count_with_info")
        var sessions: [ClaudeSession] = []
        let exp = expectation(description: "token override check")
        monitor.onSessionsChanged = { s in
            if let session = s.first, !session.tokensByModel.isEmpty {
                sessions = s
                exp.fulfill()
            }
        }
        monitor.start()
        wait(for: [exp], timeout: 5.0)

        guard let session = sessions.first else {
            XCTFail("No session found")
            return
        }
        // 마지막 token_count 이벤트의 값: input=33558, cachedInput=26880, output=63
        // 첫 번째 값(input=16768)이 합산되면 안 됨
        guard let usage = session.tokensByModel["gpt-5-codex"] else {
            XCTFail("tokensByModel에 gpt-5-codex가 없음")
            return
        }
        XCTAssertEqual(usage.input, 33558,
                       "두 번째(마지막) token_count의 input_tokens=33558이 반영되어야 한다(합산 X)")
        XCTAssertEqual(usage.cachedInput, 26880,
                       "두 번째(마지막) token_count의 cached_input_tokens=26880이 반영되어야 한다")
        XCTAssertEqual(usage.output, 63,
                       "두 번째(마지막) token_count의 output_tokens=63이 반영되어야 한다")
    }

    // MARK: - AC-R3.11: info=null token_count 무시

    func test_tokenCount_infoNullIgnored() throws {
        copyFixture("token_count_info_null")
        var sessions: [ClaudeSession] = []
        let exp = expectation(description: "info null ignored")
        monitor.onSessionsChanged = { s in
            sessions = s
            exp.fulfill()
        }
        monitor.start()
        wait(for: [exp], timeout: 5.0)

        let tokensByModel = sessions.first?.tokensByModel ?? [:]
        XCTAssertTrue(tokensByModel.isEmpty || tokensByModel.values.allSatisfy { $0.input == 0 && $0.output == 0 },
                      "info=null인 token_count 이벤트는 tokensByModel에 반영되지 않아야 한다")
    }

    // MARK: - AC-R3.12: model 도착 전 token_count → 보류 → 결합

    func test_tokenCount_beforeModel_pendingThenApplied() throws {
        copyFixture("token_count_before_model")
        var sessions: [ClaudeSession] = []
        let exp = expectation(description: "pending token applied")
        monitor.onSessionsChanged = { s in
            if let session = s.first,
               !session.tokensByModel.isEmpty {
                sessions = s
                exp.fulfill()
            }
        }
        monitor.start()
        wait(for: [exp], timeout: 5.0)

        guard let usage = sessions.first?.tokensByModel["gpt-5-codex"] else {
            XCTFail("turn_context.model 도착 후 보류된 token_count가 gpt-5-codex 키로 결합되어야 한다")
            return
        }
        XCTAssertEqual(usage.input, 5000, "보류 토큰 input=5000이 model 결합 후 반영되어야 한다")
        XCTAssertEqual(usage.output, 100, "보류 토큰 output=100이 model 결합 후 반영되어야 한다")
    }

    // MARK: - AC-R3.13: task_complete의 last_agent_message → lastAssistantText 200자

    func test_taskComplete_setsLastAssistantText() throws {
        copyFixture("task_complete")
        var sessions: [ClaudeSession] = []
        let exp = expectation(description: "task_complete assistant text")
        monitor.onSessionsChanged = { s in
            if s.first?.lastAssistantText.isEmpty == false {
                sessions = s
                exp.fulfill()
            }
        }
        monitor.start()
        wait(for: [exp], timeout: 5.0)

        let text = sessions.first?.lastAssistantText ?? ""
        // fixture task_complete.jsonl의 last_agent_message는 200자 이내이므로 그대로 반영
        XCTAssertFalse(text.isEmpty, "task_complete.last_agent_message가 lastAssistantText에 반영되어야 한다")
        XCTAssertLessThanOrEqual(text.count, 200, "lastAssistantText는 최대 200자 truncate 적용")
    }

    // MARK: - AC-R3.14: reasoning response_item은 lastEventType 갱신 안 함

    func test_reasoningOnly_doesNotChangeLastEventType() throws {
        copyFixture("reasoning_only")
        var sessions: [ClaudeSession] = []
        let exp = expectation(description: "reasoning does not update lastEventType")
        monitor.onSessionsChanged = { s in
            sessions = s
            exp.fulfill()
        }
        monitor.start()
        wait(for: [exp], timeout: 5.0)

        let lastEventType = sessions.first?.lastEventType ?? ""
        // reasoning_only fixture: session_meta → task_started → turn_context → response_item(reasoning)
        // lastEventType은 task_started로 설정 후 reasoning에서 갱신되면 안 됨
        XCTAssertNotEqual(lastEventType, "reasoning",
                          "response_item.reasoning은 lastEventType을 갱신해서는 안 된다")
        XCTAssertEqual(lastEventType, "task_started",
                       "reasoning 이벤트 이전 lastEventType(task_started)이 유지되어야 한다")
    }

    // MARK: - AC-R2.3: .zst 파일은 무시됨

    func test_zstFile_ignored() throws {
        let dir = tempDir.appendingPathComponent("2026/04/27", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zstFile = dir.appendingPathComponent("rollout-test.jsonl.zst")
        try! "dummy zst content".write(to: zstFile, atomically: true, encoding: .utf8)

        var sessions: [ClaudeSession] = []
        let exp = expectation(description: "zst ignored")
        exp.isInverted = true
        monitor.onSessionsChanged = { s in
            if s.contains(where: { $0.id.contains("zst") }) {
                exp.fulfill()
            }
        }
        monitor.start()
        wait(for: [exp], timeout: 2.0)

        XCTAssertTrue(sessions.isEmpty || !sessions.contains(where: { $0.id.contains("zst") }),
                      ".zst 파일은 세션 목록에 포함되지 않아야 한다")
    }

    // MARK: - AC-R2.4: 손상된 JSON 첫 줄 → 크래시 없이 스킵

    func test_corruptJsonl_skippedWithoutCrash() throws {
        let dir = tempDir.appendingPathComponent("2026/04/27", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-corrupt.jsonl")
        try! "{not json\n".write(to: file, atomically: true, encoding: .utf8)

        // 손상된 JSONL을 1초간 처리하게 두고, 그 사이 크래시 없으면 통과.
        // (invertedExpectation은 test runner에서 flaky하므로 명시적 fulfill로 변경)
        let exp = expectation(description: "monitor processed corrupt file without crash")
        monitor.onSessionsChanged = { _ in /* corrupt 줄은 skip되지만 publish는 일어날 수 있음 — 무시 */ }
        monitor.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3.0)
        monitor.stop()
        // 여기 도달 = 크래시 없이 끝남
        XCTAssertTrue(true, "손상된 JSONL 파일 처리 중 크래시가 발생해서는 안 된다")
    }

    // MARK: - AC-R2.5: 빈 파일 → 크래시 없음

    func test_emptyFile_noCrash() throws {
        let dir = tempDir.appendingPathComponent("2026/04/27", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-empty.jsonl")
        try! "".write(to: file, atomically: true, encoding: .utf8)

        let exp = expectation(description: "no crash on empty file")
        exp.isInverted = true
        monitor.onSessionsChanged = { _ in }
        monitor.start()
        wait(for: [exp], timeout: 2.0)
        // 크래시가 나지 않으면 통과
    }
}
