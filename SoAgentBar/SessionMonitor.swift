import Foundation
import CoreServices

// MARK: - 세션 상태 (JSONL 이벤트 기반)

enum SessionStatus {
    case running            // 툴 실행 중 or Claude 생성 중 (파일 최근 수정 + 마지막 이벤트가 active)
    case waitingForApproval // tool_use 후 파일 변화 없음 = 사용자 승인 대기
    case responded          // Claude 응답 완료, 사용자 입력 대기
    case completed          // "result" 이벤트 감지 = 세션 정상 종료
    case error              // "result" 이벤트에서 isError 감지
    case idle               // 5분 이상 아무 변화 없음
}

// MARK: - 세션 출처

enum SessionSource: Hashable {
    case cli           // 터미널에서 claude 명령어로 실행
    case xcode         // Xcode Coding Assistant에서 실행
    case desktopCode   // Claude Desktop의 Code 탭
    case desktopCowork // Claude Desktop의 Cowork 탭 (VM)
}

// MARK: - Claude 세션 모델

struct ClaudeSession: Identifiable {
    let id: String
    let projectDir: String
    var source: SessionSource
    var workingPath: String
    var lastModified: Date
    var lastActivity: Date

    // JSONL 파싱 상태 (오프셋 기반으로 누적)
    var sawResultEvent: Bool = false
    var sawErrorEvent: Bool = false
    var lastEventType: String = ""         // "user", "assistant", "tool_result", "result"
    var lastAssistantHasToolUse: Bool = false
    var lastToolUseTime: Date? = nil       // tool_use 감지 시각 (승인 대기 판단용)
    var tokensByModel: [String: (input: Int, output: Int)] = [:]  // 모델별 누적 토큰
    var lastToolName: String = "running"
    var lastAssistantText: String = ""      // 마지막 Claude 응답 미리보기
    var currentModel: String = ""           // 마지막 assistant 이벤트의 모델명
    var permissionMode: String = "default"  // "default", "acceptEdits", "plan", "auto", "bypassPermissions"
    var title: String? = nil                // AI 생성 제목 (ai-title 이벤트 또는 Desktop 메타데이터)
    var currentTurnHadThinking: Bool = false // 현재 턴에 extended thinking이 있었는지 (중간 텍스트 오탐 방지)
    var isSubagent: Bool = false             // subagents/ 하위 JSONL 여부 (알람 제외 대상)

    var totalTokens: Int {
        tokensByModel.values.reduce(0) { $0 + $1.input + $1.output }
    }

    var estimatedCost: Double? {
        let costs = tokensByModel.compactMap { (model, tokens) in
            CostCalculator.estimate(model: model, inputTokens: tokens.input, outputTokens: tokens.output)
        }
        guard !costs.isEmpty else { return nil }
        return costs.reduce(0, +)
    }

    // 현재 permissionMode에서 해당 도구가 자동 승인되는지 판단
    // 모든 모드에서 읽기 전용/내부 도구는 승인 불필요
    private static let readOnlyTools: Set<String> = ["read", "glob", "grep", "agent", "todowrite"]

    func isToolAutoApproved(_ toolName: String) -> Bool {
        // 읽기 전용 및 내부 도구는 어떤 모드에서든 자동 승인
        if Self.readOnlyTools.contains(toolName) { return true }

        switch permissionMode {
        case "bypassPermissions", "auto":
            return true
        case "acceptEdits":
            return ["edit", "write"].contains(toolName)
        default: // "default", "plan"
            return false
        }
    }

    // JSONL 이벤트 기반 상태 판단
    var sessionStatus: SessionStatus {
        // result 이벤트 = 세션 종료 (정상 or 에러)
        if sawResultEvent { return sawErrorEvent ? .error : .completed }

        let age = Date().timeIntervalSince(lastModified)

        // 5분 이상 = idle
        if age > 300 { return .idle }

        // 마지막 이벤트로 판단
        // assistant with text only → Claude가 방금 응답 완료
        if lastEventType == "assistant" && !lastAssistantHasToolUse {
            return .responded
        }

        // tool_use 후 파일이 3초 이상 변화 없음 → 사용자 승인 대기
        // (실행 중인 명령은 bash_progress 이벤트로 파일이 계속 갱신됨)
        // 단, 현재 permissionMode에서 자동 승인되는 도구는 제외
        if lastAssistantHasToolUse, let toolUseTime = lastToolUseTime,
           !isToolAutoApproved(lastToolName) {
            let timeSinceToolUse = Date().timeIntervalSince(toolUseTime)
            if timeSinceToolUse > 5 && age > 5 {
                return .waitingForApproval
            }
        }

        // tool_result, assistant with tool_use, user → 아직 실행 중
        return .running
    }

    var displayName: String {
        // AI 생성 제목이 있으면 우선 사용
        if let title, !title.isEmpty { return title }

        // projectDir 인코딩: 경로의 특수문자(/, _ 등)를 -로 1:1 치환 → 길이 보존
        // 예: /Users/hs_so/Develop/Dcty-Agent → -Users-hs-so-Develop-Dcty-Agent (둘 다 31자)
        // 이를 이용해 workingPath에서 프로젝트 루트와 서브디렉토리를 분리

        // worktree 접미사 제거: --claude-worktrees-xxx
        let baseProjectDir = projectDir.components(separatedBy: "--claude-worktrees").first ?? projectDir
        let projectRootLength = baseProjectDir.count

        guard workingPath.count >= projectRootLength else {
            return URL(fileURLWithPath: workingPath).lastPathComponent
        }

        let projectRoot = String(workingPath.prefix(projectRootLength))
        let projectName = URL(fileURLWithPath: projectRoot).lastPathComponent

        // workingPath가 프로젝트 루트보다 깊으면 서브디렉토리 표시
        // 단, .claude/worktrees/ 경로는 내부 워크트리 경로라 사용자에게 불필요 → 생략
        if workingPath.count > projectRootLength + 1 {
            let subdir = String(workingPath.dropFirst(projectRootLength + 1))
            if subdir.hasPrefix(".claude/worktrees/") { return projectName }
            return "\(projectName) (\(subdir))"
        }

        return projectName
    }
}

// MARK: - SessionMonitor

class SessionMonitor {
    private let projectsDirs: [URL]                            // 직접 스캔하는 정적 프로젝트 디렉토리
    private let watchedExtraDirs: [URL]                        // FSEvents 감시 추가 경로
    private let dispatchQueue = DispatchQueue(label: "com.sotthang.so-agentbar.sessionmonitor", qos: .utility)

    var onSessionsChanged: (([ClaudeSession]) -> Void)?

    private var eventStream: FSEventStreamRef?
    private var fallbackTimer: Timer?
    private var pollWorkItem: DispatchWorkItem?       // FSEvents 디바운스용
    private var fileOffsets: [String: UInt64] = [:]   // 파일별 마지막 읽은 바이트 위치
    private var sessionCache: [String: ClaudeSession] = [:]

    // Desktop Code: cliSessionId → (title, isArchived) 매핑 (claude-code-sessions/*.json 에서 로드)
    // isArchived=false인 세션만 Desktop으로 표시 (현재 Desktop에서 열려있는 세션)
    private var desktopCodeMeta: [String: (title: String, isArchived: Bool)] = [:]

    init() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        projectsDirs = [
            // CLI: claude 명령어로 실행한 세션
            home.appendingPathComponent(".claude/projects"),
            // Xcode: Coding Assistant에서 실행한 세션
            home.appendingPathComponent("Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/projects"),
        ]
        watchedExtraDirs = [
            home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions"),
            home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions"),
        ]
    }

    func start() {
        // 디렉토리가 없으면 미리 생성 (FSEvents가 감시할 수 있도록)
        for dir in projectsDirs {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // 앱 재시작 후에도 파일 오프셋 복원 (전체 재파싱 방지)
        loadFileOffsets()

        // 초기 폴링
        dispatchQueue.async { [weak self] in self?.poll() }

        // FSEvents: 파일 변경 시 자동으로 poll 트리거
        startFSEvents()

        // 안전장치: 30초마다 폴백 폴링 (FSEvents가 놓칠 경우 대비)
        DispatchQueue.main.async { [weak self] in
            self?.fallbackTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                self?.dispatchQueue.async { self?.poll() }
            }
        }
    }

    func stop() {
        stopFSEvents()
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    func updatePollInterval(_ interval: Double) {
        // FSEvents가 실시간 감지하므로 폴백 타이머 간격만 조정
        DispatchQueue.main.async { [weak self] in
            self?.fallbackTimer?.invalidate()
            self?.fallbackTimer = Timer.scheduledTimer(withTimeInterval: max(interval, 10), repeats: true) { [weak self] _ in
                self?.dispatchQueue.async { self?.poll() }
            }
        }
    }

    // MARK: - FSEvents 파일 시스템 감시

    private func startFSEvents() {
        let paths = (projectsDirs + watchedExtraDirs).map(\.path) as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientInfo, _, _, _, _ in
            guard let clientInfo else { return }
            let monitor = Unmanaged<SessionMonitor>.fromOpaque(clientInfo).takeUnretainedValue()
            monitor.scheduleDebouncedPoll()
        }

        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,  // 1초 내 이벤트 병합
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

    /// FSEvents 콜백 디바운스: 0.5초 내 중복 호출 병합
    private func scheduleDebouncedPoll() {
        pollWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.poll() }
        pollWorkItem = item
        dispatchQueue.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    // MARK: - 메인 루프

    private func poll() {
        let now = Date()
        var results: [ClaudeSession] = []

        // Desktop Code 메타데이터 갱신 (cliSessionId → title 매핑)
        loadDesktopCodeTitles()

        // (디렉토리 URL, 출처) 쌍으로 순회
        let staticProjectDirs: [(url: URL, source: SessionSource)] = [
            (projectsDirs[0], .cli),
            (projectsDirs[1], .xcode),
        ].flatMap { (baseDir, source) in
            ((try? FileManager.default.contentsOfDirectory(
                at: baseDir, includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []).map { (url: $0, source: source) }
        }

        let coworkProjectDirs: [(url: URL, source: SessionSource)] = discoverCoworkProjectDirs().flatMap { projectsDir in
            ((try? FileManager.default.contentsOfDirectory(
                at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []).map { (url: $0, source: SessionSource.desktopCowork) }
        }

        let projectDirs = staticProjectDirs + coworkProjectDirs

        for entry in projectDirs {
            guard entry.url.hasDirectoryPath else { continue }
            let folderName = entry.url.lastPathComponent

            // 직접 JSONL + 서브에이전트 JSONL 모두 수집
            let directJSONLs = activeJSONLs(in: entry.url, now: now)
            let subagentJSONLs = activeSubagentJSONLs(in: entry.url, now: now)

            for jsonlURL in directJSONLs + subagentJSONLs {
                guard let modDate = modificationDate(of: jsonlURL) else { continue }

                let isSubagent = subagentJSONLs.contains(jsonlURL)
                let sessionID = jsonlURL.deletingPathExtension().lastPathComponent
                var session = sessionCache[sessionID] ?? ClaudeSession(
                    id: sessionID,
                    projectDir: folderName,
                    source: entry.source,
                    workingPath: readCWD(from: jsonlURL) ?? entry.url.path,
                    lastModified: modDate,
                    lastActivity: modDate
                )

                session.lastModified = modDate
                session.isSubagent = isSubagent

                // Desktop Code 메타데이터 적용 (직접 JSONL에만 적용, 서브에이전트는 제외)
                // isArchived=false: 현재 Desktop에서 열려있는 세션 → Desktop으로 표시 + 클릭 시 Claude.app
                // isArchived=true: 이전에 Desktop에서 열었지만 지금은 닫힘 → CLI 유지, title만 적용
                if entry.source == .cli, directJSONLs.contains(jsonlURL),
                   let meta = desktopCodeMeta[sessionID] {
                    if !meta.isArchived {
                        session.source = .desktopCode
                    }
                    if session.title == nil, !meta.title.isEmpty {
                        session.title = meta.title
                    }
                }

                // 새로 추가된 줄만 파싱
                parseNewLines(url: jsonlURL, session: &session)

                sessionCache[sessionID] = session
                results.append(session)
            }
        }

        // 같은 프로젝트끼리 인접 + 각 그룹 내 최신순 정렬
        results.sort {
            if $0.projectDir == $1.projectDir {
                return $0.lastModified > $1.lastModified
            }
            // 프로젝트 그룹의 대표 시간 = 그룹 내 최신 세션
            return $0.lastModified > $1.lastModified
        }

        // 캐시 정리: 현재 결과에 없는 항목 제거 (24시간 필터에서 걸러진 오래된 세션)
        let activeIDs = Set(results.map(\.id))
        for key in sessionCache.keys where !activeIDs.contains(key) {
            sessionCache.removeValue(forKey: key)
        }
        for path in fileOffsets.keys {
            let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            if !activeIDs.contains(id) {
                fileOffsets.removeValue(forKey: path)
            }
        }

        // 안전장치: 캐시가 비정상적으로 클 경우 오래된 항목 제거
        if sessionCache.count > 500 {
            let excess = sessionCache.count - 400
            sessionCache.keys.prefix(excess).forEach { sessionCache.removeValue(forKey: $0) }
        }

        // 변경된 오프셋 영속화
        saveFileOffsets()

        DispatchQueue.main.async { [weak self] in
            self?.onSessionsChanged?(results)
        }
    }

    // MARK: - JSONL 파싱 (오프셋 기반)

    private func parseNewLines(url: URL, session: inout ClaudeSession) {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fileHandle.close() }

        let currentOffset = fileOffsets[url.path] ?? 0

        // 파일 크기 확인
        let fileSize = (try? fileHandle.seekToEnd()) ?? 0
        guard fileSize > currentOffset else { return }

        // 마지막으로 읽은 위치로 이동
        try? fileHandle.seek(toOffset: currentOffset)

        // 새로 추가된 데이터만 읽기
        let newData = fileHandle.readDataToEndOfFile()
        guard !newData.isEmpty else { return }

        // 마지막 개행 위치까지만 처리 — 파일 쓰는 도중인 불완전한 줄 제외
        // 개행이 없으면 아직 한 줄도 완성되지 않은 것이므로 전부 건너뜀
        let newlineByte = UInt8(ascii: "\n")
        guard let lastNewlineIdx = newData.lastIndex(of: newlineByte) else { return }

        // 완성된 줄까지만 슬라이싱 & 오프셋 전진
        // 나머지 부분 줄은 다음 폴링 때 재처리됨
        let completeData = newData[newData.startIndex...lastNewlineIdx]
        fileOffsets[url.path] = currentOffset + UInt64(completeData.count)

        guard let text = String(data: completeData, encoding: .utf8) else { return }

        // 완성된 줄만 파싱
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            processEvent(json, session: &session)
        }
    }

    private func processEvent(_ json: [String: Any], session: inout ClaudeSession) {
        guard let type = json["type"] as? String else { return }

        // 타임스탬프 업데이트
        if let tsStr = json["timestamp"] as? String,
           let ts = parseISO8601(tsStr), ts > session.lastActivity {
            session.lastActivity = ts
        }

        switch type {

        // ✅ 세션 완전 종료 감지
        case "result":
            session.sawResultEvent = true
            session.lastEventType = type
            // 에러 감지: isError 필드 또는 subtype == "error"
            if (json["isError"] as? Bool == true) ||
               (json["subtype"] as? String == "error") {
                session.sawErrorEvent = true
            }

        // Claude 응답 파싱
        case "assistant":
            guard let message = json["message"] as? [String: Any] else { return }

            // 모델명은 스트리밍 중에도 업데이트 (stop_reason 체크 전)
            if let model = message["model"] as? String {
                session.currentModel = model
            }

            let stopReason = message["stop_reason"] as? String

            // stop_reason이 nil인 경우: extended thinking 중간 스트림 or 텍스트 전용 이벤트
            if stopReason == nil {
                let content = message["content"] as? [[String: Any]] ?? []
                let types = Set(content.compactMap { $0["type"] as? String })

                // thinking 전용 이벤트 = extended thinking 시작 → 플래그 설정 후 무시
                if types.subtracting(["thinking"]).isEmpty {
                    session.currentTurnHadThinking = true
                    return
                }

                // 텍스트가 있는 경우:
                // - 같은 턴에 thinking이 있었다면 extended thinking 중간 이벤트 → 무시
                // - thinking이 없었다면 end_turn 누락 케이스(CLI 버그) → 응답 완료로 처리
                let hasText = types.contains("text")
                if hasText && !session.currentTurnHadThinking {
                    session.lastEventType = type
                    session.lastAssistantHasToolUse = false
                    let textParts = content
                        .filter { $0["type"] as? String == "text" }
                        .compactMap { $0["text"] as? String }
                    if let text = textParts.last, !text.isEmpty {
                        session.lastAssistantText = String(text.prefix(200))
                    }
                }
                return
            }

            // API 에러(stop_sequence 등)는 응답 완료가 아님 → 무시
            guard stopReason == "end_turn" || stopReason == "tool_use" else { return }

            session.lastEventType = type
            session.lastAssistantHasToolUse = stopReason == "tool_use"

            // 토큰 사용량 (모델별 누적)
            if let model = message["model"] as? String,
               let usage = message["usage"] as? [String: Any] {
                let input = (usage["input_tokens"] as? Int ?? 0)
                          + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                          + (usage["cache_read_input_tokens"] as? Int ?? 0)
                let output = usage["output_tokens"] as? Int ?? 0
                let existing = session.tokensByModel[model] ?? (0, 0)
                session.tokensByModel[model] = (existing.0 + input, existing.1 + output)
            }

            // 응답 텍스트 추출
            if let content = message["content"] as? [[String: Any]] {
                let textParts = content
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                if let text = textParts.last, !text.isEmpty {
                    // 처음 200자만 저장
                    session.lastAssistantText = String(text.prefix(200))
                }

                // tool 이름 기록 + 승인 대기 타이머 시작
                if stopReason == "tool_use",
                   let lastTool = content.last(where: { $0["type"] as? String == "tool_use" }),
                   let name = lastTool["name"] as? String {
                    session.lastToolName = name.lowercased()
                    session.lastToolUseTime = Date()
                }
            }

        // user 메시지 = 새 요청 시작 or 툴 결과 수신 (승인 완료)
        case "user":
            session.lastEventType = type
            session.lastToolUseTime = nil       // 승인 완료 → 대기 상태 해제
            session.currentTurnHadThinking = false  // 새 턴 시작 → thinking 플래그 리셋
            // cwd 필드가 있으면 정확한 경로로 업데이트
            if let cwd = json["cwd"] as? String {
                session.workingPath = cwd
            }
            if let mode = json["permissionMode"] as? String {
                session.permissionMode = mode
            }

        // AI 생성 제목
        case "ai-title":
            if let title = json["title"] as? String, !title.isEmpty {
                session.title = title
            }

        // Cowork 세션: queue-operation enqueue의 content를 title 폴백으로 사용
        // (ai-title 이벤트가 없거나 오래된 세션의 경우 사용자의 첫 요청으로 제목 표시)
        case "queue-operation":
            if session.source == .desktopCowork,
               (json["operation"] as? String) == "enqueue",
               session.title == nil,
               let content = json["content"] as? String,
               !content.isEmpty {
                // 단어 경계에서 자르기 (60자 초과 시 마지막 공백 위치에서 truncation)
                if content.count <= 60 {
                    session.title = content
                } else {
                    let prefix = String(content.prefix(57))
                    if let lastSpace = prefix.lastIndex(of: " ") {
                        session.title = String(prefix[..<lastSpace]) + "…"
                    } else {
                        session.title = prefix + "…"
                    }
                }
            }

        // 메타데이터 이벤트: 대화 상태와 무관 → lastEventType 덮어쓰지 않음
        // (end_turn 후 이런 이벤트가 오면 상태가 running으로 flicker → 중복 알림 발생 방지)
        case "progress", "file-history-snapshot", "last-prompt", "system":
            break

        default:
            session.lastEventType = type
        }
    }

    // MARK: - Desktop Code / Cowork 디렉토리 탐색

    /// claude-code-sessions 디렉토리를 스캔해 cliSessionId → (title, isArchived) 매핑 갱신
    private func loadDesktopCodeTitles() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let base = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        guard let userDirs = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return }

        var meta: [String: (title: String, isArchived: Bool)] = [:]
        for userDir in userDirs {
            guard let windowDirs = try? FileManager.default.contentsOfDirectory(at: userDir, includingPropertiesForKeys: nil) else { continue }
            for windowDir in windowDirs {
                guard let jsonFiles = try? FileManager.default.contentsOfDirectory(at: windowDir, includingPropertiesForKeys: nil) else { continue }
                for jsonFile in jsonFiles where jsonFile.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: jsonFile),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let cliSessionId = json["cliSessionId"] as? String else { continue }
                    let title = json["title"] as? String ?? ""
                    let isArchived = json["isArchived"] as? Bool ?? true
                    // 같은 세션에 여러 항목이 있으면 isArchived=false 우선
                    if let existing = meta[cliSessionId] {
                        if !isArchived && existing.isArchived {
                            meta[cliSessionId] = (title: title, isArchived: false)
                        }
                    } else {
                        meta[cliSessionId] = (title: title, isArchived: isArchived)
                    }
                }
            }
        }
        desktopCodeMeta = meta
    }

    /// local-agent-mode-sessions 아래의 모든 .claude/projects 디렉토리 반환
    private func discoverCoworkProjectDirs() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let base = home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
        let fm = FileManager.default
        var result: [URL] = []

        guard let userDirs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        for userDir in userDirs {
            guard userDir.hasDirectoryPath, looksLikeUUID(userDir.lastPathComponent) else { continue }
            guard let sessionDirs = try? fm.contentsOfDirectory(at: userDir, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for sessionDir in sessionDirs {
                guard sessionDir.hasDirectoryPath, looksLikeUUID(sessionDir.lastPathComponent) else { continue }
                guard let localDirs = try? fm.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
                for localDir in localDirs {
                    guard localDir.hasDirectoryPath else { continue }
                    let name = localDir.lastPathComponent
                    if name.hasPrefix("local_") {
                        let projectsDir = localDir.appendingPathComponent(".claude/projects")
                        if fm.fileExists(atPath: projectsDir.path) { result.append(projectsDir) }
                    } else if name == "agent" {
                        // agent/ 서브디렉토리 내 local_ditto_xxx 탐색
                        guard let agentSubDirs = try? fm.contentsOfDirectory(at: localDir, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
                        for agentSubDir in agentSubDirs where agentSubDir.hasDirectoryPath && agentSubDir.lastPathComponent.hasPrefix("local_") {
                            let projectsDir = agentSubDir.appendingPathComponent(".claude/projects")
                            if fm.fileExists(atPath: projectsDir.path) { result.append(projectsDir) }
                        }
                    }
                }
            }
        }
        return result
    }

    /// 디렉토리명이 UUID 형식인지 확인 (skills-plugin 등 제외용)
    private func looksLikeUUID(_ name: String) -> Bool {
        guard name.count == 36 else { return false }
        let chars = Array(name)
        return chars[8] == "-" && chars[13] == "-" && chars[18] == "-" && chars[23] == "-"
    }

    // MARK: - 유틸

    /// 프로젝트 디렉토리 내 24시간 이내 활성 JSONL 파일 목록 반환
    private func activeJSONLs(in projectURL: URL, now: Date) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: projectURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "jsonl" }
            .filter { url in
                guard let mod = modificationDate(of: url) else { return false }
                return now.timeIntervalSince(mod) < 86400
            }
            .sorted {
                (modificationDate(of: $0) ?? .distantPast) >
                (modificationDate(of: $1) ?? .distantPast)
            }
    }

    /// 프로젝트 디렉토리 내 서브에이전트 JSONL 파일 목록 반환
    /// 경로: {projectURL}/{sessionId}/subagents/agent-xxx.jsonl
    private func activeSubagentJSONLs(in projectURL: URL, now: Date) -> [URL] {
        guard let sessionDirs = try? FileManager.default.contentsOfDirectory(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var result: [URL] = []
        for sessionDir in sessionDirs {
            guard sessionDir.hasDirectoryPath else { continue }
            let subagentsDir = sessionDir.appendingPathComponent("subagents")
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: subagentsDir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            let recent = files
                .filter { $0.pathExtension == "jsonl" }
                .filter { url in
                    guard let mod = modificationDate(of: url) else { return false }
                    return now.timeIntervalSince(mod) < 86400
                }
            result.append(contentsOf: recent)
        }
        return result
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// JSONL 파일의 처음 몇 줄에서 cwd 필드를 읽어 정확한 프로젝트 경로 반환
    private func readCWD(from jsonlURL: URL) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: jsonlURL) else { return nil }
        defer { try? fileHandle.close() }

        // 첫 4KB만 읽으면 cwd가 포함된 초기 이벤트를 충분히 커버
        let data = fileHandle.readData(ofLength: 4096)
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let cwd = json["cwd"] as? String
            else { continue }
            return cwd
        }
        return nil
    }

    // MARK: - fileOffsets 영속화

    private func saveFileOffsets() {
        let encoded = Dictionary(uniqueKeysWithValues: fileOffsets.map { ($0.key, String($0.value)) })
        if let data = try? JSONEncoder().encode(encoded) {
            UserDefaults.standard.set(data, forKey: "fileOffsets")
        }
    }

    private func loadFileOffsets() {
        guard let data = UserDefaults.standard.data(forKey: "fileOffsets"),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        for (path, offsetStr) in dict {
            // 파일이 실제로 존재하고 오프셋이 파일 크기 이하인 경우만 복원
            if let offset = UInt64(offsetStr),
               let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? UInt64,
               offset <= size {
                fileOffsets[path] = offset
            }
        }
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func parseISO8601(_ str: String) -> Date? {
        Self.iso8601Formatter.date(from: str)
    }
}
