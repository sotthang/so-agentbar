import Foundation
import CoreServices

// MARK: - CodexSessionMonitor
// Codex CLI (~/.codex/sessions) 세션 모니터.
// YYYY/MM/DD/*.jsonl 구조를 FSEvents + 폴링으로 감시하고,
// JSONL 이벤트를 파싱해 ClaudeSession 목록으로 발행한다.

final class CodexSessionMonitor: SessionMonitorProtocol {

    // MARK: Public (Protocol)
    var onSessionsChanged: (([ClaudeSession]) -> Void)?

    // MARK: Init

    /// - rolloutsRoot: ~/.codex/sessions (테스트에서는 임시 디렉토리)
    /// - fileManager: FileManager (테스트에서는 mock 가능)
    /// - now: poll 기준 시각 (24시간 필터) — 테스트에서 고정 시계 주입
    /// - makeByteSource: JSONL 파일 읽기 원천 — 테스트에서 읽은 바이트를 세는 spy 주입
    init(
        rolloutsRoot: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/sessions"),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        makeByteSource: @escaping (URL) -> ByteSource? = { FileByteSource(url: $0) }
    ) {
        self.rolloutsRoot = rolloutsRoot
        self.fm = fileManager
        self.now = now
        self.makeByteSource = makeByteSource
    }

    // MARK: Protocol Methods

    func start() {
        requestPoll()
        startFSEvents()
        DispatchQueue.main.async { [weak self] in
            self?.fallbackTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                self?.requestPoll()
            }
        }
    }

    func stop() {
        stopFSEvents()
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        pollWorkItem?.cancel()
        pollWorkItem = nil
    }

    func updatePollInterval(_ interval: Double) {
        DispatchQueue.main.async { [weak self] in
            self?.fallbackTimer?.invalidate()
            self?.fallbackTimer = Timer.scheduledTimer(withTimeInterval: max(interval, 10), repeats: true) { [weak self] _ in
                self?.requestPoll()
            }
        }
    }

    // MARK: Internals (private)

    private let rolloutsRoot: URL
    private let fm: FileManager
    private let now: () -> Date
    private let makeByteSource: (URL) -> ByteSource?
    // .workItem: 작업 단위마다 autorelease pool을 비운다 — 기본값(.inherit)이면 큐가 쉬지 못할 때
    // 스레드 pool이 비워지지 않아 파일 Data/JSON 트리가 계속 쌓인다 (PERF-003 / PERF-007)
    private let dispatchQueue = DispatchQueue(
        label: "com.sotthang.so-agentbar.codexmonitor", qos: .utility, autoreleaseFrequency: .workItem
    )
    // 폴링 병합: 큐에 대기 중인 폴링이 있으면 새 요청은 버린다 (진행 중 폴링 뒤로 최대 1회만 대기)
    private let pollRequestLock = NSLock()
    private var isPollQueued = false
    private var eventStream: FSEventStreamRef?
    private var fallbackTimer: Timer?
    private var pollWorkItem: DispatchWorkItem?
    private var fileOffsets: [String: UInt64] = [:]   // 파일 경로 → 다음에 읽을 바이트 위치
    // 파일 경로 → 누적 파싱 상태. fileOffsets와 같은 키를 써서 상태가 남아 있는 한 오프셋이 리셋되지 않고,
    // 같은 파일명(세션 id)의 다른 파일과 상태가 섞이지 않는다 (PERF-001 / PERF-007)
    private var sessionCache: [String: ClaudeSession] = [:]

    // 파일 경로 → model 도착 전 token_count 이벤트 임시 저장 (turn_context.model과 결합 대기)
    private var pendingTokenSnapshot: [String: [String: Any]] = [:]

    // MARK: - FSEvents

    private func startFSEvents() {
        // rolloutsRoot가 없으면 FSEvents 생략 (디렉토리를 생성하지 않음 — R6.5 정책)
        guard fm.fileExists(atPath: rolloutsRoot.path) else { return }

        let paths = [rolloutsRoot.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, clientInfo, _, _, _, _ in
            guard let clientInfo else { return }
            let monitor = Unmanaged<CodexSessionMonitor>.fromOpaque(clientInfo).takeUnretainedValue()
            monitor.scheduleDebouncedPoll()
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }

        eventStream = stream
        FSEventStreamSetDispatchQueue(stream, dispatchQueue)
        FSEventStreamStart(stream)
    }

    private func stopFSEvents() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    private func scheduleDebouncedPoll() {
        pollWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.requestPoll() }
        pollWorkItem = item
        dispatchQueue.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    // MARK: - 메인 루프

    /// 폴링 요청의 단일 진입점 (초기 폴링 / 폴백 타이머 / FSEvents 디바운스).
    /// 폴링이 진행 중이거나 대기 중이면 병합되어, 진행 중 폴링이 끝난 뒤 최대 1회만 추가 실행된다.
    func requestPoll() {
        pollRequestLock.lock()
        defer { pollRequestLock.unlock() }
        guard !isPollQueued else { return }
        isPollQueued = true
        dispatchQueue.async { [weak self] in self?.runQueuedPoll() }
    }

    private func runQueuedPoll() {
        // 실행 시작 시점에 대기 표시를 해제 — 이후 들어온 요청은 다음 1회로 대기한다
        pollRequestLock.lock()
        isPollQueued = false
        pollRequestLock.unlock()
        poll()
    }

    private func poll() {
        let results = pollNow()
        DispatchQueue.main.async { [weak self] in
            self?.onSessionsChanged?(results)
        }
    }

    /// 한 번의 스캔·파싱을 호출 스레드에서 동기 수행하고 세션 목록을 반환한다.
    /// 프로덕션에서는 dispatchQueue 위에서 poll()을 통해서만 호출된다.
    /// 테스트에서는 start() 없이 직접 호출해 폴링을 동기적으로 구동한다 (onSessionsChanged 미호출).
    @discardableResult
    func pollNow() -> [ClaudeSession] {
        let now = self.now()
        var results: [ClaudeSession] = []

        var activePaths: Set<String> = []

        let rolloutFiles = discoverRolloutFiles(now: now)
        for fileURL in rolloutFiles {
            // 파일마다 읽은 Data/파싱 결과의 autorelease 객체를 즉시 해제
            autoreleasepool {
                guard let modDate = modificationDate(of: fileURL) else { return }
                let cacheKey = fileURL.path

                // 상태가 없을 때(새 파일)만 처음부터 읽는다 — 상태가 있으면 오프셋을 그대로 이어 쓴다
                var session: ClaudeSession
                if let cached = sessionCache[cacheKey] {
                    session = cached
                } else {
                    fileOffsets.removeValue(forKey: cacheKey)
                    pendingTokenSnapshot.removeValue(forKey: cacheKey)
                    session = ClaudeSession(
                        id: deriveSessionID(from: fileURL),
                        projectDir: fileURL.lastPathComponent,
                        source: .codexCLI,
                        workingPath: "",
                        lastModified: modDate,
                        lastActivity: .distantPast,
                        lastContentChange: .distantPast
                    )
                }
                session.lastModified = modDate

                // Codex invariant 강제 (R3.8)
                session.isSubagent = false
                session.parentSessionId = nil

                parseNewLines(url: fileURL, session: &session)

                sessionCache[cacheKey] = session
                activePaths.insert(cacheKey)
                results.append(session)
            }
        }

        // 캐시 정리: 이번 폴링에 없는 파일(24시간 필터에서 걸러짐)의 상태·오프셋 제거
        for key in sessionCache.keys where !activePaths.contains(key) {
            sessionCache.removeValue(forKey: key)
        }
        for key in fileOffsets.keys where !activePaths.contains(key) {
            fileOffsets.removeValue(forKey: key)
        }
        for key in pendingTokenSnapshot.keys where !activePaths.contains(key) {
            pendingTokenSnapshot.removeValue(forKey: key)
        }

        return results
    }

    // MARK: - rollout 파일 탐색

    private func discoverRolloutFiles(now: Date) -> [URL] {
        guard fm.fileExists(atPath: rolloutsRoot.path) else { return [] }

        var result: [URL] = []
        // 재귀적으로 YYYY/MM/DD/*.jsonl 탐색
        guard let dateDirs = try? fm.contentsOfDirectory(at: rolloutsRoot, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }

        for yearDir in dateDirs where yearDir.hasDirectoryPath {
            guard let monthDirs = try? fm.contentsOfDirectory(at: yearDir, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for monthDir in monthDirs where monthDir.hasDirectoryPath {
                guard let dayDirs = try? fm.contentsOfDirectory(at: monthDir, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
                for dayDir in dayDirs where dayDir.hasDirectoryPath {
                    guard let files = try? fm.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                    for file in files {
                        // .zst 파일 무시 (AC-R2.3)
                        if file.pathExtension == "zst" { continue }
                        guard file.pathExtension == "jsonl" else { continue }
                        guard let mod = modificationDate(of: file),
                              now.timeIntervalSince(mod) < 86400 else { continue }
                        result.append(file)
                    }
                }
            }
        }
        return result
    }

    // MARK: - JSONL 파싱 (오프셋 기반)

    private func parseNewLines(url: URL, session: inout ClaudeSession) {
        guard let source = makeByteSource(url) else { return }

        let currentOffset = fileOffsets[url.path] ?? 0

        // 파싱 전 lastActivity 스냅샷 — 새 이벤트 유무 판단용
        let activityBefore = session.lastActivity

        // 마지막 개행까지의 완성된 줄만 청크 단위로 스트리밍 파싱 — 쓰는 도중인 불완전한 줄 제외
        let nextOffset = JSONLReader.readCompleteLines(from: source, startingAt: currentOffset) { json in
            processCodexEvent(json, session: &session, stateKey: url.path)
        }
        if let nextOffset {
            fileOffsets[url.path] = nextOffset
        }

        // 파싱 후 lastActivity가 전진했으면 lastContentChange를 해당 timestamp로 갱신
        // (앱 재시작 시 과거 이벤트를 한꺼번에 읽어도 "지금 활동 중"으로 오판되지 않음)
        if session.lastActivity > activityBefore {
            session.lastContentChange = session.lastActivity
        }
    }

    // MARK: - Codex 이벤트 파싱

    private enum EventMsgKind {
        case taskStarted, taskComplete, error, agentMessage, userMessage, tokenCount, unknown
    }

    private enum ResponseItemKind {
        case message, reasoning, ghostSnapshot, unknown
    }

    private func decodeEventMsgKind(_ payload: [String: Any]) -> EventMsgKind {
        guard let type = payload["type"] as? String else { return .unknown }
        switch type {
        case "task_started":  return .taskStarted
        case "task_complete": return .taskComplete
        case "error":         return .error
        case "agent_message": return .agentMessage
        case "user_message":  return .userMessage
        case "token_count":   return .tokenCount
        default:              return .unknown
        }
    }

    private func decodeResponseItemKind(_ payload: [String: Any]) -> ResponseItemKind {
        guard let type = payload["type"] as? String else { return .unknown }
        switch type {
        case "message":        return .message
        case "reasoning":      return .reasoning
        case "ghost_snapshot": return .ghostSnapshot
        default:               return .unknown
        }
    }

    /// - stateKey: 파일별 보류 토큰 저장 키 (파일 경로)
    private func processCodexEvent(_ json: [String: Any], session: inout ClaudeSession, stateKey: String) {
        guard let type = json["type"] as? String else { return }

        // 타임스탬프 갱신
        if let tsStr = json["timestamp"] as? String,
           let ts = SessionDateUtil.parseISO8601(tsStr),
           ts > session.lastActivity {
            session.lastActivity = ts
        }

        // 각 이벤트 타입은 json["payload"]에 실제 데이터가 들어있음
        // session_meta, turn_context, event_msg, response_item 모두 동일한 구조
        let outerPayload = json["payload"] as? [String: Any]

        switch type {
        case "session_meta":
            guard let payload = outerPayload else { break }
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                session.workingPath = cwd
            }
            let originator = payload["originator"] as? String
            session.source = (originator == "codex_vscode") ? .codexVSCode : .codexCLI
            session.lastEventType = "session_meta"

        case "turn_context":
            guard let payload = outerPayload else { break }
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                session.workingPath = cwd
            }
            if let model = payload["model"] as? String {
                session.currentModel = model
                // 보류된 토큰 스냅샷이 있으면 지금 결합
                if let pending = pendingTokenSnapshot[stateKey] {
                    applyTokenSnapshot(info: pending, model: model, session: &session)
                    pendingTokenSnapshot[stateKey] = nil
                }
            }
            if let policy = payload["approval_policy"] as? String {
                session.codexApprovalPolicy = policy
            }

        case "event_msg":
            // json["payload"]가 innerPayload (type, info 등이 직접 포함)
            guard let innerPayload = outerPayload else { break }
            switch decodeEventMsgKind(innerPayload) {
            case .taskStarted:
                session.lastEventType = "task_started"
                session.codexSawResultEvent = false
                session.codexSawErrorEvent = false

            case .taskComplete:
                session.lastEventType = "task_complete"
                session.codexSawResultEvent = true
                if let msg = innerPayload["last_agent_message"] as? String {
                    session.lastAssistantText = String(msg.prefix(200))
                }
                if let dur = innerPayload["duration_ms"] as? Int {
                    session.codexLastTurnDurationMs = dur
                }

            case .error:
                session.lastEventType = "error"
                session.codexSawResultEvent = true
                session.codexSawErrorEvent = true
                if let info = innerPayload["codex_error_info"] as? String {
                    session.codexErrorInfo = info
                }

            case .agentMessage:
                session.lastEventType = "assistant"
                if let msg = innerPayload["message"] as? String {
                    session.lastAssistantText = String(msg.prefix(200))
                }

            case .userMessage:
                session.lastEventType = "user"
                session.lastToolUseTime = nil
                session.currentTurnHadThinking = false

            case .tokenCount:
                // innerPayload["info"]가 nil이면 무시 (AC-R3.11)
                guard let info = innerPayload["info"] as? [String: Any] else {
                    break
                }
                updateTokenUsage(info: info, session: &session, stateKey: stateKey)

            case .unknown:
                break
            }

        case "response_item":
            // json["payload"]가 innerPayload (type, role 등이 직접 포함)
            guard let innerPayload = outerPayload else { break }
            switch decodeResponseItemKind(innerPayload) {
            case .message:
                if let role = innerPayload["role"] as? String {
                    if role == "assistant" {
                        session.lastEventType = "assistant"
                    } else if role == "user" {
                        session.lastEventType = "user"
                    }
                }
            case .reasoning:
                // AC-R3.14: lastEventType 갱신 없이 무시
                session.currentTurnHadThinking = true

            case .ghostSnapshot:
                session.lastEventType = "ghost_snapshot"

            case .unknown:
                break
            }

        default:
            break
        }

        // Codex invariant 강제 (R3.8)
        session.isSubagent = false
        session.parentSessionId = nil
    }

    // MARK: - 토큰 처리

    private func updateTokenUsage(info: [String: Any], session: inout ClaudeSession, stateKey: String) {
        guard info["total_token_usage"] is [String: Any] else { return }

        let model = session.currentModel
        if !model.isEmpty {
            applyTokenSnapshot(info: info, model: model, session: &session)
        } else {
            // model 미정 — 보류 (AC-R3.12)
            pendingTokenSnapshot[stateKey] = info
        }
    }

    private func applyTokenSnapshot(info: [String: Any], model: String, session: inout ClaudeSession) {
        guard let usage = info["total_token_usage"] as? [String: Any] else { return }
        let inputTokens           = (usage["input_tokens"] as? Int) ?? 0
        let cachedInputTokens     = (usage["cached_input_tokens"] as? Int) ?? 0
        let outputTokens          = (usage["output_tokens"] as? Int) ?? 0
        let reasoningOutputTokens = (usage["reasoning_output_tokens"] as? Int) ?? 0

        // 누적 X — 마지막 값으로 덮어쓰기 (rev6)
        session.tokensByModel[model] = ClaudeSession.TokenUsage(
            input: inputTokens,
            cachedInput: cachedInputTokens,
            output: outputTokens,
            reasoningOutput: reasoningOutputTokens
        )
    }

    // MARK: - 유틸

    private func deriveSessionID(from url: URL) -> String {
        // 파일명에서 session ID 추출: rollout-{id}.jsonl → {id}
        let filename = url.deletingPathExtension().lastPathComponent
        if filename.hasPrefix("rollout-") {
            return String(filename.dropFirst("rollout-".count))
        }
        return filename
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
