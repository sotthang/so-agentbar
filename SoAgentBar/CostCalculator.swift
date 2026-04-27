import Foundation

// MARK: - CostCalculator

struct CostCalculator {
    struct ModelPrice {
        let inputPerMTok: Double         // $/million input tokens
        let outputPerMTok: Double        // $/million output tokens
        let cachedInputPerMTok: Double   // [NEW] $/million cached input tokens (0.0 = input 단가 폴백)
    }

    /// 배열 기반 순차 매칭 - Dictionary 순서 비보장 문제 회피
    /// 매칭 순서: 더 구체적인 키부터 → contains() 첫 매칭 승리
    /// (gpt-5-codex → gpt-5.5 → gpt-5 → gpt-4.1 → o4-mini → opus → sonnet → haiku)
    /// 단가 출처: openai.com/api/pricing (2026-04 시점)
    static let priceTable: [(key: String, value: ModelPrice)] = [
        // gpt-5-codex: ChatGPT 구독 플랜 묶음이라 per-token API 단가 없음 — 0.0 유지하면 formatCost가 nil 반환.
        ("gpt-5-codex", ModelPrice(inputPerMTok: 0.0,  outputPerMTok: 0.0,  cachedInputPerMTok: 0.0)),
        // gpt-5.5 (2026-04-23 출시): GPT-5 라인 가격 2배 인상.
        ("gpt-5.5",     ModelPrice(inputPerMTok: 5.0,  outputPerMTok: 30.0, cachedInputPerMTok: 0.50)),
        // gpt-5: cached 90% 할인.
        ("gpt-5",       ModelPrice(inputPerMTok: 1.25, outputPerMTok: 10.0, cachedInputPerMTok: 0.125)),
        ("gpt-4.1",     ModelPrice(inputPerMTok: 2.0,  outputPerMTok: 8.0,  cachedInputPerMTok: 0.50)),
        ("o4-mini",     ModelPrice(inputPerMTok: 1.10, outputPerMTok: 4.40, cachedInputPerMTok: 0.275)),

        // 기존 Claude — cachedInputPerMTok=0.0 (cached 인자가 0이므로 영향 없음)
        ("opus",   ModelPrice(inputPerMTok: 15.0, outputPerMTok: 75.0, cachedInputPerMTok: 0.0)),
        ("sonnet", ModelPrice(inputPerMTok: 3.0,  outputPerMTok: 15.0, cachedInputPerMTok: 0.0)),
        ("haiku",  ModelPrice(inputPerMTok: 0.80, outputPerMTok: 4.0,  cachedInputPerMTok: 0.0)),
    ]

    /// 기존 시그니처 (Claude — cached=0과 동등). 하위 호환성 유지.
    static func estimate(model: String, inputTokens: Int, outputTokens: Int) -> Double? {
        return estimate(
            model: model,
            inputTokens: inputTokens,
            cachedInputTokens: 0,
            outputTokens: outputTokens
        )
    }

    /// [NEW] cached input 토큰을 별도 인자로 받는 오버로드.
    /// - cachedInputPerMTok이 0.0이면 input 단가로 폴백.
    static func estimate(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int
    ) -> Double? {
        guard let price = priceTable.first(where: { model.lowercased().contains($0.key) })?.value
        else { return nil }
        let cachedRate = price.cachedInputPerMTok > 0 ? price.cachedInputPerMTok : price.inputPerMTok
        return (Double(inputTokens) * price.inputPerMTok / 1_000_000)
             + (Double(cachedInputTokens) * cachedRate / 1_000_000)
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
