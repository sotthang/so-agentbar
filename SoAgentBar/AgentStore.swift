import Foundation
import Carbon.HIToolbox
import Combine
import AppKit
import UserNotifications

// MARK: - 언어 설정

enum AppLanguage: String, CaseIterable {
    case korean = "ko"
    case english = "en"

    var displayName: String {
        switch self {
        case .korean: return "한국어"
        case .english: return "English"
        }
    }
}

// MARK: - 메뉴바 스타일

enum MenubarStyle: String, CaseIterable {
    case emoji        // 🤖🤔😴
    case emojiCount   // 🤖 3
    case countOnly    // 3

    var displayName: String { "" } // SettingsView에서 직접 표시
}

// MARK: - 에디터 설정

enum OpenWith: String, CaseIterable {
    case vscode  = "vscode"
    case cursor  = "cursor"
    case terminal = "terminal"
    case finder  = "finder"

    var displayName: String {
        switch self {
        case .vscode:   return "VSCode"
        case .cursor:   return "Cursor"
        case .terminal: return "Terminal"
        case .finder:   return "Finder"
        }
    }

    static func open(path: String, source: SessionSource, cliEditor: OpenWith) {
        switch source {
        case .xcode:
            // Xcode 세션은 항상 Xcode로 열기
            let task = Process()
            task.launchPath = "/usr/bin/open"
            task.arguments = ["-a", "Xcode", path]
            try? task.run()
        case .cli:
            cliEditor.openInEditor(path: path)
        }
    }

    private func openInEditor(path: String) {
        switch self {
        case .vscode:
            let task = Process()
            task.launchPath = "/usr/bin/open"
            task.arguments = ["-a", "Visual Studio Code", path]
            try? task.run()
        case .cursor:
            let task = Process()
            task.launchPath = "/usr/bin/open"
            task.arguments = ["-a", "Cursor", path]
            try? task.run()
        case .terminal:
            let script = "tell application \"Terminal\"\nactivate\ndo script \"cd '\(path)'\"\nend tell"
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        case .finder:
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
}

// MARK: - 상태 모델

enum AgentStatus: Equatable {
    case idle
    case thinking
    case working
    case error

    var emoji: String {
        switch self {
        case .idle:     return "😴"
        case .thinking: return "🤔"
        case .working:  return "🤖"
        case .error:    return "😵"
        }
    }
}

struct Agent: Identifiable {
    let id: String
    var name: String
    var status: AgentStatus
    var currentTask: String
    var elapsedSeconds: Int
    var inputTokens: Int
    var outputTokens: Int
    var sessionID: String
    var workingPath: String
    var lastActivity: Date
    var source: SessionSource
    var lastResponse: String
    var pid: Int?

    var elapsedDisplay: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    var totalTokens: Int { inputTokens + outputTokens }
}

// MARK: - AgentStore

@MainActor
class AgentStore: ObservableObject {
    @Published var agents: [Agent] = []

    // 세션 설정
    @Published var showIdleSessions: Bool {
        didSet { UserDefaults.standard.set(showIdleSessions, forKey: "showIdleSessions") }
    }
    @Published var pollInterval: Double {
        didSet {
            UserDefaults.standard.set(pollInterval, forKey: "pollInterval")
            monitor.updatePollInterval(pollInterval)
        }
    }

    // 언어
    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") }
    }

    // 메뉴바 스타일
    @Published var menubarStyle: MenubarStyle {
        didSet { UserDefaults.standard.set(menubarStyle.rawValue, forKey: "menubarStyle") }
    }

    // 에디터
    @Published var openWith: OpenWith {
        didSet { UserDefaults.standard.set(openWith.rawValue, forKey: "openWith") }
    }

    // 팝오버 고정
    @Published var isPinned: Bool {
        didSet { UserDefaults.standard.set(isPinned, forKey: "isPinned") }
    }

    // 글로벌 핫키
    @Published var hotkeyEnabled: Bool {
        didSet { UserDefaults.standard.set(hotkeyEnabled, forKey: "hotkeyEnabled") }
    }
    @Published var hotkeyKeyCode: Int {
        didSet { UserDefaults.standard.set(hotkeyKeyCode, forKey: "hotkeyKeyCode") }
    }
    @Published var hotkeyModifiers: Int {
        didSet { UserDefaults.standard.set(hotkeyModifiers, forKey: "hotkeyModifiers") }
    }

    // 알림
    @Published var notifyOnComplete: Bool {
        didSet { UserDefaults.standard.set(notifyOnComplete, forKey: "notifyOnComplete") }
    }
    @Published var notifyOnError: Bool {
        didSet { UserDefaults.standard.set(notifyOnError, forKey: "notifyOnError") }
    }

    // 쿼터 알림
    @Published var notifyOnQuotaThreshold: Bool {
        didSet {
            UserDefaults.standard.set(notifyOnQuotaThreshold, forKey: "notifyOnQuotaThreshold")
            syncUsageMonitorSettings()
        }
    }
    @Published var notifyOnQuotaReset: Bool {
        didSet {
            UserDefaults.standard.set(notifyOnQuotaReset, forKey: "notifyOnQuotaReset")
            syncUsageMonitorSettings()
        }
    }
    @Published var sessionAlertThreshold: Double {
        didSet {
            UserDefaults.standard.set(sessionAlertThreshold, forKey: "sessionAlertThreshold")
            syncUsageMonitorSettings()
        }
    }

    func syncUsageMonitorSettings() {
        usageMonitor.alertThreshold     = sessionAlertThreshold
        usageMonitor.notifyOnThreshold  = notifyOnQuotaThreshold
        usageMonitor.notifyOnReset      = notifyOnQuotaReset
        usageMonitor.localizer          = { [weak self] ko, en in self?.t(ko, en) ?? ko }
    }

    // 프로젝트별 커스텀 이모지
    @Published var projectEmojis: [String: String] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(projectEmojis) {
                UserDefaults.standard.set(data, forKey: "projectEmojis")
            }
        }
    }

    func displayEmoji(for agent: Agent) -> String {
        projectEmojis[agent.id] ?? agent.status.emoji
    }

    func setEmoji(_ emoji: String, for agentId: String) {
        projectEmojis[agentId] = emoji
    }

    func resetEmoji(for agentId: String) {
        projectEmojis.removeValue(forKey: agentId)
    }

    private let monitor = SessionMonitor()
    let usageMonitor = UsageMonitor()
    let statsStore = StatsStore()
    private var elapsedTimer: Timer?
    private var previousStatuses: [String: AgentStatus] = [:]
    private var workingSince: [String: Date] = [:]  // working 시작 시각 추적
    private var recordedSessionIDs: Set<String> = [] // 이미 통계에 기록된 세션

    init() {
        self.showIdleSessions   = UserDefaults.standard.object(forKey: "showIdleSessions") as? Bool ?? true
        self.pollInterval       = UserDefaults.standard.object(forKey: "pollInterval") as? Double ?? 10.0
        self.language           = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "ko") ?? .korean
        self.menubarStyle       = MenubarStyle(rawValue: UserDefaults.standard.string(forKey: "menubarStyle") ?? "emoji") ?? .emoji
        self.openWith           = OpenWith(rawValue: UserDefaults.standard.string(forKey: "openWith") ?? "vscode") ?? .vscode
        self.isPinned                  = UserDefaults.standard.object(forKey: "isPinned") as? Bool ?? false
        self.hotkeyEnabled             = UserDefaults.standard.object(forKey: "hotkeyEnabled") as? Bool ?? true
        self.hotkeyKeyCode             = UserDefaults.standard.object(forKey: "hotkeyKeyCode") as? Int ?? Int(kVK_ANSI_S)
        self.hotkeyModifiers           = UserDefaults.standard.object(forKey: "hotkeyModifiers") as? Int ?? Int(optionKey | shiftKey)
        self.notifyOnComplete          = UserDefaults.standard.object(forKey: "notifyOnComplete") as? Bool ?? true
        self.notifyOnError             = UserDefaults.standard.object(forKey: "notifyOnError") as? Bool ?? true
        self.notifyOnQuotaThreshold    = UserDefaults.standard.object(forKey: "notifyOnQuotaThreshold") as? Bool ?? true
        self.notifyOnQuotaReset        = UserDefaults.standard.object(forKey: "notifyOnQuotaReset") as? Bool ?? true
        self.sessionAlertThreshold     = UserDefaults.standard.object(forKey: "sessionAlertThreshold") as? Double ?? 80

        if let data = UserDefaults.standard.data(forKey: "projectEmojis"),
           let emojis = try? JSONDecoder().decode([String: String].self, from: data) {
            self.projectEmojis = emojis
        }

        requestNotificationPermission()

        monitor.onSessionsChanged = { [weak self] sessions in
            // 현재 렌더 사이클이 끝난 뒤 실행되도록 한 번 더 async로 미룸
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.updateAgents(from: sessions)
                }
            }
        }
        monitor.start()
        syncUsageMonitorSettings()
        usageMonitor.start()

        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for i in self.agents.indices where self.agents[i].status == .working {
                    self.agents[i].elapsedSeconds += 1
                }
            }
        }
    }

    // MARK: - 번역 헬퍼

    func t(_ ko: String, _ en: String) -> String {
        language == .korean ? ko : en
    }

    func translateToolName(_ rawName: String) -> String {
        switch rawName {
        case "bash":      return t("터미널 실행 중", "Running terminal")
        case "read":      return t("파일 읽는 중", "Reading file")
        case "write":     return t("파일 쓰는 중", "Writing file")
        case "edit":      return t("파일 편집 중", "Editing file")
        case "glob":      return t("파일 검색 중", "Searching files")
        case "grep":      return t("코드 검색 중", "Searching code")
        case "webfetch":  return t("웹 가져오는 중", "Fetching webpage")
        case "websearch": return t("웹 검색 중", "Searching web")
        case "todowrite": return t("할 일 업데이트 중", "Updating todos")
        case "agent":     return t("서브에이전트 실행 중", "Running sub-agent")
        case "running":   return t("실행 중", "Running")
        default:          return t("\(rawName) 실행 중", "Running \(rawName)")
        }
    }

    func relativeTime(_ date: Date) -> String {
        let diff = Int(Date().timeIntervalSince(date))
        if language == .korean {
            if diff < 60    { return "\(diff)초 전" }
            if diff < 3600  { return "\(diff / 60)분 전" }
            if diff < 86400 { return "\(diff / 3600)시간 전" }
            return "\(diff / 86400)일 전"
        } else {
            if diff < 60    { return "\(diff)s ago" }
            if diff < 3600  { return "\(diff / 60)m ago" }
            if diff < 86400 { return "\(diff / 3600)h ago" }
            return "\(diff / 86400)d ago"
        }
    }

    // MARK: - 핫키 표시

    var hotkeyDisplayString: String {
        var mods = ""
        if hotkeyModifiers & Int(controlKey) != 0 { mods += "⌃" }
        if hotkeyModifiers & Int(optionKey) != 0  { mods += "⌥" }
        if hotkeyModifiers & Int(shiftKey) != 0   { mods += "⇧" }
        if hotkeyModifiers & Int(cmdKey) != 0     { mods += "⌘" }
        return mods + Self.keyCodeName(hotkeyKeyCode)
    }

    static func keyCodeName(_ code: Int) -> String {
        let map: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
            43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
            49: "Space", 50: "`",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 103: "F11", 109: "F10", 111: "F12",
            118: "F4", 119: "F2", 120: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return map[code] ?? "?"
    }

    static func nsModifiersToCarbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var carbon = 0
        if flags.contains(.control) { carbon |= Int(controlKey) }
        if flags.contains(.option)  { carbon |= Int(optionKey) }
        if flags.contains(.shift)   { carbon |= Int(shiftKey) }
        if flags.contains(.command) { carbon |= Int(cmdKey) }
        return carbon
    }

    // MARK: - 프로젝트 열기

    func openProject(_ path: String, source: SessionSource) {
        OpenWith.open(path: path, source: source, cliEditor: openWith)
    }

    // MARK: - 알림

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - 세션 업데이트

    private func updateAgents(from sessions: [ClaudeSession]) {
        let filtered = showIdleSessions
            ? sessions
            : sessions.filter { $0.sessionStatus == .running || $0.sessionStatus == .responded }

        let newAgents = filtered.map { session in
            let status: AgentStatus
            let task: String

            switch session.sessionStatus {
            case .running:
                status = .working
                task = translateToolName(session.lastToolName)
            case .responded:
                status = .thinking
                task = t("응답 완료 · 입력 대기", "Responded · waiting for input")
            case .completed:
                status = .idle
                task = t("세션 종료", "Session ended")
            case .idle:
                status = .idle
                task = t("대기 중", "Idle")
            }

            let existing = agents.first(where: { $0.id == session.id })
            let elapsed = session.sessionStatus == .running ? (existing?.elapsedSeconds ?? 0) : 0

            return Agent(
                id: session.id,
                name: session.displayName,
                status: status,
                currentTask: task,
                elapsedSeconds: elapsed,
                inputTokens: session.inputTokens,
                outputTokens: session.outputTokens,
                sessionID: session.id,
                workingPath: session.workingPath,
                lastActivity: session.lastActivity,
                source: session.source,
                lastResponse: session.lastAssistantText,
                pid: nil
            )
        }

        // 상태 변화 감지 → 알림
        for agent in newAgents {
            let prev = previousStatuses[agent.id]

            // working 시작 시각 기록
            if agent.status == .working, prev != .working {
                workingSince[agent.id] = Date()
            }

            // working → thinking = JSONL에서 "assistant" (tool 없음) 이벤트 감지
            // = Claude가 실제로 응답 완료한 순간
            if notifyOnComplete,
               prev == .working,
               agent.status == .thinking,
               let since = workingSince[agent.id],
               Date().timeIntervalSince(since) >= 10 {
                sendNotification(
                    title: t("응답 완료", "Response ready"),
                    body: "\(agent.name) — \(t("Claude가 응답했습니다", "Claude responded"))"
                )
                workingSince.removeValue(forKey: agent.id)
            }

            if notifyOnError, agent.status == .error, prev != .error {
                sendNotification(
                    title: t("에러 발생", "Error occurred"),
                    body: "\(agent.name) — \(t("에러가 발생했습니다", "encountered an error"))"
                )
            }

            // 통계 기록: 토큰이 있는 세션이 idle/completed로 전환될 때 1회 기록
            if (agent.status == .idle || agent.status == .thinking),
               prev == .working,
               agent.totalTokens > 0,
               !recordedSessionIDs.contains(agent.id) {
                recordedSessionIDs.insert(agent.id)
                statsStore.record(agent: agent)
            }

            previousStatuses[agent.id] = agent.status
        }

        agents = newAgents
    }
}
