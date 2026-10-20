import XCTest
@testable import SoAgentBar

// PERF-006: resume/fork로 같은 이름의 서브에이전트 jsonl(`<parent>/subagents/agent-xxx.jsonl`)이
// 여러 부모 아래에 복제된다. 파일명만 ClaudeSession.id로 쓰면 서로 다른 서브에이전트의 id가 충돌해
// 다운스트림(AgentStore의 id 기반 상태/경과시간/SwiftUI identity)에서 섞인다.
// → 서브에이전트 id는 부모 세션 id로 한정해 유일하게, 최상위 세션 id(파일명 UUID)는 그대로 유지한다.

private final class StubMonitor: SessionMonitorProtocol {
    var onSessionsChanged: (([ClaudeSession]) -> Void)?
    private let sessionsToEmit: [ClaudeSession]?

    init(emitting sessions: [ClaudeSession]? = nil) {
        sessionsToEmit = sessions
    }

    func start() {
        if let sessionsToEmit { onSessionsChanged?(sessionsToEmit) }
    }
    func stop() {}
    func updatePollInterval(_ interval: Double) {}
}

final class SubagentSessionIdentityTests: XCTestCase {

    private var rootDir: URL!
    private var cliDir: URL!
    private var projectDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    private let parentA = "aaaaaaaa-0000-0000-0000-00000000000a"
    private let parentB = "bbbbbbbb-0000-0000-0000-00000000000b"
    private let duplicatedAgentId = "dup123"
    private var duplicatedStem: String { "agent-\(duplicatedAgentId)" }

    override func setUpWithError() throws {
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubagentSessionIdentityTests-\(UUID().uuidString)")
        cliDir = rootDir.appendingPathComponent("cli")
        projectDir = cliDir.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        suiteName = "SubagentSessionIdentityTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: rootDir)
        rootDir = nil
        cliDir = nil
        projectDir = nil
        defaults = nil
        suiteName = nil
    }

    // MARK: - Fixtures

    private func makeMonitor() -> ClaudeSessionMonitor {
        ClaudeSessionMonitor(
            cliProjectsDir: cliDir,
            xcodeProjectsDir: rootDir.appendingPathComponent("xcode"),
            desktopCodeSessionsDir: rootDir.appendingPathComponent("desktop"),
            coworkSessionsDir: rootDir.appendingPathComponent("cowork"),
            defaults: defaults
        )
    }

    private func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)! + "\n"
    }

    /// 상태가 .responded가 되도록 실제 현재 시각 근처의 timestamp 사용
    private func recentTimestamp(secondsAgo: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-secondsAgo))
    }

    private func assistantEndTurn(input: Int, output: Int, secondsAgo: Double) -> [String: Any] {
        [
            "type": "assistant",
            "timestamp": recentTimestamp(secondsAgo: secondsAgo),
            "message": [
                "role": "assistant",
                "model": "claude-opus-4-7",
                "stop_reason": "end_turn",
                "usage": ["input_tokens": input, "output_tokens": output],
                "content": [["type": "text", "text": "완료"]],
            ] as [String: Any],
        ]
    }

    /// 부모 세션: Agent spawn(tool_use) → tool_result(agentId 확정) → end_turn
    private func parentContents(agentType: String, description: String, input: Int, output: Int) -> String {
        let user: [String: Any] = [
            "type": "user",
            "timestamp": recentTimestamp(secondsAgo: 40),
            "cwd": "/tmp/proj",
            "message": ["role": "user", "content": "요청"],
        ]
        let spawn: [String: Any] = [
            "type": "assistant",
            "timestamp": recentTimestamp(secondsAgo: 35),
            "message": [
                "role": "assistant",
                "model": "claude-opus-4-7",
                "stop_reason": "tool_use",
                "usage": ["input_tokens": 0, "output_tokens": 0],
                "content": [[
                    "type": "tool_use", "id": "tu-1", "name": "Agent",
                    "input": ["subagent_type": agentType, "description": description],
                ] as [String: Any]],
            ] as [String: Any],
        ]
        let result: [String: Any] = [
            "type": "user",
            "timestamp": recentTimestamp(secondsAgo: 30),
            "toolUseResult": ["agentId": duplicatedAgentId, "agentType": agentType],
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tu-1"]]],
        ]
        return jsonLine(user) + jsonLine(spawn) + jsonLine(result)
            + jsonLine(assistantEndTurn(input: input, output: output, secondsAgo: 20))
    }

    private func subagentContents(input: Int, output: Int) -> String {
        let user: [String: Any] = [
            "type": "user",
            "timestamp": recentTimestamp(secondsAgo: 34),
            "cwd": "/tmp/proj",
            "message": ["role": "user", "content": "서브 작업"],
        ]
        return jsonLine(user) + jsonLine(assistantEndTurn(input: input, output: output, secondsAgo: 25))
    }

    /// 두 부모(A, B) 아래에 같은 이름(agent-dup123.jsonl)의 서브에이전트 jsonl을 만든다
    private func createDuplicatedSubagentFixture() throws {
        try parentContents(agentType: "explorer", description: "탐색 A", input: 1000, output: 100)
            .write(to: projectDir.appendingPathComponent("\(parentA).jsonl"), atomically: true, encoding: .utf8)
        try parentContents(agentType: "reviewer", description: "리뷰 B", input: 2000, output: 200)
            .write(to: projectDir.appendingPathComponent("\(parentB).jsonl"), atomically: true, encoding: .utf8)

        for (parent, tokens) in [(parentA, (10, 1)), (parentB, (50_000, 5_000))] {
            let subDir = projectDir.appendingPathComponent("\(parent)/subagents")
            try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
            try subagentContents(input: tokens.0, output: tokens.1)
                .write(to: subDir.appendingPathComponent("\(duplicatedStem).jsonl"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: - API 수준: 코디네이터 → AgentStore 에서 두 서브가 각자의 부모에 붙고 합계가 섞이지 않는다

    @MainActor
    func test_storeFromCoordinator_sameNamedSubagentsUnderDifferentParents_stayDistinctWithPerParentTotals() throws {
        try createDuplicatedSubagentFixture()
        let polled = makeMonitor().pollNow()

        let coordinator = SessionCoordinator(
            claudeMonitor: StubMonitor(emitting: polled),
            codexMonitor: StubMonitor(),
            initialCodexEnabled: false
        )
        var merged: [ClaudeSession] = []
        coordinator.onSessionsChanged = { merged = $0 }
        coordinator.start()

        XCTAssertEqual(Set(merged.map(\.id)).count, merged.count,
                       "코디네이터가 내보내는 세션 id는 서로 달라야 한다: \(merged.map(\.id))")

        let store = AgentStore()
        store.updateAgents(from: merged)

        let parents = Dictionary(uniqueKeysWithValues: store.agents.map { ($0.id, $0) })
        XCTAssertEqual(Set(parents.keys), [parentA, parentB], "최상위 에이전트 id는 부모 세션 UUID 그대로")

        let allIds = store.agents.flatMap { [$0.id] + $0.subagents.map(\.id) }
        XCTAssertEqual(Set(allIds).count, allIds.count, "부모/서브 전체 트리에서 에이전트 id가 유일해야 한다: \(allIds)")

        let a = try XCTUnwrap(parents[parentA])
        let b = try XCTUnwrap(parents[parentB])
        XCTAssertEqual(a.subagentCount, 1)
        XCTAssertEqual(b.subagentCount, 1)

        // 부모 매핑(subagentMeta) 기반 표시 이름 유지
        XCTAssertEqual(a.subagents.first?.name, "↳ explorer — 탐색 A")
        XCTAssertEqual(b.subagents.first?.name, "↳ reviewer — 리뷰 B")

        // 서브 토큰은 자기 것만, 부모 합계 = 부모 자신 + 자기 서브
        XCTAssertEqual(a.subagents.first?.totalTokens, 11)
        XCTAssertEqual(b.subagents.first?.totalTokens, 55_000)
        XCTAssertEqual(a.totalTokens, 1100 + 11)
        XCTAssertEqual(b.totalTokens, 2200 + 55_000)
    }

    // MARK: - 최소 재현: pollNow 결과에서 같은 이름의 서브에이전트 두 개가 서로 다른 id를 가진다

    func test_pollNow_sameNamedSubagentsUnderDifferentParents_haveDistinctIdsAndOwnTokens() throws {
        try createDuplicatedSubagentFixture()

        let sessions = makeMonitor().pollNow()
        let subs = sessions.filter(\.isSubagent)

        XCTAssertEqual(subs.count, 2)
        XCTAssertEqual(Set(subs.map(\.id)).count, 2, "같은 파일명이라도 부모가 다르면 id가 달라야 한다: \(subs.map(\.id))")

        let byParent = Dictionary(uniqueKeysWithValues: subs.map { ($0.parentSessionId ?? "", $0) })
        XCTAssertEqual(byParent[parentA]?.id, "\(parentA)/\(duplicatedStem)")
        XCTAssertEqual(byParent[parentB]?.id, "\(parentB)/\(duplicatedStem)")
        XCTAssertEqual(byParent[parentA]?.totalTokens, 11)
        XCTAssertEqual(byParent[parentB]?.totalTokens, 55_000)
    }

    // MARK: - 회귀: 최상위 세션 id(파일명 UUID)는 바뀌지 않는다 (sessionEmojis 등 영속 키 보존)

    func test_pollNow_topLevelSessionIds_remainFileStem() throws {
        try createDuplicatedSubagentFixture()

        let topLevel = makeMonitor().pollNow().filter { !$0.isSubagent }

        XCTAssertEqual(Set(topLevel.map(\.id)), [parentA, parentB])
        XCTAssertTrue(topLevel.allSatisfy { $0.parentSessionId == nil })
    }
}
