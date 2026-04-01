import Foundation

// MARK: - CostCalculator

struct CostCalculator {
    struct ModelPrice {
        let inputPerMTok: Double   // $/million input tokens
        let outputPerMTok: Double  // $/million output tokens
    }

    /// 배열 기반 순차 매칭 - Dictionary 순서 비보장 문제 회피
    /// 매칭 순서: opus -> sonnet -> haiku
    static let priceTable: [(key: String, value: ModelPrice)] = [
        ("opus",   ModelPrice(inputPerMTok: 15.0, outputPerMTok: 75.0)),
        ("sonnet", ModelPrice(inputPerMTok: 3.0,  outputPerMTok: 15.0)),
        ("haiku",  ModelPrice(inputPerMTok: 0.80, outputPerMTok: 4.0)),
    ]

    /// 모델명과 토큰 수로 비용 계산. 알 수 없는 모델이면 nil 반환.
    static func estimate(model: String, inputTokens: Int, outputTokens: Int) -> Double? {
        guard let price = priceTable.first(where: { model.lowercased().contains($0.key) })?.value
        else { return nil }
        return (Double(inputTokens) * price.inputPerMTok / 1_000_000)
             + (Double(outputTokens) * price.outputPerMTok / 1_000_000)
    }

    /// 비용 포맷 규칙 (모든 UI 공통)
    /// - $10 이상: "$12.3" (소수점 1자리)
    /// - $0.01 이상 ~ $10 미만: "$0.12" (소수점 2자리)
    /// - $0.01 미만: "<$0.01"
    /// - nil 또는 0: nil (표시하지 않음)
    static func formatCost(_ cost: Double?) -> String? {
        guard let cost, cost > 0 else { return nil }
        if cost < 0.01 { return "<$0.01" }
        if cost >= 10 { return String(format: "$%.1f", cost) }
        return String(format: "$%.2f", cost)
    }
}
