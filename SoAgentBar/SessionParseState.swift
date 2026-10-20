import Foundation

// MARK: - SessionParseSnapshot (PERF-004)

/// JSONL 한 파일의 누적 파싱 상태 + 이어 읽을 오프셋.
/// 앱 재시작 후 새 인스턴스가 오프셋 0부터 전체 재파싱하지 않고 `offset`부터 이어서 읽게 한다.
///
/// 저장하는 것: `processEvent`가 누적하는 ClaudeSession 필드 전부.
/// 저장하지 않는 것(매 폴링마다 재도출): id·projectDir·source·isSubagent·parentSessionId(파일 경로에서),
/// lastModified(mtime), Desktop Code 메타(title 폴백·source 전환), Codex 전용 필드(Claude 세션은 항상 기본값).
struct SessionParseSnapshot: Codable, Equatable {
    struct AgentInfo: Codable, Equatable {
        var type: String
        var description: String
    }

    /// 다음에 읽기 시작할 바이트 위치 (마지막으로 완성된 줄의 다음)
    var offset: UInt64
    /// 파일 정체성(inode). 같은 경로라도 다른 파일로 교체되었으면 스냅샷을 쓰지 않는다
    var fileID: UInt64?

    var workingPath: String
    var lastActivity: Date
    var lastContentChange: Date
    var sawResultEvent: Bool
    var sawErrorEvent: Bool
    var lastEventType: String
    var lastAssistantHasToolUse: Bool
    var lastToolUseTime: Date?
    var tokensByModel: [String: ClaudeSession.TokenUsage]
    var lastToolName: String
    var lastAssistantText: String
    var currentModel: String
    var permissionMode: String
    var title: String?
    var currentTurnHadThinking: Bool
    var subagentMeta: [String: AgentInfo]
    var pendingAgentSpawns: [String: AgentInfo]

    init(session: ClaudeSession, offset: UInt64, fileID: UInt64?) {
        self.offset = offset
        self.fileID = fileID
        workingPath = session.workingPath
        lastActivity = session.lastActivity
        lastContentChange = session.lastContentChange
        sawResultEvent = session.sawResultEvent
        sawErrorEvent = session.sawErrorEvent
        lastEventType = session.lastEventType
        lastAssistantHasToolUse = session.lastAssistantHasToolUse
        lastToolUseTime = session.lastToolUseTime
        tokensByModel = session.tokensByModel
        lastToolName = session.lastToolName
        lastAssistantText = session.lastAssistantText
        currentModel = session.currentModel
        permissionMode = session.permissionMode
        title = session.title
        currentTurnHadThinking = session.currentTurnHadThinking
        subagentMeta = session.subagentMeta.mapValues { AgentInfo(type: $0.type, description: $0.description) }
        pendingAgentSpawns = session.pendingAgentSpawns.mapValues { AgentInfo(type: $0.type, description: $0.description) }
    }

    /// 스냅샷의 누적 상태를 세션에 덮어쓴다 (경로/mtime 유래 필드는 호출자가 채운다)
    func apply(to session: inout ClaudeSession) {
        session.workingPath = workingPath
        session.lastActivity = lastActivity
        session.lastContentChange = lastContentChange
        session.sawResultEvent = sawResultEvent
        session.sawErrorEvent = sawErrorEvent
        session.lastEventType = lastEventType
        session.lastAssistantHasToolUse = lastAssistantHasToolUse
        session.lastToolUseTime = lastToolUseTime
        session.tokensByModel = tokensByModel
        session.lastToolName = lastToolName
        session.lastAssistantText = lastAssistantText
        session.currentModel = currentModel
        session.permissionMode = permissionMode
        session.title = title
        session.currentTurnHadThinking = currentTurnHadThinking
        session.subagentMeta = subagentMeta.mapValues { (type: $0.type, description: $0.description) }
        session.pendingAgentSpawns = pendingAgentSpawns.mapValues { (type: $0.type, description: $0.description) }
    }
}

// MARK: - SessionParseStateStore

/// 파싱 상태 스냅샷 저장소. 테스트에서는 임시 디렉토리 파일 또는 인메모리 구현을 주입한다.
protocol SessionParseStateStore: AnyObject {
    /// 저장된 스냅샷 (없거나 읽을 수 없으면 빈 딕셔너리 → 호출자는 전체 파싱)
    func load() -> [String: SessionParseSnapshot]
    /// 파일 경로 → 스냅샷 전체를 교체 저장
    func save(_ snapshots: [String: SessionParseSnapshot])
}

/// JSON 파일 기반 저장소 (버전 스키마, 원자적 쓰기).
/// 크기(활성 파일 수 × 수 KB)가 커서 UserDefaults 대신 Application Support에 둔다.
final class FileSessionParseStateStore: SessionParseStateStore {
    /// 스냅샷 필드 구성이 바뀌면 올린다 — 다른 버전 파일은 무시하고 전체 파싱한다
    static let schemaVersion = 1

    private struct Envelope: Codable {
        let version: Int
        let entries: [String: SessionParseSnapshot]
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }

    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// ~/Library/Application Support/<bundle id>/session-parse-state.json
    static func applicationSupportStore() -> FileSessionParseStateStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.sotthang.soagentbar"
        return FileSessionParseStateStore(
            fileURL: base.appendingPathComponent(bundleID).appendingPathComponent("session-parse-state.json"))
    }

    func load() -> [String: SessionParseSnapshot] {
        guard let data = try? Data(contentsOf: fileURL),
              let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
              probe.version == Self.schemaVersion,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return [:] }
        return envelope.entries
    }

    func save(_ snapshots: [String: SessionParseSnapshot]) {
        guard let data = try? JSONEncoder().encode(Envelope(version: Self.schemaVersion, entries: snapshots))
        else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
