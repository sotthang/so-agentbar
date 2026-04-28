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

// MARK: - 리스트 스타일

enum ListStyle: String, CaseIterable {
    case flat    // 플랫 리스트
    case grouped // 프로젝트 그룹 (트리형)
}

// MARK: - 에디터 설정

enum OpenWith: String, CaseIterable {
    case vscode       = "vscode"
    case cursor       = "cursor"
    case antigravity  = "antigravity"
    case intellij     = "intellij"
    case intellijCE   = "intellijCE"
    case pycharm      = "pycharm"
    case pycharmCE    = "pycharmCE"
    case webstorm     = "webstorm"
    case androidStudio = "androidStudio"
    case zed          = "zed"
    case windsurf     = "windsurf"
    case terminal     = "terminal"
    case finder       = "finder"

    var displayName: String {
        switch self {
        case .vscode:       return "VSCode"
        case .cursor:       return "Cursor"
        case .antigravity:  return "Antigravity"
        case .intellij:     return "IntelliJ IDEA"
        case .intellijCE:   return "IntelliJ IDEA CE"
        case .pycharm:      return "PyCharm"
        case .pycharmCE:    return "PyCharm CE"
        case .webstorm:     return "WebStorm"
        case .androidStudio: return "Android Studio"
        case .zed:          return "Zed"
        case .windsurf:     return "Windsurf"
        case .terminal:     return "Terminal"
        case .finder:       return "Finder"
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
        case .desktopCode, .desktopCowork:
            // Cowork 세션은 VM 내부 경로라 로컬에서 열 수 없음 → Claude Desktop 앱 열기
            let task = Process()
            task.launchPath = "/usr/bin/open"
            task.arguments = ["-a", "Claude"]
            try? task.run()
        case .codexCLI, .codexVSCode:
            // Codex 세션은 항상 Codex.app으로 열기
            let task = Process()
            task.launchPath = "/usr/bin/open"
            task.arguments = ["-a", "Codex"]
            try? task.run()
        }
    }

    private func openInEditor(path: String) {
        if self == .finder {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        let appName: String
        switch self {
        case .vscode:         appName = "Visual Studio Code"
        case .cursor:         appName = "Cursor"
        case .antigravity:    appName = "Antigravity"
        case .intellij:       appName = "IntelliJ IDEA"
        case .intellijCE:     appName = "IntelliJ IDEA CE"
        case .pycharm:        appName = "PyCharm"
        case .pycharmCE:      appName = "PyCharm CE"
        case .webstorm:       appName = "WebStorm"
        case .androidStudio:  appName = "Android Studio"
        case .zed:            appName = "Zed"
        case .windsurf:       appName = "Windsurf"
        case .terminal:       appName = "Terminal"
        case .finder:         return  // handled above
        }
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-a", appName, path]
        try? task.run()
    }
}

// MARK: - 상태 모델

enum AgentStatus: Equatable {
    case idle
    case thinking
    case working
    case waitingApproval  // 사용자 승인 대기 (human in the loop)
    case error

    var emoji: String {
        switch self {
        case .idle:             return "😴"
        case .thinking:         return "🤔"
        case .working:          return "🤖"
        case .waitingApproval:  return "⏳"
        case .error:            return "😵"
        }
    }

    var statusIndicator: String {
        switch self {
        case .idle:             return ""
        case .thinking:         return "…"
        case .working:          return "▶"
        case .waitingApproval:  return "❗"
        case .error:            return "⚠"
        }
    }
}

struct Agent: Identifiable {
    let id: String
    var name: String
    var status: AgentStatus
    var currentTask: String
    var elapsedSeconds: Int
    var tokensByModel: [String: ClaudeSession.TokenUsage]
    var currentModel: String
    var sessionID: String
    var projectDir: String
    var workingPath: String
    var lastActivity: Date
    var source: SessionSource
    var lastResponse: String
    var permissionMode: String
    var isSubagent: Bool
    var subagentCount: Int = 0  // 이 부모에 속한 활성 서브에이전트 수
    var subagents: [Agent] = [] // 펼쳐 보기용 자식 에이전트 목록
    var pid: Int?
    var codexApprovalPolicy: String? = nil  // [NEW] Codex approval policy
    var groupKey: String = ""               // [NEW] 프로젝트 그룹화 키

    // 기존 호환성 유지: computed properties
    var inputTokens: Int { tokensByModel.values.reduce(0) { $0 + $1.input } }
    var outputTokens: Int { tokensByModel.values.reduce(0) { $0 + $1.output } }
    var totalTokens: Int { inputTokens + outputTokens }

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

    var elapsedDisplay: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// "claude-sonnet-4-6" → "Sonnet 4.6"
    var modelDisplayName: String {
        guard !currentModel.isEmpty else { return "" }
        if currentModel.contains("opus")   { return "Opus" }
        if currentModel.contains("sonnet") { return "Sonnet" }
        if currentModel.contains("haiku")  { return "Haiku" }
        return currentModel
    }

    /// source 배지 텍스트 (CLI는 nil → 배지 없음)
    var sourceBadgeName: String? {
        switch source {
        case .cli:           return nil
        case .xcode:         return "Xcode"
        case .desktopCode:   return "Code"
        case .desktopCowork: return "Cowork"
        case .codexCLI:      return "Codex"          // [NEW]
        case .codexVSCode:   return "Codex VSCode"   // [NEW]
        }
    }

    /// "default" → "Ask", "acceptEdits" → "Auto", "plan" → "Plan"
    /// Codex: codexApprovalPolicy 기반 source-aware 라벨
    var modeDisplayName: String {
        switch source {
        case .codexCLI, .codexVSCode:
            return Self.codexApprovalLabel(codexApprovalPolicy)
        default:
            return Self.claudePermissionLabel(permissionMode)
        }
    }

    private static func claudePermissionLabel(_ mode: String) -> String {
        switch mode {
        case "acceptEdits":       return "Auto"
        case "plan":              return "Plan"
        case "auto":              return "Auto+"
        case "bypassPermissions": return "Bypass"
        default:                  return "Ask"
        }
    }

    private static func codexApprovalLabel(_ policy: String?) -> String {
        switch policy {
        case "untrusted":   return "신뢰되지 않음"
        case "on-request":  return "요청 시 승인"
        case "on-failure":  return "실패 시 승인"
        case "never":       return "항상 허용"
        default:            return "Codex 기본"
        }
    }
}

// MARK: - AgentStore

@preconcurrency @MainActor
class AgentStore: ObservableObject {
    @Published var agents: [Agent] = []
    @Published var popoverOpenCount = 0

    // 픽셀 에이전트 윈도우
    @Published var isPixelWindowVisible: Bool {
        didSet { UserDefaults.standard.set(isPixelWindowVisible, forKey: "isPixelWindowVisible") }
    }
    @Published var pixelWindowOpacity: Double {
        didSet { UserDefaults.standard.set(pixelWindowOpacity, forKey: "pixelWindowOpacity") }
    }

    /// 픽셀 창의 저장된 위치/크기를 기본값으로 초기화 요청 (WindowController가 구독).
    let pixelWindowResetRequest = PassthroughSubject<Void, Never>()

    // 세션 설정
    @Published var showIdleSessions: Bool {
        didSet { UserDefaults.standard.set(showIdleSessions, forKey: "showIdleSessions") }
    }
    @Published var pollInterval: Double {
        didSet {
            UserDefaults.standard.set(pollInterval, forKey: "pollInterval")
            coordinator.updatePollInterval(pollInterval)
        }
    }

    /// Codex CLI 세션 모니터링 토글 (Settings에서 노출)
    @Published var monitorCodexSessions: Bool {
        didSet {
            UserDefaults.standard.set(monitorCodexSessions, forKey: "monitorCodexSessions")
            coordinator.setCodexEnabled(monitorCodexSessions)
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

    // 리스트 스타일
    @Published var listStyle: ListStyle {
        didSet { UserDefaults.standard.set(listStyle.rawValue, forKey: "listStyle") }
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

    // 픽셀 에이전트 글로벌 핫키
    @Published var pixelHotkeyEnabled: Bool {
        didSet { UserDefaults.standard.set(pixelHotkeyEnabled, forKey: "pixelHotkeyEnabled") }
    }
    @Published var pixelHotkeyKeyCode: Int {
        didSet { UserDefaults.standard.set(pixelHotkeyKeyCode, forKey: "pixelHotkeyKeyCode") }
    }
    @Published var pixelHotkeyModifiers: Int {
        didSet { UserDefaults.standard.set(pixelHotkeyModifiers, forKey: "pixelHotkeyModifiers") }
    }

    // 알림
    @Published var notifyOnComplete: Bool {
        didSet { UserDefaults.standard.set(notifyOnComplete, forKey: "notifyOnComplete") }
    }
    @Published var notifyOnError: Bool {
        didSet { UserDefaults.standard.set(notifyOnError, forKey: "notifyOnError") }
    }
    @Published var notifyOnApprovalRequired: Bool {
        didSet { UserDefaults.standard.set(notifyOnApprovalRequired, forKey: "notifyOnApprovalRequired") }
    }

    // 팝오버 탭 (persistence 없음)
    @Published var selectedTab: PopoverTab = .agents

    // Keep Awake
    let keepAwakeManager: KeepAwakeManager
    @Published var autoKeepAwakeOnSession: Bool {
        didSet { UserDefaults.standard.set(autoKeepAwakeOnSession, forKey: "autoKeepAwakeOnSession") }
    }

    // Clipboard
    var clipboardMonitor: ClipboardMonitor

    // Quick Note
    let quickNoteStore: QuickNoteStore

    // 알림 사운드
    @Published var completionSound: String {
        didSet { UserDefaults.standard.set(completionSound, forKey: "completionSound") }
    }

    // 집중 모드(DND) 중 알림 억제
    @Published var respectFocusMode: Bool {
        didSet { UserDefaults.standard.set(respectFocusMode, forKey: "respectFocusMode") }
    }
    private var isDNDActive: Bool = false

    // Quiet Hours 설정
    @Published var quietHoursEnabled: Bool {
        didSet { UserDefaults.standard.set(quietHoursEnabled, forKey: "quietHoursEnabled") }
    }
    @Published var quietHoursStart: Int {
        didSet { UserDefaults.standard.set(quietHoursStart, forKey: "quietHoursStart") }
    }
    @Published var quietHoursEnd: Int {
        didSet { UserDefaults.standard.set(quietHoursEnd, forKey: "quietHoursEnd") }
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

    // 커스텀 이모지: 세션별 / 프로젝트별 2단계
    @Published var pixelCharacterOverrides: [String: Int] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(pixelCharacterOverrides) {
                UserDefaults.standard.set(data, forKey: "pixelCharacterOverrides")
            }
        }
    }

    @Published var sessionEmojis: [String: String] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(sessionEmojis) {
                UserDefaults.standard.set(data, forKey: "sessionEmojis")
            }
        }
    }
    @Published var projectEmojis: [String: String] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(projectEmojis) {
                UserDefaults.standard.set(data, forKey: "projectEmojis")
            }
        }
    }

    /// 세션 이모지 → 프로젝트 이모지 → 상태 이모지 (팝오버 표시용)
    func displayEmoji(for agent: Agent) -> String {
        sessionEmojis[agent.id]
            ?? projectEmojis[agent.projectDir]
            ?? agent.status.emoji
    }

    /// 메뉴바 표시용: 커스텀 이모지가 있으면 상태 기호를 suffix로 붙여 상태도 표시
    func menuBarEmoji(for agent: Agent) -> String {
        let custom = sessionEmojis[agent.id] ?? projectEmojis[agent.projectDir]
        if let custom {
            return custom + agent.status.statusIndicator
        }
        return agent.status.emoji
    }

    func setEmoji(_ emoji: String, for agent: Agent, projectWide: Bool) {
        if projectWide {
            projectEmojis[agent.projectDir] = emoji
            // 해당 프로젝트의 세션별 오버라이드 초기화
            for a in agents where a.projectDir == agent.projectDir {
                sessionEmojis.removeValue(forKey: a.id)
            }
        } else {
            sessionEmojis[agent.id] = emoji
        }
    }

    func resetEmoji(for agent: Agent) {
        sessionEmojis.removeValue(forKey: agent.id)
        // 세션 오버라이드만 제거 → 프로젝트 이모지로 폴백
    }

    func resetProjectEmoji(for agent: Agent) {
        projectEmojis.removeValue(forKey: agent.projectDir)
        for a in agents where a.projectDir == agent.projectDir {
            sessionEmojis.removeValue(forKey: a.id)
        }
    }

    private let coordinator = SessionCoordinator()
    let usageMonitor = UsageMonitor()
    let systemMetricsMonitor = SystemMetricsMonitor()
    let statsStore = StatsStore()
    private var elapsedTimer: Timer?
    private var previousStatuses: [String: AgentStatus] = [:]
    private var workingSince: [String: Date] = [:]  // working 시작 시각 추적
    private var recordedSessionIDs: Set<String> = [] // 이미 통계에 기록된 세션
    private var lastNotificationTime: [String: Date] = [:]  // 알림 중복 방지용
    private let notificationCooldown: TimeInterval = 60     // 같은 이벤트 재알림 최소 간격
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Initialize utility managers first (before @Published properties that may trigger didSet)
        let savedModeRaw = UserDefaults.standard.string(forKey: "keepAwakeMode") ?? "off"
        let savedMode = KeepAwakeMode(rawValue: savedModeRaw) ?? .off
        self.keepAwakeManager = KeepAwakeManager(initialMode: savedMode)
        self.clipboardMonitor = ClipboardMonitor()
        self.quickNoteStore = QuickNoteStore()
        self.autoKeepAwakeOnSession =
            UserDefaults.standard.object(forKey: "autoKeepAwakeOnSession") as? Bool ?? false

        self.isPixelWindowVisible = UserDefaults.standard.object(forKey: "isPixelWindowVisible") as? Bool ?? true
        self.pixelWindowOpacity   = UserDefaults.standard.object(forKey: "pixelWindowOpacity") as? Double ?? 0.8
        self.showIdleSessions   = UserDefaults.standard.object(forKey: "showIdleSessions") as? Bool ?? true
        self.pollInterval       = UserDefaults.standard.object(forKey: "pollInterval") as? Double ?? 10.0
        self.monitorCodexSessions = UserDefaults.standard.object(forKey: "monitorCodexSessions") as? Bool ?? true
        self.language           = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "en") ?? .english
        self.menubarStyle       = MenubarStyle(rawValue: UserDefaults.standard.string(forKey: "menubarStyle") ?? "emoji") ?? .emoji
        self.listStyle          = ListStyle(rawValue: UserDefaults.standard.string(forKey: "listStyle") ?? "grouped") ?? .grouped
        self.openWith           = OpenWith(rawValue: UserDefaults.standard.string(forKey: "openWith") ?? "vscode") ?? .vscode
        self.isPinned                  = UserDefaults.standard.object(forKey: "isPinned") as? Bool ?? false
        self.hotkeyEnabled             = UserDefaults.standard.object(forKey: "hotkeyEnabled") as? Bool ?? true
        self.hotkeyKeyCode             = UserDefaults.standard.object(forKey: "hotkeyKeyCode") as? Int ?? Int(kVK_ANSI_S)
        self.hotkeyModifiers           = UserDefaults.standard.object(forKey: "hotkeyModifiers") as? Int ?? Int(optionKey | shiftKey)
        self.pixelHotkeyEnabled        = UserDefaults.standard.object(forKey: "pixelHotkeyEnabled") as? Bool ?? false
        self.pixelHotkeyKeyCode        = UserDefaults.standard.object(forKey: "pixelHotkeyKeyCode") as? Int ?? Int(kVK_ANSI_P)
        self.pixelHotkeyModifiers      = UserDefaults.standard.object(forKey: "pixelHotkeyModifiers") as? Int ?? Int(optionKey | shiftKey)
        self.completionSound           = UserDefaults.standard.string(forKey: "completionSound") ?? "default"
        self.respectFocusMode          = UserDefaults.standard.object(forKey: "respectFocusMode") as? Bool ?? false
        self.quietHoursEnabled         = UserDefaults.standard.object(forKey: "quietHoursEnabled") as? Bool ?? false
        self.quietHoursStart           = UserDefaults.standard.object(forKey: "quietHoursStart") as? Int ?? 23
        self.quietHoursEnd             = UserDefaults.standard.object(forKey: "quietHoursEnd") as? Int ?? 9
        self.notifyOnComplete          = UserDefaults.standard.object(forKey: "notifyOnComplete") as? Bool ?? true
        self.notifyOnError             = UserDefaults.standard.object(forKey: "notifyOnError") as? Bool ?? true
        self.notifyOnApprovalRequired  = UserDefaults.standard.object(forKey: "notifyOnApprovalRequired") as? Bool ?? true
        self.notifyOnQuotaThreshold    = UserDefaults.standard.object(forKey: "notifyOnQuotaThreshold") as? Bool ?? true
        self.notifyOnQuotaReset        = UserDefaults.standard.object(forKey: "notifyOnQuotaReset") as? Bool ?? true
        self.sessionAlertThreshold     = UserDefaults.standard.object(forKey: "sessionAlertThreshold") as? Double ?? 80

        if let data = UserDefaults.standard.data(forKey: "pixelCharacterOverrides"),
           let overrides = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.pixelCharacterOverrides = overrides
        }
        if let data = UserDefaults.standard.data(forKey: "projectEmojis"),
           let emojis = try? JSONDecoder().decode([String: String].self, from: data) {
            self.projectEmojis = emojis
        }
        if let data = UserDefaults.standard.data(forKey: "sessionEmojis"),
           let emojis = try? JSONDecoder().decode([String: String].self, from: data) {
            self.sessionEmojis = emojis
        }

        requestNotificationPermission()
        setupDNDObserver()

        // init 시점의 토글 OFF 상태를 coordinator에 반영 (didSet은 초기화 시점에 발동 안 함)
        if !monitorCodexSessions {
            coordinator.setCodexEnabled(false)
        }
        coordinator.onSessionsChanged = { [weak self] sessions in
            // 현재 렌더 사이클이 끝난 뒤 실행되도록 한 번 더 async로 미룸
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.updateAgents(from: sessions)
                }
            }
        }
        coordinator.start()
        syncUsageMonitorSettings()
        usageMonitor.sendNotificationHandler = { [weak self] title, body in
            self?.sendNotification(title: title, body: body)
        }
        usageMonitor.start()
        systemMetricsMonitor.start()

        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for i in self.agents.indices where self.agents[i].status == .working || self.agents[i].status == .waitingApproval {
                    self.agents[i].elapsedSeconds += 1
                }
            }
        }

        // Wire active-session count to KeepAwakeManager
        $agents
            .map { agents in
                agents.filter { $0.status == .working || $0.status == .waitingApproval }.count
            }
            .removeDuplicates()
            .sink { [weak self] count in
                self?.keepAwakeManager.updateActiveSessionCount(count)
            }
            .store(in: &cancellables)

        // 중첩 ObservableObject 변경을 상위로 전파 — SwiftUI가 즉시 재렌더링하도록
        keepAwakeManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        clipboardMonitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
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
        if diff < 60    { return t("\(diff)초 전",           "\(diff)s ago") }
        if diff < 3600  { return t("\(diff / 60)분 전",      "\(diff / 60)m ago") }
        if diff < 86400 { return t("\(diff / 3600)시간 전",  "\(diff / 3600)h ago") }
        return t("\(diff / 86400)일 전", "\(diff / 86400)d ago")
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

    var pixelHotkeyDisplayString: String {
        var mods = ""
        if pixelHotkeyModifiers & Int(controlKey) != 0 { mods += "⌃" }
        if pixelHotkeyModifiers & Int(optionKey) != 0  { mods += "⌥" }
        if pixelHotkeyModifiers & Int(shiftKey) != 0   { mods += "⇧" }
        if pixelHotkeyModifiers & Int(cmdKey) != 0     { mods += "⌘" }
        return mods + Self.keyCodeName(pixelHotkeyKeyCode)
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

    // MARK: - DND / Focus 모드 감지

    private func setupDNDObserver() {
        // 앱 시작 시 현재 DND 상태 확인
        isDNDActive = currentDNDState()

        // DND 시작/종료 알림 구독 (macOS 집중 모드 포함)
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.notificationcenterui.dndStart"),
            object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.isDNDActive = true } }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.notificationcenterui.dndEnd"),
            object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.isDNDActive = false } }
    }

    private func currentDNDState() -> Bool {
        UserDefaults(suiteName: "com.apple.notificationcenterui")?.bool(forKey: "dndEnabled") ?? false
    }

    // MARK: - Quiet Hours

    /// Quiet Hours 범위 내인지 확인 (nonisolated static: 테스트 가능, Date() 의존 없음)
    nonisolated static func isInQuietHours(currentHour: Int, startHour: Int, endHour: Int) -> Bool {
        if startHour == endHour { return false }
        if startHour < endHour {
            return currentHour >= startHour && currentHour < endHour
        } else {
            // 자정 넘김
            return currentHour >= startHour || currentHour < endHour
        }
    }

    func sendNotification(title: String, body: String, workingPath: String? = nil, source: SessionSource? = nil, dedupeKey: String? = nil) {
        // 집중 모드(DND) 중엔 알림 억제
        if respectFocusMode && isDNDActive { return }

        // Quiet Hours 체크
        if quietHoursEnabled {
            let currentHour = Calendar.current.component(.hour, from: Date())
            if Self.isInQuietHours(currentHour: currentHour, startHour: quietHoursStart, endHour: quietHoursEnd) {
                return
            }
        }

        // 같은 키로 cooldown 이내에 보낸 알림은 억제
        if let key = dedupeKey {
            if let last = lastNotificationTime[key],
               Date().timeIntervalSince(last) < notificationCooldown { return }
            lastNotificationTime[key] = Date()
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        switch completionSound {
        case "none":    content.sound = nil
        case "default": content.sound = .default
        default:        content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: completionSound))
        }

        if let path = workingPath, let src = source {
            let srcStr: String
            switch src {
            case .cli:           srcStr = "cli"
            case .xcode:         srcStr = "xcode"
            case .desktopCode:   srcStr = "desktopCode"
            case .desktopCowork: srcStr = "desktopCowork"
            case .codexCLI:      srcStr = "codex"
            case .codexVSCode:   srcStr = "codexVSCode"
            }
            content.userInfo = ["workingPath": path, "source": srcStr]
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - 세션 업데이트

    /// 픽셀 창/메뉴 표시 대상 세션을 결정하는 순수 함수.
    static func filterSessionsForDisplay(
        _ sessions: [ClaudeSession],
        showIdleSessions: Bool
    ) -> [ClaudeSession] {
        if showIdleSessions { return sessions }
        return sessions.filter { $0.displayStatus == .running || $0.displayStatus == .responded }
    }

    private func updateAgents(from sessions: [ClaudeSession]) {
        let preFiltered = Self.filterSessionsForDisplay(sessions, showIdleSessions: showIdleSessions)

        // 서브에이전트를 부모별로 그룹화
        // - 부모 세션은 그대로 표시 + subagentCount 누적
        // - 부모가 idle인데 서브가 활성이면 가장 활동적인 서브의 상태/도구로 부모 표시 오버라이드
        // - 부모를 못 찾는 고아 서브는 숨김
        var subagentsByParent: [String: [ClaudeSession]] = [:]
        var topLevelSessions: [ClaudeSession] = []
        let allSessionIds = Set(sessions.map { $0.id })
        for session in preFiltered {
            if session.isSubagent, let parentId = session.parentSessionId, allSessionIds.contains(parentId) {
                subagentsByParent[parentId, default: []].append(session)
            } else if !session.isSubagent {
                topLevelSessions.append(session)
            }
            // 고아 서브에이전트(부모 jsonl 없음)는 무시
        }

        // 부모 → 활성 서브 우선순위(running > waitingForApproval > responded > 그 외) + 최신
        func pickActiveSubagent(_ subs: [ClaudeSession]) -> ClaudeSession? {
            func rank(_ s: ClaudeSession) -> Int {
                switch s.displayStatus {
                case .running: return 0
                case .waitingForApproval: return 1
                case .responded: return 2
                default: return 3
                }
            }
            return subs.sorted {
                let r1 = rank($0), r2 = rank($1)
                if r1 != r2 { return r1 < r2 }
                return $0.lastModified > $1.lastModified
            }.first
        }

        let filtered = topLevelSessions

        // 같은 프로젝트에 세션이 여러 개면 번호 붙이기
        var projectSessionCounts: [String: Int] = [:]
        for session in filtered {
            projectSessionCounts[session.projectDir, default: 0] += 1
        }
        var projectSessionIndex: [String: Int] = [:]

        // 단일 세션을 Agent로 변환 (부모/서브 공통 사용)
        // displayOverride: 표시 정보를 다른 세션으로 가져오고 싶을 때 사용 (예: 부모 표시를 서브로)
        func makeAgent(
            from session: ClaudeSession,
            displayOverride: ClaudeSession? = nil,
            nameOverride: String? = nil,
            isSubagent: Bool = false
        ) -> Agent {
            let display = displayOverride ?? session
            let status: AgentStatus
            let task: String
            switch display.displayStatus {
            case .running:
                status = .working
                task = translateToolName(display.lastToolName)
            case .waitingForApproval:
                status = .waitingApproval
                task = t("승인 대기 중", "Waiting for approval")
            case .responded:
                status = .thinking
                task = t("응답 완료 · 입력 대기", "Responded · waiting for input")
            case .completed:
                status = .idle
                task = t("세션 종료", "Session ended")
            case .error:
                status = .error
                task = t("에러 발생", "Error occurred")
            case .idle:
                status = .idle
                task = t("대기 중", "Idle")
            }
            let existing = agents.first(where: { $0.id == session.id })
                ?? agents.flatMap { [$0] + $0.subagents }.first(where: { $0.id == session.id })
            let elapsed = display.sessionStatus == .running ? (existing?.elapsedSeconds ?? 0) : 0
            var agent = Agent(
                id: session.id,
                name: nameOverride ?? session.displayName,
                status: status,
                currentTask: task,
                elapsedSeconds: elapsed,
                tokensByModel: session.tokensByModel,
                currentModel: display.currentModel,
                sessionID: session.id,
                projectDir: session.projectDir,
                workingPath: session.workingPath,
                lastActivity: max(session.lastActivity, display.lastActivity),
                source: session.source,
                lastResponse: display.lastAssistantText,
                permissionMode: session.permissionMode,
                isSubagent: isSubagent,
                subagentCount: 0,
                subagents: [],
                pid: nil
            )
            agent.codexApprovalPolicy = session.codexApprovalPolicy
            agent.groupKey = ProjectGroupKey.key(for: session)
            return agent
        }

        let newAgents = filtered.map { parentSession -> Agent in
            // 활성 서브가 있고 부모가 일하고 있지 않으면, 부모 표시를 서브 정보로 오버라이드
            let subs = subagentsByParent[parentSession.id] ?? []
            let activeSub = pickActiveSubagent(subs)
            let parentIsActive = parentSession.displayStatus == .running
                || parentSession.displayStatus == .waitingForApproval
            let displayOverride: ClaudeSession? = (!parentIsActive && activeSub != nil) ? activeSub : nil

            // 같은 프로젝트에 세션이 2개 이상이면 "#1", "#2" 붙이기
            var name = parentSession.displayName
            if (projectSessionCounts[parentSession.projectDir] ?? 1) > 1 {
                let idx = (projectSessionIndex[parentSession.projectDir] ?? 0) + 1
                projectSessionIndex[parentSession.projectDir] = idx
                name += " #\(idx)"
            }

            // 서브에이전트들도 Agent로 변환 (활성 우선 → 최신순)
            let sortedSubs = subs.sorted {
                let r1: Int = ($0.displayStatus == .running) ? 0 : ($0.displayStatus == .waitingForApproval ? 1 : 2)
                let r2: Int = ($1.displayStatus == .running) ? 0 : ($1.displayStatus == .waitingForApproval ? 1 : 2)
                if r1 != r2 { return r1 < r2 }
                return $0.lastModified > $1.lastModified
            }
            let subAgents = sortedSubs.enumerated().map { idx, sub -> Agent in
                // 서브에이전트 jsonl 파일명: "agent-{agentId}" → prefix 제거 후 부모 매핑 조회
                let bareAgentId = sub.id.hasPrefix("agent-") ? String(sub.id.dropFirst("agent-".count)) : sub.id
                let meta = parentSession.subagentMeta[bareAgentId]
                let subName: String
                if let meta = meta {
                    if !meta.description.isEmpty {
                        subName = "↳ \(meta.type) — \(meta.description)"
                    } else {
                        subName = "↳ \(meta.type)"
                    }
                } else {
                    subName = "↳ subagent #\(idx + 1)"
                }
                return makeAgent(from: sub, nameOverride: subName, isSubagent: true)
            }

            var parentAgent = makeAgent(from: parentSession, displayOverride: displayOverride, nameOverride: name)
            parentAgent.subagentCount = subs.count
            parentAgent.subagents = subAgents

            // 부모 토큰에 서브에이전트 토큰 합산 (모델별로 누적)
            // → 파이프라인 전체 비용을 부모 행에서 한눈에 볼 수 있음
            var combined = parentAgent.tokensByModel
            for sub in subAgents {
                for (model, tokens) in sub.tokensByModel {
                    let existing = combined[model] ?? ClaudeSession.TokenUsage()
                    combined[model] = ClaudeSession.TokenUsage(
                        input: existing.input + tokens.input,
                        cachedInput: existing.cachedInput + tokens.cachedInput,
                        output: existing.output + tokens.output,
                        reasoningOutput: existing.reasoningOutput + tokens.reasoningOutput
                    )
                }
            }
            parentAgent.tokensByModel = combined
            return parentAgent
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
               !agent.isSubagent,
               prev == .working,
               agent.status == .thinking,
               let since = workingSince[agent.id],
               Date().timeIntervalSince(since) >= 10 {
                sendNotification(
                    title: t("응답 완료", "Response ready"),
                    body: "\(agent.name) — \(t("Claude가 응답했습니다", "Claude responded"))",
                    workingPath: agent.workingPath,
                    source: agent.source,
                    dedupeKey: "\(agent.id).complete"
                )
                workingSince.removeValue(forKey: agent.id)
            }

            if notifyOnApprovalRequired, !agent.isSubagent, agent.status == .waitingApproval, prev != .waitingApproval {
                sendNotification(
                    title: t("승인 필요", "Approval required"),
                    body: "\(agent.name) — \(t("작업 진행을 위해 승인이 필요합니다", "requires your approval to proceed"))",
                    workingPath: agent.workingPath,
                    source: agent.source,
                    dedupeKey: "\(agent.id).approval"
                )
            }

            if notifyOnError, !agent.isSubagent, agent.status == .error, prev != .error {
                sendNotification(
                    title: t("에러 발생", "Error occurred"),
                    body: "\(agent.name) — \(t("에러가 발생했습니다", "encountered an error"))",
                    workingPath: agent.workingPath,
                    source: agent.source,
                    dedupeKey: "\(agent.id).error"
                )
            }

            // 통계 기록: 토큰이 있는 세션이 idle/completed로 전환될 때 1회 기록
            if (agent.status == .idle || agent.status == .thinking || agent.status == .error),
               prev == .working,
               agent.totalTokens > 0,
               !recordedSessionIDs.contains(agent.id) {
                recordedSessionIDs.insert(agent.id)
                statsStore.record(agent: agent)
            }

            previousStatuses[agent.id] = agent.status
        }

        // 새 세션에 미사용 캐릭터 랜덤 배정
        let previousIDs = Set(agents.flatMap { [$0.id] + $0.subagents.map { $0.id } })
        let allNewAgents = newAgents.flatMap { [$0] + $0.subagents }
        for agent in allNewAgents where !previousIDs.contains(agent.id) && pixelCharacterOverrides[agent.id] == nil {
            let inUse = Set(allNewAgents.map { a in pixelCharacterOverrides[a.id] ?? SpriteSheetPixelProvider.charIndex(for: a.id) })
            pixelCharacterOverrides[agent.id] = assignCharacter(forNewAgentID: agent.id, inUseIndices: inUse)
        }

        agents = newAgents
    }

    /// Returns a character index not in inUseIndices, or a random index if all 6 are used.
    internal func assignCharacter(forNewAgentID id: String, inUseIndices: Set<Int>) -> Int {
        let total = SpriteSheetPixelProvider.charCount
        let available = (0..<total).filter { !inUseIndices.contains($0) }
        if available.isEmpty {
            return Int.random(in: 0..<total)
        }
        return available.randomElement()!
    }
}
