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

    func readToEnd(from offset: UInt64) -> Data {
        let data = inner.readToEnd(from: offset)
        recorder.record(path: path, offset: offset, bytes: data.count)
        return data
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
}
