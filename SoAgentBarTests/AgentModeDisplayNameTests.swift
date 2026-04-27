import XCTest
@testable import SoAgentBar

// MARK: - AgentModeDisplayNameTests
// AC-R5.6 검증 (source-aware modeDisplayName 라벨)
// RED: SessionSource.codexCLI/codexVSCode 없음, Agent.codexApprovalPolicy 없음,
//      Agent.modeDisplayName이 source-aware 분기 없음, Agent.sourceBadgeName Codex case 없음
//      → 컴파일 에러 예상

final class AgentModeDisplayNameTests: XCTestCase {

    // MARK: - 헬퍼: Agent 빌더

    private func makeAgent(
        source: SessionSource,
        permissionMode: String = "default",
        codexApprovalPolicy: String? = nil
    ) -> Agent {
        // Agent 구조체의 실제 이니셜라이저 사용
        // 신규 필드 codexApprovalPolicy, groupKey는 Developer가 추가 후 여기 반영
        Agent(
            id: UUID().uuidString,
            name: "Test Project",
            status: .working,
            currentTask: "",
            elapsedSeconds: 0,
            tokensByModel: [:],
            currentModel: "",
            sessionID: UUID().uuidString,
            projectDir: "/tmp/test",
            workingPath: "/tmp/test",
            lastActivity: Date(),
            source: source,
            lastResponse: "",
            permissionMode: permissionMode,
            isSubagent: false,
            codexApprovalPolicy: codexApprovalPolicy,   // [NEW] Developer가 추가
            groupKey: "/tmp/test"                        // [NEW] Developer가 추가
        )
    }

    // MARK: - AC-R5.6: Codex on-request → "요청 시 승인"

    func test_codexOnRequest_returnsKoreanRequestApprovalLabel() {
        let agent = makeAgent(source: .codexCLI, codexApprovalPolicy: "on-request")
        XCTAssertEqual(agent.modeDisplayName, "요청 시 승인",
                       "Codex codexApprovalPolicy=on-request → '요청 시 승인' (AC-R5.6)")
    }

    // MARK: - AC-R5.6: Codex never → "항상 허용"

    func test_codexNever_returnsAlwaysAllowLabel() {
        let agent = makeAgent(source: .codexCLI, codexApprovalPolicy: "never")
        XCTAssertEqual(agent.modeDisplayName, "항상 허용",
                       "Codex codexApprovalPolicy=never → '항상 허용' (AC-R5.6)")
    }

    // MARK: - AC-R5.6: Codex on-failure → "실패 시 승인"

    func test_codexOnFailure_returnsAskOnFailureLabel() {
        let agent = makeAgent(source: .codexCLI, codexApprovalPolicy: "on-failure")
        XCTAssertEqual(agent.modeDisplayName, "실패 시 승인",
                       "Codex codexApprovalPolicy=on-failure → '실패 시 승인' (AC-R5.6)")
    }

    // MARK: - AC-R5.6: Codex untrusted → "신뢰되지 않음"

    func test_codexUntrusted_returnsUntrustedLabel() {
        let agent = makeAgent(source: .codexCLI, codexApprovalPolicy: "untrusted")
        XCTAssertEqual(agent.modeDisplayName, "신뢰되지 않음",
                       "Codex codexApprovalPolicy=untrusted → '신뢰되지 않음' (AC-R5.6)")
    }

    // MARK: - AC-R5.6: Codex nil policy → "Codex 기본"

    func test_codexNilPolicy_returnsCodexDefault() {
        let agent = makeAgent(source: .codexCLI, codexApprovalPolicy: nil)
        XCTAssertEqual(agent.modeDisplayName, "Codex 기본",
                       "Codex codexApprovalPolicy=nil → 'Codex 기본' (AC-R5.6)")
    }

    // MARK: - AC-R5.6: Codex VSCode도 동일 라벨 적용

    func test_codexVSCode_onRequest_sameLabel() {
        let agent = makeAgent(source: .codexVSCode, codexApprovalPolicy: "on-request")
        XCTAssertEqual(agent.modeDisplayName, "요청 시 승인",
                       "codexVSCode source도 동일한 Codex 라벨을 사용해야 한다")
    }

    // MARK: - 회귀: Claude acceptEdits → "Auto"

    func test_claudeAcceptEdits_returnsAuto() {
        let agent = makeAgent(source: .cli, permissionMode: "acceptEdits")
        XCTAssertEqual(agent.modeDisplayName, "Auto",
                       "Claude CLI acceptEdits → 'Auto' (회귀 보호)")
    }

    // MARK: - 회귀: Claude plan → "Plan"

    func test_claudePlan_returnsPlan() {
        let agent = makeAgent(source: .cli, permissionMode: "plan")
        XCTAssertEqual(agent.modeDisplayName, "Plan",
                       "Claude CLI plan → 'Plan' (회귀 보호)")
    }

    // MARK: - 회귀: Claude auto → "Auto+"

    func test_claudeAuto_returnsAutoPlus() {
        let agent = makeAgent(source: .cli, permissionMode: "auto")
        XCTAssertEqual(agent.modeDisplayName, "Auto+",
                       "Claude CLI auto → 'Auto+' (회귀 보호)")
    }

    // MARK: - 회귀: Claude default/기타 → "Ask"

    func test_claudeDefault_returnsAsk() {
        let agent = makeAgent(source: .cli, permissionMode: "default")
        XCTAssertEqual(agent.modeDisplayName, "Ask",
                       "Claude CLI default → 'Ask' (회귀 보호)")
    }

    // MARK: - AC-R1.2: sourceBadgeName 검증

    func test_codexCLI_sourceBadgeName_isCodex() {
        let agent = makeAgent(source: .codexCLI)
        XCTAssertEqual(agent.sourceBadgeName, "Codex",
                       ".codexCLI sourceBadgeName → 'Codex' (AC-R1.2)")
    }

    func test_codexVSCode_sourceBadgeName_isCodexVSCode() {
        let agent = makeAgent(source: .codexVSCode)
        XCTAssertEqual(agent.sourceBadgeName, "Codex VSCode",
                       ".codexVSCode sourceBadgeName → 'Codex VSCode' (AC-R1.2)")
    }
}
