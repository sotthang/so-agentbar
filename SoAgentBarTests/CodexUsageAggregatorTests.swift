import XCTest
@testable import SoAgentBar

/// Phase 1 — CodexUsageAggregator 순수 함수 단위 테스트.
/// AC-1.1: 세션별 마지막 스냅샷만 합산 (중간 스냅샷 중복 가산 금지)
/// AC-1.2: estimateInfo — 비용 추정 / 비용 추정 불가(gpt-5-codex 단가 0)
/// AC-1.4: 디렉토리 부재 시 needsSetup / 디렉토리 생성 안 함
/// AC-1.5: 24h 롤링 윈도우 경계 — 윈도우 밖 파일 제외
final class CodexUsageAggregatorTests: XCTestCase {

    // MARK: - 공통 헬퍼

    /// 임시 디렉토리에 YYYY/MM/DD/rollout-{id}.jsonl 경로로 파일을 쓰고 mtime을 세팅한다.
    @discardableResult
    private func writeJSONL(
        root: URL,
        dateDir: String,       // "2026/06/14"
        sessionID: String,
        content: String,
        modificationDate: Date,
        fm: FileManager = .default
    ) throws -> URL {
        let dir = dateDir.components(separatedBy: "/").reduce(root) { $0.appendingPathComponent($1) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("rollout-\(sessionID).jsonl")
        try content.data(using: .utf8)!.write(to: fileURL)
        try fm.setAttributes([.modificationDate: modificationDate], ofItemAtPath: fileURL.path)
        return fileURL
    }

    /// 단일 token_count 이벤트 JSONL 라인 생성.
    private func tokenCountLine(model: String, input: Int, output: Int, cached: Int = 0, reasoning: Int = 0) -> String {
        let payload: [String: Any] = [
            "total_token_usage": [
                "input_tokens": input,
                "output_tokens": output,
                "cached_input_tokens": cached,
                "reasoning_output_tokens": reasoning
            ]
        ]
        let outer: [String: Any] = [
            "type": "event_msg",
            "timestamp": "2026-06-14T10:00:00Z",
            "payload": [
                "type": "token_count",
                "info": payload
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: outer)
        return String(data: data, encoding: .utf8)!
    }

    /// turn_context 이벤트 JSONL 라인 생성 (model 설정용).
    private func turnContextLine(model: String) -> String {
        let outer: [String: Any] = [
            "type": "turn_context",
            "timestamp": "2026-06-14T10:00:00Z",
            "payload": ["model": model, "cwd": "/tmp"]
        ]
        let data = try! JSONSerialization.data(withJSONObject: outer)
        return String(data: data, encoding: .utf8)!
    }

    // MARK: - lastSnapshot: 중간 스냅샷 중복 가산 방지 (AC-1.1)

    func test_lastSnapshot_singleLine_returnsTokensForModel() {
        // 단일 token_count 이벤트 → 모델별 토큰 반환
        let content = """
        \(turnContextLine(model: "gpt-5"))
        \(tokenCountLine(model: "gpt-5", input: 100, output: 200))
        """
        let data = content.data(using: .utf8)!
        let snapshot = CodexUsageAggregator.lastSnapshot(jsonlData: data)
        // RED: 스텁은 빈 딕셔너리 반환 → 반드시 실패
        XCTAssertFalse(snapshot.isEmpty, "lastSnapshot은 토큰 데이터를 반환해야 한다")
        let tokens = snapshot["gpt-5"]
        XCTAssertNotNil(tokens, "gpt-5 모델의 토큰이 있어야 한다")
        XCTAssertEqual(tokens?.input, 100)
        XCTAssertEqual(tokens?.output, 200)
    }

    func test_lastSnapshot_multipleSnapshots_usesLastNotSum() {
        // 같은 세션에 여러 스냅샷 → 마지막 스냅샷만 사용 (누적 X)
        // snapshot1: input=100, output=200
        // snapshot2: input=150, output=300 (마지막 — 이 값이 와야 함)
        let content = """
        \(turnContextLine(model: "gpt-5"))
        \(tokenCountLine(model: "gpt-5", input: 100, output: 200))
        \(tokenCountLine(model: "gpt-5", input: 150, output: 300))
        """
        let data = content.data(using: .utf8)!
        let snapshot = CodexUsageAggregator.lastSnapshot(jsonlData: data)
        // RED: 스텁은 빈 딕셔너리 반환
        let tokens = snapshot["gpt-5"]
        XCTAssertNotNil(tokens)
        // 합산(100+150=250)이 아닌 마지막(150)이어야 함
        XCTAssertEqual(tokens?.input, 150,
                       "중간 스냅샷을 합산하면 안 됨 — 마지막 스냅샷(input=150)을 써야 한다")
        XCTAssertEqual(tokens?.output, 300)
    }

    func test_lastSnapshot_multipleModels_eachLastSnapshot() {
        // gpt-5: 스냅샷 2번, o4-mini: 스냅샷 1번
        let content = """
        \(turnContextLine(model: "gpt-5"))
        \(tokenCountLine(model: "gpt-5", input: 50, output: 100))
        \(tokenContextLineSwitchModel(model: "o4-mini"))
        \(tokenCountLine(model: "o4-mini", input: 30, output: 60))
        \(turnContextLine(model: "gpt-5"))
        \(tokenCountLine(model: "gpt-5", input: 80, output: 160))
        """
        let data = content.data(using: .utf8)!
        let snapshot = CodexUsageAggregator.lastSnapshot(jsonlData: data)
        // RED
        XCTAssertEqual(snapshot["gpt-5"]?.input, 80, "gpt-5 마지막 스냅샷은 input=80이어야 한다")
        XCTAssertEqual(snapshot["o4-mini"]?.input, 30)
    }

    func test_lastSnapshot_emptyData_returnsEmpty() {
        let data = Data()
        let snapshot = CodexUsageAggregator.lastSnapshot(jsonlData: data)
        XCTAssertTrue(snapshot.isEmpty)
    }

    // MARK: - aggregate: 세션 간 마지막 스냅샷 합산 (AC-1.1)

    func test_aggregate_twoSessions_sumsLastSnapshots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex_agg_test_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        // 세션 A: input=100, output=200
        let sessionAContent = """
        \(turnContextLine(model: "gpt-5"))
        \(tokenCountLine(model: "gpt-5", input: 50, output: 100))
        \(tokenCountLine(model: "gpt-5", input: 100, output: 200))
        """
        // 세션 B: input=300, output=400
        let sessionBContent = """
        \(turnContextLine(model: "gpt-5"))
        \(tokenCountLine(model: "gpt-5", input: 300, output: 400))
        """
        try writeJSONL(root: root, dateDir: "2026/06/14", sessionID: "aaa",
                       content: sessionAContent, modificationDate: now)
        try writeJSONL(root: root, dateDir: "2026/06/14", sessionID: "bbb",
                       content: sessionBContent, modificationDate: now)

        let result = CodexUsageAggregator.aggregate(root: root, now: now, fileManager: .default)

        // RED: 스텁은 빈 딕셔너리 반환
        // 세션 A 마지막(input=100) + 세션 B 마지막(input=300) = 합계 input=400
        XCTAssertFalse(result.isEmpty, "두 세션의 합산 결과가 있어야 한다")
        XCTAssertEqual(result["gpt-5"]?.input, 400,
                       "세션별 마지막 스냅샷 합산: 100+300=400")
        XCTAssertEqual(result["gpt-5"]?.output, 600,
                       "세션별 마지막 스냅샷 합산: 200+400=600")
    }

    func test_aggregate_singleSession_multipleSnapshots_noDoubleCount() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex_agg_test_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        // 한 세션에 스냅샷 3번 — 마지막(input=300)만 카운트돼야 함
        let content = """
        \(turnContextLine(model: "gpt-5"))
        \(tokenCountLine(model: "gpt-5", input: 100, output: 200))
        \(tokenCountLine(model: "gpt-5", input: 200, output: 300))
        \(tokenCountLine(model: "gpt-5", input: 300, output: 400))
        """
        try writeJSONL(root: root, dateDir: "2026/06/15", sessionID: "single",
                       content: content, modificationDate: now)

        let result = CodexUsageAggregator.aggregate(root: root, now: now, fileManager: .default)

        // RED
        XCTAssertEqual(result["gpt-5"]?.input, 300,
                       "중간 스냅샷 합산(600)이 아닌 마지막 스냅샷(300)만 집계돼야 한다")
    }

    // MARK: - discoverRolloutFiles: 24h 롤링 윈도우 (AC-1.5)

    func test_discoverRolloutFiles_withinWindow_included() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex_discover_test_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let recentMod = now.addingTimeInterval(-3600)  // 1시간 전 — 24h 이내
        try writeJSONL(root: root, dateDir: "2026/06/15", sessionID: "recent",
                       content: "{}", modificationDate: recentMod)

        let files = CodexUsageAggregator.discoverRolloutFiles(root: root, now: now, fileManager: .default)

        // RED: 스텁은 빈 배열 반환
        XCTAssertEqual(files.count, 1, "24h 이내 파일은 포함돼야 한다")
    }

    func test_discoverRolloutFiles_outsideWindow_excluded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex_discover_test_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let oldMod = now.addingTimeInterval(-86401)  // 24h+1초 전 — 윈도우 밖
        try writeJSONL(root: root, dateDir: "2026/06/14", sessionID: "old",
                       content: "{}", modificationDate: oldMod)

        let files = CodexUsageAggregator.discoverRolloutFiles(root: root, now: now, fileManager: .default)

        // RED
        XCTAssertEqual(files.count, 0, "24h 윈도우 밖 파일은 제외돼야 한다")
    }

    func test_discoverRolloutFiles_exactBoundary_excluded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex_discover_boundary_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        // 정확히 86400초 전 → 제외 (<86400 조건)
        let boundaryMod = now.addingTimeInterval(-86400)
        try writeJSONL(root: root, dateDir: "2026/06/14", sessionID: "boundary",
                       content: "{}", modificationDate: boundaryMod)

        let files = CodexUsageAggregator.discoverRolloutFiles(root: root, now: now, fileManager: .default)
        // now.timeIntervalSince(mod) < 86400 → 86400 < 86400 = false → 제외
        XCTAssertEqual(files.count, 0, "정확히 86400초 전 파일은 윈도우 밖으로 제외돼야 한다")
    }

    func test_discoverRolloutFiles_zstIgnored() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex_zst_test_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let recentMod = now.addingTimeInterval(-100)

        // .jsonl 파일
        let dir = root.appendingPathComponent("2026/06/15")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jsonlURL = dir.appendingPathComponent("rollout-abc.jsonl")
        let zstURL = dir.appendingPathComponent("rollout-abc.jsonl.zst")
        try "{}".data(using: .utf8)!.write(to: jsonlURL)
        try "{}".data(using: .utf8)!.write(to: zstURL)
        try FileManager.default.setAttributes([.modificationDate: recentMod], ofItemAtPath: jsonlURL.path)
        try FileManager.default.setAttributes([.modificationDate: recentMod], ofItemAtPath: zstURL.path)

        let files = CodexUsageAggregator.discoverRolloutFiles(root: root, now: now, fileManager: .default)

        // RED
        XCTAssertFalse(files.contains(where: { $0.pathExtension == "zst" }),
                       ".zst 파일은 무시돼야 한다")
    }

    func test_discoverRolloutFiles_missingRoot_returnsEmpty() {
        let missing = URL(fileURLWithPath: "/nonexistent/path/\(UUID().uuidString)")
        let files = CodexUsageAggregator.discoverRolloutFiles(root: missing, now: Date(), fileManager: .default)
        XCTAssertTrue(files.isEmpty, "root가 없으면 빈 배열이어야 한다")
    }

    func test_discoverRolloutFiles_doesNotCreateDirectory() {
        let nonExistentRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex_no_create_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: nonExistentRoot) }

        _ = CodexUsageAggregator.discoverRolloutFiles(root: nonExistentRoot, now: Date(), fileManager: .default)

        XCTAssertFalse(FileManager.default.fileExists(atPath: nonExistentRoot.path),
                       "discoverRolloutFiles는 디렉토리를 생성하면 안 된다 (R1.5)")
    }

    // MARK: - estimateInfo: 비용 추정 (AC-1.2)

    func test_estimateInfo_gpt5_calculatesCost() {
        // gpt-5: input $1.25/MT, output $10/MT
        let tokens: [String: ClaudeSession.TokenUsage] = [
            "gpt-5": ClaudeSession.TokenUsage(input: 1_000_000, cachedInput: 0, output: 100_000, reasoningOutput: 0)
        ]
        let info = CodexUsageAggregator.estimateInfo(from: tokens, windowHours: 24)

        // RED: 스텁은 totalTokens=0, costDollars=nil 반환
        XCTAssertEqual(info.windowHours, 24)
        XCTAssertEqual(info.totalTokens, 1_100_000,
                       "총 토큰은 input+output의 합이어야 한다")
        XCTAssertNotNil(info.costDollars,
                        "gpt-5는 단가가 있으므로 비용이 계산돼야 한다")
        // gpt-5: 1M input * $1.25 + 0.1M output * $10 = $1.25 + $1.00 = $2.25
        XCTAssertEqual(info.costDollars!, 2.25, accuracy: 0.001)
    }

    func test_estimateInfo_gpt5codex_costIsNil() {
        // gpt-5-codex: 단가 0 → 비용 nil → isCostUnavailable=true (AC-1.2)
        let tokens: [String: ClaudeSession.TokenUsage] = [
            "gpt-5-codex": ClaudeSession.TokenUsage(input: 10000, cachedInput: 0, output: 5000, reasoningOutput: 0)
        ]
        let info = CodexUsageAggregator.estimateInfo(from: tokens, windowHours: 24)

        // RED
        XCTAssertEqual(info.totalTokens, 15000)
        XCTAssertNil(info.costDollars,
                     "gpt-5-codex는 단가 0이므로 costDollars는 nil이어야 한다 (C3)")
        XCTAssertTrue(info.isCostUnavailable,
                      "costDollars==nil이고 totalTokens>0이므로 isCostUnavailable=true")
    }

    func test_estimateInfo_emptyTokens_returnsZero() {
        let info = CodexUsageAggregator.estimateInfo(from: [:], windowHours: 24)
        XCTAssertEqual(info.totalTokens, 0)
        XCTAssertNil(info.costDollars)
        XCTAssertFalse(info.isCostUnavailable, "토큰이 없으면 isCostUnavailable=false")
    }

    func test_estimateInfo_mixedModels_partialCost() {
        // gpt-5(비용 있음) + gpt-5-codex(비용 없음) 혼합
        // → gpt-5 비용만 합산, costDollars != nil
        let tokens: [String: ClaudeSession.TokenUsage] = [
            "gpt-5": ClaudeSession.TokenUsage(input: 1_000_000, cachedInput: 0, output: 0, reasoningOutput: 0),
            "gpt-5-codex": ClaudeSession.TokenUsage(input: 5000, cachedInput: 0, output: 2000, reasoningOutput: 0)
        ]
        let info = CodexUsageAggregator.estimateInfo(from: tokens, windowHours: 24)

        // RED
        XCTAssertEqual(info.totalTokens, 1_007_000, "gpt-5(1M) + gpt-5-codex(7k) = 1,007,000")
        XCTAssertNotNil(info.costDollars,
                        "gpt-5 비용은 계산 가능하므로 부분 비용이 있어야 한다")
        XCTAssertFalse(info.isCostUnavailable,
                       "일부 모델이라도 비용 산출 가능하면 isCostUnavailable=false")
    }

    // MARK: - buildUsage: 데이터 없음 상태 (AC-1.4)

    func test_buildUsage_missingDirectory_returnsNeedsSetup() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        let usage = CodexUsageAggregator.buildUsage(root: missing, now: Date(), fileManager: .default)

        // RED: 스텁은 .loading 반환
        XCTAssertEqual(usage.id, .codex)
        XCTAssertEqual(usage.state, .needsSetup,
                       "디렉토리 부재 시 .needsSetup이어야 한다 (R1.5, AC-1.4)")
        XCTAssertTrue(usage.isEstimate)
    }

    func test_buildUsage_missingDirectory_doesNotCreateDirectory() {
        let nonExistent = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex_build_usage_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: nonExistent) }

        _ = CodexUsageAggregator.buildUsage(root: nonExistent, now: Date(), fileManager: .default)

        XCTAssertFalse(FileManager.default.fileExists(atPath: nonExistent.path),
                       "buildUsage는 디렉토리를 생성하면 안 된다 (R1.5)")
    }

    func test_buildUsage_noFilesIn24hWindow_returnsNeedsSetup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex_empty_window_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        // 24h 밖 파일만 있음
        try writeJSONL(root: root, dateDir: "2026/06/14", sessionID: "old",
                       content: "{}", modificationDate: now.addingTimeInterval(-90000))

        let usage = CodexUsageAggregator.buildUsage(root: root, now: now, fileManager: .default)

        // RED
        XCTAssertEqual(usage.state, .needsSetup,
                       "24h 윈도우 내 파일이 없으면 .needsSetup이어야 한다")
    }

    func test_buildUsage_withValidData_returnsDataState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex_valid_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let content = """
        \(turnContextLine(model: "gpt-5"))
        \(tokenCountLine(model: "gpt-5", input: 1000, output: 500))
        """
        try writeJSONL(root: root, dateDir: "2026/06/15", sessionID: "valid",
                       content: content, modificationDate: now.addingTimeInterval(-60))

        let usage = CodexUsageAggregator.buildUsage(root: root, now: now, fileManager: .default)

        // RED
        XCTAssertEqual(usage.state, .data, "유효 데이터가 있으면 .data 상태여야 한다")
        XCTAssertTrue(usage.isEstimate, "Codex는 항상 isEstimate=true여야 한다 (AC-1.3)")
        XCTAssertNotNil(usage.estimate)
        XCTAssertEqual(usage.estimate?.windowHours, 24)
    }

    // MARK: - 헬퍼 (turn_context 모델 전환)

    private func tokenContextLineSwitchModel(model: String) -> String {
        let outer: [String: Any] = [
            "type": "turn_context",
            "timestamp": "2026-06-14T11:00:00Z",
            "payload": ["model": model, "cwd": "/tmp"]
        ]
        let data = try! JSONSerialization.data(withJSONObject: outer)
        return String(data: data, encoding: .utf8)!
    }
}
