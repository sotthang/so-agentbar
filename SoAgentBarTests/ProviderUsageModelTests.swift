import XCTest
@testable import SoAgentBar

/// Phase 0 — ProviderUsage 모델 계약 단위 테스트 (AC-0.2)
/// 정확치(quota) / 추정치(estimate) / 비용 추정 불가 케이스를 모두 표현할 수 있음을 검증한다.
final class ProviderUsageModelTests: XCTestCase {

    // MARK: - EstimateInfo.isCostUnavailable (AC-0.2, AC-1.2)

    func test_isCostUnavailable_returnsTrue_whenCostNilAndTokensPositive() {
        let info = EstimateInfo(totalTokens: 1000, costDollars: nil, windowHours: 24)
        XCTAssertTrue(info.isCostUnavailable,
                      "costDollars가 nil이고 totalTokens>0이면 isCostUnavailable은 true여야 한다")
    }

    func test_isCostUnavailable_returnsFalse_whenCostPresent() {
        let info = EstimateInfo(totalTokens: 1000, costDollars: 2.5, windowHours: 24)
        XCTAssertFalse(info.isCostUnavailable,
                       "costDollars가 있으면 isCostUnavailable은 false여야 한다")
    }

    func test_isCostUnavailable_returnsFalse_whenBothZero() {
        // 토큰 0 + 비용 nil → 데이터 없음 케이스, 비용 추정 불가가 아님
        let info = EstimateInfo(totalTokens: 0, costDollars: nil, windowHours: 24)
        XCTAssertFalse(info.isCostUnavailable,
                       "totalTokens가 0이면 isCostUnavailable은 false여야 한다 (데이터 없음 케이스)")
    }

    func test_isCostUnavailable_returnsFalse_whenCostZeroAndTokensPositive() {
        // costDollars가 0.0 (nil이 아님) → 비용 추정 불가 아님
        let info = EstimateInfo(totalTokens: 1000, costDollars: 0.0, windowHours: 24)
        XCTAssertFalse(info.isCostUnavailable,
                       "costDollars가 0.0으로 세팅된 경우(nil이 아님) isCostUnavailable은 false여야 한다")
    }

    // MARK: - ProviderUsage.loading 팩토리 (AC-0.2)

    func test_loadingFactory_claude_hasCorrectFields() {
        let usage = ProviderUsage.loading(.claude, isEstimate: false)
        XCTAssertEqual(usage.id, .claude)
        XCTAssertEqual(usage.state, .loading)
        XCTAssertFalse(usage.isEstimate, "Claude는 isEstimate=false여야 한다")
        XCTAssertNil(usage.quota)
        XCTAssertNil(usage.estimate)
    }

    func test_loadingFactory_codex_hasCorrectFields() {
        let usage = ProviderUsage.loading(.codex, isEstimate: true)
        XCTAssertEqual(usage.id, .codex)
        XCTAssertEqual(usage.state, .loading)
        XCTAssertTrue(usage.isEstimate, "Codex는 isEstimate=true여야 한다")
        XCTAssertNil(usage.quota)
        XCTAssertNil(usage.estimate)
    }

    // MARK: - ProviderUsage Equatable (AC-0.2)

    func test_providerUsage_equatable_sameValues() {
        let a = ProviderUsage(id: .codex, state: .data, isEstimate: true,
                              quota: nil,
                              estimate: EstimateInfo(totalTokens: 500, costDollars: 1.2, windowHours: 24))
        let b = ProviderUsage(id: .codex, state: .data, isEstimate: true,
                              quota: nil,
                              estimate: EstimateInfo(totalTokens: 500, costDollars: 1.2, windowHours: 24))
        XCTAssertEqual(a, b)
    }

    func test_providerUsage_equatable_differentProvider() {
        let a = ProviderUsage.loading(.claude, isEstimate: false)
        let b = ProviderUsage.loading(.codex, isEstimate: true)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - ProviderID.displayName

    func test_providerID_displayName_claude() {
        XCTAssertEqual(ProviderID.claude.displayName, "Claude")
    }

    func test_providerID_displayName_codex() {
        XCTAssertEqual(ProviderID.codex.displayName, "Codex")
    }

    func test_providerID_displayName_gemini() {
        XCTAssertEqual(ProviderID.gemini.displayName, "Gemini")
    }

    // MARK: - ProviderState Equatable

    func test_providerState_errorEquatable_sameMessage() {
        XCTAssertEqual(ProviderState.error("msg"), ProviderState.error("msg"))
    }

    func test_providerState_errorEquatable_differentMessage() {
        XCTAssertNotEqual(ProviderState.error("a"), ProviderState.error("b"))
    }

    // MARK: - ProviderUsage 정확 쿼터 표현 (Claude 계열)

    func test_providerUsage_quotaPath_claudeModel() {
        let quota = QuotaInfo(
            sessionUtilization: 45,
            sessionResetsAt: nil,
            weeklyUtilization: 70,
            weeklyResetsAt: nil,
            planName: "Max 5x",
            extra: nil
        )
        let usage = ProviderUsage(id: .claude, state: .data, isEstimate: false,
                                  quota: quota, estimate: nil)
        XCTAssertFalse(usage.isEstimate)
        XCTAssertNotNil(usage.quota)
        XCTAssertNil(usage.estimate)
        XCTAssertEqual(usage.quota?.sessionUtilization, 45)
        XCTAssertEqual(usage.quota?.planName, "Max 5x")
    }

    // MARK: - ProviderUsage 추정치 표현 (Codex 계열, windowHours=24)

    func test_providerUsage_estimatePath_codexModel_24hWindow() {
        let estimate = EstimateInfo(totalTokens: 12000, costDollars: 2.34, windowHours: 24)
        let usage = ProviderUsage(id: .codex, state: .data, isEstimate: true,
                                  quota: nil, estimate: estimate)
        XCTAssertTrue(usage.isEstimate)
        XCTAssertNil(usage.quota)
        XCTAssertNotNil(usage.estimate)
        XCTAssertEqual(usage.estimate?.totalTokens, 12000)
        XCTAssertEqual(usage.estimate?.costDollars, 2.34)
        XCTAssertEqual(usage.estimate?.windowHours, 24)
    }

    // MARK: - ProviderUsage 비용 추정 불가 케이스 (gpt-5-codex 단가 0)

    func test_providerUsage_costUnavailable_codex_gpt5codex() {
        // gpt-5-codex 단가 0 → CostCalculator.estimate는 0.0을 반환하므로 nil로 처리해야 함
        let estimate = EstimateInfo(totalTokens: 45000, costDollars: nil, windowHours: 24)
        let usage = ProviderUsage(id: .codex, state: .data, isEstimate: true,
                                  quota: nil, estimate: estimate)
        XCTAssertTrue(usage.estimate?.isCostUnavailable ?? false,
                      "gpt-5-codex처럼 단가 0이면 isCostUnavailable=true여야 한다")
    }
}
