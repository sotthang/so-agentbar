import XCTest
@testable import SoAgentBar

// MARK: - Mock Provider (테스트 타겟 전용)

/// UsageProviderProtocol을 구현하는 mock — 코디네이터 단위 테스트용.
@MainActor
final class MockUsageProvider: UsageProviderProtocol {
    nonisolated let id: ProviderID
    var onUsageChanged: ((ProviderUsage) -> Void)?
    private(set) var currentUsage: ProviderUsage
    private(set) var startCalled = false
    private(set) var stopCalled = false
    private(set) var fetchCalled = false

    init(id: ProviderID, initialUsage: ProviderUsage? = nil) {
        self.id = id
        self.currentUsage = initialUsage ?? ProviderUsage.loading(id, isEstimate: id != .claude)
    }

    func start() { startCalled = true }
    func stop()  { stopCalled = true }
    func fetch() async { fetchCalled = true }
    func updatePollInterval(_ interval: Double) {}

    /// 테스트에서 수동으로 스냅샷 발행
    func emit(_ usage: ProviderUsage) {
        currentUsage = usage
        onUsageChanged?(usage)
    }

    /// 에러 상태 발행
    func emitError(_ message: String) {
        let u = ProviderUsage(id: id, state: .error(message), isEstimate: id != .claude,
                              quota: nil, estimate: nil)
        emit(u)
    }
}

// MARK: - UsageCoordinatorTests

/// Phase 0 — UsageCoordinator 합성 로직 단위 테스트.
/// AC-0.3: 비활성 프로바이더는 fetch하지 않음
/// AC-0.4: 한 프로바이더 에러가 다른 프로바이더 발행을 막지 않음 (NFR4)
@MainActor
final class UsageCoordinatorTests: XCTestCase {

    // MARK: - 헬퍼

    private func makeDataUsage(
        id: ProviderID,
        isEstimate: Bool = false
    ) -> ProviderUsage {
        if isEstimate {
            return ProviderUsage(
                id: id, state: .data, isEstimate: true,
                quota: nil,
                estimate: EstimateInfo(totalTokens: 1000, costDollars: 1.0, windowHours: 24)
            )
        } else {
            return ProviderUsage(
                id: id, state: .data, isEstimate: false,
                quota: QuotaInfo(sessionUtilization: 50, sessionResetsAt: nil,
                                  weeklyUtilization: 60, weeklyResetsAt: nil,
                                  planName: nil, extra: nil),
                estimate: nil
            )
        }
    }

    // MARK: - AC-0.3: 비활성 프로바이더 fetch 제외

    func test_coordinator_start_onlyStartsActiveProviders() {
        let claude = MockUsageProvider(id: .claude)
        let codex = MockUsageProvider(id: .codex)
        let gemini = MockUsageProvider(id: .gemini)

        let coordinator = UsageCoordinator(
            claude: claude, codex: codex, gemini: gemini,
            codexEnabled: false,
            geminiEnabled: false,
            selectedProvider: .claude
        )
        coordinator.start()

        // RED: UsageCoordinator가 아직 구현되지 않아 컴파일 또는 동작 실패
        XCTAssertTrue(claude.startCalled, "Claude는 항상 start돼야 한다")
        XCTAssertFalse(codex.startCalled, "비활성 Codex는 start되면 안 된다 (AC-0.3)")
        XCTAssertFalse(gemini.startCalled, "비활성 Gemini는 start되면 안 된다 (AC-0.3)")
    }

    func test_coordinator_setEnabled_codex_startsProvider() {
        let claude = MockUsageProvider(id: .claude)
        let codex = MockUsageProvider(id: .codex)

        let coordinator = UsageCoordinator(
            claude: claude, codex: codex, gemini: nil,
            codexEnabled: false,
            geminiEnabled: false,
            selectedProvider: .claude
        )
        coordinator.start()

        XCTAssertFalse(codex.startCalled)
        coordinator.setEnabled(.codex, true)
        // RED
        XCTAssertTrue(codex.startCalled,
                      "setEnabled(.codex, true) 호출 후 Codex가 start돼야 한다")
    }

    func test_coordinator_setEnabled_false_stopsProvider() {
        let claude = MockUsageProvider(id: .claude)
        let codex = MockUsageProvider(id: .codex)

        let coordinator = UsageCoordinator(
            claude: claude, codex: codex, gemini: nil,
            codexEnabled: true,
            geminiEnabled: false,
            selectedProvider: .claude
        )
        coordinator.start()
        XCTAssertTrue(codex.startCalled)

        coordinator.setEnabled(.codex, false)
        // RED
        XCTAssertTrue(codex.stopCalled,
                      "setEnabled(.codex, false) 호출 후 Codex가 stop돼야 한다")
    }

    // MARK: - AC-0.3: providers 발행 — 비활성 프로바이더 제외

    func test_coordinator_providers_onlyContainsActiveProviders() {
        let claude = MockUsageProvider(id: .claude)
        let codex = MockUsageProvider(id: .codex)

        let coordinator = UsageCoordinator(
            claude: claude, codex: codex, gemini: nil,
            codexEnabled: false,
            geminiEnabled: false,
            selectedProvider: .claude
        )
        coordinator.start()

        // Codex 비활성 → providers에 Claude만 있어야 함
        // RED
        let providerIDs = coordinator.providers.map(\.id)
        XCTAssertTrue(providerIDs.contains(.claude), "Claude는 항상 providers에 있어야 한다")
        XCTAssertFalse(providerIDs.contains(.codex),
                       "비활성 Codex는 providers에 없어야 한다 (AC-0.3)")
    }

    func test_coordinator_providers_includesCodexWhenEnabled() {
        let claude = MockUsageProvider(id: .claude)
        let codex = MockUsageProvider(id: .codex)

        let coordinator = UsageCoordinator(
            claude: claude, codex: codex, gemini: nil,
            codexEnabled: true,
            geminiEnabled: false,
            selectedProvider: .claude
        )
        coordinator.start()
        claude.emit(makeDataUsage(id: .claude))
        codex.emit(makeDataUsage(id: .codex, isEstimate: true))

        // RED
        let ids = coordinator.providers.map(\.id)
        XCTAssertTrue(ids.contains(.claude))
        XCTAssertTrue(ids.contains(.codex), "활성 Codex는 providers에 포함돼야 한다")
    }

    func test_coordinator_providers_fixedOrder_claude_codex_gemini() {
        let claude = MockUsageProvider(id: .claude)
        let codex = MockUsageProvider(id: .codex)
        let gemini = MockUsageProvider(id: .gemini)

        let coordinator = UsageCoordinator(
            claude: claude, codex: codex, gemini: gemini,
            codexEnabled: true,
            geminiEnabled: true,
            selectedProvider: .claude
        )
        coordinator.start()
        claude.emit(makeDataUsage(id: .claude))
        codex.emit(makeDataUsage(id: .codex, isEstimate: true))
        gemini.emit(makeDataUsage(id: .gemini, isEstimate: true))

        // RED
        XCTAssertEqual(coordinator.providers.map(\.id), [.claude, .codex, .gemini],
                       "표시 순서는 Claude → Codex → Gemini로 고정이어야 한다 (design.md)")
    }

    // MARK: - AC-0.4: 장애 격리 (NFR4)

    func test_coordinator_oneProviderError_othersStillPublish() {
        let claude = MockUsageProvider(id: .claude)
        let codex = MockUsageProvider(id: .codex)

        let coordinator = UsageCoordinator(
            claude: claude, codex: codex, gemini: nil,
            codexEnabled: true,
            geminiEnabled: false,
            selectedProvider: .claude
        )
        coordinator.start()

        // Claude 정상 발행
        claude.emit(makeDataUsage(id: .claude))

        // Codex 에러 발행
        codex.emitError("network failed")

        // RED
        let claudeProvider = coordinator.providers.first(where: { $0.id == .claude })
        let codexProvider  = coordinator.providers.first(where: { $0.id == .codex })

        XCTAssertNotNil(claudeProvider, "Claude 결과는 여전히 providers에 있어야 한다")
        XCTAssertEqual(claudeProvider?.state, .data,
                       "Codex 에러가 Claude 데이터 상태에 영향을 주면 안 된다 (AC-0.4)")
        XCTAssertNotNil(codexProvider)
        if case .error(_) = codexProvider?.state { } else {
            XCTFail("Codex는 .error 상태여야 한다")
        }
    }

    func test_coordinator_allProvidersError_publishesAllErrors() {
        let claude = MockUsageProvider(id: .claude)
        let codex = MockUsageProvider(id: .codex)

        let coordinator = UsageCoordinator(
            claude: claude, codex: codex, gemini: nil,
            codexEnabled: true,
            geminiEnabled: false,
            selectedProvider: .claude
        )
        coordinator.start()

        claude.emitError("claude error")
        codex.emitError("codex error")

        // RED: 두 에러 상태가 모두 발행돼야 함
        XCTAssertEqual(coordinator.providers.count, 2,
                       "양쪽 에러여도 providers 배열에 두 항목이 있어야 한다")
    }

    // MARK: - menubarUsage (RX.4, AC-X.5)

    func test_coordinator_menubarUsage_defaultClaude_followsClaudeProvider() {
        let claude = MockUsageProvider(id: .claude)

        let coordinator = UsageCoordinator(
            claude: claude, codex: nil, gemini: nil,
            codexEnabled: false,
            geminiEnabled: false,
            selectedProvider: .claude
        )
        coordinator.start()

        let claudeData = makeDataUsage(id: .claude)
        claude.emit(claudeData)

        // RED
        XCTAssertNotNil(coordinator.menubarUsage,
                        "Claude가 활성이고 데이터 있으면 menubarUsage는 nil이 아니어야 한다")
        XCTAssertEqual(coordinator.menubarUsage?.id, .claude)
    }

    func test_coordinator_menubarUsage_switchToCodex_followsCodex() {
        let claude = MockUsageProvider(id: .claude)
        let codex = MockUsageProvider(id: .codex)

        let coordinator = UsageCoordinator(
            claude: claude, codex: codex, gemini: nil,
            codexEnabled: true,
            geminiEnabled: false,
            selectedProvider: .claude
        )
        coordinator.start()

        claude.emit(makeDataUsage(id: .claude))
        codex.emit(makeDataUsage(id: .codex, isEstimate: true))

        coordinator.setSelectedProvider(.codex)

        // RED
        XCTAssertEqual(coordinator.menubarUsage?.id, .codex,
                       "setSelectedProvider(.codex) 후 menubarUsage는 Codex 데이터를 따라야 한다 (AC-X.5)")
    }

    func test_coordinator_menubarUsage_disabledProvider_returnsNil() {
        let claude = MockUsageProvider(id: .claude)
        let codex = MockUsageProvider(id: .codex)

        let coordinator = UsageCoordinator(
            claude: claude, codex: codex, gemini: nil,
            codexEnabled: false,        // Codex 비활성
            geminiEnabled: false,
            selectedProvider: .codex    // 그래도 Codex 선택
        )
        coordinator.start()

        // RED
        XCTAssertNil(coordinator.menubarUsage,
                     "비활성 프로바이더를 선택하면 menubarUsage는 nil이어야 한다 (AC-X.5)")
    }

    func test_coordinator_menubarUsage_errorState_returnsNil() {
        let claude = MockUsageProvider(id: .claude)

        let coordinator = UsageCoordinator(
            claude: claude, codex: nil, gemini: nil,
            codexEnabled: false,
            geminiEnabled: false,
            selectedProvider: .claude
        )
        coordinator.start()
        claude.emitError("quota fetch failed")

        // RED
        XCTAssertNil(coordinator.menubarUsage,
                     "에러 상태 프로바이더가 선택되면 menubarUsage는 nil이어야 한다 (design.md noSuffix 규칙)")
    }

    // MARK: - Claude 토글 테스트 (신규)

    /// 기본값에서 Claude는 활성, providers에 claude 포함 (회귀)
    func test_coordinator_default_claudeEnabled_providersContainClaude() {
        let claude = MockUsageProvider(id: .claude)

        let coordinator = UsageCoordinator(
            claude: claude, codex: nil, gemini: nil,
            claudeEnabled: true,
            codexEnabled: false,
            geminiEnabled: false,
            selectedProvider: .claude
        )
        coordinator.start()

        let ids = coordinator.providers.map(\.id)
        XCTAssertTrue(ids.contains(.claude),
                      "기본값(claudeEnabled=true)에서 providers에 claude가 포함돼야 한다")
        XCTAssertTrue(claude.startCalled,
                      "claudeEnabled=true면 claude.start()가 호출돼야 한다")
    }

    /// setEnabled(.claude, false) → providers에서 claude 제외 + stop 호출 + menubarUsage nil
    func test_coordinator_setEnabled_claude_false_removesFromProviders() {
        let claude = MockUsageProvider(id: .claude)

        let coordinator = UsageCoordinator(
            claude: claude, codex: nil, gemini: nil,
            claudeEnabled: true,
            codexEnabled: false,
            geminiEnabled: false,
            selectedProvider: .claude
        )
        coordinator.start()
        claude.emit(makeDataUsage(id: .claude))

        coordinator.setEnabled(.claude, false)

        let ids = coordinator.providers.map(\.id)
        XCTAssertFalse(ids.contains(.claude),
                       "setEnabled(.claude, false) 후 providers에서 claude가 제외돼야 한다")
        XCTAssertTrue(claude.stopCalled,
                      "setEnabled(.claude, false) 후 claude.stop()이 호출돼야 한다")
        XCTAssertNil(coordinator.menubarUsage,
                     "Claude 비활성 후 menubarUsage(.claude 선택)는 nil이어야 한다")
    }

    /// setEnabled(.claude, true) → 다시 포함/start
    func test_coordinator_setEnabled_claude_true_reEnables() {
        let claude = MockUsageProvider(id: .claude)

        let coordinator = UsageCoordinator(
            claude: claude, codex: nil, gemini: nil,
            claudeEnabled: false,
            codexEnabled: false,
            geminiEnabled: false,
            selectedProvider: .claude
        )
        coordinator.start()

        XCTAssertFalse(coordinator.providers.map(\.id).contains(.claude),
                       "claudeEnabled=false로 시작 시 providers에 claude 없어야 한다")

        coordinator.setEnabled(.claude, true)

        XCTAssertTrue(coordinator.providers.map(\.id).contains(.claude),
                      "setEnabled(.claude, true) 후 providers에 claude가 포함돼야 한다")
        XCTAssertTrue(claude.startCalled,
                      "setEnabled(.claude, true) 후 claude.start()가 호출돼야 한다")
    }

    /// Claude/Codex/Cursor 전부 off → providers 빈 배열, 크래시 없음
    func test_coordinator_allDisabled_providersEmpty_noCrash() {
        let claude = MockUsageProvider(id: .claude)
        let codex = MockUsageProvider(id: .codex)
        let cursor = MockUsageProvider(id: .cursor)

        let coordinator = UsageCoordinator(
            claude: claude, codex: codex, gemini: nil, cursor: cursor,
            claudeEnabled: false,
            codexEnabled: false,
            geminiEnabled: false,
            cursorEnabled: false,
            selectedProvider: .claude
        )
        coordinator.start()

        XCTAssertTrue(coordinator.providers.isEmpty,
                      "전부 off이면 providers는 빈 배열이어야 한다")
        XCTAssertNil(coordinator.menubarUsage,
                     "전부 off이면 menubarUsage는 nil이어야 한다")
    }
}
