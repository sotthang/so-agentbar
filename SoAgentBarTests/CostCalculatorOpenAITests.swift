import XCTest
@testable import SoAgentBar

// MARK: - CostCalculatorOpenAITests
// AC-R8.x 검증 (OpenAI 모델 단가, cached input 처리)
// RED: CostCalculator.estimate(model:inputTokens:cachedInputTokens:outputTokens:) 오버로드 없음
//      ModelPrice.cachedInputPerMTok 필드 없음 → 컴파일 에러 예상

final class CostCalculatorOpenAITests: XCTestCase {

    // MARK: - AC-R8.1: priceTable에 OpenAI 4개 모델 등록 확인

    func test_priceTable_containsGpt5Codex() {
        let keys = CostCalculator.priceTable.map { $0.key }
        XCTAssertTrue(keys.contains("gpt-5-codex"),
                      "priceTable에 gpt-5-codex 항목이 있어야 한다 (AC-R8.1)")
    }

    func test_priceTable_containsGpt5() {
        let keys = CostCalculator.priceTable.map { $0.key }
        XCTAssertTrue(keys.contains("gpt-5"),
                      "priceTable에 gpt-5 항목이 있어야 한다 (AC-R8.1)")
    }

    func test_priceTable_containsGpt41() {
        let keys = CostCalculator.priceTable.map { $0.key }
        XCTAssertTrue(keys.contains("gpt-4.1"),
                      "priceTable에 gpt-4.1 항목이 있어야 한다 (AC-R8.1)")
    }

    func test_priceTable_containsO4Mini() {
        let keys = CostCalculator.priceTable.map { $0.key }
        XCTAssertTrue(keys.contains("o4-mini"),
                      "priceTable에 o4-mini 항목이 있어야 한다 (AC-R8.1)")
    }

    // MARK: - 매칭 우선순위: gpt-5-codex가 gpt-5보다 먼저 매칭

    func test_gpt5CodexMatchesBeforeGpt5() {
        // gpt-5-codex 모델명으로 호출 시 gpt-5 단가가 아닌 gpt-5-codex 단가 적용
        // priceTable에서 gpt-5-codex가 gpt-5보다 앞에 있어야 함
        let gpt5CodexIndex = CostCalculator.priceTable.firstIndex(where: { $0.key == "gpt-5-codex" })
        let gpt5Index = CostCalculator.priceTable.firstIndex(where: { $0.key == "gpt-5" })
        XCTAssertNotNil(gpt5CodexIndex, "gpt-5-codex가 priceTable에 있어야 함")
        XCTAssertNotNil(gpt5Index, "gpt-5가 priceTable에 있어야 함")
        if let ci = gpt5CodexIndex, let i = gpt5Index {
            XCTAssertLessThan(ci, i,
                              "gpt-5-codex는 gpt-5보다 priceTable에서 먼저 위치해야 한다(매칭 우선순위)")
        }
    }

    // MARK: - AC-R8.2: gpt-5-codex input=10000/output=5000 비용 계산

    func test_gpt5Codex_calculatesCost() {
        // Developer가 OpenAI pricing 페이지에서 단가를 확정하면 이 assertion의 expected 값도 갱신 필요.
        // 현재는 단가가 placeholder 0.0이므로 결과가 0.0.
        // priceTable에 실제 단가 입력 후 소수점 6자리 비교.
        let result = CostCalculator.estimate(
            model: "gpt-5-codex",
            inputTokens: 10_000,
            cachedInputTokens: 0,
            outputTokens: 5_000
        )
        XCTAssertNotNil(result, "gpt-5-codex 모델 비용 계산 결과가 nil이어서는 안 된다")
        // 실제 단가 확정 후 아래 주석 해제하여 검증:
        // let expected = (10_000.0 * inputPerMTok + 5_000.0 * outputPerMTok) / 1_000_000
        // XCTAssertEqual(result!, expected, accuracy: 0.000001)
    }

    // MARK: - AC-R8.3: 미등록 모델 → nil

    func test_unknownModel_returnsNil() {
        let result = CostCalculator.estimate(
            model: "unknown-model-xyz",
            inputTokens: 1_000,
            cachedInputTokens: 0,
            outputTokens: 500
        )
        XCTAssertNil(result, "priceTable에 없는 모델은 nil을 반환해야 한다 (크래시 금지)")
    }

    // MARK: - AC-R8.6: cached_input_tokens 별도 처리

    func test_cachedInputTokens_appliesCachedRate() {
        // cachedInputPerMTok이 설정된 경우 별도 단가로 계산
        // placeholder 0.0이면 input 단가와 동일하게 폴백
        let resultWithCache = CostCalculator.estimate(
            model: "gpt-5-codex",
            inputTokens: 10_000,
            cachedInputTokens: 4_000,
            outputTokens: 5_000
        )
        let resultWithoutCache = CostCalculator.estimate(
            model: "gpt-5-codex",
            inputTokens: 10_000,
            cachedInputTokens: 0,
            outputTokens: 5_000
        )
        XCTAssertNotNil(resultWithCache, "cached 인자 포함 오버로드가 nil을 반환하면 안 된다")
        XCTAssertNotNil(resultWithoutCache, "cached=0 호출이 nil을 반환하면 안 된다")
        // 단가가 0.0 placeholder일 때는 두 결과가 동일(0.0). 실제 단가 입력 후 차이가 생김.
        // OpenAI pricing 확정 후: cachedInputPerMTok > 0이면 resultWithCache가 다름을 검증.
    }

    // MARK: - cachedInputPerMTok=0.0 → input 단가로 폴백

    func test_cachedInputTokens_zeroCachedRate_fallsBackToInputRate() {
        // cachedInputPerMTok이 0.0이면 input 단가 동일 적용 (fallback 정책)
        // 이 경우 cached 있는 호출 결과가 결정론적이어야 함
        let result = CostCalculator.estimate(
            model: "gpt-5-codex",
            inputTokens: 6_000,
            cachedInputTokens: 4_000,
            outputTokens: 2_000
        )
        XCTAssertNotNil(result, "cachedInputPerMTok=0.0 폴백 처리 시 nil이 아니어야 한다")
    }

    // MARK: - 기존 시그니처 호환 회귀 (cached=0으로 위임)

    func test_legacyEstimate_callsOverloadWithCachedZero() {
        // 기존 estimate(model:inputTokens:outputTokens:) 시그니처가 그대로 동작해야 함
        let legacy = CostCalculator.estimate(
            model: "claude-sonnet-4-6",
            inputTokens: 1_000_000,
            outputTokens: 100_000
        )
        let withZeroCached = CostCalculator.estimate(
            model: "claude-sonnet-4-6",
            inputTokens: 1_000_000,
            cachedInputTokens: 0,
            outputTokens: 100_000
        )
        // 두 결과가 동일해야 함 (기존 시그니처 = cached=0 오버로드 위임)
        XCTAssertEqual(legacy, withZeroCached,
                       "기존 시그니처는 cachedInputTokens=0 오버로드로 위임되어야 한다")
    }

    // MARK: - Claude 기존 모델 회귀 보호

    func test_existingClaudeModels_stillWork() {
        let sonnet = CostCalculator.estimate(model: "claude-sonnet-4-6",
                                             inputTokens: 1_000_000,
                                             outputTokens: 100_000)
        let opus = CostCalculator.estimate(model: "claude-opus-4-6",
                                           inputTokens: 500_000,
                                           outputTokens: 50_000)
        XCTAssertNotNil(sonnet, "Claude Sonnet 모델 비용 계산이 계속 동작해야 한다")
        XCTAssertNotNil(opus, "Claude Opus 모델 비용 계산이 계속 동작해야 한다")
    }
}
