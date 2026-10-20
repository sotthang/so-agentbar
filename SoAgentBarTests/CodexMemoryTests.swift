import XCTest
@testable import SoAgentBar

// PERF-007: Codex 경로에도 Claude 모니터(PERF-001~003)와 같은 잠재 패턴이 있었다.
// - CodexSessionMonitor: 표시용 캐시(sessionID 키)와 오프셋(경로 키)이 어긋나 같은 파일명의 세션이 상태를 섞고,
//   폴링 요청이 병합되지 않으며, 큐가 작업 단위로 autorelease pool을 비우지 않았다.
// - CodexUsageAggregator: 폴링마다 24시간 내 모든 rollout 파일을 통째로 메모리에 읽어 줄 단위로 재파싱했다.

/// 읽기 기록을 공유하는 spy 레코더 (스레드 안전 — 폴링 큐와 테스트 스레드가 함께 쓴다)
private final class CodexReadRecorder {
    struct Read { let path: String; let offset: UInt64; let bytes: Int; let requested: Int }
    private let lock = NSLock()
    private var _reads: [Read] = []
    private var _openedPaths: [String] = []

    var reads: [Read] { lock.lock(); defer { lock.unlock() }; return _reads }
    var openedPaths: [String] { lock.lock(); defer { lock.unlock() }; return _openedPaths }
    var totalBytes: Int { reads.reduce(0) { $0 + $1.bytes } }

    func recordOpen(path: String) { lock.lock(); _openedPaths.append(path); lock.unlock() }
    func record(_ read: Read) { lock.lock(); _reads.append(read); lock.unlock() }
    func reset() { lock.lock(); _reads.removeAll(); _openedPaths.removeAll(); lock.unlock() }
}

/// 실제 파일을 읽되 읽은 바이트 수를 기록하는 spy ByteSource
private final class CodexSpyByteSource: ByteSource {
    private let inner: FileByteSource
    private let path: String
    private let recorder: CodexReadRecorder

    init?(url: URL, recorder: CodexReadRecorder) {
        guard let inner = FileByteSource(url: url) else { return nil }
        self.inner = inner
        self.path = url.path
        self.recorder = recorder
        recorder.recordOpen(path: url.path)
    }

    var size: UInt64 { inner.size }

    func read(from offset: UInt64, upTo count: Int) -> Data {
        let data = inner.read(from: offset, upTo: count)
        recorder.record(.init(path: path, offset: offset, bytes: data.count, requested: count))
        return data
    }
}

/// 첫 번째 읽기 원천 생성 시 폴링 스레드를 멈춰 세우는 게이트 (폴링 "진행 중" 상태 재현)
private final class CodexPollGate {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasBlocked = false

    func blockFirstCall() {
        lock.lock()
        let shouldBlock = !hasBlocked
        hasBlocked = true
        lock.unlock()
        guard shouldBlock else { return }
        entered.signal()
        _ = release.wait(timeout: .now() + 10)
    }
}

final class CodexMemoryTests: XCTestCase {

    private var rootDir: URL!
    private var recorder: CodexReadRecorder!
    private let fixedNow = Date()

    override func setUpWithError() throws {
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMemoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        recorder = CodexReadRecorder()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootDir)
        rootDir = nil
        recorder = nil
    }

    // MARK: - 공통 헬퍼

    private func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)! + "\n"
    }

    private func sessionMetaLine(cwd: String) -> String {
        jsonLine(["timestamp": "2026-10-20T01:00:00.000Z", "type": "session_meta",
                  "payload": ["id": UUID().uuidString, "cwd": cwd, "originator": "codex-tui"]])
    }

    private func turnContextLine(model: String, cwd: String = "/tmp",
                                 timestamp: String = "2026-10-20T01:00:01.000Z") -> String {
        jsonLine(["timestamp": timestamp, "type": "turn_context",
                  "payload": ["model": model, "cwd": cwd, "approval_policy": "on-request"]])
    }

    private func tokenCountLine(input: Int, output: Int, timestamp: String = "2026-10-20T01:00:02.000Z") -> String {
        jsonLine(["timestamp": timestamp, "type": "event_msg",
                  "payload": ["type": "token_count",
                              "info": ["total_token_usage": [
                                "input_tokens": input, "cached_input_tokens": input / 2,
                                "output_tokens": output, "reasoning_output_tokens": output / 3,
                              ]]]])
    }

    private func taskCompleteLine(message: String) -> String {
        jsonLine(["timestamp": "2026-10-20T01:00:03.000Z", "type": "event_msg",
                  "payload": ["type": "task_complete", "last_agent_message": message, "duration_ms": 1000]])
    }

    /// root/YYYY/MM/DD/rollout-{name}.jsonl 에 쓰고 mtime을 주입된 now 기준 최근으로 맞춘다
    @discardableResult
    private func writeRollout(
        root: URL, dateDir: String = "2026/10/20", name: String, contents: String,
        age: TimeInterval = 60
    ) throws -> URL {
        let dir = root.appendingPathComponent(dateDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout-\(name).jsonl")
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: fixedNow.addingTimeInterval(-age)],
                                              ofItemAtPath: url.path)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    // MARK: - CodexSessionMonitor

    private var sessionsRoot: URL { rootDir.appendingPathComponent("sessions") }

    private func makeMonitor(makeByteSource: ((URL) -> ByteSource?)? = nil) -> CodexSessionMonitor {
        let recorder = self.recorder!
        let now = fixedNow
        return CodexSessionMonitor(
            rolloutsRoot: sessionsRoot,
            now: { now },
            makeByteSource: makeByteSource ?? { CodexSpyByteSource(url: $0, recorder: recorder) }
        )
    }

    @discardableResult
    private func createCodexSessions(count: Int) throws -> [URL] {
        let padding = String(repeating: "x", count: 2000)
        return try (0..<count).map { i in
            try writeRollout(
                root: sessionsRoot, name: "s\(i)",
                contents: sessionMetaLine(cwd: "/tmp/codex-\(i)")
                    + turnContextLine(model: "gpt-5")
                    + tokenCountLine(input: 100 + i, output: 10 + i)
                    + taskCompleteLine(message: "완료 \(i) \(padding)"),
                age: Double(60 + i))
        }
    }

    private struct SessionDigest: Equatable {
        let id: String
        let workingPath: String
        let tokens: [String: ClaudeSession.TokenUsage]
        let lastEventType: String
        let lastAssistantText: String
        let lastActivity: Date
    }

    private func digest(_ sessions: [ClaudeSession]) -> [SessionDigest] {
        sessions.map {
            SessionDigest(id: $0.id, workingPath: $0.workingPath, tokens: $0.tokensByModel,
                          lastEventType: $0.lastEventType, lastAssistantText: $0.lastAssistantText,
                          lastActivity: $0.lastActivity)
        }.sorted { $0.id < $1.id }
    }

    func test_codexPollNow_with250Sessions_secondPollReadsZeroBytesAndKeepsResults() throws {
        try createCodexSessions(count: 250)
        let monitor = makeMonitor()

        let first = monitor.pollNow()
        XCTAssertEqual(first.count, 250)
        XCTAssertGreaterThan(recorder.totalBytes, 0, "첫 폴링은 모든 파일을 읽어야 한다")

        recorder.reset()
        let second = monitor.pollNow()

        XCTAssertEqual(recorder.totalBytes, 0, "변경 없는 파일을 다시 읽으면 안 된다 (재독 \(recorder.totalBytes)바이트)")
        XCTAssertTrue(recorder.reads.filter { $0.offset == 0 }.isEmpty, "오프셋 0부터 재독하면 안 된다")
        XCTAssertEqual(digest(second), digest(first), "두 폴링의 세션 결과는 동일해야 한다")
    }

    func test_codexPollNow_afterAppendingLine_readsOnlyNewBytes() throws {
        let urls = try createCodexSessions(count: 30)
        let monitor = makeMonitor()
        monitor.pollNow()

        let target = urls[7]
        let originalSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: target.path)[.size] as? UInt64)
        let appended = tokenCountLine(input: 9999, output: 99, timestamp: "2026-10-20T01:10:00.000Z")
        try append(appended, to: target)

        recorder.reset()
        let sessions = monitor.pollNow()

        XCTAssertEqual(recorder.reads.count, 1, "변경된 파일 하나만 읽어야 한다 (실제 \(recorder.reads.count)건)")
        XCTAssertEqual(recorder.reads.first?.offset, originalSize)
        XCTAssertEqual(recorder.totalBytes, Data(appended.utf8).count)
        XCTAssertEqual(sessions.first { $0.id == "s7" }?.tokensByModel["gpt-5"]?.input, 9999,
                       "새로 읽은 token_count가 반영되어야 한다")
    }

    /// 같은 파일명(=같은 세션 id)이 서로 다른 날짜 디렉토리에 있어도 파싱 상태는 파일(경로)별로 분리되어야 한다.
    /// sessionID 키 캐시는 한 파일의 누적 상태를 다른 파일에 덮어써, 오프셋은 유지된 채 엉뚱한 상태가 표시됐다.
    func test_codexPollNow_sameFileNameInTwoDateDirs_keepsParseStatePerFile() throws {
        try writeRollout(root: sessionsRoot, dateDir: "2026/10/19", name: "dup",
                         contents: sessionMetaLine(cwd: "/tmp/first")
                            + turnContextLine(model: "gpt-5", cwd: "/tmp/first")
                            + tokenCountLine(input: 111, output: 11)
                            + taskCompleteLine(message: "first done"))
        try writeRollout(root: sessionsRoot, dateDir: "2026/10/20", name: "dup",
                         contents: sessionMetaLine(cwd: "/tmp/second"))
        let monitor = makeMonitor()

        for poll in 1...2 {
            let sessions = monitor.pollNow()
            XCTAssertEqual(sessions.count, 2)
            let first = sessions.first { $0.workingPath == "/tmp/first" }
            let second = sessions.first { $0.workingPath == "/tmp/second" }
            XCTAssertNotNil(first, "폴링 \(poll): 첫 파일 상태가 유지되어야 한다")
            XCTAssertNotNil(second, "폴링 \(poll): 두 번째 파일 상태가 유지되어야 한다")
            XCTAssertEqual(first?.lastAssistantText, "first done")
            XCTAssertEqual(second?.lastAssistantText, "", "폴링 \(poll): 다른 파일의 상태가 섞이면 안 된다")
            XCTAssertTrue(second?.tokensByModel.isEmpty ?? false, "폴링 \(poll): 다른 파일의 토큰이 섞이면 안 된다")
        }
    }

    /// 오프셋 영속화는 캐시 미스 때마다 버려지는 죽은 상태였다 — 폴링마다 UserDefaults에 쓰지 않아야 한다
    func test_codexPollNow_doesNotPersistOffsetsToUserDefaults() throws {
        let urls = try createCodexSessions(count: 3)
        let monitor = makeMonitor()
        monitor.pollNow()

        let stored = UserDefaults.standard.data(forKey: "fileOffsets")
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        let leaked = stored.keys.filter { key in urls.contains { key.hasSuffix($0.lastPathComponent) } }
        XCTAssertTrue(leaked.isEmpty, "폴링이 fileOffsets에 Codex 오프셋을 기록했다: \(leaked)")
    }

    func test_codexRequestPoll_manyRequestsWhilePollInFlight_runAtMostOneExtraPoll() throws {
        try createCodexSessions(count: 1)
        let gate = CodexPollGate()
        let monitor = makeMonitor(makeByteSource: { url in
            gate.blockFirstCall()
            return FileByteSource(url: url)
        })
        let lock = NSLock()
        var pollCount = 0
        let twoPolls = expectation(description: "진행 중 폴링 + 병합된 1회")
        twoPolls.expectedFulfillmentCount = 2
        twoPolls.assertForOverFulfill = false
        monitor.onSessionsChanged = { _ in
            lock.lock(); pollCount += 1; lock.unlock()
            twoPolls.fulfill()
        }

        monitor.requestPoll()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success, "첫 폴링이 시작되어야 한다")

        for _ in 0..<50 { monitor.requestPoll() }
        gate.release.signal()

        wait(for: [twoPolls], timeout: 5)
        let settle = expectation(description: "추가 폴링 관찰")
        settle.isInverted = true
        wait(for: [settle], timeout: 1)

        lock.lock(); let count = pollCount; lock.unlock()
        XCTAssertEqual(count, 2, "진행 중 폴링 동안의 요청 50건은 1회로 병합되어야 한다 (실제 \(count)회)")

        let third = expectation(description: "유휴 후 새 요청")
        monitor.onSessionsChanged = { _ in third.fulfill() }
        monitor.requestPoll()
        wait(for: [third], timeout: 5)
    }

    // MARK: - CodexUsageAggregator

    private var usageRoot: URL { rootDir.appendingPathComponent("usage") }

    private func makeScanCache(chunkSize: Int = JSONLReader.defaultChunkSize) -> CodexUsageScanCache {
        let recorder = self.recorder!
        return CodexUsageScanCache(chunkSize: chunkSize,
                                   makeByteSource: { CodexSpyByteSource(url: $0, recorder: recorder) })
    }

    /// 기존 방식(파일 전체를 읽어 lastSnapshot) 기준값
    private func legacyAggregate(_ urls: [URL]) throws -> [String: ClaudeSession.TokenUsage] {
        var combined: [String: ClaudeSession.TokenUsage] = [:]
        for url in urls {
            for (model, t) in CodexUsageAggregator.lastSnapshot(jsonlData: try Data(contentsOf: url)) {
                let e = combined[model] ?? ClaudeSession.TokenUsage()
                combined[model] = ClaudeSession.TokenUsage(
                    input: e.input + t.input, cachedInput: e.cachedInput + t.cachedInput,
                    output: e.output + t.output, reasoningOutput: e.reasoningOutput + t.reasoningOutput)
            }
        }
        return combined
    }

    private func fixtureContents(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Codex/\(name).jsonl")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 골든: 픽스처 + 다중 모델/보류 토큰/끝 개행 없는 파일에서 기존 전체 읽기 방식과 결과가 같아야 한다
    func test_aggregate_withScanCache_matchesLegacyFullFileResultOnFixtures() throws {
        let fixtures = ["error_event", "reasoning_only", "task_complete", "task_started_after_complete",
                        "token_count_before_model", "token_count_info_null", "token_count_with_info"]
        var urls: [URL] = []
        for name in fixtures {
            urls.append(try writeRollout(root: usageRoot, name: name, contents: try fixtureContents(name)))
        }
        let multiModel = turnContextLine(model: "gpt-5") + tokenCountLine(input: 50, output: 100)
            + turnContextLine(model: "o4-mini") + tokenCountLine(input: 30, output: 60)
            + turnContextLine(model: "gpt-5") + tokenCountLine(input: 80, output: 160)
        urls.append(try writeRollout(root: usageRoot, name: "multi-model", contents: multiModel))
        let pendingThenOverride = tokenCountLine(input: 7, output: 7) + turnContextLine(model: "o4-mini")
            + turnContextLine(model: "gpt-5") + tokenCountLine(input: 9, output: 9)
        urls.append(try writeRollout(root: usageRoot, name: "pending", contents: pendingThenOverride))
        // 마지막 줄 끝에 개행이 없는 파일 (기존 방식은 마지막 줄도 집계했다)
        let noTrailingNewline = String((turnContextLine(model: "gpt-5") + tokenCountLine(input: 42, output: 4)).dropLast())
        urls.append(try writeRollout(root: usageRoot, name: "no-newline", contents: noTrailingNewline))

        let expected = try legacyAggregate(urls)
        XCTAssertFalse(expected.isEmpty)

        let cache = makeScanCache()
        let first = CodexUsageAggregator.aggregate(root: usageRoot, now: fixedNow, fileManager: .default, scanCache: cache)
        XCTAssertEqual(first, expected, "전체 읽기 방식과 같은 집계 결과여야 한다")
        let second = CodexUsageAggregator.aggregate(root: usageRoot, now: fixedNow, fileManager: .default, scanCache: cache)
        XCTAssertEqual(second, expected, "캐시된 결과도 같아야 한다")
    }

    /// 큰 파일도 한 번에 통째로 읽지 않고 청크 상한 이하로 나눠 읽어야 한다
    func test_aggregate_largeFile_readsInBoundedChunks() throws {
        var text = turnContextLine(model: "gpt-5")
        let padding = String(repeating: "p", count: 1000)
        for i in 0..<3000 {   // 약 3.3MB
            text += jsonLine(["timestamp": "2026-10-20T01:00:00.000Z", "type": "response_item",
                              "payload": ["type": "message", "role": "assistant", "content": "\(i) \(padding)"]])
            if i % 100 == 0 { text += tokenCountLine(input: i, output: i) }
        }
        text += tokenCountLine(input: 123_456, output: 789)
        let url = try writeRollout(root: usageRoot, name: "large", contents: text)
        let fileSize = Data(text.utf8).count

        let chunkSize = 64 * 1024
        let result = CodexUsageAggregator.aggregate(
            root: usageRoot, now: fixedNow, fileManager: .default, scanCache: makeScanCache(chunkSize: chunkSize))

        XCTAssertEqual(result, try legacyAggregate([url]))
        XCTAssertEqual(result["gpt-5"]?.input, 123_456)
        let maxRead = recorder.reads.map(\.bytes).max() ?? 0
        XCTAssertLessThanOrEqual(maxRead, chunkSize, "한 번에 읽는 바이트가 청크 상한(\(chunkSize))을 넘으면 안 된다 (\(maxRead))")
        XCTAssertLessThanOrEqual(recorder.totalBytes, fileSize, "파일 크기 이상을 읽으면 안 된다")
    }

    /// 변경 없는 파일은 다시 열지도 읽지도 않고, 덧붙은 파일은 새 바이트만 읽는다
    func test_aggregate_unchangedFilesNotRescanned_appendedFileReadsOnlyNewBytes() throws {
        var urls: [URL] = []
        for i in 0..<5 {
            urls.append(try writeRollout(root: usageRoot, name: "u\(i)",
                                         contents: turnContextLine(model: "gpt-5") + tokenCountLine(input: 10, output: 1)))
        }
        let cache = makeScanCache()
        _ = CodexUsageAggregator.aggregate(root: usageRoot, now: fixedNow, fileManager: .default, scanCache: cache)

        recorder.reset()
        let unchanged = CodexUsageAggregator.aggregate(root: usageRoot, now: fixedNow, fileManager: .default, scanCache: cache)
        XCTAssertTrue(recorder.openedPaths.isEmpty, "변경 없는 파일을 다시 열면 안 된다: \(recorder.openedPaths.count)건")
        XCTAssertEqual(recorder.totalBytes, 0)
        XCTAssertEqual(unchanged["gpt-5"]?.input, 50)

        let target = urls[2]
        let originalSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: target.path)[.size] as? UInt64)
        let appended = tokenCountLine(input: 1000, output: 100)
        try append(appended, to: target)
        try FileManager.default.setAttributes([.modificationDate: fixedNow.addingTimeInterval(-1)],
                                              ofItemAtPath: target.path)

        recorder.reset()
        let afterAppend = CodexUsageAggregator.aggregate(root: usageRoot, now: fixedNow, fileManager: .default, scanCache: cache)
        XCTAssertEqual(Set(recorder.openedPaths.map { URL(fileURLWithPath: $0).lastPathComponent }), [target.lastPathComponent])
        XCTAssertEqual(recorder.reads.first?.offset, originalSize, "덧붙은 위치부터 읽어야 한다")
        XCTAssertEqual(recorder.totalBytes, Data(appended.utf8).count)
        XCTAssertEqual(afterAppend["gpt-5"]?.input, 40 + 1000)
        XCTAssertEqual(afterAppend, try legacyAggregate(urls))
    }

    /// 24시간 윈도우를 벗어난 파일의 캐시 항목은 버려야 한다 (캐시 크기 = 윈도우 내 파일 수)
    func test_aggregate_filesLeavingWindow_areEvictedFromScanCache() throws {
        let keep = try writeRollout(root: usageRoot, name: "keep",
                                    contents: turnContextLine(model: "gpt-5") + tokenCountLine(input: 1, output: 1))
        let old = try writeRollout(root: usageRoot, name: "old",
                                   contents: turnContextLine(model: "gpt-5") + tokenCountLine(input: 2, output: 2))
        let cache = makeScanCache()
        _ = CodexUsageAggregator.aggregate(root: usageRoot, now: fixedNow, fileManager: .default, scanCache: cache)
        XCTAssertEqual(cache.cachedFileCount, 2)

        try FileManager.default.setAttributes([.modificationDate: fixedNow.addingTimeInterval(-90_000)],
                                              ofItemAtPath: old.path)
        let result = CodexUsageAggregator.aggregate(root: usageRoot, now: fixedNow, fileManager: .default, scanCache: cache)

        XCTAssertEqual(cache.cachedFileCount, 1, "윈도우 밖 파일의 캐시 항목이 남아 있다")
        XCTAssertEqual(result, try legacyAggregate([keep]))
    }
}
