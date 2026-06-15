import Foundation
import Combine

// MARK: - UsageCoordinator (프로바이더 합성/발행)
//
// 활성화된 프로바이더들(Claude, Codex, Gemini)을 합성하고 단일 발행 채널로 통합.
// (R0.3, RX.4, NFR4)
//
// 역할:
// - Claude 프로바이더는 기본 활성, claudeEnabled로 on/off 토글 가능
// - Codex/Gemini는 사용자 설정(enabled)으로 on/off 토글
// - providers: 팝오버(UsageView)가 구독, 순서 고정 Claude → Codex → Gemini
// - menubarUsage: 메뉴바 아이콘이 구독, 선택된 프로바이더 1개만 표시
// - 장애 격리(NFR4): 한 프로바이더 오류가 다른 프로바이더 표시를 막지 않음

@MainActor
final class UsageCoordinator: ObservableObject {

        // 팝오버(UsageView)가 구독: 표시 순서 고정 Claude → Codex → Gemini → Cursor
    @Published private(set) var providers: [ProviderUsage] = []

    // 메뉴바 아이콘이 구독: 선택된 프로바이더의 스냅샷 (없으면 nil, RX.4)
    @Published private(set) var menubarUsage: ProviderUsage?

    private let claude: UsageProviderProtocol
    private let codex: UsageProviderProtocol?
    private let gemini: UsageProviderProtocol?
    private let cursor: UsageProviderProtocol?    // [SPEC-002]
    private var enabled: [ProviderID: Bool]
    private var selectedProvider: ProviderID
    private var latest: [ProviderID: ProviderUsage] = [:]  // 프로바이더별 마지막 스냅샷 (장애 격리)

    init(
        claude: UsageProviderProtocol? = nil,
        codex: UsageProviderProtocol? = nil,
        gemini: UsageProviderProtocol? = nil,
        cursor: UsageProviderProtocol? = nil,         // [SPEC-002]
        claudeEnabled: Bool = true,
        codexEnabled: Bool = false,
        geminiEnabled: Bool = false,
        cursorEnabled: Bool = false,                  // [SPEC-002]
        selectedProvider: ProviderID = .claude
    ) {
        self.claude = claude ?? _PlaceholderProvider(id: .claude)
        self.codex = codex
        self.gemini = gemini
        self.cursor = cursor
        self.enabled = [.claude: claudeEnabled, .codex: codexEnabled, .gemini: geminiEnabled, .cursor: cursorEnabled]
        self.selectedProvider = selectedProvider

        // onUsageChanged 콜백 등록 (장애 격리: 각 프로바이더 독립)
        self.setupCallbacks()
    }

    private func setupCallbacks() {
        claude.onUsageChanged = { [weak self] usage in
            self?.receiveUsage(usage)
        }
        codex?.onUsageChanged = { [weak self] usage in
            self?.receiveUsage(usage)
        }
        gemini?.onUsageChanged = { [weak self] usage in
            self?.receiveUsage(usage)
        }
        cursor?.onUsageChanged = { [weak self] usage in    // [SPEC-002]
            self?.receiveUsage(usage)
        }
    }

    private func receiveUsage(_ usage: ProviderUsage) {
        latest[usage.id] = usage
        rebuildAll()
    }

    // MARK: - 공개 메서드

    func start() {
        // Claude: 활성화된 경우만 start
        if enabled[.claude] == true {
            claude.start()
        }

        // Codex: 활성화된 경우만 start
        if enabled[.codex] == true, let c = codex {
            c.start()
        }

        // Gemini: 활성화된 경우만 start
        if enabled[.gemini] == true, let g = gemini {
            g.start()
        }

        // Cursor: 활성화된 경우만 start (SPEC-002)
        if enabled[.cursor] == true, let cu = cursor {
            cu.start()
        }

        // 초기 스냅샷으로 providers 구성
        rebuildAll()
    }

    func stop() {
        claude.stop()
        codex?.stop()
        gemini?.stop()
        cursor?.stop()    // [SPEC-002]
    }

    func updatePollInterval(_ interval: Double) {
        claude.updatePollInterval(interval)
        if enabled[.codex] == true { codex?.updatePollInterval(interval) }
        if enabled[.gemini] == true { gemini?.updatePollInterval(interval) }
        if enabled[.cursor] == true { cursor?.updatePollInterval(interval) }    // [SPEC-002]
    }

    /// on/off 토글 (RX.1) — false면 stop + latest 제거 + 재발행
    func setEnabled(_ provider: ProviderID, _ isEnabled: Bool) {
        enabled[provider] = isEnabled

        let target: UsageProviderProtocol?
        switch provider {
        case .claude:  target = claude
        case .codex:   target = codex
        case .gemini:  target = gemini
        case .cursor:  target = cursor
        }

        if isEnabled {
            target?.start()
        } else {
            target?.stop()
            latest.removeValue(forKey: provider)
        }

        rebuildAll()
    }

    /// 메뉴바 표시 프로바이더 선택 (RX.4) — menubarUsage 즉시 재계산
    func setSelectedProvider(_ provider: ProviderID) {
        selectedProvider = provider
        rebuildMenubar()
    }

    /// 특정 프로바이더 수동 새로고침 (onRetry)
    func refresh(_ provider: ProviderID) {
        Task {
            switch provider {
            case .claude:  await claude.fetch()
            case .codex:   await codex?.fetch()
            case .gemini:  await gemini?.fetch()
            case .cursor:  await cursor?.fetch()    // [SPEC-002]
            }
        }
    }

    // MARK: - 내부 재계산

    /// providers + menubarUsage 동시 재계산 (항상 쌍으로 호출되므로 통합).
    private func rebuildAll() {
        rebuildProviders()
        rebuildMenubar()
    }

    /// providers 재계산: enabled된 것만, 고정 순서 Claude → Codex → Gemini → Cursor
    private func rebuildProviders() {
        var result: [ProviderUsage] = []

        // Claude: 활성화된 경우만 포함 (latest에 없으면 currentUsage 사용)
        if enabled[.claude] == true {
            result.append(latest[.claude] ?? claude.currentUsage)
        }

        // Codex: 활성화된 경우만
        if enabled[.codex] == true, let c = codex {
            result.append(latest[.codex] ?? c.currentUsage)
        }

        // Gemini: 활성화된 경우만
        if enabled[.gemini] == true, let g = gemini {
            result.append(latest[.gemini] ?? g.currentUsage)
        }

        // Cursor: 활성화된 경우만 (표시 순서 마지막, SPEC-002 R5.3)
        if enabled[.cursor] == true, let cu = cursor {
            result.append(latest[.cursor] ?? cu.currentUsage)
        }

        providers = result
    }

    /// menubarUsage 재계산: 선택 프로바이더가 off거나 data 아니면 nil
    private func rebuildMenubar() {
        // Claude는 enabled[.claude]=true로 항상 활성 — 동일한 조회로 통일
        guard enabled[selectedProvider] == true else {
            menubarUsage = nil
            return
        }

        // 선택 프로바이더의 최신 스냅샷 가져오기
        let usage: ProviderUsage?
        switch selectedProvider {
        case .claude:  usage = latest[.claude] ?? claude.currentUsage
        case .codex:   usage = latest[.codex] ?? codex?.currentUsage
        case .gemini:  usage = latest[.gemini] ?? gemini?.currentUsage
        case .cursor:  usage = latest[.cursor] ?? cursor?.currentUsage    // [SPEC-002]
        }

        // state가 .data일 때만 menubarUsage 설정 (noSuffix 규칙)
        if let u = usage, case .data = u.state {
            menubarUsage = u
        } else {
            menubarUsage = nil
        }
    }
}

// MARK: - 내부 플레이스홀더 (init nil 방어용)

@MainActor
private final class _PlaceholderProvider: UsageProviderProtocol {
    nonisolated let id: ProviderID
    var onUsageChanged: ((ProviderUsage) -> Void)?
    var currentUsage: ProviderUsage

    init(id: ProviderID) {
        self.id = id
        self.currentUsage = ProviderUsage.loading(id, isEstimate: id != .claude)
    }

    func start() {}
    func stop() {}
    func fetch() async {}
    func updatePollInterval(_ interval: Double) {}
}
