import XCTest
import AppKit
@testable import SoAgentBar

/// AC-X.5: buildUsageSuffix 순수 함수 — 선택 프로바이더별 메뉴바 suffix 포맷 분기 테스트.
/// Claude=쿼터% (기존 buildQuotaSuffix 위임), Codex/Gemini=추정 토큰/비용 포맷.
/// 기존 buildQuotaSuffix 회귀 방지 포함.
@MainActor
final class MenubarUsageSuffixTests: XCTestCase {

    // MARK: - 비쿼터 모드 → 항상 ""

    func test_buildUsageSuffix_emojiMode_returnsEmpty() {
        let usage = ProviderUsage(
            id: .codex, state: .data, isEstimate: true,
            quota: nil,
            estimate: EstimateInfo(totalTokens: 10000, costDollars: 2.5, windowHours: 24)
        )
        let result = AppDelegate.buildUsageSuffix(usage: usage, mode: .emoji)
        XCTAssertEqual(result, "", "쿼터 모드 아닐 때 suffix는 빈 문자열이어야 한다")
    }

    func test_buildUsageSuffix_emojiCountMode_returnsEmpty() {
        let usage = ProviderUsage(
            id: .codex, state: .data, isEstimate: true,
            quota: nil,
            estimate: EstimateInfo(totalTokens: 10000, costDollars: 2.5, windowHours: 24)
        )
        let result = AppDelegate.buildUsageSuffix(usage: usage, mode: .emojiCount)
        XCTAssertEqual(result, "")
    }

    // MARK: - nil usage → ""

    func test_buildUsageSuffix_nilUsage_returnsEmpty() {
        let result = AppDelegate.buildUsageSuffix(usage: nil, mode: .quotaSession)
        XCTAssertEqual(result, "", "usage가 nil이면 suffix는 빈 문자열이어야 한다")
    }

    // MARK: - Claude → 기존 buildQuotaSuffix 경로 (회귀 방지, AC-X.4)

    func test_buildUsageSuffix_claude_quotaSession_formatsS() {
        let quota = QuotaInfo(
            sessionUtilization: 45, sessionResetsAt: nil,
            weeklyUtilization: 72, weeklyResetsAt: nil,
            planName: nil, extra: nil
        )
        let usage = ProviderUsage(id: .claude, state: .data, isEstimate: false,
                                  quota: quota, estimate: nil)
        let result = AppDelegate.buildUsageSuffix(usage: usage, mode: .quotaSession)
        // RED: 스텁은 "" 반환
        XCTAssertEqual(result, "S45%", "Claude + quotaSession → S{n}% 포맷이어야 한다")
    }

    func test_buildUsageSuffix_claude_quotaSessionAndWeekly_formatsSW() {
        let quota = QuotaInfo(
            sessionUtilization: 45, sessionResetsAt: nil,
            weeklyUtilization: 72, weeklyResetsAt: nil,
            planName: nil, extra: nil
        )
        let usage = ProviderUsage(id: .claude, state: .data, isEstimate: false,
                                  quota: quota, estimate: nil)
        let result = AppDelegate.buildUsageSuffix(usage: usage, mode: .quotaSessionAndWeekly)
        // RED
        XCTAssertEqual(result, "S45%/W72%", "Claude + quotaSessionAndWeekly → S{n}%/W{n}% 포맷이어야 한다")
    }

    func test_buildUsageSuffix_claude_noQuota_returnsEmpty() {
        // Claude인데 quota==nil → suffix 없음
        let usage = ProviderUsage(id: .claude, state: .needsSetup, isEstimate: false,
                                  quota: nil, estimate: nil)
        let result = AppDelegate.buildUsageSuffix(usage: usage, mode: .quotaSession)
        XCTAssertEqual(result, "", "Claude quota가 없으면 suffix는 빈 문자열이어야 한다")
    }

    // MARK: - Codex + 비용 있음 → "~$X.X" 포맷 (AC-X.5)

    func test_buildUsageSuffix_codex_withCost_returnsTildeDollar() {
        let usage = ProviderUsage(
            id: .codex, state: .data, isEstimate: true,
            quota: nil,
            estimate: EstimateInfo(totalTokens: 10000, costDollars: 2.3, windowHours: 24)
        )
        let result = AppDelegate.buildUsageSuffix(usage: usage, mode: .quotaSession)
        // RED: 스텁은 "" 반환
        XCTAssertEqual(result, "~$2.3",
                       "Codex 비용 있음 → ~$X.X 포맷이어야 한다 (design.md suffix 계약)")
    }

    func test_buildUsageSuffix_codex_withCostLarger_returnsOneDp() {
        // $12.5 → "~$12.5"
        let usage = ProviderUsage(
            id: .codex, state: .data, isEstimate: true,
            quota: nil,
            estimate: EstimateInfo(totalTokens: 100000, costDollars: 12.5, windowHours: 24)
        )
        let result = AppDelegate.buildUsageSuffix(usage: usage, mode: .quotaSession)
        // RED
        XCTAssertEqual(result, "~$12.5")
    }

    // MARK: - Codex + 비용 추정 불가 → "~{N}k" 포맷 (AC-X.5, C3)

    func test_buildUsageSuffix_codex_costUnavailable_returnsTildeKilo() {
        // gpt-5-codex: costDollars==nil, totalTokens=45000
        let usage = ProviderUsage(
            id: .codex, state: .data, isEstimate: true,
            quota: nil,
            estimate: EstimateInfo(totalTokens: 45000, costDollars: nil, windowHours: 24)
        )
        let result = AppDelegate.buildUsageSuffix(usage: usage, mode: .quotaSession)
        // RED: 스텁은 "" 반환
        XCTAssertEqual(result, "~45k",
                       "Codex 비용 추정 불가 → ~{N}k 포맷이어야 한다 (design.md suffix 계약)")
    }

    func test_buildUsageSuffix_codex_costUnavailable_roundsDown() {
        // 1500 tokens → "~1k" (소수점 버림)
        let usage = ProviderUsage(
            id: .codex, state: .data, isEstimate: true,
            quota: nil,
            estimate: EstimateInfo(totalTokens: 1500, costDollars: nil, windowHours: 24)
        )
        let result = AppDelegate.buildUsageSuffix(usage: usage, mode: .quotaSession)
        // RED
        XCTAssertEqual(result, "~1k", "1,500 토큰은 ~1k로 표시돼야 한다")
    }

    // MARK: - Codex + 토큰도 비용도 없음 → "" (AC-X.5)

    func test_buildUsageSuffix_codex_noTokensNoCost_returnsEmpty() {
        let usage = ProviderUsage(
            id: .codex, state: .data, isEstimate: true,
            quota: nil,
            estimate: EstimateInfo(totalTokens: 0, costDollars: nil, windowHours: 24)
        )
        let result = AppDelegate.buildUsageSuffix(usage: usage, mode: .quotaSession)
        XCTAssertEqual(result, "", "토큰도 비용도 없으면 suffix 미표시")
    }

    // MARK: - Codex 비쿼터 상태 → "" (AC-X.5)

    func test_buildUsageSuffix_codex_nonDataState_returnsEmpty() {
        // .needsSetup 상태면 estimate가 있어도 suffix 미표시
        let usage = ProviderUsage(
            id: .codex, state: .needsSetup, isEstimate: true,
            quota: nil, estimate: nil
        )
        let result = AppDelegate.buildUsageSuffix(usage: usage, mode: .quotaSession)
        XCTAssertEqual(result, "", ".needsSetup 상태면 suffix는 빈 문자열이어야 한다")
    }

    func test_buildUsageSuffix_codex_errorState_returnsEmpty() {
        let usage = ProviderUsage(
            id: .codex, state: .error("fetch failed"), isEstimate: true,
            quota: nil, estimate: nil
        )
        let result = AppDelegate.buildUsageSuffix(usage: usage, mode: .quotaSession)
        XCTAssertEqual(result, "", ".error 상태면 suffix는 빈 문자열이어야 한다")
    }

    // MARK: - suffix 길이 제약 (7~8자 이내, design.md)

    func test_buildUsageSuffix_codex_suffixIsShort() {
        let usage = ProviderUsage(
            id: .codex, state: .data, isEstimate: true,
            quota: nil,
            estimate: EstimateInfo(totalTokens: 999000, costDollars: 99.9, windowHours: 24)
        )
        let result = AppDelegate.buildUsageSuffix(usage: usage, mode: .quotaSession)
        // RED — 스텁은 "" 반환하므로 통과할 수 없음
        if !result.isEmpty {
            XCTAssertLessThanOrEqual(result.count, 8,
                                     "메뉴바 suffix는 8자 이내여야 한다 (design.md)")
        }
    }

    // MARK: - 기존 buildQuotaSuffix 회귀 방지 (NFR5)

    func test_buildQuotaSuffix_regression_sessionOnly() {
        // 기존 buildQuotaSuffix는 buildUsageSuffix 도입 후에도 동작해야 함
        let s = AppDelegate.buildQuotaSuffix(util: (45, 72), mode: .quotaSession)
        XCTAssertEqual(s, "S45%", "기존 buildQuotaSuffix 회귀 없음")
    }

    func test_buildQuotaSuffix_regression_sessionAndWeekly() {
        let s = AppDelegate.buildQuotaSuffix(util: (30, 85), mode: .quotaSessionAndWeekly)
        XCTAssertEqual(s, "S30%/W85%", "기존 buildQuotaSuffix 회귀 없음")
    }
}
