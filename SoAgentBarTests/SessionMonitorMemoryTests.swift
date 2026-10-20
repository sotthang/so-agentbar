import XCTest
@testable import SoAgentBar

// PERF-001: 활성 세션이 200개를 넘으면 sessionCache 상한(200→150) 정리로 쫓겨난 세션이
// 다음 폴링에서 캐시 미스로 판정되어 fileOffset이 리셋되고 오프셋 0부터 전체 재파싱되었다.
// (실사용 데이터: 232개 세션, 폴링마다 3.26GB 재독 → CPU/메모리 무한 증가)

/// 읽기 기록을 공유하는 spy 레코더
private final class ReadRecorder {
    struct Read { let path: String; let offset: UInt64; let bytes: Int }
    private(set) var reads: [Read] = []

    func record(path: String, offset: UInt64, bytes: Int) {
        reads.append(Read(path: path, offset: offset, bytes: bytes))
    }

    func reset() { reads.removeAll() }

    var totalBytes: Int { reads.reduce(0) { $0 + $1.bytes } }
}

/// 실제 파일을 읽되 읽은 바이트 수를 기록하는 spy ByteSource
private final class SpyByteSource: ByteSource {
    private let inner: FileByteSource
    private let path: String
    private let recorder: ReadRecorder

    init?(url: URL, recorder: ReadRecorder) {
        guard let inner = FileByteSource(url: url) else { return nil }
        self.inner = inner
        self.path = url.path
        self.recorder = recorder
    }

    var size: UInt64 { inner.size }

    func read(from offset: UInt64, upTo count: Int) -> Data {
        let data = inner.read(from: offset, upTo: count)
        recorder.record(path: path, offset: offset, bytes: data.count)
        return data
    }
}

// PERF-003: 폴링이 폴백 간격(30초)보다 오래 걸리면 타이머/FSEvents 요청이 직렬 큐에 계속 쌓여
// 워커 스레드가 쉬지 못하고, 스레드 단위 autorelease pool이 비워지지 않아 파일 Data와
// JSON 트리가 전부 살아남았다. → 진행 중인 폴링이 있으면 요청을 병합(최대 1회 추가)한다.

/// 첫 번째 읽기 원천 생성 시 폴링 스레드를 멈춰 세우는 게이트 (폴링 "진행 중" 상태 재현)
private final class PollGate {
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

final class SessionMonitorMemoryTests: XCTestCase {

    private var rootDir: URL!
    private var cliDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var recorder: ReadRecorder!
    private let fixedNow = Date()

    override func setUpWithError() throws {
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionMonitorMemoryTests-\(UUID().uuidString)")
        cliDir = rootDir.appendingPathComponent("cli")
        try FileManager.default.createDirectory(at: cliDir, withIntermediateDirectories: true)
        suiteName = "SessionMonitorMemoryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        recorder = ReadRecorder()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: rootDir)
        rootDir = nil
        cliDir = nil
        defaults = nil
        suiteName = nil
        recorder = nil
    }

    // MARK: - Fixtures

    private func makeMonitor() -> ClaudeSessionMonitor {
        let recorder = self.recorder!
        let now = fixedNow
        return ClaudeSessionMonitor(
            cliProjectsDir: cliDir,
            xcodeProjectsDir: rootDir.appendingPathComponent("xcode"),
            desktopCodeSessionsDir: rootDir.appendingPathComponent("desktop"),
            coworkSessionsDir: rootDir.appendingPathComponent("cowork"),
            defaults: defaults,
            now: { now },
            makeByteSource: { SpyByteSource(url: $0, recorder: recorder) }
        )
    }

    private func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)! + "\n"
    }

    /// 최소한의 유효한 Claude 세션 이벤트(user → assistant end_turn → ai-title), 수 KB 크기
    private func sessionContents(index: Int, cwd: String) -> String {
        let padding = String(repeating: "x", count: 2000)
        let user: [String: Any] = [
            "type": "user",
            "timestamp": "2026-10-20T01:00:00.000Z",
            "cwd": cwd,
            "permissionMode": "default",
            "message": ["role": "user", "content": "요청 \(index) \(padding)"],
        ]
        let assistant: [String: Any] = [
            "type": "assistant",
            "timestamp": "2026-10-20T01:00:05.000Z",
            "message": [
                "role": "assistant",
                "model": "claude-opus-4-7",
                "stop_reason": "end_turn",
                "usage": ["input_tokens": 100 + index, "output_tokens": 10 + index],
                "content": [["type": "text", "text": "응답 \(index) \(padding)"]],
            ] as [String: Any],
        ]
        let title: [String: Any] = ["type": "ai-title", "title": "세션 \(index)"]
        return jsonLine(user) + jsonLine(assistant) + jsonLine(title)
    }

    /// 프로젝트 폴더 10개에 걸쳐 `count`개 세션 JSONL 생성 (mtime은 주입된 now 기준 24시간 이내)
    @discardableResult
    private func createSessions(count: Int) throws -> [URL] {
        var urls: [URL] = []
        for i in 0..<count {
            let projectDir = cliDir.appendingPathComponent("-tmp-project-\(i % 10)")
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let url = projectDir.appendingPathComponent("\(UUID().uuidString).jsonl")
            try sessionContents(index: i, cwd: "/tmp/project-\(i % 10)")
                .write(to: url, atomically: true, encoding: .utf8)
            let mtime = fixedNow.addingTimeInterval(-Double(60 + i * 10))
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
            urls.append(url)
        }
        return urls
    }

    private struct Snapshot: Equatable {
        let id: String
        let totalTokens: Int
        let title: String?
        let lastEventType: String
        let lastActivity: Date
        let workingPath: String
        let permissionMode: String
    }

    private func snapshot(_ sessions: [ClaudeSession]) -> [Snapshot] {
        sessions.map {
            Snapshot(id: $0.id, totalTokens: $0.totalTokens, title: $0.title,
                     lastEventType: $0.lastEventType, lastActivity: $0.lastActivity,
                     workingPath: $0.workingPath, permissionMode: $0.permissionMode)
        }.sorted { $0.id < $1.id }
    }

    // MARK: - API 수준: 250개 세션 두 번 폴링 → 두 번째는 0바이트 읽기

    func test_pollNow_with250ActiveSessions_secondPollReadsZeroBytesAndKeepsResults() throws {
        try createSessions(count: 250)
        let monitor = makeMonitor()

        let first = monitor.pollNow()
        XCTAssertEqual(first.count, 250)
        XCTAssertGreaterThan(recorder.totalBytes, 0, "첫 폴링은 모든 파일을 읽어야 한다")

        recorder.reset()
        let second = monitor.pollNow()

        XCTAssertEqual(recorder.totalBytes, 0,
                       "변경 없는 파일은 두 번째 폴링에서 다시 읽으면 안 된다 (재독 \(recorder.totalBytes)바이트)")
        XCTAssertEqual(second.count, 250)
        XCTAssertEqual(snapshot(second), snapshot(first), "두 폴링의 세션 결과(토큰/제목 등)는 동일해야 한다")
    }

    // MARK: - 최소 재현: 201개 세션 → 두 번째 폴링에서 오프셋 0 재독 없음

    func test_pollNow_with201Sessions_secondPollNeverRereadsFromOffsetZero() throws {
        try createSessions(count: 201)
        let monitor = makeMonitor()

        monitor.pollNow()
        recorder.reset()
        monitor.pollNow()

        let rereads = recorder.reads.filter { $0.offset == 0 }
        XCTAssertTrue(rereads.isEmpty, "오프셋 0부터 재독된 파일 \(rereads.count)개")
    }

    // MARK: - 한 파일에 줄 추가 → 그 파일의 새 바이트만 읽음

    func test_pollNow_afterAppendingLineToOneFile_readsOnlyThatFilesNewBytes() throws {
        let urls = try createSessions(count: 250)
        let monitor = makeMonitor()
        monitor.pollNow()

        let target = urls[0]
        let originalSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: target.path)[.size] as? UInt64)
        let appended = jsonLine([
            "type": "user",
            "timestamp": "2026-10-20T01:10:00.000Z",
            "message": ["role": "user", "content": "추가 요청"],
        ])
        let handle = try FileHandle(forWritingTo: target)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        recorder.reset()
        monitor.pollNow()

        XCTAssertEqual(recorder.reads.count, 1, "변경된 파일 하나만 읽어야 한다 (실제 \(recorder.reads.count)건)")
        XCTAssertEqual(recorder.reads.first.map { URL(fileURLWithPath: $0.path).lastPathComponent }, target.lastPathComponent)
        XCTAssertEqual(recorder.reads.first?.offset, originalSize)
        XCTAssertEqual(recorder.totalBytes, Data(appended.utf8).count)
    }

    // MARK: - PERF-003: 폴링 요청 병합

    func test_requestPoll_manyRequestsWhilePollInFlight_runAtMostOneExtraPoll() throws {
        try createSessions(count: 1)
        let gate = PollGate()
        let now = fixedNow
        let monitor = ClaudeSessionMonitor(
            cliProjectsDir: cliDir,
            xcodeProjectsDir: rootDir.appendingPathComponent("xcode"),
            desktopCodeSessionsDir: rootDir.appendingPathComponent("desktop"),
            coworkSessionsDir: rootDir.appendingPathComponent("cowork"),
            defaults: defaults,
            now: { now },
            makeByteSource: { url in
                gate.blockFirstCall()
                return FileByteSource(url: url)
            }
        )
        var pollCount = 0
        let twoPolls = expectation(description: "진행 중 폴링 + 병합된 1회")
        twoPolls.expectedFulfillmentCount = 2
        twoPolls.assertForOverFulfill = false
        monitor.onSessionsChanged = { _ in
            pollCount += 1
            twoPolls.fulfill()
        }

        monitor.requestPoll()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success, "첫 폴링이 시작되어야 한다")

        for _ in 0..<50 { monitor.requestPoll() }
        gate.release.signal()

        wait(for: [twoPolls], timeout: 5)
        // 더 들어오는 폴링이 없는지 잠시 관찰
        let settle = expectation(description: "추가 폴링 관찰")
        settle.isInverted = true
        wait(for: [settle], timeout: 1)

        XCTAssertEqual(pollCount, 2, "진행 중 폴링 동안의 요청 50건은 1회로 병합되어야 한다 (실제 \(pollCount)회)")

        // 병합 상태가 해제되어 이후 요청은 다시 폴링되어야 한다
        let third = expectation(description: "유휴 후 새 요청")
        monitor.onSessionsChanged = { _ in third.fulfill() }
        monitor.requestPoll()
        wait(for: [third], timeout: 5)
    }

    // MARK: - PERF-003: 줄 단위 autorelease pool

    /// 한 줄 처리 중 생성된 autorelease 객체는 다음 줄로 넘어가기 전에 해제되어야 한다.
    /// (줄 루프에 autoreleasepool이 없으면 호출자의 pool이 비워질 때까지 모든 줄의 객체가 살아남는다)
    func test_readCompleteLines_releasesAutoreleasedObjectsPerLine() throws {
        let url = rootDir.appendingPathComponent("lines.jsonl")
        let text = (0..<20).map { jsonLine(["type": "user", "index": $0]) }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
        let source = try XCTUnwrap(FileByteSource(url: url))

        weak var previous: NSObject?
        var survivedLines = 0
        autoreleasepool {
            _ = JSONLReader.readCompleteLines(from: source, startingAt: 0) { _ in
                if previous != nil { survivedLines += 1 }
                // 줄마다 autorelease 객체 하나를 만들어 pool에 맡긴다
                let marker = NSObject()
                previous = Unmanaged.passRetained(marker).autorelease().takeUnretainedValue()
            }
        }
        XCTAssertEqual(survivedLines, 0, "이전 줄의 autorelease 객체가 \(survivedLines)줄에서 살아 있었다")
    }
}

// MARK: - PERF-004: 파싱 상태 스냅샷 영속화
//
// 앱을 켤 때마다 24시간 내 활성 세션 파일 전체(실사용 259개 / 6.85GB)를 오프셋 0부터 재파싱했다.
// 저장된 오프셋은 캐시 미스 시 버려졌다 — 누적 파싱 상태(토큰/제목/상태)가 영속화되지 않아서였다.
// → 파일별 파싱 상태 스냅샷을 오프셋과 함께 저장하고, 새 인스턴스는 그 지점부터 이어서 읽는다.

/// 저장/로드 호출을 기록하는 인메모리 스토어
private final class SpyParseStateStore: SessionParseStateStore {
    var stored: [String: SessionParseSnapshot] = [:]
    private(set) var saveCount = 0

    func load() -> [String: SessionParseSnapshot] { stored }

    func save(_ snapshots: [String: SessionParseSnapshot]) {
        saveCount += 1
        stored = snapshots
    }
}

/// 테스트에서 직접 전진시키는 시계
private final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

extension SessionMonitorMemoryTests {

    /// 모니터가 보는 경로 형태 (임시 디렉토리의 /var → /private/var 심볼릭 링크 해석)
    private func monitorPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private var stateFileURL: URL { rootDir.appendingPathComponent("state/session-parse-state.json") }

    private func makeMonitor(
        store: SessionParseStateStore?,
        clock: TestClock? = nil,
        recorder: ReadRecorder? = nil
    ) -> ClaudeSessionMonitor {
        let recorder = recorder ?? self.recorder!
        let fixed = fixedNow
        return ClaudeSessionMonitor(
            cliProjectsDir: cliDir,
            xcodeProjectsDir: rootDir.appendingPathComponent("xcode"),
            desktopCodeSessionsDir: rootDir.appendingPathComponent("desktop"),
            coworkSessionsDir: rootDir.appendingPathComponent("cowork"),
            defaults: defaults,
            now: { clock?.now ?? fixed },
            makeByteSource: { SpyByteSource(url: $0, recorder: recorder) },
            parseStateStore: store,
            parseStateSaveInterval: 15
        )
    }

    /// processEvent가 누적하는 상태를 고루 건드리는 세션 앞부분
    /// (cwd/permissionMode, Agent spawn → tool_result 확정, 미확정 spawn, thinking, ai-title, 두 모델 토큰)
    private func richSessionPrefix(index: Int) -> String {
        let user: [String: Any] = [
            "type": "user", "timestamp": "2026-10-20T01:00:00.123Z",
            "cwd": "/tmp/rich-\(index)", "permissionMode": "acceptEdits",
            "message": ["role": "user", "content": "시작 \(index)"],
        ]
        let spawn: [String: Any] = [
            "type": "assistant", "timestamp": "2026-10-20T01:00:01.456Z",
            "message": [
                "model": "claude-opus-4-7", "stop_reason": "tool_use",
                "usage": ["input_tokens": 10, "cache_read_input_tokens": 5, "output_tokens": 3],
                "content": [
                    ["type": "text", "text": "에이전트를 띄운다"],
                    ["type": "tool_use", "id": "toolu_A", "name": "Agent",
                     "input": ["subagent_type": "explorer", "description": "탐색 \(index)"]],
                    ["type": "tool_use", "id": "toolu_B", "name": "Agent",
                     "input": ["subagent_type": "reviewer", "description": "대기 중"]],
                ],
            ] as [String: Any],
        ]
        let result: [String: Any] = [
            "type": "user", "timestamp": "2026-10-20T01:00:02.000Z",
            "toolUseResult": ["agentId": "a\(index)", "agentType": "explorer"],
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_A"]]],
        ]
        let thinking: [String: Any] = [
            "type": "assistant", "timestamp": "2026-10-20T01:00:03.000Z",
            "message": ["model": "claude-sonnet-4-6", "content": [["type": "thinking", "thinking": "..."]]] as [String: Any],
        ]
        let title: [String: Any] = ["type": "ai-title", "title": "풍부한 세션 \(index)"]
        return [user, spawn, result, thinking, title].map(jsonLine).joined()
    }

    /// 재시작 후 덧붙는 부분 — 다른 모델 토큰 + Bash tool_use(승인 대기 판단 필드)
    private func richSessionAppendix(index: Int) -> String {
        let bash: [String: Any] = [
            "type": "assistant", "timestamp": "2026-10-20T01:05:00.789Z",
            "message": [
                "model": "claude-sonnet-4-6", "stop_reason": "tool_use",
                "usage": ["input_tokens": 200 + index, "cache_creation_input_tokens": 7, "output_tokens": 20],
                "content": [["type": "tool_use", "id": "toolu_C", "name": "Bash", "input": ["command": "ls"]]],
            ] as [String: Any],
        ]
        return jsonLine(bash)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func setRecentMTime(_ url: URL, secondsAgo: Double = 60) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: fixedNow.addingTimeInterval(-secondsAgo)], ofItemAtPath: url.path)
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64)
    }

    /// 직접 세션 3개 + 서브에이전트 1개 생성
    @discardableResult
    private func createRichSessions() throws -> [URL] {
        let projectDir = cliDir.appendingPathComponent("-tmp-rich")
        var urls: [URL] = []
        for i in 0..<3 {
            let url = projectDir.appendingPathComponent("rich-\(i).jsonl")
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            try richSessionPrefix(index: i).write(to: url, atomically: true, encoding: .utf8)
            try setRecentMTime(url, secondsAgo: Double(60 + i))
            urls.append(url)
        }
        let subDir = projectDir.appendingPathComponent("rich-0/subagents")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let subURL = subDir.appendingPathComponent("agent-a0.jsonl")
        try richSessionPrefix(index: 9).write(to: subURL, atomically: true, encoding: .utf8)
        try setRecentMTime(subURL, secondsAgo: 70)
        urls.append(subURL)
        return urls
    }

    /// 세션의 사용자 노출 결과 전부 (골든 비교용)
    private struct DetailedSnapshot: Equatable {
        let id: String
        let projectDir: String
        let workingPath: String
        let lastModified: Date
        let lastActivity: Date
        let lastContentChange: Date
        let sawResultEvent: Bool
        let sawErrorEvent: Bool
        let lastEventType: String
        let lastAssistantHasToolUse: Bool
        let lastToolUseTime: Date?
        let tokensByModel: [String: [Int]]
        let lastToolName: String
        let lastAssistantText: String
        let currentModel: String
        let permissionMode: String
        let title: String?
        let currentTurnHadThinking: Bool
        let isSubagent: Bool
        let parentSessionId: String?
        let subagentMeta: [String: [String]]
        let pendingAgentSpawns: [String: [String]]
        let totalTokens: Int
        let estimatedCost: Double?
        let displayStatus: SessionStatus
    }

    private func detailed(_ sessions: [ClaudeSession]) -> [DetailedSnapshot] {
        sessions.map { s in
            DetailedSnapshot(
                id: s.id, projectDir: s.projectDir, workingPath: s.workingPath,
                lastModified: s.lastModified, lastActivity: s.lastActivity,
                lastContentChange: s.lastContentChange,
                sawResultEvent: s.sawResultEvent, sawErrorEvent: s.sawErrorEvent,
                lastEventType: s.lastEventType, lastAssistantHasToolUse: s.lastAssistantHasToolUse,
                lastToolUseTime: s.lastToolUseTime,
                tokensByModel: s.tokensByModel.mapValues { [$0.input, $0.cachedInput, $0.output, $0.reasoningOutput] },
                lastToolName: s.lastToolName, lastAssistantText: s.lastAssistantText,
                currentModel: s.currentModel, permissionMode: s.permissionMode, title: s.title,
                currentTurnHadThinking: s.currentTurnHadThinking,
                isSubagent: s.isSubagent, parentSessionId: s.parentSessionId,
                subagentMeta: s.subagentMeta.mapValues { [$0.type, $0.description] },
                pendingAgentSpawns: s.pendingAgentSpawns.mapValues { [$0.type, $0.description] },
                totalTokens: s.totalTokens, estimatedCost: s.estimatedCost,
                displayStatus: s.displayStatus
            )
        }.sorted { ($0.projectDir, $0.id) < ($1.projectDir, $1.id) }
    }

    /// 스토어 없이 새 인스턴스로 전체 파싱한 결과 (골든)
    private func freshFullParse() -> [DetailedSnapshot] {
        detailed(makeMonitor(store: nil, recorder: ReadRecorder()).pollNow())
    }

    // MARK: 재시작 후 덧붙은 바이트만 읽고, 결과는 전체 파싱과 동일

    func test_newInstanceWithPersistedSnapshot_readsOnlyAppendedBytes_andMatchesFullParse() throws {
        let urls = try createRichSessions()
        let store = FileSessionParseStateStore(fileURL: stateFileURL)

        let first = makeMonitor(store: store)
        first.pollNow()
        first.flushParseState()

        // 재시작 사이에 두 파일에 줄이 덧붙는다
        var sizesBefore: [String: UInt64] = [:]
        for url in urls { sizesBefore[url.lastPathComponent] = try fileSize(url) }
        let appended = [urls[0], urls[3]]
        var appendedBytes = 0
        for (i, url) in appended.enumerated() {
            let text = richSessionAppendix(index: i)
            appendedBytes += Data(text.utf8).count
            try append(text, to: url)
            try setRecentMTime(url, secondsAgo: 30)
        }

        recorder.reset()
        let restarted = makeMonitor(store: FileSessionParseStateStore(fileURL: stateFileURL))
        let resumed = restarted.pollNow()

        XCTAssertTrue(recorder.reads.allSatisfy { $0.offset > 0 }, "재시작 후 오프셋 0부터 읽은 파일이 있다")
        for read in recorder.reads {
            let name = URL(fileURLWithPath: read.path).lastPathComponent
            XCTAssertEqual(read.offset, sizesBefore[name], "\(name)은 저장된 오프셋부터 읽어야 한다")
        }
        XCTAssertEqual(recorder.totalBytes, appendedBytes, "덧붙은 바이트만 읽어야 한다")
        XCTAssertEqual(resumed.count, 4)
        XCTAssertEqual(detailed(resumed), freshFullParse(), "스냅샷 복원 결과는 전체 재파싱과 같아야 한다")
    }

    func test_newInstanceWithPersistedSnapshot_unchangedFiles_readsZeroBytes() throws {
        try createRichSessions()
        let first = makeMonitor(store: FileSessionParseStateStore(fileURL: stateFileURL))
        first.pollNow()
        first.flushParseState()

        recorder.reset()
        let resumed = makeMonitor(store: FileSessionParseStateStore(fileURL: stateFileURL)).pollNow()

        XCTAssertEqual(recorder.totalBytes, 0)
        XCTAssertEqual(detailed(resumed), freshFullParse())
    }

    // MARK: 파일 정체성이 바뀐 경우 → 전체 재파싱

    func test_truncatedFileSmallerThanSnapshotOffset_isFullyReparsed() throws {
        let urls = try createRichSessions()
        let first = makeMonitor(store: FileSessionParseStateStore(fileURL: stateFileURL))
        first.pollNow()
        first.flushParseState()

        // 같은 파일(같은 inode)을 더 짧은 내용으로 덮어씀
        let target = urls[1]
        let shorter = jsonLine(["type": "user", "timestamp": "2026-10-20T02:00:00.000Z",
                                "cwd": "/tmp/short", "message": ["role": "user", "content": "새로"]])
        let handle = try FileHandle(forWritingTo: target)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(shorter.utf8))
        try handle.close()
        try setRecentMTime(target, secondsAgo: 10)

        recorder.reset()
        let resumed = makeMonitor(store: FileSessionParseStateStore(fileURL: stateFileURL)).pollNow()

        let targetReads = recorder.reads.filter { $0.path == monitorPath(target) }
        XCTAssertEqual(targetReads.first?.offset, 0, "잘린 파일은 처음부터 다시 읽어야 한다")
        XCTAssertEqual(recorder.reads.filter { $0.path != monitorPath(target) }.count, 0, "다른 파일은 읽지 않아야 한다")
        XCTAssertEqual(detailed(resumed), freshFullParse())
    }

    func test_replacedFileWithDifferentIdentity_isFullyReparsedEvenIfLarger() throws {
        let urls = try createRichSessions()
        let first = makeMonitor(store: FileSessionParseStateStore(fileURL: stateFileURL))
        first.pollNow()
        first.flushParseState()

        // 회전: 같은 경로에 새 파일(다른 inode), 원래보다 크다
        let target = urls[2]
        try FileManager.default.removeItem(at: target)
        let bigger = richSessionPrefix(index: 42) + richSessionAppendix(index: 42)
        try bigger.write(to: target, atomically: false, encoding: .utf8)
        try setRecentMTime(target, secondsAgo: 10)

        recorder.reset()
        let resumed = makeMonitor(store: FileSessionParseStateStore(fileURL: stateFileURL)).pollNow()

        XCTAssertEqual(recorder.reads.filter { $0.path == monitorPath(target) }.first?.offset, 0)
        XCTAssertEqual(detailed(resumed), freshFullParse())
    }

    // MARK: 손상/버전 불일치 → 무시하고 전체 파싱

    func test_corruptSnapshotFile_fallsBackToFullParseWithoutCrash() throws {
        try createRichSessions()
        try FileManager.default.createDirectory(
            at: stateFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json ".utf8).write(to: stateFileURL)

        let store = FileSessionParseStateStore(fileURL: stateFileURL)
        XCTAssertTrue(store.load().isEmpty)

        recorder.reset()
        let monitor = makeMonitor(store: store)
        let sessions = monitor.pollNow()

        XCTAssertEqual(Set(recorder.reads.filter { $0.offset == 0 }.map(\.path)).count, 4, "모든 파일을 처음부터 읽어야 한다")
        XCTAssertEqual(detailed(sessions), freshFullParse())

        // 손상 파일은 다음 저장에서 정상 스냅샷으로 교체된다
        monitor.flushParseState()
        XCTAssertEqual(FileSessionParseStateStore(fileURL: stateFileURL).load().count, 4)
    }

    func test_snapshotWithDifferentSchemaVersion_isIgnored() throws {
        try createRichSessions()
        let first = makeMonitor(store: FileSessionParseStateStore(fileURL: stateFileURL))
        first.pollNow()
        first.flushParseState()

        // 저장된 파일의 version만 바꾼다 (entries는 그대로 유효)
        let data = try Data(contentsOf: stateFileURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, FileSessionParseStateStore.schemaVersion)
        object["version"] = FileSessionParseStateStore.schemaVersion + 1
        try JSONSerialization.data(withJSONObject: object).write(to: stateFileURL)

        XCTAssertTrue(FileSessionParseStateStore(fileURL: stateFileURL).load().isEmpty)

        recorder.reset()
        let resumed = makeMonitor(store: FileSessionParseStateStore(fileURL: stateFileURL)).pollNow()
        XCTAssertEqual(Set(recorder.reads.filter { $0.offset == 0 }.map(\.path)).count, 4)
        XCTAssertEqual(detailed(resumed), freshFullParse())
    }

    // MARK: 정리 — 활성이 아닌 파일의 스냅샷은 버린다

    func test_snapshotEntriesForInactiveFiles_arePruned() throws {
        let urls = try createRichSessions()
        let store = SpyParseStateStore()
        let first = makeMonitor(store: store)
        first.pollNow()
        XCTAssertEqual(Set(store.stored.keys), Set(urls.map(monitorPath)))

        // 하나는 24시간 밖으로 밀려남 → 같은 인스턴스에서 정리
        try setRecentMTime(urls[1], secondsAgo: 90_000)
        first.pollNow()
        first.flushParseState()
        XCTAssertFalse(store.stored.keys.contains(monitorPath(urls[1])))
        XCTAssertEqual(store.stored.count, 3)

        // 재시작 시점에 이미 비활성인 파일의 스냅샷도 저장에서 빠진다
        try setRecentMTime(urls[2], secondsAgo: 90_000)
        let restarted = makeMonitor(store: store)
        restarted.pollNow()
        restarted.flushParseState()
        XCTAssertEqual(Set(store.stored.keys), Set([monitorPath(urls[0]), monitorPath(urls[3])]))
    }

    // MARK: 쓰기 스로틀링 (주입 시계)

    func test_parseStateWrites_areThrottled_andOnlyWhenChanged() throws {
        let urls = try createRichSessions()
        let store = SpyParseStateStore()
        let clock = TestClock(fixedNow)
        let monitor = makeMonitor(store: store, clock: clock)

        monitor.pollNow()
        XCTAssertEqual(store.saveCount, 1, "첫 파싱 결과는 즉시 저장한다")

        try append(richSessionAppendix(index: 0), to: urls[0])
        try setRecentMTime(urls[0], secondsAgo: 1)
        clock.now = fixedNow.addingTimeInterval(5)
        monitor.pollNow()
        XCTAssertEqual(store.saveCount, 1, "저장 간격(15초) 안에서는 쓰지 않는다")

        clock.now = fixedNow.addingTimeInterval(16)
        monitor.pollNow()
        XCTAssertEqual(store.saveCount, 2, "간격이 지나면 밀린 변경을 저장한다")
        XCTAssertEqual(store.stored[monitorPath(urls[0])]?.offset, try fileSize(urls[0]))

        try append(richSessionAppendix(index: 1), to: urls[0])
        try setRecentMTime(urls[0], secondsAgo: 1)
        clock.now = fixedNow.addingTimeInterval(20)
        monitor.pollNow()
        XCTAssertEqual(store.saveCount, 2)
        monitor.flushParseState()
        XCTAssertEqual(store.saveCount, 3, "flush(종료 시)는 간격과 무관하게 밀린 변경을 저장한다")
        XCTAssertEqual(store.stored[monitorPath(urls[0])]?.offset, try fileSize(urls[0]))

        clock.now = fixedNow.addingTimeInterval(60)
        monitor.pollNow()
        XCTAssertEqual(store.saveCount, 3, "변경이 없으면 쓰지 않는다")

        monitor.flushParseState()
        XCTAssertEqual(store.saveCount, 3, "변경 없는 flush는 쓰지 않는다")
    }

    func test_monitorWithoutStore_neverPersists() throws {
        try createRichSessions()
        let monitor = makeMonitor(store: nil)
        monitor.pollNow()
        monitor.flushParseState()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFileURL.path))
    }
}
