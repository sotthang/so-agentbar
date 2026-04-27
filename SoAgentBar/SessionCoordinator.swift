import Foundation

// MARK: - SessionCoordinator
// 두 모니터(Claude + Codex)를 합성하고 onSessionsChanged를 단일 채널로 발행.

final class SessionCoordinator {

    // MARK: Public API
    var onSessionsChanged: (([ClaudeSession]) -> Void)?

    // MARK: Internals
    private let claudeMonitor: SessionMonitorProtocol
    private let codexMonitor: SessionMonitorProtocol
    private var lastClaudeSessions: [ClaudeSession] = []
    private var lastCodexSessions: [ClaudeSession] = []
    private var codexEnabled: Bool

    // MARK: Init

    init(
        claudeMonitor: SessionMonitorProtocol? = nil,
        codexMonitor: SessionMonitorProtocol? = nil,
        initialCodexEnabled: Bool = true
    ) {
        self.claudeMonitor = claudeMonitor ?? ClaudeSessionMonitor()
        self.codexMonitor = codexMonitor ?? CodexSessionMonitor()
        self.codexEnabled = initialCodexEnabled
    }

    // MARK: Public Methods

    func start() {
        claudeMonitor.onSessionsChanged = { [weak self] sessions in
            guard let self else { return }
            self.lastClaudeSessions = sessions
            self.publishMerged()
        }
        codexMonitor.onSessionsChanged = { [weak self] sessions in
            guard let self else { return }
            self.lastCodexSessions = sessions
            self.publishMerged()
        }
        claudeMonitor.start()
        if codexEnabled {
            codexMonitor.start()
        }
    }

    func stop() {
        claudeMonitor.stop()
        codexMonitor.stop()
    }

    func updatePollInterval(_ interval: Double) {
        claudeMonitor.updatePollInterval(interval)
        codexMonitor.updatePollInterval(interval)
    }

    /// Codex 모니터링 토글
    func setCodexEnabled(_ enabled: Bool) {
        codexEnabled = enabled
        if enabled {
            codexMonitor.start()
        } else {
            codexMonitor.stop()
            lastCodexSessions = []
            publishMerged()
        }
    }

    // MARK: Private

    private func publishMerged() {
        var merged = lastClaudeSessions
        if codexEnabled {
            merged += lastCodexSessions
        }
        onSessionsChanged?(merged)
    }
}
