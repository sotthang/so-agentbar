import XCTest
@testable import SoAgentBar

final class CostCalculatorTests: XCTestCase {

    // MARK: - estimate(model:inputTokens:outputTokens:)

    // Happy path: Sonnet 1M input + 100K output
    // Input:  1_000_000 * $3.00 / 1_000_000 = $3.00
    // Output:   100_000 * $15.00 / 1_000_000 = $1.50
    // Total: $4.50
    func test_estimate_sonnet_returns_4_50() {
        let result = CostCalculator.estimate(
            model: "claude-sonnet-4-6",
            inputTokens: 1_000_000,
            outputTokens: 100_000
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 4.50, accuracy: 0.0001)
    }

    // Happy path: Opus 500K input + 50K output
    // Input:  500_000 * $15.00 / 1_000_000 = $7.50
    // Output:  50_000 * $75.00 / 1_000_000 = $3.75
    // Total: $11.25
    func test_estimate_opus_returns_11_25() {
        let result = CostCalculator.estimate(
            model: "claude-opus-4-6",
            inputTokens: 500_000,
            outputTokens: 50_000
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 11.25, accuracy: 0.0001)
    }

    // Happy path: Haiku 1M input + 100K output
    // Input:  1_000_000 * $0.80 / 1_000_000 = $0.80
    // Output:   100_000 * $4.00 / 1_000_000 = $0.40
    // Total: $1.20
    func test_estimate_haiku_returns_1_20() {
        let result = CostCalculator.estimate(
            model: "claude-3-5-haiku-20241022",
            inputTokens: 1_000_000,
            outputTokens: 100_000
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 1.20, accuracy: 0.0001)
    }

    // Error case: unknown model returns nil
    func test_estimate_unknownModel_returnsNil() {
        let result = CostCalculator.estimate(
            model: "gpt-4o",
            inputTokens: 1_000_000,
            outputTokens: 100_000
        )
        XCTAssertNil(result)
    }

    // Error case: empty string model returns nil
    func test_estimate_emptyModel_returnsNil() {
        let result = CostCalculator.estimate(
            model: "",
            inputTokens: 100,
            outputTokens: 100
        )
        XCTAssertNil(result)
    }

    // Edge case: case-insensitive matching — "Claude-SONNET-4-6" should use Sonnet pricing
    func test_estimate_caseInsensitive_sonnet() {
        let result = CostCalculator.estimate(
            model: "Claude-SONNET-4-6",
            inputTokens: 1_000_000,
            outputTokens: 100_000
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 4.50, accuracy: 0.0001)
    }

    // Edge case: multi-model session
    // Sonnet 500K input / 100K output: $1.50 + $1.50 = $3.00
    // Haiku  200K input /  50K output: $0.16 + $0.20 = $0.36
    // Total: $3.36
    func test_estimate_multiModel_sonnetPlusHaiku_returns_3_36() {
        let sonnetCost = CostCalculator.estimate(
            model: "claude-sonnet-4-6",
            inputTokens: 500_000,
            outputTokens: 100_000
        )
        let haikuCost = CostCalculator.estimate(
            model: "claude-3-5-haiku-20241022",
            inputTokens: 200_000,
            outputTokens: 50_000
        )
        XCTAssertNotNil(sonnetCost)
        XCTAssertNotNil(haikuCost)
        let total = sonnetCost! + haikuCost!
        XCTAssertEqual(total, 3.36, accuracy: 0.0001)
    }

    // MARK: - formatCost(_:)

    // Edge case: cost below $0.01 → "<$0.01"
    func test_formatCost_belowOneCent_returnsLessThanOneCent() {
        let result = CostCalculator.formatCost(0.005)
        XCTAssertEqual(result, "<$0.01")
    }

    // Happy path: $0.123 → "$0.12" (two decimal places)
    func test_formatCost_lessThanTenDollars_returnsTwoDecimals() {
        let result = CostCalculator.formatCost(0.123)
        XCTAssertEqual(result, "$0.12")
    }

    // Happy path: $12.3 → "$12.3" (one decimal place)
    func test_formatCost_tenDollarsOrMore_returnsOneDecimal() {
        let result = CostCalculator.formatCost(12.3)
        XCTAssertEqual(result, "$12.3")
    }
}
