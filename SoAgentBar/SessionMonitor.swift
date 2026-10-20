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
    case codexCLI      // [NEW] OpenAI Codex CLI
    case codexVSCode   // [NEW] OpenAI Codex VSCode 확장

    /// Codex 계열 여부
    var isCodexFamily: Bool {
        switch self {
        case .codexCLI, .codexVSCode: return true
        default: return false
        }
    }
}

// MARK: - Claude 세션 모델

struct ClaudeSession: Identifiable {
    let id: String
    let projectDir: String
    var source: SessionSource
    var workingPath: String
    var lastModified: Date
    var lastActivity: Date
    var lastContentChange: Date  // 실제로 새 jsonl 줄이 파싱된 시각 (mtime 단순 갱신 제외)

    // JSONL 파싱 상태 (오프셋 기반으로 누적)
    var sawResultEvent: Bool = false
    var sawErrorEvent: Bool = false
    var lastEventType: String = ""         // "user", "assistant", "tool_result", "result"
    var lastAssistantHasToolUse: Bool = false
    var lastToolUseTime: Date? = nil       // tool_use 감지 시각 (승인 대기 판단용)
    // 모델별 누적 토큰 — TokenUsage struct (cachedInput, reasoningOutput 포함)
    struct TokenUsage: Codable, Equatable {  // Codable: 파싱 상태 스냅샷 영속화 (PERF-004)
        var input: Int = 0
        var cachedInput: Int = 0
        var output: Int = 0
        var reasoningOutput: Int = 0
    }
    var tokensByModel: [String: TokenUsage] = [:]  // 모델별 누적 토큰
    var lastToolName: String = "running"
    var lastAssistantText: String = ""      // 마지막 Claude 응답 미리보기
    var currentModel: String = ""           // 마지막 assistant 이벤트의 모델명
    var permissionMode: String = "default"  // "default", "acceptEdits", "plan", "auto", "bypassPermissions"
    var title: String? = nil                // AI 생성 제목 (ai-title 이벤트 또는 Desktop 메타데이터)
    var currentTurnHadThinking: Bool = false // 현재 턴에 extended thinking이 있었는지 (중간 텍스트 오탐 방지)
    var isSubagent: Bool = false             // subagents/ 하위 JSONL 여부 (알람 제외 대상)
    var parentSessionId: String? = nil       // 서브에이전트인 경우 부모 세션 ID
    // 부모 세션 한정: spawn한 서브에이전트의 agentId → (type, description) 매핑
    // (Agent tool_use → tool_result 쌍을 파싱해서 채워짐, 완료된 서브만 등록됨)
    var subagentMeta: [String: (type: String, description: String)] = [:]
    // 부모 세션 한정: tool_use_id → (type, description) 임시 저장 (tool_result 도착 전)
    var pendingAgentSpawns: [String: (type: String, description: String)] = [:]

    var totalTokens: Int {
        tokensByModel.values.reduce(0) { $0 + $1.input + $1.output }
    }

    var estimatedCost: Double? {
        let costs = tokensByModel.compactMap { (model, tokens) in
            CostCalculator.estimate(
                model: model,
                inputTokens: tokens.input,
                cachedInputTokens: tokens.cachedInput,
                outputTokens: tokens.output
            )
        }
        guard !costs.isEmpty else { return nil }
        return costs.reduce(0, +)
    }

    // Codex 전용 필드 (Claude 세션에서는 항상 기본값 유지)
    var codexApprovalPolicy: String? = nil
    var codexErrorInfo: String? = nil
    var codexLastTurnDurationMs: Int? = nil
    var codexSawResultEvent: Bool = false
    var codexSawErrorEvent: Bool = false

    // Source-aware status dispatcher
    var displayStatus: SessionStatus {
        switch source {
        case .codexCLI, .codexVSCode:
            return codexSessionStatus
        default:
            return sessionStatus
        }
    }

    private var codexSessionStatus: SessionStatus {
        if codexSawErrorEvent {
            return .error
        }
        if codexSawResultEvent {
            return .completed
        }
        let age = Date().timeIntervalSince(lastContentChange)
        if age > 300 { return .idle }
        if codexApprovalPolicy == "on-request",
           let toolTime = lastToolUseTime,
           Date().timeIntervalSince(toolTime) > 5 {
            return .waitingForApproval
        }
        if (lastEventType == "assistant" || lastEventType == "task_complete"),
           age >= 5 {
            return .responded
        }
        if (lastEventType == "task_started" || lastEventType == "user"),
           age < 5 {
            return .running
        }
        return .running
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

        // 상태 판정은 실제 새 이벤트 파싱 시각 기준 (단순 mtime 갱신은 무시)
        let age = Date().timeIntervalSince(lastContentChange)

        // 5분 이상 = idle
        if age > 300 { return .idle }

        // 마지막 이벤트로 판단
        // assistant with text only → Claude가 방금 응답 완료
        if lastEventType == "assistant" && !lastAssistantHasToolUse {
            return .responded
        }

        // tool_use 후 jsonl이 일정 시간 정적 → 사용자 승인 대기로 간주
        // 주의: Claude Code는 도구 실행 중 jsonl에 진행 이벤트를 쓰지 않는다.
        // 따라서 "실행 중인 긴 명령"과 "승인 대기"는 jsonl만으로는 구분 불가.
        // → Bash처럼 오래 걸릴 수 있는 도구는 임계값을 크게 잡아 오탐을 줄인다.
        //   (pytest/서버/빌드 등 10분까지 가는 명령이 흔함)
        // 단, 현재 permissionMode에서 자동 승인되는 도구는 제외.
        if lastAssistantHasToolUse, let toolUseTime = lastToolUseTime,
           !isToolAutoApproved(lastToolName) {
            let timeSinceToolUse = Date().timeIntervalSince(toolUseTime)
            let threshold: TimeInterval = (lastToolName == "bash") ? 600 : 5
            if timeSinceToolUse > threshold && age > threshold {
                return .waitingForApproval
            }
        }

        // tool_result, assistant with tool_use, user → 아직 실행 중
        return .running
    }

    var displayName: String {
        // AI 생성 제목이 있으면 우선 사용
        if let title, !title.isEmpty { return title }

        // workingPath가 jsonl 저장소 내부면 readCWD()가 실패한 fallback 상태.
        // 이 경우 길이 기반 분할을 적용하면 "/Users/hs_so/.claude/projects/-U" 처럼
        // 엉뚱한 위치에서 잘려서 깨진 이름이 나옴 → projectDir 기반 best-effort 이름으로 표시.
        if workingPath.contains("/.claude/projects/") || workingPath.isEmpty {
            // "-Users-hs-so-Develop-Dcty-Agent" → "Dcty-Agent" 비슷하게 추정 불가능(인코딩 lossy)
            // → 그냥 인코딩된 형태에서 앞 prefix를 떼고 보여줌
            let trimmed = projectDir.hasPrefix("-") ? String(projectDir.dropFirst()) : projectDir
            return trimmed
        }

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

// MARK: - ClaudeSessionMonitor

class ClaudeSessionMonitor: SessionMonitorProtocol {
    private let projectsDirs: [URL]                            // 직접 스캔하는 정적 프로젝트 디렉토리
    private let watchedExtraDirs: [URL]                        // FSEvents 감시 추가 경로
    // .workItem: 작업 단위마다 autorelease pool을 비운다 — 기본값(.inherit)이면 큐가 쉬지 못할 때
    // 스레드 pool이 비워지지 않아 파일 Data/JSON 트리가 계속 쌓인다 (PERF-003)
    private let dispatchQueue = DispatchQueue(
        label: "com.sotthang.so-agentbar.sessionmonitor", qos: .utility, autoreleaseFrequency: .workItem
    )
    // 폴링 병합: 큐에 대기 중인 폴링이 있으면 새 요청은 버린다 (진행 중 폴링 뒤로 최대 1회만 대기)
    private let pollRequestLock = NSLock()
    private var isPollQueued = false

    var onSessionsChanged: (([ClaudeSession]) -> Void)?

    private var eventStream: FSEventStreamRef?
    private var fallbackTimer: Timer?
    private var pollWorkItem: DispatchWorkItem?       // FSEvents 디바운스용
    private var fileOffsets: [String: UInt64] = [:]   // 파일별 마지막 읽은 바이트 위치
    // 파일 경로 → 누적 파싱 상태(ClaudeSession). fileOffsets와 같은 키를 써서
    // 캐시에 상태가 남아 있는 한 오프셋이 절대 리셋되지 않도록 한다 (PERF-001)
    private var sessionCache: [String: ClaudeSession] = [:]
    private var fileIDs: [String: UInt64] = [:]        // 파일별 inode (마지막으로 새 줄을 읽었을 때)

    // PERF-004: 파싱 상태 스냅샷 영속화 — 재시작 후 오프셋 0부터의 전체 재파싱 방지
    private let parseStateStore: SessionParseStateStore?
    private let parseStateSaveInterval: TimeInterval
    private var restoredSnapshots: [String: SessionParseSnapshot]? = nil  // 첫 폴링 전 lazy 로드, 첫 폴링 후 비움
    private var isParseStateDirty = false
    private var lastParseStateSave: Date? = nil

    // Desktop Code: cliSessionId → (title, isArchived) 매핑 (claude-code-sessions/*.json 에서 로드)
    // isArchived=false인 세션만 Desktop으로 표시 (현재 Desktop에서 열려있는 세션)
    private var desktopCodeMeta: [String: (title: String, isArchived: Bool)] = [:]

    private let desktopCodeSessionsDir: URL                    // Desktop Code 메타데이터(claude-code-sessions)
    private let coworkSessionsDir: URL                         // Cowork VM 세션(local-agent-mode-sessions)
    private let defaults: UserDefaults                         // 구버전 fileOffsets 키 정리용
    private let now: () -> Date                                // poll 기준 시각 (24시간 필터)
    private let makeByteSource: (URL) -> ByteSource?           // JSONL 파일 읽기 원천

    /// 프로덕션 기본 경로(홈 디렉토리 기준)로 생성
    convenience init() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        self.init(
            // CLI: claude 명령어로 실행한 세션
            cliProjectsDir: home.appendingPathComponent(".claude/projects"),
            // Xcode: Coding Assistant에서 실행한 세션
            xcodeProjectsDir: home.appendingPathComponent("Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/projects"),
            desktopCodeSessionsDir: home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions"),
            coworkSessionsDir: home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions"),
            parseStateStore: FileSessionParseStateStore.applicationSupportStore()
        )
    }

    /// 의존성 주입용 지정 이니셜라이저 (테스트에서는 임시 디렉토리 / 전용 UserDefaults / spy ByteSource 사용)
    init(
        cliProjectsDir: URL,
        xcodeProjectsDir: URL,
        desktopCodeSessionsDir: URL,
        coworkSessionsDir: URL,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        makeByteSource: @escaping (URL) -> ByteSource? = { FileByteSource(url: $0) },
        parseStateStore: SessionParseStateStore? = nil,     // nil = 영속화 안 함 (테스트 기본값)
        parseStateSaveInterval: TimeInterval = 15
    ) {
        projectsDirs = [cliProjectsDir, xcodeProjectsDir]
        watchedExtraDirs = [desktopCodeSessionsDir, coworkSessionsDir]
        self.desktopCodeSessionsDir = desktopCodeSessionsDir
        self.coworkSessionsDir = coworkSessionsDir
        self.defaults = defaults
        self.now = now
        self.makeByteSource = makeByteSource
        self.parseStateStore = parseStateStore
        self.parseStateSaveInterval = parseStateSaveInterval
    }

    func start() {
        // 디렉토리가 없으면 미리 생성 (FSEvents가 감시할 수 있도록)
        for dir in projectsDirs {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // 구버전이 UserDefaults에 저장하던 fileOffsets는 더 이상 쓰지 않는다 (PERF-004: 스냅샷으로 대체)
        defaults.removeObject(forKey: "fileOffsets")

        // 초기 폴링
        requestPoll()

        // FSEvents: 파일 변경 시 자동으로 poll 트리거
        startFSEvents()

        // 안전장치: 30초마다 폴백 폴링 (FSEvents가 놓칠 경우 대비)
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
        flushParseState()
    }

    /// 스로틀로 밀린 파싱 상태 변경을 즉시 저장한다 (앱 종료 시).
    /// 폴링과 같은 직렬 큐에서 실행해 상태 접근을 직렬화한다 — dispatchQueue 위에서 호출하면 안 된다.
    func flushParseState() {
        dispatchQueue.sync {
            if isParseStateDirty { saveParseState(at: now()) }
        }
    }

    func updatePollInterval(_ interval: Double) {
        // FSEvents가 실시간 감지하므로 폴백 타이머 간격만 조정
        DispatchQueue.main.async { [weak self] in
            self?.fallbackTimer?.invalidate()
            self?.fallbackTimer = Timer.scheduledTimer(withTimeInterval: max(interval, 10), repeats: true) { [weak self] _ in
                self?.requestPoll()
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
            let monitor = Unmanaged<ClaudeSessionMonitor>.fromOpaque(clientInfo).takeUnretainedValue()
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
        let item = DispatchWorkItem { [weak self] in self?.requestPoll() }
        pollWorkItem = item
        dispatchQueue.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    // MARK: - 메인 루프

    /// 폴링 요청의 단일 진입점 (초기 폴링 / 폴백 타이머 / FSEvents 디바운스).
    /// 폴링이 진행 중이거나 대기 중이면 병합되어, 진행 중 폴링이 끝난 뒤 최대 1회만 추가 실행된다 (PERF-003).
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

        // Desktop Code 메타데이터 갱신 (cliSessionId → title 매핑)
        loadDesktopCodeTitles()

        // 이전 실행이 저장한 파싱 상태 스냅샷 (프로세스 생애 동안 한 번만 로드)
        if restoredSnapshots == nil {
            restoredSnapshots = parseStateStore?.load() ?? [:]
        }

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
                // 파일마다 읽은 Data/파싱 결과의 autorelease 객체를 즉시 해제 (PERF-003)
                autoreleasepool {
                    guard let modDate = modificationDate(of: jsonlURL) else { return }

                    let isSubagent = subagentJSONLs.contains(jsonlURL)
                    let fileStem = jsonlURL.deletingPathExtension().lastPathComponent
                    // 서브에이전트 jsonl 경로: {projectURL}/{parentSessionId}/subagents/agent-xxx.jsonl
                    // → 두 단계 위 디렉토리 이름이 부모 sessionId
                    let parentSessionId: String? = isSubagent
                        ? jsonlURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                        : nil
                    // resume/fork 시 같은 이름의 서브 jsonl이 여러 부모 아래 복제되므로
                    // 서브에이전트 id는 "{부모id}/{파일명}"으로 한정한다. 최상위 세션 id(UUID 파일명)는 그대로 (PERF-006)
                    let sessionID = parentSessionId.map { "\($0)/\(fileStem)" } ?? fileStem

                    // 캐시 미스 = 앱 재시작 직후 또는 새 세션
                    // → 유효한 스냅샷이 있으면 그 상태·오프셋부터 이어 읽고, 없으면 처음부터 재파싱 (PERF-004)
                    let cacheKey = jsonlURL.path
                    let cached = sessionCache[cacheKey]
                    var session: ClaudeSession
                    if let cached {
                        session = cached
                    } else {
                        fileOffsets.removeValue(forKey: cacheKey)
                        fileIDs.removeValue(forKey: cacheKey)
                        session = ClaudeSession(
                            id: sessionID,
                            projectDir: folderName,
                            source: entry.source,
                            workingPath: entry.url.path,
                            lastModified: modDate,
                            lastActivity: .distantPast,  // 파싱 중 이벤트 timestamp로 채워짐
                            lastContentChange: .distantPast
                        )
                        if let snapshot = restoredSnapshots?.removeValue(forKey: cacheKey),
                           isSnapshotUsable(snapshot, for: jsonlURL) {
                            snapshot.apply(to: &session)
                            fileOffsets[cacheKey] = snapshot.offset
                            fileIDs[cacheKey] = snapshot.fileID
                        } else {
                            session.workingPath = readCWD(from: jsonlURL) ?? entry.url.path
                        }
                    }

                    session.lastModified = modDate
                    session.isSubagent = isSubagent
                    session.parentSessionId = parentSessionId

                    // 캐시된 workingPath가 fallback 상태(.claude/projects 내부)면 매 폴링마다 재시도
                    if session.workingPath.contains("/.claude/projects/"),
                       let cwd = readCWD(from: jsonlURL) {
                        session.workingPath = cwd
                    }

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

                    sessionCache[cacheKey] = session
                    activePaths.insert(cacheKey)
                    results.append(session)
                }
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

        // 캐시 정리: 이번 폴링에 없는 파일 제거 (24시간 필터에서 걸러진 오래된 세션)
        // 활성 파일 수로 캐시 크기가 제한되므로 별도 개수 상한은 두지 않는다 —
        // 활성 세션을 쫓아내면 다음 폴링에서 오프셋 0부터 전체 재파싱된다 (PERF-001)
        for key in sessionCache.keys where !activePaths.contains(key) {
            sessionCache.removeValue(forKey: key)
        }
        for path in fileOffsets.keys where !activePaths.contains(path) {
            fileOffsets.removeValue(forKey: path)
            isParseStateDirty = true
        }
        for path in fileIDs.keys where !activePaths.contains(path) {
            fileIDs.removeValue(forKey: path)
        }
        // 이번 폴링에서 쓰이지 않은 복원 스냅샷 = 비활성 파일 → 버리고 저장본에서도 제거
        if restoredSnapshots?.isEmpty == false {
            isParseStateDirty = true
        }
        restoredSnapshots = [:]

        // pendingAgentSpawns가 tool_result를 못 받고 누적되는 것 방지 (Agent 호출당 최대 32개)
        for key in sessionCache.keys {
            guard var s = sessionCache[key], s.pendingAgentSpawns.count > 32 else { continue }
            let toDrop = s.pendingAgentSpawns.count - 32
            s.pendingAgentSpawns.keys.prefix(toDrop).forEach { s.pendingAgentSpawns.removeValue(forKey: $0) }
            sessionCache[key] = s
        }

        // 변경된 파싱 상태 영속화 (첫 저장은 즉시, 이후 parseStateSaveInterval마다 최대 1회)
        if isParseStateDirty,
           lastParseStateSave.map({ now.timeIntervalSince($0) >= parseStateSaveInterval }) ?? true {
            saveParseState(at: now)
        }

        return results
    }

    // MARK: - JSONL 파싱 (오프셋 기반)

    private func parseNewLines(url: URL, session: inout ClaudeSession) {
        guard let source = makeByteSource(url) else { return }

        let currentOffset = fileOffsets[url.path] ?? 0

        // 실제 파싱된 이벤트의 timestamp를 기준으로 lastContentChange 갱신
        // (processEvent에서 session.lastActivity를 이벤트 timestamp로 업데이트하므로
        //  파싱 전 스냅샷과 비교해서 바뀌었으면 "새 이벤트가 있었다"고 판단)
        let activityBefore = session.lastActivity

        let nextOffset = JSONLReader.readCompleteLines(from: source, startingAt: currentOffset) { json in
            processEvent(json, session: &session)
        }
        if let nextOffset {
            fileOffsets[url.path] = nextOffset
            fileIDs[url.path] = Self.fileAttributes(of: url)?.fileID
            isParseStateDirty = true
        }

        // 파싱 후 lastActivity가 실제로 전진했으면 그 timestamp를 lastContentChange로 사용
        // (앱 재시작 시 과거 이벤트를 한꺼번에 읽어도 "지금 활동 중"으로 오판되지 않음)
        if session.lastActivity > activityBefore {
            session.lastContentChange = session.lastActivity
        }
    }

    internal func processEvent(_ json: [String: Any], session: inout ClaudeSession) {
        guard let type = json["type"] as? String else { return }

        // 타임스탬프 업데이트
        if let tsStr = json["timestamp"] as? String,
           let ts = SessionDateUtil.parseISO8601(tsStr), ts > session.lastActivity {
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

            // extended thinking이 켜진 턴은 thinking 블록만 가진 end_turn 이벤트가
            // 먼저 도착하고, 실제 텍스트 응답은 다음 end_turn 이벤트로 따라온다.
            // 첫 이벤트를 응답 완료로 처리하면 알람이 일찍 울리고 본문이 이전 턴 텍스트가 된다.
            if stopReason == "end_turn",
               let content = message["content"] as? [[String: Any]] {
                let types = Set(content.compactMap { $0["type"] as? String })
                if !types.isEmpty && types.subtracting(["thinking"]).isEmpty {
                    session.currentTurnHadThinking = true
                    return
                }
            }

            session.lastEventType = type
            session.lastAssistantHasToolUse = stopReason == "tool_use"

            // 토큰 사용량 (모델별 누적)
            if let model = message["model"] as? String,
               let usage = message["usage"] as? [String: Any] {
                let input = (usage["input_tokens"] as? Int ?? 0)
                          + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                          + (usage["cache_read_input_tokens"] as? Int ?? 0)
                let output = usage["output_tokens"] as? Int ?? 0
                let existing = session.tokensByModel[model] ?? ClaudeSession.TokenUsage()
                session.tokensByModel[model] = ClaudeSession.TokenUsage(
                    input: existing.input + input,
                    cachedInput: existing.cachedInput,
                    output: existing.output + output,
                    reasoningOutput: existing.reasoningOutput
                )
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
                // 이벤트 timestamp를 기준으로 해야 앱 재시작 시 과거 이벤트를 "방금 tool_use"로 오판하지 않음
                if stopReason == "tool_use",
                   let lastTool = content.last(where: { $0["type"] as? String == "tool_use" }),
                   let name = lastTool["name"] as? String {
                    session.lastToolName = name.lowercased()
                    if let tsStr = json["timestamp"] as? String, let ts = SessionDateUtil.parseISO8601(tsStr) {
                        session.lastToolUseTime = ts
                    } else {
                        session.lastToolUseTime = Date()
                    }
                }

                // Agent tool_use(서브에이전트 spawn) 감지 → tool_use_id로 임시 저장
                // 나중에 같은 id의 tool_result에서 agentId가 나오면 확정 매핑
                for item in content where item["type"] as? String == "tool_use" {
                    guard let name = item["name"] as? String, name == "Agent",
                          let id = item["id"] as? String,
                          let input = item["input"] as? [String: Any],
                          let subagentType = input["subagent_type"] as? String else { continue }
                    let desc = (input["description"] as? String) ?? ""
                    session.pendingAgentSpawns[id] = (type: subagentType, description: desc)
                }
            }

        // user 메시지 = 새 요청 시작 or 툴 결과 수신 (승인 완료)
        case "user":
            // 세션 resume 감지: 이전에 result/error로 종료된 세션에 새 user 이벤트가 오면 부활
            // (같은 jsonl에서 사용자가 대화를 이어서 시작하는 케이스)
            if session.sawResultEvent {
                session.sawResultEvent = false
                session.sawErrorEvent = false
            }
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

            // Agent tool 결과인 경우: toolUseResult.agentId / agentType 추출하여 확정 매핑
            // (subagent jsonl 파일명이 "agent-{agentId}.jsonl"이라 이걸로 매칭됨)
            if let toolUseResult = json["toolUseResult"] as? [String: Any],
               let agentId = toolUseResult["agentId"] as? String {
                let agentType = (toolUseResult["agentType"] as? String) ?? ""
                // tool_use_id로 description 회수
                var description = ""
                if let message = json["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]],
                   let firstResult = content.first(where: { $0["type"] as? String == "tool_result" }),
                   let toolUseId = firstResult["tool_use_id"] as? String,
                   let pending = session.pendingAgentSpawns[toolUseId] {
                    description = pending.description
                    session.pendingAgentSpawns.removeValue(forKey: toolUseId)
                }
                if !agentType.isEmpty {
                    session.subagentMeta[agentId] = (type: agentType, description: description)
                }
            }

        // AI 생성 제목
        case "ai-title":
            if let title = json["title"] as? String, !title.isEmpty {
                session.title = title
            }

        // Cowork 세션: queue-operation enqueue의 content를 title 폴백으로 사용
        // (ai-title 이벤트가 없거나 오래된 세션의 경우 사용자의 첫 요청으로 제목 표시)
        // <scheduled-task> 래퍼는 boilerplate를 제거하고 실제 프롬프트만 사용
        // 시각적 truncation은 뷰에서 처리 — 전체 텍스트는 hover 툴팁에서 보여주기 위해 보존
        case "queue-operation":
            if session.source == .desktopCowork,
               (json["operation"] as? String) == "enqueue",
               session.title == nil,
               let content = json["content"] as? String,
               !content.isEmpty {
                let raw: String
                if let parsed = ScheduledTaskParser.parse(content) {
                    raw = parsed.displayTitle
                } else {
                    raw = content
                }
                // 메모리 보호용 hard cap (악의적 JSONL이 거대한 content를 쓰는 경우 방어)
                // 시각적 truncation은 SwiftUI가, 전체 텍스트는 .help() 툴팁이 처리
                session.title = String(raw.prefix(500))
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
        let base = desktopCodeSessionsDir
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
        let base = coworkSessionsDir
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

    /// JSONL 파일에서 cwd 필드를 가진 첫 이벤트를 찾아 반환
    /// queue-operation 등 큰 메타 이벤트가 앞에 있을 수 있어 청크 단위로 확장 탐색
    private func readCWD(from jsonlURL: URL) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: jsonlURL) else { return nil }
        defer { try? fileHandle.close() }

        let chunkSize = 16384
        let maxBytes = 262144 // 256KB까지 확장 (큰 메타 이벤트 대비)
        var accumulated = Data()
        while accumulated.count < maxBytes {
            let chunk = fileHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            accumulated.append(chunk)

            // 마지막 개행까지만 안전하게 파싱
            let newlineByte = UInt8(ascii: "\n")
            guard let lastNewlineIdx = accumulated.lastIndex(of: newlineByte) else { continue }
            let parsable = accumulated[accumulated.startIndex...lastNewlineIdx]
            guard let text = String(data: parsable, encoding: .utf8) else { continue }

            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                      let lineData = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let cwd = json["cwd"] as? String
                else { continue }
                return cwd
            }
        }
        return nil
    }

    // MARK: - 파싱 상태 영속화 (PERF-004)

    private static func fileAttributes(of url: URL) -> (fileID: UInt64?, size: UInt64)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return nil }
        return ((attrs[.systemFileNumber] as? NSNumber)?.uint64Value, size)
    }

    /// 같은 파일(inode)이고 저장 오프셋 이후로만 자랐을 때만 스냅샷을 이어 쓴다.
    /// 잘림(size < offset)·교체(inode 변경)는 전체 재파싱한다.
    private func isSnapshotUsable(_ snapshot: SessionParseSnapshot, for url: URL) -> Bool {
        guard let attrs = Self.fileAttributes(of: url) else { return false }
        return attrs.size >= snapshot.offset && attrs.fileID == snapshot.fileID
    }

    private func saveParseState(at date: Date) {
        guard let parseStateStore else { return }
        var snapshots: [String: SessionParseSnapshot] = [:]
        for (path, offset) in fileOffsets {
            guard let session = sessionCache[path] else { continue }
            snapshots[path] = SessionParseSnapshot(session: session, offset: offset, fileID: fileIDs[path])
        }
        parseStateStore.save(snapshots)
        isParseStateDirty = false
        lastParseStateSave = date
    }

}
